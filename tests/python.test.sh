#!/usr/bin/env bash
# python/ensure-venvs.sh: healthy skip, recreate, sibling preservation, failure.
# Fake python3/pip on PATH. No network. Never touches /home/box.
set -euo pipefail

ROOT=$(realpath "$(dirname "$0")/..")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$ROOT/python/ensure-venvs.sh" ]]; then
  echo "FAIL python/ensure-venvs.sh is not executable"
  exit 1
fi
if ! grep -q 'set -euo pipefail' "$ROOT/python/ensure-venvs.sh"; then
  echo "FAIL python/ensure-venvs.sh missing set -euo pipefail"
  exit 1
fi
if [[ ! -f "$ROOT/python/venvs.txt" ]]; then
  echo "FAIL python/venvs.txt is missing"
  exit 1
fi
if ! grep -q '/home/box/.config/youtube-coding/venv' "$ROOT/python/venvs.txt"; then
  echo "FAIL python/venvs.txt missing youtube-coding entry"
  exit 1
fi
if ! grep -q 'google-auth-oauthlib' "$ROOT/python/venvs.txt"; then
  echo "FAIL python/venvs.txt missing google-auth-oauthlib"
  exit 1
fi
if ! grep -q 'google-api-python-client' "$ROOT/python/venvs.txt"; then
  echo "FAIL python/venvs.txt missing google-api-python-client"
  exit 1
fi

ens=$(env -u PYTHON_VENVS_ENSURE bash -c 'source "$1"; printf %s "$PYTHON_VENVS_ENSURE"' _ "$ROOT/lib/common.sh")
if [[ "$ens" != "$ROOT/python/ensure-venvs.sh" ]]; then
  echo "FAIL PYTHON_VENVS_ENSURE default was $ens"
  exit 1
fi
lst=$(env -u PYTHON_VENVS_LIST bash -c 'source "$1"; printf %s "$PYTHON_VENVS_LIST"' _ "$ROOT/lib/common.sh")
if [[ "$lst" != "$ROOT/python/venvs.txt" ]]; then
  echo "FAIL PYTHON_VENVS_LIST default was $lst"
  exit 1
fi
echo "ok python scripts and defaults"

BIN=$TMP/bin
mkdir -p "$BIN"
SUDO_LOG=$TMP/sudo.log
VENV_CREATE_LOG=$TMP/venv-create.log
PIP_INSTALL_RC=0
export SUDO_LOG VENV_CREATE_LOG PIP_INSTALL_RC

cat > "$BIN/sudo" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SUDO_LOG"
echo "FAIL sudo/apt should not run in python.test.sh" >&2
exit 1
EOF
chmod +x "$BIN/sudo"

# Fake python3: supports import venv and `python3 -m venv --clear <path>`.
# Creates a stub venv with bin/python and bin/pip; no real packages, no network.
cat > "$BIN/python3" << 'EOF'
#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == "-c" && "${2:-}" == "import venv" ]]; then
  exit 0
fi
if [[ "${1:-}" == "-m" && "${2:-}" == "venv" ]]; then
  clear=0
  path=
  shift 2
  for arg in "$@"; do
    if [[ "$arg" == "--clear" ]]; then
      clear=1
      continue
    fi
    path=$arg
  done
  if [[ "$clear" -ne 1 || -z "$path" ]]; then
    echo "FAIL fake python3: expected -m venv --clear <path>" >&2
    exit 1
  fi
  printf '%s\n' "$path" >> "$VENV_CREATE_LOG"
  rm -rf "$path"
  mkdir -p "$path/bin"
  : > "$path/.pkgs"
  cat > "$path/bin/python" << 'PY'
#!/bin/bash
if [[ "${1:-}" == "-c" && "${2:-}" == "import sys" ]]; then
  exit 0
fi
exit 1
PY
  cat > "$path/bin/pip" << 'PIP'
#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
pkgs="$here/.pkgs"
case "${1:-}" in
  show)
    grep -qx "${2:-}" "$pkgs" 2>/dev/null
    ;;
  install)
    if [[ "${PIP_INSTALL_RC:-0}" -ne 0 ]]; then
      exit "$PIP_INSTALL_RC"
    fi
    shift
    for pkg in "$@"; do
      printf '%s\n' "$pkg" >> "$pkgs"
    done
    ;;
  *)
    exit 1
    ;;
