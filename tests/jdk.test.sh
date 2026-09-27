#!/usr/bin/env bash
# JDK detection and java/install-jdk.sh. Mock apt. No network.
# up.sh cases use mock gate, aos, and jdk entries.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$ROOT/java/install-jdk.sh" ]]; then
  echo "FAIL java/install-jdk.sh is not executable"
  exit 1
fi
if ! grep -q 'set -euo pipefail' "$ROOT/java/install-jdk.sh"; then
  echo "FAIL java/install-jdk.sh missing set -euo pipefail"
  exit 1
fi
if grep -q 'jdk' "$ROOT/packages.txt"; then
  echo "FAIL JDK package belongs in java/install-jdk.sh, not packages.txt"
  exit 1
fi
echo "ok jdk script is executable and packages.txt stays cronie"

pkg=$(env -u JDK_PACKAGE bash -c 'source "$1"; printf %s "$JDK_PACKAGE"' _ "$ROOT/lib/common.sh")
if [[ "$pkg" != "default-jdk" ]]; then
  echo "FAIL default JDK package was $pkg"
  exit 1
fi
inst=$(env -u JDK_INSTALL bash -c 'source "$1"; printf %s "$JDK_INSTALL"' _ "$ROOT/lib/common.sh")
if [[ "$inst" != "$ROOT/java/install-jdk.sh" ]]; then
  echo "FAIL JDK_INSTALL default was $inst"
  exit 1
fi
pkg=$(JDK_PACKAGE=openjdk-17-jdk bash -c 'source "$1"; printf %s "$JDK_PACKAGE"' _ "$ROOT/lib/common.sh")
if [[ "$pkg" != "openjdk-17-jdk" ]]; then
  echo "FAIL JDK_PACKAGE override was $pkg"
  exit 1
fi
echo "ok JDK_PACKAGE defaults to default-jdk and can be overridden"

ok_bin=$TMP/ok-bin
empty_bin=$TMP/empty-bin
jre_bin=$TMP/jre-bin
bad_bin=$TMP/bad-bin
TOOLS=$TMP/tools
mkdir -p "$ok_bin" "$empty_bin" "$jre_bin" "$bad_bin" "$TOOLS"
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
cp "$TMP/stub-ok" "$ok_bin/java"
cp "$TMP/stub-ok" "$ok_bin/javac"
cp "$TMP/stub-ok" "$jre_bin/java"
cp "$TMP/stub-bad" "$bad_bin/java"
cp "$TMP/stub-ok" "$bad_bin/javac"
chmod +x "$ok_bin/java" "$ok_bin/javac" "$jre_bin/java" "$bad_bin/java" "$bad_bin/javac"

check_present() {
  local path=$1 expect=$2 rc
  set +e
  PATH="$path:$TOOLS" /bin/bash -c 'source "$1"; box_upkeep_jdk_present' _ "$ROOT/lib/common.sh"
  rc=$?
  set -e
  if [[ "$rc" -ne "$expect" ]]; then
    echo "FAIL jdk present check path=$path rc=$rc want=$expect"
    exit 1
  fi
}
check_present "$ok_bin" 0
check_present "$empty_bin" 1
check_present "$jre_bin" 1
check_present "$bad_bin" 1
echo "ok java and javac must both run"

BIN=$TMP/apt-bin
APT_LOG=$TMP/apt.log
PKG_LOG=$TMP/pkg.log
STUB=$TMP/stub-ok
APT_UPDATE_RC=0
APT_INSTALL_RC=0
APT_LEAVE_MISSING=0
export APT_LOG PKG_LOG BIN_DIR="$BIN" STUB APT_UPDATE_RC APT_INSTALL_RC APT_LEAVE_MISSING

cat > "$TMP/sudo" << 'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$APT_LOG"
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
    /bin/cp "$STUB" "$BIN_DIR/java"
    /bin/cp "$STUB" "$BIN_DIR/javac"
    /bin/chmod +x "$BIN_DIR/java" "$BIN_DIR/javac"
  fi
fi
exit 0
EOF
chmod +x "$TMP/sudo"

reset_tooling() {
  rm -rf "$BIN"
  mkdir -p "$BIN"
  cp "$TMP/sudo" "$BIN/sudo"
  chmod +x "$BIN/sudo"
  rm -f "$APT_LOG" "$PKG_LOG"
  APT_UPDATE_RC=0
  APT_INSTALL_RC=0
  APT_LEAVE_MISSING=0
}

run_install() {
  PATH="$BIN:$TOOLS" /bin/bash "$ROOT/java/install-jdk.sh"
}

unset JDK_PACKAGE
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
if ! printf '%s\n' "$out" | grep -qx 'jdk-install: default-jdk'; then
  echo "FAIL install did not announce default-jdk"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'jdk: installed default-jdk'; then
  echo "FAIL install did not report success"
  printf '%s\n' "$out"
  exit 1
fi
if ! grep -qx 'apt-get update -y' "$APT_LOG"; then
  echo "FAIL apt-get update was not invoked"
  cat "$APT_LOG"
  exit 1
