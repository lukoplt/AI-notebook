"""Reproduce pinned Unicode 15.1 resources and shared detector fixtures offline."""

import argparse
import base64
from collections import Counter
from copy import deepcopy
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import stat
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

ARCHIVE_URL = "https://www.unicode.org/Public/zipped/15.1.0/UCD.zip"
UCD_URL = "https://www.unicode.org/Public/15.1.0/ucd/"
LICENSE_URL = "https://www.unicode.org/license.txt"
LICENSE_SHA256 = "e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96"
LICENSE_RETRIEVED_AT = "2026-10-09"
NORMALIZATION_VERSION = "ucd-15.1.0-default-full-v1"
UCD_FILES = ("UnicodeData.txt", "CaseFolding.txt", "DerivedNormalizationProps.txt", "NormalizationTest.txt")
PINNED_SHA256 = {
    "UCD.zip": "cb1c663d053926500cd501229736045752713a066bd75802098598b7a7056177",
    "UnicodeData.txt": "2fc713e6a31a87c4850a37fe2caffa4218180fadb5de86b43a143ddb4581fb86",
    "CaseFolding.txt": "4e55acfdc32825a22e87670e9056a3bf94ad7c5400065778e9e10f8314372bcf",
    "DerivedNormalizationProps.txt": "8875dccee2bc1a7c1fe568a3b502a9e78c9e0495afd96b6568b4294d0ed1f7e1",
    "NormalizationTest.txt": "871238e37e3be0696ec2bd0891119a041b052da1a84485eda05a5438724b223e",
}
CATEGORIES = frozenset("Lu Ll Lt Lm Lo Mn Mc Me Nd Nl No Pc Pd Ps Pe Pi Pf Po "
                       "Sm Sc Sk So Zs Zl Zp Cc Cf Cs Co Cn".split())


def verify_bytes(name: str, data: bytes) -> None:
    actual = hashlib.sha256(data).hexdigest()
    if actual != PINNED_SHA256[name]:
        raise ValueError(f"SHA-256 mismatch for {name}: {actual}")


def _codepoint(value: str, *, scalar: bool = False) -> int:
    if not value or any(c not in "0123456789ABCDEFabcdef" for c in value):
        raise ValueError(f"Invalid Unicode code point: {value!r}")
    cp = int(value, 16)
    if cp > 0x10FFFF or (scalar and 0xD800 <= cp <= 0xDFFF):
        raise ValueError(f"Invalid Unicode {'scalar' if scalar else 'code point'}: {value}")
    return cp


def parse_unicode_data(text: str) -> dict:
    """Read fields 2/3/5/13, preserving Cs ranges but scalar-only mappings."""
    result = {"categories": [], "ccc": [], "decomposition": [], "simpleLower": []}
    pending = None
    previous = -1

    def append_range(start, end, fields):
        category, ccc = fields[2], int(fields[3])
        categories = result["categories"]
        if category != "Cn":
            if categories and categories[-1][1] + 1 == start and categories[-1][2] == category:
                categories[-1][1] = end
            else:
                categories.append([start, end, category])
        decomposition = fields[5]
        components = ([_codepoint(x, scalar=True) for x in decomposition.split()]
                      if decomposition and not decomposition.startswith("<") else [])
        lower = _codepoint(fields[13], scalar=True) if fields[13] else None
        if components or lower is not None:
            if start <= 0xDFFF and end >= 0xD800:
                raise ValueError("Surrogate cannot have a scalar mapping")
        for cp in range(start, end + 1):
            if ccc:
                result["ccc"].append([cp, ccc])
            if components:
                result["decomposition"].append([cp, components.copy()])
            if lower is not None and lower != cp:
                result["simpleLower"].append([cp, lower])

    for line in text.splitlines():
        if not line:
            continue
        fields = line.split(";")
        if len(fields) != 15:
            raise ValueError("UnicodeData record must have 15 fields")
        cp = _codepoint(fields[0])
        if cp <= previous:
            raise ValueError("UnicodeData code points must be sorted and unique")
        previous = cp
        if fields[2] not in CATEGORIES:
            raise ValueError(f"Unknown General_Category: {fields[2]}")
        if (not fields[3] or any(c not in "0123456789" for c in fields[3])
                or not 0 <= int(fields[3]) <= 255):
            raise ValueError("Invalid canonical combining class")
        name = fields[1]
        if pending is not None:
            start, first = pending
            if (not name.endswith(", Last>")
                    or name[:-7] != first[1][:-8] or fields[2:] != first[2:]):
                raise ValueError("Mismatched UnicodeData First/Last range")
            append_range(start, cp, first)
            pending = None
        elif name.endswith(", First>"):
            pending = (cp, fields)
        elif name.endswith(", Last>"):
            raise ValueError("UnicodeData Last without First")
        else:
            append_range(cp, cp, fields)
    if pending is not None:
        raise ValueError("UnicodeData First without Last")

    decompositions = dict(result["decomposition"])
    active, done = set(), set()

    def visit(cp):
        if cp in active:
            raise ValueError("Canonical decomposition cycle")
        if cp in done:
            return
        active.add(cp)
        for component in decompositions.get(cp, []):
            visit(component)
        active.remove(cp)
        done.add(cp)

    for cp in decompositions:
        visit(cp)
    return result


def parse_case_folding(text: str) -> list:
    mappings = {}
    seen = set()
    for line in text.splitlines():
        body = line.split("#", 1)[0].strip()
        if not body:
            continue
        fields = [field.strip() for field in body.split(";")]
        if len(fields) != 4 or fields[3] or fields[1] not in ("C", "F", "S", "T"):
            raise ValueError("Invalid CaseFolding row")
        cp = _codepoint(fields[0], scalar=True)
        components = [_codepoint(value, scalar=True) for value in fields[2].split()]
        if not components:
            raise ValueError("Empty case-fold mapping")
        if fields[1] in ("C", "F"):
            if cp in seen:
                raise ValueError("Duplicate/conflicting C/F case-fold mapping")
            seen.add(cp)
            if components != [cp]:
                mappings[cp] = components
    return [[cp, mappings[cp]] for cp in sorted(mappings)]


