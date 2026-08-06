#!/bin/bash
#
# スケジュール判定ロジックのテスト。
# date を関数で差し替えて任意の日時を注入する。
#
#   ./tests/test_schedule.sh
#
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$SCRIPT_DIR/../caffeinate-scheduler.30s.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config"
export SWIFTBAR_PLUGIN_DATA_PATH="$TMP/state"

# 関数だけを読み込む
export CAFFEINATE_SCHEDULER_LIB_ONLY=1
# shellcheck source=/dev/null
. "$PLUGIN"

PASS=0
FAIL=0

# 注入する現在時刻
MOCK_DOW=1
MOCK_HH=12
MOCK_MM=00

date() {
    case "${1:-}" in
        +%u) echo "$MOCK_DOW" ;;
        +%H) printf '%02d\n' "$((10#$MOCK_HH))" ;;
        +%M) printf '%02d\n' "$((10#$MOCK_MM))" ;;
        *) command date "$@" ;;
    esac
}

# assert <期待 in|out> <曜日> <時> <分> <スケジュール> <説明>
assert() {
    local expect="$1" dow="$2" hh="$3" mm="$4" sched="$5" desc="$6"
    MOCK_DOW="$dow" MOCK_HH="$hh" MOCK_MM="$mm"
    # shellcheck disable=SC2034  # in_schedule が参照する
    SCHEDULE="$sched"

    local actual="out"
    if in_schedule; then actual="in"; fi

    if [ "$actual" = "$expect" ]; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$desc"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL  %s  (expected %s, got %s)\n' "$desc" "$expect" "$actual"
    fi
}

echo "hhmm_to_min"
for pair in "00:00 0" "09:00 540" "08:09 489" "23:59 1439"; do
    got="$(hhmm_to_min "${pair%% *}")"
    want="${pair##* }"
    if [ "$got" = "$want" ]; then
        PASS=$((PASS + 1))
        printf '  ok    %s -> %s\n' "${pair%% *}" "$got"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL  %s -> %s (expected %s)\n' "${pair%% *}" "$got" "$want"
    fi
done

echo "day_match"
for c in "1 1-5 0" "5 1-5 0" "6 1-5 1" "7 1-5,7 0" "3 1,3,5 0" "4 1,3,5 1"; do
    # shellcheck disable=SC2086  # 意図的に単語分割する
    set -- $c
    if day_match "$1" "$2"; then got=0; else got=1; fi
    if [ "$got" = "$3" ]; then
        PASS=$((PASS + 1))
        printf '  ok    day %s in %s\n' "$1" "$2"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL  day %s in %s\n' "$1" "$2"
    fi
done

echo "in_schedule: 平日 09:00-22:00"
S="1-5 09:00-22:00"
assert out 1 08 59 "$S" "月 08:59 は窓の直前"
assert in 1 09 00 "$S" "月 09:00 は開始ちょうど"
assert in 3 15 30 "$S" "水 15:30 は窓の中"
assert out 5 22 00 "$S" "金 22:00 は終了ちょうど（含まない）"
assert out 6 15 00 "$S" "土 15:30 は対象曜日外"
assert out 7 12 00 "$S" "日は対象曜日外"

echo "in_schedule: 複数の窓"
S="1-5 09:00-22:00; 6 10:00-18:00"
assert in 6 12 00 "$S" "土 12:00 は 2 つ目の窓"
assert out 6 09 00 "$S" "土 09:00 はまだ窓の外"
assert in 2 20 00 "$S" "火 20:00 は 1 つ目の窓"
assert out 7 12 00 "$S" "日はどの窓にも入らない"

echo "in_schedule: 日をまたぐ窓 (22:00-02:00)"
S="1-5 22:00-02:00"
assert in 1 23 30 "$S" "月 23:30 は開始日の側"
assert in 2 01 00 "$S" "火 01:00 は月曜の窓の続き"
assert out 2 03 00 "$S" "火 03:00 は窓を過ぎている"
assert in 6 01 00 "$S" "土 01:00 は金曜の窓の続き"
assert out 6 23 00 "$S" "土 23:00 は対象曜日外"
assert out 1 21 59 "$S" "月 21:59 は窓の直前"

echo "in_schedule: 制限なし"
assert in 7 03 00 "" "空文字なら常に窓の中"

echo "in_schedule: 空白や区切りの揺れ"
assert in 1 12 00 "  1-5   09:00-22:00  " "前後と途中の余分な空白"
assert in 1 12 00 "1-5 09:00-22:00;" "末尾に余分なセミコロン"
assert in 1 12 00 ";;1-5 09:00-22:00" "先頭に空のエントリ"
assert in 6 12 00 "1-5 09:00-22:00 ; 6 10:00-18:00" "セミコロンの前後に空白"
assert out 1 12 00 "1-5" "時間範囲がない不正なエントリは無視"
assert out 1 12 00 "garbage" "解釈できない文字列は無視"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
