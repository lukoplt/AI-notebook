"""Reproducible offline language training/export. Acquisition is a separate CLI."""

import argparse
from collections import Counter, defaultdict
from datetime import datetime
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools.lang.calibrate import calibrate_bucket, evaluate_rows, exact_gate
from tools.lang.prepare_corpus import (BUCKETS, LENGTH_AUGMENTATIONS, SPLITS, TABLE_PATH, _validate_config,
    json_bytes, prepare, read_json, sha_file, validate_snapshot_skew)
from tools.lang.reference import Scorer, UnicodeData, detect_document, export_profiles

RESOURCES = TABLE_PATH.parent
ARTIFACT_NAME = "lang-detector-v1.json"
MANIFEST_NAME = "lang-detector-v1.manifest.json"
ARTIFACT_PATH = "Sources/AINotebookCore/Resources/Language/" + ARTIFACT_NAME
NOTICE_PATH = ROOT / "NOTICE"
BEGIN = "BEGIN AI NOTEBOOK LANGUAGE DATA"
END = "END AI NOTEBOOK LANGUAGE DATA"
TARGETS = ["cs", "de", "en", "sk"]
NEGATIVES = ["fr", "hr", "hu", "nl", "pl", "sl"]
MINIMUM_SUPPORT = {"groupsPerTarget": 200, "groupsPerNegativeLanguage": 200,
                   "acceptedTotal": 1000, "acceptedTrueCs": 100, "acceptedTrueSk": 100}
PARAMETERS = {"maxFeaturesPerProfile": [256, 1024, 4096], "orderWeights": [1, 2, 3],
              "scoreScale": 1024, "lengthBucketStarts": [12, 32, 80, 200],
              "minLetters": 12, "minWords": 3, "mixedDominanceBp": 7000,
              "inputCapScalars": 5000000, "textCapScalars": 8192, "windowCount": 8, "windowScalars": 512}
TIE_BREAK = ["minWinningScoreDescending", "minMarginDescending", "minKnownCoverageBpDescending"]
UNICODE_PINS = {
    "UnicodeData.txt": "2fc713e6a31a87c4850a37fe2caffa4218180fadb5de86b43a143ddb4581fb86",
    "CaseFolding.txt": "4e55acfdc32825a22e87670e9056a3bf94ad7c5400065778e9e10f8314372bcf",
    "DerivedNormalizationProps.txt": "8875dccee2bc1a7c1fe568a3b502a9e78c9e0495afd96b6568b4294d0ed1f7e1",
    "NormalizationTest.txt": "871238e37e3be0696ec2bd0891119a041b052da1a84485eda05a5438724b223e"}


def validate_schema(value, schema, root=None, path="$", depth=0):
    """The small, closed subset used by the two committed appendix schemas."""
    root = schema if root is None else root
    if depth > 64:
        raise ValueError(f"{path}: JSON depth exceeds 64")
    if "$ref" in schema:
        node = root
        for part in schema["$ref"].removeprefix("#/").split("/"):
            node = node[part]
        return validate_schema(value, node, root, path, depth + 1)
    if "anyOf" in schema:
        for option in schema["anyOf"]:
            try:
                validate_schema(value, option, root, path, depth + 1)
                return
            except ValueError:
                pass
        raise ValueError(f"{path}: does not match any permitted kind")
    if "const" in schema and json_bytes(value) != json_bytes(schema["const"]):
        raise ValueError(f"{path}: wrong constant")
    if "enum" in schema and not any(json_bytes(value) == json_bytes(v) for v in schema["enum"]):
        raise ValueError(f"{path}: invalid enumeration")
    kinds = {"object": dict, "array": list, "integer": int, "string": str, "null": type(None)}
    if "type" in schema and type(value) is not kinds[schema["type"]]:
        raise ValueError(f"{path}: wrong JSON kind")
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        if not set(schema.get("required", [])) <= set(value):
            raise ValueError(f"{path}: missing required properties")
        if schema.get("additionalProperties") is False and not set(value) <= set(properties):
            raise ValueError(f"{path}: unknown properties")
        for name, child in value.items():
            if name in properties:
                validate_schema(child, properties[name], root, f"{path}.{name}", depth + 1)
    elif isinstance(value, list):
        if not schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", sys.maxsize):
            raise ValueError(f"{path}: invalid array length")
        for i, child in enumerate(value):
            validate_schema(child, schema.get("items", {}), root, f"{path}[{i}]", depth + 1)
    elif isinstance(value, str):
        if any(0xD800 <= ord(c) <= 0xDFFF for c in value):
            raise ValueError(f"{path}: unpaired surrogate")
        if len(value) < schema.get("minLength", 0) or ("pattern" in schema and re.search(schema["pattern"], value) is None):
            raise ValueError(f"{path}: invalid string")
    elif type(value) is int:
        if not schema.get("minimum", -sys.maxsize) <= value <= schema.get("maximum", sys.maxsize):
            raise ValueError(f"{path}: integer out of range")


def _unique(rows, fields, name):
    keys = [tuple(row[f] for f in fields) for row in rows]
    if len(set(keys)) != len(keys):
        raise ValueError(f"duplicate {name} compound key")
    return set(keys)


