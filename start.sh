#!/usr/bin/env bash
# Cold start: sobe unidades que reboot/Update da box não relançam.
# Não toca na plataforma Grok Bot/Cursor. Falha do AOS não aborta o portão.

set -euo pipefail

HOME_BOX="${HOME_BOX:-/home/box}"
UPKEEP="${HOME_BOX}/upkeep"
AOS_ROOT="${AOS_ROOT:-/workspace/aos}"
AOS_BIN="${AOS_ROOT}/scripts/aos"

nohup "$UPKEEP/tailscale-watchdog.sh" >/dev/null 2>&1 &
sleep 1
nohup "$UPKEEP/sshd-watchdog.sh" >/dev/null 2>&1 &
nohup "$UPKEEP/cron-watchdog.sh" >/dev/null 2>&1 &
nohup "$UPKEEP/aos-watchdog.sh" >/dev/null 2>&1 &
echo "started: tailscale + sshd + cron + aos watchdogs"
pgrep -af '/home/box/upkeep/.*-watchdog\.sh' || true

if [[ -x "$AOS_BIN" ]]; then
  if ! "$AOS_BIN" up --quiet; then
    echo "WARN: aos up failed; watchdogs continue" >&2
  fi
else
  echo "aos skipped: missing $AOS_BIN"
fi
