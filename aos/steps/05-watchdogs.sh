#!/usr/bin/env bash
# Start the vendored cron and AOS keep-alive loops (bash, flock, nohup).
# Not systemd. aos/aos-up.sh skips this step on --no-watchdogs.
# Replaces an already-running copy of these two scripts so a re-run picks
# up the current files: aos/units/, a leftover pair started from the old
# repo-root units/, and a leftover pair under /home/box/upkeep/.
# Does not start the gate's loops.

box_upkeep_script_pids() {
  local script=$1 pid cmd toks i prev
  for pid in /proc/[0-9]*; do
    pid=${pid#/proc/}
    [[ "$pid" == "$$" ]] && continue
    [[ -r "/proc/$pid/cmdline" ]] || continue
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
    [[ -n "$cmd" ]] || continue
    # shellcheck disable=SC2206
    toks=($cmd)
    for ((i = 0; i < ${#toks[@]}; i++)); do
      [[ "${toks[$i]}" == "$script" ]] || continue
      if (( i == 0 )); then
        printf '%s\n' "$pid"
        break
      fi
      prev=${toks[$((i - 1))]}
      case "$prev" in
        bash|*/bash|env|*/env|nohup|*/nohup)
          printf '%s\n' "$pid"
          break
          ;;
      esac
    done
  done
}

stop_prior_watchdogs() {
  local legacy="${HOME_BOX:-/home/box}/upkeep"
  local previous
  previous=$(cd "$REPO/.." && pwd)/units
  local scripts=(
    "$REPO/units/cron-watchdog.sh"
    "$REPO/units/aos-watchdog.sh"
    "$previous/cron-watchdog.sh"
    "$previous/aos-watchdog.sh"
    "$legacy/cron-watchdog.sh"
    "$legacy/aos-watchdog.sh"
  )
  local script pids n
  pids=""
  for script in "${scripts[@]}"; do
    pids+=$(box_upkeep_script_pids "$script")
    pids+=$'\n'
  done
  pids=$(printf '%s\n' "$pids" | awk 'NF && !seen[$0]++')
  if [[ -n "$pids" ]]; then
    echo "stopping prior cron/aos watchdogs: $(echo "$pids" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    n=0
    while true; do
      local still=""
      for script in "${scripts[@]}"; do
        still+=$(box_upkeep_script_pids "$script")
        still+=$'\n'
      done
      still=$(printf '%s\n' "$still" | awk 'NF && !seen[$0]++')
      [[ -z "$still" ]] && break
      sleep 1
      n=$((n + 1))
      if (( n >= 5 )); then
        echo "WARN: leftover cron/aos watchdogs still running; sending SIGKILL" >&2
        # shellcheck disable=SC2086
        kill -9 $still 2>/dev/null || true
        sleep 1
        break
      fi
    done
  fi
  local still=""
  for script in "${scripts[@]}"; do
    still+=$(box_upkeep_script_pids "$script")
    still+=$'\n'
  done
  still=$(printf '%s\n' "$still" | awk 'NF && !seen[$0]++')
  if [[ -n "$still" ]]; then
    echo "ERROR: prior cron/aos watchdogs still running; leaving lock files" >&2
    return 1
  fi
  rm -f \
    "$REPO/units/cron-watchdog.lock/pid" \
    "$REPO/units/aos-watchdog.lock/pid" \
    "$previous/cron-watchdog.lock/pid" \
    "$previous/aos-watchdog.lock/pid" \
    "$legacy/cron-watchdog.lock/pid" \
    "$legacy/aos-watchdog.lock/pid"
}

step_watchdogs() {
  local cron="$REPO/units/cron-watchdog.sh"
  local aos="$REPO/units/aos-watchdog.sh"
  if [[ ! -x "$cron" || ! -x "$aos" ]]; then
    echo "ERROR: watchdog scripts missing under $REPO/units" >&2
    return 1
  fi
  stop_prior_watchdogs
  echo "watchdog: starting cron keep-alive ($cron)"
  nohup "$cron" >/dev/null 2>&1 &
  sleep 1
  echo "watchdog: starting aos keep-alive ($aos)"
  nohup "$aos" >/dev/null 2>&1 &
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  box_upkeep_parse_aos_args "$@"
  if [[ "$NO_WATCHDOGS" -eq 1 ]]; then
    echo "watchdog: skipped (--no-watchdogs)"
    exit 0
  fi
  step_watchdogs
fi
