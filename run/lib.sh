# shellcheck shell=bash
# /var/run on a fresh image. No apt work and no set -e.
# run/ensure-run.sh sources this file. Tests point VAR_RUN and RUN_DIR at a
# fake tree and put a fake sudo/pgrep first on PATH.
#
# Debian expects /var/run to be a symlink to /run. An image that ships
# /var/run as a real directory (root, 0700) splits the two: a daemon that
# binds its socket under /run is not found by a client that dials /var/run,
# and a non-root check of /var/run/docker.sock cannot see the socket.
# Daemon-specific runtime directories belong to the repo that owns the daemon.

if [[ -z "${BOX_UPKEEP_RUN_LOADED:-}" ]]; then
  BOX_UPKEEP_RUN_LOADED=1

VAR_RUN=${VAR_RUN:-/var/run}
RUN_DIR=${RUN_DIR:-/run}
# Seconds to wait for a dockerd that is stopped before the move.
RUN_DOCKERD_STOP_WAIT=${RUN_DOCKERD_STOP_WAIT:-20}

# 0 when $VAR_RUN is a symlink that resolves to $RUN_DIR.
box_upkeep_var_run_is_link() {
  local want got
  [[ -L "$VAR_RUN" ]] || return 1
  want=$(/usr/bin/realpath -m -- "$RUN_DIR")
  got=$(/usr/bin/realpath -m -- "$VAR_RUN")
  [[ "$got" == "$want" ]]
}

# Free name for the old directory: <VAR_RUN>.pre-symlink-YYYYMMDD, then
# -HHMMSS when that one is taken. Nothing already there is overwritten.
box_upkeep_var_run_backup_name() {
  local base
  base="${VAR_RUN}.pre-symlink-$(date +%Y%m%d)"
  if ! sudo test -e "$base"; then
    printf '%s\n' "$base"
    return 0
  fi
  base="${base}-$(date +%H%M%S)"
  if sudo test -e "$base"; then
    return 1
  fi
  printf '%s\n' "$base"
}

# A dockerd whose socket or pidfile sits in the real /var/run directory keeps
# those paths after the rename, and clients would look in /run. Stop it so the
# Docker step starts it again on /run. Returns 1 when it does not exit.
box_upkeep_var_run_stop_dockerd() {
  local pid i
  sudo test -e "$VAR_RUN/docker.sock" || sudo test -e "$VAR_RUN/docker.pid" || return 0
  pgrep -x dockerd >/dev/null 2>&1 || return 0
  echo "var-run: stopping dockerd (socket in $VAR_RUN); the Docker step starts it on $RUN_DIR"
  while read -r pid; do
    [[ -n "$pid" ]] || continue
    sudo kill "$pid" 2>/dev/null || true
  done < <(pgrep -x dockerd 2>/dev/null || true)
  for ((i = 0; i < RUN_DOCKERD_STOP_WAIT; i++)); do
    pgrep -x dockerd >/dev/null 2>&1 || return 0
    sleep 1
  done
  echo "ERROR: dockerd did not exit; $VAR_RUN left as a directory" >&2
  return 1
}

# Move each top-level entry of the real /var/run directory into /run unless
# /run already has that name. Sockets stay behind: a socket moved across file
# systems is a dead node. Nothing in /run is overwritten.
box_upkeep_var_run_merge() {
  local entry name
  while IFS= read -r -d '' entry; do
    name=${entry##*/}
    if sudo test -S "$entry"; then
      echo "var-run: kept socket $name in the old directory"
      continue
    fi
    if sudo test -e "$RUN_DIR/$name" || sudo test -L "$RUN_DIR/$name"; then
      echo "var-run: kept $name in the old directory ($RUN_DIR/$name exists)"
      continue
    fi
    if sudo mv -n -- "$entry" "$RUN_DIR/$name"; then
      echo "var-run: moved $name to $RUN_DIR"
    else
      echo "WARN: var-run: could not move $name; kept in the old directory" >&2
    fi
  done < <(sudo find "$VAR_RUN" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

# Idempotent. A symlink to /run is a one-line no-op. A real directory is
# merged into /run, renamed to <VAR_RUN>.pre-symlink-<date>, and replaced by
# a symlink. A symlink elsewhere, or any other file type, is reported and left.
box_upkeep_ensure_var_run() {
  local backup
  if box_upkeep_var_run_is_link; then
    echo "var-run: ok ($VAR_RUN -> $RUN_DIR)"
    return 0
  fi
  if [[ -L "$VAR_RUN" ]]; then
    echo "ERROR: $VAR_RUN is a symlink to $(readlink -- "$VAR_RUN"), not $RUN_DIR; left as is" >&2
    return 1
  fi
  sudo mkdir -p -- "$RUN_DIR" || return 1
  if ! sudo test -e "$VAR_RUN"; then
    sudo ln -s -- "$RUN_DIR" "$VAR_RUN" || return 1
    echo "var-run: created $VAR_RUN -> $RUN_DIR"
    return 0
  fi
  if ! sudo test -d "$VAR_RUN"; then
    echo "ERROR: $VAR_RUN is not a directory or a symlink; left as is" >&2
    return 1
  fi
  echo "var-run: $VAR_RUN is a directory, not a symlink to $RUN_DIR; fixing"
  box_upkeep_var_run_stop_dockerd || return 1
  box_upkeep_var_run_merge
  if ! backup=$(box_upkeep_var_run_backup_name); then
    echo "ERROR: no free backup name for $VAR_RUN; left as is" >&2
    return 1
  fi
  sudo mv -T -- "$VAR_RUN" "$backup" || return 1
  if ! sudo ln -s -- "$RUN_DIR" "$VAR_RUN"; then
    echo "ERROR: could not create $VAR_RUN -> $RUN_DIR; restoring the directory" >&2
    sudo mv -T -- "$backup" "$VAR_RUN" || true
    return 1
  fi
  echo "var-run: renamed the old directory to $backup (nothing deleted)"
  echo "var-run: created $VAR_RUN -> $RUN_DIR"
}


fi
