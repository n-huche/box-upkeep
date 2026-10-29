#!/usr/bin/env bash
# Cold start: run/ensure-run.sh first (/var/run -> /run symlink),
# then execute box-access/up.sh, then aos/aos-up.sh. RUN_ENSURE overrides the
# first entry; a failure there is reported, counts last in the exit status,
# and does not stop the other sides.
# AOS_UP overrides that entry.
# When java or javac does not run, java/install-jdk.sh runs after both.
# When mvn -v does not run, java/install-maven.sh runs after the JDK.
# When gh --version does not run, gh/install-gh.sh runs after Maven.
# A github.com login in /home/box/.config/gh is checked on every run.
# A missing login warns and does not fail this script.
# docker/ensure-dockerd.sh runs after GitHub CLI: install docker.io and
# docker-cli when dockerd or docker is missing, start dockerd if it is down,
# and start docker/dockerd-watchdog.sh unless --no-watchdogs.
# python/ensure-venvs.sh runs after dockerd: recreate declared Python venvs
# when unhealthy (PYTHON_VENVS_LIST). Healthy venvs are left alone.
# Last, "$TICKETS_CLI service ensure" starts the ticket monitor supervisor
# when it is not running (the CLI checks its pid and flock, so a running
# monitor is left alone). A missing CLI or a failure only warns.
# Gate logic is not in this repo. BOX_ACCESS_UP overrides the sibling path.
# A failing side is reported. The other still runs unless --stop-on-error,
# --access-only, or --aos-only. JDK, Maven, GitHub CLI, Docker, and Python
# venv failures are reported the same way: the exit status is the first
# non-zero of access, aos, jdk, maven, gh, docker, then python.
# --stop-on-error returns before the JDK, Maven, GitHub CLI, Docker, and
# Python venvs steps when the gate fails.
# bootstrap.sh execs this script.

set -euo pipefail

REPO=$(dirname "$(/usr/bin/realpath "$0")")
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
maven_rc=0
gh_rc=0
docker_rc=0
python_rc=0
tickets_rc=0
run_rc=0

# Runtime directories before the gate: its daemons and clients use /run.
# Runs under every flag. A fresh image can ship /var/run as a real directory.
echo "run: $RUN_ENSURE"
if [[ ! -x "$RUN_ENSURE" ]]; then
  echo "ERROR: run entry not executable: $RUN_ENSURE" >&2
  run_rc=127
else
  set +e
  "$RUN_ENSURE"
  run_rc=$?
  set -e
fi
if [[ "$run_rc" -ne 0 ]]; then
  echo "ERROR: run ensure failed status=$run_rc" >&2
fi

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

# JDK step. Runs after the gate and AOS, including --install-only,
# --access-only, and --aos-only. A gate failure with --stop-on-error
# returns above, so this step is not reached.
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

# Maven follows the JDK. Same flags, including --install-only,
# --access-only, and --aos-only. A gate failure with --stop-on-error
# returns above, so this step is not reached.
if box_upkeep_maven_present; then
  echo "maven: present"
else
  echo "maven: $MAVEN_INSTALL"
  if [[ ! -x "$MAVEN_INSTALL" ]]; then
    echo "ERROR: maven install entry not executable: $MAVEN_INSTALL" >&2
    maven_rc=127
  else
    set +e
    "$MAVEN_INSTALL"
    maven_rc=$?
    set -e
  fi
  if [[ "$maven_rc" -ne 0 ]]; then
    echo "ERROR: maven install failed status=$maven_rc" >&2
  fi
fi

# GitHub CLI follows Maven. Same flags, including --install-only,
# --access-only, and --aos-only. A gate failure with --stop-on-error
# returns above, so this step is not reached. A missing login warns
# inside box_upkeep_gh_auth and does not change gh_rc.
if box_upkeep_gh_present; then
  echo "gh: present"
