import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

from gen_retrieval_fixtures import make_contracts, rrf


class RetrievalFixturesTests(unittest.TestCase):
    def fixture(self, group):
        return make_contracts()[f'retrieval-{group}-v1.json']

    def cases(self, group):
        return {c['name']: c for c in self.fixture(group)['cases']}

    def test_integer_rrf(self):
        self.assertEqual([
            {"chunkId": 20, "rrfMicro": 32522},
            {"chunkId": 10, "rrfMicro": 16393},
            {"chunkId": 30, "rrfMicro": 16129}], rrf([20, 30], [10, 20]))

    def test_contracts(self):
        fs = make_contracts()
        self.assertEqual(6, len(fs))
        for filename, f in fs.items():
            self.assertEqual(filename.removesuffix('-v1.json'), f['contract'])
            self.assertEqual(1, f['version'])
            names = [c['name'] for c in f['cases']]
            self.assertTrue(names)
            self.assertEqual(len(names), len(set(names)))
        self.assertEqual(make_contracts(), fs)

    def test_rrf_deduplication_ties_and_full_union(self):
        cases = self.cases('rank')
        self.assertEqual([3, 9], [x['chunkId'] for x in cases['tie']['expected']])
        self.assertEqual([{'chunkId': 20, 'rrfMicro': 32786},
                          {'chunkId': 30, 'rrfMicro': 16129}],
                         cases['dedupe']['expected'])
        self.assertEqual([1, 3, 2, 4],
                         [x['chunkId'] for x in cases['full-pool']['expected']])
        self.assertEqual([], cases['empty']['expected'])
        self.assertEqual([{'chunkId': 7, 'rrfMicro': 500000}], rrf([7, 7], [], 1))

    def test_scope_seed_referential_integrity(self):
        seed = self.fixture('scope')['seed']
        sources = {s['id']: s for s in seed['sources']}
        revisions = {r['id']: r for r in seed['revisions']}
        chunks = {c['id']: c for c in seed['chunks']}
        self.assertEqual({101, 102, 201, 301, 401, 402, 501, 601, 701}, set(revisions))
        for source in sources.values():
            for key in ('currentRevision', 'publishedRevisionId'):
                if source[key] is not None:
                    self.assertEqual(source['id'], revisions[source[key]]['sourceId'])
        for revision in revisions.values():
            chunk = chunks[revision['id'] * 10]
            self.assertEqual(revision['id'], chunk['revisionId'])
            self.assertEqual(revision['sourceId'], chunk['sourceId'])
            self.assertEqual(revision['canonicalText'], chunk['text'])
            self.assertEqual(revision['id'] % 10, revision['revision'])
        self.assertEqual('error', sources[4]['status'])
        self.assertEqual((402, 401), (sources[4]['currentRevision'], sources[4]['publishedRevisionId']))
        self.assertIsNone(sources[6]['publishedRevisionId'])
        self.assertEqual(6, len(seed['manifest']))
        self.assertEqual(6, len(seed['embeddings']))
        for row in seed['manifest']:
            self.assertEqual(row['sourceId'], revisions[row['revisionId']]['sourceId'])
            self.assertEqual('done', row['state'])
            self.assertIn(row['generationId'], (90, 91))

    def test_scope_events_keep_pinned_revisions_and_only_revoke(self):
        cases = self.cases('scope')
        self.assertEqual(14, len(cases))
        for name, lexical, vector in (
                ('all', [1020, 4010], [1010, 4010]),
                ('folder10', [1020], [1010]),
                ('union-source4-folder10', [1020, 4010], [1010, 4010]),
                ('other-notebook', [5010], []),
                ('wrong-notebook-ids', [], []), ('unpublished', [], [])):
            self.assertEqual(lexical, cases[name]['publishedChunkIds'], name)
            self.assertEqual(vector, cases[name]['vectorChunkIds'], name)
        self.assertEqual({'kind': 'selection', 'sourceIds': [4], 'folderIds': [10]},
                         cases['union-source4-folder10']['scope'])
        self.assertEqual(0, cases['empty']['sqlCalls'])
        self.assertEqual(0, cases['empty']['embeddingCalls'])
        self.assertEqual([1020, 4010], cases['no-active']['publishedChunkIds'])
        self.assertEqual([], cases['no-active']['vectorChunkIds'])
        expected = {
            'revoke-availability': ([4010], [4010]),
            'revoke-eligible': ([4010], [4010]),
            'revoke-membership': ([], []),
            'join-membership': ([1020], [1010]),
            'publish-during-query': ([1020, 4010], [1010, 4010]),
            'switch-during-query': ([1020, 4010], [1010, 4010]),
        }
        for name, (lexical, vector) in expected.items():
            self.assertEqual(lexical, cases[name]['afterPublishedChunkIds'], name)
            self.assertEqual(vector, cases[name]['afterVectorChunkIds'], name)
            self.assertTrue(cases[name]['events'])

    def test_vector_boundaries_and_integer_scores(self):
        cases = self.cases('rank')
        for name, ids, scores in (
                ('mask-before-heap', [2, 3], [0, -1000000]),
                ('tie-id', [3], [1000000]),
                ('zero-legacy', [1, 2], [0, -1000000]),
                ('k0', [], []),
                ('k9', [1, 2, 3], [1000000, 0, -1000000]),
                ('normalized-dot', [1], [960000])):
            self.assertEqual(ids, cases[name]['expectedIds'], name)
            self.assertEqual(scores, cases[name]['expectedScoreMicros'], name)
        self.assertEqual(cases['tied-forward']['expectedIds'], cases['tied-reversed']['expectedIds'])
        self.assertEqual(3, cases['nonfinite']['invalidVectorCount'])
        self.assertEqual([0x7fc00000, 0], cases['nonfinite']['rows'][0]['float32Bits'])
        for name in ('query-empty', 'query-zero', 'query-wrong-dims', 'query-nonfinite'):
            self.assertEqual([], cases[name]['expectedIds'])
            self.assertEqual('invalidQueryVector', cases[name]['expectedStatus'])
        oversized = cases['oversized-generation']
        self.assertEqual(2097153, oversized['dims'])
        self.assertEqual('oversizedVector', oversized['expectedStatus'])
        self.assertEqual(0, oversized['expectedBlobReads'])
        self.assertEqual(0, oversized['expectedEmbeddingCalls'])

    def test_cache_oracle_accounts_for_leases_and_reservations(self):
        fixture = self.fixture('cache')
        self.assertEqual((160, 2, 2, 80), tuple(fixture[k] for k in
                         ('budgetBytes', 'dims', 'rowsPerMatrix', 'chargedBytesPerMatrix')))
        cases = self.cases('cache')
        self.assertEqual(7, len(cases))
        self.assertEqual(['A', 'C'], cases['lru']['actions'][-1]['expected']['residentKeys'])
        leased = cases['leased-eviction']['actions']
        invalidated = next(a for a in leased if a['op'] == 'invalidate')
        self.assertEqual({'residentBytes': 160, 'reservedBytes': 0, 'entryCount': 1,
                          'loadCount': 2, 'residentKeys': ['B']}, invalidated['expected'])
        streamed = next(a for a in leased if a.get('expectedMode') == 'stream')
        self.assertEqual(invalidated['expected'], streamed['expected'])
        for name, loads in (('epoch-race', 1), ('load-failure', 1), ('oversize', 0)):
            stats = cases[name]['actions'][-1]['expected']
            self.assertEqual((0, 0, 0, loads, []), tuple(stats[k] for k in
                ('residentBytes', 'reservedBytes', 'entryCount', 'loadCount', 'residentKeys')))
        single = cases['single-flight']['actions']
        self.assertEqual(2, sum(a['op'] == 'startAcquire' for a in single))
        completed = next(a for a in single if a['op'] == 'completeFill')['expected']
        self.assertEqual((80, 0, 1, 1), tuple(completed[k] for k in
                         ('residentBytes', 'reservedBytes', 'entryCount', 'loadCount')))
        isolated = cases['databases-isolated']['actions'][-1]['expected']
        self.assertEqual((160, 2, ['A', 'B']), tuple(isolated[k] for k in
                         ('residentBytes', 'entryCount', 'residentKeys')))
        self.assertNotEqual(fixture['keys']['A']['databaseId'], fixture['keys']['B']['databaseId'])
        for case in cases.values():
            for action in case['actions']:
                stats = action['expected']
                self.assertLessEqual(stats['residentBytes'] + stats['reservedBytes'], 160)
                self.assertEqual(len(stats['residentKeys']), stats['entryCount'])

    def test_cache_deferred_acquisitions_declare_eventual_result(self):
        for case in self.cases('cache').values():
            for action in case['actions']:
                if action['op'] != 'startAcquire':
                    continue
                self.assertEqual(80, action['expected']['reservedBytes'])
                if case['name'] == 'load-failure':
                    self.assertEqual('loadFailed', action['expectedError'])
                else:
                    self.assertEqual('stream' if case['name'] == 'epoch-race' else 'cached',
                                     action['expectedMode'])

    def test_evidence_uses_scalars_and_retains_revision_identity(self):
        fixture = self.fixture('evidence')
        self.assertEqual(20, len(fixture['canonicalText']))
        self.assertEqual('dle tail', fixture['canonicalText'][12:20])
        cases = self.cases('evidence')
        for c in cases.values():
            if 'row' not in c or 'expectedError' in c:
                continue
            r = c['row']
            canonical = r.get('canonicalText', fixture['canonicalText'])
            text = r['chunkText'] if r['start'] is None else canonical[r['start']:r['end']]
            self.assertEqual(text, c['expectedText'])
            self.assertEqual(text[:240], c['expectedSnippet'])
        self.assertEqual(241, len(cases['snippet']['expectedText']))
        self.assertEqual(240, len(cases['snippet']['expectedSnippet']))
        self.assertEqual([], cases['legacy']['expectedSpans'])
        old = cases['old-vector']
        self.assertEqual(101, old['reference']['revisionId'])
        self.assertEqual([(1020, 102), (1021, 102)],
                         [(r['chunkId'], r['revisionId']) for r in old['expectedNeighbours']])
        self.assertFalse(old['mayMerge'])
        self.assertEqual([1020, 1022], [r['chunkId'] for r in cases['published-neighbours']['expectedNeighbours']])
        self.assertEqual('invalidSpan', cases['invalid-span']['expectedError'])
        self.assertEqual('revisionMismatch', cases['wrong-revision']['expectedError'])
        self.assertEqual([], cases['revoked']['expectedPassages'])
        gc = cases['gc-pin']
        self.assertEqual({'chunkId': 1010, 'sourceId': 1, 'revisionId': 101, 'ord': 0}, gc['reference'])
        self.assertEqual((90, 101, 'needle revision 101'),
                         (gc['retireGenerationId'], gc['deletedRevisionId'], gc['expectedText']))

    def test_session_identity_matches_frozen_ingestion_identity(self):
        cases = self.cases('session')
        # User carry-over: WP5 and WP6 must share generation endpoint identity.
        # WP6 has already frozen SHA256(type + LF + normalized API root), no prefix.
        for case in cases.values():
            if 'expectedEndpointRevision' in case:
                payload = case['type'] + '\n' + case['normalizedRoot']
                self.assertEqual(hashlib.sha256(payload.encode('utf-8')).hexdigest(),
                                 case['expectedEndpointRevision'])
        ingestion = json.loads((Path(__file__).resolve().parents[2] / 'Tests/fixtures/contracts/ingestion-generations-v1.json').read_bytes())
        identities = []
        def collect(value):
            if isinstance(value, dict):
                if value.get('providerId') == 'local' and 'endpointRevision' in value:
                    identities.append(value['endpointRevision'])
                for child in value.values():
                    collect(child)
            elif isinstance(value, list):
                for child in value:
                    collect(child)
        collect(ingestion)
        self.assertIn(cases['root']['expectedEndpointRevision'], identities)
        rotation = cases['key-rotation']
        self.assertEqual(rotation['oldRoot'], rotation['newRoot'])
        self.assertNotEqual(rotation['oldKey'], rotation['newKey'])
        self.assertEqual('Bearer ' + rotation['oldKey'], rotation['expectedRequest']['authorization'])
        self.assertEqual(rotation['rawModel'], rotation['expectedRequest']['model'])
        self.assertEqual('qwen3:0.6b', cases['legacy']['rawModel'])
        self.assertEqual('m', cases['legacy-bare']['rawModel'])
        for name in ('legacy-bare-tag', 'legacy-bare-size-tag', 'legacy-unknown-prefix', 'legacy-empty-prefix'):
            # The whole stored key is the bare model of the selected provider.
            self.assertEqual(cases[name]['storedKey'], cases[name]['rawModel'])
            self.assertEqual('provider-a', cases[name]['selectedProviderId'])
            self.assertEqual('legacyEndpointUnverified', cases[name]['expectedStatus'])
            self.assertIsNone(cases[name]['expectedError'])
        self.assertEqual(36, cases['legacy-unresolved']['storedKey'].index(':'))
        for name, error in (('root-change', 'endpointRevisionMismatch'),
                            ('chat-only-anthropic', 'unsupportedEndpoint'),
                            ('chat-only-openwebui', 'unsupportedEndpoint'),
                            ('unknown-format', 'unsupportedQueryFormat'),
                            ('legacy-unresolved', 'legacyProviderUnresolved'),
                            ('legacy-unresolved-type', 'legacyProviderUnresolved')):
            self.assertEqual(error, cases[name]['expectedError'])
            self.assertEqual(0, cases[name]['requests'])
        for name in ('root', 'proxy', 'legacy', 'legacy-bare', 'legacy-bare-tag',
                     'legacy-bare-size-tag', 'legacy-unknown-prefix', 'legacy-empty-prefix'):
            self.assertIn(cases[name]['queryFormatVersion'], ('1', 'legacy'))
            self.assertEqual(cases[name]['inputs'], cases[name]['expectedInputs'])

    def test_perf_rows_hash_and_phase_boundaries(self):
        cases = self.cases('perf')
        small = cases['small']
        self.assertEqual(8, len(small['rows']))
        raw = b''
        for i, row in enumerate(small['rows']):
            self.assertEqual((i + 1, 1, i), (row['chunkId'], row['sourceId'], row['ord']))
            self.assertEqual(f'synthetic {i} needle{i % 97}', row['text'])
            self.assertEqual([int(j == (i + 17) % 4) for j in range(4)], row['vector'])
            raw += struct.pack('<4f', *row['vector'])
        self.assertEqual(hashlib.sha256(raw).hexdigest(), small['expectedVectorBytesSha256'])
        for name, count in (('large100k', 100000), ('large200k', 200000)):
            self.assertEqual((count, 256, 17), tuple(cases[name][k] for k in ('count', 'dims', 'seed')))
            self.assertNotIn('rows', cases[name])
        timing = cases['timing']
        self.assertEqual([100, 130, 180, 230], timing['clockTicks'])
        self.assertEqual((30, 50, 50), tuple(timing[k] for k in
                         ('queryEmbeddingMs', 'warmRetrievalMs', 'hydrationMs')))
        self.assertEqual({'concurrent-ingestion', 'streaming-budget', 'warm-cache'},
                         set(self.fixture('perf')['scenarios']))

    def test_cli_only_writes_owned_files_and_check_detects_byte_changes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            script = root / 'tools/contracts/gen_retrieval_fixtures.py'
            script.parent.mkdir(parents=True)
            shutil.copyfile(Path(__file__).with_name(script.name), script)
            out = root / 'Tests/fixtures/contracts'
            out.mkdir(parents=True)
            sentinel = out / 'unowned.json'
            sentinel.write_bytes(b'untouched\n')
            def run(*args):
                return subprocess.run([sys.executable, '-B', str(script), *args],
                                      capture_output=True, check=False)
            self.assertEqual(1, run('--check').returncode)
            self.assertEqual([sentinel], list(out.iterdir()))
            self.assertEqual(0, run().returncode)
            fs = make_contracts()
            self.assertEqual(set(fs) | {'unowned.json'}, {p.name for p in out.iterdir()})
            for name, fixture in fs.items():
                expected = (json.dumps(fixture, ensure_ascii=False, sort_keys=True,
                                       indent=2, allow_nan=False) + '\n').encode('utf-8')
                self.assertEqual(expected, (out / name).read_bytes())
            self.assertEqual(0, run('--check').returncode)
            victim = out / 'retrieval-evidence-v1.json'
            victim.write_bytes(victim.read_bytes().replace(b'\n', b'\r\n'))
            before = victim.read_bytes()
            self.assertEqual(1, run('--check').returncode)
            self.assertEqual(before, victim.read_bytes())
            self.assertEqual(b'untouched\n', sentinel.read_bytes())

    def test_contract_arithmetic_values_are_integers(self):
        def visit(value):
            self.assertNotIsInstance(value, float)
            if isinstance(value, dict):
                for child in value.values():
                    visit(child)
            elif isinstance(value, list):
                for child in value:
                    visit(child)
        visit(make_contracts())


if __name__ == '__main__':
    unittest.main()
