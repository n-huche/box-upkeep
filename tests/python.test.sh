#!/usr/bin/env bash
# python/ensure-venvs.sh: healthy skip, recreate, sibling preservation, failure,
# and -r requirements-file lines. Fake python3/pip on PATH. No network.
# Never touches /home/box or /workspace/tickets.
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
if ! grep -qE '^/workspace/tickets/\.venv[[:space:]]+-r[[:space:]]+/workspace/tickets/requirements\.txt[[:space:]]*$' \
  "$ROOT/python/venvs.txt"; then
  echo "FAIL python/venvs.txt missing tickets -r entry"
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
PIP_INSTALL_LOG=$TMP/pip-install.log
PIP_INSTALL_RC=0
export SUDO_LOG VENV_CREATE_LOG PIP_INSTALL_LOG PIP_INSTALL_RC

cat > "$BIN/sudo" << 'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SUDO_LOG"
echo "FAIL sudo/apt should not run in python.test.sh" >&2
exit 1
EOF
chmod +x "$BIN/sudo"

# Shared body for fake pip (created into each stub venv).
# install supports loose packages and `install -r <file>` (names only, no network).
FAKE_PIP_BODY=$TMP/fake-pip-body.sh
cat > "$FAKE_PIP_BODY" << 'PIP'
#!/bin/bash
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
pkgs="$here/.pkgs"
fake_req_name() {
  local line=$1
  line=${line%%#*}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  [[ -z "$line" ]] && return 0
  [[ "$line" == -* ]] && return 0
  line=${line%%;*}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  [[ -z "$line" ]] && return 0
  if [[ "$line" == *"["* ]]; then
    line="${line%%\[*}"
  fi
  line=${line%"${line##*[![:space:]]}"}
  line=$(printf '%s\n' "$line" | sed -E 's/[[:space:]]*(==|>=|<=|~=|!=|<|>).*//')
  line=${line%"${line##*[![:space:]]}"}
  [[ -n "$line" ]] && printf '%s\n' "$line"
}
case "${1:-}" in
  show)
    grep -qx "${2:-}" "$pkgs" 2>/dev/null
    ;;
  install)
    if [[ -n "${PIP_INSTALL_LOG:-}" ]]; then
      printf '%s\n' "$*" >> "$PIP_INSTALL_LOG"
    fi
    if [[ "${PIP_INSTALL_RC:-0}" -ne 0 ]]; then
      exit "$PIP_INSTALL_RC"
    fi
    shift
    while [[ "$#" -gt 0 ]]; do
      if [[ "$1" == "-r" ]]; then
        shift
        reqf=${1:-}
        if [[ -z "$reqf" || ! -f "$reqf" ]]; then
          exit 1
        fi
        while IFS= read -r rline || [[ -n "$rline" ]]; do
          name=$(fake_req_name "$rline")
          [[ -n "$name" ]] && printf '%s\n' "$name" >> "$pkgs"
        done < "$reqf"
      else
        printf '%s\n' "$1" >> "$pkgs"
      fi
      shift
    done
    ;;
  *)
    exit 1
    ;;
esac
PIP

# Fake python3: supports import venv and `python3 -m venv --clear <path>`.
# Creates a stub venv with bin/python and bin/pip; no real packages, no network.
# Copies FAKE_PIP_BODY into each new venv's bin/pip.
export FAKE_PIP_BODY
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
  cp "$FAKE_PIP_BODY" "$path/bin/pip"
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
  cp "$FAKE_PIP_BODY" "$path/bin/pip"
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

