# Canonical paths and process identity for the cron and AOS watchdogs.
# No side effects on source. Paths come from realpath of the script file
# (dirname of $0 / BASH_SOURCE after symlink resolution).

if [[ -z "${BOX_UPKEEP_PROC_LOADED:-}" ]]; then
  BOX_UPKEEP_PROC_LOADED=1

# realpath from a known location. Tests source this file with a stripped PATH.
box_upkeep_realpath() {
  local bin=/usr/bin/realpath
  if [[ ! -x "$bin" ]]; then
    bin=/bin/realpath
  fi
  if [[ ! -x "$bin" ]]; then
    bin=$(command -v realpath)
  fi
  "$bin" "$@"
}

# Basename that does not treat a leading dash as an option.
box_upkeep_base() {
  local token=$1
  if [[ "$token" == */* ]]; then
    basename -- "$token"
  else
    printf '%s\n' "$token"
  fi
}

box_upkeep_script_dir() {
  local src=$1 resolved
  if [[ -e "$src" ]]; then
    resolved=$(box_upkeep_realpath "$src")
    if [[ -d "$resolved" ]]; then
      printf '%s\n' "$resolved"
      return 0
    fi
    dirname "$resolved"
    return 0
  fi
  box_upkeep_realpath "$(dirname "$src")"
}

# Resolve a cmdline or env token the way the kernel sees it.
# Relative tokens are joined to that process's cwd, not the caller's.
box_upkeep_canon_token() {
  local pid=$1 token=$2 path cwd
  path=$token
  if [[ "$path" != /* ]]; then
    if [[ "$path" != */* ]]; then
      printf '%s\n' "$token"
      return 0
    fi
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || true)
    if [[ -z "$cwd" ]]; then
      printf '%s\n' "$token"
      return 0
    fi
    path="$cwd/$token"
  fi
  if [[ -e "$path" ]]; then
    box_upkeep_realpath "$path"
    return 0
  fi
  printf '%s\n' "$path"
}

box_upkeep_pid_tokens() {
  local pid=$1 token
  [[ -r "/proc/$pid/cmdline" ]] || return 0
  while IFS= read -r token || [[ -n "$token" ]]; do
    [[ -n "$token" ]] && printf '%s\n' "$token"
  done < <(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null || true)
}

box_upkeep_token_is_watchdog() {
  local token=$1 base=$2 prev=$3 index=$4
  [[ "$(box_upkeep_base "$token")" == "$base" ]] || return 1
  if (( index == 0 )); then
    return 0
  fi
  case "$prev" in
    bash|*/bash|sh|*/sh|env|*/env|nohup|*/nohup) return 0 ;;
  esac
  return 1
}

