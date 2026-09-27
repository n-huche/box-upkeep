#!/usr/bin/env bash
# Canonical AOS orchestrator. Repo-root ./aos-up.sh execs this script.
# Sources lib/common.sh, then steps/*.sh in order.
# Flags: --install-only (stop after cronie), --skip-clone, --no-watchdogs.
# AOS only. Does not implement the gate. Does not use systemd.

set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
box_upkeep_parse_aos_args "$@"

echo "repo=$REPO"
echo "aos_root=$AOS_ROOT"

run_step() {
  local file=$1
  local func=$2
  echo "step: $(basename "$file")"
  # shellcheck source=/dev/null
  source "$file"
  "$func"
}

run_step "$REPO/steps/01-timezone.sh" step_timezone
run_step "$REPO/steps/02-cronie.sh" step_cronie
if [[ "$INSTALL_ONLY" -eq 1 ]]; then
  echo "install-only"
  exit 0
fi

run_step "$REPO/steps/03-clone-aos.sh" step_clone_aos
run_step "$REPO/steps/04-calendar.sh" step_calendar

if [[ "$NO_WATCHDOGS" -eq 1 ]]; then
  echo "watchdog: skipped (--no-watchdogs)"
else
  run_step "$REPO/steps/05-watchdogs.sh" step_watchdogs
fi

echo "aos-up: ok"
