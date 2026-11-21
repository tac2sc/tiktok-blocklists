#!/usr/bin/env python3
"""Compile a validated M4jx mirror and curated local additions. Stdlib-only."""
from __future__ import annotations

import argparse
import csv
import hashlib
import ipaddress
import json
import re
import sys
import urllib.request
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[1]
BASE_URL = 'https://raw.githubusercontent.com/M4jx/TikTokBlockList/main/'
UPSTREAM_NAMES = ('ipv4s', 'ipv6s', 'hosts', 'asns')
DOMAIN_RE = re.compile(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$', re.I)
ASN_RE = re.compile(r'^AS[1-9][0-9]{0,9}$')

class ValidationError(ValueError):
    pass


def content_lines(raw: str):
    for line_num, raw_line in enumerate(raw.splitlines(), 1):
        line = raw_line.strip()
        if line and not line.startswith('#'):
            yield line_num, line


def validate_ip_networks(raw: str, version: int, source: str, minimum: int = 0):
    networks = []
    for line_num, line in content_lines(raw):
        if '#' in line or len(line.split()) != 1:
            raise ValidationError(f'{source}:{line_num}: invalid IP entry {line!r}')
        try:
            net = ipaddress.ip_network(line, strict=False)
        except ValueError as ex:
            raise ValidationError(f'{source}:{line_num}: {ex}') from ex
        if net.version != version or not net.is_global:
            raise ValidationError(f'{source}:{line_num}: not a public IPv{version} address: {line}')
        if net.prefixlen < (16 if version == 4 else 32):
            raise ValidationError(f'{source}:{line_num}: dangerously broad prefix: {line}')
        networks.append(net)
    if len(networks) < minimum:
        raise ValidationError(f'{source}: only {len(networks)} entries, expected >= {minimum}')
    return networks


def validate_hosts(raw: str, source: str, minimum: int = 0):
    result = set()
    for line_num, line in content_lines(raw):
        parts = line.split()
        if len(parts) == 1:
            host = parts[0]
        elif len(parts) == 2 and parts[0] in ('0.0.0.0', '127.0.0.1', '::'):
            host = parts[1]
        else:
            raise ValidationError(f'{source}:{line_num}: unsupported hosts entry {line!r}')
        host = host.rstrip('.').lower()
        if len(host) > 253 or not DOMAIN_RE.fullmatch(host):
            raise ValidationError(f'{source}:{line_num}: invalid hostname {host!r}')
        result.add(host)
    if len(result) < minimum:
        raise ValidationError(f'{source}: only {len(result)} unique domains, expected >= {minimum}')
    return sorted(result)


def validate_asns(raw: str, source: str, minimum: int = 0):
    values = set()
    for n, s in content_lines(raw):
        if not ASN_RE.fullmatch(s):
            raise ValidationError(f'{source}:{n}: invalid ASN: {s!r}')
        values.add(s)
    if len(values) < minimum:
        raise ValidationError(f'{source}: only {len(values)} ASNs, expected >= {minimum}')
    return sorted(values, key=lambda v: int(v[2:]))


def collapse(networks: Iterable, version: int):
    unique = set(networks)
    if not unique:
        return []
    if any(item.version != version for item in unique):
        raise ValidationError('mixed address families')
    return sorted(ipaddress.collapse_addresses(unique), key=lambda n: (int(n.network_address), n.prefixlen))


def subtract(networks, excluded, version):
    current = collapse(networks, version)
    for ex in collapse(excluded, version):
        newer = []
        for net in current:
            if not net.overlaps(ex):
                newer.append(net)
            elif net.subnet_of(ex):
                continue
            elif ex.subnet_of(net):
                newer.extend(net.address_exclude(ex))
            else:
                raise ValidationError('overlapping network subtraction error')
        current = collapse(newer, version)
        if len(current) > 20000:
            raise ValidationError('too many fragments after exclusion')
    return current


def serialize_ip(networks):
    return ''.join(f'{net}\n' for net in networks)


def load_curated(path: Path):
    result = []
    with path.open(newline='', encoding='utf-8') as handle:
        reader = csv.DictReader(handle)
        required = {'address', 'enabled', 'confidence', 'evidence', 'notes'}
        if set(reader.fieldnames or ()) != required:
            raise ValidationError(f'{path}: CSV columns must be {sorted(required)}')
        for i, row in enumerate(reader, 2):
            if row['enabled'] not in ('true', 'false'):
                raise ValidationError(f'{path}:{i}: enabled must be true/false')
            if row['confidence'] not in ('sni-confirmed', 'traffic-observed', 'previously-deployed', 'candidate'):
                raise ValidationError(f'{path}:{i}: invalid confidence')
            nets = validate_ip_networks(row['address'], 4, f'{path}:{i}', minimum=1)
            if len(nets) != 1 or nets[0].prefixlen != 32:
                raise ValidationError(f'{path}:{i}: observed addresses must be exact IPv4s')
            if row['enabled'] == 'true':
                result.extend(nets)
    return result


def download(name: str):
    url = BASE_URL + name
    request = urllib.request.Request(url, headers={'User-Agent': 'tiktok-blocklists-sync/1.0', 'Accept': 'text/plain'})
    with urllib.request.urlopen(request, timeout=30) as response:
        data = response.read(2_000_001)
        if len(data) > 2_000_000:
            raise ValidationError(f'{name}: upstream exceeds 2 MB')
    try:
        return data.decode('utf-8-sig')
    except UnicodeDecodeError as e:
        raise ValidationError(f'{name}: invalid UTF-8') from e


def guard_change(new_count: int, prior_count: int, name: str):
    if prior_count and (new_count < prior_count * 0.75 or new_count > prior_count * 3):
        raise ValidationError(f'{name}: large size change {prior_count} -> {new_count}; manual review required')


def prior_counts(dist_dir: Path):
    path = dist_dir / 'manifest.json'
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding='utf-8'))
    return data.get('upstream_counts', {})