def parse_composition_exclusions(text: str) -> list:
    exclusions = set()
    for line in text.splitlines():
        fields = [field.strip() for field in line.split("#", 1)[0].split(";")]
        if len(fields) < 2 or fields[1] != "Full_Composition_Exclusion":
            continue
        if len(fields) != 2:
            raise ValueError("Invalid Full_Composition_Exclusion row")
        bounds = fields[0].split("..")
        if len(bounds) not in (1, 2):
            raise ValueError("Invalid exclusion range")
        start, end = _codepoint(bounds[0], scalar=True), _codepoint(bounds[-1], scalar=True)
        if end < start or (start <= 0xDFFF and end >= 0xD800):
            raise ValueError("Invalid exclusion range")
        for cp in range(start, end + 1):
            if cp in exclusions:
                raise ValueError("Duplicate composition exclusion")
            exclusions.add(cp)
    return sorted(exclusions)


def json_bytes(value, *, pretty=False) -> bytes:
    return (json.dumps(value, ensure_ascii=False, allow_nan=False,
                       indent=2 if pretty else None,
                       separators=None if pretty else (",", ":")) + "\n").encode("utf-8")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix="." + path.name + ".",
                                         delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.chmod(0o644)
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def extract_archive(data: bytes, ucd_dir: Path) -> None:
    """Validate the complete inventory, then extract only the four pinned inputs."""
    verify_bytes("UCD.zip", data)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        names = set()
        for info in archive.infolist():
            name = info.filename
            path = PurePosixPath(name)
            mode = info.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if (not name or path.is_absolute() or ".." in path.parts or "\\" in name
                    or ":" in name or "\x00" in name or name in names
                    or kind not in (0, stat.S_IFREG, stat.S_IFDIR)
                    or (kind == stat.S_IFDIR and not info.is_dir())
                    or (kind == stat.S_IFREG and info.is_dir())):
                raise ValueError(f"Unsafe archive member: {name!r}")
            names.add(name)
        inputs = {}
        for name in UCD_FILES:
            if name not in names or archive.getinfo(name).is_dir():
                raise ValueError(f"Missing archive input: {name}")
            inputs[name] = archive.read(name)
            verify_bytes(name, inputs[name])
    # No extractall, filesystem paths from archive metadata, or writes before verification.
    for name, content in {"UCD.zip": data, **inputs}.items():
        atomic_write(ucd_dir / name, content)


