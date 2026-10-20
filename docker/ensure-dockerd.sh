#!/usr/bin/env bash
# Install Docker when dockerd or docker is missing, start dockerd if it is
# down, and start docker/dockerd-watchdog.sh. Skip the watchdog with
# --no-watchdogs (NO_WATCHDOGS=1), the same way cron still starts once.
# ./up.sh runs this after GitHub CLI. A non-zero exit is reported there
# and counts toward the first non-zero status.
# Not a systemd unit. There is no systemd on this host.

set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(dirname "$(/usr/bin/realpath "$0")")/../lib/common.sh"
# shellcheck source=lib.sh
source "$(dirname "$(/usr/bin/realpath "$0")")/lib.sh"

pkg=$DOCKER_PACKAGE

box_upkeep_install_docker() {
  echo "dockerd-install: $pkg docker-cli"
  if ! sudo apt-get update -y; then
    echo "ERROR: apt-get update failed while installing $pkg" >&2
    return 1
  fi
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" docker-cli; then
    echo "ERROR: apt-get install failed for $pkg and docker-cli" >&2
    return 1
  fi
  if ! box_upkeep_docker_bins_present; then
    echo "ERROR: $pkg and docker-cli installed but dockerd or docker still does not run" >&2
    return 1
  fi
  echo "dockerd: installed $pkg docker-cli"
}

if ! box_upkeep_docker_bins_present; then
  box_upkeep_install_docker
fi

if box_upkeep_dockerd_running; then
  echo "dockerd: present"
else
  box_upkeep_start_dockerd
fi
box_upkeep_open_docker_socket

if [[ "${NO_WATCHDOGS:-0}" -eq 0 ]]; then
  box_upkeep_start_dockerd_watchdog
else
  echo "watchdog: skipped (--no-watchdogs)"
fi