def compile_lists(upstream: dict[str, str], sources_dir: Path, previous_counts: dict):
    v4 = validate_ip_networks(upstream['ipv4s'], 4, 'M4jx/ipv4s', minimum=10)
    v6 = validate_ip_networks(upstream['ipv6s'], 6, 'M4jx/ipv6s', minimum=1)
    domains = validate_hosts(upstream['hosts'], 'M4jx/hosts', minimum=100)
    asns = validate_asns(upstream['asns'], 'M4jx/asns', minimum=1)
    counts = {'ipv4s': len(v4), 'ipv6s': len(v6), 'hosts': len(domains), 'asns': len(asns)}
    for name, count in counts.items():
        guard_change(count, previous_counts.get(name, 0), name)

    manual4 = validate_ip_networks((sources_dir / 'manual-ipv4.txt').read_text(encoding='utf-8'), 4, 'sources/manual-ipv4.txt')
    observed4 = load_curated(sources_dir / 'observed-ipv4.csv')
    exclude4 = validate_ip_networks((sources_dir / 'exclude-ipv4.txt').read_text(encoding='utf-8'), 4, 'sources/exclude-ipv4.txt')
    manual_hosts = validate_hosts((sources_dir / 'manual-domains.txt').read_text(encoding='utf-8'), 'sources/manual-domains.txt')

    author4 = subtract(v4, exclude4, 4)
    obs4 = subtract(observed4, exclude4, 4)
    local4 = subtract(manual4, exclude4, 4)
    combined4 = collapse(author4 + obs4 + local4, 4)
    if not combined4:
        raise ValidationError('empty combined IPv4 list')
    domains_all = sorted(set(domains + manual_hosts))
    return {
        'counts': counts,
        'author4': author4,
        'observed4': obs4,
        'manual4': local4,
        'all4': combined4,
        'ipv6': collapse(v6, 6),
        'domains': domains_all,
        'asns': asns,
    }


