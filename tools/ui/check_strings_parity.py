#!/usr/bin/env python3
"""UI string parity between macOS and Windows (UI redesign C1).

Compares the macOS strings (``AppText.Key`` with its English and Czech tables in
``Sources/AINotebookCore/Localization.swift``) with the Windows resources
(``windows/src/AINotebook.App/Strings/{en-US,cs-CZ}/Resources.resw``) and the
Windows ``StringKey`` enum. Reports, per side:

* keys missing on Windows / missing on macOS,
* en-US vs cs-CZ key sets that differ, and keys without a StringKey member,
* empty values (either language, either platform),
* English or Czech text that differs for the same key (placeholders such as
  ``%@``, ``%d``, ``%1$@`` and ``{0}`` compare equal).

Intentional differences live in ``tools/ui/strings-parity-allowlist.txt``; every
entry needs a justification and stale entries fail the check, so the list only
ever shrinks. Exit status: 0 when in parity, 1 on any finding, 2 on bad input.

Usage: python3 tools/ui/check_strings_parity.py [--root REPO] [--allowlist FILE]
"""
from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

SWIFT = Path("Sources/AINotebookCore/Localization.swift")
RESW = Path("windows/src/AINotebook.App/Strings/{locale}/Resources.resw")
STRING_KEY = Path("windows/src/AINotebook.App/Services/StringKey.cs")
ALLOWLIST = Path("tools/ui/strings-parity-allowlist.txt")
LOCALES = {"en": "en-US", "cs": "cs-CZ"}
KINDS = {"alias", "mac-only", "windows-only", "value"}


class InputError(Exception):
    pass


# ---------------------------------------------------------------- parsing

def swift_strings(path: Path) -> tuple[list[str], dict[str, dict[str, str]]]:
    """AppText.Key cases in order, and {lang: {key: value}} from english()/czech()."""
    src = path.read_text(encoding="utf-8")
    enum = re.search(r"public enum Key\b[^{]*\{(.*?)\n    \}", src, re.S)
    if not enum:
        raise InputError(f"{path}: AppText.Key enum not found")
    keys = re.findall(r"^\s*case\s+([A-Za-z_]\w*)\s*$", enum.group(1), re.M)
    tables: dict[str, dict[str, str]] = {}
    for lang, fn in (("en", "english"), ("cs", "czech")):
        body = re.search(r"private func %s\(_ key: Key\) -> String \{(.*?)\n    \}" % fn, src, re.S)
        if not body:
            raise InputError(f"{path}: {fn}() table not found")
        table: dict[str, str] = {}
        for line in body.group(1).splitlines():
            line = line.strip()
            if not line.startswith("case ."):
                continue
            m = re.fullmatch(r'case ((?:\.\w+\s*,\s*)*\.\w+)\s*:\s*"((?:[^"\\]|\\.)*)"', line)
            if not m:
                raise InputError(f"{path}: {fn}(): unsupported line (one string literal per case expected): {line}")
            for key in re.findall(r"\.(\w+)", m.group(1)):
                table[key] = swift_unescape(m.group(2))
        tables[lang] = table
    return keys, tables


def swift_unescape(value: str) -> str:
    return re.sub(r'\\(["\\nt])', lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), value)


def resw_strings(path: Path) -> dict[str, str]:
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError) as error:
        raise InputError(f"{path}: {error}") from error
    return {d.get("name"): (d.findtext("value") or "") for d in root.findall("data")}


def string_key_members(path: Path) -> set[str]:
    src = path.read_text(encoding="utf-8")
    body = re.search(r"public enum StringKey\s*\{(.*?)\n\}", src, re.S)
    if not body:
        raise InputError(f"{path}: enum StringKey not found")
    text = re.sub(r"//[^\n]*", "", body.group(1))
    return {m for m in re.findall(r"\b([A-Z]\w*)\b", text)}


@dataclass
class Allowlist:
    alias: dict[str, str] = field(default_factory=dict)      # mac key -> windows key
    mac_only: set[str] = field(default_factory=set)
    windows_only: set[str] = field(default_factory=set)
    value: set[str] = field(default_factory=set)             # mac key (alias: mac side)
    used: set[tuple[str, str]] = field(default_factory=set)


