#!/usr/bin/env bash
# bk-celery-watchdog-check.sh
# 单次探测 + 判定 + 自愈。由 bk-celery-watchdog-loop.sh 周期调用。
# 仅适用于 RabbitMQ broker 模式。需要 bash 4.0+(关联数组)。

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "FATAL bk-celery-watchdog requires bash 4.0+ (got ${BASH_VERSION:-unknown})" >&2
    exit 1
fi

set -uo pipefail

# ============================================================================
# 配置区
# ============================================================================

APP_CODE="${APP_ID:-${BK_CELERY_WATCHDOG_APP_CODE:-bk_usermgr}}"

RMQ_HOST="${BK_CELERY_WATCHDOG_RABBITMQ_HOST:-${RABBITMQ_HOST:-}}"
RMQ_PORT="${BK_CELERY_WATCHDOG_RABBITMQ_MGMT_PORT:-${BKAPP_RABBITMQ_MGMT_PORT:-15672}}"
RMQ_VHOST="${BK_CELERY_WATCHDOG_RABBITMQ_VHOST:-${RABBITMQ_VHOST:-}}"
RMQ_USER="${BK_CELERY_WATCHDOG_RABBITMQ_USERNAME:-${RABBITMQ_USER:-}}"
RMQ_PASS="${BK_CELERY_WATCHDOG_RABBITMQ_PASSWORD:-${RABBITMQ_PASSWORD:-}}"

SUPERVISOR_CONF="${BK_CELERY_WATCHDOG_SUPERVISOR_CONF:-/data/bkce/etc/supervisor-usermgr-api.conf}"
SUPERVISORCTL_OVERRIDE="${BK_CELERY_WATCHDOG_SUPERVISORCTL:-}"
SUPERVISOR_BIN_DIR="${BK_CELERY_WATCHDOG_SUPERVISOR_BIN_DIR:-}"
SUPERVISORCTL=""
PYTHON_OVERRIDE="${BK_CELERY_WATCHDOG_PYTHON:-}"
PYTHON_BIN=""
STATE_DIR="${BK_CELERY_WATCHDOG_STATE_DIR:-${BK_LOG_DIR:-/data/bkce/logs/usermgr}/celery-watchdog}"
LOG_TAG="bk-celery-watchdog"

# 判定阈值
ACK_RATE_THRESHOLD="${BK_CELERY_WATCHDOG_ACK_RATE_THRESHOLD:-0.01}"
STUCK_CYCLES_THRESHOLD="${BK_CELERY_WATCHDOG_STUCK_CYCLES:-8}"

# 熔断
RESTART_QUOTA="${BK_CELERY_WATCHDOG_RESTART_QUOTA:-3}"
RESTART_WINDOW="${BK_CELERY_WATCHDOG_RESTART_WINDOW:-3600}"

DRY_RUN="${DRY_RUN:-0}"

# 队列 -> worker(supervisor program 名)映射
declare -A Q2W=()

# ============================================================================
# Docker 日志帮助函数
# ============================================================================

write_log() {
    local level="$1"
    shift
    printf '%s [%s] %s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$LOG_TAG" "$level" "$*"
}

log()  { write_log "INFO" "$*"; }
warn() { write_log "WARN" "$*"; }
err()  { write_log "ERROR" "$*" >&2; }

resolve_supervisorctl() {
    if [ -n "$SUPERVISORCTL_OVERRIDE" ]; then
        echo "$SUPERVISORCTL_OVERRIDE"
        return 0
    fi
    if command -v supervisorctl >/dev/null 2>&1; then
        echo "supervisorctl"
        return 0
    fi
    if [ -n "$SUPERVISOR_BIN_DIR" ] && [ -x "${SUPERVISOR_BIN_DIR%/}/supervisorctl" ]; then
        echo "${SUPERVISOR_BIN_DIR%/}/supervisorctl"
        return 0
    fi
    return 1
}

resolve_python() {
    if [ -n "$PYTHON_OVERRIDE" ]; then
        echo "$PYTHON_OVERRIDE"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        echo "python3"
        return 0
    fi
    if command -v python >/dev/null 2>&1; then
        echo "python"
        return 0
    fi
    return 1
}