def render(upstream: dict[str, str], compiled: dict):
    dist = {}
    def put(name, text):
        dist[name] = text.encode('utf-8')
    put('author-ipv4.txt', serialize_ip(compiled['author4']))
    put('observed-ipv4.txt', serialize_ip(compiled['observed4']))
    put('manual-ipv4.txt', serialize_ip(compiled['manual4']))
    put('all-ipv4.txt', serialize_ip(compiled['all4']))
    put('ipv6.txt', serialize_ip(compiled['ipv6']))
    put('domains.txt', ''.join(d + '\n' for d in compiled['domains']))
    put('hosts.txt', ''.join('0.0.0.0 ' + d + '\n' for d in compiled['domains']))
    put('asns.txt', ''.join(a + '\n' for a in compiled['asns']))
    # Self-contained syntax for manually loading the sets into an empty FreshTomato ipset namespace.
    # ipset -exist restore is suitable for first provisioning, not for atomic updates.
    for name, setname, field in (
        ('freshtomato/author.ipset', 'tiktok_author_v4', 'author4'),
        ('freshtomato/observed.ipset', 'tiktok_observed_v4', 'observed4'),
        ('freshtomato/manual.ipset', 'tiktok_manual_v4', 'manual4'),
    ):
        lines = [f'create {setname} hash:net family inet']
        lines += [f'add {setname} {n}' for n in compiled[field]]
        put(name, '\n'.join(lines) + '\n')
    # A standalone nftables bridge table; no LAN interface hardcoding, does not run automatically.
    nft_elements = ',\n            '.join(str(n) for n in compiled['all4'])
    put('openwrt/tiktok-bridge.nft', (
        '# Review before applying. Standalone nftables bridge table, not a fw4 include.\n'
        'table bridge tiktok_blocklists {\n'
        '    set blocked_v4 {\n'
        '        type ipv4_addr;\n'
        '        flags interval;\n'
        '        auto-merge;\n'
        '        elements = {\n            ' + nft_elements + '\n        }\n'
        '    }\n'
        '    chain forward {\n'
        '        type filter hook forward priority -10; policy accept;\n'
        '        ether type ip ip daddr @blocked_v4 counter drop\n'
        '    }\n}\n'
    ))
    manifest = {
        'schema': 1,
        'source': 'https://github.com/M4jx/TikTokBlockList',
        'upstream_counts': compiled['counts'],
        'output_counts': {
            'author_ipv4_cidrs': len(compiled['author4']),
            'observed_ipv4_cidrs': len(compiled['observed4']),
            'manual_ipv4_cidrs': len(compiled['manual4']),
            'all_ipv4_cidrs': len(compiled['all4']),
            'ipv6_cidrs': len(compiled['ipv6']),
            'domains': len(compiled['domains']),
        },
        'sha256': {p: hashlib.sha256(body).hexdigest() for p, body in sorted(dist.items())},
        'upstream_sha256': {n: hashlib.sha256(upstream[n].encode('utf-8')).hexdigest() for n in UPSTREAM_NAMES},
    }
    put('manifest.json', json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    return dist


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--fixtures-dir', type=Path, help='Use local input fixtures (no network)')
    parser.add_argument('--output-dir', type=Path, default=ROOT / 'dist')
    parser.add_argument('--upstream-dir', type=Path, default=ROOT / 'upstream')
    parser.add_argument('--sources-dir', type=Path, default=ROOT / 'sources')
    args = parser.parse_args(argv)
    # Fetch and validate everything before any destination files are written.
    upstream = {n: (args.fixtures_dir / n).read_text(encoding='utf-8') if args.fixtures_dir else download(n) for n in UPSTREAM_NAMES}
    previous = prior_counts(args.output_dir)
    compiled = compile_lists(upstream, args.sources_dir, previous)
    outputs = render(upstream, compiled)
    # Commit-ready files are only written after validation passes.
    # A failed workflow never reaches git add/push.
    for name, payload in outputs.items():
        dest = args.output_dir / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(payload)
    for name, content in upstream.items():
        dest = args.upstream_dir / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(content, encoding='utf-8')
    print('Validated and generated:', compiled['counts'], 'outputs:', len(outputs))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValidationError, ValueError) as ex:
        print('SYNC FAILED:', ex, file=sys.stderr)
        sys.exit(1)