def validate_config(config):
    _validate_config(config)
    expected = {"sourceId", "modelId", "targets", "negativeLanguages", "languageMappings", "seed", "splitBp",
                "maxComponentMembers", "caps", "augmentation", "parameters", "licenseIds", "minimumSupport", "calibration"}
    if set(config) - {"maxSnapshotSkewBp"} != expected:
        raise ValueError("unknown/missing training config properties")
    if config["sourceId"] != "tatoeba" or config["targets"] != TARGETS or config["negativeLanguages"] != NEGATIVES:
        raise ValueError("v1 requires the ten reviewed languages")
    mappings = {r["sourceLanguage"]: r["detectorLanguage"] for r in config["languageMappings"]}
    if mappings != dict(zip(["ces", "deu", "eng", "slk", "fra", "hrv", "hun", "nld", "pol", "slv"], TARGETS + NEGATIVES)):
        raise ValueError("unexpected source language mapping")
    if json_bytes(config["parameters"]) != json_bytes(PARAMETERS) or json_bytes(config["minimumSupport"]) != json_bytes(MINIMUM_SUPPORT):
        raise ValueError("production constants/minimum support cannot be changed")
    if set(config["licenseIds"]) != {"CC0-1.0", "CC-BY-2.0-FR"} or len(config["licenseIds"]) != 2:
        raise ValueError("unreviewed corpus license selection")
    calibration = config["calibration"]
    if set(calibration) != {"algorithm", "candidates", "tieBreak"} or calibration["algorithm"] != "grid-max-accepted-v1" or calibration["tieBreak"] != TIE_BREAK:
        raise ValueError("invalid calibration policy")
    if [r["bucketStart"] for r in calibration["candidates"]] != list(BUCKETS[1:]):
        raise ValueError("calibration must cover four ordered buckets")
    for row in calibration["candidates"]:
        if set(row) != {"bucketStart", "minWinningScores", "minMargins", "minKnownCoverageBp"}:
            raise ValueError("invalid calibration candidate properties")
        for name, lo, hi in (("minWinningScores", -7000000, 0), ("minMargins", 1, 7000000), ("minKnownCoverageBp", 0, 10000)):
            values = row[name]
            if not values or any(type(v) is not int or not lo <= v <= hi for v in values) or values != sorted(set(values)):
                raise ValueError("candidate arrays must be sorted, unique, valid integers")


def load_wp1(path):
    snapshot = read_json(path)
    if set(snapshot) != {"contract", "version", "sourceRevision", "snapshotDate", "documents"} or snapshot["contract"] != "wp1-detector-documents" or type(snapshot["version"]) is not int or snapshot["version"] != 1:
        raise ValueError("invalid WP1 snapshot envelope")
    if re.fullmatch(r"[0-9a-f]{40,64}", snapshot["sourceRevision"]) is None:
        raise ValueError("invalid WP1 source revision")
    datetime.strptime(snapshot["snapshotDate"], "%Y-%m-%d")
    if not isinstance(snapshot["documents"], list) or not snapshot["documents"]:
        raise ValueError("WP1 snapshot must contain held-out documents")
    _unique(snapshot["documents"], ["sourceId", "documentId"], "WP1 documents")
    for row in snapshot["documents"]:
        if set(row) != {"documentId", "sourceId", "goldLabel", "sha256", "encoding", "text", "licenseId", "translationGroupId", "url"}:
            raise ValueError("unknown/missing WP1 document property")
        if row["goldLabel"] not in TARGETS + ["mixed", "und"] or row["encoding"] not in ("utf-8", "windows-1250"):
            raise ValueError("invalid WP1 label/encoding")
        if not row["url"].startswith("https://") or not row["licenseId"] or not row["translationGroupId"]:
            raise ValueError("missing WP1 provenance")
        if row["url"].startswith("https://raw.githubusercontent.com/"):
            components = row["url"].removeprefix("https://raw.githubusercontent.com/").split("/")
            if len(components) < 4 or components[2] != snapshot["sourceRevision"]:
                raise ValueError("WP1 source URL revision mismatch")
        raw = row["text"].encode("cp1250" if row["encoding"] == "windows-1250" else "utf-8", errors="strict")
        if hashlib.sha256(raw).hexdigest() != row["sha256"]:
            raise ValueError("WP1 snapshot text SHA-256 mismatch")
    return snapshot


def iter_examples(path, split=None):
    with Path(path).open(encoding="utf-8") as stream:
        for line in stream:
            row = json.loads(line)
            if split is not None:
                if SPLITS.index(row["split"]) > SPLITS.index(split):
                    break
                if row["split"] != split:
                    continue
            yield row


def _training_rows(path, profile):
    for row in iter_examples(path, "train"):
        if row["language"] == profile or (profile == "background" and row["language"] in NEGATIVES):
            yield row


def _score_rows(path, split, scorer):
    for row in iter_examples(path, split):
        result = scorer.score(row["normalizedScalars"][:PARAMETERS["textCapScalars"]])
        yield {"truth": row["language"], "originalGroupId": row["originalGroupId"], "split": split,
               "recordKey": row["recordKey"], "rule": row["rule"], "length": row["length"],
               "winner": result["winner"], "winningScore": result["profiles"][result["winner"]]["combinedScore"],
               "margin": result["margin"], "coverageBp": result["coverageBp"], "letterCount": result["letterCount"],
               "wordCount": result["wordCount"], "bucketStart": result["bucketStart"] or 0}


def _contributor(value):
    value = (value or "").strip()
    return "(no contributor supplied)" if value in ("", "\\N") else value


