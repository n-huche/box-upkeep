#!/usr/bin/env bash
# dockerd install, start, and keep-alive. Mock apt, pgrep, and sudo. No network.
# up.sh cases use mock gate, aos, and dockerd entries.
set -euo pipefail

ROOT=$(realpath "$(dirname "$0")/..")
TMP=$(mktemp -d)
watch_script=
cleanup() {
  if [[ -n "${watch_script:-}" ]]; then
    pkill -f -- "$watch_script" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

if [[ ! -x "$ROOT/docker/ensure-dockerd.sh" || ! -x "$ROOT/docker/dockerd-watchdog.sh" ]]; then
  echo "FAIL docker scripts are not executable"
  exit 1
fi
if ! grep -q 'set -euo pipefail' "$ROOT/docker/ensure-dockerd.sh"; then
  echo "FAIL docker/ensure-dockerd.sh missing set -euo pipefail"
  exit 1
fi
if grep -q 'docker' "$ROOT/aos/packages.txt"; then
  echo "FAIL Docker packages belong in docker/ensure-dockerd.sh, not aos/packages.txt"
  exit 1
fi
if grep -R -n --include='*.sh' -E 'systemctl|\.service' "$ROOT/docker" >/dev/null; then
  echo "FAIL systemd unit reference in docker scripts"
  exit 1
fi
pkg=$(env -u DOCKER_PACKAGE bash -c 'source "$1"; printf %s "$DOCKER_PACKAGE"' _ "$ROOT/lib/common.sh")
if [[ "$pkg" != "docker.io" ]]; then
  echo "FAIL default DOCKER_PACKAGE was $pkg"
  exit 1
fi
ens=$(env -u DOCKERD_ENSURE bash -c 'source "$1"; printf %s "$DOCKERD_ENSURE"' _ "$ROOT/lib/common.sh")
if [[ "$ens" != "$ROOT/docker/ensure-dockerd.sh" ]]; then
  echo "FAIL DOCKERD_ENSURE default was $ens"
  exit 1
fi
echo "ok docker scripts stay out of aos/packages.txt"

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL python3 is required to build a fake docker socket"
  exit 1
fi

BIN=$TMP/bin
SUDO_LOG=$TMP/sudo.log
SOCK_DIR=$TMP/sock
DOCKER_SOCK=$SOCK_DIR/docker.sock
DOCKER_LOG=$TMP/dockerd.log
DOCKERD_PIDFILE=$TMP/dockerd.pid
STUB=$TMP/stub
APT_INSTALL_RC=0
export SUDO_LOG DOCKER_SOCK DOCKER_LOG DOCKERD_PIDFILE STUB BIN APT_INSTALL_RC

mkdir -p "$BIN" "$SOCK_DIR"
cat > "$STUB" << 'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$STUB"
cat > "$BIN/pgrep" << 'EOF'
#!/bin/bash
if [[ "${1:-}" == "-x" && "${2:-}" == "dockerd" && -f "${PGREP_DOCKERD_MARKER:-$DOCKERD_PIDFILE}" ]]; then
  exit 0
fi
exit 1
EOF
cat > "$BIN/sudo" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SUDO_LOG"
case "${1:-}" in
  test|cat|mkdir) exec "$@" ;;
esac
if [[ "$*" == *"apt-get install"* && "${APT_INSTALL_RC:-0}" -ne 0 ]]; then
  exit "$APT_INSTALL_RC"
fi
if [[ "$*" == *"apt-get install"* ]]; then
  /bin/cp "$STUB" "$BIN/dockerd"
  /bin/cp "$STUB" "$BIN/docker"
  /bin/chmod +x "$BIN/dockerd" "$BIN/docker"
fi
if [[ "$*" == *setsid* ]]; then
  : > "$DOCKERD_PIDFILE"
  /usr/bin/python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$DOCKER_SOCK"
fi
exit 0
EOF
chmod +x "$BIN/pgrep" "$BIN/sudo"

