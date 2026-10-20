#!/usr/bin/env bash
# Checkout paths come from the script. A symlink does not stack a watchdog.
# A watchdog from another directory is replaced. aos watch is left running.
set -euo pipefail

ROOT=$(realpath "$(dirname "$0")/..")
TMP=$(mktemp -d)
pids=()
# shellcheck source=../aos/lib/proc.sh
source "$ROOT/aos/lib/proc.sh"

cleanup() {
  local pid wpid wpath
  for pid in "${pids[@]+"${pids[@]}"}"; do
    kill "$pid" 2>/dev/null || true
  done
  while read -r wpid wpath; do
    [[ -n "${wpid:-}" ]] || continue
    if [[ "$wpath" == "$ROOT"* || "$wpath" == "$TMP"* ]]; then
      kill "$wpid" 2>/dev/null || true
    fi
  done < <(box_upkeep_list_watchdogs aos-watchdog.sh || true)
  while read -r wpid wpath; do
    [[ -n "${wpid:-}" ]] || continue
    if [[ "$wpath" == "$ROOT"* || "$wpath" == "$TMP"* ]]; then
      kill "$wpid" 2>/dev/null || true
    fi
  done < <(box_upkeep_list_watchdogs cron-watchdog.sh || true)
  rm -rf "$TMP"
  rm -rf "$ROOT/aos/units/aos-watchdog.lock" "$ROOT/aos/units/cron-watchdog.lock"
  rm -f "$ROOT/aos/units/aos-watchdog.log" "$ROOT/aos/units/cron-watchdog.log"
}
trap cleanup EXIT

fail() {
  echo "FAIL $*" >&2
  exit 1
}

count_canon() {
  local name=$1 canon=$2 n=0 pid path
  while read -r pid path; do
    [[ "${path:-}" == "$canon" ]] && n=$((n + 1))
  done < <(box_upkeep_list_watchdogs "$name")
  printf '%s\n' "$n"
}

wait_until() {
  local n=0
  until "$@"; do
    n=$((n + 1))
    if (( n > 50 )); then
      return 1
    fi
    sleep 0.1
  done
}

dead() {
  ! kill -0 "$1" 2>/dev/null
}

# --- derived paths ---

repo=$(env -u BOX_ACCESS_UP bash -c 'source "$1"; printf %s "$REPO"' _ "$ROOT/lib/common.sh")
[[ "$repo" == "$ROOT" ]] || fail "REPO is $repo, want $ROOT"
access=$(env -u BOX_ACCESS_UP bash -c 'source "$1"; printf %s "$BOX_ACCESS_UP"' _ "$ROOT/lib/common.sh")
[[ "$access" == "$(dirname "$ROOT")/box-access/up.sh" ]] || fail "gate entry is $access"
over=$(BOX_ACCESS_UP=/tmp/override/up.sh bash -c 'source "$1"; printf %s "$BOX_ACCESS_UP"' _ "$ROOT/lib/common.sh")
[[ "$over" == /tmp/override/up.sh ]] || fail "BOX_ACCESS_UP override was $over"

mkdir -p "$TMP/via"
ln -s "$ROOT" "$TMP/via/box-upkeep"
via_repo=$(env -u BOX_ACCESS_UP bash -c 'source "$1"; printf %s "$REPO"' _ "$TMP/via/box-upkeep/lib/common.sh")
[[ "$via_repo" == "$ROOT" ]] || fail "symlinked lib REPO is $via_repo"
via_access=$(env -u BOX_ACCESS_UP bash -c 'source "$1"; printf %s "$BOX_ACCESS_UP"' _ "$TMP/via/box-upkeep/lib/common.sh")
[[ "$via_access" == "$(dirname "$ROOT")/box-access/up.sh" ]] || fail "symlinked gate entry is $via_access"
aos_repo=$(bash -c 'source "$1"; printf %s "$REPO"' _ "$TMP/via/box-upkeep/aos/lib/common.sh")
[[ "$aos_repo" == "$(realpath "$ROOT/aos")" ]] || fail "symlinked aos REPO is $aos_repo"

