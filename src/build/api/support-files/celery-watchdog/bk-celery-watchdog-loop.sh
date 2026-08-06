#!/usr/bin/env bash
# bk-celery-watchdog-loop.sh
# supervisor 长跑入口。每 INTERVAL 秒调用一次 check 脚本。
# 由 [program:usermgrapi-worker-watchdog] 拉起。

set -uo pipefail

VERSION="1.0.1-bkuser"
INTERVAL="${BK_CELERY_WATCHDOG_INTERVAL:-120}"
LOG_TAG="bk-celery-watchdog"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="${BK_CELERY_WATCHDOG_CHECK_SCRIPT:-$SCRIPT_DIR/bk-celery-watchdog-check.sh}"

log() {
    printf '%s [%s] INFO %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$LOG_TAG" "$*"
}

trap 'log "STOP received SIGTERM pid=$$"; exit 0' TERM INT

log "START version=$VERSION pid=$$ interval=${INTERVAL}s check_script=$CHECK_SCRIPT stuck_cycles=${BK_CELERY_WATCHDOG_STUCK_CYCLES:-8} restart_quota=${BK_CELERY_WATCHDOG_RESTART_QUOTA:-3} restart_window=${BK_CELERY_WATCHDOG_RESTART_WINDOW:-3600}s dry_run=${DRY_RUN:-0}"

while true; do
    "$CHECK_SCRIPT" || log "check exited non-zero (will retry next cycle)"
    sleep "$INTERVAL" &
    wait $!
done