def download(ucd_dir: Path) -> None:
    """Explicit developer acquisition; never imported/called by offline generation."""
    from urllib.request import HTTPRedirectHandler, build_opener

    class NoRedirect(HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            raise ValueError("Unicode archive redirects are not allowed")

    with build_opener(NoRedirect).open(ARCHIVE_URL, timeout=60) as response:
        data = response.read()
    extract_archive(data, ucd_dir)


def normalization_rows(data: bytes) -> list:
    rows = []
    for line in data.decode("utf-8").splitlines():
        body = line.split("#", 1)[0].strip()
        if not body or body.startswith("@"):
            continue
        fields = body.split(";")
        if len(fields) != 6 or fields[-1].strip():
            raise ValueError("Invalid NormalizationTest row")
        rows.append([[_codepoint(value, scalar=True) for value in field.split()]
                     for field in fields[:5]])
    if not rows:
        raise ValueError("No normalization conformance rows")
    return rows


def validate_source_mappings(table: dict, inputs: dict) -> None:
    """Independently reconstruct all mappings from the pinned source records."""
    categories = table["categories"]
    ccc = dict(table["ccc"])
    decompositions = dict(table["decomposition"])
    lowers = dict(table["simpleLower"])
    category_index = 0
    pending = None
    for line in inputs["UnicodeData.txt"].decode("utf-8").splitlines():
        if not line:
            continue
        fields = line.split(";")
        cp = int(fields[0], 16)
        if fields[1].endswith(", First>"):
            pending = cp
            continue
        start = cp if pending is None else pending
        pending = None
        canonical = fields[5] and not fields[5].startswith("<")
        expected_decomposition = [int(value, 16) for value in fields[5].split()] if canonical else None
        for value in range(start, cp + 1):
            while category_index < len(categories) and categories[category_index][1] < value:
                category_index += 1
            category = (categories[category_index][2] if category_index < len(categories)
                        and categories[category_index][0] <= value else "Cn")
            if (category != fields[2] or ccc.get(value, 0) != int(fields[3])
                    or decompositions.get(value) != expected_decomposition
                    or lowers.get(value, value) != (int(fields[13], 16) if fields[13] else value)):
                raise ValueError(f"UnicodeData mapping reconstruction failed at U+{value:04X}")

    # Re-read source records instead of calling the parsers again: a parser
    # dropping or changing a mapping must not silently change the shared table.
    expected_folds = {}
    for line in inputs["CaseFolding.txt"].decode("utf-8").splitlines():
        fields = [field.strip() for field in line.split("#", 1)[0].split(";")]
        if len(fields) < 3 or fields[1] not in ("C", "F"):
            continue
        cp = int(fields[0], 16)
        components = [int(value, 16) for value in fields[2].split()]
        if components != [cp]:
            expected_folds[cp] = components
    if table["caseFold"] != [[cp, parts] for cp, parts in sorted(expected_folds.items())]:
        raise ValueError("CaseFolding mapping reconstruction failed")

    expected_exclusions = set()
    for line in inputs["DerivedNormalizationProps.txt"].decode("utf-8").splitlines():
        fields = [field.strip() for field in line.split("#", 1)[0].split(";")]
        if len(fields) < 2 or fields[1] != "Full_Composition_Exclusion":
            continue
        first, separator, last = fields[0].partition("..")
        expected_exclusions.update(range(int(first, 16), int(last if separator else first, 16) + 1))
    if table["compositionExclusions"] != sorted(expected_exclusions):
        raise ValueError("Full_Composition_Exclusion reconstruction failed")


def build_unicode_outputs(inputs: dict, license_data: bytes) -> tuple:
    parsed = parse_unicode_data(inputs["UnicodeData.txt"].decode("utf-8"))
    excluded = parse_composition_exclusions(inputs["DerivedNormalizationProps.txt"].decode("utf-8"))
    excluded_set = set(excluded)
    composition = sorted([*parts, cp] for cp, parts in parsed["decomposition"]
                         if len(parts) == 2 and cp not in excluded_set)
    if len({tuple(row[:2]) for row in composition}) != len(composition):
        raise ValueError("Conflicting canonical composition pairs")
    table = {"format": 1, "unicodeVersion": "15.1.0",
             "normalizationTablesVersion": NORMALIZATION_VERSION,
             "categories": parsed["categories"], "ccc": parsed["ccc"],
             "decomposition": parsed["decomposition"], "compositionExclusions": excluded,
             "composition": composition,
             "caseFold": parse_case_folding(inputs["CaseFolding.txt"].decode("utf-8")),
             "simpleLower": parsed["simpleLower"]}
    for key in ("ccc", "decomposition", "caseFold", "simpleLower"):
        keys = [row[0] for row in table[key]]
        if keys != sorted(set(keys)):
            raise ValueError(f"Unsorted/duplicate {key} mappings")
    validate_source_mappings(table, inputs)
    rows = normalization_rows(inputs["NormalizationTest.txt"])
    table_bytes = json_bytes(table)
    manifest = {
        "format": 1, "unicodeVersion": "15.1.0", "normalizationTablesVersion": NORMALIZATION_VERSION,
        "archive": {"url": ARCHIVE_URL, "sha256": PINNED_SHA256["UCD.zip"]},
        "files": [{"name": name, "url": UCD_URL + name, "sha256": PINNED_SHA256[name]}
                  for name in UCD_FILES],
        "license": {"url": LICENSE_URL, "sha256": LICENSE_SHA256,
                    "retrievedAt": LICENSE_RETRIEVED_AT, "licenseId": "Unicode-3.0"},
        "tableSha256": sha256(table_bytes), "normalizationRows": len(rows),
    }
    resources = {"unicode-15.1.0.json": table_bytes,
                 "unicode-15.1.0.json.sha256": (sha256(table_bytes) + "\n").encode(),
                 "unicode-sources-v1.json": json_bytes(manifest, pretty=True),
                 "UNICODE-LICENSE.txt": license_data}
    fixtures = {"unicode/NormalizationTest-15.1.0.txt": inputs["NormalizationTest.txt"],
                "unicode/NormalizationTest-15.1.0.txt.sha256":
                    (PINNED_SHA256["NormalizationTest.txt"] + "\n").encode()}
    return resources, fixtures


def envelope(contract: str, cases: list) -> bytes:
    return json_bytes({"contract": contract, "version": 1, "cases": cases}, pretty=True)


def extract_schemas() -> dict:
    appendix = (ROOT / "docs/contracts/lang-detector-v1.md").read_text(encoding="utf-8")
    result = {}
    for section, name in [("## 9. JSON Schema: artifact", "artifact"),
                          ("## 10. JSON Schema: training manifest", "manifest")]:
        block = appendix.split(section, 1)[1].split("```json\n", 1)[1].split("```", 1)[0]
        schema = json.loads(block)
        if name == "manifest":
            # Training added this optional extension after the WP0 appendix was
            # frozen. Reproduce it explicitly without using the output as input.
            extension = {
                "type": "object", "additionalProperties": False,
                "required": ["missingFromBase", "cc0DetailMismatch", "excludedIdsSha256", "sampleIds"],
                "properties": {
                    "missingFromBase": {"type": "integer", "minimum": 0, "maximum": 9007199254740991},
                    "cc0DetailMismatch": {"type": "integer", "minimum": 0, "maximum": 9007199254740991},
                    "excludedIdsSha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
                    "sampleIds": {"type": "array", "items": {
                        "type": "integer", "minimum": 0, "maximum": 9223372036854775807}, "maxItems": 20},
                },
            }
            properties = {}
            for key, value in schema["properties"].items():
                properties[key] = value
                if key == "negativeLanguages":
                    properties["snapshotSkew"] = extension
            schema["properties"] = properties
        result[f"{name}-v1.schema.json"] = json_bytes(schema, pretty=True)
    return result


def unicode_fixture() -> bytes:
    def case(name, operation, source, expected):
        return {"name": name, "operation": operation, "input": source, "expected": expected}
    return envelope("unicode-tables", [
        case("simple-lower-not-full-fold", "lower", [304, 7838, 66560], [105, 223, 66600]),
        case("full-fold-expands", "fold", [304, 7838], [105, 775, 115, 115]),
        # Required minimal example also frozen in lang-normalize-v1. The other
        # NFC pairs below occur verbatim in the pinned conformance columns.
        case("canonical-reordering", "nfc", [97, 789, 768], [224, 789]),
        case("hangul", "nfc", [4352, 4449, 4520], [44033]),
        case("composition-exclusion", "nfc", [836], [776, 769]),
        case("equal-ccc-blocking", "nfc", [97, 773, 789, 768, 1454, 98], [97, 1454, 773, 768, 789, 98]),
        case("leading-marks", "nfc", [1464, 1465, 1457, 1425, 1475, 1456, 1452, 1439],
             [1457, 1464, 1465, 1425, 1475, 1456, 1452, 1439]),
        case("categories", "category", [0x0378, 0x11F02, 0x0307, 0x0663, 0xE000], ["Cn", "Lo", "Mn", "Nd", "Co"]),
    ])


def artifact_fixture(model: dict) -> bytes:
    raw = json_bytes(model).decode("utf-8")
    cases = [{"name": "unchanged-synthetic", "rawArtifact": raw, "valid": True}]

    def mutation(name, path, value):
        changed = deepcopy(model)
        target = changed
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value
        cases.append({"name": name, "rawArtifact": json_bytes(changed).decode("utf-8"), "valid": False})

    def feature(name, order, index, symbols):
        values = deepcopy(model["vocabulary"][order - 1]["features"])
        values[index] = symbols
        mutation(name, ["vocabulary", order - 1, "features"], sorted(values))

    for name, replacement in [("duplicate-version", '"version":1,"version":1'),
                              ("escaped-duplicate-version", '"version":1,"\\u0076ersion":1'),
                              ("fraction-version", '"version":1.0'),
                              ("exponent-version", '"version":1e0')]:
        cases.append({"name": name, "rawArtifact": raw.replace('"version":1', replacement, 1), "valid": False})
    mutation("boolean-alpha", ["alpha"], True)
    mutation("unknown-top-level", ["unexpected"], 1)
    mutation("unknown-nested", ["parameters", "unexpected"], 1)
    changed = deepcopy(model)
    del changed["thresholds"]
    cases.append({"name": "missing-thresholds", "rawArtifact": json_bytes(changed).decode(), "valid": False})
    feature("surrogate-feature", 1, 4, [55296])
    mutation("unsorted-features", ["vocabulary", 0, "features"], list(reversed(model["vocabulary"][0]["features"])))
    features = deepcopy(model["vocabulary"][0]["features"])
    features[1] = features[0].copy()
    mutation("duplicate-feature", ["vocabulary", 0, "features"], features)
    feature("order-feature-length", 1, 2, [97, 97])
    feature("eos-in-middle", 3, 0, [97, -2, 97])
    feature("duplicate-bos", 3, 0, [-1, -1, 97])
    feature("boundary-only-bigram", 2, 0, [-1, -2])
    feature("digit-only-feature", 1, 2, [48])
    feature("bos-detached-mark", 2, 0, [-1, 775])
    mutation("wrong-profile-order", ["profiles"], list(reversed(model["profiles"])))
    mutation("bad-weight-count", ["profiles", 0, "orders", 0, "weights"], [])
    mutation("weight-positive", ["profiles", 0, "orders", 0, "weights", 0], 1)
    mutation("weight-too-negative", ["profiles", 0, "orders", 0, "weights", 0], -1000001)
    mutation("wrong-prior", ["profiles", 0, "priorWeight"], -1124)
    mutation("duplicate-target", ["targets"], ["xa", "xa"])
    for name, key, value in [("changed-min-letters", "minLetters", 11),
                             ("changed-min-words", "minWords", 2),
                             ("changed-order-weights", "orderWeights", [1, 1, 1]),
                             ("changed-dominance", "mixedDominanceBp", 6999),
                             ("changed-scale", "scoreScale", 1023),
                             ("zero-cap", "inputCapScalars", 0),
                             ("window-exceeds-text-cap", "windowScalars", 257),
                             ("input-cap-too-large", "inputCapScalars", 5000001)]:
        mutation(name, ["parameters", key], value)
    mutation("enabled-zero-margin", ["thresholds", 0, "minMargin"], 0)
    for name, value in [("malformed-escape", raw.replace('"kind":"synthetic"', '"kind":"\\q"')),
                        ("invalid-json", raw[:-2] + ",}\n"),
                        ("missing-final-lf", raw[:-1]), ("bom", "\ufeff" + raw)]:
        cases.append({"name": name, "rawArtifact": value, "valid": False})
    cases.append({"name": "invalid-utf8", "rawBytesBase64": base64.b64encode(
        raw.encode().replace(b"synthetic", b"synthetic\xff", 1)).decode("ascii"), "valid": False})
    return envelope("lang-artifact-validation", cases)


def snapshot_skew_validation_cases() -> list:
    """Raw manifest properties prefixed to the production-shaped loader fixture.

    Preserve raw number spelling and duplicate keys so both native parsers and
    the independent Python validator exercise the same malformed JSON tokens.
    """
    base = {"missingFromBase": 0, "cc0DetailMismatch": 0,
            "excludedIdsSha256": "0" * 64, "sampleIds": []}
    cases = []

    def raw(value):
        return json_bytes(value).decode("utf-8").removesuffix("\n")

    def case(name, properties, valid=False):
        cases.append({"name": "manifest-snapshot-skew-" + name,
                      "rawManifestProperties": properties, "valid": valid})

    def skew(name, value, valid=False):
        case(name, '"snapshotSkew":' + raw(value) + ",", valid)

    def mutation(name, key, value):
        changed = deepcopy(base)
        changed[key] = value
        skew(name, changed)

    def token(name, key, value):
        body = raw(base).replace(raw(key) + ":" + raw(base[key]), raw(key) + ":" + value, 1)
        case(name, '"snapshotSkew":' + body + ",")

    case("absent", "", True)
    skew("zero-counts-empty-samples", base, True)
    skew("nonzero", dict(base, missingFromBase=12, cc0DetailMismatch=34,
                         excludedIdsSha256="0123456789abcdef" * 4, sampleIds=[0, 1, 123456789]), True)
    skew("maximum-counts-and-twenty-ids", dict(base, missingFromBase=9007199254740991,
         cc0DetailMismatch=9007199254740991,
         sampleIds=[*range(18), 9007199254740992, 9223372036854775807]), True)
    skew("unordered-repeated-ids", dict(base, sampleIds=[2, 1, 2]), True)

    for name, value in [("null", None), ("boolean", False), ("integer", 0),
                        ("string", ""), ("array", [])]:
        skew("object-" + name, value)
    for key in base:
        changed = deepcopy(base)
        del changed[key]
        skew("missing-" + key, changed)
    mutation("unknown-nested-field", "unexpected", 0)
    for key in ("missingFromBase", "cc0DetailMismatch"):
        for name, value in [("negative", -1), ("overflow", 9007199254740992),
                            ("boolean", True), ("null", None), ("string", "1"),
                            ("array", []), ("object", {})]:
            mutation(key + "-" + name, key, value)
        token(key + "-fraction", key, "1.0")
        token(key + "-exponent", key, "1e0")
    for name, value in [("null", None), ("boolean", True), ("integer", 0),
                        ("array", []), ("object", {}), ("empty", ""),
                        ("short", "0" * 63), ("long", "0" * 65),
                        ("uppercase", "A" * 64), ("nonhex", "g" * 64)]:
        mutation("sha256-" + name, "excludedIdsSha256", value)
    for name, value in [("null", None), ("boolean", True), ("integer", 0),
                        ("string", "0"), ("object", {})]:
        mutation("samples-" + name, "sampleIds", value)
    mutation("twenty-one-ids", "sampleIds", list(range(21)))
    for name, value in [("null", None), ("boolean", False), ("string", "1"),
                        ("object", {}), ("array", []), ("negative", -1),
                        ("overflow", 9223372036854775808)]:
        mutation("sample-id-" + name, "sampleIds", [value])
    for name, value in [("fraction", "[1.0]"), ("exponent", "[1e0]"),
                        ("leading-zero", "[01]"), ("plus-sign", "[+1]")]:
        token("sample-id-" + name, "sampleIds", value)
    body = raw(base)
    for name, key in [("duplicate-field", '"missingFromBase"'),
                      ("escaped-duplicate-field", '"\\u006dissingFromBase"')]:
        case(name, '"snapshotSkew":' + body.replace(
            '"missingFromBase":0', '"missingFromBase":0,' + key + ":0", 1) + ",")
    property_text = '"snapshotSkew":' + body + ","
    case("duplicate-object", property_text + property_text)
    case("unknown-root-field", property_text + '"unexpected":0,')
    return cases


def inheritance_fixture() -> bytes:
    rows = [("unavailable-with-document", None, None, "cs", None, False),
            ("unavailable-without-document", None, None, None, None, False),
            ("short-letters", "und", "minLetters", "cs", "cs", True),
            ("short-words", "und", "minWords", "de", "de", True)]
    for reason in ("minMargin", "background", "bucketDisabled", "minWinningScore", "minKnownCoverageBp"):
        rows.append(("no-inheritance-" + reason, "und", reason, "cs", "und", False))
    for reason in ("minLetters", "minWords"):
        for document in ("mixed", "und", None):
            rows.append((f"short-{reason}-document-{document or 'null'}", "und", reason, document, "und", False))
    rows.append(("accepted-chunk-keeps-language", "sk", "accepted", "cs", "sk", False))
    return envelope("lang-inheritance", [
        {"name": name, "operation": "resolve", "input": {"label": label, "reason": reason, "documentLabel": document},
         "expected": {"lang": lang, "langInherited": inherited}}
        for name, label, reason, document, lang, inherited in rows])


def score_fixture_words(words: list, model: dict) -> dict:
    """Small supplemental oracle over explicit ASCII words and frozen weights.

    This does not normalize, train or export; Task 4 owns the independent full
    reference. Keep every diagnostic, including raw unknown tuples and floors.
    """
    if any(not word or any(cp not in range(97, 123) for cp in word) for word in words):
        raise ValueError("Supplemental oracle only accepts explicit ASCII letter words")
    counts = [Counter() for _ in range(3)]
    for word in words:
        padded = [-1] + word + [-2]
        for n in range(1, 4):
            counts[n - 1].update(tuple(padded[i:i + n]) for i in range(len(padded) - n + 1))
    vocabularies = [{tuple(symbols): i for i, symbols in enumerate(order["features"])}
                    for order in model["vocabulary"]]
    totals = [sum(order.values()) for order in counts]
    known = [sum(count for symbols, count in order.items() if symbols in vocabulary)
             for order, vocabulary in zip(counts, vocabularies)]
    scores = {}
    for profile in model["profiles"]:
        sums = []
        for order, vocabulary, weights in zip(counts, vocabularies, profile["orders"]):
            sums.append(sum(count * (weights["weights"][vocabulary[symbols]] if symbols in vocabulary
                                     else weights["unknownWeight"]) for symbols, count in order.items()))
        order_scores = [weighted // total if total else 0 for weighted, total in zip(sums, totals)]
        scores[profile["id"]] = {"weightedSums": sums, "orderScores": order_scores,
            "combinedScore": profile["priorWeight"] + sum(w * s for w, s in zip(model["parameters"]["orderWeights"], order_scores))}
    ranked = sorted(scores, key=lambda name: (-scores[name]["combinedScore"], name != "background", name))
    winner, runner_up = ranked[:2]
    margin = scores[winner]["combinedScore"] - scores[runner_up]["combinedScore"]
    letters = sum(map(len, words))
    threshold = next((row for row in reversed(model["thresholds"]) if row["start"] <= letters), None)
    coverage = 10000 * sum(known) // sum(totals) if sum(totals) else 0
    p = model["parameters"]
    if letters < p["minLetters"]:
        reason = "minLetters"
    elif len(words) < p["minWords"]:
        reason = "minWords"
    elif not threshold["enabled"]:
        reason = "bucketDisabled"
    elif winner == "background":
        reason = "background"
    elif scores[winner]["combinedScore"] < threshold["minWinningScore"]:
        reason = "minWinningScore"
    elif margin < threshold["minMargin"]:
        reason = "minMargin"
    elif coverage < threshold["minKnownCoverageBp"]:
        reason = "minKnownCoverageBp"
    else:
        reason = "accepted"
    return {"words": ["".join(map(chr, word)) for word in words], "wordScalars": words,
            "letterCount": letters, "wordCount": len(words), "bucketStart": threshold["start"] if threshold else None,
            "features": [[{"symbols": list(symbols), "count": count} for symbols, count in sorted(order.items())] for order in counts],
            "featureCounts": totals, "knownCounts": known, "unknownCounts": [f - k for f, k in zip(totals, known)],
            "profiles": scores, "winner": winner, "runnerUp": runner_up, "margin": margin,
            "coverageBp": coverage, "label": winner if reason == "accepted" else "und", "reason": reason}


def runtime_fixture(frozen: dict) -> bytes:
    cases = []
    def case(name, operation, source, expected):
        cases.append({"name": name, "operation": operation, "input": source, "expected": expected})

    # These explicit small inputs have hand-derived pinned normalization outputs.
    for name, units, cap, text_cap, mode, stream, scalars, words, letters in [
        ("utf16-pair-cap", [55297, 56320, 65], 1, 1, "text", [66600], [66600], [[66600]], 1),
        ("utf16-unpaired-adjacent", [55296, 55296, 56320, 65], 8, 8, "text", [65533, 65536, 97], [65533, 65536, 97], [[65536, 97]], 2),
        ("fold-pre-post-cap", [223, 223, 65], 3, 3, "text", [115, 115, 115], [115, 115, 115], [[115, 115, 115]], 3),
        ("dotted-i-text-cap", [304], 8, 1, "text", [105, 775], [105], [[105]], 1),
        ("dotted-i-document", [304], 8, 1, "document", [105, 775], [105, 775], [[105, 775]], 1),
    ]:
        case(name, "normalize", {"utf16Units": units, "inputCap": cap, "textCap": text_cap, "mode": mode},
             {"stream": stream, "scalars": scalars, "words": ["".join(map(chr, word)) for word in words],
              "wordScalars": words, "boundaryWords": [[-1] + word + [-2] for word in words],
              "letterCount": letters, "wordCount": len(words)})
    for length, expected in [(0, []), (513, [[0, 256], [257, 513]]),
                             (4097, [[0, 512], [512, 1024], [1024, 1536], [1536, 2048],
                                     [2048, 2560], [2560, 3072], [3072, 3584], [3585, 4097]])]:
        case(f"windows-{length}", "windows", {"length": length, "count": 8, "size": 512}, expected)
    # Explicit denominator boundaries: unknown letters always remain sampled.
    for name, labels, letters, accepted, unknown, shares, unknown_share, coverage, label, reason in [
        ("dominance-equality", ["cs", "und"], [70, 30], [70, 0, 0, 0], 30, [7000, 0, 0, 0], 3000, 7000, "cs", "dominant"),
        ("one-target-diluted", ["cs", "und"], [69, 31], [69, 0, 0, 0], 31, [6900, 0, 0, 0], 3100, 6900, "und", "insufficientEvidence"),
        ("tiny-confident-minority", ["cs", "sk", "und"], [69, 1, 30], [69, 0, 0, 1], 30, [6900, 0, 0, 100], 3000, 7000, "mixed", "mixed"),
        ("zero-letter-empty", [], [], [0, 0, 0, 0], 0, [0, 0, 0, 0], 0, 0, "und", "insufficientEvidence"),
        ("independent-share-floors", ["cs", "sk", "und"], [1, 1, 1], [1, 0, 0, 1], 1, [3333, 0, 0, 3333], 3333, 6666, "mixed", "mixed"),
    ]:
        targets = ["cs", "de", "en", "sk"]
        case(name, "aggregate", {"targets": targets, "labels": labels, "letters": letters},
             {"sampledLetters": sum(letters), "acceptedLetters": dict(zip(targets, accepted)), "unknownLetters": unknown,
              "sharesBp": dict(zip(targets, shares)), "unknownShareBp": unknown_share, "langCoverageBp": coverage,
              "label": label, "reason": reason})
    existing = {row["name"]: row for row in frozen["cases"]}
    for name, text_case, triple in [
        ("equal-winning-score", "accept-xa", [-8957, 1, 0]),
        ("equal-margin", "accept-xa", [-20000, 9096, 0]),
        ("equal-coverage", "accept-xa", [-20000, 1, 10000]),
        ("equal-floored-coverage", "coverage-only", [-20000, 1, 8888]),
    ]:
        threshold = dict(zip(["minWinningScore", "minMargin", "minKnownCoverageBp"], triple))
        row = existing[text_case]
        expected = deepcopy(row["expected"])
        expected.update(label="xa", reason="accepted")
        case(name, "score", row["input"], expected)
        # Deep merge object fields; thresholds is the full replacement array.
        thresholds = deepcopy(frozen["model"]["thresholds"])
        thresholds[0].update(threshold)
        cases[-1]["modelOverrides"] = {"thresholds": thresholds}
    # Hand-check this small oracle against the appendix's complete worked tree.
    if score_fixture_words([[97] * 4 for _ in range(3)], frozen["model"]) != existing["accept-xa"]["expected"]:
        raise ValueError("Supplemental score oracle differs from frozen xa worked example")
    text = "a" * 8190 + " " + "a"
    expected = score_fixture_words([[97] * 8190, [97]], frozen["model"])
    for name, source in [("text-cap-exact", text), ("text-cap-discards-suffix", text + "b")]:
        case(name, "score", source, deepcopy(expected))
        cases[-1]["modelOverrides"] = {"parameters": {"inputCapScalars": 9000, "textCapScalars": 8192}}
    return envelope("lang-runtime", cases)


def supplemental_fixtures() -> dict:
    frozen = json.loads((ROOT / "Tests/fixtures/contracts/lang-score-v1.json").read_bytes())
    return {"contracts/unicode-tables-v1.json": unicode_fixture(),
            "contracts/lang-artifact-validation-v1.json": artifact_fixture(frozen["model"]),
            "contracts/lang-inheritance-v1.json": inheritance_fixture(),
            "contracts/lang-runtime-v1.json": runtime_fixture(frozen)}


def merge_regression_fixtures(fixtures: dict) -> dict:
    """Append the reviewed WP4 parity cases without reading generated outputs.

    Raw JSON strings in these cases deliberately exercise parser boundaries;
    preserve them verbatim and retain their original case order.
    """
    supplemental = json.loads(Path(__file__).with_name("supplemental-cases.json").read_bytes())
    supplemental["contracts/lang-artifact-validation-v1.json"]["cases"].extend(
        snapshot_skew_validation_cases())
    result = dict(fixtures)
    for name, extra in supplemental.items():
        fixture = (json.loads(result[name]) if name in result else
                   {"contract": extra["contract"], "version": extra["version"], "cases": []})
        if any(fixture[key] != extra[key] for key in ("contract", "version")):
            raise ValueError(f"Supplemental fixture envelope mismatch: {name}")
        names = {case["name"] for case in fixture["cases"]}
        for case in extra["cases"]:
            if case["name"] in names:
                raise ValueError(f"Duplicate supplemental case {case['name']}: {name}")
            names.add(case["name"])
            fixture["cases"].append(case)
        result[name] = json_bytes(fixture, pretty=True)
    return result


def generate(ucd_dir: Path, output_dir: Path, fixture_dir: Path, *,
             license_file: Path = None, schema_dir: Path = None, check: bool = False) -> None:
    inputs = {name: (ucd_dir / name).read_bytes() for name in UCD_FILES}
    for name, data in inputs.items():
        verify_bytes(name, data)
    archive = ucd_dir / "UCD.zip"
    if archive.exists():
        verify_bytes("UCD.zip", archive.read_bytes())
    license_data = (license_file or ucd_dir / "license.txt").read_bytes()
    if sha256(license_data) != LICENSE_SHA256:
        raise ValueError("SHA-256 mismatch for approved Unicode license")
    resources, fixtures = build_unicode_outputs(inputs, license_data)
    fixtures.update(supplemental_fixtures())
    fixtures.update(build_loading_fixtures())
    fixtures = merge_regression_fixtures(fixtures)
    schemas = extract_schemas()
    schema_dir = schema_dir or ROOT / "tools/lang/schemas"
    outputs = {**{output_dir / name: data for name, data in resources.items()},
               **{fixture_dir / name: data for name, data in fixtures.items()},
               **{schema_dir / name: data for name, data in schemas.items()}}
    if check:
        mismatches = [str(path) for path, data in outputs.items()
                      if not path.is_file() or path.read_bytes() != data]
        if mismatches:
            raise ValueError("Generated output mismatch: " + ", ".join(mismatches))
    else:
        for path, data in outputs.items():
            atomic_write(path, data)
    manifest = json.loads(resources["unicode-sources-v1.json"])
    print(f"Unicode 15.1.0 tables verified; {manifest['normalizationRows']} conformance rows; "
          f"SHA-256 {manifest['tableSha256']}")


def build_loading_fixtures() -> dict:
    """Invent a complete production-shaped bundle solely for loader validation.

    Mutation inputs use fixed resource names and JSON pointers. setManifestValue
    and addUnknownManifestKey reserialize JSON with a final LF; duplicateManifestKey
    inserts a second decoded key at that pointer without reparsing the result.
    flipByte XORs the indexed byte with 1. replaceArtifactWithSynthetic uses the
    frozen lang-score-v1 model and updates artifactSha256 to its exact new bytes,
    ensuring the negative case reaches production-kind validation.
    """
    import base64
    import copy

    model_id = "wp4-loader-test-only"
    artifact_name = "lang-detector-v1.json"
    manifest_name = "lang-detector-v1.manifest.json"
    targets = ["cs", "de", "en", "sk"]
    negatives = ["fr", "hr", "hu", "nl", "pl", "sl"]
    languages = sorted(targets + negatives)
    splits = ["train", "validation", "test"]
    buckets = [0, 12, 32, 80, 200]
    notice = b"Wholly invented WP4 loader fixture; not for distribution as a model.\n"
    # Like tools/lang/train_detector.py, attribute the redistributed Unicode
    # tables: attribution licenses = corpus licenses plus Unicode-3.0.
    attribution = {"sourceIds": [model_id], "licenseIds": ["LicenseRef-WP4-Test-Only", "Unicode-3.0"],
                   "attributionPath": "tools/lang/ATTRIBUTION.md", "attributionSha256": sha256(notice),
                   "noticePath": "NOTICE", "noticeSha256": sha256(notice)}
    model = {
        "contract": "lang-detector", "version": 1, "kind": "production", "modelId": model_id,
        "targets": targets, "normalizationTablesVersion": NORMALIZATION_VERSION, "alpha": 1,
        "parameters": {"maxFeaturesPerProfile": [256, 1024, 4096], "orderWeights": [1, 2, 3],
                       "scoreScale": 1024, "lengthBucketStarts": buckets[1:], "minLetters": 12,
                       "minWords": 3, "mixedDominanceBp": 7000, "inputCapScalars": 5000000,
                       "textCapScalars": 8192, "windowCount": 8, "windowScalars": 512},
        "vocabulary": [{"order": n, "features": []} for n in (1, 2, 3)],
        "profiles": [{"id": name, "priorWeight": -1648,
                      "orders": [{"order": n, "weights": [], "unknownWeight": 0} for n in (1, 2, 3)]}
                     for name in ["background"] + targets],
        "thresholds": [{"start": b, "enabled": 0, "minWinningScore": -120000,
                        "minMargin": 1, "minKnownCoverageBp": 0} for b in buckets[1:]],
        "attribution": copy.deepcopy(attribution),
    }
    artifact_bytes = json_bytes(model)
    # Counts of noncomment, nonempty data rows in the four exact pinned files.
    unicode_records = {"UnicodeData.txt": 34931, "CaseFolding.txt": 1563,
                       "DerivedNormalizationProps.txt": 15893, "NormalizationTest.txt": 19074}
    manifest = {
        "contract": "lang-detector-manifest", "version": 1, "modelId": model_id,
        "artifactPath": "Sources/AINotebookCore/Resources/Language/lang-detector-v1.json",
        "artifactSha256": sha256(artifact_bytes), "createdAt": "2026-10-09T00:00:00Z",
        "corpus": [{
            "id": model_id,
            "files": [{"role": "sentences", "url": "https://example.invalid/wp4-loader-test-only",
                       "snapshotDate": "2026-10-09", "sha256": sha256(b""),
                       "formatVersion": "wp4-invented-empty-v1", "records": 0}],
            "licenseIds": ["LicenseRef-WP4-Test-Only"],
            "licenseSelectionPolicy": "Wholly invented zero-record fixture; no corpus was downloaded.",
            "languageSelectionPolicy": "All ten mapped languages; zero source records.",
            "deduplicationPolicy": "none; translation links only",
            "translationGroupPolicy": "translation-components-sha256-v1; no records or links",
            "originalRecords": 0,
            "languageMappings": [{"sourceLanguage": source, "detectorLanguage": target}
                                 for source, target in [("ces", "cs"), ("deu", "de"), ("eng", "en"),
                                     ("fra", "fr"), ("hrv", "hr"), ("hun", "hu"), ("nld", "nl"),
                                     ("pol", "pl"), ("slk", "sk"), ("slv", "sl")]],
        }],
        "negativeLanguages": negatives,
        "environment": {
            "exporterGitCommit": "0" * 40,
            "commandArguments": [model_id, "--created-at", "2026-10-09T00:00:00Z",
                                 "--exporter-commit", "0" * 40],
            "pythonVersion": "3.12.0", "dependencies": [],
            "normalizationTablesVersion": NORMALIZATION_VERSION,
            "unicodeFiles": [{"role": "normalizationTest" if name == "NormalizationTest.txt" else "unicodeData",
                              "url": UCD_URL + name, "snapshotDate": "2026-10-09",
                              "sha256": PINNED_SHA256[name], "formatVersion": "Unicode-15.1.0",
                              "records": unicode_records[name]} for name in UCD_FILES],
        },
        "split": {"algorithm": "translation-components-sha256-v1", "seed": 1729,
                  "splitBp": {"train": 8000, "validation": 1000, "test": 1000},
                  "maxComponentMembers": 10000, "oversizedComponents": []},
        "caps": [{"split": split, "language": language, "maxOriginalRecords": 0}
                 for split in splits for language in languages],
        "augmentation": [{"algorithm": "none-v1", "splits": splits,
                          "lengths": [], "inputCount": 0, "outputCount": 0}],
        "counts": [{"split": split, "language": language, "bucketStart": bucket,
                    "originals": 0, "augmented": 0, "originalGroups": 0}
                   for split in splits for language in languages for bucket in buckets],
        "exclusions": [],
        "minimumSupport": {"groupsPerTarget": 200, "groupsPerNegativeLanguage": 200,
                           "acceptedTotal": 1000, "acceptedTrueCs": 100, "acceptedTrueSk": 100},
        "calibration": {
            "algorithm": "grid-max-accepted-v1",
            "candidates": [{"bucketStart": bucket, "minWinningScores": [-120000],
                            "minMargins": [1], "minKnownCoverageBp": [0]} for bucket in buckets[1:]],
            "tieBreak": ["minWinningScoreDescending", "minMarginDescending", "minKnownCoverageBpDescending"],
            "disabledBuckets": [{"bucketStart": bucket, "reason": "insufficientSupport"} for bucket in buckets[1:]],
        },
        "support": [{"split": split, "bucketStart": bucket, "language": language,
                     "originalGroups": 0, "evaluated": 0, "accepted": 0}
                    for split in splits[1:] for language in languages for bucket in buckets[1:]],
        "metrics": [{"split": split, "bucketStart": bucket, "language": language, "name": name,
                     "numerator": 0, "denominator": 0, "rateBp": None}
                    for split in splits[1:] for language in languages + ["all"] for bucket in buckets
                    for name in ["acceptedError", "csSkConfusion", "foreignAcceptance", "acceptanceCoverage"]],
        "documentMetrics": [], "attribution": copy.deepcopy(attribution),
    }
    resources = {artifact_name: artifact_bytes, manifest_name: json_bytes(manifest),
                 "NOTICE": notice, "ATTRIBUTION.md": notice}
    unicode_names = ["unicode-15.1.0.json", "unicode-15.1.0.json.sha256",
                     "unicode-sources-v1.json", "UNICODE-LICENSE.txt"]
    bundle = {"contract": "lang-loading-bundle", "version": 1, "testOnly": 1,
              "resources": {name: base64.b64encode(data).decode("ascii") for name, data in resources.items()},
              "sharedUnicodeResources": unicode_names}
    cases = []

    def case(name, operation, value, available=False):
        cases.append({"name": name, "operation": operation, "input": value,
                      "expected": {"isAvailable": available}})

    def set_manifest(name, pointer, value):
        case(name, "setManifestValue", {"resource": manifest_name, "pointer": pointer, "value": value})

    case("unchanged-production-shaped-test-bundle", "unchanged", {}, True)
    for name in [artifact_name, manifest_name, *unicode_names, "NOTICE", "ATTRIBUTION.md"]:
        case("missing-" + name, "removeResource", {"resource": name})
    for name in [artifact_name, "unicode-15.1.0.json", "NOTICE", "ATTRIBUTION.md"]:
        case("changed-" + name, "flipByte", {"resource": name, "byteIndex": 0})
    case("correct-digest-synthetic-artifact", "replaceArtifactWithSynthetic", {"resource": artifact_name})
    set_manifest("changed-model-id", "/modelId", "wp4-loader-test-only-changed")
    set_manifest("changed-normalization-version", "/environment/normalizationTablesVersion", "ucd-15.0.0-default-full-v1")
    for i, name in enumerate(UCD_FILES):
        set_manifest("changed-source-pin-" + name, f"/environment/unicodeFiles/{i}/sha256", "0" * 64)
    set_manifest("changed-attribution-hash", "/attribution/attributionSha256", "0" * 64)
    set_manifest("attribution-path-traversal", "/attribution/attributionPath", "../tools/lang/ATTRIBUTION.md")
    set_manifest("changed-notice-hash", "/attribution/noticeSha256", "0" * 64)
    set_manifest("notice-path-traversal", "/attribution/noticePath", "../NOTICE")
    set_manifest("artifact-path-traversal", "/artifactPath", "../Sources/AINotebookCore/Resources/Language/lang-detector-v1.json")
    set_manifest("invalid-calendar-date", "/createdAt", "2026-02-30T00:00:00Z")
    set_manifest("duplicate-count-compound-key", "/counts/1", copy.deepcopy(manifest["counts"][0]))
    set_manifest("duplicate-support-compound-key", "/support/1", copy.deepcopy(manifest["support"][0]))
    case("attribution-without-unicode-license", "setResourceValues",
         {"changes": [{"resource": name, "pointer": "/attribution/licenseIds", "value": ["LicenseRef-WP4-Test-Only"]}
                      for name in (artifact_name, manifest_name)],
          "refreshArtifactDigest": True})
    case("unknown-manifest-key", "addUnknownManifestKey", {"resource": manifest_name, "pointer": "/unexpected", "value": 0})
    case("duplicate-manifest-key", "duplicateManifestKey", {"resource": manifest_name, "pointer": "/version", "value": 1})
    return {"lang/loading-bundle-v1.json": json_bytes(bundle, pretty=True),
            "contracts/lang-loading-v1.json": json_bytes({"contract": "lang-loading", "version": 1,
                                                          "cases": cases}, pretty=True)}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ucd-dir", required=True, type=Path,
                        help="Directory containing four pinned UCD inputs (ZIP optional offline)")
    parser.add_argument("--license-file", type=Path, help="Approved local Unicode License V3 (default: UCD dir/license.txt)")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "Sources/AINotebookCore/Resources/Language")
    parser.add_argument("--fixture-dir", type=Path, default=ROOT / "Tests/fixtures")
    parser.add_argument("--schema-dir", type=Path, default=ROOT / "tools/lang/schemas")
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--download", action="store_true", help="Explicitly acquire only the pinned UCD archive")
    modes.add_argument("--check", action="store_true", help="Recompute all outputs without writing")
    args = parser.parse_args(argv)
    try:
        if args.download:
            download(args.ucd_dir)
        generate(args.ucd_dir, args.output_dir, args.fixture_dir,
                 license_file=args.license_file, schema_dir=args.schema_dir, check=args.check)
        return 0
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
