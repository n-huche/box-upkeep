#!/usr/bin/env bash
# Install the AOS calendar crontab and run catch-up via `aos up`.
# --watch-only is the keep-alive loop, not this step.

step_calendar() {
  local bin log rc git_root
  # aos up writes AOS_ROOT into the calendar crontab. Resolve it first so
  # the installed crontab stores the canonical checkout, not a symlink.
  if [[ -n "${AOS_ROOT:-}" && -e "$AOS_ROOT" ]]; then
    AOS_ROOT=$(/usr/bin/realpath "$AOS_ROOT")
    export AOS_ROOT
  fi
  bin="$AOS_ROOT/scripts/aos"
  if [[ ! -x "$bin" ]]; then
    echo "ERROR: missing $bin (clone AOS or set AOS_ROOT)" >&2
    return 1
  fi
  echo "calendar: $bin up"
  log=$(mktemp)
  # `&& ||` keeps set -e from aborting the step before the status is recorded.
  "$bin" up >"$log" 2>&1 && rc=0 || rc=$?
  cat "$log"
  if [[ "$rc" -ne 0 ]]; then
    rm -f "$log"
    echo "ERROR: aos up failed status=$rc" >&2
    return "$rc"
  fi
  if grep -q 'crontab-error:' "$log"; then
    rm -f "$log"
    echo "ERROR: aos up did not install the calendar crontab" >&2
    return 1
  fi
  if grep -q 'crontab-unavailable' "$log"; then
    rm -f "$log"
    echo "ERROR: crontab is unavailable (cronie provides it)" >&2
    return 1
  fi
  rm -f "$log"
  # This function lives in aos/steps/. The checkout root is two levels up.
  git_root=$(dirname "$(/usr/bin/realpath "${BASH_SOURCE[0]}")")
  git_root=$(/usr/bin/realpath "$git_root/../..")
  box_upkeep_refresh_crontab_paths "$git_root" "${AOS_ROOT:-}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(dirname "$(/usr/bin/realpath "$0")")/../lib/common.sh"
  box_upkeep_parse_aos_args "$@"
  step_calendar
fi