ln -s "$ROOT/aos/units/aos-watchdog.sh" "$TMP/aos-watchdog.sh"
ln -s "$ROOT/aos/units/cron-watchdog.sh" "$TMP/cron-watchdog.sh"
got=$("$TMP/aos-watchdog.sh" --print-dir)
[[ "$got" == "$(realpath "$ROOT/aos/units")" ]] || fail "file symlink aos dir is $got"
got=$("$TMP/via/box-upkeep/aos/units/cron-watchdog.sh" --print-dir)
[[ "$got" == "$(realpath "$ROOT/aos/units")" ]] || fail "dir symlink cron dir is $got"

mkdir -p "$TMP/bin" "$TMP/home"
cat > "$TMP/bin/java" << 'EOF'
#!/bin/bash
exit 0
EOF
cp "$TMP/bin/java" "$TMP/bin/javac"
cp "$TMP/bin/java" "$TMP/bin/mvn"
cat > "$TMP/bin/gh" << 'EOF'
#!/bin/bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  printf '%s\n' 'n-huche'
fi
exit 0
EOF
cat > "$TMP/access-up.sh" << 'EOF'
#!/bin/bash
exit 0
EOF
cat > "$TMP/aos-up.sh" << 'EOF'
#!/bin/bash
exit 0
EOF
cat > "$TMP/dockerd-ensure.sh" << 'EOF'
#!/bin/bash
printf '%s\n' 'dockerd: present'
exit 0
EOF
chmod +x "$TMP/bin/java" "$TMP/bin/javac" "$TMP/bin/mvn" "$TMP/bin/gh" \
  "$TMP/access-up.sh" "$TMP/aos-up.sh" "$TMP/dockerd-ensure.sh"
out=$(PATH="$TMP/bin:$PATH" HOME_BOX="$TMP/home" \
  BOX_ACCESS_UP="$TMP/access-up.sh" AOS_UP="$TMP/aos-up.sh" \
  DOCKERD_ENSURE="$TMP/dockerd-ensure.sh" \
  "$TMP/via/box-upkeep/up.sh")
repo_line=$(printf '%s\n' "$out" | awk -F= '$1=="repo"{print $2; exit}')
[[ "$repo_line" == "$ROOT" ]] || fail "up.sh via symlink printed repo=$repo_line"
echo "ok paths are derived from the script"

# --- step 05: symlink does not duplicate; another directory is replaced ---

stub=$TMP/checkout
mkdir -p "$stub/units"
cat > "$stub/units/cron-watchdog.sh" << 'EOF'
#!/usr/bin/env bash
sleep 180
EOF
cp "$stub/units/cron-watchdog.sh" "$stub/units/aos-watchdog.sh"
chmod +x "$stub/units/cron-watchdog.sh" "$stub/units/aos-watchdog.sh"
# shellcheck source=../aos/lib/common.sh
source "$ROOT/aos/lib/common.sh"
# shellcheck source=../aos/steps/05-watchdogs.sh
source "$ROOT/aos/steps/05-watchdogs.sh"

REPO=$stub
step_watchdogs >/dev/null
stub_cron=$(realpath "$stub/units/cron-watchdog.sh")
stub_aos=$(realpath "$stub/units/aos-watchdog.sh")
wait_until test "$(count_canon cron-watchdog.sh "$stub_cron")" -eq 1
wait_until test "$(count_canon aos-watchdog.sh "$stub_aos")" -eq 1

ln -s "$stub" "$TMP/checkout-link"
REPO=$TMP/checkout-link
second=$(step_watchdogs)
printf '%s\n' "$second" | grep -q 'already running' || fail "symlink step did not keep the running watchdog"
[[ "$(count_canon cron-watchdog.sh "$stub_cron")" -eq 1 ]] || fail "symlink duplicated cron-watchdog"
[[ "$(count_canon aos-watchdog.sh "$stub_aos")" -eq 1 ]] || fail "symlink duplicated aos-watchdog"
echo "ok a symlink does not start a second watchdog"