make_socket() {
  rm -f "$DOCKER_SOCK"
  /usr/bin/python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$DOCKER_SOCK"
}

reset_docker() {
  rm -f "$SUDO_LOG" "$DOCKERD_PIDFILE" "$DOCKER_SOCK" "$BIN/dockerd" "$BIN/docker"
  APT_INSTALL_RC=0
}

run_ensure() {
  PATH="$BIN:/usr/bin:/bin" \
    NO_WATCHDOGS="${NO_WATCHDOGS:-1}" \
    DOCKER_PACKAGE="${DOCKER_PACKAGE:-docker.io}" \
    DOCKERD_WATCHDOG="${DOCKERD_WATCHDOG:-}" \
    DOCKERD_BIN_CANDIDATES= \
    DOCKER_BIN_CANDIDATES= \
    /bin/bash "$ROOT/docker/ensure-dockerd.sh"
}

reset_docker
cp "$STUB" "$BIN/dockerd"
cp "$STUB" "$BIN/docker"
: > "$DOCKERD_PIDFILE"
make_socket
NO_WATCHDOGS=1
out=$(run_ensure)
if ! printf '%s\n' "$out" | grep -qx 'dockerd: present'; then
  echo "FAIL a running dockerd was not left alone"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'watchdog: skipped (--no-watchdogs)'; then
  echo "FAIL --no-watchdogs did not skip the dockerd loop"
  printf '%s\n' "$out"
  exit 1
fi
if grep -q 'apt-get\|setsid' "$SUDO_LOG"; then
  echo "FAIL present dockerd still installed or started"
  cat "$SUDO_LOG"
  exit 1
fi
if ! grep -q 'chmod 666' "$SUDO_LOG"; then
  echo "FAIL present dockerd did not open the socket"
  cat "$SUDO_LOG"
  exit 1
fi
echo "ok a running dockerd is left up and the socket is opened"

reset_docker
NO_WATCHDOGS=1
out=$(run_ensure)
if ! printf '%s\n' "$out" | grep -qx 'dockerd-install: docker.io docker-cli'; then
  echo "FAIL missing binaries did not announce docker.io and docker-cli"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'dockerd: installed docker.io docker-cli'; then
  echo "FAIL install did not report success"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'dockerd: started'; then
  echo "FAIL install did not start dockerd"
  printf '%s\n' "$out"
  exit 1
fi
if ! grep -qx 'apt-get update -y' "$SUDO_LOG"; then
  echo "FAIL apt-get update was not invoked"
  cat "$SUDO_LOG"
  exit 1
fi
if ! grep -qx 'DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-cli' "$SUDO_LOG"; then
  echo "FAIL apt-get install line: $(cat "$SUDO_LOG")"
  exit 1
fi
if ! grep -q 'setsid' "$SUDO_LOG"; then
  echo "FAIL dockerd was not started with setsid"
  cat "$SUDO_LOG"
  exit 1
fi
echo "ok missing docker.io and docker-cli are installed and dockerd is started"

reset_docker
cp "$STUB" "$BIN/dockerd"
cp "$STUB" "$BIN/docker"
NO_WATCHDOGS=1
out=$(run_ensure)
if printf '%s\n' "$out" | grep -q 'dockerd-install:'; then
  echo "FAIL binaries present still reinstalled"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'dockerd: started'; then
  echo "FAIL a down dockerd was not started"
  printf '%s\n' "$out"
  exit 1
fi
if grep -q 'apt-get' "$SUDO_LOG"; then
  echo "FAIL a down dockerd reinstalled packages"
  cat "$SUDO_LOG"
  exit 1
fi
echo "ok a down dockerd is started without reinstalling"

