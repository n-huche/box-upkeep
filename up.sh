#!/usr/bin/env bash
# Cold start: execute box-access/up.sh, then ./aos-up.sh.
# Gate logic is not in this repo. BOX_ACCESS_UP overrides the sibling path.
# A failing side is reported. The other still runs unless --stop-on-error,
# --access-only, or --aos-only. bootstrap.sh execs this script.

set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"
box_upkeep_parse_up_args "$@"

echo "repo=$REPO"

access_args=()
aos_args=()
if [[ "$INSTALL_ONLY" -eq 1 ]]; then
  access_args+=(--install-only)
  aos_args+=(--install-only)
fi
if [[ "$NO_WATCHDOGS" -eq 1 ]]; then
  access_args+=(--no-watchdogs)
  aos_args+=(--no-watchdogs)
fi
if [[ "$SKIP_CLONE" -eq 1 ]]; then
  aos_args+=(--skip-clone)
fi

access_rc=0
aos_rc=0

if [[ "$AOS_ONLY" -eq 0 ]]; then
  echo "access: $BOX_ACCESS_UP${access_args[*]:+ ${access_args[*]}}"
  if [[ ! -x "$BOX_ACCESS_UP" ]]; then
    echo "ERROR: box-access entry not executable: $BOX_ACCESS_UP" >&2
    access_rc=127
  else
    set +e
    "$BOX_ACCESS_UP" "${access_args[@]}"
    access_rc=$?
    set -e
  fi
  if [[ "$access_rc" -ne 0 ]]; then
    echo "ERROR: box-access failed status=$access_rc" >&2
    if [[ "$STOP_ON_ERROR" -eq 1 ]]; then
      echo "stop-on-error: not running aos-up" >&2
      exit "$access_rc"
    fi
  fi
else
  echo "access: skipped (--aos-only)"
fi

if [[ "$ACCESS_ONLY" -eq 0 ]]; then
  echo "aos: $AOS_UP${aos_args[*]:+ ${aos_args[*]}}"
  if [[ ! -x "$AOS_UP" ]]; then
    echo "ERROR: aos-up entry not executable: $AOS_UP" >&2
    aos_rc=127
  else
    set +e
    "$AOS_UP" "${aos_args[@]}"
    aos_rc=$?
    set -e
  fi
  if [[ "$aos_rc" -ne 0 ]]; then
    echo "ERROR: aos-up failed status=$aos_rc" >&2
  fi
else
  echo "aos: skipped (--access-only)"
fi

if [[ "$access_rc" -ne 0 || "$aos_rc" -ne 0 ]]; then
  echo "up: failed access=$access_rc aos=$aos_rc" >&2
  if [[ "$access_rc" -ne 0 ]]; then
    exit "$access_rc"
  fi
  exit "$aos_rc"
fi

echo "up: ok"
