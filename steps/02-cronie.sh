#!/usr/bin/env bash
# Install cronie and start crond once if it is down.
# The calendar crontab belongs to AOS (steps/04-calendar.sh). The keep-alive
# loop is steps/05-watchdogs.sh.

ensure_pkg() {
  local pkg=$1
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "pkg-ok: $pkg"
    return 0
  fi
  echo "pkg-install: $pkg"
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
}

cron_is_running() {
  pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1
}

step_cronie() {
  local pkg bin
  while read -r pkg; do
    [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
    ensure_pkg "$pkg"
  done < "$REPO/packages.txt"

  if cron_is_running; then
    echo "cron: already running"
    return 0
  fi

  bin=/usr/sbin/crond
  if [[ ! -x "$bin" ]]; then
    bin=/usr/sbin/cron
  fi
  if [[ ! -x "$bin" ]]; then
    echo "ERROR: cronie installed but no crond or cron binary" >&2
    return 1
  fi
  echo "cron: starting $bin"
  sudo setsid "$bin" >/dev/null 2>&1 &
  sleep 1
  if cron_is_running; then
    echo "cron: started"
    return 0
  fi
  echo "ERROR: cron failed to stay up after start" >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  box_upkeep_parse_aos_args "$@"
  step_cronie
fi
