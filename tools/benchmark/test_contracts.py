"""WP7 Task 1 contract tests: run from the repository root with
python3 -B -m unittest tools.benchmark.test_contracts (standard library only)."""
import json
import unittest

from tools.contracts.gen_benchmark_fixtures import (
    CHAT_MODEL, FIXTURE_FAMILY, OUT, PROFILE_ORDER, RES, calibrate, estimate, fnv1a32, make_contracts,
    make_resources, payload_hash, percentile, render)


def by_name(fixture):
    return {c['name']: c for c in fixture['cases']}


class ContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.contracts = make_contracts()
        cls.resources = make_resources()

    def test_profile_matrix(self):
        f = self.contracts['embedding-profiles-v1.json']
        self.assertEqual(7, len(f['profiles']))
        self.assertEqual([256, 512, 1024], [p['dims'] for p in f['profiles']
                                            if p['model'] == 'qwen3-embedding:0.6b'])

    def test_calibration_rounding(self):
        self.assertEqual(6667, calibrate([(3, 2), (10, 3)]))
        self.assertEqual(190, percentile(list(range(1, 201)), 9500))
        self.assertEqual(100, percentile(list(range(1, 201)), 5000))
        self.assertEqual(4, estimate(3, 6667))
        with self.assertRaises(ValueError):
            calibrate([(0, 2)])

    def test_all_envelopes(self):
        for name, f in self.contracts.items():
            self.assertIsInstance(f['version'], int, name)
            self.assertIsInstance(f['contract'], str, name)
            names = [c['name'] for c in f['cases']]
            self.assertEqual(len(names), len(set(names)), name)
            self.assertTrue(all(isinstance(c.get('kind'), str) for c in f['cases']), name)

    def test_profile_rows_are_frozen(self):
        rows = {p['id']: p for p in self.contracts['embedding-profiles-v1.json']['profiles']}
        self.assertEqual(PROFILE_ORDER, ['nomic-v2-256', 'nomic-v2-768', 'qwen3-06b-256', 'qwen3-06b-512',
                                         'qwen3-06b-1024', 'bge-m3-1024', 'paraphrase-768'])
        self.assertEqual('search_query: ', rows['nomic-v2-256']['queryPrefix'])
        self.assertEqual('search_document: ', rows['nomic-v2-768']['documentPrefix'])
        self.assertTrue(rows['qwen3-06b-512']['queryPrefix'].endswith('\nQuery:'))
        self.assertEqual('', rows['qwen3-06b-512']['documentPrefix'])
        self.assertEqual((8192, False), (rows['bge-m3-1024']['maxInputTokens'], rows['bge-m3-1024']['matryoshka']))
        self.assertEqual('ollama-512', rows['paraphrase-768']['ceilingSource'])
        self.assertEqual('sentence-transformers/paraphrase-multilingual-mpnet-base-v2',
                         rows['paraphrase-768']['tokenizerId'])
        cases = by_name(self.contracts['embedding-profiles-v1.json'])
        self.assertEqual('wp7:nomic-v2-256:query:split1:scalarpool1:prefixl2:ctx512',
                         cases['nomic-v2-256-query-cs']['formatVersion'])
        self.assertEqual('search_document: Záruka platí.', cases['nomic-v2-256-document-sk']['expected'])
        self.assertEqual([600000, 800000], cases['nomic-project']['expectedMillionths'])
        self.assertEqual([447214, 894427], cases['pool']['expectedMillionths'])
        self.assertEqual('unknownProfile', cases['unknown-profile']['error'])
        self.assertEqual('profileIdentityMismatch', cases['wrong-dims']['error'])
        self.assertEqual(('ab', '😀cd'), (cases['bisect-astral']['left'], cases['bisect-astral']['right']))
        for name in ('project-zero', 'project-nan', 'project-wrong-length', 'pool-zero-sum'):
            self.assertEqual('invalidEmbedding', cases[name]['error'], name)
        self.assertEqual('NaN', cases['project-nan']['vector'][0])

    def test_strict_cases(self):
        cases = by_name(self.contracts['embedding-strict-v1.json'])
        split = cases['split']['expected']
        self.assertEqual([dict(start=0, end=2, tokens=4), dict(start=2, end=5, tokens=5)], split['parts'])
        self.assertEqual((9, 1, 3), (split['successfulTokens'], split['rejectedRequests'], split['requestCount']))
        snap = cases['telemetry-split']['snapshot']
        self.assertEqual(dict(serviceTokens=None, successfulTokens=9, requestCount=3, rejectedRequests=1,
                              splitParts=2, uncountedRequests=1, serviceTokenStatus='partial'), snap)
        self.assertEqual([928477, 371391], cases['three-leaf-unequal-depth']['expected']['vectorMillionths'])
        self.assertEqual('inputCannotFit', cases['prefix-exhausts']['expected']['error'])
        over = cases['telemetry-over-limit']['snapshot']
        self.assertEqual((16, 8, 'measured'), (over['serviceTokens'], over['successfulTokens'],
                                               over['serviceTokenStatus']))
        for name, error in (('unrelated-400', 'providerError'), ('http-500', 'providerError'),
                            ('cancel', 'cancelled'), ('no-count-no-tokenizer', 'tokenCountUnavailable'),
                            ('wrong-dim', 'invalidEmbedding'), ('nonfinite', 'invalidEmbedding'),
                            ('empty-input', 'emptyInput')):
            self.assertEqual(error, cases[name]['expected']['error'], name)
            self.assertLessEqual(cases[name]['expected']['requestCount'], 1, name)
        self.assertEqual([dict(text='q:abc', tokenizerId=FIXTURE_FAMILY)], cases['no-count']['expected']['counterCalls'])
        body = cases['wire-embed']['request']['body']
        self.assertEqual((False, ['q:abc'], 2, 'fixture'), (body['truncate'], body['input'], body['dimensions'],
                                                              body['model']))
        raw = cases['raw-calibration']['request']['body']
        self.assertEqual((True, False, 1), (raw['raw'], raw['stream'], raw['options']['num_predict']))
        self.assertNotIn('raw', cases['chat-full-prompt']['request']['body'])
        prep = cases['prepare-profile']['expected']
        self.assertEqual(32768, prep['effectiveLimit'])
        self.assertTrue(prep['identity']['queryFormatVersion'].endswith(':ctx32768'))
        self.assertEqual(['http://127.0.0.1:11434/api/tags', 'http://127.0.0.1:11434/api/show'],
                         [r['url'] for r in cases['prepare-profile-root-change']['expected']['requests']])
        self.assertEqual('modelMetadataUnavailable', cases['prepare-profile-no-context']['expected']['error'])
        self.assertEqual('embeddingModelUnavailable', cases['latest-alias-no-substring']['expected']['error'])
        self.assertIsNone(cases['latest-alias-exact']['expected']['error'])
        self.assertEqual('embeddingModelChanged', cases['resume-digest-changed']['expected']['error'])
        self.assertEqual('embeddingModelChanged', cases['publish-digest-changed']['expected']['error'])

    def test_token_estimate_cases(self):
        f = self.contracts['token-estimate-v2.json']
        self.assertEqual(('token-estimate', 2, 'pending', [], [], []),
                         (f['contract'], f['version'], f['status'], f['bindings'], f['rates'], f['provenance']))
        cases = by_name(f)
        self.assertEqual(6667, cases['ceil-rate']['expected'][0]['tokensPerScalarBp'])
        self.assertEqual(cases['training-multi']['expected'], cases['training-order']['expected'])
        self.assertEqual(4, cases['ceil-headroom']['expected'])
        self.assertEqual(0, cases['empty']['expected'])
        self.assertEqual(3, cases['astral']['scalars'])
        self.assertEqual(3, cases['rate5000-astral']['expected'])
        self.assertEqual(7, cases['unknown-family']['expected'])
        self.assertEqual(cases['unknown-language']['expected'], cases['und-runtime']['expected'])
        self.assertEqual(1, cases['holdout-under']['undercounts'])
        self.assertEqual('invalidCalibration', cases['invalid-zero-scalars']['error'])
        self.assertEqual('invalidCalibration', cases['fit-holdout-rejected']['error'])
        self.assertEqual(6667, cases['calibration-observations']['expected']['rates'][0]['tokensPerScalarBp'])
        self.assertEqual(['cs-a:0:3'], cases['calibration-observations']['expected']['trainingIds'])
        self.assertEqual('fixture-only', cases['binding-exact']['expected'])
        self.assertIsNone(cases['binding-missing-digest']['expected'])
        self.assertIsNone(cases['binding-changed-digest']['expected'])
        report = cases['calibration-complete']
        self.assertTrue(report['input']['calibrated'])
        self.assertTrue(report['expectedMarkdown'].endswith('\n'))
        incomplete = cases['calibration-incomplete-missing-count']['input']
        self.assertEqual(('incomplete', 'tokenCountUnavailable', None),
                         (incomplete['status'], incomplete['errorCode'], incomplete['bodyHoldoutUndercounts']))
        self.assertFalse(cases['calibration-holdout-undercount']['input']['calibrated'])
        plan = cases['sample-plan']['expected']
        self.assertEqual(['train', 'train', 'train', 'holdout'],
                         [next(s['split'] for s in plan if s['documentId'] == d) for d in ('cs-a', 'cs-b', 'cs-c',
                                                                                          'cs-d')])
        self.assertEqual('holdout', next(s['split'] for s in plan if s['documentId'] == 'query:q-mixed-gold'))
        self.assertFalse(any(s['documentId'] in ('query:q-scope', 'query:q-absent', 'query:q-overview')
                             for s in plan))
        self.assertFalse(any(s['documentId'] == 'de-b' for s in plan))

    def test_report_cases(self):
        cases = by_name(self.contracts['benchmark-report-v1.json'])
        for name in ('complete', 'missing-windows', 'bad-identity', 'unmeasured-counts', 'decision-pair',
                     'percentiles-200', 'threshold-equal', 'threshold-below', 'tokens-per-second',
                     'denominator-zero', 'markdown-title'):
            self.assertIn(name, cases)
        self.assertEqual(dict(p50=100, p95=190), cases['percentiles-200']['expected'])
        self.assertIs(False, cases['threshold-equal']['expected'])
        self.assertIs(True, cases['threshold-below']['expected'])
        self.assertEqual(60000, cases['tokens-per-second']['expected']['tokensPerSecondMilli'])
        self.assertIsNone(cases['denominator-zero']['expected']['tokensPerSecondMilli'])
        self.assertEqual('A\\|B<br>C\\\\D', cases['markdown-title']['expected'])
        self.assertIn('| cpu | A\\|B<br>C\\\\D |', cases['markdown-escape']['expectedMarkdown'])
        complete = cases['complete']
        self.assertEqual(complete['input'], complete['expectedJson'])
        self.assertTrue(complete['expectedMarkdown'].endswith('\n'))
        self.assertIn('not measured', cases['incomplete-honest']['expectedMarkdown'])
        pair = cases['decision-pair']
        for side in ('mac', 'windows'):
            self.assertEqual(PROFILE_ORDER, [c['profileId'] for c in pair[side]['candidates']])
            for c in pair[side]['candidates']:
                self.assertEqual(4, len(c['performance']))
                for row in c['performance']:
                    self.assertEqual((200, 100, 190), (len(row['samples']), row['warmP50Us'], row['warmP95Us']))
        self.assertEqual(pair['calibration']['payloadHash'], pair['mac']['calibrationHash'])
        self.assertEqual('missing_platform', cases['missing-windows']['error'])

    def test_run_cases(self):
        cases = by_name(self.contracts['benchmark-run-v1.json'])
        for name in ('phase-order', 'cancel-build', 'cancel-query', 'failed-generation', 'dual-revisions',
                     'zero-evidence', 'truncated-away-gold', 'empty-selection', 'overview', 'overlap-required',
                     'cache-streamed', 'cold-new-cache', 'citation-wrong-revision', 'citation-unknown-marker',
                     'citation-wrong-chunk', 'fnv-abc', 'tuning-zero-cap'):
            self.assertIn(name, cases)
        self.assertEqual(440920331, cases['fnv-abc']['expected'])
        self.assertEqual(440920331, fnv1a32('abc'))
        self.assertEqual(dict(fetchK=32, topK=16, evidenceShareBp=6000), cases['tuning-pending']['expected'])
        self.assertEqual(dict(fetchK=48, topK=24, evidenceShareBp=7000), cases['tuning-accepted']['expected'])
        for name in ('tuning-fetch-below-top', 'tuning-top-zero', 'tuning-share-above'):
            self.assertEqual('invalidTuning', cases[name]['error'])
        zero = cases['tuning-zero-cap']['expected']
        self.assertEqual(([], 0), (zero['citationMap'], zero['evidenceSections']))
        self.assertEqual(dict(runnerBytes=80, serverBytes=70, combinedBytes=90), cases['memory-peaks']['expected'])
        self.assertEqual(6000 * 1024, cases['process-parent-cycle']['expected']['serverTreeBytes'])
        self.assertEqual('invalidSamples', cases['process-overflow']['error'])
        self.assertEqual('processUnavailable', cases['process-missing-root']['error'])
        defaults = cases['cli-defaults']['expected']
        self.assertEqual((16, 32, [100000, 200000], 7), (defaults['topK'], defaults['fetchK'],
                                                          defaults['chunkCounts'], len(defaults['profileIds'])))
        self.assertEqual('invalidArguments', cases['cli-repeated']['error'])
        self.assertEqual((1, 2), (cases['round-half-us']['expected']['us'], cases['round-one-half-us']['expected']['us']))
        self.assertEqual(dict(completedWrites=2, overlapUs=170), cases['overlap-observed']['expected'])
        self.assertIsNone(cases['cache-streamed']['expected']['coldCacheLoadUs'])
        trace = cases['phase-order']['expected']['trace']
        self.assertEqual(['inspect', 'ingest', 'quality', 'cold', 'warmup', 'measure', 'concurrent', 'cold',
                          'warmup', 'measure', 'concurrent', 'verifyModels', 'report'],
                         [t['phase'] for t in trace if t['profileId'] == 'nomic-v2-256'])

    def test_default_cases(self):
        cases = by_name(self.contracts['embedding-default-v1.json'])
        self.assertEqual('nomic-v2-256', cases['fresh']['expected']['applyProfileId'])
        for name in ('database-only', 'settings-only', 'completed-onboarding', 'explicit-custom', 'explicit-old',
                     'converted-chat-only', 'pending-decision', 'second-launch'):
            self.assertIsNone(cases[name]['expected']['applyProfileId'], name)
        for name in ('cancel-rebuild', 'failed-rebuild', 'second-stage-fails', 'second-activation-invalid'):
            self.assertEqual(('old', 'old', False), (cases[name]['expectedActive'], cases[name]['expectedSelection'],
                                                      cases[name]['journalRetained']), name)
        self.assertEqual(('new', 'old', True), (cases['settings-write-fails']['expectedActive'],
                                                cases['settings-write-fails']['expectedSelection'],
                                                cases['settings-write-fails']['journalRetained']))
        fresh = cases['fresh-import']['expected']
        self.assertEqual(['search_document: Záruka platí.'], fresh['requests'])
        self.assertEqual((768, 256), (fresh['nativeDims'], fresh['dims']))
        self.assertTrue(fresh['queryFormatVersion'].endswith('ctx512') and fresh['docFormatVersion'].endswith('ctx512'))
        self.assertEqual([], cases['restart-no-work']['expected']['requests'])
        self.assertIsNone(cases['legacy-no-profile']['expected']['result'])

    def test_session_cases(self):
        cases = by_name(self.contracts['token-calibration-session-v1.json'])
        self.assertEqual((True, 3, 1), (cases['matching-digest']['calibrated'], cases['matching-digest']['expectedTokens'],
                                        cases['matching-digest']['identityCalls']))
        for name in ('different-digest', 'missing-digest', 'duplicate-model', 'unknown-model', 'remote-provider',
                     'metadata-failure'):
            self.assertEqual((False, 7), (cases[name]['calibrated'], cases[name]['expectedTokens']), name)
        self.assertEqual(0, cases['remote-provider']['identityCalls'])
        self.assertIn('nextModels', cases['changed-before-send'])
        inj = cases['coordinator-injects']
        self.assertEqual((9, 3, 4500, 11, 2), (inj['fetchK'], inj['topK'], inj['evidenceShareBp'],
                                               inj['expectedQuestionTokens'], inj['expectedEstimatorVersion']))
        self.assertEqual(2, inj['expectedPrepared']['estimatorVersion'])
        self.assertEqual(15, cases['explicit-tuning']['expectedQuestionTokens'])
        for c in cases.values():
            for m in c.get('models', []):
                self.assertTrue(set(m) >= {'name', 'modified_at', 'size', 'digest', 'details'})

    def test_resources_are_truthful_projection(self):
        self.assertEqual({'embedding-profiles-v1.json', 'token-estimate-v2.json', 'embedding-decision-v1.json'},
                         set(self.resources))
        for name, resource in self.resources.items():
            text = json.dumps(resource, ensure_ascii=False)
            self.assertNotIn('cases', resource, name)
            self.assertNotIn(FIXTURE_FAMILY, text, name)
        self.assertEqual(dict(contract='embedding-decision', version=1, status='pending', profileId=None,
                              parameters=dict(fetchK=32, topK=16, evidenceShareBp=6000)),
                         self.resources['embedding-decision-v1.json'])
        est = self.resources['token-estimate-v2.json']
        self.assertEqual(payload_hash([], [], []), est['payloadHash'])
        self.assertEqual(('pending', [], [], []), (est['status'], est['bindings'], est['rates'], est['provenance']))
        fixture = self.contracts['token-estimate-v2.json']
        self.assertEqual(est['payloadHash'], fixture['payloadHash'])
        self.assertEqual(self.contracts['embedding-profiles-v1.json']['profiles'],
                         self.resources['embedding-profiles-v1.json']['profiles'])

    def test_committed_bytes_match_generator(self):
        for name, value in self.contracts.items():
            self.assertEqual(render(value), (OUT / name).read_bytes(), name)
        for name, value in self.resources.items():
            self.assertEqual(render(value), (RES / name).read_bytes(), name)

    def test_no_measured_claims_in_fixtures(self):
        self.assertEqual('llama3.2:3b', CHAT_MODEL)
        pair = by_name(self.contracts['benchmark-report-v1.json'])['decision-pair']
        self.assertEqual('fixture', pair['mac']['mode'])
        self.assertIn('fixture', pair['mac']['environment']['cpu'])


if __name__ == '__main__':
    unittest.main()
