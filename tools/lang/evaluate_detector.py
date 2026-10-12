"""Held-out release evaluation, native replay and release gate for lang-detector-v1.

Offline only. Rebuilds the pinned split from the lock/config, scores the frozen
artifact on validation and the untouched test split, evaluates every WP1
document in document mode, writes the compact committed CI replay plus metrics
and report, and optionally replays every held-out example through the real
Swift and C# production detectors. Nothing here retrains, recalibrates or edits
thresholds; failures are reported, never tuned away.
"""

import argparse
from bisect import bisect_left
from collections import Counter, defaultdict
import hashlib
import json
from multiprocessing import Pool
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools.lang.calibrate import BUCKETS, GATES, exact_gate, metric
from tools.lang.prepare_corpus import TABLE_PATH, json_bytes, prepare, read_json, sha_file
from tools.lang.reference import Scorer, UnicodeData, detect_document, normalize
from tools.lang.train_detector import MINIMUM_SUPPORT, NEGATIVES, TARGETS, _contributor, load_wp1, validate_config

REPORT_BUCKETS = (0,) + BUCKETS
EVALUATED_SPLITS = ("validation", "test")
CI_PER_GROUP = 16
BATCH_SIZE = 256
CS_SK = {("cs", "sk"), ("sk", "cs")}
METRIC_NAMES = ("acceptedError", "csSkConfusion", "foreignAcceptance", "acceptanceCoverage")
DOCUMENT_LABELS = ("cs", "de", "en", "sk", "mixed", "und")
CONTRACT = "lang-release"
SWIFT_FILTER = "LanguageReleaseTests"
DOTNET_PROJECT = "windows/tests/AINotebook.Core.Tests"
COMPACTION = {
    "features": "sha256 of UTF-8: orders joined by '|'; entries joined by ';'; entry = symbols joined by ',' + ':' + count",
    "wordScalars": "sha256 of UTF-8: words joined by ';'; word = scalars joined by ','",
    "words": "sha256 of UTF-8: the word strings joined by U+0000",
    "value": "'sha256:' + lowercase hex; applies to text results and every document window's expected result",
}


# ----------------------------------------------------------------- compaction

def _digest(text: str) -> str:
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()


def digest_features(features: list) -> str:
    return _digest("|".join(";".join(",".join(map(str, e["symbols"])) + ":" + str(e["count"]) for e in order)
                            for order in features))


def digest_word_scalars(words: list) -> str:
    return _digest(";".join(",".join(map(str, word)) for word in words))


def digest_words(words: list) -> str:
    return _digest("\0".join(words))


def compact_text(result: dict) -> dict:
    """Same fields; the three bulky derived arrays become collision-resistant digests."""
    return {**result, "features": digest_features(result["features"]),
            "wordScalars": digest_word_scalars(result["wordScalars"]), "words": digest_words(result["words"])}


def compact_document(result: dict) -> dict:
    return {**result, "windows": [{**w, "expected": compact_text(w["expected"])} for w in result["windows"]]}


# -------------------------------------------------------------------- metrics

def _bucket_of(letters: int) -> int:
    return max(b for b in REPORT_BUCKETS if b <= letters)


def _summary(selected, languages, negatives, targets):
    groups = {language: set() for language in languages}
    evaluated, accepted = Counter(), Counter()
    errors = cs_sk = 0
    for truth, group, label in selected:
        groups[truth].add(group)
        evaluated[truth] += 1
        if label in targets:
            accepted[truth] += 1
            errors += label != truth
            cs_sk += (truth, label) in CS_SK
    total = sum(accepted.values())
    return {
        "metrics": {
            "acceptedError": metric(errors, total),
            "csSkConfusion": metric(cs_sk, accepted["cs"] + accepted["sk"]),
            "foreignAcceptance": metric(sum(accepted[l] for l in negatives), sum(evaluated[l] for l in negatives)),
            "acceptanceCoverage": metric(total, sum(evaluated.values())),
        },
        "support": {l: {"originalGroups": len(groups[l]), "evaluated": evaluated[l], "accepted": accepted[l]}
                    for l in languages},
        "acceptedTotal": total, "acceptedTrueCs": accepted["cs"], "acceptedTrueSk": accepted["sk"],
    }


def _support_pass(summary, negatives):
    groups_ok = all(row["originalGroups"] >= (MINIMUM_SUPPORT["groupsPerNegativeLanguage"] if language in negatives
                                              else MINIMUM_SUPPORT["groupsPerTarget"])
                    for language, row in summary["support"].items())
    return (groups_ok and summary["acceptedTotal"] >= MINIMUM_SUPPORT["acceptedTotal"]
            and summary["acceptedTrueCs"] >= MINIMUM_SUPPORT["acceptedTrueCs"]
            and summary["acceptedTrueSk"] >= MINIMUM_SUPPORT["acceptedTrueSk"])