def _attribution_data(examples, snapshot, provenance):
    """Compact attribution: aggregated usernames plus a hash-pinned sentence ledger.

    Per-sentence identities live in prepare_corpus.py's selected-sentences.tsv,
    which is reproducible from the pinned exports and referenced here by count
    and SHA-256 instead of one line per sentence.
    """
    contributors = defaultdict(Counter)
    for row in iter_examples(examples):
        if row["rule"] == "original":
            contributors[row["sourceId"], row["licenseId"]][_contributor(row["contributor"])] += 1
    selected = provenance["selectedSentences"]
    total = sum(sum(counter.values()) for counter in contributors.values())
    if selected["records"] != total:
        raise ValueError("selected sentence ledger does not match the selected originals")
    by_license = Counter()
    for (_, license_id), counter in contributors.items():
        by_license[license_id] += sum(counter.values())
    lines = ["# AI Notebook language data attribution", "",
        "The exported language detector weights are derived data computed from sentences of the",
        "Tatoeba collection (https://tatoeba.org), selected for the train, validation and test splits.",
        "Prefix, strip-marks and concat-v1 examples reuse only these selected sentences.", "",
        "Each Tatoeba sentence keeps its own license:", "",
        "- CC BY 2.0 FR (CC-BY-2.0-FR), https://creativecommons.org/licenses/by/2.0/fr/ — every selected",
        "  sentence absent from the same-snapshot CC0 export; credited to the contributors listed below.",
        "- CC0 1.0 (CC0-1.0), https://creativecommons.org/publicdomain/zero/1.0/ — sentences listed in",
        "  the same-snapshot CC0 export.", "",
        "## Pinned Tatoeba snapshot", "",
        f"Export snapshot: {provenance['snapshotDate']}", ""]
    for entry in provenance["files"]:
        lines.append(f"- {entry['url']} — compressed SHA-256 `{entry['sha256']}`; uncompressed `{entry['uncompressedSha256']}`")
    lines.extend(["", "## Selected sentences", "",
        f"Selected original sentences: {total} ("
        + "; ".join(f"{license_id}: {count}" for license_id, count in sorted(by_license.items())) + ")", "",
        f"The full list is the ledger `{selected['path']}` with {selected['records']} lines and",
        f"SHA-256 `{selected['sha256']}`. Each LF-terminated line is",
        "`sentenceId<TAB>language<TAB>licenseId<TAB>username`, ordered by numeric sentence ID; sentence",
        "`N` is https://tatoeba.org/en/sentences/show/N. Regenerate it offline from the pinned exports",
        "(the hashes above) with the committed lock and training configuration:", "",
        "```bash",
        "python3 -B tools/lang/prepare_corpus.py --data-dir <pinned exports> \\",
        "  --lock tools/lang/tatoeba-v1.lock.json --config tools/lang/training-v1.json \\",
        "  --output-dir <prepared>",
        f"shasum -a 256 <prepared>/{selected['path']}",
        "```"])
    for (source, license_id), counter in sorted(contributors.items()):
        lines.extend(["", f"## Contributors: {source} / {license_id}", "",
                      f"{len(counter)} unique usernames with selected sentence counts, most first, ties by username:", ""])
        lines.extend(f"- {name}: {count}" for name, count in
                     sorted(counter.items(), key=lambda item: (-item[1], item[0].encode("utf-8"))))
    lines.extend(["", "## Owned held-out documents", "",
        "These documents do not contribute to features, calibration or text support. Each declared",
        "translationGroupId is preserved; questions and derived excerpts inherit that group.", ""])
    for row in snapshot["documents"]:
        lines.append(f"- {row['sourceId']} / {row['documentId']} / {row['licenseId']} / group {row['translationGroupId']}: "
                     f"{row['url']} — original SHA-256 `{row['sha256']}`")
    lines.extend(["", "## Unicode 15.1.0 — Unicode-3.0", "", (RESOURCES / "UNICODE-LICENSE.txt").read_text(encoding="utf-8").rstrip(), ""])
    attribution = "\n".join(lines).encode("utf-8")
    source_ids = {key[0] for key in contributors} | {r["sourceId"] for r in snapshot["documents"]}
    license_ids = {key[1] for key in contributors} | {r["licenseId"] for r in snapshot["documents"]} | {"Unicode-3.0"}
    return attribution, sorted(source_ids), sorted(license_ids)


def _attribution(examples, snapshot, provenance):
    attribution, source_ids, license_ids = _attribution_data(examples, snapshot, provenance)
    original = NOTICE_PATH.read_text(encoding="utf-8")
    if original.count(BEGIN) != original.count(END) or original.count(BEGIN) > 1:
        raise ValueError("malformed generated NOTICE section")
    generated = (BEGIN + "\nLanguage detector weights are derived from attributed Tatoeba data and pinned Unicode tables.\n"
                 "Tatoeba sentences: CC0-1.0 or CC-BY-2.0-FR; contributor IDs and snapshot hashes: tools/lang/ATTRIBUTION.md.\n"
                 "Owned held-out examples retain their declared licenses (MIT for multilingual-v1).\n"
                 "Unicode 15.1.0 data: Unicode-3.0.\n\n" +
                 (RESOURCES / "UNICODE-LICENSE.txt").read_text(encoding="utf-8").rstrip() + "\n" + END + "\n")
    if BEGIN in original:
        start, end = original.index(BEGIN), original.index(END) + len(END)
        if end < start:
            raise ValueError("malformed generated NOTICE section order")
        if original[end:end + 1] == "\n":
            end += 1
        notice = original[:start] + generated + original[end:]
    else:
        notice = original + ("" if original.endswith("\n\n") else "\n" if original.endswith("\n") else "\n\n") + generated
    return attribution, notice.encode("utf-8"), {"sourceIds": source_ids, "licenseIds": license_ids,
        "attributionPath": "tools/lang/ATTRIBUTION.md", "attributionSha256": hashlib.sha256(attribution).hexdigest(),
        "noticePath": "NOTICE", "noticeSha256": hashlib.sha256(notice.encode("utf-8")).hexdigest()}


