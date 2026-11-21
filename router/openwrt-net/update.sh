#!/bin/sh
# TikTok bridge updater, version 2.1 (OpenWrt Net R7800)
# Daily update of author4 and observed4 only. Never touches cdn77_test4.
set -eu
umask 077
BASE=/etc/tiktok-block
URL=https://raw.githubusercontent.com/tac2sc/tiktok-blocklists/main/dist
TMP="$(mktemp -d /tmp/tiktok-daily.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

log() { logger -t tiktok-update "$*"; echo "$*"; }
[ -s "$BASE/table.nft" ] || { log 'ERROR: saved nft table missing'; exit 1; }
for SET in author4 observed4 cdn77_test4; do
    nft list set bridge tiktok_block "$SET" >/dev/null 2>&1 || { log "ERROR: missing $SET"; exit 1; }
done
nft list chain bridge tiktok_block forward | grep -q 'ip daddr @author4' || exit 1
nft list chain bridge tiktok_block forward | grep -q 'ip daddr @observed4' || exit 1

# Download all three generated components. No changes until all are validated.
for NAME in author-ipv4 observed-ipv4 manual-ipv4; do
    wget -q -O "$TMP/$NAME.txt" "$URL/$NAME.txt" || { log "ERROR: download $NAME"; exit 1; }
done
wget -q -O "$TMP/manifest.json" "$URL/manifest.json" || { log 'ERROR: manifest download'; exit 1; }

# Verify each GitHub output against the published manifest before using it.
for NAME in author-ipv4 observed-ipv4 manual-ipv4; do
    EXPECTED="$(awk -F '"' -v key="$NAME.txt" '$2==key && length($4)==64 && $4 ~ /^[0-9a-f]+$/ {print $4; exit}' "$TMP/manifest.json")"
    ACTUAL="$(sha256sum "$TMP/$NAME.txt" | awk '{print $1}')"
    [ -n "$EXPECTED" ] && [ "$ACTUAL" = "$EXPECTED" ] || { log "ERROR: sha256 mismatch for $NAME"; exit 1; }
done

validate() {
    F="$1" MIN="$2"
    awk -v min="$MIN" '
      function err() { bad=1; exit 1 }
      /^[[:space:]]*$/ { next }
      {
        if ($0 !~ /^[0-9.]+(\/[0-9]+)?$/) err()
        n=split($0,a,"/"); if (n>2) err()
        if (n==2 && (a[2]+0<16 || a[2]+0>32 || a[2] !~ /^[0-9]+$/)) err()
        m=split(a[1],p,"."); if(m!=4) err()
        for(i=1;i<=4;i++) if(p[i]=="" || p[i] !~ /^[0-9]+$/ || p[i]+0>255 || length(p[i])>3) err()
        count++
      }
      END { if (bad || count<min || count>10000) exit 1 }
    ' "$F"
}
validate "$TMP/author-ipv4.txt" 20 || { log 'ERROR: author list validation'; exit 1; }
validate "$TMP/observed-ipv4.txt" 16 || { log 'ERROR: observed list validation'; exit 1; }
validate "$TMP/manual-ipv4.txt" 0 || { log 'ERROR: manual list validation'; exit 1; }

# Locally retained addresses from the existing 26-element observed set.
# Safe bridge until the updated GitHub CSV has propagated everywhere.
cat "$TMP/observed-ipv4.txt" "$BASE/observed-local.txt" 2>/dev/null | sort -u > "$TMP/observed-merged.txt"
cat "$TMP/author-ipv4.txt" "$TMP/manual-ipv4.txt" | sort -u > "$TMP/author-merged.txt"
validate "$TMP/observed-merged.txt" 16 || exit 1
validate "$TMP/author-merged.txt" 20 || exit 1

# Build one nft batch, committing both sets together. Existing chain/rules/counters are untouched.
{
    for SET in author4 observed4; do
        if [ "$SET" = author4 ]; then F="$TMP/author-merged.txt"; else F="$TMP/observed-merged.txt"; fi
        echo "flush set bridge tiktok_block $SET"
        printf 'add element bridge tiktok_block %s { ' "$SET"
        awk 'NF { if (count++) printf ", "; printf "%s", $0 }' "$F"
        echo ' }'
    done
} > "$TMP/sets.nft"

nft -c -f "$TMP/sets.nft" || { log 'ERROR: nft validation failed; live rules unchanged'; exit 1; }

# Prepare boot-persistent version on same filesystem before activating it.
cp "$TMP/sets.nft" "$BASE/sets-current.nft.new" || exit 1
if [ -s "$BASE/sets-current.nft" ]; then
    cp "$BASE/sets-current.nft" "$BASE/sets-previous.nft" || exit 1
fi
if ! nft -f "$TMP/sets.nft"; then
    rm -f "$BASE/sets-current.nft.new"
    log 'ERROR: nft apply failed; transaction not committed'
    exit 1
fi
mv -f "$BASE/sets-current.nft.new" "$BASE/sets-current.nft"
log 'Updated author4 and observed4; cdn77_test4 unchanged'