esac
PIP
  chmod +x "$path/bin/python" "$path/bin/pip"
  exit 0
fi
echo "FAIL fake python3: unexpected args: $*" >&2
exit 1
EOF
chmod +x "$BIN/python3"

make_healthy_venv() {
  local path=$1
  shift
  mkdir -p "$path/bin"
  : > "$path/.pkgs"
  for pkg in "$@"; do
    printf '%s\n' "$pkg" >> "$path/.pkgs"
  done
  cat > "$path/bin/python" << 'PY'
#!/bin/bash
if [[ "${1:-}" == "-c" && "${2:-}" == "import sys" ]]; then
  exit 0
fi
exit 1
PY
  cat > "$path/bin/pip" << 'PIP'
#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
pkgs="$here/.pkgs"
case "${1:-}" in
  show)
    grep -qx "${2:-}" "$pkgs" 2>/dev/null
    ;;
  *)
    exit 1
    ;;
esac
PIP
  chmod +x "$path/bin/python" "$path/bin/pip"
  # Sentinel that recreate would destroy (rm -rf the venv dir).
  printf 'sentinel-bytes\n' > "$path/DO_NOT_TOUCH"
}

run_ensure() {
  PATH="$BIN:$PATH" PYTHON_VENVS_LIST="$1" \
    /bin/bash "$ROOT/python/ensure-venvs.sh"
}

