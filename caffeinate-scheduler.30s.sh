#!/bin/bash
#
# <xbar.title>Caffeinate Scheduler</xbar.title>
# <xbar.version>v1.0.0</xbar.version>
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

# SwiftBar の bash= は絶対パスを要求するので、相対パスで起動された場合も解決しておく
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
# 設定
# ---------------------------------------------------------------------------

write_default_config() {
    cat >"$CONFIG_FILE" <<'DEFAULTS'
# caffeinate-scheduler の設定
# 変更後は SwiftBar のメニューから「設定を再読み込み」を選ぶか、次の更新を待つ。

# 監視するプロセス。ps の引数行に対する部分一致を | で区切って列挙する。
# Claude Code の Remote Control を「すべてのセッションで有効」にしている場合は
# WATCH_PATTERNS="claude" のように緩めること。
WATCH_PATTERNS="claude remote-control|claude --remote-control|claude --rc"

# 有効にする曜日と時間帯。; で複数指定できる。
# 曜日は date +%u と同じで 1=月 … 7=日。範囲 (1-5) とカンマ (1,3,5) が使える。
# 開始 > 終了 の場合は日をまたぐ窓として扱う (例 "1-5 22:00-02:00")。
# 空文字にすると時間帯の制限なし。
SCHEDULE="1-5 09:00-22:00"

# 監視プロセスが消えてから抑止を解除するまでの猶予（分）。
GRACE_MINUTES=5

# caffeinate に渡すフラグ。
#   -i  システムのアイドルスリープを抑止（画面は消える。通常はこれで十分）
#   -di 画面も点けたままにする
#   -m  ディスクのスリープも抑止
CAFFEINATE_FLAGS="-i"
DEFAULTS
}

[ -f "$CONFIG_FILE" ] || write_default_config

# ---------------------------------------------------------------------------
# スケジュール判定（副作用のない純粋関数）
# ---------------------------------------------------------------------------

# 曜日 $1 (1-7) が指定 $2 ("1-5" / "1,3,5" / "1-5,7") に含まれるか
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

# 現在が $SCHEDULE のいずれかの窓の中なら 0 を返す
in_schedule() {
    [ -z "${SCHEDULE:-}" ] && return 0

    local dow now_min prev result
    dow="$(date +%u)"
    now_min=$((10#$(date +%H) * 60 + 10#$(date +%M)))
    prev=$((dow == 1 ? 7 : dow - 1))

    result="$(printf '%s\n' "$SCHEDULE" | tr ';' '\n' | while IFS= read -r entry; do
        entry="$(printf '%s' "$entry" | tr -s ' ' | sed 's/^ //; s/ $//')"
        [ -z "$entry" ] && continue

        days="${entry%% *}"
        range="${entry##* }"
        case "$range" in
            *-*) : ;;
            *) continue ;;
        esac

        fmin="$(hhmm_to_min "${range%%-*}")"
        tmin="$(hhmm_to_min "${range##*-}")"

        if [ "$fmin" -le "$tmin" ]; then
            if day_match "$dow" "$days" && [ "$now_min" -ge "$fmin" ] && [ "$now_min" -lt "$tmin" ]; then
                echo yes
                break
            fi
        else
            # 日をまたぐ窓
            if day_match "$dow" "$days" && [ "$now_min" -ge "$fmin" ]; then
                echo yes
                break
            fi
            if day_match "$prev" "$days" && [ "$now_min" -lt "$tmin" ]; then
                echo yes
                break
            fi
        fi
    done)"

    [ "$result" = "yes" ]
}

# tests/ から関数だけを読み込むためのフック
if [ -n "${CAFFEINATE_SCHEDULER_LIB_ONLY:-}" ]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi

# ---------------------------------------------------------------------------
# メニューから呼ばれるアクション（設定を読む前に処理できるものはここで返す）
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

MODE="auto"
[ -f "$MODE_FILE" ] && MODE="$(cat "$MODE_FILE")"

# ---------------------------------------------------------------------------
# プロセス監視
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
# caffeinate の起動・停止
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
# 判定
# ---------------------------------------------------------------------------

NOW="$(date +%s)"
SHOULD_BLOCK=1 # 0 = 抑止する
REASON=""

