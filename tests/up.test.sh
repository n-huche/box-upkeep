#!/usr/bin/env bash
# Top-level up.sh order and failure policy, using mock entrypoints.
# Does not run the real gate or aos/aos-up.sh.
# java/javac stubs stay on PATH so a missing host JDK is not installed here.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ACCESS_LOG=$TMP/access.log
AOS_LOG=$TMP/aos.log
cat > "$TMP/access-up.sh" << 'EOF'
#!/usr/bin/env bash
printf 'invoked %s\n' "$*" >> "$ACCESS_LOG"
exit "${ACCESS_RC:-0}"
EOF
cat > "$TMP/aos-up.sh" << 'EOF'
#!/usr/bin/env bash
printf 'invoked %s\n' "$*" >> "$AOS_LOG"
exit "${AOS_RC:-0}"
EOF
chmod +x "$TMP/access-up.sh" "$TMP/aos-up.sh"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/java" << 'EOF'
#!/bin/bash
exit 0
EOF
cat > "$TMP/bin/javac" << 'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$TMP/bin/java" "$TMP/bin/javac"

run_up() {
  PATH="$TMP/bin:$PATH" ACCESS_RC=${ACCESS_RC:-0} AOS_RC=${AOS_RC:-0} \
    BOX_ACCESS_UP="$TMP/access-up.sh" AOS_UP="$TMP/aos-up.sh" \
    ACCESS_LOG="$ACCESS_LOG" AOS_LOG="$AOS_LOG" \
    "$ROOT/up.sh" "$@"
}

reset_logs() {
  rm -f "$ACCESS_LOG" "$AOS_LOG"
}

reset_logs
ACCESS_RC=0 AOS_RC=0
out=$(run_up)
if ! printf '%s\n' "$out" | grep -q 'up: ok'; then
  echo "FAIL success path did not print up: ok"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'jdk: present'; then
  echo "FAIL success path did not skip a present JDK"
  printf '%s\n' "$out"
  exit 1
fi
access_line=$(printf '%s\n' "$out" | grep -n '^access:' | head -n1 | cut -d: -f1)
aos_line=$(printf '%s\n' "$out" | grep -n '^aos:' | head -n1 | cut -d: -f1)
if (( access_line >= aos_line )); then
  echo "FAIL gate did not run before aos"
  exit 1
fi
if [[ "$(cat "$ACCESS_LOG")" != "invoked " || "$(cat "$AOS_LOG")" != "invoked " ]]; then
  echo "FAIL bare run forwarded unexpected flags"
  echo "access=$(cat "$ACCESS_LOG")"
  echo "aos=$(cat "$AOS_LOG")"
  exit 1
fi
echo "ok gate runs before aos"

reset_logs
ACCESS_RC=0 AOS_RC=0
run_up --install-only --no-watchdogs --skip-clone >/dev/null
if [[ "$(cat "$ACCESS_LOG")" != "invoked --install-only --no-watchdogs" ]]; then
  echo "FAIL gate flags: $(cat "$ACCESS_LOG")"
  exit 1
fi
if [[ "$(cat "$AOS_LOG")" != "invoked --install-only --no-watchdogs --skip-clone" ]]; then
  echo "FAIL aos flags: $(cat "$AOS_LOG")"
  exit 1
fi
echo "ok flags are forwarded; --skip-clone stays on the aos side"

reset_logs
ACCESS_RC=3 AOS_RC=0
set +e
out=$(run_up 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 3 ]]; then
  echo "FAIL exit status was $rc, want 3"
  printf '%s\n' "$out"
  exit 1
fi
if [[ "$(cat "$AOS_LOG")" != "invoked " ]]; then
  echo "FAIL aos side did not run after a gate failure"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: failed access=3 aos=0 jdk=0'; then
  echo "FAIL failure summary missing"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok a failing gate still runs aos and is reported"

