#!/usr/bin/env python3
"""Checks the English translation against the strings the code really looks up.

The compiler lists every localizable string (SwiftUI literals, String(localized:)) per file in
.stringsdata (SWIFT_EMIT_LOC_STRINGS). This reports keys missing from en.lproj, keys there that
the code no longer uses, and Russian literals in the code that are not localizable at all (shown
in Russian whatever the language). Run after a build: scripts/install.sh or scripts/test.sh.
"""
import glob
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STRINGS = ROOT / "MXCtl/Resources/en.lproj/Localizable.strings"
CYRILLIC = re.compile("[А-Яа-яЁё]")


def code_keys():
    keys = {}
    for path in glob.glob(str(ROOT / "build/dd/Build/Intermediates.noindex/MXCtl.build/*/MXCtl.build/Objects-normal/*/*.stringsdata")):
        data = json.load(open(path))
        for entry in data["tables"].get("Localizable", []):
            line = entry["location"]["startingLine"]
            keys.setdefault(entry["key"], set()).add((Path(data["source"]).name, line))
    return keys


def translated():
    text = STRINGS.read_text()
    pairs = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', text, re.M)
    return {json.loads(f'"{k}"'): json.loads(f'"{v}"') for k, v in pairs}


def main():
    keys = code_keys()
    if not keys:
        sys.exit("No .stringsdata in build/dd: build first (scripts/install.sh).")
    english = translated()
    problems = 0
    for key in sorted(set(keys) - set(english)):
        if CYRILLIC.search(key):
            problems += 1
            where = ", ".join(f"{f}:{l}" for f, l in sorted(keys[key]))
            print(f"missing: {json.dumps(key, ensure_ascii=False)}  ({where})")
    for key in sorted(set(english) - set(keys)):
        problems += 1
        print(f"unused: {json.dumps(key, ensure_ascii=False)}")
    for key, value in english.items():
        if CYRILLIC.search(value):
            problems += 1
            print(f"not translated: {json.dumps(key, ensure_ascii=False)}")
    # Russian literals in the code outside any localizable call (lines with a key are fine).
    lines_with_keys = {loc for locs in keys.values() for loc in locs}
    for path in sorted((ROOT / "MXCtl").glob("*.swift")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            code = line.split("//")[0] if not line.strip().startswith('"') else line
            if (path.name, number) in lines_with_keys or "Log." in code or "// no-l10n" in line:
                continue
            for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', code):
                if CYRILLIC.search(literal):
                    problems += 1
                    print(f"not localizable: {path.name}:{number}: {literal}")
    print(f"{len(keys)} keys in the code, {len(english)} translated, {problems} problems")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
