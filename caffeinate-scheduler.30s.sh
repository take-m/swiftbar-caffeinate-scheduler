#!/bin/bash
#
# <xbar.title>Caffeinate Scheduler</xbar.title>
# <xbar.version>v1.1.0</xbar.version>
# <xbar.author>yoshitake</xbar.author>
# <xbar.author.github>take-m</xbar.author.github>
# <xbar.desc>Keeps macOS awake only while a watched process is running, and only inside the days and hours you configure. Built for Claude Code Remote Control sessions.</xbar.desc>
# <xbar.dependencies>bash</xbar.dependencies>
# <xbar.abouturl>https://github.com/take-m/swiftbar-caffeinate-scheduler</xbar.abouturl>
#
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

set -u
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# SwiftBar's bash= needs an absolute path, so resolve one even if we were
# invoked by a relative path.
SELF="${SWIFTBAR_PLUGIN_PATH:-$0}"
case "$SELF" in
    /*) : ;;
    *) SELF="$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")" ;;
esac

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/caffeinate-scheduler"
CONFIG_FILE="$CONFIG_DIR/config.sh"
STATE_DIR="${SWIFTBAR_PLUGIN_DATA_PATH:-$HOME/.local/state/caffeinate-scheduler}"
PID_FILE="$STATE_DIR/caffeinate.pid"
MODE_FILE="$STATE_DIR/mode"
SEEN_FILE="$STATE_DIR/last_seen"
OVERRIDE_FILE="$STATE_DIR/override_until"

mkdir -p "$CONFIG_DIR" "$STATE_DIR" 2>/dev/null

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

write_default_config() {
    cat >"$CONFIG_FILE" <<'DEFAULTS'
# caffeinate-scheduler configuration.
# Changes take effect on the next refresh, or pick "Refresh now" from the menu.

# Menu language: auto | en | ja
# "auto" follows the macOS system locale and falls back to English.
UI_LANGUAGE="auto"

# Processes to watch. Substring matches against the `ps` argument line,
# separated by |. If you turned on Claude Code Remote Control for all
# sessions, loosen this to WATCH_PATTERNS="claude".
WATCH_PATTERNS="claude remote-control|claude --remote-control|claude --rc"

# When the rules are allowed to apply. Separate multiple windows with ;
# Weekday numbers follow `date +%u`: 1=Mon ... 7=Sun.
# Ranges (1-5) and lists (1,3,5) both work.
# If start > end the window wraps past midnight, e.g. "1-5 22:00-02:00".
# An empty string means no time restriction.
SCHEDULE="1-5 09:00-22:00"

# Keep preventing sleep for this many minutes after the watched process exits.
GRACE_MINUTES=5

# Flags passed to caffeinate.
#   -i   prevent idle system sleep (display still turns off) - usually enough
#   -di  also keep the display on
#   -m   also prevent disk sleep
CAFFEINATE_FLAGS="-i"
DEFAULTS
}

[ -f "$CONFIG_FILE" ] || write_default_config

# ---------------------------------------------------------------------------
# Strings (i18n)
#
# To add a language, add one msg_<code> function. Nothing else needs to change:
# t() falls back to English for any key a catalogue is missing, so a partial
# translation still renders. tests/test_i18n.py catches missing or stray keys.
# ---------------------------------------------------------------------------

msg_en() {
    case "$1" in
        header_blocking) echo "Keeping this Mac awake" ;;
        header_idle) echo "Not keeping this Mac awake" ;;
        reason_override) echo "Override active - %d min left" ;;
        reason_mode_off) echo "Turned off manually" ;;
        reason_mode_always) echo "Always on, set manually" ;;
        reason_outside) echo "Outside the scheduled hours" ;;
        reason_inside_nowatch) echo "Within schedule, process watching disabled" ;;
        reason_matched) echo "Matching processes: %d" ;;
        reason_grace) echo "Grace period - %d min left" ;;
        reason_no_match) echo "Within schedule, nothing matched" ;;
        section_matches) echo "Matching processes" ;;
        label_schedule) echo "Schedule: %s" ;;
        label_watch) echo "Watching: %s" ;;
        value_unrestricted) echo "no restriction" ;;
        value_none) echo "none" ;;
        mode_auto) echo "Automatic" ;;
        mode_always) echo "Always on" ;;
        mode_off) echo "Always off" ;;
        override_1h) echo "Keep awake for 1 hour" ;;
        override_3h) echo "Keep awake for 3 hours" ;;
        override_cancel) echo "Cancel the override" ;;
        foreign_label) echo "Other caffeinate processes: %s" ;;
        foreign_stop) echo "Stop all of them" ;;
        action_edit) echo "Edit configuration" ;;
        action_reset) echo "Reset configuration" ;;
        action_refresh) echo "Refresh now" ;;
    esac
}

msg_ja() {
    case "$1" in
        header_blocking) echo "スリープ抑止中" ;;
        header_idle) echo "抑止していません" ;;
        reason_override) echo "一時的に ON - 残り %d 分" ;;
        reason_mode_off) echo "手動で OFF" ;;
        reason_mode_always) echo "手動で常時 ON" ;;
        reason_outside) echo "時間帯外" ;;
        reason_inside_nowatch) echo "時間帯内、プロセス監視は無効" ;;
        reason_matched) echo "一致するプロセス %d 件" ;;
        reason_grace) echo "猶予期間中 - 残り %d 分" ;;
        reason_no_match) echo "時間帯内だが一致なし" ;;
        section_matches) echo "パターンに一致するプロセス" ;;
        label_schedule) echo "スケジュール: %s" ;;
        label_watch) echo "監視: %s" ;;
        value_unrestricted) echo "制限なし" ;;
        value_none) echo "なし" ;;
        mode_auto) echo "自動" ;;
        mode_always) echo "常に ON" ;;
        mode_off) echo "常に OFF" ;;
        override_1h) echo "今だけ 1 時間 ON" ;;
        override_3h) echo "今だけ 3 時間 ON" ;;
        override_cancel) echo "一時 ON を取り消す" ;;
        foreign_label) echo "他の caffeinate: %s" ;;
        foreign_stop) echo "すべて停止" ;;
        action_edit) echo "設定を編集" ;;
        action_reset) echo "設定を初期化" ;;
        action_refresh) echo "今すぐ更新" ;;
    esac
}

# Guess the language from the macOS system locale.
detect_lang() {
    local loc=""
    loc="$(defaults read -g AppleLocale 2>/dev/null)"
    [ -n "$loc" ] || loc="${LANG:-}"
    case "$loc" in
        ja*) printf 'ja' ;;
        *) printf 'en' ;;
    esac
}

# t <key> [printf arguments...]
t() {
    local key="$1" fmt=""
    shift
    fmt="$("msg_${UI_LANG:-en}" "$key" 2>/dev/null)"
    [ -n "$fmt" ] || fmt="$(msg_en "$key")"
    [ -n "$fmt" ] || fmt="$key"
    # shellcheck disable=SC2059  # fmt comes from our own catalogue, so it is trusted
    printf "$fmt" "$@"
}

# ---------------------------------------------------------------------------
# Schedule evaluation (pure functions, no side effects)
# ---------------------------------------------------------------------------

# Is weekday $1 (1-7) covered by the spec $2 ("1-5" / "1,3,5" / "1-5,7")?
day_match() {
    local d="$1" spec="$2" part lo hi old_ifs
    old_ifs="$IFS"
    IFS=','
    for part in $spec; do
        IFS="$old_ifs"
        case "$part" in
            *-*)
                lo="${part%%-*}"
                hi="${part##*-}"
                if [ "$d" -ge "$lo" ] && [ "$d" -le "$hi" ]; then
                    return 0
                fi
                ;;
            *)
                if [ "$d" = "$part" ]; then
                    return 0
                fi
                ;;
        esac
        IFS=','
    done
    IFS="$old_ifs"
    return 1
}

# "09:00" -> 540
hhmm_to_min() {
    local hh="${1%%:*}" mm="${1##*:}"
    echo $((10#$hh * 60 + 10#$mm))
}

# Return 0 if the current time falls inside any window in $SCHEDULE.
#
# Do not introduce a $( ) command substitution here. macOS ships bash 3.2, whose
# parser mistakes the ) closing a case pattern inside $( ) for the end of the
# substitution and raises a syntax error. A plain for loop also lets us return
# directly instead of round-tripping a result through a subshell.
in_schedule() {
    [ -z "${SCHEDULE:-}" ] && return 0

    local dow now_min prev entry days range fmin tmin old_ifs
    dow="$(date +%u)"
    now_min=$((10#$(date +%H) * 60 + 10#$(date +%M)))
    prev=$((dow == 1 ? 7 : dow - 1))

    old_ifs="$IFS"
    IFS=';'
    for entry in $SCHEDULE; do
        IFS="$old_ifs"

        # Split "days start-end" using default-IFS word splitting, which also
        # discards any leading, trailing or repeated spaces for free.
        # shellcheck disable=SC2086  # word splitting is the point here
        set -- $entry
        days="${1:-}"
        range="${2:-}"

        if [ -n "$days" ] && [ "${range%%-*}" != "$range" ]; then
            fmin="$(hhmm_to_min "${range%%-*}")"
            tmin="$(hhmm_to_min "${range##*-}")"

            if [ "$fmin" -le "$tmin" ]; then
                if day_match "$dow" "$days" &&
                    [ "$now_min" -ge "$fmin" ] && [ "$now_min" -lt "$tmin" ]; then
                    IFS="$old_ifs"
                    return 0
                fi
            else
                # Window wrapping past midnight
                if day_match "$dow" "$days" && [ "$now_min" -ge "$fmin" ]; then
                    IFS="$old_ifs"
                    return 0
                fi
                if day_match "$prev" "$days" && [ "$now_min" -lt "$tmin" ]; then
                    IFS="$old_ifs"
                    return 0
                fi
            fi
        fi

        IFS=';'
    done

    IFS="$old_ifs"
    return 1
}

# Hook that lets tests/ source the pure functions without running the plugin.
if [ -n "${CAFFEINATE_SCHEDULER_LIB_ONLY:-}" ]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# Actions invoked from the menu. Anything that does not need the config file
# is handled here and returns early.
# ---------------------------------------------------------------------------

case "${1:-}" in
    edit)
        open -t "$CONFIG_FILE"
        exit 0
        ;;
    reset-config)
        write_default_config
        exit 0
        ;;
    mode)
        printf '%s' "${2:-auto}" >"$MODE_FILE"
        rm -f "$OVERRIDE_FILE"
        exit 0
        ;;
    override)
        date -v"+${2:-60}M" +%s >"$OVERRIDE_FILE"
        exit 0
        ;;
    clear-override)
        rm -f "$OVERRIDE_FILE"
        exit 0
        ;;
    kill-foreign)
        pkill -x caffeinate
        exit 0
        ;;
esac

# shellcheck source=/dev/null
. "$CONFIG_FILE"

WATCH_PATTERNS="${WATCH_PATTERNS:-}"
SCHEDULE="${SCHEDULE:-}"
GRACE_MINUTES="${GRACE_MINUTES:-5}"
CAFFEINATE_FLAGS="${CAFFEINATE_FLAGS:--i}"

# Pick the display language. Anything other than en/ja falls back to detection.
case "${UI_LANGUAGE:-auto}" in
    en | ja) UI_LANG="${UI_LANGUAGE}" ;;
    *) UI_LANG="$(detect_lang)" ;;
esac

MODE="auto"
[ -f "$MODE_FILE" ] && MODE="$(cat "$MODE_FILE")"

# ---------------------------------------------------------------------------
# Process watching
# ---------------------------------------------------------------------------

PS_SNAPSHOT="$(ps -Ao pid=,args=)"
SELF_BASENAME="$(basename "$SELF")"

find_matches() {
    [ -z "$WATCH_PATTERNS" ] && return 0
    local pat old_ifs
    old_ifs="$IFS"
    IFS='|'
    for pat in $WATCH_PATTERNS; do
        IFS="$old_ifs"
        [ -z "$pat" ] && {
            IFS='|'
            continue
        }
        printf '%s\n' "$PS_SNAPSHOT" | grep -F -- "$pat" | grep -v -F -- "$SELF_BASENAME"
        IFS='|'
    done
    IFS="$old_ifs"
}

MATCHES="$(find_matches | sort -u -k1,1n | sed '/^$/d')"
MATCH_COUNT=0
[ -n "$MATCHES" ] && MATCH_COUNT="$(printf '%s\n' "$MATCHES" | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
# Starting and stopping caffeinate
# ---------------------------------------------------------------------------

our_pid() {
    [ -f "$PID_FILE" ] && cat "$PID_FILE"
}

is_our_caffeinate_alive() {
    local pid
    pid="$(our_pid)"
    [ -n "$pid" ] || return 1
    ps -p "$pid" -o comm= 2>/dev/null | grep -q 'caffeinate$'
}

start_block() {
    is_our_caffeinate_alive && return 0
    # shellcheck disable=SC2086
    nohup caffeinate $CAFFEINATE_FLAGS >/dev/null 2>&1 &
    printf '%s' "$!" >"$PID_FILE"
}

stop_block() {
    local pid
    pid="$(our_pid)"
    if [ -n "$pid" ] && ps -p "$pid" -o comm= 2>/dev/null | grep -q 'caffeinate$'; then
        kill "$pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
}

# ---------------------------------------------------------------------------
# Decide
# ---------------------------------------------------------------------------

NOW="$(date +%s)"
SHOULD_BLOCK=1 # 0 = prevent sleep
REASON=""

if [ -f "$OVERRIDE_FILE" ]; then
    UNTIL="$(cat "$OVERRIDE_FILE")"
    if [ "$NOW" -lt "$UNTIL" ]; then
        SHOULD_BLOCK=0
        REASON="$(t reason_override $(((UNTIL - NOW) / 60 + 1)))"
    else
        rm -f "$OVERRIDE_FILE"
    fi
fi

if [ -z "$REASON" ]; then
    case "$MODE" in
        off)
            SHOULD_BLOCK=1
            REASON="$(t reason_mode_off)"
            ;;
        always)
            SHOULD_BLOCK=0
            REASON="$(t reason_mode_always)"
            ;;
        *)
            MODE="auto"
            if ! in_schedule; then
                SHOULD_BLOCK=1
                REASON="$(t reason_outside)"
            elif [ -z "$WATCH_PATTERNS" ]; then
                SHOULD_BLOCK=0
                REASON="$(t reason_inside_nowatch)"
            elif [ "$MATCH_COUNT" -gt 0 ]; then
                printf '%s' "$NOW" >"$SEEN_FILE"
                SHOULD_BLOCK=0
                REASON="$(t reason_matched "$MATCH_COUNT")"
            else
                LAST_SEEN=0
                [ -f "$SEEN_FILE" ] && LAST_SEEN="$(cat "$SEEN_FILE")"
                ELAPSED=$((NOW - LAST_SEEN))
                if [ "$LAST_SEEN" -gt 0 ] && [ "$ELAPSED" -lt $((GRACE_MINUTES * 60)) ]; then
                    SHOULD_BLOCK=0
                    REASON="$(t reason_grace $(((GRACE_MINUTES * 60 - ELAPSED) / 60 + 1)))"
                else
                    SHOULD_BLOCK=1
                    REASON="$(t reason_no_match)"
                fi
            fi
            ;;
    esac
fi

if [ "$SHOULD_BLOCK" -eq 0 ]; then
    start_block
else
    stop_block
fi

# caffeinate processes we did not start (terminal, other apps)
OUR="$(our_pid)"
FOREIGN=""
for pid in $(pgrep -x caffeinate 2>/dev/null); do
    [ "$pid" = "$OUR" ] && continue
    FOREIGN="$FOREIGN $pid"
done
FOREIGN="$(printf '%s' "$FOREIGN" | sed 's/^ //')"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

check() { [ "$1" = "$MODE" ] && echo "true" || echo "false"; }
act="bash=\"$SELF\" terminal=false refresh=true"

if [ "$SHOULD_BLOCK" -eq 0 ]; then
    if [ -n "${SWIFTBAR:-}" ]; then
        echo "| sfimage=cup.and.saucer.fill sfcolor=#c98a3a"
    else
        echo "☕️"
    fi
else
    if [ -n "${SWIFTBAR:-}" ]; then
        echo "| sfimage=zzz sfcolor=#8a8a8a"
    else
        echo "💤"
    fi
fi

echo "---"

if [ "$SHOULD_BLOCK" -eq 0 ]; then
    echo "$(t header_blocking) | color=#c98a3a"
else
    echo "$(t header_idle) | color=#8a8a8a"
fi
echo "$REASON | size=12"

if [ "$SHOULD_BLOCK" -eq 0 ] && is_our_caffeinate_alive; then
    echo "caffeinate $CAFFEINATE_FLAGS  (PID $(our_pid)) | size=11 font=Menlo"
fi

if [ "$MATCH_COUNT" -gt 0 ]; then
    echo "---"
    echo "$(t section_matches) | size=12"
    printf '%s\n' "$MATCHES" | head -n 8 | while IFS= read -r line; do
        # | separates a menu item from its parameters, so any | inside a command
        # line has to be swapped for the fullwidth form to survive display.
        echo "${line//|/｜} | size=11 font=Menlo length=60"
    done
fi

echo "---"
echo "$(t label_schedule "${SCHEDULE:-$(t value_unrestricted)}") | size=12"
echo "$(t label_watch "${WATCH_PATTERNS:-$(t value_none)}") | size=12 length=50"

echo "---"
echo "$(t mode_auto) | $act param1=mode param2=auto checked=$(check auto)"
echo "$(t mode_always) | $act param1=mode param2=always checked=$(check always)"
echo "$(t mode_off) | $act param1=mode param2=off checked=$(check off)"

echo "---"
if [ -f "$OVERRIDE_FILE" ]; then
    echo "$(t override_cancel) | $act param1=clear-override"
else
    echo "$(t override_1h) | $act param1=override param2=60"
    echo "$(t override_3h) | $act param1=override param2=180 alternate=true"
fi

if [ -n "$FOREIGN" ]; then
    echo "---"
    echo "$(t foreign_label "$FOREIGN") | size=12"
    echo "$(t foreign_stop) | $act param1=kill-foreign"
fi

echo "---"
echo "$(t action_edit) | $act param1=edit"
echo "$(t action_reset) | $act param1=reset-config alternate=true"
echo "$(t action_refresh) | refresh=true"