old=$TMP/old-checkout/units
mkdir -p "$old"
cp "$stub/units/cron-watchdog.sh" "$old/cron-watchdog.sh"
cp "$stub/units/aos-watchdog.sh" "$old/aos-watchdog.sh"
chmod +x "$old/cron-watchdog.sh" "$old/aos-watchdog.sh"
nohup "$old/cron-watchdog.sh" >/dev/null 2>&1 &
old_cron=$!
pids+=("$old_cron")
nohup "$old/aos-watchdog.sh" >/dev/null 2>&1 &
old_aos=$!
pids+=("$old_aos")
old_cron_canon=$(realpath "$old/cron-watchdog.sh")
old_aos_canon=$(realpath "$old/aos-watchdog.sh")
wait_until test "$(count_canon cron-watchdog.sh "$old_cron_canon")" -eq 1
wait_until test "$(count_canon aos-watchdog.sh "$old_aos_canon")" -eq 1

REPO=$stub
step_watchdogs >/dev/null
wait_until dead "$old_cron"
wait_until dead "$old_aos"
[[ "$(count_canon cron-watchdog.sh "$stub_cron")" -eq 1 ]] || fail "current cron-watchdog was not kept"
[[ "$(count_canon aos-watchdog.sh "$stub_aos")" -eq 1 ]] || fail "current aos-watchdog was not kept"
[[ "$(count_canon cron-watchdog.sh "$old_cron_canon")" -eq 0 ]] || fail "old cron-watchdog still running"
[[ "$(count_canon aos-watchdog.sh "$old_aos_canon")" -eq 0 ]] || fail "old aos-watchdog still running"
echo "ok an old-path watchdog is replaced by the current checkout"

# Stop the stubs before exercising the real unit scripts.
while read -r wpid wpath; do
  [[ "${wpath:-}" == "$TMP"* ]] && kill "$wpid" 2>/dev/null || true
done < <(box_upkeep_list_watchdogs cron-watchdog.sh || true)
while read -r wpid wpath; do
  [[ "${wpath:-}" == "$TMP"* ]] && kill "$wpid" 2>/dev/null || true
done < <(box_upkeep_list_watchdogs aos-watchdog.sh || true)
wait_until test "$(count_canon cron-watchdog.sh "$stub_cron")" -eq 0
wait_until test "$(count_canon aos-watchdog.sh "$stub_aos")" -eq 0

# --- real units: symlink flock, then replace an old copy without touching aos watch ---

idle=$TMP/idle-aos
mkdir -p "$idle"
real_aos=$(realpath "$ROOT/aos/units/aos-watchdog.sh")
real_cron=$(realpath "$ROOT/aos/units/cron-watchdog.sh")

AOS_ROOT=$idle nohup "$real_aos" >/dev/null 2>&1 &
pids+=("$!")
AOS_ROOT=$idle nohup "$real_cron" >/dev/null 2>&1 &
pids+=("$!")
wait_until test -s "$ROOT/aos/units/aos-watchdog.lock/pid"
wait_until test -s "$ROOT/aos/units/cron-watchdog.lock/pid"
[[ "$(count_canon aos-watchdog.sh "$real_aos")" -eq 1 ]] || fail "real aos-watchdog did not stay up"
[[ "$(count_canon cron-watchdog.sh "$real_cron")" -eq 1 ]] || fail "real cron-watchdog did not stay up"

set +e
timeout 5 env AOS_ROOT="$idle" "$TMP/via/box-upkeep/aos/units/aos-watchdog.sh" \
  >"$TMP/second-aos.out" 2>"$TMP/second-aos.err"
aos_rc=$?
timeout 5 env AOS_ROOT="$idle" "$TMP/cron-watchdog.sh" \
  >"$TMP/second-cron.out" 2>"$TMP/second-cron.err"
