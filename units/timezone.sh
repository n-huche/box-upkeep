#!/usr/bin/env bash
# Neither Debian cron 3.0pl1 nor Debian cronie honors CRON_TZ for the schedule.
# Host localtime must be the agency timezone so AOS `0 0` is midnight there.

set -euo pipefail

ZONE="${BOX_TZ:-America/Sao_Paulo}"
ZONEFILE="/usr/share/zoneinfo/${ZONE}"

if [[ ! -e "$ZONEFILE" ]]; then
  echo "WARN: missing $ZONEFILE" >&2
  exit 0
fi

current=$(readlink -f /etc/localtime 2>/dev/null || true)
want=$(readlink -f "$ZONEFILE" 2>/dev/null || echo "$ZONEFILE")
if [[ "$current" == "$want" ]]; then
  echo "tz-ok: $ZONE"
  exit 0
fi

sudo ln -sf "$ZONEFILE" /etc/localtime
echo "$ZONE" | sudo tee /etc/timezone >/dev/null
echo "tz-set: $ZONE"
