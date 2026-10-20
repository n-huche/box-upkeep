#!/usr/bin/env bash
# GitHub CLI detection, gh/install-gh.sh, and github.com login.
# Mock apt, curl, and gh. No network. Tokens stay out of stdout, stderr, and xtrace.
set -euo pipefail

ROOT=$(realpath "$(dirname "$0")/..")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$ROOT/gh/install-gh.sh" ]]; then
  echo "FAIL gh/install-gh.sh is not executable"
  exit 1
fi
if ! grep -q 'set -euo pipefail' "$ROOT/gh/install-gh.sh"; then
  echo "FAIL gh/install-gh.sh missing set -euo pipefail"
  exit 1
fi
if grep -q 'gh' "$ROOT/aos/packages.txt"; then
  echo "FAIL gh package belongs in gh/install-gh.sh, not aos/packages.txt"
  exit 1
fi
if grep -q -- '--show-token' "$ROOT/lib/common.sh" "$ROOT/up.sh" "$ROOT/gh/install-gh.sh"; then
  echo "FAIL implementation asks gh to show a token"
  exit 1
fi
if grep -q 'source .*[Ss]ecret' "$ROOT/lib/common.sh" "$ROOT/up.sh" "$ROOT/gh/install-gh.sh"; then
  echo "FAIL secrets file is sourced"
  exit 1
fi
echo "ok gh script is executable and packages.txt stays cronie"

user=$(env -u GH_EXPECTED_USER bash -c 'source "$1"; printf %s "$GH_EXPECTED_USER"' _ "$ROOT/lib/common.sh")
if [[ "$user" != "n-huche" ]]; then
  echo "FAIL default GH_EXPECTED_USER was $user"
  exit 1
fi
inst=$(env -u GH_INSTALL bash -c 'source "$1"; printf %s "$GH_INSTALL"' _ "$ROOT/lib/common.sh")
if [[ "$inst" != "$ROOT/gh/install-gh.sh" ]]; then
  echo "FAIL GH_INSTALL default was $inst"
  exit 1
fi
cfg=$(env -u GH_CONFIG_DIR -u HOME_BOX bash -c 'source "$1"; printf %s "$GH_CONFIG_DIR"' _ "$ROOT/lib/common.sh")
if [[ "$cfg" != "/home/box/.config/gh" ]]; then
  echo "FAIL GH_CONFIG_DIR default was $cfg"
  exit 1
fi
sec=$(env -u BOX_ACCESS_SECRETS -u HOME_BOX bash -c 'source "$1"; printf %s "$BOX_ACCESS_SECRETS"' _ "$ROOT/lib/common.sh")
if [[ "$sec" != "/home/box/.config/box-access/secrets.env" ]]; then
  echo "FAIL BOX_ACCESS_SECRETS default was $sec"
  exit 1
fi
access=$(env -u BOX_ACCESS_UP bash -c 'source "$1"; printf %s "$BOX_ACCESS_UP"' _ "$ROOT/lib/common.sh")
expect="$(dirname "$ROOT")/box-access/up.sh"
if [[ "$access" != "$expect" ]]; then
  echo "FAIL BOX_ACCESS_UP default was $access, want sibling $expect"
  exit 1
fi
user=$(GH_EXPECTED_USER=custom-user bash -c 'source "$1"; printf %s "$GH_EXPECTED_USER"' _ "$ROOT/lib/common.sh")
if [[ "$user" != "custom-user" ]]; then
  echo "FAIL GH_EXPECTED_USER override was $user"
  exit 1
fi
echo "ok gh defaults to n-huche, /home/box/.config/gh, and the box-access secrets file"

# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

HOME_BOX=$TMP/home
GH_CONFIG_DIR=$HOME_BOX/.config/gh
BOX_ACCESS_SECRETS=$HOME_BOX/.config/box-access/secrets.env
export HOME_BOX GH_CONFIG_DIR BOX_ACCESS_SECRETS
unset GH_EXPECTED_USER || true

ok_bin=$TMP/ok-bin
empty_bin=$TMP/empty-bin
bad_bin=$TMP/bad-bin
TOOLS=$TMP/tools
mkdir -p "$ok_bin" "$empty_bin" "$bad_bin" "$TOOLS" "$HOME_BOX"
ln -s /usr/bin/dirname "$TOOLS/dirname"
ln -s /usr/bin/cat "$TOOLS/cat"
cat > "$TMP/stub-ok" << 'EOF'
#!/bin/bash
exit 0
EOF
cat > "$TMP/stub-bad" << 'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$TMP/stub-ok" "$TMP/stub-bad"
cp "$TMP/stub-ok" "$ok_bin/gh"
cp "$TMP/stub-bad" "$bad_bin/gh"
cp "$TMP/stub-ok" "$TOOLS/java"
cp "$TMP/stub-ok" "$TOOLS/javac"
cp "$TMP/stub-ok" "$TOOLS/mvn"
chmod +x "$ok_bin/gh" "$bad_bin/gh" "$TOOLS/java" "$TOOLS/javac" "$TOOLS/mvn"

