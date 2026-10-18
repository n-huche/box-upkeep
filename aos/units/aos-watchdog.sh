#!/usr/bin/env bash
# Keep `aos up --watch-only` running. Calendar catch-up is steps/04-calendar.sh.
# Started by steps/05-watchdogs.sh (bash, flock, nohup). Not a systemd unit.
# A second start of this same file (real path or a symlink) exits.
# A copy still running from another path is stopped first.
# An aos watch that is already up is not started again.

set -u

_unit=$(dirname "$(/usr/bin/realpath "$0")")
UPKEEP=$_unit
LOG="$UPKEEP/aos-watchdog.log"
LOCK_DIR="$UPKEEP/aos-watchdog.lock"

if [[ "${1:-}" == "--print-dir" ]]; then
  printf '%s\n' "$UPKEEP"
  exit 0
fi

# shellcheck source=../lib/proc.sh
source "$_unit/../lib/proc.sh"
box_upkeep_stop_other_watchdogs "$(/usr/bin/realpath "$0")" || exit 1

AOS_ROOT="${AOS_ROOT:-/workspace/aos}"
if [[ -e "$AOS_ROOT" ]]; then
  AOS_ROOT=$(/usr/bin/realpath "$AOS_ROOT")
fi
BIN="$AOS_ROOT/scripts/aos"
MIN_BACKOFF=5
MAX_BACKOFF=60

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"
}

mkdir -p "$LOCK_DIR"
exec 9<>"$LOCK_DIR/pid"
if ! flock -n 9; then
  echo "aos-watchdog already running" >&2
  exit 0
fi
printf '%s\n' "$$" >"$LOCK_DIR/pid"

backoff=$MIN_BACKOFF
log "watchdog start pid=$$ aos_root=$AOS_ROOT"

while true; do
  if [[ ! -x "$BIN" ]]; then
    log "waiting for aos at $BIN"
    sleep 30
    continue
  fi
  if box_upkeep_aos_watch_pid "$AOS_ROOT" >/dev/null; then
    backoff=$MIN_BACKOFF
    sleep 5
    continue
  fi
  rc=0
  "$BIN" up --watch-only --quiet && rc=0 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    backoff=$MIN_BACKOFF
    sleep 5
    continue
  fi
  log "ERROR: aos up --watch-only failed status=$rc"
  log "ensure failed; sleep ${backoff}s"
  sleep "$backoff"
  backoff=$(( backoff * 2 ))
  if (( backoff > MAX_BACKOFF )); then backoff=$MAX_BACKOFF; fi
done
