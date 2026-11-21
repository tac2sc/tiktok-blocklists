#!/bin/sh
# TikTok FreshTomato daily IPSet update, version 1.1
# Leaves iptables DROP rules unchanged; swaps only author and observed sets.
set -eu
umask 077
BASE=/jffs/tiktok-block
URL=https://raw.githubusercontent.com/tac2sc/tiktok-blocklists/main/dist
[ -s "$BASE/firewall.sh" ] || { echo 'ERROR: no firewall.sh'; exit 1; }
TMP="$(mktemp -d /tmp/tiktok-update.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
log() { logger -t tiktok-update "$*"; echo "$*"; }

for S in tiktok_author_v4 tiktok_observed_v4; do
    ipset list "$S" >/dev/null 2>&1 || { log "ERROR: missing $S"; exit 1; }
done
# Refuse to alter unexpected firewall state.
iptables -C FORWARD -s 192.168.2.0/24 -m set --match-set tiktok_author_v4 dst -j DROP 2>/dev/null || exit 1
iptables -C FORWARD -s 192.168.2.0/24 -m set --match-set tiktok_observed_v4 dst -j DROP 2>/dev/null || exit 1

fetch() {
    FILE="$1"
    if wget -q -O "$TMP/$FILE.txt" "$URL/$FILE.txt"; then return 0; fi
    if curl -fsSL --connect-timeout 15 --max-time 45 -o "$TMP/$FILE.txt" "$URL/$FILE.txt" 2>/dev/null; then return 0; fi
    log "ERROR: download failed for $FILE"
    return 1
}
for N in author-ipv4 observed-ipv4 manual-ipv4; do fetch "$N" || exit 1; done
if wget -q -O "$TMP/manifest.json" "$URL/manifest.json"; then :
elif curl -fsSL --connect-timeout 15 --max-time 45 -o "$TMP/manifest.json" "$URL/manifest.json" 2>/dev/null; then :
else log 'ERROR: manifest download'; exit 1; fi
# Verify each GitHub output against the published manifest before using it.
for NAME in author-ipv4 observed-ipv4 manual-ipv4; do
    EXPECTED="$(awk -F '"' -v key="$NAME.txt" '$2==key && length($4)==64 && $4 ~ /^[0-9a-f]+$/ {print $4; exit}' "$TMP/manifest.json")"
    ACTUAL="$(sha256sum "$TMP/$NAME.txt" | awk '{print $1}')"
    [ -n "$EXPECTED" ] && [ "$ACTUAL" = "$EXPECTED" ] || { log "ERROR: sha256 mismatch for $NAME"; exit 1; }
done

validate() {
    awk -v min="$2" '
      function err(){bad=1; exit 1}
      /^[[:space:]]*$/ {next}
      {
        if($0 !~ /^[0-9.]+(\/[0-9]+)?$/) err()
        n=split($0,a,"/"); if(n>2) err()
        if(n==2 && (a[2]+0<16 || a[2]+0>32 || a[2]!~/^[0-9]+$/)) err()
        n=split(a[1],p,"."); if(n!=4) err()
        for(i=1;i<=4;i++) if(p[i]=="" || p[i]!~/^[0-9]+$/ || p[i]+0>255 || length(p[i])>3) err()
        count++
      }
      END {if(bad || count<min || count>10000) exit 1}
    ' "$1"
}
validate "$TMP/author-ipv4.txt" 20 || exit 1
validate "$TMP/observed-ipv4.txt" 16 || exit 1
validate "$TMP/manual-ipv4.txt" 0 || exit 1
cat "$TMP/author-ipv4.txt" "$TMP/manual-ipv4.txt" | sort -u > "$TMP/author.txt"
sort -u "$TMP/observed-ipv4.txt" > "$TMP/observed.txt"

# Unique scratch sets must not already exist; never delete an unknown set.
for S in tta_next tto_next; do
    ipset list "$S" >/dev/null 2>&1 && { log "ERROR: scratch set $S already exists"; exit 1; }
done
CREATED=0
cleanup() {
    [ "$CREATED" -eq 1 ] && {
        ipset destroy tta_next 2>/dev/null || :
        ipset destroy tto_next 2>/dev/null || :
    }
    rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM
ipset create tta_next hash:net family inet || exit 1
CREATED=1
ipset create tto_next hash:net family inet || exit 1
while IFS= read -r NET; do
    [ -n "$NET" ] || continue
    ipset add tta_next "$NET" || { log "ERROR: cannot add author $NET"; exit 1; }
done < "$TMP/author.txt"
while IFS= read -r NET; do
    [ -n "$NET" ] || continue
    ipset add tto_next "$NET" || { log "ERROR: cannot add observed $NET"; exit 1; }
done < "$TMP/observed.txt"
# Ensure actual membership counts before touching live sets.
A=$(ipset list tta_next | sed -n '/^Members:/,$p' | sed '1d' | wc -l)
O=$(ipset list tto_next | sed -n '/^Members:/,$p' | sed '1d' | wc -l)
[ "$A" -ge 20 ] && [ "$O" -ge 16 ] || { log 'ERROR: incomplete scratch sets'; exit 1; }

# Create verified daily backup BEFORE changing live firewall data.
/bin/sh "$BASE/backup.sh" || { log 'ERROR: backup failed, no changes applied'; exit 1; }

ipset swap tta_next tiktok_author_v4 || exit 1
if ! ipset swap tto_next tiktok_observed_v4; then
    ipset swap tta_next tiktok_author_v4 || :
    log 'ERROR: second swap failed; first swap rolled back'
    exit 1
fi
# Save effective content for the existing firewall.sh boot restoration.
ipset save tiktok_author_v4 > "$BASE/tiktok_author_v4.save.new" || exit 1
ipset save tiktok_observed_v4 > "$BASE/tiktok_observed_v4.save.new" || exit 1
mv "$BASE/tiktok_author_v4.save.new" "$BASE/tiktok_author_v4.save"
mv "$BASE/tiktok_observed_v4.save.new" "$BASE/tiktok_observed_v4.save"
log "Updated FreshTomato: author=$A observed=$O; five backups retained"