init_queue_mapping() {
    if [ -z "$APP_CODE" ]; then
        err "FATAL missing env APP_ID or BK_CELERY_WATCHDOG_APP_CODE"
        exit 2
    fi

    Q2W[celery]="usermgrapi-worker"
}

# ============================================================================
# 启动校验
# ============================================================================

init_queue_mapping

if ! command -v curl >/dev/null 2>&1; then
    err "FATAL curl not found"
    exit 2
fi

PYTHON_BIN="$(resolve_python)" || {
    err "FATAL python not found: set BK_CELERY_WATCHDOG_PYTHON or install python3/python"
    exit 2
}

if [ -z "$RMQ_HOST" ] || [ -z "$RMQ_VHOST" ] || [ -z "$RMQ_USER" ] || [ -z "$RMQ_PASS" ]; then
    err "FATAL missing RabbitMQ management config; set RABBITMQ_* or BK_CELERY_WATCHDOG_RABBITMQ_* envs"
    exit 2
fi

mkdir -p "$STATE_DIR" || {
    err "FATAL cannot create state dir: $STATE_DIR"
    exit 2
}

SUPERVISORCTL="$(resolve_supervisorctl)" || {
    err "FATAL supervisorctl not found: not on PATH, and BK_CELERY_WATCHDOG_SUPERVISOR_BIN_DIR has no executable supervisorctl"
    exit 2
}

if [ "$(basename -- "$SUPERVISORCTL")" != "supervisorctl" ]; then
    warn "resolved supervisor binary is not named 'supervisorctl': $SUPERVISORCTL (restart may fail; check config)"
fi

# ============================================================================
# 工具函数
# ============================================================================

float_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit (a < b) ? 0 : 1 }'
}

now_ms() {
    local v
    v=$(date +%s%3N 2>/dev/null)
    case "$v" in
        ''|*[!0-9]*) echo "$(date +%s)000" ;;
        *) echo "$v" ;;
    esac
}

