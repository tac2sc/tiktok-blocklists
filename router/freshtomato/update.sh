#!/bin/sh
# TikTok FreshTomato Daily Update, version 1.3
# FreshTomato R8000, LAN 192.168.2.0/24
# SHA256 verification, backup, swap and rollback

set -eu
umask 077

BASE=/jffs/tiktok-block
URL=https://raw.githubusercontent.com/tac2sc/tiktok-blocklists/main/dist
LOCK=/tmp/tiktok-daily-update.lock

TMP=
STAGE=
LOCKED=0
CA=0
CO=0
SA=0
SO=0
PA=0
PO=0
SUCCESS=0

log() {
    logger -t tiktok-update "$*" 2>/dev/null || :
    echo "$*"
}

cleanup() {
    RC=$?
    trap - 0 1 2 15

    if [ "$SUCCESS" -ne 1 ]; then
        # Restore persistent files if replacement started.
        if [ "$PO" -eq 1 ]; then
            mv -f "$STAGE/old-observed.save" \
                "$BASE/tiktok_observed_v4.save" ||
                log "CRITICAL: observed save rollback failed"
        fi
        if [ "$PA" -eq 1 ]; then
            mv -f "$STAGE/old-author.save" \
                "$BASE/tiktok_author_v4.save" ||
                log "CRITICAL: author save rollback failed"
        fi

        # Restore previous live IPSet contents.
        if [ "$SO" -eq 1 ]; then
            ipset swap tto_next tiktok_observed_v4 ||
                log "CRITICAL: observed IPSet rollback failed"
        fi
        if [ "$SA" -eq 1 ]; then
            ipset swap tta_next tiktok_author_v4 ||
                log "CRITICAL: author IPSet rollback failed"
        fi
    fi

    if [ "$CO" -eq 1 ]; then
        ipset destroy tto_next 2>/dev/null || :
    fi
    if [ "$CA" -eq 1 ]; then
        ipset destroy tta_next 2>/dev/null || :
    fi

    [ -z "$STAGE" ] || rm -rf "$STAGE"
    [ -z "$TMP" ] || rm -rf "$TMP"

    if [ "$LOCKED" -eq 1 ]; then
        rmdir "$LOCK" 2>/dev/null || :
    fi

    exit "$RC"
}

trap cleanup 0
trap 'exit 1' 1 2 15

[ -s "$BASE/firewall.sh" ] || {
    log "ERROR: firewall.sh missing"
    exit 1
}

[ -x "$BASE/backup.sh" ] || {
    log "ERROR: backup.sh missing"
    exit 1
}

mkdir "$LOCK" 2>/dev/null || {
    log "ERROR: another update is running"
    exit 1
}
LOCKED=1

TMP=$(mktemp -d /tmp/tiktok-update.XXXXXX) || exit 1
STAGE=$(mktemp -d "$BASE/.tiktok-stage.XXXXXX") || exit 1

# Check existing firewall and IPSet types.
for S in tiktok_author_v4 tiktok_observed_v4; do
    ipset list "$S" | grep -q '^Type: hash:net$' || {
        log "ERROR: unexpected IPSet type: $S"
        exit 1
    }
    [ -s "$BASE/$S.save" ] || {
        log "ERROR: missing persistent file: $S"
        exit 1
    }
done

for S in tta_next tto_next; do
    if ipset list "$S" >/dev/null 2>&1; then
        log "ERROR: temporary IPSet already exists: $S"
        exit 1
    fi
done

iptables -C FORWARD \
    -s 192.168.2.0/24 \
    -m set --match-set tiktok_author_v4 dst \
    -j DROP || exit 1

iptables -C FORWARD \
    -s 192.168.2.0/24 \
    -m set --match-set tiktok_observed_v4 dst \
    -j DROP || exit 1

# Download over HTTPS with bounded timeouts.
for F in author-ipv4.txt observed-ipv4.txt manual-ipv4.txt manifest.json; do
    curl -fsSL \
        --connect-timeout 15 \
        --max-time 45 \
        -o "$TMP/$F" \
        "$URL/$F" || {
            log "ERROR: download failed: $F"
            exit 1
        }
done

