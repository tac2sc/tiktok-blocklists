#!/bin/sh
# FreshTomato configuration and TikTok firewall backup, version 1.1
# Retain five verified, root-only archives in /jffs/tiktok-block/backups.
set -eu
umask 077
BASE=/jffs/tiktok-block
DEST=$BASE/backups
[ -d "$BASE" ] || { echo 'ERROR: /jffs/tiktok-block not mounted'; exit 1; }
mkdir -p "$DEST"
chmod 700 "$DEST"
TMP="$(mktemp -d /tmp/tiktok-backup.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

nvram save "$TMP/router.cfg" || { echo 'ERROR: nvram backup failed'; exit 1; }
[ -s "$TMP/router.cfg" ] || { echo 'ERROR: empty NVRAM backup'; exit 1; }
iptables-save > "$TMP/iptables.rules" || exit 1
ipset save > "$TMP/ipsets.save" || exit 1
cp "$BASE/firewall.sh" "$TMP/firewall.sh" || exit 1
for NAME in tiktok_v4 tiktok_author_v4 tiktok_observed_v4; do
    [ -s "$BASE/$NAME.save" ] || { echo "ERROR: missing $NAME.save"; exit 1; }
    cp "$BASE/$NAME.save" "$TMP/$NAME.save" || exit 1
done
TS="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="$DEST/tiktok-fw-$TS-$$.tar.gz"
PARTIAL="$ARCHIVE.partial"
trap 'rm -f "$PARTIAL"; rm -rf "$TMP"' EXIT HUP INT TERM
# Archive holds NVRAM secrets; never upload to the public repository.
tar -czf "$PARTIAL" -C "$TMP" . || exit 1
tar -tzf "$PARTIAL" >/dev/null || { echo 'ERROR: invalid backup archive'; exit 1; }
[ -s "$PARTIAL" ] || exit 1
mv "$PARTIAL" "$ARCHIVE" || exit 1
chmod 600 "$ARCHIVE"

# Delete only backups created by this script, and only after a verified new archive.
COUNT=0
for FILE in $(ls -1t "$DEST"/tiktok-fw-*.tar.gz); do
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -gt 5 ]; then rm -f "$FILE"; fi
done
logger -t tiktok-backup "saved $(basename "$ARCHIVE"); rotated to last five"
echo "Backup created: $ARCHIVE"
