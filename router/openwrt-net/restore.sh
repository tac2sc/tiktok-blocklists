#!/bin/sh
# TikTok Bridge Firewall, version 2.1
# Retains existing fw4 include semantics and CDN77 test rule.
BASE=/etc/tiktok-block
if nft list table bridge tiktok_block >/dev/null 2>&1; then
    RULES="$(nft list chain bridge tiktok_block forward 2>/dev/null)"
    for SET in cdn77_test4 observed4 author4; do
        nft list set bridge tiktok_block "$SET" >/dev/null 2>&1 || exit 1
        echo "$RULES" | grep -E "ip daddr @$SET .* drop " >/dev/null || exit 1
    done
    logger -t tiktok-block 'Existing DROP rules verified'
    exit 0
fi

[ -s "$BASE/table.nft" ] || { logger -t tiktok-block 'ERROR: missing saved table'; exit 1; }
nft -f "$BASE/table.nft" || { logger -t tiktok-block 'ERROR: base table restore failed'; exit 1; }
# Preserve last successful daily data on reboot (if any).
if [ -s "$BASE/sets-current.nft" ]; then
    nft -c -f "$BASE/sets-current.nft" && nft -f "$BASE/sets-current.nft" || {
        logger -t tiktok-block 'ERROR: saved set update failed; original table retained'
        exit 1
    }
fi
logger -t tiktok-block 'Bridge DROP rules restored'
exit 0
