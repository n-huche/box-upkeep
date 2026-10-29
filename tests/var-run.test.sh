#!/usr/bin/env bash
# run/ensure-run.sh on a fake tree: /var/run as a directory, as a symlink,
# missing, or pointing elsewhere; a dockerd holding the old socket.
# sudo and pgrep are mocks. Nothing outside $TMP is touched.
set -euo pipefail

ROOT=$(realpath "$(dirname "$0")/..")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL $*"
  exit 1
}

if [[ ! -x "$ROOT/run/ensure-run.sh" ]]; then
  fail "run/ensure-run.sh is not executable"
fi
grep -q 'set -euo pipefail' "$ROOT/run/ensure-run.sh" || fail "run/ensure-run.sh missing set -euo pipefail"

BIN=$TMP/bin
SUDO_LOG=$TMP/sudo.log
DOCKERD_MARK=$TMP/dockerd.running
export SUDO_LOG DOCKERD_MARK
mkdir -p "$BIN"
cat > "$BIN/sudo" << 'EOF2'
#!/bin/bash
printf '%s\n' "$*" >> "$SUDO_LOG"
if [[ "${1:-}" == "kill" ]]; then
  if [[ -z "${DOCKERD_IGNORES_TERM:-}" ]]; then
    rm -f "$DOCKERD_MARK"
  fi
  exit 0
fi
exec "$@"
EOF2
cat > "$BIN/pgrep" << 'EOF2'
#!/bin/bash
if [[ "${1:-}" == "-x" && "${2:-}" == "dockerd" && -f "$DOCKERD_MARK" ]]; then
  echo 4242
  exit 0
fi
exit 1
EOF2
chmod +x "$BIN/sudo" "$BIN/pgrep"

run_fix() {
  PATH="$BIN:/usr/bin:/bin" \
    VAR_RUN="$TMP/var/run" RUN_DIR="$TMP/run" \
    RUN_DOCKERD_STOP_WAIT=2 \
    /bin/bash "$ROOT/run/ensure-run.sh"
}

reset_tree() {
  rm -rf "${TMP:?}/var" "${TMP:?}/run" "$SUDO_LOG" "$DOCKERD_MARK"
  mkdir -p "$TMP/var" "$TMP/run"
}

make_socket() {
  /usr/bin/python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' "$1"
}

today=$(date +%Y%m%d)

# 1. Already a symlink: one-line no-op, nothing moved or created.
reset_tree
ln -s "$TMP/run" "$TMP/var/run"
out=$(run_fix)
printf '%s\n' "$out" | grep -qx "var-run: ok ($TMP/var/run -> $TMP/run)" || fail "symlink was not a no-op: $out"
if grep -qE '^(mv|ln|kill) ' "$SUDO_LOG"; then
  fail "no-op run changed something: $(cat "$SUDO_LOG")"
fi
[[ -z "$(find "$TMP/var" -maxdepth 1 -name 'run.pre-symlink-*')" ]] || fail "no-op run created a backup"
echo "ok /var/run already a symlink to /run is a no-op"

# 2. Real directory: entries merged into /run without overwriting, the old
# directory renamed (not deleted), symlink created.
reset_tree
mkdir -p "$TMP/var/run/somed" "$TMP/var/run/lock"
chmod 700 "$TMP/var/run"
printf 'old\n' > "$TMP/var/run/only-old.pid"
printf 'old\n' > "$TMP/var/run/both.pid"
printf 'new\n' > "$TMP/run/both.pid"
mkdir -p "$TMP/run/lock"
make_socket "$TMP/var/run/stale.sock"
out=$(run_fix)
[[ -L "$TMP/var/run" ]] || fail "/var/run is not a symlink after the fix: $out"
[[ "$(realpath "$TMP/var/run")" == "$(realpath "$TMP/run")" ]] || fail "/var/run does not resolve to /run"
backup=$TMP/var/run.pre-symlink-$today
[[ -d "$backup" ]] || fail "old directory was not renamed to $backup: $out"
[[ "$(cat "$TMP/run/only-old.pid")" == old ]] || fail "only-old.pid was not moved to /run"
[[ -d "$TMP/run/somed" ]] || fail "somed/ was not moved to /run"
[[ "$(cat "$TMP/run/both.pid")" == new ]] || fail "an existing /run entry was overwritten"
[[ "$(cat "$backup/both.pid")" == old ]] || fail "the conflicting entry was not kept in the backup"
[[ -d "$backup/lock" ]] || fail "the conflicting lock/ was not kept in the backup"
[[ -S "$backup/stale.sock" && ! -e "$TMP/run/stale.sock" ]] || fail "a socket was moved"
printf '%s\n' "$out" | grep -q "renamed the old directory to $backup (nothing deleted)" || fail "rename not logged: $out"
printf '%s\n' "$out" | grep -q "kept both.pid in the old directory" || fail "conflict not logged: $out"
echo "ok a /var/run directory is merged, renamed, and replaced by a symlink"

