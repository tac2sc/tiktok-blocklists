# TikTok Blocklists for FreshTomato and OpenWrt

Version 1.0. Public-source synchronizer and locally curated TikTok IP lists.

> **State:** GitHub repository template. Once published, run the **Sync TikTok blocklists** workflow manually to populate `dist/` with validated current M4jx content. No router is changed by GitHub Actions.

## What it does

- Fetches the complete current [M4jx/TikTokBlockList](https://github.com/M4jx/TikTokBlockList) `ipv4s`, `ipv6s`, `hosts`, and `asns` from HTTPS.
- Maintains independently curated IPv4 addresses in `sources/observed-ipv4.csv`; explicit `enabled=true/false` with provenance and confidence.
- Maintains manual IPv4 prefixes in `sources/manual-ipv4.txt`, extra domains in `sources/manual-domains.txt`, and exclusions in `sources/exclude-ipv4.txt`.
- Validates public network prefixes, host syntax, source minimum sizes, and large count changes before publishing anything. No dependency on third-party Python packages.
- Collapses overlapping CIDRs without widening their union; subtracts explicitly excluded IPv4 subnets from all emitted IPv4 lists.
- Generates one common IPv4 distribution plus router-specific formats and a SHA-256 manifest.
- Publishes updates via GitHub Actions at **03:17 and 15:17 UTC**, and on manual dispatch and source/code changes. GitHub cron is best-effort and may be delayed.
- Commits generated changes only when content changes, preserving history as the last-known-good state.

## Structure

```text
.github/workflows/sync.yml          scheduled and manual sync
scripts/update.py                  fetch, validate, normalize, publish
sources/observed-ipv4.csv          reviewed and previously deployed PCAP IPs
sources/manual-ipv4.txt            manually reviewed ranges
sources/exclude-ipv4.txt           false-positive exclusions
sources/manual-domains.txt         manual DNS entries
tests/                             offline unit tests and synthetic fixtures
upstream/                          raw synchronized M4jx sources (generated)
dist/                              ready-to-consume lists (generated)
```

## Generated files

| File | Purpose |
|---|---|
| `dist/author-ipv4.txt` | M4jx IPv4 networks, collapsed and with exclusions applied |
| `dist/observed-ipv4.txt` | Enabled exact IPs from our captures, with exclusions applied |
| `dist/manual-ipv4.txt` | Manually reviewed networks |
| `dist/all-ipv4.txt` | Union of author, observed, manual, with redundant prefixes removed |
| `dist/ipv6.txt` | M4jx IPv6 networks (not automatically applied by either router) |
| `dist/domains.txt` | Plain DNS domains |
| `dist/hosts.txt` | `0.0.0.0 hostname` for Adblock/DNS clients |
| `dist/asns.txt` | Informational ASNs. **Never expands automatically to every prefix of an ASN.** |
| `dist/freshtomato/*.ipset` | Initial-provisioning `ipset restore` format, NOT an atomic update |
| `dist/openwrt/tiktok-bridge.nft` | Standalone `bridge` nftables table with a ready set and forwarding drop chain, **opt-in only** |
| `dist/manifest.json` | Counts and SHA-256 values, deterministic and without timestamps |

## PCAP address provenance and risk

Only three exact IP addresses have an individually confirmed TikTok TLS-SNI mapping in the supplied diagnostic history:

- `207.211.213.115`, SNI `v77e.tiktokcdn.com`.
- `79.133.108.62`, SNI `v58e.tiktokcdn.com`.
- `2.23.97.89`, SNI `search16-normal-c-alisg.tiktokv.com`.

Five other CDN77 addresses had significant TikTok-associated traffic. Eight more IPs were present in the previously deployed FreshTomato observed set but lacked individual verified SNI in the available record. **These are labelled accordingly in the CSV, not promoted to SNI-confirmed.** All 16 are enabled initially to reproduce the previously tested live set. To reduce collateral blocking, change `enabled` to `false` for an individual shared CDN IP and commit; Actions will regenerate only the approved entries.

`101.45.16.0/24` is a separately researched ByteDance-prefix entry in `sources/manual-ipv4.txt` and is not falsely attributed to M4jx.

**Caution:** M4jx itself includes Akamai and Google IPs; our observed list includes shared CDNs too. Blocking these addresses may interrupt non-TikTok websites. Individual network-based blocklists cannot guarantee complete TikTok filtering, particularly with alternate CDNs, CDN churn, DNS bypass, and hardware acceleration.

## Run / test

```sh
python3 -m unittest discover -s tests -v
python3 scripts/update.py                 # live HTTPS sync, needs internet
```

No `pip install` needed. For an offline smoke test, use a separate output directory so synthetic fixtures never become published blocklists:

```sh
python3 scripts/update.py --fixtures-dir tests/fixtures \
  --output-dir /tmp/tiktok-fixture-dist \
  --upstream-dir /tmp/tiktok-fixture-upstream
```

## Set up a public repository

1. Create a **public**, initially **empty** GitHub repository named `tiktok-blocklists` (no auto-generated README or license).
2. Unzip this project locally. Make it a Git repository and push the full tree (see `PUBLISH.md`).
3. Enable Actions in repository settings if necessary. Trigger **Actions > Sync TikTok blocklists > Run workflow**.
4. Check `dist/manifest.json`, generated files, and job logs before connecting routers.
5. In `Settings > Actions > General`, ensure workflow token can write repository contents if the workflow push is denied. Workflow declares `contents: write`, which is subject to repository/organization policies.

## Router strategy

- **FreshTomato R8000:** existing tested rules reference `tiktok_author_v4` and `tiktok_observed_v4`; **keep them**. Do not replace JFFS startup files with the generated initial provisioning files. Use `dist/author-ipv4.txt` and `dist/observed-ipv4.txt` as inputs to a separately reviewed staging + `ipset swap` update process. Preserve the working `/jffs/tiktok-block/*.save` snapshot as rollback.
- **Xiaomi OpenWrt:** for a bridge/AP, routed `inet` fw4 rules may not inspect Wi-Fi bridge forwarding. `dist/openwrt/tiktok-bridge.nft` is a complete optional `bridge` table but is **not installed** by this project. Review with `nft -c -f` before applying manually; avoid double enforcement if FreshTomato already blocks all egress. Do not blindly load it via `fw4` because it defines an independent table and chain.
- Both routers should **pull** validated static artifacts from the public repository. GitHub Actions does not hold SSH credentials and never connects to the LAN.

Once published replace `OWNER` with the actual GitHub username or organization:

```text
https://raw.githubusercontent.com/OWNER/tiktok-blocklists/main/dist/author-ipv4.txt
https://raw.githubusercontent.com/OWNER/tiktok-blocklists/main/dist/observed-ipv4.txt
https://raw.githubusercontent.com/OWNER/tiktok-blocklists/main/dist/all-ipv4.txt
https://raw.githubusercontent.com/OWNER/tiktok-blocklists/main/dist/hosts.txt
https://raw.githubusercontent.com/OWNER/tiktok-blocklists/main/dist/manifest.json
```

## Safety and update semantics

- Upstream failure, malformed input, empty content or suspicious volume change stops the workflow. Previously committed `dist/` remains untouched by GitHub Actions.
- A successful commit creates a normal Git revision; revert a bad change using Git history. Lists are not deleted or flushed on routers by these jobs.
- The upstream mirror is not a claim that the source is current. M4jx's IPv4/hosts files had a last-updated marker of April 25, 2026 when this project was prepared.
- SHA-256 manifests guard against accidental mismatch, but since artifacts and manifest are on the same public repository they **are not a digital signature or protection against repository compromise**. For robust router rollouts, pin all downloads to one Git commit and verify checksums before an atomic set swap.
- Routine GitHub Actions job updates only upstream snapshots and `dist`. It does not modify `sources/`.

## Attribution and license

Sync metadata and scripts: MIT (this repository's `LICENSE`). Source list data is derived from [M4jx/TikTokBlockList](https://github.com/M4jx/TikTokBlockList), also MIT-licensed, and remains attributed to its author. This project is independent and is not endorsed by M4jx.
