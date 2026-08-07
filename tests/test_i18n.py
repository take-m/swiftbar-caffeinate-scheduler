#!/usr/bin/env python3
"""Check the translation catalogues for consistency.

Verifies that every msg_<lang> function defines the same set of keys and the
same printf format specifiers. A mismatched format is the nasty case: the
display breaks, or printf silently drops an argument, but only for whichever
language you were not testing in.

    ./tests/test_i18n.py caffeinate-scheduler.30s.sh
"""

import re
import sys

CATALOG_RE = re.compile(r"^msg_([a-z]{2})\(\) \{$")
ENTRY_RE = re.compile(r'^\s*([a-z0-9_]+)\)\s*echo\s+"(.*)"\s*;;\s*$')
FORMAT_RE = re.compile(r"%[-+ #0]*[0-9*]*(?:\.[0-9*]+)?[a-zA-Z%]")

# English is the fallback, so it must exist.
BASE_LANG = "en"


def parse_catalogs(path):
    """Return {lang: {key: text}}."""
    catalogs = {}
    lang = None

    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")

            header = CATALOG_RE.match(line)
            if header:
                lang = header.group(1)
                catalogs[lang] = {}
                continue

            if lang is None:
                continue

            if line == "}":
                lang = None
                continue

            entry = ENTRY_RE.match(line)
            if entry:
                catalogs[lang][entry.group(1)] = entry.group(2)

    return catalogs


def main(argv):
    if len(argv) < 2:
        print("usage: test_i18n.py FILE", file=sys.stderr)
        return 2

    path = argv[1]
    catalogs = parse_catalogs(path)
    failures = []

    if BASE_LANG not in catalogs:
        print(f"{path}: msg_{BASE_LANG} not found", file=sys.stderr)
        return 1

    if len(catalogs) < 2:
        print(f"{path}: only one catalogue found, nothing to compare", file=sys.stderr)
        return 1

    base = catalogs[BASE_LANG]
    print(f"catalogs: {', '.join(sorted(catalogs))}  ({len(base)} keys in {BASE_LANG})")

    for lang in sorted(catalogs):
        if lang == BASE_LANG:
            continue
        other = catalogs[lang]

        for key in sorted(set(base) - set(other)):
            failures.append(f"msg_{lang}: key '{key}' is untranslated")
        for key in sorted(set(other) - set(base)):
            failures.append(
                f"msg_{lang}: key '{key}' does not exist in msg_{BASE_LANG}"
            )

        for key in sorted(set(base) & set(other)):
            base_fmt = FORMAT_RE.findall(base[key])
            other_fmt = FORMAT_RE.findall(other[key])
            if base_fmt != other_fmt:
                failures.append(
                    f"msg_{lang}: format specifiers differ for key '{key}' "
                    f"({BASE_LANG}={base_fmt or 'none'} / {lang}={other_fmt or 'none'})"
                )

        if not failures:
            print(f"  ok    msg_{lang} matches msg_{BASE_LANG} ({len(other)} keys)")

    # Find keys that are defined in a catalogue but never passed to t().
    with open(path, encoding="utf-8") as fh:
        source = fh.read()
    body = source.split("# ---", 1)[-1]
    for key in sorted(base):
        if not re.search(rf"\bt {re.escape(key)}\b", body):
            failures.append(f"key '{key}' is defined but never passed to t()")

    for message in failures:
        print(f"  FAIL  {message}", file=sys.stderr)

    if failures:
        print(f"\n{len(failures)} failed", file=sys.stderr)
        return 1

    print("\nall catalogs consistent")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
