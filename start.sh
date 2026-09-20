#!/usr/bin/env bash
# Cold start: cron + AOS. Tailscale and sshd are box-access
# (`/home/box/access/start.sh` if the gate already installed it).
# Do not touch the Grok Bot/Cursor platform. An AOS failure does not abort the host.

set -euo pipefail

HOME_BOX="${HOME_BOX:-/home/box}"
UPKEEP="${HOME_BOX}/upkeep"
ACCESS_START="${HOME_BOX}/access/start.sh"
AOS_ROOT="${AOS_ROOT:-/workspace/aos}"
AOS_BIN="${AOS_ROOT}/scripts/aos"

if [[ -x "$ACCESS_START" ]]; then
  "$ACCESS_START"
else
  echo "WARN: missing $ACCESS_START (run box-access/bootstrap.sh for SSH)" >&2
fi

nohup "$UPKEEP/cron-watchdog.sh" >/dev/null 2>&1 &
nohup "$UPKEEP/aos-watchdog.sh" >/dev/null 2>&1 &
echo "started: cron + aos watchdogs"
pgrep -af '/home/box/upkeep/.*-watchdog\.sh' || true

if [[ -x "$AOS_BIN" ]]; then
  if ! "$AOS_BIN" up --quiet; then
    echo "WARN: aos up failed; watchdogs continue" >&2
  fi
else
  echo "aos skipped: missing $AOS_BIN"
fi
