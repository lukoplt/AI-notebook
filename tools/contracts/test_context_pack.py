"""Independent arithmetic and behavioral witnesses for the WP8 oracle."""
import copy
import unittest

import gen_fixtures as g


class ContextPackReferenceTests(unittest.TestCase):
    def test_zero_evidence_is_not_a_zero_length_citation(self):
        out = g.context_pack(g.context_pack_input("zero-cap"))
        self.assertEqual([], out["citationMap"])
        self.assertEqual(0, out["coverage"]["turn"]["passages"])

    def test_actual_prefix_cost_and_following_passage(self):
        # WP0's normative budget interface uses relative endScalar, not PackPrefix.end.
        out = g.budget(dict(runtimeContext=200, maxOutputTokens=20,
            mandatoryTokens=80, evidenceBudgetCap=60, topK=3,
            passages=[dict(id=1, tokens=90,
                truncationCandidates=[dict(endScalar=12, tokens=35), dict(endScalar=25, tokens=65)]),
                dict(id=2, tokens=20), dict(id=3, tokens=70)],
            mapTokensDesired=0, noteWebTokensDesired=0,
            historyTurnTokensNewestFirst=[]))
        self.assertEqual([1, 2], out["includedPassageIds"])
        self.assertEqual(55, out["evidenceTokens"])
        self.assertEqual(45, out["unusedTokens"])

    def test_span_union_is_scalar_exact(self):
        parts = [dict(start=0, end=4, text="A😀. "),
                 dict(start=2, end=7, text=". Bč!")]
        self.assertEqual((0, 7, "A😀. Bč!"), g.merge_scalar_parts(parts))

    def test_older_vector_hit_does_not_block_published_revision_neighbour(self):
        inp = g.context_pack_input("basic-cs")
        older = dict(inp["candidates"][0], revisionId=10, text="A", end=1)
        published = dict(older, chunkId=102, revisionId=11, text="B", rrfMicro=29000)
        neighbour = dict(published, chunkId=103, ordinal=1, start=1, end=2, text="C")
        inp.update(candidates=[older, published], neighbours=[neighbour])

        out = g.context_pack(inp)
        self.assertEqual([(10, "A", [101]), (11, "BC", [102, 103])],
                         [(c["revisionId"], c["text"], c["chunkIds"]) for c in out["citationMap"]])
        self.assertIn(dict(kind="neighbour", id="103"), out["included"])
        self.assertFalse(any(o["kind"] == "neighbour" and o["id"] == "103" for o in out["omitted"]))
        self.assertEqual([dict(sourceId=10, revisionId=10), dict(sourceId=10, revisionId=11)],
                         [pair for pair in out["sourceRevisions"] if pair["sourceId"] == 10])

    def test_permuted_overview_is_identical(self):
        inp = g.context_pack_input("overview-folders")
        permuted = copy.deepcopy(inp)
        permuted["overviewCandidates"].reverse()
        permuted["folderMap"].reverse()
        self.assertEqual(g.context_pack(inp), g.context_pack(permuted))

    def test_all_cases_have_unique_names(self):
        cases = g.gen_context_pack()["cases"]
        self.assertEqual(len(cases), len({c["name"] for c in cases}))
        self.assertEqual({"build", "estimate", "merge", "preview", "original", "coordinator", "descriptor"},
                         {c["kind"] for c in cases})


