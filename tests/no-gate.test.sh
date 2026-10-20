#!/usr/bin/env bash
# The gate lives only in box-access. This tree must not vendor it.
set -euo pipefail

ROOT=$(realpath "$(dirname "$0")/..")

if [[ -d "$ROOT/units" || -d "$ROOT/steps" || -d "$ROOT/config" || -f "$ROOT/packages.txt" || -f "$ROOT/aos-up.sh" ]]; then
  echo "FAIL AOS cold-start files are still at the repo root"
  exit 1
fi

units=$(find "$ROOT/aos/units" -type f -printf '%f\n' | sort)
expected=$(printf '%s\n' aos-watchdog.sh cron-watchdog.sh)
if [[ "$units" != "$expected" ]]; then
  echo "FAIL aos/units/ is not cron + aos only"
  printf '%s\n' "$units"
  exit 1
fi
echo "ok aos/units are cron and aos only"

if grep -E -i -q 'tailscale|openssh|sshd' "$ROOT/aos/packages.txt"; then
  echo "FAIL aos/packages.txt contains a gate package"
  exit 1
fi
echo "ok aos/packages.txt has no gate packages"

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

old=$(grep -R -n -e '/workspace/box-upkeep' -e '/workspace/box-access' \
  --exclude-dir=.git --exclude-dir=tests "$ROOT" || true)
if [[ -n "$old" ]]; then
  echo "FAIL old checkout path is still hardcoded"
  printf '%s\n' "$old"
  exit 1
fi
example=$(grep -R -n '/workspace/box-infra' \
  --exclude-dir=.git --exclude-dir=tests --exclude=README.md "$ROOT" || true)
if [[ -n "$example" ]]; then
  echo "FAIL /workspace/box-infra example belongs only in the docs"
  printf '%s\n' "$example"
  exit 1
fi
for rel in up.sh lib/common.sh aos/units/aos-watchdog.sh aos/units/cron-watchdog.sh \
  aos/steps/04-calendar.sh aos/steps/05-watchdogs.sh aos/lib/proc.sh \
  docker/ensure-dockerd.sh docker/dockerd-watchdog.sh docker/lib.sh; do
  if ! grep -q 'realpath' "$ROOT/$rel"; then
    echo "FAIL $rel does not derive a path with realpath"
    exit 1
  fi
done
echo "ok checkout paths come from the script, not a fixed box path"
