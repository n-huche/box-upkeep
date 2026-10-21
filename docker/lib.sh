# dockerd process, socket, and keep-alive helpers.
# No apt work and no set -e. ensure-dockerd.sh and dockerd-watchdog.sh
# source this file. Paths come from this file's real path.

if [[ -z "${BOX_UPKEEP_DOCKER_LOADED:-}" ]]; then
  BOX_UPKEEP_DOCKER_LOADED=1

_docker_lib_dir=$(dirname "$(/usr/bin/realpath "${BASH_SOURCE[0]}")")
# shellcheck source=../aos/lib/proc.sh
source "$_docker_lib_dir/../aos/lib/proc.sh"

DOCKER_DIR=$_docker_lib_dir
# Socket and pidfile live in /run, not /var/run. An image that ships /var/run
# as a root-only directory hides /var/run/docker.sock from a non-root check;
# run/ensure-run.sh restores the symlink, and these paths do not depend on it.
DOCKER_SOCK=${DOCKER_SOCK:-/run/docker.sock}
DOCKERD_PIDFILE=${DOCKERD_PIDFILE:-/run/docker.pid}
DOCKER_LOG=${DOCKER_LOG:-$DOCKER_DIR/dockerd.log}
unset _docker_lib_dir

# First hit on PATH, then the usual locations. /usr/sbin is often absent from
# a non-login PATH, which is where Debian installs dockerd.
# DOCKERD_BIN_CANDIDATES / DOCKER_BIN_CANDIDATES replace the fallback list
# (an empty value means PATH only; tests use that).
box_upkeep_path_bin() {
  local cmd=$1 candidates=$2 bin
  bin=$(command -v "$cmd" 2>/dev/null || true)
  if [[ -n "$bin" && -x "$bin" ]]; then
    printf '%s\n' "$bin"
    return 0
  fi
  local IFS=':'
  for bin in $candidates; do
    [[ -n "$bin" && -x "$bin" ]] || continue
    printf '%s\n' "$bin"
    return 0
  done
  return 1
}

box_upkeep_dockerd_bin() {
  local candidates
  if [[ -z "${DOCKERD_BIN_CANDIDATES+x}" ]]; then
    candidates=/usr/sbin/dockerd:/usr/bin/dockerd
  else
    candidates=$DOCKERD_BIN_CANDIDATES
  fi
  box_upkeep_path_bin dockerd "$candidates"
}

box_upkeep_docker_cli() {
  local candidates
  if [[ -z "${DOCKER_BIN_CANDIDATES+x}" ]]; then
    candidates=/usr/bin/docker
  else
    candidates=$DOCKER_BIN_CANDIDATES
  fi
  box_upkeep_path_bin docker "$candidates"
}

# Both binaries are required. docker.io provides dockerd; docker-cli provides docker.
# A missing binary fails the check and does not abort the caller.
box_upkeep_docker_bins_present() {
  box_upkeep_dockerd_bin >/dev/null || return 1
  box_upkeep_docker_cli >/dev/null || return 1
}

# Pid in DOCKERD_PIDFILE when that process is alive. Read with sudo: dockerd
# writes the file as root. Empty output when there is no usable pid.
box_upkeep_dockerd_pidfile_pid() {
  local pid
  pid=$(sudo cat "$DOCKERD_PIDFILE" 2>/dev/null | tr -cd '0-9' || true)
  [[ -n "$pid" && -d "/proc/$pid" ]] || return 1
  [[ "$(cat "/proc/$pid/comm" 2>/dev/null || true)" == dockerd ]] || return 1
  printf '%s\n' "$pid"
}

# True when dockerd is running and its socket exists. The process is the
# pidfile pid, or any dockerd when the pidfile is absent (a daemon started
# before --pidfile). The socket is checked through sudo so a root-only
# parent directory does not hide it.
box_upkeep_dockerd_running() {
  if ! box_upkeep_dockerd_pidfile_pid >/dev/null; then
    pgrep -x dockerd >/dev/null 2>&1 || return 1
  fi
  sudo test -S "$DOCKER_SOCK"
}

# Mode 666 so the box user can run docker in this session. Membership in the
# docker group is not visible until a new login, and this host has no systemd
# to arrange that. usermod still records the group for a later login.
box_upkeep_open_docker_socket() {
  sudo test -S "$DOCKER_SOCK" || return 1
  sudo chmod 666 "$DOCKER_SOCK" || return 1
  if id box >/dev/null 2>&1 && getent group docker >/dev/null 2>&1; then
    sudo usermod -aG docker box || true
  fi
}

# Start dockerd in a new session. Returns 0 once the socket accepts chmod.
# Does not install packages; ensure-dockerd.sh does that.
box_upkeep_start_dockerd() {
  local bin log i
  bin=$(box_upkeep_dockerd_bin 2>/dev/null || true)
  if [[ -z "$bin" || ! -x "$bin" ]]; then
    echo "ERROR: dockerd binary missing" >&2
    return 1
  fi
  log=${DOCKER_LOG:-$DOCKER_DIR/dockerd.log}
  sudo mkdir -p /var/lib/docker || return 1
  echo "dockerd: starting $bin"
  sudo mkdir -p -- "$(dirname -- "$DOCKER_SOCK")" "$(dirname -- "$DOCKERD_PIDFILE")" || return 1
  sudo setsid "$bin" --host="unix://${DOCKER_SOCK}" --pidfile="$DOCKERD_PIDFILE" >>"$log" 2>&1 &
  for ((i = 0; i < 20; i++)); do
    if box_upkeep_dockerd_running; then
      box_upkeep_open_docker_socket || return 1
      echo "dockerd: started"
      return 0
    fi
    sleep 1
  done
  echo "ERROR: dockerd failed to stay up after start" >&2
  return 1
}

# Start docker/dockerd-watchdog.sh unless this exact file is already looping.
# DOCKERD_WATCHDOG overrides the script path (tests). A copy at another path
# with the same basename is stopped first.
box_upkeep_start_dockerd_watchdog() {
  local canon
  if [[ -n "${DOCKERD_WATCHDOG:-}" ]]; then
    canon=$(box_upkeep_realpath "$DOCKERD_WATCHDOG")
  else
    canon=$(box_upkeep_realpath "$DOCKER_DIR/dockerd-watchdog.sh")
  fi
  if [[ ! -x "$canon" ]]; then
    echo "ERROR: dockerd watchdog missing: $canon" >&2
    return 1
  fi
  box_upkeep_stop_other_watchdogs "$canon" || return 1
  if box_upkeep_watchdog_running "$canon" >/dev/null; then
    echo "watchdog: already running ($canon)"
    return 0
  fi
  echo "watchdog: starting dockerd keep-alive ($canon)"
  nohup "$canon" >/dev/null 2>&1 &
  sleep 1
  if box_upkeep_watchdog_running "$canon" >/dev/null; then
    return 0
  fi
  echo "ERROR: dockerd watchdog failed to stay up" >&2
  return 1
}

fi
