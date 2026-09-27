#!/usr/bin/env bash
# aos-up.sh wiring and flag parsing. Does not change the host timezone,
# install packages, clone AOS, or start watchdogs.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../aos/lib/common.sh
source "$ROOT/aos/lib/common.sh"

order=$(grep -oE 'steps/[0-9]{2}-[a-z0-9-]+\.sh' "$ROOT/aos/aos-up.sh")
expected=$(printf '%s\n' \
  steps/01-timezone.sh \
  steps/02-cronie.sh \
  steps/03-clone-aos.sh \
  steps/04-calendar.sh \
  steps/05-watchdogs.sh)
if [[ "$order" != "$expected" ]]; then
  echo "FAIL step order"
  printf '%s\n' "$order"
  exit 1
fi
echo "ok aos-up.sh runs steps in order"

line() { grep -n "$1" "$ROOT/aos/aos-up.sh" | head -n1 | cut -d: -f1; }
p01=$(line 'steps/01-timezone.sh')
p02=$(line 'steps/02-cronie.sh')
inst=$(line 'INSTALL_ONLY')
p03=$(line 'steps/03-clone-aos.sh')
p04=$(line 'steps/04-calendar.sh')
nw=$(line 'NO_WATCHDOGS')
p05=$(line 'steps/05-watchdogs.sh')
if (( p01 >= p02 || p02 >= inst || inst >= p03 || p03 >= p04 || p04 >= nw || nw >= p05 )); then
  echo "FAIL install-only must stop before clone, and --no-watchdogs before step 05"
  exit 1
fi
echo "ok --install-only stops after cronie; --no-watchdogs skips step 05"

box_upkeep_parse_aos_args --no-watchdogs --install-only --skip-clone
if [[ "$INSTALL_ONLY" -ne 1 || "$NO_WATCHDOGS" -ne 1 || "$SKIP_CLONE" -ne 1 ]]; then
  echo "FAIL aos flags were not all set"
  exit 1
fi
box_upkeep_parse_aos_args
if [[ "$INSTALL_ONLY" -ne 0 || "$NO_WATCHDOGS" -ne 0 || "$SKIP_CLONE" -ne 0 ]]; then
  echo "FAIL aos flags were not cleared"
  exit 1
fi
set +e
( box_upkeep_parse_aos_args --not-a-flag >/dev/null 2>&1 )
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL unknown aos flag was accepted"
  exit 1
fi
help=$(box_upkeep_parse_aos_args --help)
if ! printf '%s\n' "$help" | grep -q -- '--skip-clone'; then
  echo "FAIL aos --help missing --skip-clone"
  exit 1
fi
echo "ok aos flag parser"

# Sourcing steps must not start daemons or clone.
# shellcheck source=../aos/steps/01-timezone.sh
source "$ROOT/aos/steps/01-timezone.sh"
# shellcheck source=../aos/steps/02-cronie.sh
source "$ROOT/aos/steps/02-cronie.sh"
# shellcheck source=../aos/steps/03-clone-aos.sh
source "$ROOT/aos/steps/03-clone-aos.sh"
# shellcheck source=../aos/steps/04-calendar.sh
source "$ROOT/aos/steps/04-calendar.sh"
# shellcheck source=../aos/steps/05-watchdogs.sh
source "$ROOT/aos/steps/05-watchdogs.sh"
for func in step_timezone step_cronie step_clone_aos step_calendar step_watchdogs; do
  if ! declare -F "$func" >/dev/null; then
    echo "FAIL missing function $func"
    exit 1
  fi
done
echo "ok sourcing steps defines functions and does not run them"

if grep -R -n -E 'systemctl|\.service' \
  "$ROOT/aos-up.sh" "$ROOT/aos" "$ROOT/up.sh" "$ROOT/bootstrap.sh" \
  "$ROOT/lib" "$ROOT/java" >/dev/null; then
  echo "FAIL systemd unit reference in scripts"
  exit 1
fi
if [[ -e "$ROOT/aos/units/tailscale-watchdog.sh" || -e "$ROOT/aos/units/sshd-watchdog.sh" ]]; then
  echo "FAIL tailscale or sshd watchdog still vendored here"
  exit 1
fi
if ! grep -q 'exec ' "$ROOT/aos-up.sh" || ! grep -q 'aos/aos-up.sh' "$ROOT/aos-up.sh"; then
  echo "FAIL root aos-up.sh does not exec aos/aos-up.sh"
  exit 1
fi
help=$("$ROOT/aos-up.sh" --help)
if ! printf '%s\n' "$help" | grep -q -- '--skip-clone'; then
  echo "FAIL ./aos-up.sh --help did not reach the AOS entry"
  exit 1
fi
default_aos=$(
  env -u AOS_UP bash -c 'source "'"$ROOT"'/lib/common.sh"; printf "%s\n" "$AOS_UP"'
)
if [[ "$default_aos" != "$ROOT/aos/aos-up.sh" ]]; then
  echo "FAIL default AOS_UP is $default_aos"
  exit 1
fi
echo "ok no systemd units and no tailscale/sshd watchdogs"