def evaluate(rows: list, predictions: list, manifest: dict) -> dict:
    """Exact held-out metrics from frozen predictions; acceptance is the predicted label.

    rows: {split, truth, originalGroupId}; predictions: {label, letterCount, bucketStart}.
    Support/metric rows use the training manifest's layout, so a full run must
    reproduce the recorded manifest values exactly (reported, not assumed).
    """
    if len(rows) != len(predictions):
        raise ValueError("rows and predictions must be aligned")
    negatives = list(manifest["negativeLanguages"])
    targets = list(manifest.get("targets", TARGETS))
    languages = sorted(targets + negatives)
    disabled = [{"bucketStart": r["bucketStart"], "reason": r["reason"]}
                for r in manifest["calibration"]["disabledBuckets"]]
    enabled = [b for b in BUCKETS if b not in {r["bucketStart"] for r in disabled}]
    grouped, evaluated = defaultdict(list), Counter()
    for row, prediction in zip(rows, predictions):
        if row["split"] not in EVALUATED_SPLITS or row["truth"] not in languages:
            raise ValueError("unknown split or truth language")
        bucket = _bucket_of(prediction["letterCount"])
        if (prediction["bucketStart"] or 0) != bucket:
            raise ValueError("prediction bucketStart disagrees with letterCount")
        grouped[row["split"], bucket].append((row["truth"], row["originalGroupId"], prediction["label"]))
        evaluated[row["split"]] += 1
    support, metrics, gate_rows = [], [], []
    for split in EVALUATED_SPLITS:
        for bucket in REPORT_BUCKETS:
            selected = grouped[split, bucket]
            summary = _summary(selected, languages, negatives, targets)
            if bucket:
                support.extend({"split": split, "bucketStart": bucket, "language": language, **r}
                               for language, r in summary["support"].items())
                gate_rows.append({"split": split, "bucketStart": bucket, "enabled": int(bucket in enabled),
                                  "supportPass": _support_pass(summary, negatives), **summary["metrics"]})
            for language in ["all"] + languages:
                result = summary if language == "all" else _summary(
                    [s for s in selected if s[0] == language], languages, negatives, targets)
                metrics.extend({"split": split, "bucketStart": bucket, "language": language, "name": name, **m}
                               for name, m in result["metrics"].items())
    return {"targets": targets, "negativeLanguages": negatives, "enabledBuckets": enabled,
            "disabledBuckets": disabled, "evaluated": {s: evaluated[s] for s in EVALUATED_SPLITS},
            "support": support, "metrics": metrics, "gateRows": gate_rows,
            "manifestReconciled": {"support": support == manifest.get("support"),
                                   "metrics": metrics == manifest.get("metrics")}}


def evaluate_documents(snapshot: dict, predictions: list, manifest: dict) -> dict:
    """Document-mode results; never mixed into text denominators."""
    if len(snapshot["documents"]) != len(predictions):
        raise ValueError("documents and predictions must be aligned")
    counts = Counter()
    confusion = {gold: {label: 0 for label in DOCUMENT_LABELS} for gold in DOCUMENT_LABELS}
    results = []
    for row, predicted in zip(snapshot["documents"], predictions):
        counts[row["sourceId"], row["goldLabel"], predicted["label"]] += 1
        confusion[row["goldLabel"]][predicted["label"]] += 1
        results.append({"documentId": row["documentId"], "sourceId": row["sourceId"], "goldLabel": row["goldLabel"],
                        "label": predicted["label"], "reason": predicted["reason"],
                        "sharesBp": predicted["sharesBp"], "unknownShareBp": predicted["unknownShareBp"],
                        "langCoverageBp": predicted["langCoverageBp"], "sampledLetters": predicted["sampledLetters"],
                        "windows": [{"label": w["expected"]["label"], "reason": w["expected"]["reason"],
                                     "letterCount": w["expected"]["letterCount"]} for w in predicted["windows"]]})
    document_metrics = [{"sourceId": s, "goldLabel": g, "predictedLabel": p, "count": n}
                        for (s, g, p), n in sorted(counts.items())]
    mistakes = [r for r in results if r["label"] != r["goldLabel"]]
    return {"documents": len(results), "correct": len(results) - len(mistakes),
            "goldCounts": dict(sorted(Counter(r["goldLabel"] for r in results).items())),
            "documentMetrics": document_metrics, "confusion": confusion, "results": results, "mistakes": mistakes,
            "reconciled": document_metrics == manifest.get("documentMetrics")}