# 3. Second run on the fixed tree is a no-op.
: > "$SUDO_LOG"
out=$(run_fix)
printf '%s\n' "$out" | grep -qx "var-run: ok ($TMP/var/run -> $TMP/run)" || fail "second run was not a no-op: $out"
if grep -qE '^(mv|ln) ' "$SUDO_LOG"; then
  fail "second run changed something: $(cat "$SUDO_LOG")"
fi
echo "ok the fix is idempotent"

# 4. A backup name already taken: a second name is used, nothing overwritten.
rm "$TMP/var/run"
mkdir "$TMP/var/run"
printf 'x\n' > "$TMP/var/run/again.pid"
out=$(run_fix)
[[ -L "$TMP/var/run" ]] || fail "second fix did not create the symlink: $out"
[[ -f "$backup/both.pid" ]] || fail "the first backup was touched"
[[ "$(find "$TMP/var" -maxdepth 1 -name "run.pre-symlink-${today}-*" | wc -l)" -eq 1 ]] || fail "no second backup name: $out"
echo "ok an existing backup is not overwritten"

# 5. Missing /var/run: symlink created.
reset_tree
out=$(run_fix)
[[ -L "$TMP/var/run" ]] || fail "missing /var/run was not created as a symlink: $out"
echo "ok a missing /var/run becomes a symlink"