def _corpus(provenance, snapshot):
    # Source record count means selected originals; file records describe raw exports.
    corpus = [{"id": provenance["sourceId"], "files": [
        {"role": {"base": "sentences", "sentences": "sentences", "links": "links", "cc0": "attribution"}[r["role"]],
         "url": r["url"], "snapshotDate": provenance["snapshotDate"], "sha256": r["sha256"],
         "formatVersion": r["formatVersion"], "records": r["records"]} for r in provenance["files"]],
        "licenseIds": ["CC-BY-2.0-FR", "CC0-1.0"],
        "licenseSelectionPolicy": "CC0 IDs from the matching snapshot; otherwise CC-BY-2.0-FR with nonmissing owner; exclude unknown licenses",
        "languageSelectionPolicy": "explicit source-language mappings only; filter after global translation grouping",
        "deduplicationPolicy": provenance["deduplicationPolicy"],
        "translationGroupPolicy": "all global base IDs and link endpoints; components before filtering; blocks retain original split",
        "originalRecords": sum(r["originals"] for r in provenance["counts"]),
        "languageMappings": provenance["languageMappings"]}]
    for source in sorted({r["sourceId"] for r in snapshot["documents"]}):
        docs = [r for r in snapshot["documents"] if r["sourceId"] == source]
        codes = sorted({"mul" if r["goldLabel"] == "mixed" else r["goldLabel"] for r in docs})
        corpus.append({"id": source, "files": [{"role": "ownedExamples", "url": r["url"],
            "snapshotDate": snapshot["snapshotDate"], "sha256": r["sha256"], "formatVersion": "wp1-detector-documents-v1", "records": 1} for r in docs],
            "licenseIds": sorted({r["licenseId"] for r in docs}), "licenseSelectionPolicy": "preserve declared owned-document license",
            "languageSelectionPolicy": "declared gold labels; mixed represented by mul in mappings only",
            "deduplicationPolicy": "none; independently authored document IDs",
            "translationGroupPolicy": "declared translationGroupId; whole source held out from training/calibration/text support",
            "originalRecords": len(docs), "languageMappings": [{"sourceLanguage": code, "detectorLanguage": code} for code in codes]})
    return corpus


def _unicode_files():
    sources = read_json(RESOURCES / "unicode-sources-v1.json")
    if {r["name"]: r["sha256"] for r in sources["files"]} != UNICODE_PINS:
        raise ValueError("Unicode source pins changed")
    return [{"role": "normalizationTest" if r["name"] == "NormalizationTest.txt" else "unicodeData",
        "url": r["url"], "snapshotDate": sources["license"]["retrievedAt"], "sha256": r["sha256"],
        "formatVersion": "Unicode-15.1.0", "records": 0} for r in sources["files"]]


def _support_pass(result):
    return (all(r["originalGroups"] >= 200 for r in result["support"].values()) and
            result["acceptedTotal"] >= 1000 and result["acceptedTrueCs"] >= 100 and result["acceptedTrueSk"] >= 100)


def _metrics(rows, thresholds):
    support, metrics, gate_rows = [], [], []
    for split in ("validation", "test"):
        for bucket in BUCKETS:
            selected = [r for r in rows[split] if r["bucketStart"] == bucket]
            threshold = next((t for t in thresholds if t["start"] == bucket),
                             {"start": 0, "enabled": 0, "minWinningScore": -120000, "minMargin": 1, "minKnownCoverageBp": 0})
            evaluated = evaluate_rows(selected, threshold, TARGETS, NEGATIVES)
            if bucket:
                support.extend({"split": split, "bucketStart": bucket, "language": language, **r}
                               for language, r in evaluated["support"].items())
                gate_rows.append({"split": split, "bucketStart": bucket, "enabled": threshold["enabled"],
                    "supportPass": _support_pass(evaluated), **evaluated["metrics"]})
            for language in ["all"] + sorted(TARGETS + NEGATIVES):
                result = evaluated if language == "all" else evaluate_rows(
                    [r for r in selected if r["truth"] == language], threshold, TARGETS, NEGATIVES)
                metrics.extend({"split": split, "bucketStart": bucket, "language": language, "name": name, **m}
                               for name, m in result["metrics"].items())
    return support, metrics, gate_rows


def _command_arguments(lock_path, config_path, wp1_documents, created_at, exporter_commit):
    return ["--data-dir", "$DATA", "--lock", "$LOCK", "--config", "$CONFIG", "--output-dir", "$OUTPUT",
            "--wp1-documents", "$WP1", "--wp1-snapshot-sha256", sha_file(wp1_documents),
            "--config-sha256", sha_file(config_path), "--lock-sha256", sha_file(lock_path),
            "--created-at", created_at, "--exporter-commit", exporter_commit]


def _disabled_buckets(calibrated):
    return [{"bucketStart": row["threshold"]["start"], "reason": row["reason"]}
            for row in calibrated if not row["threshold"]["enabled"]]


def _document_results(snapshot, model, tables):
    counts, predictions = Counter(), []
    for row in snapshot["documents"]:
        predicted = detect_document(row["text"], model, tables)
        counts[row["sourceId"], row["goldLabel"], predicted["label"]] += 1
        predictions.append({"documentId": row["documentId"], "sourceId": row["sourceId"],
                            "goldLabel": row["goldLabel"], "expected": predicted})
    metrics = [{"sourceId": source, "goldLabel": gold, "predictedLabel": predicted, "count": count}
               for (source, gold, predicted), count in sorted(counts.items())]
    return metrics, predictions


def _training_report(manifest, provenance, calibrated, gate_rows, document_predictions, thresholds):
    arguments = manifest["environment"]["commandArguments"]
    report = {"contract": "language-training-report", "version": 1,
        "artifactSha256": manifest["artifactSha256"],
        **{name: arguments[arguments.index(flag) + 1] for name, flag in (
            ("configSha256", "--config-sha256"), ("lockSha256", "--lock-sha256"),
            ("wp1SnapshotSha256", "--wp1-snapshot-sha256"))},
        "preparation": provenance, "calibrationDiagnostics": calibrated, "gateRows": gate_rows,
        "enabledBuckets": [threshold["start"] for threshold in thresholds if threshold["enabled"]],
        "documentPredictions": document_predictions}
    report["readiness"] = ("NO_ENABLED_BUCKETS: usefulness review required" if not report["enabledBuckets"] else
        "held-out support/error failure" if any(row["enabled"] and (not row["supportPass"] or
            any(not exact_gate(row[name]["numerator"], row[name]["denominator"], bp)
                for name, bp in (("acceptedError", 200), ("csSkConfusion", 100), ("foreignAcceptance", 100))))
            for row in gate_rows) else "release evaluation and native parity required")
    return report