def assert_release_gate(report: dict) -> None:
    """Fail with every exact bucket/split/support or numerator/denominator problem."""
    enabled = report.get("enabledBuckets") or []
    if not enabled:
        raise ValueError("NO_ENABLED_BUCKETS: usefulness review required")
    rows = {(r["split"], r["bucketStart"]): r for r in report.get("gateRows", [])}
    failures = []
    for bucket in enabled:
        for split in EVALUATED_SPLITS:
            row = rows.get((split, bucket))
            if row is None:
                failures.append(f"{split} bucket {bucket}: missing gate row")
                continue
            if not row["supportPass"]:
                failures.append(f"{split} bucket {bucket}: insufficient support (minimum {MINIMUM_SUPPORT})")
            for name, max_bp in GATES.items():
                n, d = row[name]["numerator"], row[name]["denominator"]
                if not exact_gate(n, d, max_bp):
                    failures.append(f"{split} bucket {bucket}: {name} {n}/{d} exceeds {max_bp} bp")
    for name, ok in (report.get("manifestReconciled") or {}).items():
        if ok is False:
            failures.append(f"{name} do not reproduce the manifest")
    parity = report.get("nativeParity")
    if parity is not None:
        for name, result in sorted(parity["platforms"].items()):
            if result["mismatches"]:
                failures.append(f"native parity {name}: {result['mismatches']} mismatches")
            if result["cases"] != parity["expectedCases"]:
                failures.append(f"native parity {name}: evaluated {result['cases']} of {parity['expectedCases']}")
            if result["exitCode"]:
                failures.append(f"native parity {name}: exit code {result['exitCode']}")
    if failures:
        raise ValueError("; ".join(failures))


# ------------------------------------------------------------- CI selection

def selection_key(record_key: str, rule: str, length) -> tuple:
    text = f"{record_key}\n{rule}\n{'' if length is None else length}\n"
    return hashlib.sha256(text.encode("utf-8")).hexdigest(), record_key


class _Selector:
    """Keeps the first CI_PER_GROUP test examples per language × bucket by selection key."""

    def __init__(self):
        self.groups = defaultdict(lambda: ([], []))

    def offer(self, candidate):
        keys, group = self.groups[candidate["language"], candidate["bucketStart"]]
        key = selection_key(candidate["recordKey"], candidate["rule"], candidate["length"])
        if len(keys) < CI_PER_GROUP or key < keys[-1]:
            index = bisect_left(keys, key)
            keys.insert(index, key)
            group.insert(index, candidate)
            del keys[CI_PER_GROUP:], group[CI_PER_GROUP:]

    def selected(self):
        return [candidate for key in sorted(self.groups) for candidate in self.groups[key][1]]


def select_ci(candidates):
    selector = _Selector()
    for candidate in candidates:
        selector.offer(candidate)
    return selector.selected()


# ------------------------------------------------------------ scoring pass

_WORKER = {}


def _init_worker(artifact_path):
    tables = UnicodeData.load(TABLE_PATH)
    model = read_json(artifact_path)
    _WORKER.update(tables=tables, model=model, scorer=Scorer(model, tables),
                   input_cap=model["parameters"]["inputCapScalars"], text_cap=model["parameters"]["textCapScalars"])


def _score_lines(lines):
    """Score the exact text the native APIs receive; check it reproduces the prepared scalars."""
    out = []
    for line in lines:
        row = json.loads(line)
        if row["split"] == "train":
            out.append(("train", row["originalGroupId"]))
            continue
        scalars = normalize(row["text"], _WORKER["tables"], _WORKER["input_cap"])[:_WORKER["text_cap"]]
        result = _WORKER["scorer"].score(scalars)
        item = {"split": row["split"], "truth": row["language"], "originalGroupId": row["originalGroupId"],
                "recordKey": row["recordKey"], "rule": row["rule"], "length": row["length"],
                "licenseId": row["licenseId"], "contributor": row["contributor"],
                "memberRecordKeys": row.get("memberRecordKeys", [row["recordKey"]]),
                "label": result["label"], "letterCount": result["letterCount"], "bucketStart": result["bucketStart"],
                "scalarMismatch": scalars != row["normalizedScalars"][:_WORKER["text_cap"]]}
        if row["split"] == "test":
            item["case"] = {"name": case_name(row), "sourceId": row["sourceId"], "recordKey": row["recordKey"],
                            "originalGroupId": row["originalGroupId"], "truth": row["language"], "mode": "text",
                            "input": row["text"], "expected": compact_text(result)}
        out.append(item)
    return out


def case_name(row):
    return f"{row['sourceId']}-{row['language']}-{row['recordKey'].split(':', 1)[1]}-{row['rule']}-{row['length'] or 0}"


def _chunks(path, size=2000):
    with Path(path).open("rb") as stream:
        chunk = []
        for line in stream:
            chunk.append(line)
            if len(chunk) == size:
                yield chunk
                chunk = []
        if chunk:
            yield chunk


class _BatchWriter:
    def __init__(self, directory):
        self.directory, self.cases, self.files, self.total = directory, [], 0, 0
        if directory is not None:
            if directory.exists():
                shutil.rmtree(directory)
            directory.mkdir(parents=True)

    def add(self, case):
        if self.directory is None:
            return
        self.cases.append(case)
        self.total += 1
        if len(self.cases) == BATCH_SIZE:
            self.flush()

    def flush(self):
        if self.directory is None or not self.cases:
            return
        self.files += 1
        path = self.directory / f"{self.files:06d}.json"
        path.write_bytes(json_bytes({"contract": CONTRACT, "version": 1, "cases": self.cases}))
        self.cases = []


