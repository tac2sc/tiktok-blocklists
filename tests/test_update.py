import ipaddress
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import update


class ValidationTests(unittest.TestCase):
    def test_rejects_private_and_default_routes(self):
        for value in ('10.0.0.0/8', '0.0.0.0/0', 'not-an-ip', '192.168.2.0/24'):
            with self.subTest(value=value), self.assertRaises(update.ValidationError):
                update.validate_ip_networks(value, 4, 'test')

    def test_collapse_parent_network(self):
        cidrs = update.validate_ip_networks('71.18.0.0/16\n71.18.251.0/24\n', 4, 'test')
        self.assertEqual([str(v) for v in update.collapse(cidrs, 4)], ['71.18.0.0/16'])

    def test_exclusion_subtract(self):
        base = [ipaddress.ip_network('71.18.0.0/16')]
        excl = [ipaddress.ip_network('71.18.251.0/24')]
        out = update.subtract(base, excl, 4)
        self.assertFalse(any(ipaddress.ip_address('71.18.251.7') in n for n in out))
        self.assertTrue(any(ipaddress.ip_address('71.18.248.7') in n for n in out))

    def test_rejects_bad_hosts(self):
        with self.assertRaises(update.ValidationError):
            update.validate_hosts('0.0.0.0 example.org malicious.org', 'bad')
        with self.assertRaises(update.ValidationError):
            update.validate_hosts('0.0.0.0 localhost', 'bad')

    def test_size_guard(self):
        with self.assertRaises(update.ValidationError):
            update.guard_change(10, 100, 'ipv4s')
        update.guard_change(90, 100, 'ipv4s')

    def test_curated_disabled(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'custom.csv'
            p.write_text('address,enabled,confidence,evidence,notes\n207.211.213.115,true,sni-confirmed,test,confirmed\n207.211.213.121,false,candidate,test,disabled\n')
            self.assertEqual(len(update.load_curated(p)), 1)

    def test_end_to_end_fixture(self):
        fixture_dir = ROOT / 'tests' / 'fixtures'
        raw = {name: (fixture_dir / name).read_text() for name in update.UPSTREAM_NAMES}
        compiled = update.compile_lists(raw, ROOT / 'sources', {})
        outputs = update.render(raw, compiled)
        self.assertEqual(compiled['counts']['hosts'], 101)
        self.assertTrue(len(compiled['all4']) > len(compiled['author4']))
        self.assertEqual(len(compiled['observed4']), 26)
        self.assertIn(b'ether type ip', outputs['openwrt/tiktok-bridge.nft'])
        self.assertIn(b'create tiktok_author_v4', outputs['freshtomato/author.ipset'])
        manifest = outputs['manifest.json'].decode()
        self.assertIn('sha256', manifest)
        self.assertEqual(outputs, update.render(raw, compiled))


if __name__ == '__main__':
    unittest.main()
