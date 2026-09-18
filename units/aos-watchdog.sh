#!/usr/bin/env bash
# Keep AOS watch up if the repo exists. Does not catch-up (that is `aos up` on start).

set -u

UPKEEP=$(cd "$(dirname "$0")" && pwd)
LOG="$UPKEEP/aos-watchdog.log"
LOCK_DIR="$UPKEEP/aos-watchdog.lock"
AOS_ROOT="${AOS_ROOT:-/workspace/aos}"
BIN="$AOS_ROOT/scripts/aos"
MIN_BACKOFF=5
MAX_BACKOFF=60

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"
}

mkdir -p "$LOCK_DIR"
exec 9>"$LOCK_DIR/pid"
if ! flock -n 9; then
  echo "aos-watchdog already running" >&2
  exit 0
fi
echo $$ >&9

backoff=$MIN_BACKOFF
log "watchdog start pid=$$ aos_root=$AOS_ROOT"

ensure_watch() {
  if [[ ! -x "$BIN" ]]; then
    log "aos missing at $BIN"
    return 1
  fi
  if "$BIN" up --watch-only --quiet; then
    return 0
  fi
  log "ERROR: aos up --watch-only failed status=$?"
  return 1
}

while true; do
  if [[ ! -x "$BIN" ]]; then
    log "waiting for aos at $BIN"
    sleep 30
    continue
  fi
  if ensure_watch; then
    backoff=$MIN_BACKOFF
    sleep 5
    continue
  fi
  log "ensure failed; sleep ${backoff}s"
  sleep "$backoff"
  backoff=$(( backoff * 2 ))
  if (( backoff > MAX_BACKOFF )); then backoff=$MAX_BACKOFF; fi
done