def score_examples(examples_path, artifact_path, batch_dir=None, workers=None):
    rows, predictions, mismatches = [], [], Counter()
    split_groups = {split: set() for split in ("train",) + EVALUATED_SPLITS}
    originals, selector, writer = {}, _Selector(), _BatchWriter(batch_dir)
    with Pool(workers or os.cpu_count(), initializer=_init_worker, initargs=(str(artifact_path),)) as pool:
        for chunk in pool.imap(_score_lines, _chunks(examples_path), chunksize=1):
            for item in chunk:
                if isinstance(item, tuple):
                    split_groups["train"].add(bytes.fromhex(item[1]))
                    continue
                split_groups[item["split"]].add(bytes.fromhex(item["originalGroupId"]))
                mismatches[item["split"]] += item["scalarMismatch"]
                rows.append({"split": item["split"], "truth": item["truth"], "originalGroupId": item["originalGroupId"]})
                predictions.append({"label": item["label"], "letterCount": item["letterCount"],
                                    "bucketStart": item["bucketStart"]})
                if item["split"] != "test":
                    continue
                if item["rule"] == "original":
                    originals[item["recordKey"]] = (item["licenseId"], item["contributor"])
                writer.add(item["case"])
                selector.offer({"language": item["truth"], "bucketStart": _bucket_of(item["letterCount"]),
                                "recordKey": item["recordKey"], "rule": item["rule"], "length": item["length"],
                                "licenseId": item["licenseId"], "contributor": item["contributor"],
                                "memberRecordKeys": item["memberRecordKeys"], "case": item["case"]})
    writer.flush()
    disjoint = all(not (split_groups[a] & split_groups[b])
                   for i, a in enumerate(split_groups) for b in list(split_groups)[i + 1:])
    return {"rows": rows, "predictions": predictions, "scalarMismatches": dict(mismatches),
            "groups": {s: len(g) for s, g in split_groups.items()}, "disjoint": disjoint,
            "originals": originals, "selected": selector.selected(), "writer": writer}


# ------------------------------------------------------- provenance checks

def _arguments(manifest):
    values = manifest["environment"]["commandArguments"]
    return {values[i]: values[i + 1] for i in range(0, len(values) - 1, 2)}


def verify_inputs(args, artifact, manifest, config, snapshot):
    arguments = _arguments(manifest)
    problems = []
    for flag, path in (("--lock-sha256", args.lock), ("--config-sha256", args.config),
                       ("--wp1-snapshot-sha256", args.wp1_documents)):
        if sha_file(path) != arguments[flag]:
            problems.append(f"{path} SHA-256 differs from the manifest {flag}")
    if sha_file(args.artifact) != manifest["artifactSha256"]:
        problems.append("artifact SHA-256 differs from the manifest")
    if artifact["modelId"] != config["modelId"] or manifest["negativeLanguages"] != NEGATIVES or artifact["targets"] != TARGETS:
        problems.append("artifact/config/manifest language identity mismatch")
    owned = {f["sha256"]: f for c in manifest["corpus"] if c["id"] != config["sourceId"] for f in c["files"]}
    licenses = {c["id"]: c["licenseIds"] for c in manifest["corpus"]}
    for row in snapshot["documents"]:
        entry = owned.get(row["sha256"])
        if entry is None or entry["url"] != row["url"] or row["licenseId"] not in licenses.get(row["sourceId"], []):
            problems.append(f"WP1 document {row['documentId']} does not reconcile with the manifest corpus")
    if len(owned) != len(snapshot["documents"]):
        problems.append("WP1 document count differs from the manifest corpus")
    if problems:
        raise ValueError("; ".join(problems))


def verify_preparation(provenance, manifest, attribution_text):
    problems = [name for name in ("caps", "augmentation", "counts", "exclusions", "snapshotSkew")
                if name in manifest and manifest[name] != provenance[name]]
    if manifest["split"] != {**provenance["split"], "oversizedComponents": provenance["oversizedComponents"]}:
        problems.append("split")
    ledger = provenance["selectedSentences"]
    if f"SHA-256 `{ledger['sha256']}`" not in attribution_text or f"with {ledger['records']} lines" not in attribution_text:
        problems.append("selected-sentence ledger")
    if problems:
        raise ValueError("rebuilt corpus does not reproduce the manifest: " + ", ".join(problems))


def _contributors(attribution_text):
    names, section = defaultdict(set), None
    for line in attribution_text.splitlines():
        match = re.fullmatch(r"## Contributors: (\S+) / (\S+)", line)
        if match:
            section = match.groups()
        elif line.startswith("## "):
            section = None
        elif section and line.startswith("- "):
            names[section].add(line[2:].rsplit(": ", 1)[0])
    return names