urlencode() {
    "$PYTHON_BIN" -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

get_stuck() {
    local queue="$1"
    cat "$STATE_DIR/${queue}.stuck_cycles" 2>/dev/null || echo 0
}

set_stuck() {
    local queue="$1" value="$2"
    echo "$value" > "$STATE_DIR/${queue}.stuck_cycles"
    if [ "$value" = "1" ]; then
        date '+%Y-%m-%dT%H:%M:%S%z' > "$STATE_DIR/${queue}.stuck_first_seen"
    fi
}

clear_stuck() {
    local queue="$1"
    rm -f "$STATE_DIR/${queue}.stuck_cycles" "$STATE_DIR/${queue}.stuck_first_seen" 2>/dev/null || true
}

get_stuck_first_seen() {
    local queue="$1"
    cat "$STATE_DIR/${queue}.stuck_first_seen" 2>/dev/null || echo "-"
}

can_restart() {
    local worker="$1"
    local hist="$STATE_DIR/restart_${worker}.hist"
    local now valid="" count=0
    now=$(date +%s)

    if [ -f "$hist" ]; then
        while read -r ts; do
            [ -z "$ts" ] && continue
            if [ $((now - ts)) -lt "$RESTART_WINDOW" ]; then
                valid+="$ts"$'\n'
                count=$((count + 1))
            fi
        done < "$hist"
    fi

    printf "%s" "$valid" > "$hist"
    [ "$count" -lt "$RESTART_QUOTA" ]
}

record_restart() {
    local worker="$1"
    echo "$(date +%s)" >> "$STATE_DIR/restart_${worker}.hist"
}

do_restart() {
    local worker="$1" reason="$2"

    if [ "$DRY_RUN" = "1" ]; then
        warn "DRY_RUN would_restart worker=$worker reason=$reason"
        return 0
    fi

    if ! can_restart "$worker"; then
        warn "QUOTA_EXCEEDED worker=$worker reason=$reason"
        return 0
    fi

    log "RESTART worker=$worker reason=$reason"
    if $SUPERVISORCTL -c "$SUPERVISOR_CONF" restart "$worker" 2>&1; then
        record_restart "$worker"
    else
        warn "RESTART_FAILED worker=$worker (supervisorctl non-zero exit)"
        record_restart "$worker"
    fi
}

# ============================================================================
# 采集
# ============================================================================

URL="http://$RMQ_HOST:$RMQ_PORT/api/queues/$RMQ_VHOST"
URL+="?columns=name,messages,messages_ready,messages_unacknowledged,consumers,message_stats.ack_details.rate"

tmpfile=$(mktemp 2>/dev/null) || tmpfile="/tmp/bk-watchdog-$$.body"
http_code=$(curl -s --max-time 15 -u "$RMQ_USER:$RMQ_PASS" \
    -o "$tmpfile" -w "%{http_code}" "$URL" 2>/dev/null)
curl_exit=$?
snapshot=$(cat "$tmpfile" 2>/dev/null)
rm -f "$tmpfile"

if [ "$curl_exit" -ne 0 ]; then
    err "FATAL management API curl failed curl_exit=$curl_exit url=$URL"
    exit 2
fi

if [ "$http_code" != "200" ]; then
    err "FATAL management API non-2xx http_code=$http_code url=$URL"
    exit 2
fi

if [ -z "$snapshot" ]; then
    err "FATAL management API returned empty body http_code=$http_code url=$URL"
    exit 2
fi

rows=$(printf '%s' "$snapshot" | "$PYTHON_BIN" -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception as exc:
    sys.stderr.write("json parse failed: %s\n" % exc)
    sys.exit(1)

for item in data:
    stats = item.get("message_stats") or {}
    ack_details = stats.get("ack_details") or {}
    fields = [
        item.get("name") or "",
        item.get("messages") or 0,
        item.get("messages_ready") or 0,
        item.get("messages_unacknowledged") or 0,
        item.get("consumers") or 0,
        ack_details.get("rate") or 0,
    ]
    print("\t".join(str(field) for field in fields))
') || {
    err "FATAL python failed to parse response"
    exit 2
}

# ============================================================================
# 判定
# ============================================================================

start_ms=$(now_ms)

queues_seen=0
healthy_count=0
progressing_count=0
restart_count=0

while IFS=$'\t' read -r queue messages ready unacked consumers ack_rate; do
    [ -z "$queue" ] && continue

    worker="${Q2W[$queue]:-}"
    if [ -z "$worker" ]; then
        continue
    fi
    queues_seen=$((queues_seen + 1))

    if [ "$messages" -le 0 ]; then
        clear_stuck "$queue"
        healthy_count=$((healthy_count + 1))
        continue
    fi

    if ! float_lt "$ack_rate" "$ACK_RATE_THRESHOLD"; then
        clear_stuck "$queue"
        healthy_count=$((healthy_count + 1))
        continue
    fi

    prev=$(get_stuck "$queue")
    cur=$((prev + 1))
    set_stuck "$queue" "$cur"

    if [ "$cur" -lt "$STUCK_CYCLES_THRESHOLD" ]; then
        first_seen=$(get_stuck_first_seen "$queue")
        log "MAYBE_STUCK queue=$queue worker=$worker messages=$messages ready=$ready unacked=$unacked consumers=$consumers ack_rate=$ack_rate cycles=$cur/$STUCK_CYCLES_THRESHOLD first_seen=$first_seen"
        progressing_count=$((progressing_count + 1))
        continue
    fi

    first_seen=$(get_stuck_first_seen "$queue")
    reason="messages=$messages ready=$ready unacked=$unacked consumers=$consumers ack_rate=$ack_rate cycles=$cur first_seen=$first_seen"
    do_restart "$worker" "$reason"
    clear_stuck "$queue"
    restart_count=$((restart_count + 1))
done <<< "$rows"

end_ms=$(now_ms)
took_ms=$((end_ms - start_ms))
log "TICK queues=$queues_seen healthy=$healthy_count progressing=$progressing_count restarts=$restart_count took=${took_ms}ms"