else
  echo "gh: $GH_INSTALL"
  if [[ ! -x "$GH_INSTALL" ]]; then
    echo "ERROR: gh install entry not executable: $GH_INSTALL" >&2
    gh_rc=127
  else
    set +e
    "$GH_INSTALL"
    gh_rc=$?
    set -e
  fi
  if [[ "$gh_rc" -ne 0 ]]; then
    echo "ERROR: gh install failed status=$gh_rc" >&2
  fi
fi
if [[ "$gh_rc" -eq 0 ]] && box_upkeep_gh_present; then
  box_upkeep_gh_auth
fi

# Docker follows GitHub CLI. Same flags, including --install-only,
# --access-only, and --aos-only. A gate failure with --stop-on-error
# returns above, so this step is not reached. --no-watchdogs still starts
# dockerd once; the keep-alive loop is skipped inside the script.
echo "dockerd: $DOCKERD_ENSURE"
if [[ ! -x "$DOCKERD_ENSURE" ]]; then
  echo "ERROR: dockerd entry not executable: $DOCKERD_ENSURE" >&2
  docker_rc=127
else
  set +e
  NO_WATCHDOGS="$NO_WATCHDOGS" "$DOCKERD_ENSURE"
  docker_rc=$?
  set -e
fi
if [[ "$docker_rc" -ne 0 ]]; then
  echo "ERROR: dockerd ensure failed status=$docker_rc" >&2
fi

# Python venvs follow dockerd. Same flags, including --install-only,
# --access-only, and --aos-only. A gate failure with --stop-on-error
# returns above, so this step is not reached. Sibling files next to a
# venv (secrets, tokens, scripts) are never touched.
echo "python-venvs: $PYTHON_VENVS_ENSURE"
if [[ ! -x "$PYTHON_VENVS_ENSURE" ]]; then
  echo "ERROR: python venvs entry not executable: $PYTHON_VENVS_ENSURE" >&2
  python_rc=127
else
  set +e
  "$PYTHON_VENVS_ENSURE"
  python_rc=$?
  set -e
fi
if [[ "$python_rc" -ne 0 ]]; then
  echo "ERROR: python venvs ensure failed status=$python_rc" >&2
fi

# Ticket monitor. Not host infra, so it never changes the exit status.
echo "tickets: $TICKETS_CLI service ensure"
if [[ ! -x "$TICKETS_CLI" ]]; then
  echo "WARN: tickets CLI not executable, skipped: $TICKETS_CLI" >&2
else
  set +e
  "$TICKETS_CLI" service ensure
  tickets_rc=$?
  set -e
  if [[ "$tickets_rc" -ne 0 ]]; then
    echo "WARN: tickets service ensure failed status=$tickets_rc" >&2
  fi
fi

if [[ "$access_rc" -ne 0 || "$aos_rc" -ne 0 || "$jdk_rc" -ne 0 || "$maven_rc" -ne 0 || "$gh_rc" -ne 0 || "$docker_rc" -ne 0 || "$python_rc" -ne 0 || "$run_rc" -ne 0 ]]; then
  echo "up: failed access=$access_rc aos=$aos_rc jdk=$jdk_rc maven=$maven_rc gh=$gh_rc docker=$docker_rc python=$python_rc run=$run_rc" >&2
  if [[ "$access_rc" -ne 0 ]]; then
    exit "$access_rc"
  fi
  if [[ "$aos_rc" -ne 0 ]]; then
    exit "$aos_rc"
  fi
  if [[ "$jdk_rc" -ne 0 ]]; then
    exit "$jdk_rc"
  fi
  if [[ "$maven_rc" -ne 0 ]]; then
    exit "$maven_rc"
  fi
  if [[ "$gh_rc" -ne 0 ]]; then
    exit "$gh_rc"
  fi
  if [[ "$docker_rc" -ne 0 ]]; then
    exit "$docker_rc"
  fi
  if [[ "$python_rc" -ne 0 ]]; then
    exit "$python_rc"
  fi
  exit "$run_rc"
fi

echo "up: ok"