# --- healthy venv is left alone ---
PARENT=$TMP/cfg-healthy
VENV=$PARENT/venv
LIST=$TMP/list-healthy.txt
mkdir -p "$PARENT"
make_healthy_venv "$VENV" pkg-a pkg-b
printf 'keep-me\n' > "$PARENT/client_secret.json"
chmod 600 "$PARENT/client_secret.json"
secret_before=$(/bin/cksum "$PARENT/client_secret.json")
mode_before=$(stat -c '%a' "$PARENT/client_secret.json")
printf '%s\n' "$VENV pkg-a pkg-b" > "$LIST"
: > "$VENV_CREATE_LOG"
: > "$SUDO_LOG"
set +e
out=$(run_ensure "$LIST" 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL healthy path status $rc"
  printf '%s\n' "$out"
  cat "$TMP/err"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx "venv: present $VENV"; then
  echo "FAIL healthy path did not report present"
  printf '%s\n' "$out"
  exit 1
fi
if [[ -s "$VENV_CREATE_LOG" ]]; then
  echo "FAIL healthy path recreated the venv"
  cat "$VENV_CREATE_LOG"
  exit 1
fi
if [[ ! -f "$VENV/DO_NOT_TOUCH" ]] || [[ "$(cat "$VENV/DO_NOT_TOUCH")" != "sentinel-bytes" ]]; then
  echo "FAIL healthy path altered the venv contents"
  exit 1
fi
if [[ "$(/bin/cksum "$PARENT/client_secret.json")" != "$secret_before" ]]; then
  echo "FAIL healthy path altered sibling secret"
  exit 1
fi
if [[ -s "$SUDO_LOG" ]]; then
  echo "FAIL healthy path invoked sudo"
  cat "$SUDO_LOG"
  exit 1
fi
echo "ok healthy venv is left alone"

# --- missing venv is recreated; sibling secret preserved ---
PARENT=$TMP/cfg-missing
VENV=$PARENT/venv
LIST=$TMP/list-missing.txt
mkdir -p "$PARENT"
printf 'secret-payload-xyz\n' > "$PARENT/client_secret.json"
chmod 640 "$PARENT/client_secret.json"
printf 'token-payload\n' > "$PARENT/token.json"
chmod 600 "$PARENT/token.json"
secret_before=$(/bin/cksum "$PARENT/client_secret.json")
secret_mode=$(stat -c '%a' "$PARENT/client_secret.json")
token_before=$(/bin/cksum "$PARENT/token.json")
token_mode=$(stat -c '%a' "$PARENT/token.json")
printf '%s\n' "$VENV google-auth-oauthlib google-api-python-client" > "$LIST"
: > "$VENV_CREATE_LOG"
: > "$SUDO_LOG"
set +e
out=$(run_ensure "$LIST" 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL missing path status $rc"
  printf '%s\n' "$out"
  cat "$TMP/err"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx "venv: recreate $VENV"; then
  echo "FAIL missing path did not recreate"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx "venv: installed $VENV"; then
  echo "FAIL missing path did not report installed"
  printf '%s\n' "$out"
  exit 1
fi
if [[ "$(cat "$VENV_CREATE_LOG")" != "$VENV" ]]; then
  echo "FAIL venv create log: $(cat "$VENV_CREATE_LOG")"
  exit 1
fi
if ! grep -qx 'google-auth-oauthlib' "$VENV/.pkgs"; then
  echo "FAIL missing google-auth-oauthlib in installed pkgs"
  cat "$VENV/.pkgs"
  exit 1
fi
if ! grep -qx 'google-api-python-client' "$VENV/.pkgs"; then
  echo "FAIL missing google-api-python-client in installed pkgs"
  cat "$VENV/.pkgs"
  exit 1
fi
if [[ "$(/bin/cksum "$PARENT/client_secret.json")" != "$secret_before" ]]; then
  echo "FAIL recreate altered client_secret.json bytes"
  exit 1
fi
if [[ "$(stat -c '%a' "$PARENT/client_secret.json")" != "$secret_mode" ]]; then
  echo "FAIL recreate altered client_secret.json mode"
  exit 1
fi
if [[ "$(/bin/cksum "$PARENT/token.json")" != "$token_before" ]]; then
  echo "FAIL recreate altered token.json bytes"
  exit 1
fi
if [[ "$(stat -c '%a' "$PARENT/token.json")" != "$token_mode" ]]; then
  echo "FAIL recreate altered token.json mode"
  exit 1
fi
if [[ -s "$SUDO_LOG" ]]; then
  echo "FAIL missing path invoked sudo"
  cat "$SUDO_LOG"
  exit 1
fi
# Idempotent second run
: > "$VENV_CREATE_LOG"
set +e
out=$(run_ensure "$LIST" 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]] || [[ -s "$VENV_CREATE_LOG" ]]; then
  echo "FAIL second run was not a no-op"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx "venv: present $VENV"; then
  echo "FAIL second run did not report present"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok missing venv is recreated; siblings preserved"

# --- parent created mode 700 when missing ---
PARENT=$TMP/new-parent
VENV=$PARENT/venv
LIST=$TMP/list-parent.txt
printf '%s\n' "$VENV only-pkg" > "$LIST"
: > "$VENV_CREATE_LOG"
set +e
out=$(run_ensure "$LIST" 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL parent-create status $rc"
  printf '%s\n' "$out"
  cat "$TMP/err"
  exit 1
fi
if [[ "$(stat -c '%a' "$PARENT")" != "700" ]]; then
  echo "FAIL parent mode was $(stat -c '%a' "$PARENT"), want 700"
  exit 1
fi
echo "ok parent dir is created mode 700"

# --- failure exits non-zero ---
PARENT=$TMP/cfg-fail
VENV=$PARENT/venv
LIST=$TMP/list-fail.txt
mkdir -p "$PARENT"
printf '%s\n' "$VENV boom-pkg" > "$LIST"
: > "$VENV_CREATE_LOG"
PIP_INSTALL_RC=7
set +e
out=$(run_ensure "$LIST" 2>"$TMP/err")
rc=$?
set -e
PIP_INSTALL_RC=0
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL pip install failure was accepted"
  printf '%s\n' "$out"
  exit 1
fi
if ! grep -q 'pip install failed' "$TMP/err"; then
  echo "FAIL pip install failure was not reported"
  cat "$TMP/err"
  exit 1
fi
echo "ok a recreate failure exits non-zero"

# --- missing list file fails ---
set +e
out=$(PATH="$BIN:$PATH" PYTHON_VENVS_LIST="$TMP/no-such-list.txt" \
  /bin/bash "$ROOT/python/ensure-venvs.sh" 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL missing list was accepted"
  exit 1
fi
if ! grep -q 'venvs list not found' "$TMP/err"; then
  echo "FAIL missing list was not reported"
  cat "$TMP/err"
  exit 1
fi
echo "ok missing list exits non-zero"

# Never touched the real home.
if [[ -e /home/box/.config/youtube-coding/venv/.pkgs ]] && \
   grep -q 'fake-test' /home/box/.config/youtube-coding/venv/.pkgs 2>/dev/null; then
  echo "FAIL test wrote into /home/box"
  exit 1
fi
echo "ok python ensure-venvs"