def attribute_selection(selected, originals, ledger_path, attribution_text, snapshot):
    """Every redistributed sentence must be in the pinned ledger and credited in ATTRIBUTION.md."""
    needed = {int(k.split(":", 1)[1]) for c in selected for k in c["memberRecordKeys"]}
    ledger = {}
    with Path(ledger_path).open(encoding="utf-8") as stream:
        for line in stream:
            number, language, license_id, owner = line.rstrip("\n").split("\t")
            if int(number) in needed:
                ledger[int(number)] = (language, license_id, owner)
    credited, problems, cases = _contributors(attribution_text), [], []
    for candidate in selected:
        members = []
        for key in candidate["memberRecordKeys"]:
            license_id, owner = originals.get(key, (None, None))
            entry = ledger.get(int(key.split(":", 1)[1]))
            if entry is None or entry != (candidate["language"], license_id, owner):
                problems.append(f"{key}: not in the pinned selected-sentence ledger")
                continue
            name = _contributor(owner)
            if license_id == "CC-BY-2.0-FR" and name not in credited["tatoeba", license_id]:
                problems.append(f"{key}: contributor {name!r} missing from ATTRIBUTION.md")
            members.append({"recordKey": key, "licenseId": license_id, "contributor": name})
        case = candidate["case"]
        cases.append({"name": case["name"], "sourceId": case["sourceId"], "recordKey": case["recordKey"],
                      "rule": candidate["rule"], "length": candidate["length"], "members": members,
                      "originalGroupId": case["originalGroupId"], "truth": case["truth"], "mode": "text",
                      "input": case["input"], "expected": case["expected"]})
    for row in snapshot["documents"]:
        if f"/ {row['documentId']} / {row['licenseId']} /" not in attribution_text or row["sha256"] not in attribution_text:
            problems.append(f"WP1 document {row['documentId']} missing from ATTRIBUTION.md")
    if problems:
        raise ValueError("attribution does not cover the redistributed replay: " + "; ".join(problems[:20]))
    return cases


def document_cases(snapshot, predictions):
    return [{"name": f"wp1-{row['documentId']}", "sourceId": row["sourceId"], "documentId": row["documentId"],
             "licenseId": row["licenseId"], "url": row["url"], "originalGroupId": row["translationGroupId"],
             "truth": row["goldLabel"], "mode": "document", "input": row["text"],
             "expected": compact_document(predicted)}
            for row, predicted in zip(snapshot["documents"], predictions)]


# ----------------------------------------------------------- native parity

def run_native_parity(batch_dir, work_dir, expected_cases):
    def run(command, **kwargs):
        return subprocess.run(command, cwd=ROOT, capture_output=True, text=True, **kwargs)

    builds = {"swift": ["swift", "build", "--build-tests", "--package-path", str(ROOT)],
              "csharp": ["dotnet", "build", str(ROOT / DOTNET_PROJECT)]}
    tests = {"swift": ["swift", "test", "--skip-build", "--package-path", str(ROOT), "--filter", SWIFT_FILTER],
             "csharp": ["dotnet", "test", str(ROOT / DOTNET_PROJECT), "--no-build", "--no-restore",
                        "--filter", f"FullyQualifiedName~{SWIFT_FILTER}"]}
    platforms = {}
    for name in ("swift", "csharp"):
        build = run(builds[name])
        log = work_dir / f"native-{name}.log"
        summary_path = work_dir / f"native-{name}-summary.json"
        summary_path.unlink(missing_ok=True)
        if build.returncode:
            log.write_text(build.stdout + build.stderr, encoding="utf-8")
            platforms[name] = {"exitCode": build.returncode, "files": 0, "cases": 0, "mismatches": 0,
                               "firstMismatches": [], "error": "build failed"}
            continue
        env = {**os.environ, "AINOTEBOOK_LANG_RELEASE_INPUT": str(batch_dir),
               "AINOTEBOOK_LANG_RELEASE_SUMMARY": str(summary_path)}
        result = run(tests[name], env=env)
        log.write_text(result.stdout + result.stderr, encoding="utf-8")
        summary = read_json(summary_path) if summary_path.is_file() else {"files": 0, "cases": 0, "mismatches": 0,
                                                                         "firstMismatches": []}
        platforms[name] = {"exitCode": result.returncode, **summary}
    return {"expectedCases": expected_cases, "batchSize": BATCH_SIZE, "platforms": platforms}


# ------------------------------------------------------------------ report

def _bp(m):
    return "—" if m["denominator"] == 0 else f"{m['numerator']}/{m['denominator']} ({m['rateBp']} bp)"


def _explain(mistake, dominance_bp):
    windows = Counter((w["label"], w["reason"]) for w in mistake["windows"])
    accepted = {label: n for (label, reason), n in windows.items() if reason == "accepted"}
    abstained = {reason: n for (label, reason), n in windows.items() if reason != "accepted"}
    share = max(mistake["sharesBp"].values()) if mistake["sharesBp"] else 0
    return (f"{len(mistake['windows'])} windows: accepted "
            + (", ".join(f"{n}× {label}" for label, n in sorted(accepted.items())) or "none")
            + "; abstained " + (", ".join(f"{n}× {reason}" for reason, n in sorted(abstained.items())) or "none")
            + f". Best share {share} bp < {dominance_bp} bp dominance, one confident language only → "
            + f"`{mistake['label']}` ({mistake['reason']}).")