reset_docker
APT_INSTALL_RC=7
NO_WATCHDOGS=1
set +e
out=$(run_ensure 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL apt-get install failure was accepted"
  printf '%s\n' "$out"
  exit 1
fi
if ! grep -q 'apt-get install failed' "$TMP/err"; then
  echo "FAIL apt-get install failure was not reported"
  cat "$TMP/err"
  exit 1
fi
echo "ok apt-get install failure is reported"

offpath=$TMP/offpath
mkdir -p "$offpath"
cp "$STUB" "$offpath/dockerd"
cp "$STUB" "$offpath/docker"
chmod +x "$offpath/dockerd" "$offpath/docker"
if ! PATH="/usr/bin:/bin" \
  DOCKERD_BIN_CANDIDATES="$offpath/dockerd" \
  DOCKER_BIN_CANDIDATES="$offpath/docker" \
  /bin/bash -c 'source "$1"; box_upkeep_docker_bins_present' _ "$ROOT/docker/lib.sh"; then
  echo "FAIL dockerd outside PATH was treated as missing"
  exit 1
fi
if PATH="/usr/bin:/bin" \
  DOCKERD_BIN_CANDIDATES= \
  DOCKER_BIN_CANDIDATES= \
  /bin/bash -c 'source "$1"; box_upkeep_docker_bins_present' _ "$ROOT/docker/lib.sh"; then
  echo "FAIL empty candidate list found a host dockerd"
  exit 1
fi
echo "ok dockerd is found outside PATH"

paths=$(env -u DOCKER_SOCK -u DOCKERD_PIDFILE bash -c 'source "$1"; printf "%s %s" "$DOCKER_SOCK" "$DOCKERD_PIDFILE"' _ "$ROOT/docker/lib.sh")
if [[ "$paths" != "/run/docker.sock /run/docker.pid" ]]; then
  echo "FAIL default socket and pidfile are not in /run: $paths"
  exit 1
fi
if grep -n '/var/run' "$ROOT/docker/lib.sh" | grep -v '^[0-9]*:#' >/dev/null; then
  echo "FAIL docker/lib.sh still uses /var/run outside comments"
  exit 1
fi
echo "ok dockerd socket and pidfile default to /run"

reset_docker
cp "$STUB" "$BIN/dockerd"
cp "$STUB" "$BIN/docker"
NO_WATCHDOGS=1
out=$(run_ensure)
if ! grep -qF -- "--host=unix://${DOCKER_SOCK} --pidfile=${DOCKERD_PIDFILE}" "$SUDO_LOG"; then
  echo "FAIL dockerd was not started with an explicit socket and pidfile"
  cat "$SUDO_LOG"
  exit 1
fi
if ! grep -qx "test -S ${DOCKER_SOCK}" "$SUDO_LOG"; then
  echo "FAIL the socket check did not go through sudo"
  cat "$SUDO_LOG"
  exit 1
fi
echo "ok dockerd starts with --host and --pidfile and is checked through sudo"

# The pidfile identifies dockerd even when pgrep does not see it (the case
# where /var/run hid the socket from a non-root check).
reset_docker
mkdir -p "$TMP/fakeproc"
cp "$(command -v sleep)" "$TMP/fakeproc/dockerd"
"$TMP/fakeproc/dockerd" 60 &
fake_pid=$!
pidfile_only=$TMP/real.pid
printf '%s\n' "$fake_pid" > "$pidfile_only"
make_socket
if ! PATH="$BIN:/usr/bin:/bin" DOCKERD_PIDFILE="$pidfile_only" PGREP_DOCKERD_MARKER="$TMP/no-dockerd" \
  /bin/bash -c 'source "$1"; box_upkeep_dockerd_running' _ "$ROOT/docker/lib.sh"; then
  kill "$fake_pid" 2>/dev/null || true
  echo "FAIL a live dockerd pid in the pidfile was reported down"
  exit 1
fi
rm -f "$DOCKER_SOCK"
if PATH="$BIN:/usr/bin:/bin" DOCKERD_PIDFILE="$pidfile_only" PGREP_DOCKERD_MARKER="$TMP/no-dockerd" \
  /bin/bash -c 'source "$1"; box_upkeep_dockerd_running' _ "$ROOT/docker/lib.sh"; then
  kill "$fake_pid" 2>/dev/null || true
  echo "FAIL dockerd without its socket was reported up"
  exit 1
fi
kill "$fake_pid" 2>/dev/null || true
wait "$fake_pid" 2>/dev/null || true
make_socket
if PATH="$BIN:/usr/bin:/bin" DOCKERD_PIDFILE="$pidfile_only" PGREP_DOCKERD_MARKER="$TMP/no-dockerd" \
  /bin/bash -c 'source "$1"; box_upkeep_dockerd_running' _ "$ROOT/docker/lib.sh"; then
  echo "FAIL a dead pid in the pidfile was reported up"
  exit 1
fi
printf '%s\n' "$$" > "$pidfile_only"
if PATH="$BIN:/usr/bin:/bin" DOCKERD_PIDFILE="$pidfile_only" PGREP_DOCKERD_MARKER="$TMP/no-dockerd" \
  /bin/bash -c 'source "$1"; box_upkeep_dockerd_running' _ "$ROOT/docker/lib.sh"; then
  echo "FAIL a pidfile naming a process that is not dockerd was accepted"
  exit 1
fi
rm -f "$pidfile_only" "$DOCKER_SOCK"
echo "ok the dockerd check uses the /run pidfile and the socket"

reset_docker
cp "$STUB" "$BIN/dockerd"
cp "$STUB" "$BIN/docker"
: > "$DOCKERD_PIDFILE"
make_socket
watch_script=$TMP/dockerd-watchdog-test.sh
cat > "$watch_script" << 'EOF'
#!/bin/bash
sleep 180
EOF
chmod +x "$watch_script"
NO_WATCHDOGS=0
out=$(DOCKERD_WATCHDOG="$watch_script" run_ensure)
if ! printf '%s\n' "$out" | grep -q 'watchdog: starting dockerd keep-alive'; then
  echo "FAIL dockerd watchdog was not started"
  printf '%s\n' "$out"
  exit 1
fi
# shellcheck source=../docker/lib.sh
source "$ROOT/docker/lib.sh"
watch_pid=$(box_upkeep_watchdog_running "$(realpath "$watch_script")" || true)
if [[ -z "$watch_pid" ]]; then
  echo "FAIL dockerd watchdog process was not found"
  exit 1
fi
kill "$watch_pid" 2>/dev/null || true
watch_script=
echo "ok the dockerd watchdog starts when --no-watchdogs is absent"

# --- up.sh wiring ---

ACCESS_LOG=$TMP/access.log
AOS_LOG=$TMP/aos.log
DOCKER_STUB_LOG=$TMP/docker-stub.log
mkdir -p "$TMP/tools"
cat > "$TMP/tools/java" << 'EOF'
#!/bin/bash
exit 0
EOF
cp "$TMP/tools/java" "$TMP/tools/javac"
cp "$TMP/tools/java" "$TMP/tools/mvn"
cat > "$TMP/tools/gh" << 'EOF'
#!/bin/bash
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  printf '%s\n' 'n-huche'
fi
exit 0
EOF
cat > "$TMP/access-up.sh" << 'EOF'
#!/bin/bash
printf 'invoked %s\n' "$*" >> "$ACCESS_LOG"
exit "${ACCESS_RC:-0}"
EOF
cat > "$TMP/aos-up.sh" << 'EOF'
#!/bin/bash
printf 'invoked %s\n' "$*" >> "$AOS_LOG"
exit "${AOS_RC:-0}"
EOF
cat > "$TMP/dockerd-ensure.sh" << 'EOF'
#!/bin/bash
printf 'no_watchdogs=%s\n' "${NO_WATCHDOGS:-}" >> "$DOCKER_STUB_LOG"
printf '%s\n' 'dockerd: present'
exit "${DOCKER_RC:-0}"
EOF
chmod +x "$TMP/tools/java" "$TMP/tools/javac" "$TMP/tools/mvn" "$TMP/tools/gh" \
  "$TMP/access-up.sh" "$TMP/aos-up.sh" "$TMP/dockerd-ensure.sh"

ACCESS_RC=0
AOS_RC=0
DOCKER_RC=0

run_up() {
  PATH="$TMP/tools:$PATH" HOME_BOX="$TMP/home" \
    ACCESS_RC="$ACCESS_RC" AOS_RC="$AOS_RC" DOCKER_RC="$DOCKER_RC" \
    BOX_ACCESS_UP="$TMP/access-up.sh" AOS_UP="$TMP/aos-up.sh" \
    TICKETS_CLI=/bin/true DOCKERD_ENSURE="${DOCKERD_ENSURE:-$TMP/dockerd-ensure.sh}" \
    PYTHON_VENVS_ENSURE=/bin/true PERMS_ENSURE=/bin/true DOCKER_STUB_LOG="$DOCKER_STUB_LOG" \
    RUN_ENSURE=/bin/true \
    ACCESS_LOG="$ACCESS_LOG" AOS_LOG="$AOS_LOG" \
    /bin/bash "$ROOT/up.sh" "$@"
}

reset_logs() {
  rm -f "$ACCESS_LOG" "$AOS_LOG" "$DOCKER_STUB_LOG"
}

reset_logs
out=$(run_up)
gh_line=$(printf '%s\n' "$out" | grep -n '^gh:' | head -n1 | cut -d: -f1)
docker_line=$(printf '%s\n' "$out" | grep -n '^dockerd:' | head -n1 | cut -d: -f1)
if (( gh_line >= docker_line )); then
  echo "FAIL dockerd did not run after gh"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'dockerd: present'; then
  echo "FAIL up.sh did not report dockerd"
  printf '%s\n' "$out"
  exit 1
fi
if [[ "$(cat "$DOCKER_STUB_LOG")" != "no_watchdogs=0" ]]; then
  echo "FAIL up.sh did not pass NO_WATCHDOGS=0: $(cat "$DOCKER_STUB_LOG")"
  exit 1
fi
echo "ok up.sh runs dockerd after gh"

reset_logs
run_up --no-watchdogs >/dev/null
if [[ "$(cat "$DOCKER_STUB_LOG")" != "no_watchdogs=1" ]]; then
  echo "FAIL --no-watchdogs was not passed to dockerd: $(cat "$DOCKER_STUB_LOG")"
  exit 1
fi
echo "ok --no-watchdogs still runs the dockerd step once"

reset_logs
DOCKER_RC=8
set +e
out=$(run_up 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 8 ]]; then
  echo "FAIL dockerd failure status was $rc, want 8"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: failed access=0 aos=0 jdk=0 maven=0 gh=0 docker=8 python=0 perms=0 run=0'; then
  echo "FAIL dockerd failure summary missing"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok a dockerd failure is reported and fails up.sh"