# Lines of "pid canon" for processes running a script named $1.
box_upkeep_list_watchdogs() {
  local base=$1 pid token prev index canon
  local -a tokens=()
  for pid in /proc/[0-9]*; do
    pid=${pid#/proc/}
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    tokens=()
    while IFS= read -r token; do
      tokens+=("$token")
    done < <(box_upkeep_pid_tokens "$pid")
    ((${#tokens[@]} == 0)) && continue
    prev=""
    for ((index = 0; index < ${#tokens[@]}; index++)); do
      token=${tokens[$index]}
      box_upkeep_token_is_watchdog "$token" "$base" "$prev" "$index" || {
        prev=$token
        continue
      }
      canon=$(box_upkeep_canon_token "$pid" "$token")
      printf '%s %s\n' "$pid" "$canon"
      break
    done
  done
}

box_upkeep_pid_alive() {
  local pid=$1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

# True when pid is `aos watch` for this root (or any aos watch if root is empty).
# `--watch-only` is not the token `watch`. `aos up` is rejected.
box_upkeep_pid_is_aos_watch() {
  local pid=$1 bin=${2:-} root=${3:-}
  box_upkeep_pid_alive "$pid" || return 1
  local -a tokens=()
  local token canon saw_watch=0 saw_up=0 script_match=0 env_match=0 env_root env_canon root_canon
  while IFS= read -r token; do
    tokens+=("$token")
  done < <(box_upkeep_pid_tokens "$pid")
  ((${#tokens[@]} == 0)) && return 1
  for token in "${tokens[@]}"; do
    [[ "$token" == "watch" ]] && saw_watch=1
    [[ "$token" == "up" ]] && saw_up=1
    [[ "$(box_upkeep_base "$token")" == "aos-watchdog.sh" ]] && return 1
    [[ "$(box_upkeep_base "$token")" == "cron-watchdog.sh" ]] && return 1
    if [[ -n "$bin" ]]; then
      canon=$(box_upkeep_canon_token "$pid" "$token")
      [[ "$canon" == "$bin" ]] && script_match=1
    elif [[ "$(box_upkeep_base "$token")" == "aos" ]]; then
      script_match=1
    fi
  done
  [[ "$saw_watch" -eq 1 && "$saw_up" -eq 0 ]] || return 1
  if [[ -n "$root" && -r "/proc/$pid/environ" ]]; then
    env_root=$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^AOS_ROOT=//p' | head -n 1 || true)
    if [[ -n "$env_root" ]]; then
      env_canon=$(box_upkeep_canon_token "$pid" "$env_root")
      root_canon=$root
      [[ -e "$root" ]] && root_canon=$(box_upkeep_realpath "$root")
      [[ "$env_canon" == "$root_canon" ]] && env_match=1
    fi
  fi
  [[ "$script_match" -eq 1 || "$env_match" -eq 1 ]]
}

# Pid of the long-running aos watch for this checkout, if one is alive.
# Pidfile first ($AOS_ROOT/logs/watch.pid), then /proc with realpath.
box_upkeep_aos_watch_pid() {
  local root=$1 root_real bin pidfile pid entry
  [[ -n "$root" && -e "$root" ]] || return 1
  root_real=$(box_upkeep_realpath "$root")
  if [[ -e "$root_real/scripts/aos" ]]; then
    bin=$(box_upkeep_realpath "$root_real/scripts/aos")
  else
    bin="$root_real/scripts/aos"
  fi
  pidfile="$root_real/logs/watch.pid"
  if [[ -f "$pidfile" ]]; then
    pid=$(awk 'NF { print $1; exit }' "$pidfile")
    if box_upkeep_pid_is_aos_watch "$pid" "$bin" "$root_real"; then
      printf '%s\n' "$pid"
      return 0
    fi
  fi
  for entry in /proc/[0-9]*; do
    pid=${entry#/proc/}
    if box_upkeep_pid_is_aos_watch "$pid" "$bin" "$root_real"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

box_upkeep_lock_pid() {
  local canon=$1 pidfile pid
  pidfile="$(dirname "$canon")/$(basename -- "$canon" .sh).lock/pid"
  [[ -f "$pidfile" ]] || return 1
  pid=$(awk 'NF { print $1; exit }' "$pidfile")
  box_upkeep_pid_alive "$pid" || return 1
  local listed path
  while read -r listed path; do
    [[ "$listed" == "$pid" && "$path" == "$canon" ]] || continue
    printf '%s\n' "$pid"
    return 0
  done < <(box_upkeep_list_watchdogs "$(basename -- "$canon")")
  # Cmdline path was deleted. The open lock file is still this checkout.
  local fd target lock_canon
  lock_canon=$(box_upkeep_realpath "$pidfile")
  for fd in "/proc/$pid/fd/"*; do
    target=$(readlink "$fd" 2>/dev/null || true)
    if [[ "$target" == "$lock_canon" || "$target" == "$pidfile" ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

# Print the pid when this exact file is already the running watchdog.
box_upkeep_watchdog_running() {
  local canon=$1 pid path
  while read -r pid path; do
    [[ -n "${pid:-}" ]] || continue
    [[ "$path" == "$canon" ]] || continue
    printf '%s\n' "$pid"
    return 0
  done < <(box_upkeep_list_watchdogs "$(basename -- "$canon")")
  box_upkeep_lock_pid "$canon"
}

box_upkeep_stop_pids() {
  local -a pids=("$@")
  ((${#pids[@]} == 0)) && return 0
  kill "${pids[@]}" 2>/dev/null || true
  local n=0 pid
  local -a still=()
  while (( n < 5 )); do
    still=()
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        still+=("$pid")
      fi
    done
    ((${#still[@]} == 0)) && return 0
    sleep 1
    n=$((n + 1))
  done
  echo "WARN: leftover cron/aos watchdogs still running; sending SIGKILL" >&2
  kill -9 "${still[@]}" 2>/dev/null || true
  sleep 1
  for pid in "${still[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      echo "ERROR: prior cron/aos watchdogs still running" >&2
      return 1
    fi
  done
  return 0
}

# Stop watchdogs whose script is not $1. Same realpath (symlink or real
# path) is left running. Does not signal aos watch.
box_upkeep_stop_other_watchdogs() {
  local canon=$1 base pid path
  base=$(basename -- "$canon")
  local -a pids=()
  local -a paths=()
  while read -r pid path; do
    [[ -n "${pid:-}" ]] || continue
    [[ "$pid" == "$$" ]] && continue
    [[ "$path" == "$canon" ]] && continue
    if box_upkeep_pid_is_aos_watch "$pid" "" ""; then
      continue
    fi
    pids+=("$pid")
    paths+=("$path")
  done < <(box_upkeep_list_watchdogs "$base")
  if ((${#pids[@]} == 0)); then
    return 0
  fi
  echo "stopping prior ${base}: ${pids[*]}"
  box_upkeep_stop_pids "${pids[@]}" || return 1
  local old dir name
  for old in "${paths[@]}"; do
    [[ "$old" == /* ]] || continue
    dir=$(dirname "$old")
    name=$(basename -- "$old" .sh)
    rm -f "$dir/$name.lock/pid"
  done
}

box_upkeep_rewrite_path_token() {
  local token=$1 canon root key path
  shift
  if [[ "$token" =~ ^([A-Za-z_][A-Za-z0-9_]*=)(/.*)$ ]]; then
    key=${BASH_REMATCH[1]}
    path=${BASH_REMATCH[2]}
    printf '%s%s' "$key" "$(box_upkeep_rewrite_path_token "$path" "$@")"
    return 0
  fi
  if [[ "$token" != /* ]]; then
    printf '%s' "$token"
    return 0
  fi
  canon=$(box_upkeep_realpath -m "$token" 2>/dev/null || printf '%s' "$token")
  if [[ "$canon" == "$token" ]]; then
    printf '%s' "$token"
    return 0
  fi
  for root in "$@"; do
    if [[ "$canon" == "$root" || "$canon" == "$root"/* ]]; then
      printf '%s' "$canon"
      return 0
    fi
  done
  printf '%s' "$token"
}

box_upkeep_canonicalize_crontab_line() {
  local line=$1
  shift
  local out="" rest=$line chunk
  while [[ -n "$rest" ]]; do
    if [[ "$rest" =~ ^([^[:space:]]+) ]]; then
      chunk=${BASH_REMATCH[1]}
      out+=$(box_upkeep_rewrite_path_token "$chunk" "$@")
      rest=${rest:${#chunk}}
    else
      break
    fi
    [[ -z "$rest" ]] && break
    if [[ "$rest" =~ ^([[:space:]]+) ]]; then
      chunk=${BASH_REMATCH[1]}
      out+=$chunk
      rest=${rest:${#chunk}}
    else
      break
    fi
  done
  printf '%s' "$out"
}

# Rewrite symlink paths under the given roots to their realpath.
# Trailing newline is preserved. Other lines are unchanged.
box_upkeep_canonicalize_crontab() {
  local text=$1 line had_nl=0 updated="" canon root
  shift
  local -a roots=()
  [[ "$text" == *$'\n' ]] && had_nl=1
  for root in "$@"; do
    [[ -z "$root" ]] && continue
    if [[ -e "$root" ]]; then
      canon=$(box_upkeep_realpath "$root")
    else
      canon=$(box_upkeep_realpath -m "$root")
    fi
    roots+=("$canon")
  done
  while IFS= read -r line || [[ -n "$line" ]]; do
    if ((${#roots[@]} > 0)); then
      updated+=$(box_upkeep_canonicalize_crontab_line "$line" "${roots[@]}")
    else
      updated+=$line
    fi
    updated+=$'\n'
  done < <(printf '%s' "$text")
  if [[ "$had_nl" -eq 0 ]]; then
    updated=${updated%$'\n'}
  fi
  printf '%s' "$updated"
}

# After `aos up`, store canonical paths in the installed crontab.
# No crontab command, or an empty crontab, is a no-op.
box_upkeep_refresh_crontab_paths() {
  local repo_root=$1 aos_root=$2 current updated
  command -v crontab >/dev/null 2>&1 || return 0
  if ! current=$(crontab -l 2>/dev/null); then
    return 0
  fi
  [[ -n "$current" ]] || return 0
  updated=$(box_upkeep_canonicalize_crontab "$current" "$repo_root" "$aos_root")
  [[ "$updated" == "$current" ]] && return 0
  printf '%s\n' "$updated" | crontab -
}

fi
