#!/usr/bin/env python3
"""macOS 標準の bash 3.2 で壊れる構文を検出する。

macOS には bash 3.2.57 (2007年) しか同梱されておらず、SwiftBar プラグインは
それで動く必要がある。ShellCheck はバージョン差のこの手の落とし穴までは
見てくれないので、既知のものをここで潰す。

    ./tests/lint_bash32.py caffeinate-scheduler.30s.sh
"""

import re
import sys

# $( ) の中に case のパターンを書くと、閉じ括弧がコマンド置換の終端と
# 誤認されて "syntax error near unexpected token" になる。
# 例: result="$( ... case "$x" in *-*) ... esac ... )"
CASE_IN_SUBST = "case-in-command-substitution"

# ${var#"${var%%...}"} のような入れ子のクォート付きパラメータ展開。
NESTED_QUOTED_EXPANSION = re.compile(r'\$\{[^{}]*"\$\{')

# bash 4 以降でしか使えない機能。
BASH4_FEATURES = [
    (re.compile(r"\bdeclare\s+-A\b"), "連想配列 (declare -A) は bash 4 以降"),
    (re.compile(r"\bmapfile\b|\breadarray\b"), "mapfile/readarray は bash 4 以降"),
    (re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*\^\^"), "${var^^} は bash 4 以降"),
    (re.compile(r"\$\{[A-Za-z_][A-Za-z0-9_]*,,"), "${var,,} は bash 4 以降"),
    (re.compile(r"&>>"), "&>> は bash 4 以降"),
    (re.compile(r"\|&"), "|& は bash 4 以降"),
]


def find_case_in_substitution(text):
    """$( ) の内側に case キーワードが現れる箇所の行番号を返す。"""
    hits = []
    i = 0
    n = len(text)
    while i < n - 1:
        if text[i] == "$" and text[i + 1] == "(" and not text.startswith("$((", i):
            depth = 1
            j = i + 2
            start = j
            while j < n and depth > 0:
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                j += 1
            body = text[start : j - 1]
            if re.search(r"(^|[\s;])case\s", body):
                hits.append(text.count("\n", 0, i) + 1)
            i = j
        else:
            i += 1
    return hits


def check(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()

    problems = []

    for line in find_case_in_substitution(text):
        problems.append((line, CASE_IN_SUBST, "$( ) の中の case は bash 3.2 で構文エラーになる"))

    for match in NESTED_QUOTED_EXPANSION.finditer(text):
        line = text.count("\n", 0, match.start()) + 1
        problems.append((line, "nested-quoted-expansion", "入れ子のクォート付き展開は bash 3.2 で挙動が異なる"))

    for pattern, message in BASH4_FEATURES:
        for match in pattern.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            problems.append((line, "bash4-only", message))

    return sorted(problems)


def main(argv):
    if len(argv) < 2:
        print("usage: lint_bash32.py FILE...", file=sys.stderr)
        return 2

    failed = False
    for path in argv[1:]:
        problems = check(path)
        for line, rule, message in problems:
            print(f"{path}:{line}: [{rule}] {message}", file=sys.stderr)
            failed = True
        if not problems:
            print(f"  ok    {path}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