# --- healthy -r venv is left alone ---
PARENT=$TMP/cfg-req-healthy
VENV=$PARENT/venv
LIST=$TMP/list-req-healthy.txt
REQ=$TMP/reqs-healthy.txt
mkdir -p "$PARENT"
cat > "$REQ" << 'REQS'
# comment
pkg-a==1.2.3
pkg-b[extra]>=2.0; python_version >= "3.10"
pkg-c~=3.0
REQS
make_healthy_venv "$VENV" pkg-a pkg-b pkg-c
printf 'keep-me\n' > "$PARENT/sibling.env"
chmod 600 "$PARENT/sibling.env"
sibling_before=$(/bin/cksum "$PARENT/sibling.env")
printf '%s\n' "$VENV -r $REQ" > "$LIST"
: > "$VENV_CREATE_LOG"
: > "$SUDO_LOG"
: > "$PIP_INSTALL_LOG"
set +e
out=$(run_ensure "$LIST" 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL healthy -r status $rc"
  printf '%s\n' "$out"
  cat "$TMP/err"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx "venv: present $VENV"; then
  echo "FAIL healthy -r did not report present"
  printf '%s\n' "$out"
  exit 1
fi
if [[ -s "$VENV_CREATE_LOG" ]]; then
  echo "FAIL healthy -r recreated the venv"
  cat "$VENV_CREATE_LOG"
  exit 1
fi
if [[ -s "$PIP_INSTALL_LOG" ]]; then
  echo "FAIL healthy -r ran pip install"
  cat "$PIP_INSTALL_LOG"
  exit 1
fi
if [[ ! -f "$VENV/DO_NOT_TOUCH" ]] || [[ "$(cat "$VENV/DO_NOT_TOUCH")" != "sentinel-bytes" ]]; then
  echo "FAIL healthy -r altered the venv contents"
  exit 1
fi
if [[ "$(/bin/cksum "$PARENT/sibling.env")" != "$sibling_before" ]]; then
  echo "FAIL healthy -r altered sibling"
  exit 1
fi
echo "ok healthy -r venv is left alone"

# --- -r venv with one missing package is recreated via install -r ---
PARENT=$TMP/cfg-req-missing
VENV=$PARENT/venv
LIST=$TMP/list-req-missing.txt
REQ=$TMP/reqs-missing.txt
mkdir -p "$PARENT"
cat > "$REQ" << 'REQS'
alpha==1.0
beta>=2.0
REQS
# Healthy for alpha only; beta is missing -> recreate.
make_healthy_venv "$VENV" alpha
printf 'token\n' > "$PARENT/token.json"
chmod 600 "$PARENT/token.json"
token_before=$(/bin/cksum "$PARENT/token.json")
token_mode=$(stat -c '%a' "$PARENT/token.json")
printf '%s\n' "$VENV -r $REQ" > "$LIST"
: > "$VENV_CREATE_LOG"
: > "$SUDO_LOG"
: > "$PIP_INSTALL_LOG"
set +e
out=$(run_ensure "$LIST" 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL -r missing-pkg status $rc"
  printf '%s\n' "$out"
  cat "$TMP/err"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx "venv: recreate $VENV"; then
  echo "FAIL -r missing-pkg did not recreate"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx "venv: installed $VENV"; then
  echo "FAIL -r missing-pkg did not report installed"
  printf '%s\n' "$out"
  exit 1
fi
if [[ "$(cat "$VENV_CREATE_LOG")" != "$VENV" ]]; then
  echo "FAIL -r missing-pkg create log: $(cat "$VENV_CREATE_LOG")"
  exit 1
fi
if ! grep -qx "install -r $REQ" "$PIP_INSTALL_LOG"; then
  echo "FAIL -r missing-pkg did not pip install -r"
  cat "$PIP_INSTALL_LOG"
  exit 1
fi
if ! grep -qx 'alpha' "$VENV/.pkgs" || ! grep -qx 'beta' "$VENV/.pkgs"; then
  echo "FAIL -r missing-pkg installed pkgs"
  cat "$VENV/.pkgs"
  exit 1
fi
if [[ -f "$VENV/DO_NOT_TOUCH" ]]; then
  echo "FAIL -r missing-pkg left old sentinel (venv not cleared)"
  exit 1
fi
if [[ "$(/bin/cksum "$PARENT/token.json")" != "$token_before" ]]; then
  echo "FAIL -r missing-pkg altered token.json bytes"
  exit 1
fi
if [[ "$(stat -c '%a' "$PARENT/token.json")" != "$token_mode" ]]; then
  echo "FAIL -r missing-pkg altered token.json mode"
  exit 1
fi
# Idempotent second run
: > "$VENV_CREATE_LOG"
: > "$PIP_INSTALL_LOG"
set +e
out=$(run_ensure "$LIST" 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]] || [[ -s "$VENV_CREATE_LOG" ]] || [[ -s "$PIP_INSTALL_LOG" ]]; then
  echo "FAIL -r second run was not a no-op"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx "venv: present $VENV"; then
  echo "FAIL -r second run did not report present"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok -r venv with missing package recreated via install -r"

# --- missing requirements file fails without touching the venv ---
PARENT=$TMP/cfg-req-absent
VENV=$PARENT/venv
LIST=$TMP/list-req-absent.txt
mkdir -p "$PARENT"
make_healthy_venv "$VENV" leftover-pkg
printf 'sentinel-bytes\n' > "$VENV/DO_NOT_TOUCH"
printf '%s\n' "$VENV -r $TMP/no-such-requirements.txt" > "$LIST"
: > "$VENV_CREATE_LOG"
: > "$SUDO_LOG"
: > "$PIP_INSTALL_LOG"
set +e
out=$(run_ensure "$LIST" 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL missing requirements file was accepted"
  printf '%s\n' "$out"
  exit 1
fi
if ! grep -q 'requirements file not found' "$TMP/err"; then
  echo "FAIL missing requirements file was not reported"
  cat "$TMP/err"
  exit 1
fi
if [[ -s "$VENV_CREATE_LOG" ]]; then
  echo "FAIL missing requirements file recreated the venv"
  cat "$VENV_CREATE_LOG"
  exit 1
fi
if [[ -s "$PIP_INSTALL_LOG" ]]; then
  echo "FAIL missing requirements file ran pip install"
  cat "$PIP_INSTALL_LOG"
  exit 1
fi
if [[ ! -f "$VENV/DO_NOT_TOUCH" ]] || [[ "$(cat "$VENV/DO_NOT_TOUCH")" != "sentinel-bytes" ]]; then
  echo "FAIL missing requirements file altered the venv"
  exit 1
fi
if ! grep -qx 'leftover-pkg' "$VENV/.pkgs"; then
  echo "FAIL missing requirements file altered .pkgs"
  exit 1
fi
echo "ok missing requirements file fails without touching the venv"

# Never touched the real home or tickets tree.
if [[ -e /home/box/.config/youtube-coding/venv/.pkgs ]] && \
   grep -q 'fake-test' /home/box/.config/youtube-coding/venv/.pkgs 2>/dev/null; then
  echo "FAIL test wrote into /home/box"
  exit 1
fi
if [[ -e /workspace/tickets/.venv ]] && \
   [[ -f /workspace/tickets/.venv/DO_NOT_TOUCH ]] && \
   grep -q 'sentinel-bytes' /workspace/tickets/.venv/DO_NOT_TOUCH 2>/dev/null; then
  echo "FAIL test wrote into /workspace/tickets"
  exit 1
fi
# Stronger: our TMP paths only; tickets list entry is never used as PYTHON_VENVS_LIST.
echo "ok python ensure-venvs"