cron_rc=$?
set -e
[[ "$aos_rc" -eq 0 ]] || fail "symlink aos-watchdog exited $aos_rc: $(cat "$TMP/second-aos.err")"
[[ "$cron_rc" -eq 0 ]] || fail "symlink cron-watchdog exited $cron_rc: $(cat "$TMP/second-cron.err")"
grep -q 'aos-watchdog already running' "$TMP/second-aos.err" || fail "aos symlink did not see the running loop"
grep -q 'cron-watchdog already running' "$TMP/second-cron.err" || fail "cron symlink did not see the running loop"
[[ "$(count_canon aos-watchdog.sh "$real_aos")" -eq 1 ]] || fail "real aos-watchdog was duplicated"
[[ "$(count_canon cron-watchdog.sh "$real_cron")" -eq 1 ]] || fail "real cron-watchdog was duplicated"
echo "ok the real watchdog scripts do not duplicate through a symlink"

# Drop the idle loops so the next start is the one that sees aos watch.
kill_canon() {
  local name=$1 canon=$2 pid path
  while read -r pid path; do
    [[ "${path:-}" == "$canon" ]] && kill "$pid" 2>/dev/null || true
  done < <(box_upkeep_list_watchdogs "$name")
}
kill_canon aos-watchdog.sh "$real_aos"
kill_canon cron-watchdog.sh "$real_cron"
wait_until test "$(count_canon aos-watchdog.sh "$real_aos")" -eq 0
wait_until test "$(count_canon cron-watchdog.sh "$real_cron")" -eq 0
rm -rf "$ROOT/aos/units/aos-watchdog.lock" "$ROOT/aos/units/cron-watchdog.lock"

fake=$TMP/aos-real
link_aos=$TMP/aos-link
mkdir -p "$fake/scripts" "$fake/logs"
ln -s "$fake" "$link_aos"
WATCH_LOG=$TMP/watch-calls.log
export WATCH_LOG
: > "$WATCH_LOG"
cat > "$fake/scripts/aos" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${WATCH_LOG:?}"
if [[ "${1:-}" == "watch" ]]; then
  root=$(dirname "$(dirname "$(realpath "$0")")")
  mkdir -p "$root/logs"
  printf '%s\n' "$$" > "$root/logs/watch.pid"
  sleep 180
fi
exit 0
EOF
chmod +x "$fake/scripts/aos"
"$fake/scripts/aos" watch --loop >/dev/null 2>&1 &
watch_pid=$!
pids+=("$watch_pid")
wait_until test -s "$fake/logs/watch.pid"
[[ "$(cat "$fake/logs/watch.pid")" -eq "$watch_pid" ]] || fail "watch pidfile does not match the process"

nohup "$old/aos-watchdog.sh" >/dev/null 2>&1 &
old_aos=$!
pids+=("$old_aos")
wait_until test "$(count_canon aos-watchdog.sh "$old_aos_canon")" -eq 1

AOS_ROOT=$link_aos nohup "$real_aos" >/dev/null 2>&1 &
pids+=("$!")
wait_until test -s "$ROOT/aos/units/aos-watchdog.lock/pid"
wait_until dead "$old_aos"
# The loop checks the watch immediately after the pidfile write. Give it a moment.
sleep 1
[[ "$(count_canon aos-watchdog.sh "$real_aos")" -eq 1 ]] || fail "replacement aos-watchdog is not the current file"
[[ "$(count_canon aos-watchdog.sh "$old_aos_canon")" -eq 0 ]] || fail "old aos-watchdog survived the real script"
kill -0 "$watch_pid" 2>/dev/null || fail "aos watch was stopped"
if grep -q 'up --watch-only' "$WATCH_LOG"; then
  echo "watch log:" >&2
  cat "$WATCH_LOG" >&2
  fail "aos watch was started again"
fi
found=$(box_upkeep_aos_watch_pid "$link_aos")
[[ "$found" == "$watch_pid" ]] || fail "aos watch pid changed from $watch_pid to ${found:-missing}"
echo "ok replacing an old watchdog leaves the current aos watch running"
