#!/usr/bin/env bash
# The gate lives only in box-access. This tree must not vendor it.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

units=$(find "$ROOT/units" -type f -printf '%f\n' | sort)
expected=$(printf '%s\n' aos-watchdog.sh cron-watchdog.sh)
if [[ "$units" != "$expected" ]]; then
  echo "FAIL units/ is not cron + aos only"
  printf '%s\n' "$units"
  exit 1
fi
echo "ok units are cron and aos only"

if grep -E -i -q 'tailscale|openssh|sshd' "$ROOT/packages.txt"; then
  echo "FAIL packages.txt contains a gate package"
  exit 1
fi
echo "ok packages.txt has no gate packages"

hits=$(grep -R -n -F \
  -e ListenAddress \
  -e tailscaled \
  -e openssh \
  -e TS_API_KEY \
  -e TS_AUTHKEY \
  -e google-chrome \
  -e pkgs.tailscale.com \
  -e authorized_keys \
  -e sshd \
  -e tailscale \
  --exclude-dir=tests \
  --exclude-dir=.git \
  "$ROOT" || true)
if [[ -n "$hits" ]]; then
  echo "FAIL gate material is still in this repo"
  printf '%s\n' "$hits"
  exit 1
fi
echo "ok no gate packages, secrets, apt, or listen logic"