fi
if ! grep -qx 'DEBIAN_FRONTEND=noninteractive apt-get install -y default-jdk' "$APT_LOG"; then
  echo "FAIL apt-get install line: $(cat "$APT_LOG")"
  exit 1
fi
if ! grep -qx 'default-jdk' "$PKG_LOG"; then
  echo "FAIL package log: $(cat "$PKG_LOG")"
  exit 1
fi
echo "ok missing jdk installs default-jdk"

lines=$(wc -l < "$APT_LOG")
set +e
out=$(run_install 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 || "$(wc -l < "$APT_LOG")" -ne "$lines" ]]; then
  echo "FAIL second run did not skip apt"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'jdk: present'; then
  echo "FAIL second run did not report jdk present"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok a second run skips apt"

reset_tooling
export JDK_PACKAGE=openjdk-17-jdk
set +e
out=$(run_install 2>"$TMP/err")
rc=$?
set -e
unset JDK_PACKAGE
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL override install status $rc"
  printf '%s\n' "$out"
  cat "$TMP/err"
  exit 1
fi
if ! grep -qx 'openjdk-17-jdk' "$PKG_LOG"; then
  echo "FAIL JDK_PACKAGE was not installed: $(cat "$PKG_LOG")"
  exit 1
fi
echo "ok JDK_PACKAGE selects the apt package"

reset_tooling
cp "$STUB" "$BIN/java"
cp "$STUB" "$BIN/javac"
chmod +x "$BIN/java" "$BIN/javac"
set +e
out=$(run_install 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 || -e "$APT_LOG" ]]; then
  echo "FAIL present jdk still called apt"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'jdk: present'; then
  echo "FAIL direct run did not skip quietly"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok direct run skips when java and javac already run"

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
if [[ -e "$BIN/java" ]]; then
  echo "FAIL update failure still produced java"
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
if ! grep -q 'apt-get install failed for default-jdk' "$TMP/err"; then
  echo "FAIL install error was not reported"
  cat "$TMP/err"
  exit 1
fi
if [[ -e "$BIN/java" ]]; then
  echo "FAIL install failure still produced java"
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
  echo "FAIL missing binaries after install were accepted"
  exit 1
fi
if ! grep -q 'java or javac still does not run' "$TMP/err"; then
  echo "FAIL post-install check was not reported"
  cat "$TMP/err"
  exit 1
fi
echo "ok install that leaves java missing is an error"

ACCESS_LOG=$TMP/access.log
AOS_LOG=$TMP/aos.log
JDK_LOG=$TMP/jdk.log
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
cat > "$TMP/jdk-install.sh" << 'EOF'
#!/bin/bash
printf 'invoked %s\n' "$*" >> "$JDK_LOG"
exit "${JDK_RC:-0}"
EOF
chmod +x "$TMP/access-up.sh" "$TMP/aos-up.sh" "$TMP/jdk-install.sh"

UP_PATH=$empty_bin
JDK_INSTALL=$TMP/jdk-install.sh
ACCESS_RC=0
AOS_RC=0
JDK_RC=0

run_up() {
  PATH="$UP_PATH:$TOOLS" \
    ACCESS_RC="$ACCESS_RC" AOS_RC="$AOS_RC" JDK_RC="$JDK_RC" \
    BOX_ACCESS_UP="$TMP/access-up.sh" AOS_UP="$TMP/aos-up.sh" \
    JDK_INSTALL="$JDK_INSTALL" \
    ACCESS_LOG="$ACCESS_LOG" AOS_LOG="$AOS_LOG" JDK_LOG="$JDK_LOG" \
    /bin/bash "$ROOT/up.sh" "$@"
}

reset_logs() {
  rm -f "$ACCESS_LOG" "$AOS_LOG" "$JDK_LOG"
}

reset_logs
out=$(run_up)
access_line=$(printf '%s\n' "$out" | grep -n '^access:' | head -n1 | cut -d: -f1)
aos_line=$(printf '%s\n' "$out" | grep -n '^aos:' | head -n1 | cut -d: -f1)
jdk_line=$(printf '%s\n' "$out" | grep -n '^jdk:' | head -n1 | cut -d: -f1)
if (( access_line >= aos_line || aos_line >= jdk_line )); then
  echo "FAIL jdk step did not run after the gate and aos"
  printf '%s\n' "$out"
  exit 1
fi
if [[ "$(cat "$JDK_LOG")" != "invoked " ]]; then
  echo "FAIL missing jdk did not call the install script"
  cat "$JDK_LOG"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: ok'; then
  echo "FAIL missing jdk path did not succeed"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok up.sh installs a missing jdk after both sides"

reset_logs
UP_PATH=$ok_bin
out=$(run_up)
if [[ -e "$JDK_LOG" ]]; then
  echo "FAIL present jdk still called the install script"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'jdk: present'; then
  echo "FAIL up.sh did not skip a present jdk"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok up.sh skips the install script when the jdk is present"

reset_logs
UP_PATH=$bad_bin
run_up >/dev/null
if [[ "$(cat "$JDK_LOG")" != "invoked " ]]; then
  echo "FAIL broken java -version did not reinstall"
  exit 1
