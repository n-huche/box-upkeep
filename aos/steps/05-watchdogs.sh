#!/usr/bin/env bash
# Start the vendored cron and AOS keep-alive loops (bash, flock, nohup).
# Not systemd. aos/aos-up.sh skips this step on --no-watchdogs.
# Each script is the real path of aos/units/. A watchdog already running as
# that file (the real path or a symlink to it) is left in place. A watchdog
# still running from another path is stopped and replaced. aos watch is not
# a watchdog and is not signaled. Does not start the gate's loops.

_step_dir=$(dirname "$(/usr/bin/realpath "${BASH_SOURCE[0]}")")
# shellcheck source=../lib/proc.sh
source "$_step_dir/../lib/proc.sh"
unset _step_dir

box_upkeep_start_watchdog() {
  local canon=$1 label=$2
  box_upkeep_stop_other_watchdogs "$canon" || return 1
  if box_upkeep_watchdog_running "$canon"; then
    echo "watchdog: already running ($canon)"
    return 0
  fi
  echo "watchdog: starting ${label} keep-alive ($canon)"
  nohup "$canon" >/dev/null 2>&1 &
  sleep 1
}

step_watchdogs() {
  local cron aos
  cron=$(/usr/bin/realpath "$REPO/units/cron-watchdog.sh")
  aos=$(/usr/bin/realpath "$REPO/units/aos-watchdog.sh")
  if [[ ! -x "$cron" || ! -x "$aos" ]]; then
    echo "ERROR: watchdog scripts missing under $REPO/units" >&2
    return 1
  fi
  box_upkeep_start_watchdog "$cron" "cron"
  box_upkeep_start_watchdog "$aos" "aos"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(dirname "$(/usr/bin/realpath "$0")")/../lib/common.sh"
  box_upkeep_parse_aos_args "$@"
  if [[ "$NO_WATCHDOGS" -eq 1 ]]; then
    echo "watchdog: skipped (--no-watchdogs)"
    exit 0
  fi
  step_watchdogs
fi
