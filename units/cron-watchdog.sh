#!/usr/bin/env bash
# Keep the cron daemon up. The calendar crontab belongs to AOS (`aos up`).

set -u

UPKEEP=$(cd "$(dirname "$0")" && pwd)
LOG="$UPKEEP/cron-watchdog.log"
LOCK_DIR="$UPKEEP/cron-watchdog.lock"
BIN=/usr/sbin/cron
MIN_BACKOFF=5
MAX_BACKOFF=60

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"
}

mkdir -p "$LOCK_DIR"
exec 9>"$LOCK_DIR/pid"
if ! flock -n 9; then
  echo "cron-watchdog already running" >&2
  exit 0
fi
echo $$ >&9

backoff=$MIN_BACKOFF
log "watchdog start pid=$$"

is_running() {
  pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1
}

start_daemon() {
  if [[ ! -x "$BIN" ]]; then
    log "ERROR: missing $BIN"
    return 1
  fi
  sudo setsid "$BIN" >>"$LOG" 2>&1 &
  local pid=$!
  sleep 1
  if is_running; then
    log "started cron (spawn_pid=$pid)"
    return 0
  fi
  log "ERROR: cron failed to stay up after start"
  return 1
}

while true; do
  if is_running; then
    backoff=$MIN_BACKOFF
    while is_running; do
      sleep 5
    done
    log "cron exited; will restart"
  else
    log "cron not running; starting"
    if start_daemon; then
      backoff=$MIN_BACKOFF
      continue
    fi
    log "start failed; sleep ${backoff}s"
    sleep "$backoff"
    backoff=$(( backoff * 2 ))
    if (( backoff > MAX_BACKOFF )); then backoff=$MAX_BACKOFF; fi
  fi
done