def validate_outputs(artifact, manifest, attribution_bytes, notice_bytes, tables):
    for name, value in (("artifact", artifact), ("manifest", manifest)):
        validate_schema(value, read_json(ROOT / "tools/lang/schemas" / f"{name}-v1.schema.json"))
    if "snapshotSkew" in manifest:
        validate_snapshot_skew(manifest["snapshotSkew"])
    if artifact["kind"] != "production" or artifact["targets"] != TARGETS or artifact["parameters"] != PARAMETERS:
        raise ValueError("invalid production parameters")
    if manifest["modelId"] != artifact["modelId"] or manifest["artifactPath"] != ARTIFACT_PATH:
        raise ValueError("artifact/manifest identity mismatch")
    if manifest["attribution"] != artifact["attribution"]:
        raise ValueError("attribution mismatch")
    attribution = artifact["attribution"]
    if attribution["attributionPath"] != "tools/lang/ATTRIBUTION.md" or attribution["noticePath"] != "NOTICE":
        raise ValueError("invalid attribution paths")
    if not attribution["sourceIds"] or not attribution["licenseIds"]:
        raise ValueError("production attribution must be nonempty")
    if hashlib.sha256(attribution_bytes).hexdigest() != attribution["attributionSha256"] or hashlib.sha256(notice_bytes).hexdigest() != attribution["noticeSha256"]:
        raise ValueError("attribution/NOTICE SHA-256 mismatch")
    if [v["order"] for v in artifact["vocabulary"]] != [1, 2, 3] or [p["id"] for p in artifact["profiles"]] != ["background"] + TARGETS:
        raise ValueError("unordered vocabulary/profiles")
    for n, vocab in enumerate(artifact["vocabulary"], 1):
        tuples = [tuple(f) for f in vocab["features"]]
        if tuples != sorted(set(tuples)) or len(tuples) > 5 * PARAMETERS["maxFeaturesPerProfile"][n - 1]:
            raise ValueError("invalid vocabulary order/size")
        for f in tuples:
            if len(f) != n or f.count(-1) > 1 or f.count(-2) > 1 or (-1 in f and f[0] != -1) or (-2 in f and f[-1] != -2):
                raise ValueError("invalid feature boundaries/length")
            interior = [cp for cp in f if cp >= 0]
            if (not interior and n != 1) or any(not tables.category(cp).startswith(("L", "M")) for cp in interior):
                raise ValueError("feature is not a letter/attached mark")
            if f[0] == -1 and interior and tables.category(interior[0]).startswith("M"):
                raise ValueError("BOS cannot attach a leading mark")
    for profile in artifact["profiles"]:
        if profile["priorWeight"] != -1648 or [o["order"] for o in profile["orders"]] != [1, 2, 3]:
            raise ValueError("invalid prior/order")
        if any(len(o["weights"]) != len(v["features"]) for o, v in zip(profile["orders"], artifact["vocabulary"])):
            raise ValueError("misaligned weights")
    if [t["start"] for t in artifact["thresholds"]] != list(BUCKETS[1:]) or any(t["enabled"] and t["minMargin"] < 1 for t in artifact["thresholds"]):
        raise ValueError("invalid thresholds")
    datetime.strptime(manifest["createdAt"], "%Y-%m-%dT%H:%M:%SZ")
    if manifest["negativeLanguages"] != NEGATIVES or manifest["minimumSupport"] != MINIMUM_SUPPORT:
        raise ValueError("invalid language/support policy")
    if sum(manifest["split"]["splitBp"].values()) != 10000:
        raise ValueError("invalid split basis points")
    for corpus in manifest["corpus"]:
        for f in corpus["files"]:
            datetime.strptime(f["snapshotDate"], "%Y-%m-%d")
        _unique(corpus["languageMappings"], ["sourceLanguage"], "source mappings")
    _unique(manifest["corpus"], ["id"], "corpus IDs")
    if not set(attribution["sourceIds"]) <= {r["id"] for r in manifest["corpus"]}:
        raise ValueError("unknown attribution source")
    unicode_files = manifest["environment"]["unicodeFiles"]
    if unicode_files != _unicode_files():
        raise ValueError("Unicode provenance mismatch")
    languages = sorted(TARGETS + NEGATIVES)
    if _unique(manifest["caps"], ["split", "language"], "caps") != {(s, l) for s in SPLITS for l in languages}:
        raise ValueError("incomplete caps")
    if _unique(manifest["counts"], ["split", "language", "bucketStart"], "counts") != {(s, l, b) for s in SPLITS for l in languages for b in BUCKETS}:
        raise ValueError("incomplete counts")
    if _unique(manifest["support"], ["split", "language", "bucketStart"], "support") != {(s, l, b) for s in ("validation", "test") for l in languages for b in BUCKETS[1:]}:
        raise ValueError("incomplete support")
    count_index = {(r["split"], r["language"], r["bucketStart"]): r for r in manifest["counts"]}
    for row in manifest["counts"]:
        if row["originalGroups"] > row["originals"] + row["augmented"]:
            raise ValueError("original group count exceeds evaluated examples")
    for cap in manifest["caps"]:
        if sum(count_index[cap["split"], cap["language"], b]["originals"] for b in BUCKETS) > cap["maxOriginalRecords"]:
            raise ValueError("selected originals exceed their language/split cap")
    corpus_index = {row["id"]: row for row in manifest["corpus"]}
    if "tatoeba" not in corpus_index or corpus_index["tatoeba"]["originalRecords"] != sum(row["originals"] for row in manifest["counts"]):
        raise ValueError("corpus original total does not reconcile with counts")
    for r in manifest["support"]:
        counts = count_index[r["split"], r["language"], r["bucketStart"]]
        if r["originalGroups"] != counts["originalGroups"] or r["evaluated"] != counts["originals"] + counts["augmented"] or r["accepted"] > r["evaluated"]:
            raise ValueError("support/count reconciliation failed")
    names = ("acceptedError", "csSkConfusion", "foreignAcceptance", "acceptanceCoverage")
    if _unique(manifest["metrics"], ["split", "language", "bucketStart", "name"], "metrics") != {
            (s, l, b, n) for s in ("validation", "test") for l in ["all"] + languages for b in BUCKETS for n in names}:
        raise ValueError("incomplete metrics")
    for r in manifest["metrics"]:
        n, d = r["numerator"], r["denominator"]
        if n > d or r["rateBp"] != (10000 * n // d if d else None):
            raise ValueError("invalid metric arithmetic")
    support_index = {(r["split"], r["language"], r["bucketStart"]): r for r in manifest["support"]}
    metric_index = {(r["split"], r["language"], r["bucketStart"], r["name"]): r for r in manifest["metrics"]}
    for split in ("validation", "test"):
        for bucket in BUCKETS:
            for language in languages:
                key = split, language, bucket
                counts = count_index[key]
                evaluated = counts["originals"] + counts["augmented"]
                accepted = support_index[key]["accepted"] if bucket else 0
                expected = {"acceptedError": (None, accepted),
                    "csSkConfusion": (None if language in ("cs", "sk") else 0,
                                      accepted if language in ("cs", "sk") else 0),
                    "foreignAcceptance": (accepted if language in NEGATIVES else 0,
                                          evaluated if language in NEGATIVES else 0),
                    "acceptanceCoverage": (accepted, evaluated)}
                for name, (numerator, denominator) in expected.items():
                    row = metric_index[key + (name,)]
                    if row["denominator"] != denominator or (numerator is not None and row["numerator"] != numerator):
                        raise ValueError("metric/count/support reconciliation failed")
            for name in names:
                aggregate = metric_index[split, "all", bucket, name]
                if any(aggregate[field] != sum(metric_index[split, language, bucket, name][field] for language in languages)
                       for field in ("numerator", "denominator")):
                    raise ValueError("aggregate/per-language metrics do not reconcile")
    for name, fields in (("exclusions", ["sourceId", "split", "language", "reason"]),
                         ("documentMetrics", ["sourceId", "goldLabel", "predictedLabel"]),
                         ("augmentation", ["algorithm"])):
        _unique(manifest[name], fields, name)
    algorithms = [r["algorithm"] for r in manifest["augmentation"]]
    if "none-v1" in algorithms and len(algorithms) != 1:
        raise ValueError("none-v1 must stand alone")
    outputs_per_original = Counter()
    for rule in manifest["augmentation"]:
        if len(set(rule["splits"])) != len(rule["splits"]):
            raise ValueError("duplicate augmentation split")
        if rule["algorithm"] in LENGTH_AUGMENTATIONS:
            if not rule["lengths"] or rule["lengths"] != sorted(set(rule["lengths"])):
                raise ValueError("invalid augmentation lengths")
        elif rule["lengths"]:
            raise ValueError("only prefix/concatenation augmentation accepts lengths")
        if rule["inputCount"] != sum(row["originals"] for row in manifest["counts"] if row["split"] in rule["splits"]):
            raise ValueError("augmentation inputs do not reconcile with selected originals")
        # Prefix and concat-v1 emit at most one example per original (anchor) and length.
        multiplier = len(rule["lengths"]) if rule["algorithm"] in LENGTH_AUGMENTATIONS else int(rule["algorithm"] == "strip-marks-v1")
        if rule["outputCount"] > rule["inputCount"] * multiplier:
            raise ValueError("augmentation outputs exceed possible derived examples")
        for split in rule["splits"]:
            outputs_per_original[split] += multiplier
    if sum(rule["outputCount"] for rule in manifest["augmentation"]) != sum(row["augmented"] for row in manifest["counts"]):
        raise ValueError("augmentation outputs do not reconcile with counts")
    for split in SPLITS:
        for language in languages:
            rows = [count_index[split, language, b] for b in BUCKETS]
            if sum(r["augmented"] for r in rows) > sum(r["originals"] for r in rows) * outputs_per_original[split]:
                raise ValueError("augmented counts exceed the rules active for their split and language")
    _unique(manifest["calibration"]["disabledBuckets"], ["bucketStart"], "disabled buckets")
    candidates = manifest["calibration"]["candidates"]
    if [r["bucketStart"] for r in candidates] != list(BUCKETS[1:]):
        raise ValueError("invalid calibration candidate bucket order")
    for row in candidates:
        for field in ("minWinningScores", "minMargins", "minKnownCoverageBp"):
            if row[field] != sorted(set(row[field])):
                raise ValueError("invalid calibration candidate ordering")
    disabled = {r["bucketStart"] for r in manifest["calibration"]["disabledBuckets"]}
    if disabled != {r["start"] for r in artifact["thresholds"] if not r["enabled"]}:
        raise ValueError("disabled thresholds/provenance disagree")


def train(data_dir: Path, lock_path: Path, config_path: Path, output_dir: Path,
          wp1_documents: Path, created_at: str, exporter_commit: str) -> dict:
    lock, config = read_json(lock_path), read_json(config_path)
    validate_config(config)
    datetime.strptime(created_at, "%Y-%m-%dT%H:%M:%SZ")
    if re.fullmatch(r"[0-9a-f]{40,64}", exporter_commit) is None:
        raise ValueError("invalid exporter revision")
    snapshot = load_wp1(wp1_documents)
    tables = UnicodeData.load(TABLE_PATH)
    output_dir = Path(output_dir)
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ainotebook-lang-train-", dir=output_dir.parent) as temporary:
        work = Path(temporary)
        provenance = prepare(data_dir, lock, config, work / "prepared")
        examples = work / "prepared/examples.jsonl"
        profiles = export_profiles({p: _training_rows(examples, p) for p in ["background"] + TARGETS},
                                   PARAMETERS["maxFeaturesPerProfile"], tables)
        model = {"contract": "lang-detector", "version": 1, "kind": "production", "modelId": config["modelId"],
                 "targets": TARGETS, "normalizationTablesVersion": "ucd-15.1.0-default-full-v1", "alpha": 1,
                 "parameters": PARAMETERS, **profiles,
                 "thresholds": [{"start": b, "enabled": 1, "minWinningScore": -7000000, "minMargin": 1,
                                 "minKnownCoverageBp": 0} for b in BUCKETS[1:]]}
        scorer = Scorer(model, tables)
        validation = list(_score_rows(examples, "validation", scorer))
        calibrated = [calibrate_bucket([r for r in validation if r["bucketStart"] == c["bucketStart"]], c, TARGETS, NEGATIVES)
                      for c in config["calibration"]["candidates"]]
        model["thresholds"] = [r["threshold"] for r in calibrated]
        # Thresholds are now frozen. No test or owned-document truth is used above.
        test = list(_score_rows(examples, "test", scorer))
        support, metrics, gate_rows = _metrics({"validation": validation, "test": test}, model["thresholds"])
        document_metrics, document_predictions = _document_results(snapshot, model, tables)
        attribution, notice, links = _attribution(examples, snapshot, provenance)
        model["attribution"] = links
        artifact_bytes = json_bytes(model)
        arguments = _command_arguments(lock_path, config_path, wp1_documents, created_at, exporter_commit)
        manifest = {"contract": "lang-detector-manifest", "version": 1, "modelId": model["modelId"],
            "artifactPath": ARTIFACT_PATH, "artifactSha256": hashlib.sha256(artifact_bytes).hexdigest(), "createdAt": created_at,
            "corpus": _corpus(provenance, snapshot), "negativeLanguages": NEGATIVES,
            "snapshotSkew": provenance["snapshotSkew"],
            "environment": {"exporterGitCommit": exporter_commit, "commandArguments": arguments,
                "pythonVersion": platform.python_version(), "dependencies": [],
                "normalizationTablesVersion": model["normalizationTablesVersion"], "unicodeFiles": _unicode_files()},
            "split": {**provenance["split"], "oversizedComponents": provenance["oversizedComponents"]},
            "caps": provenance["caps"], "augmentation": provenance["augmentation"], "counts": provenance["counts"],
            "exclusions": provenance["exclusions"], "minimumSupport": MINIMUM_SUPPORT,
            "calibration": {**config["calibration"], "disabledBuckets": _disabled_buckets(calibrated)},
            "support": support, "metrics": metrics,
            "documentMetrics": document_metrics, "attribution": links}
        validate_outputs(model, manifest, attribution, notice, tables)
        report = _training_report(manifest, provenance, calibrated, gate_rows, document_predictions, model["thresholds"])
        outputs = {ARTIFACT_NAME: artifact_bytes, MANIFEST_NAME: json_bytes(manifest), "ATTRIBUTION.md": attribution,
                   "NOTICE": notice, "support-report.json": json_bytes(report)}
        # The global graph can dwarf the selected training corpus; retain its
        # assignment provenance without loading the entire JSONL into memory.
        shutil.copyfile(work / "prepared/groups.jsonl", work / "groups.jsonl")
        output_dir.mkdir(parents=True, exist_ok=True)
        for name, raw in outputs.items():
            (work / name).write_bytes(raw)
            (work / name).replace(output_dir / name)
        (work / "groups.jsonl").replace(output_dir / "groups.jsonl")
        return report


def verify_only(data_dir, lock_path, config_path, output_dir, wp1_documents, created_at, exporter_commit):
    """Read-only checks; never reconstruct or append the generated NOTICE section."""
    config, lock = read_json(config_path), read_json(lock_path)
    validate_config(config)
    snapshot = load_wp1(wp1_documents)
    output_dir = Path(output_dir)
    artifact, manifest = read_json(output_dir / ARTIFACT_NAME), read_json(output_dir / MANIFEST_NAME)
    for name in (ARTIFACT_NAME, MANIFEST_NAME, "NOTICE", "ATTRIBUTION.md"):
        raw = (output_dir / name).read_bytes()
        if not raw.endswith(b"\n") or raw.startswith(b"\xef\xbb\xbf"):
            raise ValueError(f"{name}: expected UTF-8 without BOM, final LF")
        raw.decode("utf-8", errors="strict")
    if sha_file(output_dir / ARTIFACT_NAME) != manifest["artifactSha256"]:
        raise ValueError("artifact SHA-256 mismatch")
    tables = UnicodeData.load(TABLE_PATH)
    validate_outputs(artifact, manifest, (output_dir / "ATTRIBUTION.md").read_bytes(), (output_dir / "NOTICE").read_bytes(), tables)
    expected_arguments = _command_arguments(lock_path, config_path, wp1_documents, created_at,
                                           manifest["environment"]["exporterGitCommit"])
    if manifest["environment"]["commandArguments"] != expected_arguments:
        raise ValueError("semantic command argument provenance mismatch")
    if manifest["environment"]["dependencies"]:
        raise ValueError("stdlib-only exporter cannot declare external dependencies")
    if manifest["createdAt"] != created_at or artifact["modelId"] != config["modelId"]:
        raise ValueError("model/timestamp provenance mismatch")
    with tempfile.TemporaryDirectory(prefix="ainotebook-lang-verify-") as temporary:
        work = Path(temporary)
        provenance = prepare(data_dir, lock, config, work)
        group_path = output_dir / provenance["splitAssignments"]["path"]
        report_path = output_dir / "support-report.json"
        # Runtime resource copies intentionally contain just the artifact,
        # manifest, attribution and NOTICE. Developer exports carry both
        # diagnostics files, and neither may silently disappear from that pair.
        if report_path.exists() or group_path.exists():
            if not report_path.is_file():
                raise ValueError("missing support report for group assignments")
            if not group_path.is_file() or sha_file(group_path) != provenance["splitAssignments"]["sha256"]:
                raise ValueError("group assignment provenance mismatch")
        for name in ("caps", "augmentation", "counts", "exclusions"):
            if manifest[name] != provenance[name]:
                raise ValueError(f"{name} provenance mismatch")
        skew = provenance["snapshotSkew"]
        if "snapshotSkew" in manifest:
            if manifest["snapshotSkew"] != skew:
                raise ValueError("snapshotSkew provenance mismatch")
        elif skew["missingFromBase"] or skew["cc0DetailMismatch"]:
            raise ValueError("snapshotSkew provenance is missing")
        if manifest["corpus"] != _corpus(provenance, snapshot) or manifest["split"] != {**provenance["split"], "oversizedComponents": provenance["oversizedComponents"]}:
            raise ValueError("corpus/split provenance mismatch")
        if {k: manifest["calibration"][k] for k in ("algorithm", "candidates", "tieBreak")} != config["calibration"]:
            raise ValueError("calibration config provenance mismatch")
        expected = export_profiles({p: _training_rows(work / "examples.jsonl", p) for p in ["background"] + TARGETS},
                                   PARAMETERS["maxFeaturesPerProfile"], tables)
        if any(artifact[k] != expected[k] for k in expected):
            raise ValueError("exported weights do not reproduce training")
        expected_attribution, source_ids, license_ids = _attribution_data(work / "examples.jsonl", snapshot, provenance)
        if expected_attribution != (output_dir / "ATTRIBUTION.md").read_bytes() or artifact["attribution"]["sourceIds"] != source_ids or artifact["attribution"]["licenseIds"] != license_ids:
            raise ValueError("attribution does not cover the selected original corpus")
        notice = (output_dir / "NOTICE").read_text(encoding="utf-8")
        if notice.count(BEGIN) != 1 or notice.count(END) != 1 or notice.index(BEGIN) > notice.index(END) or (RESOURCES / "UNICODE-LICENSE.txt").read_text(encoding="utf-8").strip() not in notice:
            raise ValueError("NOTICE is missing language data or Unicode licensing")
        scorer = Scorer(artifact, tables)
        validation = list(_score_rows(work / "examples.jsonl", "validation", scorer))
        calibrated = [calibrate_bucket([r for r in validation if r["bucketStart"] == c["bucketStart"]], c, TARGETS, NEGATIVES)
                      for c in config["calibration"]["candidates"]]
        if artifact["thresholds"] != [r["threshold"] for r in calibrated]:
            raise ValueError("thresholds do not reproduce validation calibration")
        if manifest["calibration"]["disabledBuckets"] != _disabled_buckets(calibrated):
            raise ValueError("disabled calibration reasons do not reproduce validation")
        test = list(_score_rows(work / "examples.jsonl", "test", scorer))
        support, metrics, gates = _metrics({"validation": validation, "test": test}, artifact["thresholds"])
        if support != manifest["support"] or metrics != manifest["metrics"]:
            raise ValueError("support/metric provenance mismatch")
        document_metrics, document_predictions = _document_results(snapshot, artifact, tables)
        if document_metrics != manifest["documentMetrics"]:
            raise ValueError("document metric provenance mismatch")
        if report_path.is_file():
            expected_report = _training_report(manifest, provenance, calibrated, gates, document_predictions, artifact["thresholds"])
            recorded_report = read_json(report_path)
            if ("snapshotSkew" not in manifest and not skew["missingFromBase"] and not skew["cc0DetailMismatch"]
                    and isinstance(recorded_report, dict) and isinstance(recorded_report.get("preparation"), dict)
                    and "snapshotSkew" not in recorded_report["preparation"]):
                expected_report["preparation"] = {key: value for key, value in provenance.items() if key != "snapshotSkew"}
            if recorded_report != expected_report:
                raise ValueError("support report provenance mismatch")
    return {"artifactSha256": manifest["artifactSha256"], "exporterGitCommit": manifest["environment"]["exporterGitCommit"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("data-dir", "lock", "config", "output-dir", "wp1-documents"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--created-at", required=True)
    parser.add_argument("--exporter-commit", required=True)
    parser.add_argument("--wp1-snapshot-sha256")
    parser.add_argument("--config-sha256")
    parser.add_argument("--lock-sha256")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    for expected, path in ((args.wp1_snapshot_sha256, args.wp1_documents),
                           (args.config_sha256, args.config), (args.lock_sha256, args.lock)):
        if expected and expected != sha_file(path):
            parser.error(f"input SHA-256 mismatch: {path.name}")
    fn = verify_only if args.verify_only else train
    result = fn(args.data_dir, args.lock, args.config, args.output_dir, args.wp1_documents, args.created_at, args.exporter_commit)
    print(json.dumps({"artifactSha256": result["artifactSha256"], "status": result.get("readiness", "verified")}, sort_keys=True))


if __name__ == "__main__":
    main()
