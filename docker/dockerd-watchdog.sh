#!/usr/bin/env bash
# Keep dockerd up. Package install belongs to docker/ensure-dockerd.sh.
# Started by that script (bash, flock, nohup). Not a systemd unit.
# A second start of this same file (real path or a symlink) exits.
# A copy still running from another path is stopped first.

set -u

_unit=$(dirname "$(/usr/bin/realpath "$0")")
UPKEEP=$_unit
LOG="$UPKEEP/dockerd-watchdog.log"
LOCK_DIR="$UPKEEP/dockerd-watchdog.lock"

if [[ "${1:-}" == "--print-dir" ]]; then
  printf '%s\n' "$UPKEEP"
  exit 0
fi

# shellcheck source=lib.sh
source "$_unit/lib.sh"
box_upkeep_stop_other_watchdogs "$(/usr/bin/realpath "$0")" || exit 1

MIN_BACKOFF=5
MAX_BACKOFF=60

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"
}

mkdir -p "$LOCK_DIR"
exec 9<>"$LOCK_DIR/pid"
if ! flock -n 9; then
  echo "dockerd-watchdog already running" >&2
  exit 0
fi
printf '%s\n' "$$" >"$LOCK_DIR/pid"

backoff=$MIN_BACKOFF
log "watchdog start pid=$$"

if box_upkeep_dockerd_running; then
  box_upkeep_open_docker_socket || log "ERROR: docker socket not usable"
fi

while true; do
  if box_upkeep_dockerd_running; then
    backoff=$MIN_BACKOFF
    while box_upkeep_dockerd_running; do
      sleep 5
    done
    log "dockerd exited; will restart"
  else
    log "dockerd not running; starting"
    if box_upkeep_start_dockerd; then
      log "started dockerd"
      backoff=$MIN_BACKOFF
      continue
    fi
    log "start failed; sleep ${backoff}s"
    sleep "$backoff"
    backoff=$(( backoff * 2 ))
    if (( backoff > MAX_BACKOFF )); then backoff=$MAX_BACKOFF; fi
  fi
done
