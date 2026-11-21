# Daily TikTok blocklists deployment (version 1.1)

Devices:
- OpenWrt Net R7800: 10.0.0.1, nftables bridge tiktok_block. Daily at 07:30 router-local time.
- FreshTomato R8000: 192.168.2.1, ipset + iptables. Daily at 08:00 router-local time.
- GitHub Actions: 03:17 UTC daily; also on manual dispatch and relevant source/code pushes.

## Preconditions

1. On PC: `git pull --ff-only` from public `tac2sc/tiktok-blocklists`.
2. Copy **only** the following changed files from this package into the existing repo:
   `.github/workflows/sync.yml`, `sources/observed-ipv4.csv`, `tests/test_update.py`,
   `router/openwrt-net/*`, `router/freshtomato/*`, `DAILY-DEPLOY.md`.
3. Run `python -m unittest discover -s tests -v`, review `git diff`, commit and push.
4. Verify workflow published new `dist/observed-ipv4.txt` containing all 26 entries, and hashes in `dist/manifest.json`.

## OpenWrt Net (10.0.0.1)

Backup existing before replacing `restore.sh`:

```sh
cp -p /etc/tiktok-block/restore.sh /etc/tiktok-block/restore.sh.before-daily
cp -p /etc/crontabs/root /etc/tiktok-block/root.crontab.before-daily
```

Transfer these package files to router using SCP/SSH or download the published GitHub raw URLs:

- `router/openwrt-net/update.sh` -> `/etc/tiktok-block/update.sh`
- `router/openwrt-net/restore.sh` -> `/etc/tiktok-block/restore.sh`
- `router/openwrt-net/observed-local.txt` -> `/etc/tiktok-block/observed-local.txt`

On the router:

```sh
sh -n /etc/tiktok-block/update.sh
sh -n /etc/tiktok-block/restore.sh
chmod 700 /etc/tiktok-block/update.sh /etc/tiktok-block/restore.sh
nft -a list table bridge tiktok_block > /tmp/tiktok-before-daily.nft
/bin/sh /etc/tiktok-block/update.sh
nft -a list table bridge tiktok_block
if ! grep -Fq '/etc/tiktok-block/update.sh' /etc/crontabs/root; then
    printf '\n30 7 * * * /bin/sh /etc/tiktok-block/update.sh\n' >> /etc/crontabs/root
fi
/etc/init.d/cron reload
```

This never flushes the entire nftables table. It changes only `author4` and `observed4` sets using one atomic nft batch. The `cdn77_test4` set, bridge chain rules and counters are not changed. `sets-current.nft` is reapplied by the updated `restore.sh` after boot.

Rollback: remove the newly added cron line, reload cron, restore the previous `restore.sh` from `.before-daily`; if an older set version is required, test `/etc/tiktok-block/sets-previous.nft` with `nft -c -f` before applying with `nft -f`. This reverts only the two managed sets; the CDN77 rule remains.

## FreshTomato (192.168.2.1)

Existing `/jffs/tiktok-block/firewall.sh` remains unchanged. Transfer package files:
- `router/freshtomato/update.sh` -> `/jffs/tiktok-block/update.sh`
- `router/freshtomato/backup.sh` -> `/jffs/tiktok-block/backup.sh`

On FreshTomato:

```sh
sh -n /jffs/tiktok-block/update.sh
sh -n /jffs/tiktok-block/backup.sh
chmod 700 /jffs/tiktok-block/update.sh /jffs/tiktok-block/backup.sh
/bin/sh /jffs/tiktok-block/update.sh
ls -lh /jffs/tiktok-block/backups/
ipset list -n
```

`update.sh` verifies SHA-256 hashes from `dist/manifest.json`, validates IP entries, prepares scratch ipsets, creates a verified router configuration archive **before changing** the two existing ipsets, and swaps the sets atomically one at a time. It saves the active sets for current `firewall.sh`. Backups contain full NVRAM (`nvram save`), iptables, ipsets, firewall.sh and the three `.save` files. Each successful archive retains the most recent **five** only. Backups contain secrets, are mode 0600 and remain local in `/jffs/tiktok-block/backups/`. Never commit or publish them.

For boot-persistent scheduling, use FreshTomato **Administration > Scheduler > Custom 1**: enable daily schedule at 08:00, command `/bin/sh /jffs/tiktok-block/update.sh`. The native GUI stores the cron configuration persistently. Avoid replacing existing `jffs2_exec` (currently used for command history), `script_fire`, or other user scripts. As a session-only alternative, `cru a tiktok_daily '0 8 * * * /bin/sh /jffs/tiktok-block/update.sh'` does **not** guarantee persistence across boot.

To verify retention:

```sh
ls -lt /jffs/tiktok-block/backups/
```

The five archives are created with unique timestamps; if an update fails before backup creation, existing backups remain unchanged. On an update failure after backup creation, a backup still documents the previous configuration.

## Limitations

- GitHub Action runs daily at 03:17 UTC, not exactly at local daylight-saving-adjusted time.
- OpenWrt updates depend on GitHub and its HTTPS trust store; on failure, current nftables sets remain active.
- OpenWrt local list preserves ten previously deployed addresses pending upstream sync.
- FreshTomato's `ipset swap` applies each set atomically, but the two sets are switched sequentially.
- Full router configuration backup includes Wi-Fi keys and other credentials. Flash storage is not a substitute for off-device backups. Avoid using backup files across firmware versions or different hardware.
- Router scripts have been syntax-checked locally but not yet executed on the physical routers; perform the first controlled update and verify counters before relying on cron.