check_present() {
  local path=$1 expect=$2 rc
  set +e
  PATH="$path:$TOOLS" /bin/bash -c 'source "$1"; box_upkeep_gh_present' _ "$ROOT/lib/common.sh"
  rc=$?
  set -e
  if [[ "$rc" -ne "$expect" ]]; then
    echo "FAIL gh present check path=$path rc=$rc want=$expect"
    exit 1
  fi
}
check_present "$ok_bin" 0
check_present "$empty_bin" 1
check_present "$bad_bin" 1
echo "ok gh --version must run"

BIN=$TMP/apt-bin
APT_LOG=$TMP/apt.log
PKG_LOG=$TMP/pkg.log
CURL_LOG=$TMP/curl.log
FAKE_ROOT=$TMP/root
STUB=$TMP/stub-ok
APT_UPDATE_RC=0
APT_INSTALL_RC=0
APT_LEAVE_MISSING=0
CURL_RC=0
export APT_LOG PKG_LOG CURL_LOG BIN_DIR="$BIN" STUB APT_UPDATE_RC APT_INSTALL_RC APT_LEAVE_MISSING CURL_RC FAKE_ROOT

cat > "$TMP/sudo" << 'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$APT_LOG"
if [[ "${1:-}" == "tee" ]]; then
  dest=$2
  /bin/mkdir -p "$FAKE_ROOT$(dirname "$dest")"
  /bin/cat > "$FAKE_ROOT$dest"
  exit 0
fi
if [[ "${1:-}" == "mkdir" || "${1:-}" == "chmod" ]]; then
  exit 0
fi
for arg in "$@"; do
  if [[ "$arg" == "update" && "$APT_UPDATE_RC" -ne 0 ]]; then
    exit "$APT_UPDATE_RC"
  fi
done
is_install=0
for arg in "$@"; do
  if [[ "$arg" == "install" ]]; then
    is_install=1
  fi
done
if [[ "$is_install" -eq 1 ]]; then
  pkg=
  for arg in "$@"; do
    pkg=$arg
  done
  printf '%s\n' "$pkg" >> "$PKG_LOG"
  if [[ "$APT_INSTALL_RC" -ne 0 ]]; then
    exit "$APT_INSTALL_RC"
  fi
  if [[ "$APT_LEAVE_MISSING" != "1" ]]; then
    /bin/cp "$STUB" "$BIN_DIR/gh"
    /bin/chmod +x "$BIN_DIR/gh"
  fi
fi
exit 0
EOF
cat > "$TMP/curl" << 'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$CURL_LOG"
if [[ "${CURL_RC:-0}" -ne 0 ]]; then
  exit "$CURL_RC"
fi
out=
prev=
for arg in "$@"; do
  if [[ "$prev" == "-o" ]]; then
    out=$arg
  fi
  prev=$arg
done
printf 'keyring-bytes\n' > "$out"
exit 0
EOF
cat > "$TMP/dpkg" << 'EOF'
#!/bin/bash
echo amd64
exit 0
EOF
chmod +x "$TMP/sudo" "$TMP/curl" "$TMP/dpkg"

reset_tooling() {
  rm -rf "$BIN" "$FAKE_ROOT"
  mkdir -p "$BIN" "$FAKE_ROOT"
  cp "$TMP/sudo" "$BIN/sudo"
  cp "$TMP/curl" "$BIN/curl"
  cp "$TMP/dpkg" "$BIN/dpkg"
  chmod +x "$BIN/sudo" "$BIN/curl" "$BIN/dpkg"
  rm -f "$APT_LOG" "$PKG_LOG" "$CURL_LOG"
  APT_UPDATE_RC=0
  APT_INSTALL_RC=0
  APT_LEAVE_MISSING=0
  CURL_RC=0
}

run_install() {
  PATH="$BIN:$TOOLS" /bin/bash "$ROOT/gh/install-gh.sh"
}