# 6. Symlink somewhere else: reported, left alone, non-zero.
reset_tree
mkdir -p "$TMP/elsewhere"
ln -s "$TMP/elsewhere" "$TMP/var/run"
set +e
out=$(run_fix 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "a symlink elsewhere was accepted"
[[ "$(readlink "$TMP/var/run")" == "$TMP/elsewhere" ]] || fail "a symlink elsewhere was changed"
printf '%s\n' "$out" | grep -q "not $TMP/run; left as is" || fail "symlink elsewhere not reported: $out"
echo "ok a /var/run symlink elsewhere is reported and left alone"

# 7. dockerd holding a socket in the real directory is stopped first.
reset_tree
mkdir -p "$TMP/var/run"
make_socket "$TMP/var/run/docker.sock"
printf '4242\n' > "$TMP/var/run/docker.pid"
: > "$DOCKERD_MARK"
out=$(run_fix)
grep -qx 'kill 4242' "$SUDO_LOG" || fail "dockerd was not stopped: $(cat "$SUDO_LOG")"
printf '%s\n' "$out" | grep -q 'stopping dockerd' || fail "dockerd stop not logged: $out"
[[ -L "$TMP/var/run" ]] || fail "symlink not created after stopping dockerd"
[[ -f "$TMP/run/docker.pid" ]] || fail "docker.pid was not moved"
echo "ok a dockerd on the old /var/run is stopped before the move"

# 8. dockerd that does not exit: directory left as is, non-zero.
reset_tree
mkdir -p "$TMP/var/run"
make_socket "$TMP/var/run/docker.sock"
: > "$DOCKERD_MARK"
set +e
out=$(DOCKERD_IGNORES_TERM=1 run_fix 2>&1)
rc=$?
set -e
[[ "$rc" -ne 0 ]] || fail "a dockerd that did not exit was accepted"
[[ -d "$TMP/var/run" && ! -L "$TMP/var/run" ]] || fail "/var/run changed while dockerd was still up"
printf '%s\n' "$out" | grep -q 'dockerd did not exit' || fail "stuck dockerd not reported: $out"
echo "ok a dockerd that does not exit leaves /var/run untouched"

# 9. up.sh runs the run step first, before the gate, and reports its failure.
mkdir -p "$TMP/tools" "$TMP/home"
for t in java javac mvn; do
  printf '#!/bin/bash\nexit 0\n' > "$TMP/tools/$t"
done
printf '#!/bin/bash\nif [[ "${1:-}" == auth && "${2:-}" == status ]]; then echo n-huche; fi\nexit 0\n' > "$TMP/tools/gh"
ORDER=$TMP/order.log
export ORDER
printf '#!/bin/bash\necho run >> "$ORDER"\nexit "${RUN_RC:-0}"\n' > "$TMP/run-ensure.sh"
printf '#!/bin/bash\necho access >> "$ORDER"\nexit 0\n' > "$TMP/access-up.sh"
printf '#!/bin/bash\necho aos >> "$ORDER"\nexit 0\n' > "$TMP/aos-up.sh"
printf '#!/bin/bash\necho docker >> "$ORDER"\nexit 0\n' > "$TMP/dockerd-ensure.sh"
chmod +x "$TMP"/tools/* "$TMP/run-ensure.sh" "$TMP/access-up.sh" "$TMP/aos-up.sh" "$TMP/dockerd-ensure.sh"
run_up() {
  PATH="$TMP/tools:$PATH" HOME_BOX="$TMP/home" \
    RUN_ENSURE="$TMP/run-ensure.sh" BOX_ACCESS_UP="$TMP/access-up.sh" AOS_UP="$TMP/aos-up.sh" \
    TICKETS_CLI=/bin/true DOCKERD_ENSURE="$TMP/dockerd-ensure.sh" \
    PYTHON_VENVS_ENSURE=/bin/true PERMS_ENSURE=/bin/true \
    /bin/bash "$ROOT/up.sh" "$@"
}
rm -f "$ORDER"
run_up >/dev/null
[[ "$(tr '\n' ' ' < "$ORDER")" == "run access aos docker " ]] || fail "up.sh order was $(tr '\n' ' ' < "$ORDER")"
rm -f "$ORDER"
run_up --aos-only >/dev/null
[[ "$(head -n1 "$ORDER")" == run ]] || fail "--aos-only skipped the run step"
rm -f "$ORDER"
set +e
out=$(RUN_RC=5 run_up 2>&1)
rc=$?
set -e
[[ "$rc" -eq 5 ]] || fail "run step failure status was $rc, want 5"
printf '%s\n' "$out" | grep -q 'up: failed access=0 aos=0 jdk=0 maven=0 gh=0 docker=0 python=0 perms=0 run=5' || fail "run failure summary missing: $out"
[[ "$(tr '\n' ' ' < "$ORDER")" == "run access aos docker " ]] || fail "a run failure stopped the other sides"
set +e
out=$(RUN_ENSURE="$TMP/missing.sh" PATH="$TMP/tools:$PATH" HOME_BOX="$TMP/home" \
  BOX_ACCESS_UP="$TMP/access-up.sh" AOS_UP="$TMP/aos-up.sh" TICKETS_CLI=/bin/true \
  DOCKERD_ENSURE="$TMP/dockerd-ensure.sh" PYTHON_VENVS_ENSURE=/bin/true \
  PERMS_ENSURE=/bin/true \
  /bin/bash "$ROOT/up.sh" 2>&1)
rc=$?
set -e
[[ "$rc" -eq 127 ]] || fail "missing run entry status was $rc"
def=$(env -u RUN_ENSURE bash -c 'source "$1"; printf %s "$RUN_ENSURE"' _ "$ROOT/lib/common.sh")
[[ "$def" == "$ROOT/run/ensure-run.sh" ]] || fail "RUN_ENSURE default was $def"
echo "ok up.sh runs the run step first and reports its failure"
