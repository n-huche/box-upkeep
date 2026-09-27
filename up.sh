#!/usr/bin/env bash
# Cold start: execute box-access/up.sh, then aos/aos-up.sh.
# AOS_UP overrides that entry.
# When java or javac does not run, java/install-jdk.sh runs after both.
# Gate logic is not in this repo. BOX_ACCESS_UP overrides the sibling path.
# A failing side is reported. The other still runs unless --stop-on-error,
# --access-only, or --aos-only. JDK failure is reported the same way:
# the exit status is the first non-zero of access, aos, then jdk.
# --stop-on-error returns before the JDK step when the gate fails.
# bootstrap.sh execs this script.

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
jdk_rc=0

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

# This repo's package step. Runs after the gate and AOS, including
# --install-only, --access-only, and --aos-only. A gate failure with
# --stop-on-error returns above, so this step is not reached.
if box_upkeep_jdk_present; then
  echo "jdk: present"
else
  echo "jdk: $JDK_INSTALL"
  if [[ ! -x "$JDK_INSTALL" ]]; then
    echo "ERROR: jdk install entry not executable: $JDK_INSTALL" >&2
    jdk_rc=127
  else
    set +e
    "$JDK_INSTALL"
    jdk_rc=$?
    set -e
  fi
  if [[ "$jdk_rc" -ne 0 ]]; then
    echo "ERROR: jdk install failed status=$jdk_rc" >&2
  fi
fi

if [[ "$access_rc" -ne 0 || "$aos_rc" -ne 0 || "$jdk_rc" -ne 0 ]]; then
  echo "up: failed access=$access_rc aos=$aos_rc jdk=$jdk_rc" >&2
  if [[ "$access_rc" -ne 0 ]]; then
    exit "$access_rc"
  fi
  if [[ "$aos_rc" -ne 0 ]]; then
    exit "$aos_rc"
  fi
  exit "$jdk_rc"
fi

echo "up: ok"