reset_tooling
set +e
out=$(run_install 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL install script status $rc"
  printf '%s\n' "$out"
  cat "$TMP/err"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'gh-install: gh'; then
  echo "FAIL install did not announce gh"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'gh: installed gh'; then
  echo "FAIL install did not report success"
  printf '%s\n' "$out"
  exit 1
fi
if ! grep -q 'https://cli.github.com/packages/githubcli-archive-keyring.gpg' "$CURL_LOG"; then
  echo "FAIL keyring URL was not fetched"
  cat "$CURL_LOG"
  exit 1
fi
if ! grep -qx 'mkdir -p -m 755 /etc/apt/keyrings' "$APT_LOG"; then
  echo "FAIL keyring directory was not created"
  cat "$APT_LOG"
  exit 1
fi
if ! grep -qx 'tee /etc/apt/keyrings/githubcli-archive-keyring.gpg' "$APT_LOG"; then
  echo "FAIL keyring was not installed"
  cat "$APT_LOG"
  exit 1
fi
if ! grep -qx 'chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg' "$APT_LOG"; then
  echo "FAIL keyring permissions were not set"
  cat "$APT_LOG"
  exit 1
fi
keyring_file=$FAKE_ROOT/etc/apt/keyrings/githubcli-archive-keyring.gpg
if [[ "$(cat "$keyring_file")" != "keyring-bytes" ]]; then
  echo "FAIL keyring contents were not the downloaded file"
  exit 1
fi
list_file=$FAKE_ROOT/etc/apt/sources.list.d/github-cli.list
want_list='deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main'
if [[ "$(cat "$list_file")" != "$want_list" ]]; then
  echo "FAIL apt source line was wrong"
  cat "$list_file"
  exit 1
fi
if ! grep -qx 'apt-get update -y' "$APT_LOG"; then
  echo "FAIL apt-get update was not invoked"
  cat "$APT_LOG"
  exit 1
fi
if ! grep -qx 'DEBIAN_FRONTEND=noninteractive apt-get install -y gh' "$APT_LOG"; then
  echo "FAIL apt-get install line: $(cat "$APT_LOG")"
  exit 1
fi
if ! grep -qx 'gh' "$PKG_LOG"; then
  echo "FAIL package log: $(cat "$PKG_LOG")"
  exit 1
fi
echo "ok missing gh installs gh from the official apt repo"

lines=$(wc -l < "$APT_LOG")
curl_lines=$(wc -l < "$CURL_LOG")
set +e
out=$(run_install 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 || "$(wc -l < "$APT_LOG")" -ne "$lines" || "$(wc -l < "$CURL_LOG")" -ne "$curl_lines" ]]; then
  echo "FAIL second run did not skip apt"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'gh: present'; then
  echo "FAIL second run did not report gh present"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok a second run skips apt"

reset_tooling
cp "$STUB" "$BIN/gh"
chmod +x "$BIN/gh"
set +e
out=$(run_install 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 || -e "$APT_LOG" || -e "$CURL_LOG" ]]; then
  echo "FAIL present gh still called apt"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'gh: present'; then
  echo "FAIL direct run did not skip quietly"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok direct run skips when gh --version already runs"