def read_allowlist(path: Path) -> Allowlist:
    allow = Allowlist()
    if not path.exists():
        return allow
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        entry, sep, reason = line.partition(" -- ")
        parts = entry.split()
        where = f"{path}:{number}"
        if not sep or not reason.strip():
            raise InputError(f"{where}: missing ' -- justification'")
        if not parts or parts[0] not in KINDS:
            raise InputError(f"{where}: kind must be one of {sorted(KINDS)}")
        kind, args = parts[0], parts[1:]
        if kind == "alias":
            if len(args) != 3 or args[1] != "=":
                raise InputError(f"{where}: expected 'alias <macKey> = <windowsKey> -- why'")
            allow.alias[args[0]] = args[2]
        elif len(args) != 1:
            raise InputError(f"{where}: expected '{kind} <key> -- why'")
        elif kind == "mac-only":
            allow.mac_only.add(args[0])
        elif kind == "windows-only":
            allow.windows_only.add(args[0])
        else:
            allow.value.add(args[0])
    return allow


# ---------------------------------------------------------------- checks

def normalize(value: str) -> str:
    value = re.sub(r"%(\d+\$)?(@|lld|ld|d|f|\.\d+f)", "{}", value)
    return re.sub(r"\{\d+(:[^}]*)?\}", "{}", value)


def check(root: Path, allowlist_path: Path) -> list[str]:
    keys, swift = swift_strings(root / SWIFT)
    resw = {lang: resw_strings(root / str(RESW).format(locale=loc)) for lang, loc in LOCALES.items()}
    members = string_key_members(root / STRING_KEY)
    allow = read_allowlist(allowlist_path)
    problems: list[str] = []
    mac, win = set(keys), set(resw["en"])

    # One side on its own.
    for lang in LOCALES:
        for key in keys:
            if not swift[lang].get(key, "").strip():
                problems.append(f"macOS {lang}: '{key}' has no text")
        for key, value in sorted(resw[lang].items()):
            if not value.strip():
                problems.append(f"Windows {LOCALES[lang]}: '{key}' is empty")
    for key in sorted(set(resw["en"]) ^ set(resw["cs"])):
        side = "cs-CZ" if key in resw["en"] else "en-US"
        problems.append(f"Windows: '{key}' missing in {side}")
    for key in sorted(win):
        if key[:1].upper() + key[1:] not in members:
            problems.append(f"Windows: '{key}' has no StringKey member")

    # Pairs: same key, or an allowlisted alias.
    pairs = {key: key for key in mac & win}
    for mac_key, win_key in allow.alias.items():
        if mac_key not in mac or win_key not in win:
            problems.append(f"allowlist: alias {mac_key} = {win_key} names a key that does not exist")
        elif mac_key in win or win_key in mac:
            problems.append(f"allowlist: alias {mac_key} = {win_key} is stale (a shared key exists now)")
        else:
            pairs[mac_key] = win_key
            allow.used.add(("alias", mac_key))
    paired_win = set(pairs.values())

    for key in keys:
        if key in pairs:
            continue
        if key in allow.mac_only:
            allow.used.add(("mac-only", key))
        else:
            problems.append(f"missing on Windows: '{key}' (macOS AppText.Key)")
    for key in sorted(win - paired_win):
        if key in allow.windows_only:
            allow.used.add(("windows-only", key))
        else:
            problems.append(f"missing on macOS: '{key}' (Windows resw)")

    for mac_key, win_key in sorted(pairs.items()):
        differs = [lang for lang in LOCALES
                   if normalize(swift[lang].get(mac_key, "")) != normalize(resw[lang].get(win_key, ""))]
        if not differs:
            continue
        if mac_key in allow.value:
            allow.used.add(("value", mac_key))
            continue
        for lang in differs:
            problems.append(f"text differs ({lang}) for '{mac_key}'"
                            + (f" / '{win_key}'" if win_key != mac_key else "")
                            + f": macOS {swift[lang].get(mac_key)!r} vs Windows {resw[lang].get(win_key)!r}")

    # Stale allowlist entries.
    for kind, entries in (("mac-only", allow.mac_only), ("windows-only", allow.windows_only), ("value", allow.value)):
        for key in sorted(entries):
            if (kind, key) not in allow.used:
                problems.append(f"allowlist: '{kind} {key}' is stale (nothing to allow) — remove it")
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--allowlist", type=Path)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    try:
        problems = check(root, args.allowlist or root / ALLOWLIST)
    except InputError as error:
        print(f"check_strings_parity: {error}", file=sys.stderr)
        return 2
    if problems:
        print(f"UI string parity: {len(problems)} finding(s)")
        for problem in problems:
            print(f"  - {problem}")
        print(f"Fix the strings, or allowlist an intentional difference with a justification in {ALLOWLIST}.")
        return 1
    print("UI string parity: OK (macOS AppText ↔ Windows resw en-US/cs-CZ)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