if [ -f "$OVERRIDE_FILE" ]; then
    UNTIL="$(cat "$OVERRIDE_FILE")"
    if [ "$NOW" -lt "$UNTIL" ]; then
        SHOULD_BLOCK=0
        REASON="一時的に ON（あと $(((UNTIL - NOW) / 60 + 1)) 分）"
    else
        rm -f "$OVERRIDE_FILE"
    fi
fi

if [ -z "$REASON" ]; then
    case "$MODE" in
        off)
            SHOULD_BLOCK=1
            REASON="手動で OFF"
            ;;
        always)
            SHOULD_BLOCK=0
            REASON="手動で常時 ON"
            ;;
        *)
            MODE="auto"
            if ! in_schedule; then
                SHOULD_BLOCK=1
                REASON="時間帯外"
            elif [ -z "$WATCH_PATTERNS" ]; then
                SHOULD_BLOCK=0
                REASON="時間帯内（プロセス監視なし）"
            elif [ "$MATCH_COUNT" -gt 0 ]; then
                printf '%s' "$NOW" >"$SEEN_FILE"
                SHOULD_BLOCK=0
                REASON="対象プロセス ${MATCH_COUNT} 件を検出"
            else
                LAST_SEEN=0
                [ -f "$SEEN_FILE" ] && LAST_SEEN="$(cat "$SEEN_FILE")"
                ELAPSED=$((NOW - LAST_SEEN))
                if [ "$LAST_SEEN" -gt 0 ] && [ "$ELAPSED" -lt $((GRACE_MINUTES * 60)) ]; then
                    SHOULD_BLOCK=0
                    REASON="猶予期間中（あと $(((GRACE_MINUTES * 60 - ELAPSED) / 60 + 1)) 分）"
                else
                    SHOULD_BLOCK=1
                    REASON="時間帯内だが対象プロセスなし"
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

# 自分以外の caffeinate（ターミナルや他アプリが起動したもの）
OUR="$(our_pid)"
FOREIGN=""
for pid in $(pgrep -x caffeinate 2>/dev/null); do
    [ "$pid" = "$OUR" ] && continue
    FOREIGN="$FOREIGN $pid"
done
FOREIGN="$(printf '%s' "$FOREIGN" | sed 's/^ //')"

# ---------------------------------------------------------------------------
# 出力
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
    echo "スリープ抑止中 | color=#c98a3a"
else
    echo "抑止していません | color=#8a8a8a"
fi
echo "$REASON | size=12"

if [ "$SHOULD_BLOCK" -eq 0 ] && is_our_caffeinate_alive; then
    echo "caffeinate $CAFFEINATE_FLAGS  (PID $(our_pid)) | size=11 font=Menlo"
fi

if [ "$MATCH_COUNT" -gt 0 ]; then
    echo "---"
    echo "パターンに一致するプロセス | size=12"
    printf '%s\n' "$MATCHES" | head -n 8 | while IFS= read -r line; do
        echo "${line//|/｜} | size=11 font=Menlo length=60"
    done
fi

echo "---"
echo "スケジュール: ${SCHEDULE:-制限なし} | size=12"
echo "監視: ${WATCH_PATTERNS:-なし} | size=12 length=50"

echo "---"
echo "自動 | $act param1=mode param2=auto checked=$(check auto)"
echo "常に ON | $act param1=mode param2=always checked=$(check always)"
echo "常に OFF | $act param1=mode param2=off checked=$(check off)"

echo "---"
if [ -f "$OVERRIDE_FILE" ]; then
    echo "一時 ON を取り消す | $act param1=clear-override"
else
    echo "今だけ 1 時間 ON | $act param1=override param2=60"
    echo "今だけ 3 時間 ON | $act param1=override param2=180 alternate=true"
fi

if [ -n "$FOREIGN" ]; then
    echo "---"
    echo "他の caffeinate: $FOREIGN | size=12"
    echo "すべて停止 | $act param1=kill-foreign"
fi

echo "---"
echo "設定を編集 | $act param1=edit"
echo "設定を初期化 | $act param1=reset-config alternate=true"
echo "今すぐ更新 | refresh=true"