def render_report(metrics_doc):
    m, docs, prov = metrics_doc, metrics_doc["documents"], metrics_doc["provenance"]
    gate = m["gate"]
    lines = ["# Language detector v1 — held-out release gate", "",
             f"Generated by `tools/lang/evaluate_detector.py` (WP4 Task 14). Gate: **{gate['status']}**"
             + (f" — {gate['message']}" if gate["message"] else "") + ".", "",
             "Thresholds come from validation-only calibration (Task 13) and were not changed here. Test metrics use",
             "the untouched test split. Text metrics and WP1 document results are reported separately.", "",
             "## Provenance", "",
             "| Item | SHA-256 / value |", "|---|---|"]
    for key in ("artifactSha256", "manifestSha256", "lockSha256", "configSha256", "wp1SnapshotSha256",
                "attributionSha256", "fixtureSha256"):
        lines.append(f"| {key} | `{prov[key]}` |")
    lines += [f"| Tatoeba snapshot | {prov['tatoebaSnapshotDate']} |",
              f"| Exporter commit | `{prov['exporterGitCommit']}` |",
              f"| WP1 source revision | `{prov['wp1SourceRevision']}` |", "",
              ("Corpus rebuilt from the pinned exports" if m["corpus"]["rebuilt"] else
               "Corpus reused from a verified earlier preparation") + f": {m['corpus']['examples']['validation']} validation and "
              f"{m['corpus']['examples']['test']} test examples; original groups train/validation/test "
              f"{m['corpus']['groups']['train']}/{m['corpus']['groups']['validation']}/{m['corpus']['groups']['test']}, "
              f"pairwise disjoint: **{m['corpus']['disjoint']}**. Re-normalized input text reproduced the prepared "
              f"scalars for every example (mismatches: {sum(m['corpus']['scalarMismatches'].values())}). "
              f"Support/metric/document rows reproduce the training manifest: "
              f"**{all(m['manifestReconciled'].values())}**.", "",
              "## Release gate (enabled buckets, exact integer comparisons)", "",
              "Required per split and bucket: ≥200 original groups per language, ≥1000 accepts, ≥100 accepted true cs",
              "and sk; acceptedError ≤200 bp, csSkConfusion ≤100 bp, foreignAcceptance ≤100 bp.", "",
              "| Split | Bucket | Support | acceptedError | csSkConfusion | foreignAcceptance | Acceptance coverage |",
              "|---|---|---|---|---|---|---|"]
    for r in m["gateRows"]:
        lines.append(f"| {r['split']} | {r['bucketStart']} | {'pass' if r['supportPass'] else 'FAIL'} | "
                     f"{_bp(r['acceptedError'])} | {_bp(r['csSkConfusion'])} | {_bp(r['foreignAcceptance'])} | "
                     f"{_bp(r['acceptanceCoverage'])} |")
    lines += ["", "Enabled buckets: " + ", ".join(map(str, m["enabledBuckets"])) + ". Disabled buckets: "
              + (", ".join(f"{d['bucketStart']} ({d['reason']})" for d in m["disabledBuckets"]) or "none") + ".", "",
              "## Test acceptance coverage by language and bucket", "",
              "Accepted / evaluated test examples (bucket 0 = below 12 letters, always abstains).", "",
              "| Language | " + " | ".join(str(b) for b in REPORT_BUCKETS) + " |",
              "|---|" + "---|" * len(REPORT_BUCKETS)]
    coverage = {(r["bucketStart"], r["language"]): r for r in m["metrics"]
                if r["split"] == "test" and r["name"] == "acceptanceCoverage"}
    for language in ["all"] + sorted(m["targets"] + m["negativeLanguages"]):
        cells = []
        for b in REPORT_BUCKETS:
            r = coverage[b, language]
            cells.append(f"{r['numerator']}/{r['denominator']}" + (f" ({r['rateBp']} bp)" if r["denominator"] else ""))
        lines.append(f"| {language} | " + " | ".join(cells) + " |")
    lines += ["", "Negative languages (fr, hr, hu, nl, pl, sl) should be rejected; their accepted counts are",
              "foreign acceptances.", "",
              "## WP1 documents (document mode)", "",
              f"{docs['correct']}/{docs['documents']} documents receive their gold label. Gold counts: "
              + ", ".join(f"{k} {v}" for k, v in docs["goldCounts"].items()) + ". No appendix accuracy target exists;",
              "these results are for review, not a numeric gate.", "",
              "| Gold \\ predicted | " + " | ".join(DOCUMENT_LABELS) + " |", "|---|" + "---|" * len(DOCUMENT_LABELS)]
    for gold in DOCUMENT_LABELS:
        if any(docs["confusion"][gold].values()):
            lines.append(f"| {gold} | " + " | ".join(str(docs["confusion"][gold][p]) for p in DOCUMENT_LABELS) + " |")
    lines += ["", "Documents not receiving their gold label:", ""]
    for mistake in docs["mistakes"]:
        shares = ", ".join(f"{k} {v}" for k, v in mistake["sharesBp"].items() if v)
        lines.append(f"- **{mistake['documentId']}** (gold {mistake['goldLabel']}) → `{mistake['label']}`; shares "
                     f"{shares or 'none'} bp, unknown {mistake['unknownShareBp']} bp, coverage "
                     f"{mistake['langCoverageBp']} bp. " + _explain(mistake, m["mixedDominanceBp"]))
    if not docs["mistakes"]:
        lines.append("- none")
    lines += ["", "These abstentions are the conservative failure mode: no window chose a wrong language, but",
              "short or form-like windows (headers, tables, names, numbers) abstained, so the confident letters",
              "stay below the 70% dominance share. WP6/WP8 treat `und` as unknown; retrieval eligibility is unchanged.", ""]
    parity = m.get("nativeParity")
    ci = m["ciFixture"]
    lines += ["## Native parity", "",
              f"Committed CI replay `{ci['path']}` ({ci['bytes']} bytes): {ci['textCases']} test-split text cases "
              f"(first {CI_PER_GROUP} per language × bucket by SHA-256 selection key) and {ci['documentCases']} WP1 "
              "documents. Swift `LanguageDetector.bundled()` and C# `LanguageDetector.LoadBundled()` must reproduce "
              "every field of the Python reference result in ordinary CI; `features`, `wordScalars` and `words` are "
              "compared through SHA-256 digests of a canonical serialization to keep the fixture small.", ""]
    if parity:
        lines.append(f"Full held-out replay (`--native-parity`): {parity['expectedCases']} cases in envelopes of "
                     f"{parity['batchSize']}.")
        lines.append("")
        lines += ["| Platform | Exit | Cases | Mismatches |", "|---|---|---|---|"]
        for name, r in sorted(parity["platforms"].items()):
            lines.append(f"| {name} | {r['exitCode']} | {r['cases']} | {r['mismatches']} |")
    else:
        lines.append("Full held-out native replay was not run for this report.")
    lines += ["", "## Attribution", "",
              "Every replayed Tatoeba sentence is in the pinned selected-sentence ledger and its contributor is",
              "credited in `tools/lang/ATTRIBUTION.md`; each fixture case also carries its sentence IDs, licenses",
              "and contributors. WP1 documents are MIT (`eval/multilingual`) and listed in ATTRIBUTION.md.", "",
              "## Reproduce", "", "```bash", " ".join(m["command"]), "```", ""]
    return "\n".join(lines)