fi
echo "ok a java that fails -version is treated as missing"

reset_logs
UP_PATH=$jre_bin
run_up >/dev/null
if [[ "$(cat "$JDK_LOG")" != "invoked " ]]; then
  echo "FAIL a JRE without javac skipped the install"
  exit 1
fi
echo "ok javac is required"

reset_logs
UP_PATH=$empty_bin
run_up --install-only >/dev/null
if [[ "$(cat "$ACCESS_LOG")" != "invoked --install-only" ]]; then
  echo "FAIL --install-only access flags: $(cat "$ACCESS_LOG")"
  exit 1
fi
if [[ "$(cat "$AOS_LOG")" != "invoked --install-only" ]]; then
  echo "FAIL --install-only aos flags: $(cat "$AOS_LOG")"
  exit 1
fi
if [[ "$(cat "$JDK_LOG")" != "invoked " ]]; then
  echo "FAIL --install-only skipped the jdk install"
  exit 1
fi
echo "ok --install-only still installs a missing jdk"

reset_logs
run_up --access-only >/dev/null
if [[ ! -f "$ACCESS_LOG" || -e "$AOS_LOG" || "$(cat "$JDK_LOG")" != "invoked " ]]; then
  echo "FAIL --access-only did not still install a missing jdk"
  exit 1
fi
echo "ok --access-only still installs a missing jdk"

reset_logs
run_up --aos-only >/dev/null
if [[ -e "$ACCESS_LOG" || ! -f "$AOS_LOG" || "$(cat "$JDK_LOG")" != "invoked " ]]; then
  echo "FAIL --aos-only did not still install a missing jdk"
  exit 1
fi
echo "ok --aos-only still installs a missing jdk"

reset_logs
JDK_RC=9
set +e
out=$(run_up 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 9 ]]; then
  echo "FAIL jdk failure status was $rc, want 9"
  printf '%s\n' "$out"
  exit 1
fi
if [[ "$(cat "$ACCESS_LOG")" != "invoked " || "$(cat "$AOS_LOG")" != "invoked " ]]; then
  echo "FAIL jdk failure skipped a side"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'ERROR: jdk install failed status=9'; then
  echo "FAIL jdk failure was not reported"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: failed access=0 aos=0 jdk=9'; then
  echo "FAIL jdk failure summary missing"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok a jdk install failure is reported and fails up.sh"

reset_logs
ACCESS_RC=3
JDK_RC=9
set +e
out=$(run_up 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 3 ]]; then
  echo "FAIL first failure status was $rc, want 3"
  printf '%s\n' "$out"
  exit 1
fi
if [[ "$(cat "$AOS_LOG")" != "invoked " || "$(cat "$JDK_LOG")" != "invoked " ]]; then
  echo "FAIL access failure skipped aos or jdk"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: failed access=3 aos=0 jdk=9'; then
  echo "FAIL combined failure summary missing"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok when access and jdk fail, jdk still runs and the gate status wins"

reset_logs
ACCESS_RC=4
AOS_RC=0
JDK_RC=0
set +e
out=$(run_up --stop-on-error 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 4 ]]; then
  echo "FAIL stop-on-error status was $rc"
  printf '%s\n' "$out"
  exit 1
fi
if [[ -e "$AOS_LOG" || -e "$JDK_LOG" ]]; then
  echo "FAIL stop-on-error still ran aos or jdk"
  exit 1
fi
echo "ok --stop-on-error returns before the jdk step"

reset_logs
ACCESS_RC=0
JDK_INSTALL=$TMP/missing-jdk.sh
set +e
out=$(run_up 2>&1)
rc=$?
set -e
JDK_INSTALL=$TMP/jdk-install.sh
if [[ "$rc" -ne 127 ]]; then
  echo "FAIL missing jdk script status was $rc"
  printf '%s\n' "$out"
  exit 1
fi
if [[ "$(cat "$ACCESS_LOG")" != "invoked " || "$(cat "$AOS_LOG")" != "invoked " ]]; then
  echo "FAIL missing jdk script skipped a side"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'jdk install entry not executable'; then
  echo "FAIL missing jdk script was not reported"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: failed access=0 aos=0 jdk=127'; then
  echo "FAIL missing jdk script summary missing"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok a missing jdk script is status 127"

reset_logs
UP_PATH=$empty_bin
run_up --help >/dev/null
if [[ -e "$ACCESS_LOG" || -e "$AOS_LOG" || -e "$JDK_LOG" ]]; then
  echo "FAIL --help invoked a side or the jdk script"
  exit 1
fi
help=$(run_up --help)
if ! printf '%s\n' "$help" | grep -q 'JDK_PACKAGE'; then
  echo "FAIL up.sh --help missing JDK_PACKAGE"
  exit 1
fi
if ! printf '%s\n' "$help" | grep -q 'default-jdk'; then
  echo "FAIL up.sh --help missing default-jdk"
  exit 1
fi
echo "ok up.sh --help mentions the jdk package"
