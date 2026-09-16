import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('proxy', Path(__file__).parents[1] / 'proxy.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class ProxyTests(unittest.TestCase):
    probe = {'port': 38432, 'password': 'test-only'}

    def test_published_helper_digest_matches_source(self):
        root = Path(__file__).parents[1]
        self.assertIn('HELPER_SHA256=' + p.digest((root / 'proxy.py').read_bytes()),
                      (root / 'install.sh').read_text(encoding='utf-8'))

    def test_mihomo_preserves_rejections_and_only_changes_policy_tokens(self):
        original = {'mode': 'rule', 'rules': ['DOMAIN,DIRECT.example,REJECT',
                     'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve', 'MATCH,DIRECT'],
                    'listeners': [{'name': 'node', 'type': 'vless', 'uuid': 'keep-secret'}]}
        baseline = copy.deepcopy(original)
        out = p.transform(original, 'mihomo', 'hybrid', self.probe)
        self.assertEqual(original, baseline)
        self.assertEqual(out['rules'][0], baseline['rules'][0])
        self.assertEqual(out['rules'][1], f'IP-CIDR,10.0.0.0/8,{p.TAG},no-resolve')
        self.assertEqual(out['listeners'][0], baseline['listeners'][0])
        self.assertEqual(out['proxies'][0]['ip-version'], 'ipv6-prefer')
        self.assertEqual(out['listeners'][-1]['listen'], '127.0.0.1')
        self.assertTrue(out['listeners'][-1]['users'])

    def test_singbox_preserves_reject_and_inbounds(self):
        original = {'inbounds': [{'type': 'vless', 'tag': 'original'}],
                    'outbounds': [{'type': 'direct', 'tag': 'direct'}],
                    'route': {'rules': [{'domain': ['bad.example'], 'action': 'reject'}], 'final': 'direct'}}
        out = p.transform(original, 'sing-box', 'hybrid', self.probe)
        self.assertEqual(out['route'], original['route'])
        self.assertEqual(out['inbounds'][0], original['inbounds'][0])
        self.assertEqual(out['outbounds'][0]['domain_resolver']['strategy'], 'prefer_ipv6')
        self.assertEqual(out['outbounds'][0]['routing_mark'], p.MARK)

    def test_remote_chains_and_existing_marks_refused(self):
        for obj, engine in [({'proxies': [{'type': 'socks5'}]}, 'mihomo'),
                            ({'routing-mark': 33}, 'mihomo'),
                            ({'outbounds': [{'type': 'vless'}]}, 'sing-box'),
                            ({'outbounds': [{'type': 'direct', 'routing_mark': 1}]}, 'sing-box')]:
            with self.subTest(engine=engine, obj=obj), self.assertRaises(p.Error):
                p.transform(obj, engine, 'all', self.probe)

    def test_tun_refused(self):
        with self.assertRaises(p.Error):
            p.transform({'tun': {'enable': True}}, 'mihomo', 'all', self.probe)
        with self.assertRaises(p.Error):
            p.transform({'inbounds': [{'type': 'tun'}]}, 'sing-box', 'all', self.probe)

    def test_duplicate_yaml_and_json_keys_refused(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'config'
            for raw, engine in [(b'mode: rule\nmode: direct\n', 'mihomo'), (b'{"route":{},"route":{}}', 'sing-box')]:
                path.write_bytes(raw)
                with self.assertRaises(p.Error):
                    p.read_config(path, engine)

    def test_restore_exact_bytes_and_detect_outside_changes(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            config, dep, statefile = root / 'config', root / 'service', root / 'state'
            original = b'# preserve comments\nsecret: original\n'
            updated = b'secret: rewritten\n'
            (root / 'config.original').write_bytes(original)
            config.write_bytes(updated)
            dep.write_bytes(b'dependency')
            statefile.write_text('{}')
            state = {'backup': d, 'config': str(config), 'file_mode': 0o600,
                     'uid': None, 'gid': None, 'manager': 'openrc',
                     'before_hash': p.digest(original), 'after_hash': p.digest(updated),
                     'dependency': {'path': str(dep), 'existed': False, 'mode': 0o644,
                                    'before_hash': p.digest(b''), 'after_hash': p.digest(b'dependency')}}
            p.check_unchanged(state)
            config.write_bytes(b'user edit')
            with self.assertRaises(p.Error):
                p.check_unchanged(state)
            config.write_bytes(updated)
            calls = []
            with patch.object(p, 'STATE', statefile), patch.object(p, 'service', side_effect=lambda *a: calls.append('restart')), patch.object(p, 'command', side_effect=lambda *a: calls.append('remove-routes')):
                p.restore(state)
            self.assertEqual(config.read_bytes(), original)
            self.assertFalse(dep.exists())
            self.assertFalse(statefile.exists())
            self.assertEqual(calls, ['restart', 'remove-routes'])

    def test_failed_restore_keeps_fail_closed_rules_and_journal(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / 'config.original').write_bytes(b'{}')
            (root / 'config').write_bytes(b'new')
            journal = root / 'state'
            journal.write_text('{}')
            state = {'backup': d, 'config': str(root / 'config'), 'file_mode': 0o600,
                     'uid': None, 'gid': None, 'manager': 'openrc',
                     'dependency': {'path': str(root / 'dep'), 'existed': False}}
            with patch.object(p, 'STATE', journal), patch.object(p, 'service', side_effect=p.Error('restart fails')), patch.object(p, 'command') as command:
                with self.assertRaises(p.Error):
                    p.restore(state)
                command.assert_not_called()
                self.assertTrue(journal.exists())


if __name__ == '__main__':
    unittest.main()