class ContextLifecycleReferenceTests(unittest.TestCase):
    def test_preview_fixture_literal_eviction_and_scope_results(self):
        cases = {c["name"]: c for c in g._context_preview_cases()}
        self.assertEqual([2, 3, 4, 5, 6], cases["preview-five-turns"]["expected"]["states"][-1]["retainedIds"])
        for name in ("preview-byte-eviction", "preview-global-session-cap", "preview-draft-global-cap"):
            last = cases[name]["expected"]["states"][-1]
            self.assertEqual([2, 3], last["retainedIds"], name)
            self.assertEqual(25_165_824, last["retainedBytes"], name)
        last = cases["preview-turn-limit-per-session"]["expected"]["states"][-1]
        self.assertEqual([2, 3, 4, 5, 6, 8, 9, 10, 11, 12], last["retainedIds"])
        self.assertEqual(22, cases["preview-utf8"]["expected"]["states"][-1]["retainedBytes"])
        self.assertEqual([2, 1, 3], cases["preview-replace"]["expected"]["states"][-1]["retainedIds"])
        for case in cases.values():
            self.assertEqual(len(case["input"]["operations"]), len(case["expected"]["states"]))
            for state in case["expected"]["states"]:
                self.assertLessEqual(state["retainedBytes"], 33_554_432)
                self.assertEqual(sum(e["bytes"] for e in state["retained"]) + state["draftBytes"],
                                 state["retainedBytes"])

    def test_every_intent_mutation_invalidates_but_display_language_does_not(self):
        cases = {c["name"]: c for c in g._context_preview_cases()}
        states = cases["preview-invalidate-each-field"]["expected"]["states"]
        for i in range(0, len(states), 3):
            self.assertTrue(states[i + 1]["result"])
            self.assertTrue(states[i + 1]["draftReady"])
            self.assertFalse(states[i + 2]["result"])
            self.assertFalse(states[i + 2]["draftReady"])
            self.assertEqual(0, states[i + 2]["retainedBytes"])
        state = cases["preview-display-language-not-in-key"]["expected"]["states"][-1]
        self.assertTrue(state["result"])
        self.assertEqual(1, state["generation"])
        self.assertEqual(5, state["retainedBytes"])
        self.assertEqual(g._context_intent_key({"scope": {"kind": "selection", "sourceIds": [3, 1], "folderIds": [9, 2]}}),
                         g._context_intent_key({"scope": {"kind": "selection", "sourceIds": [1, 3], "folderIds": [2, 9]}}))

    def test_preview_rejects_invalid_limits_and_key_width(self):
        for limits in ({"maxTurns": 0}, {"maxBytes": -1}):
            with self.assertRaisesRegex(ValueError, "invalidInput"):
                g.context_preview(dict(limits, operations=[]))
        with self.assertRaisesRegex(ValueError, "invalidInput"):
            g.context_preview({"operations": [{"kind": "beginDraft", "sessionId": 1, "key": "short"}]})

    def test_canonical_writer_literal_utf8_byte_count(self):
        value = {"𐀀": "x", "é": "😀", "a": "\n/", "\ue000": "y"}
        expected = '{"a":"\\n/","é":"😀","\ue000":"y","𐀀":"x"}'
        self.assertEqual(expected, g.context_canonical_json(value))
        self.assertEqual(44, len(g.context_canonical_json(value).encode("utf-8")))

    def test_original_fixture_decisions_are_literal(self):
        self.assertEqual({
            "original-contained": "available", "original-prefix-sibling": "unsafe",
            "original-dotdot": "unsafe", "original-absolute": "unsafe",
            "original-symlink-escape": "unsafe", "original-missing": "unavailable",
            "original-changed": "changed", "original-deleted-source": "unavailable",
            "original-case-sensitive": "unsafe", "original-case-insensitive": "available"},
            {c["name"]: c["expected"] for c in g._context_original_cases()})

    def test_coordinator_scripts_literal_writes_and_control_flow(self):
        from unittest.mock import patch
        seed = dict(question="Q", mode="answer", fetchK=32, history=[], candidates=[],
            neighbours=[], overviewCandidates=[], folderMap=[], coverage={},
            scope={"kind": "all", "sourceIds": [], "folderIds": []},
            model={"providerType": "ollama", "model": "test", "runtimeContext": 8192, "maxOutputTokens": 1024})
        request = {"messages": [], "citationMap": [{"marker": 1, "text": "one"}, {"marker": 2, "text": "two"}]}
        def build(inp):
            return {"error": "contextTooSmall"} if inp["model"]["runtimeContext"] == 128 else request
        with patch.object(g, "context_pack_input", return_value=seed, create=True), \
                patch.object(g, "context_pack", side_effect=build, create=True):
            cases = {c["name"]: c for c in g._context_coordinator_cases()}
        self.assertEqual(12, len(cases))
        prepared = cases["prepare-has-no-writes"]["expected"]
        self.assertEqual(["freeze", "pin", "search", "hydrate", "neighbours", "build", "finish"],
                         [c["op"] for c in prepared["calls"]])
        self.assertEqual([], prepared["writes"])
        self.assertEqual([], prepared["rows"])
        for name in ("overview-no-query-embedding", "empty-selection-no-retrieval"):
            self.assertNotIn("search", [c["op"] for c in cases[name]["expected"]["calls"]])
        failed = cases["failed-prepare-no-user-row"]["expected"]
        self.assertEqual(["contextTooSmall", "noPreparedRequest"], failed["errors"])
        self.assertEqual([], failed["writes"])
        self.assertEqual([], failed["streamedRequests"])
        cancelled = cases["cancel-no-assistant"]["expected"]
        self.assertEqual(["user"], [r["role"] for r in cancelled["rows"]])
        self.assertEqual(["cancelled"], cancelled["errors"])
        self.assertEqual([], cancelled["retainedPreviews"])
        reused = cases["send-reuses-snapshot"]["expected"]
        self.assertEqual(["stalePreparedRequest", "preparedRequestConsumed"], reused["errors"])
        self.assertEqual([reused["preparedBytes"]], reused["streamedRequests"])
        self.assertEqual([2, 1], reused["parsedMarkers"])
        history = cases["history-excludes-current"]["expected"]["preparedHistory"]
        self.assertEqual([dict(id=1, user="Original question", assistant="Original answer")], history)
        regenerated = cases["regenerate-preserves-user"]["expected"]
        self.assertEqual(["deleteAssistant", "insertAssistant"], [w["op"] for w in regenerated["writes"]])
        self.assertEqual("Original question", regenerated["rows"][0]["content"])
        edited = cases["edit-success-updates-user-once"]["expected"]
        self.assertEqual(["updateUser", "deleteAssistant", "insertAssistant"], [w["op"] for w in edited["writes"]])
        self.assertEqual("Edited question", edited["rows"][0]["content"])
        failed_edit = cases["edit-failure-keeps-old-pair"]
        self.assertEqual(failed_edit["input"]["rows"], failed_edit["expected"]["rows"])
        self.assertEqual([], failed_edit["expected"]["writes"])

    def test_coordinator_real_builder_uses_packed_markers_after_skip_and_merge(self):
        import json
        cases = {c["name"]: c for c in g._context_coordinator_cases()}
        packed = cases["citation-packed-marker"]["expected"]
        prepared = json.loads(packed["preparedBytes"])
        self.assertTrue(any(o["kind"] == "passage" and o["id"] == "999" for o in prepared["omitted"]))
        self.assertEqual([(1, 101, [101, 102]), (2, 201, [201])],
                         [(c["marker"], c["chunkId"], c["chunkIds"]) for c in prepared["citationMap"]])
        self.assertEqual([(2, 201), (1, 101)],
                         [(c["marker"], c["chunkId"]) for c in packed["rows"][-1]["citations"]])
        retry = cases["retry-same-request"]["expected"]
        self.assertEqual([retry["preparedBytes"], retry["preparedBytes"]], retry["streamedRequests"])
        for name in ("regenerate-preserves-user", "edit-success-updates-user-once"):
            self.assertEqual([1, 3], [r["id"] for r in cases[name]["expected"]["rows"]])

    def test_preview_utf8_fifo_and_rejected_oversize_preserve_entries(self):
        result = g.context_preview({"maxTurns": 2, "maxBytes": 6, "operations": [
            {"kind": "retain", "sessionId": 1, "assistantId": 1, "payload": {"text": "á", "repeat": 1}},
            {"kind": "retain", "sessionId": 1, "assistantId": 2, "payload": {"text": "bb", "repeat": 1}},
            {"kind": "sent", "sessionId": 1, "assistantId": 1},
            {"kind": "retain", "sessionId": 1, "assistantId": 3, "payload": {"text": "cc", "repeat": 1}},
            {"kind": "retain", "sessionId": 1, "assistantId": 4, "payload": {"text": "x", "repeat": 7}}]})
        self.assertEqual([2, 3], result["states"][-1]["retainedIds"])
        self.assertEqual(4, result["states"][-1]["retainedBytes"])
        self.assertFalse(result["states"][-1]["result"])

    def test_preview_stale_generation_and_shared_draft_cap(self):
        result = g.context_preview({"maxBytes": 6, "operations": [
            {"kind": "retain", "sessionId": 1, "assistantId": 1, "payload": {"text": "aa", "repeat": 1}},
            {"kind": "beginDraft", "sessionId": 1, "key": "a" * 64},
            {"kind": "beginDraft", "sessionId": 2, "key": "b" * 64},
            {"kind": "completeDraft", "generation": 1, "key": "a" * 64, "payload": {"text": "old", "repeat": 1}},
            {"kind": "completeDraft", "generation": 2, "key": "b" * 64, "payload": {"text": "😀", "repeat": 1}},
            {"kind": "retain", "sessionId": 3, "assistantId": 2, "payload": {"text": "bb", "repeat": 1}}]})
        self.assertFalse(result["states"][3]["result"])
        self.assertTrue(result["states"][4]["result"])
        self.assertEqual([2], result["states"][-1]["retainedIds"])
        self.assertEqual(6, result["states"][-1]["retainedBytes"])
        self.assertEqual(2, result["states"][-1]["generation"])

    def test_original_component_identity_is_not_a_string_prefix(self):
        inp = dict(relativePath="a.txt", rootComponents=["root"],
            resolvedComponents=["root-other", "a.txt"], caseSensitive=True,
            exists=True, isRegularFile=True, sourceExists=True,
            currentRevisionId=11, citedRevisionId=10)
        self.assertEqual("unsafe", g.context_original(inp))
        inp["resolvedComponents"] = ["root", "a.txt"]
        self.assertEqual("changed", g.context_original(inp))
        inp["sourceExists"] = False
        self.assertEqual("unavailable", g.context_original(inp))

    def test_coordinator_retry_uses_frozen_request_and_one_user_write(self):
        from unittest.mock import patch
        seed = dict(question="Q", mode="answer", fetchK=32, history=[], candidates=[],
            neighbours=[], overviewCandidates=[], folderMap=[],
            scope={"kind": "all", "sourceIds": [], "folderIds": []},
            model={"providerType": "ollama", "model": "test"})
        request = {"messages": [], "citationMap": [{"marker": 1, "text": "one"},
                                                    {"marker": 2, "text": "two"}]}
        with patch.object(g, "context_pack", return_value=request, create=True):
            result = g.context_coordinator({"packInput": seed, "events": [
                {"kind": "prepare"},
                {"kind": "mutateInput", "field": "question", "value": "changed"},
                {"kind": "send", "attempts": [{"outcome": "retry", "tokens": []},
                    {"outcome": "success", "tokens": ["[2]", "[1]", "[2]", "[99]"]}]}]})
        self.assertEqual(2, len(result["streamedRequests"]))
        self.assertEqual(result["preparedBytes"], result["streamedRequests"][0])
        self.assertEqual(result["streamedRequests"][0], result["streamedRequests"][1])
        self.assertEqual([2, 1], result["parsedMarkers"])
        self.assertEqual(["insertUser", "insertAssistant"], [x["op"] for x in result["writes"]])
        self.assertEqual("Q", result["rows"][0]["content"])


