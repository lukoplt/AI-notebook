import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tools.contracts.gen_release_fixtures import build, encoded, generate  # noqa: E402


class ReleaseFixtureTests(unittest.TestCase):
    def test_scenarios_and_real_inputs(self):
        f = build(ROOT)
        self.assertEqual('release-integration', f['contract'])
        self.assertEqual(1, f['version'])
        self.assertEqual([
            'upgrade-chat', 'restart-reconcile', 'cancel-resume',
            'delete-completed-scan', 'rules-restrict', 'empty-selection',
            'zero-evidence'], [x['name'] for x in f['cases']])
        self.assertEqual(6, len(f['assets']))
        self.assertEqual({'cs', 'sk', 'en', 'de'},
                         {x['language'] for x in f['assets'] if x['kind'] == 'invoice'})
        for a in f['assets']:
            raw = (ROOT / a['repoPath']).read_bytes()
            self.assertEqual(a['rawSha256'], hashlib.sha256(raw).hexdigest())
        cp = next(a for a in f['assets'] if a['kind'] == 'cp1250')
        raw = (ROOT / cp['repoPath']).read_bytes()
        with self.assertRaises(UnicodeDecodeError):
            raw.decode('utf-8', errors='strict')
        self.assertIn('Příliš žluťoučký kůň', raw.decode('cp1250'))

    def test_deterministic_and_rejects_stale_file(self):
        self.assertEqual(encoded(ROOT), encoded(ROOT))
        f = build(ROOT)
        self.assertEqual(hashlib.sha256(
            b'openai_compatible\nhttps://wp9.invalid/v1').hexdigest(),
            f['endpointCases'][0]['expected'])
        self.assertEqual([2, 1], f['cases'][0]['expected']['savedMarkers'])
        self.assertEqual(0, f['cases'][-1]['expected']['citations'])
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / 'fixture.json'
            out.write_bytes(encoded(ROOT))
            self.assertEqual(json.loads(out.read_bytes()), f)
            generate(ROOT, True, output=out)
            out.write_bytes(b'{}\n')
            with self.assertRaises(SystemExit):
                generate(ROOT, True, output=out)

    def test_committed_fixture_is_current(self):
        generate(ROOT, True)


if __name__ == '__main__':
    unittest.main()