# ---------------------------------------------------------------------- CLI

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("data-dir", "lock", "config", "artifact", "manifest", "wp1-documents", "work-dir",
                 "fixture-output", "metrics-output", "report"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--attribution", type=Path, default=ROOT / "tools/lang/ATTRIBUTION.md")
    parser.add_argument("--prepared-dir", type=Path,
                        help="reuse an existing preparation of the same lock/config (verified against the manifest)")
    parser.add_argument("--workers", type=int)
    parser.add_argument("--native-parity", action="store_true",
                        help="replay every held-out example through swift test and dotnet test")
    parser.add_argument("--gate", action="store_true", help="exit nonzero unless every release gate passes")
    args = parser.parse_args(argv)

    lock, config = read_json(args.lock), read_json(args.config)
    validate_config(config)
    artifact_sha = sha_file(args.artifact)
    artifact, manifest = read_json(args.artifact), read_json(args.manifest)
    snapshot = load_wp1(args.wp1_documents)
    verify_inputs(args, artifact, manifest, config, snapshot)
    attribution_text = args.attribution.read_text(encoding="utf-8")
    if hashlib.sha256(attribution_text.encode("utf-8")).hexdigest() != artifact["attribution"]["attributionSha256"]:
        raise ValueError("ATTRIBUTION.md differs from the artifact's attribution digest")
    work = args.work_dir
    work.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="prepared-", dir=work) as temporary:
        prepared = args.prepared_dir or Path(temporary) / "prepared"
        if args.prepared_dir is None:
            provenance = prepare(args.data_dir, lock, config, prepared)
        else:
            provenance = read_json(prepared / "provenance.json")
            for item in ("selectedSentences", "splitAssignments"):
                if sha_file(prepared / provenance[item]["path"]) != provenance[item]["sha256"]:
                    raise ValueError(f"reused preparation {item} digest mismatch")
        verify_preparation(provenance, manifest, attribution_text)
        batch_dir = work / "replay" if args.native_parity else None
        scored = score_examples(prepared / "examples.jsonl", args.artifact, batch_dir, args.workers)
        tables = UnicodeData.load(TABLE_PATH)
        document_predictions = [detect_document(row["text"], artifact, tables) for row in snapshot["documents"]]
        text_cases = attribute_selection(scored["selected"], scored["originals"],
                                         prepared / provenance["selectedSentences"]["path"], attribution_text, snapshot)

    report = evaluate(scored["rows"], scored["predictions"], {**manifest, "targets": artifact["targets"]})
    documents = evaluate_documents(snapshot, document_predictions, manifest)
    report["manifestReconciled"]["documentMetrics"] = documents["reconciled"]
    if not scored["disjoint"]:
        report["manifestReconciled"]["groupPartition"] = False
    if any(scored["scalarMismatches"].values()):
        report["manifestReconciled"]["normalizedText"] = False

    docs = document_cases(snapshot, document_predictions)
    fixture = {"contract": CONTRACT, "version": 1, "artifactSha256": manifest["artifactSha256"],
               "compaction": COMPACTION,
               "attribution": "Text inputs are Tatoeba sentences (https://tatoeba.org); member recordKey "
                              "tatoeba:N is https://tatoeba.org/en/sentences/show/N, licensed CC-BY-2.0-FR "
                              "(https://creativecommons.org/licenses/by/2.0/fr/, credited to the member contributor) "
                              "or CC0-1.0, as listed per member; see tools/lang/ATTRIBUTION.md. Document inputs are "
                              "MIT-licensed eval/multilingual files at the case url.",
               "cases": text_cases + docs}
    fixture_bytes = json_bytes(fixture)
    args.fixture_output.parent.mkdir(parents=True, exist_ok=True)
    args.fixture_output.write_bytes(fixture_bytes)

    parity = None
    if args.native_parity:
        writer = scored["writer"]
        writer.directory = batch_dir
        for case in docs:  # documents are held out too: replay them after the text batches
            writer.add({k: case[k] for k in ("name", "sourceId", "originalGroupId", "truth", "mode", "input", "expected")})
        writer.flush()
        parity = run_native_parity(batch_dir, work, len(fixture["cases"]) + writer.total)
        report["nativeParity"] = parity

    if sha_file(args.artifact) != artifact_sha:
        raise ValueError("artifact changed during evaluation")
    try:
        assert_release_gate(report)
        gate = {"status": "PASS", "message": ""}
    except ValueError as error:
        gate = {"status": "FAIL", "message": str(error)}

    def relative(path):
        try:
            return Path(path).resolve().relative_to(ROOT).as_posix()
        except ValueError:
            return str(path)

    command = ["python3", "-B", "tools/lang/evaluate_detector.py", "--data-dir", "$DATA",
               "--lock", relative(args.lock), "--config", relative(args.config), "--artifact", relative(args.artifact),
               "--manifest", relative(args.manifest), "--wp1-documents", relative(args.wp1_documents),
               "--work-dir", "$WORK", "--fixture-output", relative(args.fixture_output),
               "--metrics-output", relative(args.metrics_output), "--report", relative(args.report)]
    command += (["--native-parity"] if args.native_parity else []) + (["--gate"] if args.gate else [])
    metrics_doc = {
        "contract": "lang-release-metrics", "version": 1,
        "provenance": {"artifactSha256": manifest["artifactSha256"], "manifestSha256": sha_file(args.manifest),
                       "lockSha256": sha_file(args.lock), "configSha256": sha_file(args.config),
                       "wp1SnapshotSha256": sha_file(args.wp1_documents),
                       "attributionSha256": artifact["attribution"]["attributionSha256"],
                       "fixtureSha256": hashlib.sha256(fixture_bytes).hexdigest(),
                       "tatoebaSnapshotDate": lock["snapshotDate"],
                       "exporterGitCommit": manifest["environment"]["exporterGitCommit"],
                       "wp1SourceRevision": snapshot["sourceRevision"]},
        "command": command,
        "environment": {"pythonVersion": platform.python_version(), "dependencies": []},
        "corpus": {"rebuilt": args.prepared_dir is None, "examples": report["evaluated"],
                   "groups": scored["groups"], "disjoint": scored["disjoint"],
                   "scalarMismatches": scored["scalarMismatches"]},
        "targets": report["targets"], "negativeLanguages": report["negativeLanguages"],
        "mixedDominanceBp": artifact["parameters"]["mixedDominanceBp"],
        "enabledBuckets": report["enabledBuckets"], "disabledBuckets": report["disabledBuckets"],
        "thresholds": artifact["thresholds"], "minimumSupport": MINIMUM_SUPPORT,
        "gateRows": report["gateRows"], "support": report["support"], "metrics": report["metrics"],
        "manifestReconciled": report["manifestReconciled"],
        "documents": {k: v for k, v in documents.items() if k != "reconciled"},
        "ciFixture": {"path": relative(args.fixture_output), "bytes": len(fixture_bytes),
                      "textCases": len(text_cases), "documentCases": len(docs), "perLanguageBucket": CI_PER_GROUP},
        "nativeParity": parity, "gate": gate}
    args.metrics_output.parent.mkdir(parents=True, exist_ok=True)
    args.metrics_output.write_bytes(json_bytes(metrics_doc))
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(render_report(metrics_doc), encoding="utf-8")
    if parity:
        print("native parity: " + ", ".join(f"{'Swift' if n == 'swift' else 'C#'}={r['mismatches']} mismatches"
                                            f" ({r['cases']}/{parity['expectedCases']} cases)"
                                            for n, r in sorted(parity["platforms"].items(), reverse=True)))
    print(f"release gate: {gate['status']}" + (f" — {gate['message']}" if gate["message"] else ""))
    if args.gate and gate["status"] != "PASS":
        sys.exit(1)


if __name__ == "__main__":
    main()
