import json
from pathlib import Path
import subprocess
import sys
import unittest

from gen_partial_index_fixtures import OUTPUT, build, render, rrf

ROOT = Path(__file__).resolve().parents[2]


class PartialIndexFixtureTests(unittest.TestCase):
    def cases(self):
        return {c['name']: c for c in build()['cases']}

    def test_envelope_and_unique_names(self):
        fixture = build()
        self.assertEqual(('retrieval-partial', 1), (fixture['contract'], fixture['version']))
        names = [c['name'] for c in fixture['cases']]
        self.assertEqual(len(names), len(set(names)))
        for required in ('no-generation', 'building-partial', 'active-and-building',
                         'stale-revision-only', 'mismatched-selection'):
            self.assertIn(required, names)

    def test_committed_fixture_is_current(self):
        self.assertEqual(render(build()), (ROOT / OUTPUT).read_bytes())
        check = subprocess.run([sys.executable, '-B', str(ROOT / 'tools/contracts/gen_partial_index_fixtures.py'),
                                '--check'], capture_output=True, check=False)
        self.assertEqual(0, check.returncode, check.stdout)

    def test_building_generation_serves_only_done_published_revisions(self):
        e = self.cases()['building-partial']['expected']
        self.assertEqual((70, 'building', 'used'), (e['generationId'], e['generationState'], e['vectorStatus']))
        self.assertEqual({1: 11, 2: 21}, {r['sourceId']: r['revisionId'] for r in e['vectorRevisions']})
        # 301 (stale revision), 511 (pending source) and 611 (missing source) never surface.
        self.assertEqual([111, 211, 112, 212], e['vectorChunkIds'])
        # Not yet embedded sources stay reachable lexically.
        self.assertEqual([111, 311, 411, 512], e['lexicalChunkIds'])
        self.assertEqual(rrf(e['lexicalChunkIds'], e['vectorChunkIds']), e['fused'])

    def test_active_generation_hides_building_generation(self):
        cases = self.cases()
        self.assertEqual((60, [112, 111]), (cases['active-and-building']['expected']['generationId'],
                                            cases['active-and-building']['expected']['vectorChunkIds']))
        other = cases['active-other-model-and-building']['expected']
        self.assertEqual((None, 'noActiveGeneration', 0), (other['generationId'], other['vectorStatus'],
                                                           other['embedCalls']))

    def test_lexical_only_cases_keep_lexical_results(self):
        for name in ('no-generation', 'stale-revision-only', 'mismatched-selection', 'mismatched-endpoint',
                     'mismatched-dims', 'provider-unavailable'):
            e = self.cases()[name]['expected']
            self.assertEqual([], e['vectorChunkIds'], name)
            self.assertEqual(rrf(e['lexicalChunkIds'], []), e['fused'], name)
        self.assertEqual(71, self.cases()['newest-building']['expected']['generationId'])

    def test_integers_only(self):
        def visit(value):
            self.assertNotIsInstance(value, float)
            if isinstance(value, dict):
                for child in value.values():
                    visit(child)
            elif isinstance(value, list):
                for child in value:
                    visit(child)
        visit(json.loads(render(build())))


if __name__ == '__main__':
    unittest.main()