reset_logs
ACCESS_RC=0 AOS_RC=5
set +e
out=$(run_up 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 5 ]]; then
  echo "FAIL aos failure status was $rc, want 5"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: failed access=0 aos=5 jdk=0'; then
  echo "FAIL aos failure summary missing"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok a failing aos side is reported"

reset_logs
ACCESS_RC=3 AOS_RC=5
set +e
out=$(run_up 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 3 ]]; then
  echo "FAIL first failure status was $rc, want 3"
  printf '%s\n' "$out"
  exit 1
fi
if [[ "$(cat "$AOS_LOG")" != "invoked " ]]; then
  echo "FAIL both-failure path skipped aos"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: failed access=3 aos=5 jdk=0'; then
  echo "FAIL both-failure summary missing"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok when both sides fail, aos still runs and the gate status wins"

reset_logs
ACCESS_RC=4 AOS_RC=0
set +e
out=$(run_up --stop-on-error 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 4 ]]; then
  echo "FAIL stop-on-error status was $rc"
  printf '%s\n' "$out"
  exit 1
fi
if [[ -e "$AOS_LOG" ]]; then
  echo "FAIL stop-on-error still ran aos"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'stop-on-error: not running aos-up'; then
  echo "FAIL stop-on-error was not reported"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok --stop-on-error skips aos after a gate failure"

reset_logs
ACCESS_RC=0 AOS_RC=0
run_up --access-only >/dev/null
if [[ ! -f "$ACCESS_LOG" || -e "$AOS_LOG" ]]; then
  echo "FAIL --access-only did not run only the gate"
  exit 1
fi
echo "ok --access-only"

reset_logs
ACCESS_RC=0 AOS_RC=0
run_up --aos-only >/dev/null
if [[ -e "$ACCESS_LOG" || ! -f "$AOS_LOG" ]]; then
  echo "FAIL --aos-only did not run only aos"
  exit 1
fi
echo "ok --aos-only"

set +e
run_up --access-only --aos-only >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL combined --access-only --aos-only was accepted"
  exit 1
fi
echo "ok --access-only and --aos-only are exclusive"

reset_logs
ACCESS_RC=0 AOS_RC=0
set +e
out=$(PATH="$TMP/bin:$PATH" BOX_ACCESS_UP="$TMP/missing-up.sh" AOS_UP="$TMP/aos-up.sh" \
  ACCESS_LOG="$ACCESS_LOG" AOS_LOG="$AOS_LOG" \
  "$ROOT/up.sh" 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 127 ]]; then
  echo "FAIL missing gate status was $rc"
  printf '%s\n' "$out"
  exit 1
fi
if [[ "$(cat "$AOS_LOG")" != "invoked " ]]; then
  echo "FAIL missing gate skipped aos"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: failed access=127 aos=0 jdk=0'; then
  echo "FAIL missing gate was not reported"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok a missing gate is reported and aos still runs"

reset_logs
PATH="$TMP/bin:$PATH" BOX_ACCESS_UP="$TMP/access-up.sh" AOS_UP="$TMP/aos-up.sh" \
  ACCESS_LOG="$ACCESS_LOG" AOS_LOG="$AOS_LOG" \
  "$ROOT/up.sh" --help >/dev/null
if [[ -e "$ACCESS_LOG" || -e "$AOS_LOG" ]]; then
  echo "FAIL --help invoked a side"
  exit 1
fi
help=$(PATH="$TMP/bin:$PATH" BOX_ACCESS_UP="$TMP/access-up.sh" AOS_UP="$TMP/aos-up.sh" \
  ACCESS_LOG="$ACCESS_LOG" AOS_LOG="$AOS_LOG" \
  "$ROOT/up.sh" --help)
if ! printf '%s\n' "$help" | grep -q -- '--stop-on-error'; then
  echo "FAIL up.sh --help missing policy flag"
  exit 1
fi
echo "ok up.sh --help"
