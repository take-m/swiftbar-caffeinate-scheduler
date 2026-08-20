#!/bin/bash
#
# Tests for the schedule logic.
#
# `date` is replaced with a shell function so any weekday and time can be
# injected without touching the system clock.
#
#   ./tests/test_schedule.sh
#
# Run it with /bin/bash explicitly to exercise bash 3.2, which is what macOS
# ships and therefore what SwiftBar runs the plugin under.
#
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$SCRIPT_DIR/../caffeinate-scheduler.30s.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export XDG_CONFIG_HOME="$TMP/config"
export SWIFTBAR_PLUGIN_DATA_PATH="$TMP/state"

# Load only the pure functions, not the plugin body.
export CAFFEINATE_SCHEDULER_LIB_ONLY=1
# shellcheck source=/dev/null
. "$PLUGIN"

PASS=0
FAIL=0

# The clock to inject.
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

# assert <in|out> <weekday> <hour> <minute> <schedule> <description>
assert() {
    local expect="$1" dow="$2" hh="$3" mm="$4" sched="$5" desc="$6"
    MOCK_DOW="$dow" MOCK_HH="$hh" MOCK_MM="$mm"
    # shellcheck disable=SC2034  # in_schedule reads this
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
    # shellcheck disable=SC2086  # splitting the fixture is the point
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

echo "in_schedule: weekdays 09:00-22:00"
S="1-5 09:00-22:00"
assert out 1 08 59 "$S" "Mon 08:59 is just before the window"
assert in 1 09 00 "$S" "Mon 09:00 is the exact start"
assert in 3 15 30 "$S" "Wed 15:30 is inside"
assert out 5 22 00 "$S" "Fri 22:00 is the exact end, exclusive"
assert out 6 15 00 "$S" "Sat 15:00 is not a listed weekday"
assert out 7 12 00 "$S" "Sun is not a listed weekday"

echo "in_schedule: multiple windows"
S="1-5 09:00-22:00; 6 10:00-18:00"
assert in 6 12 00 "$S" "Sat 12:00 matches the second window"
assert out 6 09 00 "$S" "Sat 09:00 is before the second window"
assert in 2 20 00 "$S" "Tue 20:00 matches the first window"
assert out 7 12 00 "$S" "Sun matches neither window"

echo "in_schedule: window wrapping past midnight (22:00-02:00)"
S="1-5 22:00-02:00"
assert in 1 23 30 "$S" "Mon 23:30 is on the opening side"
assert in 2 01 00 "$S" "Tue 01:00 continues Monday's window"
assert out 2 03 00 "$S" "Tue 03:00 is past the window"
assert in 6 01 00 "$S" "Sat 01:00 continues Friday's window"
assert out 6 23 00 "$S" "Sat 23:00 is not a listed weekday"
assert out 1 21 59 "$S" "Mon 21:59 is just before the window"

echo "in_schedule: no restriction"
assert in 7 03 00 "" "an empty schedule always matches"

echo "in_schedule: whitespace and separator noise"
assert in 1 12 00 "  1-5   09:00-22:00  " "stray spaces around and within"
assert in 1 12 00 "1-5 09:00-22:00;" "trailing semicolon"
assert in 1 12 00 ";;1-5 09:00-22:00" "leading empty entries"
assert in 6 12 00 "1-5 09:00-22:00 ; 6 10:00-18:00" "spaces around the semicolon"
assert out 1 12 00 "1-5" "an entry with no time range is ignored"
assert out 1 12 00 "garbage" "an unparseable entry is ignored"

echo "power_gate"
# assert_gate <gate|pass> <require_ac> <floor> <source> <pct> <description> [reason]
assert_gate() {
    local expect="$1" req="$2" floor="$3" src="$4" pct="$5" desc="$6" want_reason="${7:-}"

    local actual="pass"
    POWER_GATE_REASON=""
    if power_gate "$req" "$floor" "$src" "$pct"; then actual="gate"; fi

    if [ "$actual" != "$expect" ]; then
        FAIL=$((FAIL + 1))
        printf '  FAIL  %s  (expected %s, got %s)\n' "$desc" "$expect" "$actual"
    elif [ -n "$want_reason" ] && [ "$POWER_GATE_REASON" != "$want_reason" ]; then
        FAIL=$((FAIL + 1))
        printf '  FAIL  %s  (expected reason %s, got "%s")\n' \
            "$desc" "$want_reason" "$POWER_GATE_REASON"
    else
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$desc"
    fi
}

assert_gate pass false 0 battery 5 "everything disabled never gates"
assert_gate pass false 0 ac 100 "everything disabled on AC never gates"

assert_gate gate true 0 battery 80 "REQUIRE_AC gates on battery power" no_ac
assert_gate pass true 0 ac 80 "REQUIRE_AC passes on AC power"

assert_gate gate false 20 battery 19 "below the floor on battery gates" battery_low
assert_gate pass false 20 battery 20 "exactly at the floor does not gate"
assert_gate pass false 20 battery 21 "above the floor does not gate"
assert_gate pass false 20 ac 10 "below the floor on AC does not gate"
assert_gate pass false 20 battery "" "unknown percentage does not gate"

assert_gate gate true 20 battery 50 "REQUIRE_AC is reported before the floor" no_ac

assert_gate pass false garbage battery 5 "a non-numeric floor is ignored"
assert_gate pass false 20 "" 10 "an unknown power source does not gate"

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