reset_logs
ACCESS_RC=4
DOCKER_RC=0
set +e
out=$(run_up --stop-on-error 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 4 ]]; then
  echo "FAIL stop-on-error status was $rc"
  printf '%s\n' "$out"
  exit 1
fi
if [[ -e "$DOCKER_STUB_LOG" ]]; then
  echo "FAIL stop-on-error still ran dockerd"
  exit 1
fi
echo "ok --stop-on-error returns before dockerd"

reset_logs
ACCESS_RC=0
set +e
out=$(TICKETS_CLI=/bin/true DOCKERD_ENSURE="$TMP/missing-dockerd.sh" \
  PYTHON_VENVS_ENSURE=/bin/true PERMS_ENSURE=/bin/true run_up 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 127 ]]; then
  echo "FAIL missing dockerd script status was $rc"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'dockerd entry not executable'; then
  echo "FAIL missing dockerd script was not reported"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok a missing dockerd script is status 127"

help=$(run_up --help)
if ! printf '%s\n' "$help" | grep -q 'DOCKER_PACKAGE'; then
  echo "FAIL up.sh --help missing DOCKER_PACKAGE"
  exit 1
fi
if ! printf '%s\n' "$help" | grep -q 'docker.io'; then
  echo "FAIL up.sh --help missing docker.io"
  exit 1
fi
echo "ok up.sh --help mentions the docker package"