reset_tooling
CURL_RC=9
set +e
out=$(run_install 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL keyring download failure was ignored"
  exit 1
fi
if ! grep -q 'failed to download the GitHub CLI keyring' "$TMP/err"; then
  echo "FAIL download error was not reported"
  cat "$TMP/err"
  exit 1
fi
if [[ -e "$BIN/gh" || -e "$FAKE_ROOT/etc/apt/sources.list.d/github-cli.list" ]]; then
  echo "FAIL download failure still installed gh"
  exit 1
fi
echo "ok keyring download failure is reported"

reset_tooling
APT_UPDATE_RC=7
set +e
out=$(run_install 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL apt-get update failure was ignored"
  exit 1
fi
if ! grep -q 'apt-get update failed' "$TMP/err"; then
  echo "FAIL update error was not reported"
  cat "$TMP/err"
  exit 1
fi
if [[ -e "$BIN/gh" ]]; then
  echo "FAIL update failure still produced gh"
  exit 1
fi
echo "ok apt-get update failure is reported"

reset_tooling
APT_INSTALL_RC=8
set +e
out=$(run_install 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL apt-get install failure was ignored"
  exit 1
fi
if ! grep -q 'apt-get install failed for gh' "$TMP/err"; then
  echo "FAIL install error was not reported"
  cat "$TMP/err"
  exit 1
fi
if [[ -e "$BIN/gh" ]]; then
  echo "FAIL install failure still produced gh"
  exit 1
fi
echo "ok apt-get install failure is reported"

reset_tooling
APT_LEAVE_MISSING=1
set +e
out=$(run_install 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL missing gh after install was accepted"
  exit 1
fi
if ! grep -q 'gh --version still does not run' "$TMP/err"; then
  echo "FAIL post-install check was not reported"
  cat "$TMP/err"
  exit 1
fi
echo "ok install that leaves gh missing is an error"

GH_LOG=$TMP/gh.log
GH_ENV_LOG=$TMP/gh-env.log
GH_STDIN=$TMP/gh-stdin
GH_STATE=$TMP/gh-state
FILE_TOKEN='file-sentinel-value'
ENV_TOKEN='env-sentinel-value'
XTRACE_TOKEN='xtrace-sentinel-value'
export GH_LOG GH_ENV_LOG GH_STDIN GH_STATE
unset GH_TOKEN GITHUB_TOKEN GH_LOGIN_RC GH_AFTER_LOGIN || true

cat > "$TMP/gh-auth" << 'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_LOG"
if [[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]]; then
  printf 'env-set\n' >> "$GH_ENV_LOG"
else
  printf 'env-unset\n' >> "$GH_ENV_LOG"
fi
printf 'dir=%s\n' "${GH_CONFIG_DIR-}" >> "$GH_ENV_LOG"
if [[ "${1:-}" == "--version" ]]; then
  exit 0
fi
for arg in "$@"; do
  if [[ "$arg" == "--show-token" || "$arg" == "token" ]]; then
    echo "show-token" >> "$GH_LOG"
    exit 9
  fi
done
if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
  if [[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]]; then
    printf '%s\n' "env-user"
    exit 0
  fi
  if [[ -s "$GH_STATE" ]]; then
    cat "$GH_STATE"
    exit 0
  fi
  echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2
  exit 1
fi
if [[ "${1:-}" == "auth" && "${2:-}" == "login" ]]; then
  cat > "$GH_STDIN"
  if [[ "${GH_LOGIN_RC:-0}" -ne 0 ]]; then
    cat "$GH_STDIN" >&2
    exit "$GH_LOGIN_RC"
  fi
  printf '%s\n' "${GH_AFTER_LOGIN:-n-huche}" > "$GH_STATE"
  exit 0
fi
if [[ "${1:-}" == "auth" && "${2:-}" == "setup-git" ]]; then
  exit "${GH_SETUP_RC:-0}"
fi
exit 1
EOF
chmod +x "$TMP/gh-auth"

AUTH_PATH=$TMP/auth-bin
mkdir -p "$AUTH_PATH"
cp "$TMP/gh-auth" "$AUTH_PATH/gh"
cp "$TMP/stub-ok" "$AUTH_PATH/java"
cp "$TMP/stub-ok" "$AUTH_PATH/javac"
cp "$TMP/stub-ok" "$AUTH_PATH/mvn"
chmod +x "$AUTH_PATH/java" "$AUTH_PATH/javac" "$AUTH_PATH/mvn"

reset_auth() {
  rm -f "$GH_LOG" "$GH_ENV_LOG" "$GH_STDIN" "$GH_STATE" "$TMP/err" "$TMP/out" "$TMP/trace"
  rm -rf "$HOME_BOX"
  mkdir -p "$HOME_BOX"
  unset GH_TOKEN GITHUB_TOKEN GH_EXPECTED_USER || true
  GH_LOGIN_RC=0
  GH_AFTER_LOGIN=n-huche
  GH_SETUP_RC=0
  export GH_LOGIN_RC GH_AFTER_LOGIN GH_SETUP_RC
}

write_secrets() {
  local token=$1
  mkdir -p "$(dirname "$BOX_ACCESS_SECRETS")"
  {
    printf '%s\n' '# Outside git. Used by box-access recovery only.'
    printf '%s\n' 'TS_API_KEY=other-api-should-stay-in-file'
    printf '%s\n' 'TS_AUTHKEY=other-auth-should-stay-in-file'
    printf '%s\n' 'TS_HOSTNAME=cursor'
    printf 'GH_TOKEN=%s\n' "$token"
    printf '%s\n' "\$(touch $TMP/pwned)"
  } > "$BOX_ACCESS_SECRETS"
  chmod 600 "$BOX_ACCESS_SECRETS"
}

assert_no_leak() {
  local needle=$1
  shift
  local file
  if printf '%s\n' "$out" | grep -F -q -- "$needle"; then
    echo "FAIL secret value leaked into stdout"
    exit 1
  fi
  if [[ -f "$TMP/err" ]] && grep -F -q -- "$needle" "$TMP/err"; then
    echo "FAIL secret value leaked into stderr"
    exit 1
  fi
  for file in "$@"; do
    if [[ -f "$file" ]] && grep -F -q -- "$needle" "$file"; then
      echo "FAIL secret value leaked into $(basename "$file")"
      exit 1
    fi
  done
}

run_auth() {
  PATH="$AUTH_PATH:$TOOLS" /bin/bash -c 'source "$1"; box_upkeep_gh_auth' _ "$ROOT/lib/common.sh"
}

reset_auth
printf '%s\n' 'n-huche' > "$GH_STATE"
write_secrets "$FILE_TOKEN"
unset TS_API_KEY TS_AUTHKEY || true
set +e
out=$(run_auth 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL logged-in status was $rc"
  printf '%s\n' "$out"
  cat "$TMP/err"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'gh: logged in as n-huche'; then
  echo "FAIL logged-in account was not reported"
  printf '%s\n' "$out"
  exit 1
fi
if grep -q 'auth login' "$GH_LOG"; then
  echo "FAIL a logged-in account still ran gh auth login"
  exit 1
fi
if ! grep -q 'auth setup-git --hostname github.com' "$GH_LOG"; then
  echo "FAIL logged-in account did not run gh auth setup-git"
  cat "$GH_LOG"
  exit 1
fi
if ! grep -q 'auth status --hostname github.com' "$GH_LOG"; then
  echo "FAIL auth status was not checked for github.com"
  cat "$GH_LOG"
  exit 1
fi
if grep -q 'show-token' "$GH_LOG"; then
  echo "FAIL token display was requested"
  exit 1
fi
if grep -q 'env-set' "$GH_ENV_LOG"; then
  echo "FAIL gh inherited an ambient token"
  exit 1
fi
if ! grep -q "dir=$GH_CONFIG_DIR" "$GH_ENV_LOG"; then
  echo "FAIL gh was not pointed at the persisted config"
  cat "$GH_ENV_LOG"
  exit 1
fi
if [[ -n "${TS_API_KEY:-}" || -n "${TS_AUTHKEY:-}" ]]; then
  echo "FAIL sourcing secrets exported another variable"
  exit 1
fi
if [[ -e "$TMP/pwned" ]]; then
  echo "FAIL secrets file was evaluated"
  exit 1
fi
echo "ok a logged-in expected account runs gh auth setup-git"

reset_auth
set +e
out=$(run_auth 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL logged-out status was $rc, want 0"
  printf '%s\n' "$out"
  cat "$TMP/err"
  exit 1
fi
if grep -q 'auth login' "$GH_LOG"; then
  echo "FAIL a missing token still ran gh auth login"
  exit 1
fi
if grep -q 'auth setup-git' "$GH_LOG"; then
  echo "FAIL a missing token still ran gh auth setup-git"
  exit 1
fi
if ! grep -q 'gh is not logged in to github.com' "$TMP/err"; then
  echo "FAIL logged-out warning missing"
  cat "$TMP/err"
  exit 1
fi
if ! grep -q "GH_CONFIG_DIR=$GH_CONFIG_DIR gh auth login --hostname github.com" "$TMP/err"; then
  echo "FAIL logged-out warning missing the login command"
  cat "$TMP/err"
  exit 1
fi
echo "ok a missing login warns and returns 0"

reset_auth
mkdir -p "$(dirname "$BOX_ACCESS_SECRETS")"
printf '%s\n' 'TS_API_KEY=other-api-should-stay-in-file' 'GH_TOKEN=' > "$BOX_ACCESS_SECRETS"
chmod 600 "$BOX_ACCESS_SECRETS"
set +e
out=$(run_auth 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL empty GH_TOKEN status was $rc"
  exit 1
fi
if grep -q 'auth login' "$GH_LOG"; then
  echo "FAIL an empty GH_TOKEN still ran gh auth login"
  exit 1
fi
if ! grep -q 'gh is not logged in to github.com' "$TMP/err"; then
  echo "FAIL empty GH_TOKEN warning missing"
  exit 1
fi
if grep -q 'other-api-should-stay-in-file' "$TMP/err" <<<"$out"; then
  echo "FAIL another secret was printed"
  exit 1
fi
echo "ok an empty GH_TOKEN warns and returns 0"

reset_auth
printf '%s\n' 'someone' > "$GH_STATE"
set +e
out=$(run_auth 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL wrong-user status was $rc, want 0"
  exit 1
fi
if grep -q 'auth login' "$GH_LOG" || grep -q 'auth setup-git' "$GH_LOG"; then
  echo "FAIL wrong user still logged in or configured git"
  cat "$GH_LOG"
  exit 1
fi
if ! grep -q 'logged in as someone, expected n-huche' "$TMP/err"; then
  echo "FAIL wrong-user warning missing"
  cat "$TMP/err"
  exit 1
fi
if ! grep -q "GH_CONFIG_DIR=$GH_CONFIG_DIR gh auth login --hostname github.com" "$TMP/err"; then
  echo "FAIL wrong-user warning missing the login command"
  exit 1
fi
echo "ok an unexpected account warns and returns 0"

reset_auth
export GH_TOKEN="$ENV_TOKEN"
write_secrets "$FILE_TOKEN"
rm -f "$TMP/pwned"
set +e
out=$(run_auth 2>"$TMP/err")
rc=$?
set -e
unset GH_TOKEN
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL token login status was $rc"
  printf '%s\n' "$out"
  cat "$TMP/err"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'gh: logged in as n-huche'; then
  echo "FAIL token login did not report the account"
  printf '%s\n' "$out"
  exit 1
fi
if ! grep -q 'auth login --hostname github.com --git-protocol https --with-token' "$GH_LOG"; then
  echo "FAIL token was not passed to gh auth login --with-token"
  cat "$GH_LOG"
  exit 1
fi
printf '%s\n' "$FILE_TOKEN" > "$TMP/expect-stdin"
if ! cmp -s "$TMP/expect-stdin" "$GH_STDIN"; then
  echo "FAIL login stdin was not the secrets-file GH_TOKEN"
  exit 1
fi
if ! grep -q 'auth setup-git --hostname github.com' "$GH_LOG"; then
  echo "FAIL token login did not run gh auth setup-git"
  cat "$GH_LOG"
  exit 1
fi
if grep -q 'env-set' "$GH_ENV_LOG"; then
  echo "FAIL ambient GH_TOKEN was visible to gh"
  exit 1
fi
if [[ -e "$TMP/pwned" || -n "${TS_API_KEY:-}" ]]; then
  echo "FAIL secrets file was sourced"
  exit 1
fi
assert_no_leak "$FILE_TOKEN" "$GH_LOG" "$GH_ENV_LOG" "$TMP/trace"
assert_no_leak "$ENV_TOKEN" "$GH_LOG" "$GH_ENV_LOG" "$TMP/trace"
assert_no_leak "other-api-should-stay-in-file" "$GH_LOG" "$GH_ENV_LOG"
echo "ok a secrets-file GH_TOKEN logs in on stdin and ignores the environment"

reset_auth
export GH_TOKEN="$ENV_TOKEN"
set +e
out=$(run_auth 2>"$TMP/err")
rc=$?
set -e
unset GH_TOKEN
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL ambient-token-only status was $rc"
  exit 1
fi
if [[ -e "$GH_STDIN" ]] || grep -q 'auth login' "$GH_LOG"; then
  echo "FAIL an ambient GH_TOKEN was used as the login"
  exit 1
fi
if grep -q 'env-set' "$GH_ENV_LOG"; then
  echo "FAIL gh auth status saw the ambient GH_TOKEN"
  exit 1
fi
if ! grep -q 'gh is not logged in to github.com' "$TMP/err"; then
  echo "FAIL ambient token was treated as a persisted login"
  cat "$TMP/err"
  exit 1
fi
assert_no_leak "$ENV_TOKEN" "$GH_LOG" "$GH_ENV_LOG"
echo "ok an ambient GH_TOKEN does not count as logged in"

reset_auth
write_secrets "$FILE_TOKEN"
GH_LOGIN_RC=3
set +e
out=$(run_auth 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL token login failure status was $rc, want 0"
  exit 1
fi
if grep -q 'auth setup-git' "$GH_LOG"; then
  echo "FAIL a failed token login still ran gh auth setup-git"
  exit 1
fi
if ! grep -q 'gh auth login failed for github.com' "$TMP/err"; then
  echo "FAIL token login failure was not warned"
  cat "$TMP/err"
  exit 1
fi
assert_no_leak "$FILE_TOKEN" "$GH_LOG" "$GH_ENV_LOG"
echo "ok a failed token login warns, hides the token, and returns 0"

reset_auth
printf '%s\n' 'not_a_user' > "$GH_STATE"
set +e
out=$(run_auth 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL token-shaped login status was $rc"
  exit 1
fi
if printf '%s\n' "$out" | grep -q 'not_a_user' || grep -q 'not_a_user' "$TMP/err"; then
  echo "FAIL a token-shaped login name was printed"
  exit 1
fi
if ! grep -q 'gh is not logged in to github.com' "$TMP/err"; then
  echo "FAIL token-shaped login was accepted"
  cat "$TMP/err"
  exit 1
fi
echo "ok a token-shaped status login is not printed"

reset_auth
write_secrets "$XTRACE_TOKEN"
rm -f "$TMP/pwned"
set +e
PATH="$AUTH_PATH:$TOOLS" \
  /bin/bash -c '
    exec 9>"$1"
    export BASH_XTRACEFD=9
    set -x
    source "$2"
    box_upkeep_gh_auth
    set +x
  ' _ "$TMP/trace" "$ROOT/lib/common.sh" >"$TMP/out" 2>"$TMP/err"
rc=$?
set -e
out=$(cat "$TMP/out")
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL xtrace login status was $rc"
  exit 1
fi
if ! cmp -s <(printf '%s\n' "$XTRACE_TOKEN") "$GH_STDIN"; then
  echo "FAIL xtrace run did not pass the secrets-file token"
  exit 1
fi
if ! grep -q 'box_upkeep_gh_auth' "$TMP/trace"; then
  echo "FAIL xtrace did not record the auth call"
  exit 1
fi
assert_no_leak "$XTRACE_TOKEN" "$TMP/trace" "$GH_LOG" "$GH_ENV_LOG"
echo "ok set -x does not print the token"

reset_auth
mkdir -p "$(dirname "$BOX_ACCESS_SECRETS")"
printf '%s\n' 'export GH_TOKEN="quoted-sentinel-value"' > "$BOX_ACCESS_SECRETS"
chmod 600 "$BOX_ACCESS_SECRETS"
got=$(PATH="$AUTH_PATH:$TOOLS" /bin/bash -c 'source "$1"; box_upkeep_read_gh_token "$2"' _ "$ROOT/lib/common.sh" "$BOX_ACCESS_SECRETS")
if [[ "$got" != "quoted-sentinel-value" ]]; then
  echo "FAIL quoted GH_TOKEN was not read literally"
  exit 1
fi
echo "ok only the GH_TOKEN assignment is read"

ACCESS_LOG=$TMP/access.log
AOS_LOG=$TMP/aos.log
GH_INSTALL_LOG=$TMP/gh-install.log
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
cat > "$TMP/gh-install.sh" << 'EOF'
#!/bin/bash
printf 'invoked %s\n' "$*" >> "$GH_INSTALL_LOG"
exit "${GH_RC:-0}"
EOF
cat > "$TMP/dockerd-ensure.sh" << 'EOF'
#!/bin/bash
printf '%s\n' 'dockerd: present'
exit 0
EOF
chmod +x "$TMP/access-up.sh" "$TMP/aos-up.sh" "$TMP/gh-install.sh" "$TMP/dockerd-ensure.sh"

ACCESS_RC=0
AOS_RC=0
GH_RC=0
UP_PATH=$AUTH_PATH

run_up() {
  PATH="$UP_PATH:$TOOLS" \
    HOME_BOX="$HOME_BOX" GH_CONFIG_DIR="$GH_CONFIG_DIR" BOX_ACCESS_SECRETS="$BOX_ACCESS_SECRETS" \
    GH_EXPECTED_USER="${GH_EXPECTED_USER:-}" \
    ACCESS_RC="$ACCESS_RC" AOS_RC="$AOS_RC" GH_RC="$GH_RC" \
    GH_LOGIN_RC="${GH_LOGIN_RC:-0}" GH_AFTER_LOGIN="${GH_AFTER_LOGIN:-n-huche}" \
    GH_SETUP_RC="${GH_SETUP_RC:-0}" \
    GH_LOG="$GH_LOG" GH_ENV_LOG="$GH_ENV_LOG" GH_STDIN="$GH_STDIN" GH_STATE="$GH_STATE" \
    BOX_ACCESS_UP="$TMP/access-up.sh" AOS_UP="$TMP/aos-up.sh" \
    GH_INSTALL="${GH_INSTALL_OVERRIDE:-$TMP/gh-install.sh}" \
    DOCKERD_ENSURE="$TMP/dockerd-ensure.sh" \
    ACCESS_LOG="$ACCESS_LOG" AOS_LOG="$AOS_LOG" GH_INSTALL_LOG="$GH_INSTALL_LOG" \
    /bin/bash "$ROOT/up.sh" "$@"
}

reset_logs() {
  rm -f "$ACCESS_LOG" "$AOS_LOG" "$GH_INSTALL_LOG" "$GH_LOG" "$GH_ENV_LOG" "$GH_STDIN"
}

reset_auth
reset_logs
printf '%s\n' 'n-huche' > "$GH_STATE"
out=$(run_up)
if [[ -e "$GH_INSTALL_LOG" ]]; then
  echo "FAIL present gh still called the install script"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'gh: present'; then
  echo "FAIL up.sh did not skip a present gh"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'gh: logged in as n-huche'; then
  echo "FAIL up.sh did not report the logged-in account"
  printf '%s\n' "$out"
  exit 1
fi
access_line=$(printf '%s\n' "$out" | grep -n '^access:' | head -n1 | cut -d: -f1)
aos_line=$(printf '%s\n' "$out" | grep -n '^aos:' | head -n1 | cut -d: -f1)
jdk_line=$(printf '%s\n' "$out" | grep -n '^jdk:' | head -n1 | cut -d: -f1)
maven_line=$(printf '%s\n' "$out" | grep -n '^maven:' | head -n1 | cut -d: -f1)
gh_line=$(printf '%s\n' "$out" | grep -n '^gh:' | head -n1 | cut -d: -f1)
if (( access_line >= aos_line || aos_line >= jdk_line || jdk_line >= maven_line || maven_line >= gh_line )); then
  echo "FAIL gh step did not run after maven"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok up.sh skips install when gh is present and logged in"

reset_auth
reset_logs
UP_PATH=$empty_bin
out=$(run_up)
if [[ "$(cat "$GH_INSTALL_LOG")" != "invoked " ]]; then
  echo "FAIL missing gh did not call the install script"
  cat "$GH_INSTALL_LOG"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: ok'; then
  echo "FAIL missing gh path did not succeed"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok up.sh installs a missing gh after maven"

reset_auth
reset_logs
UP_PATH=$AUTH_PATH
set +e
out=$(run_up 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL logged-out up.sh status was $rc"
  printf '%s\n' "$out"
  cat "$TMP/err"
  exit 1
fi
if [[ -e "$GH_INSTALL_LOG" ]]; then
  echo "FAIL logged-out up.sh reinstalled gh"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: ok'; then
  echo "FAIL logged-out up.sh did not succeed"
  printf '%s\n' "$out"
  exit 1
fi
if ! grep -q 'gh is not logged in to github.com' "$TMP/err"; then
  echo "FAIL up.sh hid the logged-out warning"
  cat "$TMP/err"
  exit 1
fi
echo "ok up.sh warns when gh is logged out and still exits 0"

reset_auth
reset_logs
printf '%s\n' 'someone' > "$GH_STATE"
set +e
out=$(run_up 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL wrong-user up.sh status was $rc"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: ok'; then
  echo "FAIL wrong-user up.sh failed"
  printf '%s\n' "$out"
  exit 1
fi
if ! grep -q 'expected n-huche' "$TMP/err"; then
  echo "FAIL up.sh hid the wrong-user warning"
  cat "$TMP/err"
  exit 1
fi
echo "ok up.sh warns on the wrong account and still exits 0"

reset_auth
reset_logs
export GH_TOKEN="$ENV_TOKEN"
write_secrets "$FILE_TOKEN"
set +e
out=$(run_up 2>"$TMP/err")
rc=$?
set -e
unset GH_TOKEN
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL token up.sh status was $rc"
  printf '%s\n' "$out"
  cat "$TMP/err"
  exit 1
fi
if [[ -e "$GH_INSTALL_LOG" ]]; then
  echo "FAIL token login reinstalled a present gh"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'gh: logged in as n-huche'; then
  echo "FAIL up.sh token login did not report the account"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: ok'; then
  echo "FAIL token login failed up.sh"
  printf '%s\n' "$out"
  exit 1
fi
printf '%s\n' "$FILE_TOKEN" > "$TMP/expect-stdin"
if ! cmp -s "$TMP/expect-stdin" "$GH_STDIN"; then
  echo "FAIL up.sh login stdin was not the secrets-file GH_TOKEN"
  exit 1
fi
if ! grep -q 'auth setup-git --hostname github.com' "$GH_LOG"; then
  echo "FAIL up.sh token login skipped gh auth setup-git"
  exit 1
fi
assert_no_leak "$FILE_TOKEN" "$GH_LOG" "$GH_ENV_LOG"
assert_no_leak "$ENV_TOKEN" "$GH_LOG" "$GH_ENV_LOG"
echo "ok up.sh logs in from the secrets file without printing the token"

reset_auth
reset_logs
UP_PATH=$empty_bin
GH_RC=4
set +e
out=$(run_up 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 4 ]]; then
  echo "FAIL gh failure status was $rc, want 4"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'ERROR: gh install failed status=4'; then
  echo "FAIL gh failure was not reported"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: failed access=0 aos=0 jdk=0 maven=0 gh=4 docker=0'; then
  echo "FAIL gh failure summary missing"
  printf '%s\n' "$out"
  exit 1
fi
if [[ -f "$GH_LOG" ]] && grep -q 'auth status' "$GH_LOG"; then
  echo "FAIL a failed install still checked auth"
  exit 1
fi
echo "ok a gh install failure is reported and fails up.sh"

reset_logs
ACCESS_RC=4
AOS_RC=0
GH_RC=0
UP_PATH=$empty_bin
set +e
out=$(run_up --stop-on-error 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 4 ]]; then
  echo "FAIL stop-on-error status was $rc"
  printf '%s\n' "$out"
  exit 1
fi
if [[ -e "$AOS_LOG" || -e "$GH_INSTALL_LOG" ]]; then
  echo "FAIL stop-on-error still ran aos or gh"
  exit 1
fi
if printf '%s\n' "$out" | grep -q '^gh:'; then
  echo "FAIL stop-on-error still reached gh"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok --stop-on-error returns before the gh step"

reset_logs
ACCESS_RC=0
UP_PATH=$empty_bin
run_up --install-only >/dev/null
if [[ "$(cat "$ACCESS_LOG")" != "invoked --install-only" ]]; then
  echo "FAIL --install-only access flags: $(cat "$ACCESS_LOG")"
  exit 1
fi
if [[ "$(cat "$GH_INSTALL_LOG")" != "invoked " ]]; then
  echo "FAIL --install-only skipped the gh install"
  exit 1
fi
echo "ok --install-only still installs a missing gh"

reset_logs
run_up --access-only >/dev/null
if [[ ! -f "$ACCESS_LOG" || -e "$AOS_LOG" || "$(cat "$GH_INSTALL_LOG")" != "invoked " ]]; then
  echo "FAIL --access-only did not still install a missing gh"
  exit 1
fi
echo "ok --access-only still installs a missing gh"

reset_logs
run_up --aos-only >/dev/null
if [[ -e "$ACCESS_LOG" || ! -f "$AOS_LOG" || "$(cat "$GH_INSTALL_LOG")" != "invoked " ]]; then
  echo "FAIL --aos-only did not still install a missing gh"
  exit 1
fi
echo "ok --aos-only still installs a missing gh"

reset_logs
ACCESS_RC=0
GH_INSTALL_OVERRIDE=$TMP/missing-gh.sh
set +e
out=$(run_up 2>&1)
rc=$?
set -e
unset GH_INSTALL_OVERRIDE
if [[ "$rc" -ne 127 ]]; then
  echo "FAIL missing gh script status was $rc"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'gh install entry not executable'; then
  echo "FAIL missing gh script was not reported"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: failed access=0 aos=0 jdk=0 maven=0 gh=127 docker=0'; then
  echo "FAIL missing gh script summary missing"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok a missing gh script is status 127"

reset_logs
UP_PATH=$empty_bin
run_up --help >/dev/null
if [[ -e "$ACCESS_LOG" || -e "$AOS_LOG" || -e "$GH_INSTALL_LOG" ]]; then
  echo "FAIL --help invoked a side or the gh script"
  exit 1
fi
help=$(run_up --help)
if ! printf '%s\n' "$help" | grep -q 'GH_EXPECTED_USER'; then
  echo "FAIL up.sh --help missing GH_EXPECTED_USER"
  exit 1
fi
if ! printf '%s\n' "$help" | grep -q 'n-huche'; then
  echo "FAIL up.sh --help missing n-huche"
  exit 1
fi
if ! printf '%s\n' "$help" | grep -q '/home/box/.config/box-access/secrets.env'; then
  echo "FAIL up.sh --help missing the secrets file"
  exit 1
fi
echo "ok up.sh --help mentions the GitHub CLI login"
