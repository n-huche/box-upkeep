#!/usr/bin/env bash
# Host localtime for AOS midnight. Debian cron and cronie ignore CRON_TZ.

step_timezone() {
  local zone="${BOX_TZ:-America/Sao_Paulo}"
  local zonefile="/usr/share/zoneinfo/${zone}"

  if [[ ! -e "$zonefile" ]]; then
    echo "WARN: missing $zonefile" >&2
    return 0
  fi

  local current want
  current=$(readlink -f /etc/localtime 2>/dev/null || true)
  want=$(readlink -f "$zonefile" 2>/dev/null || echo "$zonefile")
  if [[ "$current" == "$want" ]]; then
    echo "tz-ok: $zone"
    return 0
  fi

  sudo ln -sf "$zonefile" /etc/localtime
  echo "$zone" | sudo tee /etc/timezone >/dev/null
  echo "tz-set: $zone"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  box_upkeep_parse_aos_args "$@"
  step_timezone
fi
