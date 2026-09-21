#!/usr/bin/env bash
# Cold start: start units that a box reboot/Update does not relaunch.
# Do not touch the Grok Bot/Cursor platform. An AOS failure does not abort the gate.

set -euo pipefail

HOME_BOX="${HOME_BOX:-/home/box}"
UPKEEP="${HOME_BOX}/upkeep"
AOS_ROOT="${AOS_ROOT:-/workspace/aos}"
AOS_BIN="${AOS_ROOT}/scripts/aos"
WATCHDOG_RE="${UPKEEP}/[^/]*-watchdog\\.sh"

stop_prior_watchdogs() {
  local pids n
  pids=$(pgrep -f "$WATCHDOG_RE" || true)
  if [[ -z "$pids" ]]; then
    return 0
  fi
  echo "stopping prior upkeep watchdogs: $(echo "$pids" | tr '\n' ' ')"
  # flock on *-watchdog.lock/pid is released when these processes exit.
  kill $pids 2>/dev/null || true
  n=0
  while pids=$(pgrep -f "$WATCHDOG_RE" || true); [[ -n "$pids" ]]; do
    sleep 1
    n=$((n + 1))
    if (( n >= 5 )); then
      echo "WARN: leftover watchdogs still running; sending SIGKILL" >&2
      kill -9 $pids 2>/dev/null || true
      sleep 1
      break
    fi
  done
}

if [[ -x "$UPKEEP/timezone.sh" ]]; then
  "$UPKEEP/timezone.sh" || echo "WARN: timezone.sh failed" >&2
fi

stop_prior_watchdogs

nohup "$UPKEEP/tailscale-watchdog.sh" >/dev/null 2>&1 &
sleep 1
nohup "$UPKEEP/sshd-watchdog.sh" >/dev/null 2>&1 &
nohup "$UPKEEP/cron-watchdog.sh" >/dev/null 2>&1 &
nohup "$UPKEEP/aos-watchdog.sh" >/dev/null 2>&1 &
echo "started: tailscale + sshd + cron + aos watchdogs"
pgrep -af "$WATCHDOG_RE" || true

if [[ -x "$AOS_BIN" ]]; then
  if ! "$AOS_BIN" up --quiet; then
    echo "WARN: aos up failed; watchdogs continue" >&2
  fi
else
  echo "aos skipped: missing $AOS_BIN"
fi