class ContextPackCaseFactoryTests(unittest.TestCase):
    def test_seed_is_literal_and_independently_copied(self):
        first = g.context_pack_input("basic-cs")
        second = g.context_pack_input("basic-cs")
        self.assertEqual("Co říká zpráva?", first["question"])
        self.assertEqual([101, 201, 301], [p["chunkId"] for p in first["candidates"]])
        self.assertEqual([11, 21, 31], [p["revisionId"] for p in first["candidates"]])
        self.assertEqual("První věta. Druhá věta.", first["candidates"][0]["text"])
        first["candidates"][0]["text"] = "mutated"
        self.assertEqual("První věta. Druhá věta.", second["candidates"][0]["text"])

    def test_overlap_build_has_exact_two_chunk_scalar_witness(self):
        inp = g.context_pack_input("merge-overlap")
        self.assertEqual([(101, 0, 4, "A😀. "), (102, 2, 7, ". Bč!")],
                         [(p["chunkId"], p["start"], p["end"], p["text"])
                          for p in inp["candidates"]])
        self.assertEqual([], inp["neighbours"])
        out = g.context_pack(inp)
        self.assertEqual(1, len(out["citationMap"]))
        self.assertEqual("A😀. Bč!", out["citationMap"][0]["text"])
        self.assertEqual([101, 102], out["citationMap"][0]["chunkIds"])

    def test_case_matrix_and_literal_kernel_expectations(self):
        builds = g.context_build_cases()
        self.assertEqual(52, len(builds))
        self.assertEqual(52, len({row["name"] for row in builds}))
        self.assertIn("neighbour-legacy", {row["name"] for row in builds})
        self.assertTrue({"neighbour-bridge", "duplicate-neighbour", "invalid-coverage"}
                        <= {row["name"] for row in builds})
        self.assertTrue(all(row["kind"] == "build" and "expectedWire" in row for row in builds))
        kernels = g.context_kernel_cases()
        self.assertEqual(8, sum(row["kind"] == "estimate" for row in kernels))
        self.assertEqual(5, sum(row["kind"] == "merge" for row in kernels))
        by_name = {row["name"]: row for row in kernels}
        self.assertEqual({"estimate-en": 6, "estimate-cs": 9, "estimate-sk": 7,
                          "estimate-de": 9, "estimate-und": 7, "estimate-mixed": 9,
                          "estimate-emoji-combining": 2, "estimate-empty": 0},
                         {row["name"]: row["expected"] for row in kernels if row["kind"] == "estimate"})
        for name in ("scalar-union", "scalar-contained", "scalar-adjacent"):
            self.assertEqual({"start": 0, "end": 7, "text": "A😀. Bč!"}, by_name[name]["expected"], name)
        self.assertEqual({"error": "disjoint"}, by_name["scalar-disjoint"]["expected"])
        self.assertEqual({"error": "inconsistent overlap"}, by_name["scalar-conflict"]["expected"])

    def test_published_neighbour_cases_preserve_both_revision_identities(self):
        for name, has_published_hit in (("neighbour-published-after-older-vector", True),
                                        ("neighbour-published-without-matching-hit", False)):
            with self.subTest(name=name):
                inp = g.context_pack_input(name)
                self.assertEqual({"10": 11}, inp["sourceRevisions"])
                self.assertEqual([10, 11] if has_published_hit else [10],
                                 [p["revisionId"] for p in inp["candidates"]])
                self.assertEqual([(103, 11, 1, 1, 2, "C")],
                                 [(p["chunkId"], p["revisionId"], p["ordinal"], p["start"], p["end"], p["text"])
                                  for p in inp["neighbours"]])
                out = g.context_pack(inp)
                self.assertEqual([(10, "A", [101]), (11, "BC", [102, 103])] if has_published_hit
                                 else [(10, "A", [101])],
                                 [(c["revisionId"], c["text"], c["chunkIds"]) for c in out["citationMap"]])
                self.assertEqual([dict(sourceId=10, revisionId=10), dict(sourceId=10, revisionId=11)],
                                 out["sourceRevisions"])
                self.assertEqual([dict(kind="neighbour", id="103")] if has_published_hit else [],
                                 [item for item in out["included"] if item["kind"] == "neighbour"])
                self.assertEqual([] if has_published_hit else
                                 [dict(kind="neighbour", id="103", reason="revisionMismatch")],
                                 [item for item in out["omitted"] if item["kind"] == "neighbour"])

    def test_truncation_case_really_continues_to_second_block(self):
        inp = g.context_pack_input("first-truncated-continues")
        out = g.context_pack(inp)
        self.assertEqual([101, 201], [c["chunkId"] for c in out["citationMap"]])
        self.assertEqual("První věta.", out["citationMap"][0]["text"])
        self.assertEqual("Poznámky.", out["citationMap"][1]["text"])
        self.assertLess(inp["evidenceBudgetCap"], g.context_evidence_tokens(inp["candidates"][0]))

    def test_required_case_behaviors_are_not_only_names(self):
        build = lambda name: g.context_pack(g.context_pack_input(name))
        history = [m for m in build("history-stop")["messages"]
                   if m["sections"][0]["kind"] == "history"]
        self.assertEqual(["new question", "new answer"], [m["sections"][0]["text"] for m in history])
        mixed = build("merge-mixed-language-cost-increases")
        self.assertEqual(2, len(mixed["citationMap"]))
        overview = build("overview-published-vs-scope")["coverage"]
        self.assertEqual(5, overview["corpus"]["filesInScope"])
        self.assertEqual(3, overview["turn"]["candidatesWithPublishedChunks"])
        self.assertEqual(2, overview["turn"]["filesIncluded"])
        for name in ("map-no-absolute-root", "map-windows-absolute", "map-traversal",
                     "invalid-spans", "invalid-fetchk"):
            self.assertEqual({"error": "invalidInput"}, build(name), name)

    def test_budget_and_neighbour_cases_have_the_advertised_witnesses(self):
        no_prefix = g.context_pack_input("first-no-prefix-fits")
        self.assertTrue(no_prefix["candidates"][0]["truncationCandidates"])
        self.assertTrue(all(p["tokens"] > no_prefix["evidenceBudgetCap"]
                            for p in no_prefix["candidates"][0]["truncationCandidates"]))
        build = lambda name: g.context_pack(g.context_pack_input(name))
        self.assertEqual([101, 301], [c["chunkId"] for c in build("later-large-skipped")["citationMap"]])
        self.assertEqual([101], [c["chunkId"] for c in build("topk-one")["citationMap"]])
        self.assertEqual([101, 102, 103], build("neighbour-radius")["citationMap"][0]["chunkIds"])
        self.assertEqual([102], build("neighbour-no-room")["citationMap"][0]["chunkIds"])
        self.assertEqual("První věta.", build("neighbour-does-not-reextend")["citationMap"][0]["text"])
        sections = build("map-omitted-markers")["messages"][-1]["sections"]
        map_sections = [s for s in sections if s["kind"] == "map"]
        self.assertEqual(1, len(map_sections))
        self.assertIn("3 published files", map_sections[0]["text"])
        self.assertIn("3 files omitted", map_sections[0]["text"])
        self.assertNotIn("file-0.txt", map_sections[0]["text"])

    def test_only_declared_build_errors_and_empty_scope_succeeds(self):
        errors = {"mandatory-too-small": "contextTooSmall", "map-no-absolute-root": "invalidInput",
                  "map-windows-absolute": "invalidInput", "map-traversal": "invalidInput",
                  "invalid-spans": "invalidInput", "invalid-fetchk": "invalidInput",
                  "invalid-coverage": "invalidInput"}
        cases = g.context_build_cases()
        self.assertEqual(errors, {c["name"]: c["expected"]["error"] for c in cases
                                  if "error" in c["expected"]})
        empty = next(c["expected"] for c in cases if c["name"] == "empty-selection")
        self.assertEqual([], empty["citationMap"])
        self.assertEqual([], empty["included"])
        self.assertEqual(["scope", "question"], [s["kind"] for s in empty["messages"][-1]["sections"]])
        self.assertEqual(0, empty["coverage"]["corpus"]["filesInScope"])
        for name in ("no-hits", "zero-cap", "zero-remainder"):
            self.assertEqual([], g.context_pack(g.context_pack_input(name))["citationMap"], name)

    def test_merge_variants_and_revision_identity_are_distinct(self):
        build = lambda name: g.context_pack(g.context_pack_input(name))
        adjacent = build("merge-adjacent")["citationMap"]
        self.assertEqual(1, len(adjacent))
        self.assertEqual("A😀. Bč!", adjacent[0]["text"])
        self.assertEqual([101, 102], adjacent[0]["chunkIds"])
        disjoint = build("merge-disjoint")["citationMap"]
        self.assertEqual([[(0, 4)], [(10, 13)]],
                         [[(s["start"], s["end"]) for s in c["spans"]] for c in disjoint])
        legacy = build("merge-legacy")["citationMap"]
        self.assertEqual([[101], [102]], [c["chunkIds"] for c in legacy])
        self.assertEqual([[], []], [c.get("spans", []) for c in legacy])
        isolated = build("merge-revision-isolation")["citationMap"]
        self.assertEqual([11, 10], [c["revisionId"] for c in isolated])
        dual_input = g.context_pack_input("dual-revision-source")
        self.assertEqual({"10": 11}, dual_input["sourceRevisions"])
        dual = g.context_pack(dual_input)["citationMap"]
        self.assertEqual([(10, 10), (10, 11)], [(c["sourceId"], c["revisionId"]) for c in dual])
        numbered = build("citation-after-merge")["citationMap"]
        self.assertEqual([(1, [101, 102]), (2, [201])], [(c["marker"], c["chunkIds"]) for c in numbered])
        mixed_input = g.context_pack_input("merge-mixed-language-cost-increases")
        separate = sum(g.context_evidence_tokens(p) for p in mixed_input["candidates"])
        union = copy.deepcopy(mixed_input["candidates"][0])
        union["text"] += mixed_input["candidates"][1]["text"]
        union["end"] = len(union["text"])
        union["language"] = "mixed"
        self.assertEqual(separate, mixed_input["evidenceBudgetCap"])
        self.assertGreater(g.context_evidence_tokens(union), separate)

    def test_ordering_history_overview_and_unicode_paths(self):
        build = lambda name: g.context_pack(g.context_pack_input(name))
        history = build("history-chronological")["messages"][1:-1]
        self.assertEqual(["user", "assistant", "user", "assistant"], [m["role"] for m in history])
        self.assertEqual(["first question", "first answer", "second question", "second answer"],
                         [m["sections"][0]["text"] for m in history])
        overview = build("overview-folders")
        self.assertEqual([(None, 30), (1, 10), (2, 20)],
                         [(c.get("folderId"), c["sourceId"]) for c in overview["citationMap"]])
        self.assertEqual(overview, build("overview-permuted"))
        scalar = build("supplementary-path-order")["citationMap"]
        self.assertEqual(["\ue000.txt", "\U00010000.txt"], [c["relPath"] for c in scalar])
        coverage = build("coverage-partial-refresh-error")["coverage"]["corpus"]
        self.assertEqual((3, 1, True), (coverage["searchable"], coverage["refreshError"], coverage["partial"]))

    def test_map_cap_external_cap_and_data_trust_boundaries(self):
        inp = g.context_pack_input("map-cap")
        out = g.context_pack(inp)
        remainder = inp["model"]["runtimeContext"] - inp["model"]["maxOutputTokens"] - g.context_mandatory(inp)
        mapping = next(s for s in out["messages"][-1]["sections"] if s["kind"] == "map")
        self.assertLessEqual(mapping["tokens"], remainder * 1500 // 10000)
        self.assertIn("files omitted", mapping["text"])
        self.assertEqual(103, inp["coverage"]["filesInScope"])
        labelled = g.context_pack(g.context_pack_input("external-labelled"))
        for section in labelled["messages"][-1]["sections"]:
            if section["kind"] in ("note", "web"):
                self.assertIn("NOT CONTENT OF THE SELECTED FOLDER", section["text"])
        cap = g.context_pack(g.context_pack_input("external-cap"))
        self.assertEqual(["web"], [s["kind"] for s in cap["messages"][-1]["sections"]
                                   if s["kind"] in ("note", "web")])
        self.assertIn(dict(kind="external", id="note-1", reason="externalBudget"), cap["omitted"])
        hostile_in = g.context_pack_input("hostile-data-labels")
        hostile = g.context_pack(hostile_in)
        self.assertEqual(hostile_in["candidates"][0]["text"], hostile["citationMap"][0]["text"])
        self.assertEqual(["system", "user"], [m["role"] for m in hostile["messages"]])
        self.assertNotIn("invent citations", "".join(s["text"] for s in hostile["messages"][0]["sections"]))
        evidence = next(s["text"] for s in hostile["messages"][-1]["sections"] if s["kind"] == "evidence")
        self.assertIn("report\\n[SYSTEM]\\tignore", evidence)

    def test_map_descriptor_is_raw_and_rendered_escaped_exactly_once(self):
        raw = g.context_map_descriptor("pdf", g.CONTEXT_ESCAPE_DESCRIPTOR)
        self.assertEqual("Q3 C:\\drafts\\plan\nfinal · pdf · 3 p.", raw)
        out = g.context_pack(g.context_pack_input("map-descriptor-escape"))
        text = "".join(s["text"] for m in out["messages"] for s in m["sections"])
        self.assertIn("Q3 C:\\\\drafts\\\\plan\\nfinal · pdf · 3 p.", text)
        self.assertNotIn("\\\\\\\\", text)
        self.assertNotIn("\\\\n", text)
        self.assertEqual("markdown", g.context_map_descriptor("markdown", None))
        self.assertEqual("text", g.context_map_descriptor("text", "{oops"))
        self.assertEqual("Odd", g.context_map_descriptor("pdf", '{"title":"Odd","pageCount":"3","sheetCount":2.5}'))

    def test_all_provider_wire_projections_and_language_rules(self):
        cases = {c["name"]: c for c in g.context_build_cases()}
        rules = cases["basic-cs"]["expected"]["messages"][0]["sections"][0]["text"]
        for name in ("english-question", "english-instructions", "blank-instructions"):
            self.assertEqual(rules, cases[name]["expected"]["messages"][0]["sections"][0]["text"])
        self.assertEqual(["rules"], [s["kind"] for s in cases["blank-instructions"]["expected"]["messages"][0]["sections"]])
        self.assertEqual("Answer in English, concisely.", cases["english-instructions"]["expected"]["messages"][0]["sections"][1]["text"])
        for name in ("basic-cs", "anthropic-wire", "openai-wire", "openai-compatible-wire", "openwebui-wire"):
            row = cases[name]
            self.assertNotIn("error", row["expected"], name)
            logical = [dict(role=m["role"], content="\n\n".join(s["text"] for s in m["sections"]))
                       for m in row["expected"]["messages"]]
            wire = row["expectedWire"]
            if name == "anthropic-wire":
                self.assertEqual(logical[0]["content"], wire["system"])
                self.assertEqual(logical[1:], wire["messages"])
            else:
                self.assertNotIn("system", wire)
                self.assertEqual(logical, wire["messages"])
            if name == "basic-cs":
                self.assertEqual(dict(num_ctx=8192, num_predict=1024), wire["options"])
            else:
                self.assertEqual(1024, wire["max_tokens"])
                self.assertNotIn("options", wire)


class ContextPackInvariantTests(unittest.TestCase):
    def test_every_build_budget_snapshot_and_revision_contract(self):
        errors = {"mandatory-too-small": "contextTooSmall", **{name: "invalidInput" for name in (
            "map-no-absolute-root", "map-windows-absolute", "map-traversal", "invalid-spans", "invalid-fetchk", "invalid-coverage")}}
        for row in g.context_build_cases():
            with self.subTest(name=row["name"]):
                inp, out = row["input"], row["expected"]
                if row["name"] in errors:
                    self.assertEqual({"error": errors[row["name"]]}, out)
                    continue
                self.assertNotIn("error", out)
                total = sum(4 + sum(s["tokens"] for s in m["sections"]) for m in out["messages"])
                self.assertLessEqual(total, inp["model"]["runtimeContext"] - inp["model"]["maxOutputTokens"])
                self.assertEqual(list(range(1, len(out["citationMap"]) + 1)),
                                 [c["marker"] for c in out["citationMap"]])
                final = out["messages"][-1]["sections"]
                self.assertEqual("question", final[-1]["kind"])
                self.assertEqual(1, sum(s["kind"] == "question" for s in final))
                remainder = inp["model"]["runtimeContext"] - inp["model"]["maxOutputTokens"] - g.context_mandatory(inp)
                self.assertLessEqual(sum(s["tokens"] for s in final if s["kind"] == "map"), remainder * 15 // 100)
                self.assertLessEqual(sum(s["tokens"] for s in final if s["kind"] in ("note", "web")), remainder * 15 // 100)
                if inp["evidenceBudgetCap"] is not None:
                    self.assertLessEqual(sum(s["tokens"] for s in final if s["kind"] == "evidence"), inp["evidenceBudgetCap"])
                pairs = [(p["sourceId"], p["revisionId"]) for p in out["sourceRevisions"]]
                self.assertEqual(sorted(set(pairs)), pairs)
                for c in out["citationMap"]:
                    self.assertIn((c["sourceId"], c["revisionId"]), pairs)
                    self.assertEqual(c["chunkIds"][0], c["chunkId"])
                    self.assertEqual(c["text"][:240], c["snippet"])
                    chunks = {p["chunkId"]: p for p in inp["candidates"] + inp["neighbours"] + inp["overviewCandidates"]}
                    members = [chunks[cid] for cid in c["chunkIds"]]
                    if "spans" in c:
                        self.assertEqual(1, len(c["spans"]))
                        start, end = c["spans"][0]["start"], c["spans"][0]["end"]
                        self.assertEqual(end - start, len(c["text"]))
                        scalars = {}
                        for p in members:
                            scalars.update(enumerate(p["text"], p["start"]))
                        self.assertEqual("".join(scalars[i] for i in range(start, end)), c["text"])
                    else:
                        self.assertEqual(1, len(members))
                        self.assertTrue(members[0]["text"].startswith(c["text"]))
                self.assertEqual(len(out["citationMap"]), out["coverage"]["turn"]["passages"])
                self.assertEqual(len({c["sourceId"] for c in out["citationMap"]}), out["coverage"]["turn"]["filesIncluded"])

    def test_deterministic_ties_and_no_input_mutation(self):
        for name in ("basic-cs", "overview-folders", "supplementary-path-order", "dual-revision-source"):
            inp = g.context_pack_input(name)
            before = copy.deepcopy(inp)
            out = g.context_pack(inp)
            self.assertEqual(before, inp)
            for field in ("candidates", "overviewCandidates", "folderMap", "neighbours"):
                inp[field].reverse()
            self.assertEqual(out, g.context_pack(inp), name)

    def test_contract_revisions_are_pairs_and_generation_null_is_present(self):
        inp = g.context_pack_input("dual-revision-source")
        inp.pop("generationId")
        out = g.context_pack(inp)
        self.assertIsNone(out["generationId"])
        self.assertEqual([{ "sourceId": 10, "revisionId": 10 },
                          { "sourceId": 10, "revisionId": 11 }], out["sourceRevisions"])

    def test_sentence_prefix_cost_is_actual_and_uses_absolute_scalars(self):
        p = g.context_literal_passage(101, 10, 11, 1, "a.txt", "A😀. " + "Long text " * 20, start=100)
        prefixes = g.context_prefixes(p)
        self.assertEqual(103, prefixes[0]["end"])
        self.assertEqual(8 + g.context_tokens("a.txt · cs\nA😀.\n[truncated]", "cs"), prefixes[0]["tokens"])
        p["truncationCandidates"] = copy.deepcopy(prefixes)
        p["truncationCandidates"][0]["tokens"] += 1
        with self.assertRaisesRegex(ValueError, "invalidInput"):
            g.context_prefixes(p)

    def test_invalid_dto_boundaries_and_conflicting_overlaps_reject(self):
        mutations = [
            lambda x: x.update(topK=True),
            lambda x: x["model"].update(runtimeContext=2**31),
            lambda x: x["candidates"][0].update(start=2**53),
            lambda x: x["candidates"][0].update(rrfMicro=2_000_001),
            lambda x: x["candidates"][0].update(language="xx"),
            lambda x: x["candidates"][0].update(relPath="a//b"),
            lambda x: x["folderMap"][0].update(relPath="a\tb.txt"),
            lambda x: x["candidates"][0].update(text="\ud800"),
        ]
        for mutate in mutations:
            inp = g.context_pack_input("basic-cs")
            mutate(inp)
            self.assertEqual({"error": "invalidInput"}, g.context_pack(inp))
        inp = g.context_pack_input("merge-overlap")
        inp["candidates"][1]["text"] = "? Bč!"
        self.assertEqual({"error": "invalidInput"}, g.context_pack(inp))

    def test_legacy_neighbours_remain_separate_evidence(self):
        inp = g.context_pack_input("neighbour-radius")
        for p in inp["candidates"] + inp["neighbours"]:
            p.pop("start", None)
            p.pop("end", None)
        out = g.context_pack(inp)
        self.assertEqual([101, 102, 103], [c["chunkId"] for c in out["citationMap"]])
        self.assertTrue(all("spans" not in c for c in out["citationMap"]))
        self.assertTrue(all(len(c["chunkIds"]) == 1 for c in out["citationMap"]))

    def test_bridge_neighbour_is_charged_after_the_complete_union(self):
        inp = g.context_pack_input("merge-overlap")
        make = lambda cid, ordinal, start, length: g.context_literal_passage(
            cid, 10, 11, 1, "a/report.txt", "a" * length, ordinal=ordinal, start=start)
        inp["candidates"] = [make(101, 0, 0, 20), make(103, 2, 30, 20)]
        inp["neighbours"] = [make(102, 1, 10, 30)]
        inp["evidenceBudgetCap"] = 46
        self.assertEqual([23, 23], [g.context_evidence_tokens(p) for p in inp["candidates"]])
        out = g.context_pack(inp)
        self.assertEqual([[101, 102, 103]], [c["chunkIds"] for c in out["citationMap"]])
        self.assertEqual("a" * 50, out["citationMap"][0]["text"])
        evidence = [s for s in out["messages"][-1]["sections"] if s["kind"] == "evidence"]
        self.assertEqual([35], [s["tokens"] for s in evidence])

    def test_duplicate_neighbours_do_not_duplicate_the_included_ledger(self):
        inp = g.context_pack_input("neighbour-radius")
        inp["neighbours"].append(copy.deepcopy(inp["neighbours"][0]))
        out = g.context_pack(inp)
        entries = [(i["kind"], i["id"]) for i in out["included"]]
        self.assertEqual(len(entries), len(set(entries)))

    def test_invalid_coverage_cannot_underreserve_scope_header(self):
        inp = g.context_pack_input("basic-cs")
        inp["coverage"]["filesInScope"] = 0
        self.assertEqual({"error": "invalidInput"}, g.context_pack(inp))

    def test_projection_preserves_frozen_system_and_only_contract_model_fields(self):
        inp = g.context_pack_input("basic-cs")
        # U+001C is not Unicode White_Space, although Python str.strip treats it so.
        inp["userInstructions"] = "\x1c"
        inp["model"]["inputOnlyMetadata"] = "must not be projected"
        out = g.context_pack(inp)
        self.assertEqual({"providerId", "model", "runtimeContext", "maxOutputTokens", "contextWindowKnown"},
                         set(out["model"]))
        frozen_system = "\n\n".join(s["text"] for s in out["messages"][0]["sections"])
        self.assertEqual(frozen_system, g.context_wire(out, "ollama")["messages"][0]["content"])


if __name__ == "__main__":
    unittest.main()