# Verify SHA256 of all three source lists.
for NAME in author-ipv4 observed-ipv4 manual-ipv4; do
    EXPECTED=$(awk -F '"' -v key="$NAME.txt" '
        $2==key && length($4)==64 &&
        $4 ~ /^[0-9a-f]+$/ {
            print $4
            exit
        }
    ' "$TMP/manifest.json")

    HASH=$(openssl dgst -sha256 "$TMP/$NAME.txt") || exit 1
    ACTUAL=${HASH##* }

    if [ -z "$EXPECTED" ] || [ "$ACTUAL" != "$EXPECTED" ]; then
        log "ERROR: SHA256 mismatch: $NAME"
        exit 1
    fi
done

# Validate CIDR syntax and reasonable list sizes.
validate() {
    awk -v min="$2" '
        function err() { bad=1; exit 1 }
        /^[[:space:]]*$/ { next }
        {
            if ($0 !~ /^[0-9.]+(\/[0-9]+)?$/) err()

            n=split($0,a,"/")
            if (n>2) err()
            if (n==2 &&
                (a[2]+0<16 || a[2]+0>32 ||
                 a[2]!~/^[0-9]+$/)) err()

            n=split(a[1],p,".")
            if (n!=4) err()

            for (i=1;i<=4;i++)
                if (p[i]=="" ||
                    p[i]!~/^[0-9]+$/ ||
                    p[i]+0>255 ||
                    length(p[i])>3) err()

            count++
        }
        END {
            if (bad || count<min || count>10000)
                exit 1
        }
    ' "$1"
}

validate "$TMP/author-ipv4.txt" 20 || exit 1
validate "$TMP/observed-ipv4.txt" 16 || exit 1
validate "$TMP/manual-ipv4.txt" 0 || exit 1

cat "$TMP/author-ipv4.txt" "$TMP/manual-ipv4.txt" |
    sort -u > "$TMP/author.txt"

sort -u "$TMP/observed-ipv4.txt" > "$TMP/observed.txt"

# Build temporary sets without changing live rules.
ipset create tta_next hash:net family inet || exit 1
CA=1

ipset create tto_next hash:net family inet || exit 1
CO=1

while IFS= read -r NET; do
    [ -n "$NET" ] || continue
    ipset add tta_next "$NET" || exit 1
done < "$TMP/author.txt"

while IFS= read -r NET; do
    [ -n "$NET" ] || continue
    ipset add tto_next "$NET" || exit 1
done < "$TMP/observed.txt"

A=$(ipset list tta_next |
    awk '/^Members:/ {m=1;next} m && NF {n++} END {print n+0}')

O=$(ipset list tto_next |
    awk '/^Members:/ {m=1;next} m && NF {n++} END {print n+0}')

[ "$A" -ge 20 ] && [ "$O" -ge 16 ] || {
    log "ERROR: incomplete temporary IPSet"
    exit 1
}

# Prepare persistent files BEFORE live swapping.
cp "$BASE/tiktok_author_v4.save" "$STAGE/old-author.save" || exit 1
cp "$BASE/tiktok_observed_v4.save" "$STAGE/old-observed.save" || exit 1

ipset save tta_next > "$STAGE/raw-author.save" || exit 1
ipset save tto_next > "$STAGE/raw-observed.save" || exit 1

sed \
    -e 's/^create tta_next /create tiktok_author_v4 /' \
    -e 's/^add tta_next /add tiktok_author_v4 /' \
    "$STAGE/raw-author.save" > "$STAGE/next-author.save" || exit 1

sed \
    -e 's/^create tto_next /create tiktok_observed_v4 /' \
    -e 's/^add tto_next /add tiktok_observed_v4 /' \
    "$STAGE/raw-observed.save" > "$STAGE/next-observed.save" || exit 1

grep -q '^create tiktok_author_v4 hash:net ' \
    "$STAGE/next-author.save" || exit 1

grep -q '^create tiktok_observed_v4 hash:net ' \
    "$STAGE/next-observed.save" || exit 1

AA=$(grep -c '^add tiktok_author_v4 ' "$STAGE/next-author.save")
OO=$(grep -c '^add tiktok_observed_v4 ' "$STAGE/next-observed.save")

[ "$AA" -eq "$A" ] && [ "$OO" -eq "$O" ] || {
    log "ERROR: persistent snapshot count mismatch"
    exit 1
}

# Mandatory verified backup before modifying active sets.
/bin/sh "$BASE/backup.sh" || {
    log "ERROR: backup failed, no changes applied"
    exit 1
}

# Switch live sets. On failure, cleanup rolls back.
ipset swap tta_next tiktok_author_v4 || exit 1
SA=1

ipset swap tto_next tiktok_observed_v4 || exit 1
SO=1

# Atomic replacement of each file on the same JFFS filesystem.
PA=1
mv -f "$STAGE/next-author.save" \
    "$BASE/tiktok_author_v4.save" || exit 1

PO=1
mv -f "$STAGE/next-observed.save" \
    "$BASE/tiktok_observed_v4.save" || exit 1

SUCCESS=1
log "SUCCESS: author=$A observed=$O; CDN77 unchanged"
exit 0
