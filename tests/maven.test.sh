#!/usr/bin/env bash
# Maven detection and java/install-maven.sh. Mock apt. No network.
# up.sh cases use mock gate, aos, jdk, and maven entries.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$ROOT/java/install-maven.sh" ]]; then
  echo "FAIL java/install-maven.sh is not executable"
  exit 1
fi
if ! grep -q 'set -euo pipefail' "$ROOT/java/install-maven.sh"; then
  echo "FAIL java/install-maven.sh missing set -euo pipefail"
  exit 1
fi
if grep -q 'maven' "$ROOT/aos/packages.txt"; then
  echo "FAIL Maven package belongs in java/install-maven.sh, not aos/packages.txt"
  exit 1
fi
echo "ok maven script is executable and packages.txt stays cronie"

pkg=$(env -u MAVEN_PACKAGE bash -c 'source "$1"; printf %s "$MAVEN_PACKAGE"' _ "$ROOT/lib/common.sh")
if [[ "$pkg" != "maven" ]]; then
  echo "FAIL default Maven package was $pkg"
  exit 1
fi
inst=$(env -u MAVEN_INSTALL bash -c 'source "$1"; printf %s "$MAVEN_INSTALL"' _ "$ROOT/lib/common.sh")
if [[ "$inst" != "$ROOT/java/install-maven.sh" ]]; then
  echo "FAIL MAVEN_INSTALL default was $inst"
  exit 1
fi
pkg=$(MAVEN_PACKAGE=custom-maven bash -c 'source "$1"; printf %s "$MAVEN_PACKAGE"' _ "$ROOT/lib/common.sh")
if [[ "$pkg" != "custom-maven" ]]; then
  echo "FAIL MAVEN_PACKAGE override was $pkg"
  exit 1
fi
echo "ok MAVEN_PACKAGE defaults to maven and can be overridden"

ok_bin=$TMP/ok-bin
empty_bin=$TMP/empty-bin
bad_bin=$TMP/bad-bin
jdk_bin=$TMP/jdk-bin
TOOLS=$TMP/tools
mkdir -p "$ok_bin" "$empty_bin" "$bad_bin" "$jdk_bin" "$TOOLS"
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
cp "$TMP/stub-ok" "$ok_bin/mvn"
cp "$TMP/stub-ok" "$ok_bin/java"
cp "$TMP/stub-ok" "$ok_bin/javac"
cp "$TMP/stub-bad" "$bad_bin/mvn"
cp "$TMP/stub-ok" "$bad_bin/java"
cp "$TMP/stub-ok" "$bad_bin/javac"
cp "$TMP/stub-ok" "$jdk_bin/java"
cp "$TMP/stub-ok" "$jdk_bin/javac"
chmod +x "$ok_bin/mvn" "$ok_bin/java" "$ok_bin/javac" \
  "$bad_bin/mvn" "$bad_bin/java" "$bad_bin/javac" \
  "$jdk_bin/java" "$jdk_bin/javac"

check_present() {
  local path=$1 expect=$2 rc
  set +e
  PATH="$path:$TOOLS" /bin/bash -c 'source "$1"; box_upkeep_maven_present' _ "$ROOT/lib/common.sh"
  rc=$?
  set -e
  if [[ "$rc" -ne "$expect" ]]; then
    echo "FAIL maven present check path=$path rc=$rc want=$expect"
    exit 1
  fi
}
check_present "$ok_bin" 0
check_present "$empty_bin" 1
check_present "$bad_bin" 1
echo "ok mvn -v must run"

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
    /bin/cp "$STUB" "$BIN_DIR/mvn"
    /bin/chmod +x "$BIN_DIR/mvn"
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
  PATH="$BIN:$TOOLS" /bin/bash "$ROOT/java/install-maven.sh"
}

unset MAVEN_PACKAGE
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
if ! printf '%s\n' "$out" | grep -qx 'maven-install: maven'; then
  echo "FAIL install did not announce maven"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'maven: installed maven'; then
  echo "FAIL install did not report success"
  printf '%s\n' "$out"
  exit 1
fi
if ! grep -qx 'apt-get update -y' "$APT_LOG"; then
  echo "FAIL apt-get update was not invoked"
  cat "$APT_LOG"
  exit 1
fi
if ! grep -qx 'DEBIAN_FRONTEND=noninteractive apt-get install -y maven' "$APT_LOG"; then
  echo "FAIL apt-get install line: $(cat "$APT_LOG")"
  exit 1
fi
if ! grep -qx 'maven' "$PKG_LOG"; then
  echo "FAIL package log: $(cat "$PKG_LOG")"
  exit 1
fi
echo "ok missing maven installs maven"

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
if ! printf '%s\n' "$out" | grep -qx 'maven: present'; then
  echo "FAIL second run did not report maven present"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok a second run skips apt"

reset_tooling
export MAVEN_PACKAGE=custom-maven
set +e
out=$(run_install 2>"$TMP/err")
rc=$?
set -e
unset MAVEN_PACKAGE
if [[ "$rc" -ne 0 ]]; then
  echo "FAIL override install status $rc"
  printf '%s\n' "$out"
  cat "$TMP/err"
  exit 1
fi
if ! grep -qx 'custom-maven' "$PKG_LOG"; then
  echo "FAIL MAVEN_PACKAGE was not installed: $(cat "$PKG_LOG")"
  exit 1
fi
echo "ok MAVEN_PACKAGE selects the apt package"

reset_tooling
cp "$STUB" "$BIN/mvn"
chmod +x "$BIN/mvn"
set +e
out=$(run_install 2>"$TMP/err")
rc=$?
set -e
if [[ "$rc" -ne 0 || -e "$APT_LOG" ]]; then
  echo "FAIL present maven still called apt"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'maven: present'; then
  echo "FAIL direct run did not skip quietly"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok direct run skips when mvn -v already runs"

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
if [[ -e "$BIN/mvn" ]]; then
  echo "FAIL update failure still produced mvn"
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
if ! grep -q 'apt-get install failed for maven' "$TMP/err"; then
  echo "FAIL install error was not reported"
  cat "$TMP/err"
  exit 1
fi
if [[ -e "$BIN/mvn" ]]; then
  echo "FAIL install failure still produced mvn"
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
  echo "FAIL missing mvn after install was accepted"
  exit 1
fi
if ! grep -q 'mvn -v still does not run' "$TMP/err"; then
  echo "FAIL post-install check was not reported"
  cat "$TMP/err"
  exit 1
fi
echo "ok install that leaves mvn missing is an error"

ACCESS_LOG=$TMP/access.log
AOS_LOG=$TMP/aos.log
JDK_LOG=$TMP/jdk.log
MAVEN_LOG=$TMP/maven.log
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
cat > "$TMP/maven-install.sh" << 'EOF'
#!/bin/bash
printf 'invoked %s\n' "$*" >> "$MAVEN_LOG"
exit "${MAVEN_RC:-0}"
EOF
chmod +x "$TMP/access-up.sh" "$TMP/aos-up.sh" "$TMP/jdk-install.sh" "$TMP/maven-install.sh"

UP_PATH=$jdk_bin
JDK_INSTALL=$TMP/jdk-install.sh
MAVEN_INSTALL=$TMP/maven-install.sh
ACCESS_RC=0
AOS_RC=0
JDK_RC=0
MAVEN_RC=0

run_up() {
  PATH="$UP_PATH:$TOOLS" \
    ACCESS_RC="$ACCESS_RC" AOS_RC="$AOS_RC" JDK_RC="$JDK_RC" MAVEN_RC="$MAVEN_RC" \
    BOX_ACCESS_UP="$TMP/access-up.sh" AOS_UP="$TMP/aos-up.sh" \
    JDK_INSTALL="$JDK_INSTALL" MAVEN_INSTALL="$MAVEN_INSTALL" \
    ACCESS_LOG="$ACCESS_LOG" AOS_LOG="$AOS_LOG" JDK_LOG="$JDK_LOG" MAVEN_LOG="$MAVEN_LOG" \
    /bin/bash "$ROOT/up.sh" "$@"
}

reset_logs() {
  rm -f "$ACCESS_LOG" "$AOS_LOG" "$JDK_LOG" "$MAVEN_LOG"
}

reset_logs
UP_PATH=$empty_bin
out=$(run_up)
access_line=$(printf '%s\n' "$out" | grep -n '^access:' | head -n1 | cut -d: -f1)
aos_line=$(printf '%s\n' "$out" | grep -n '^aos:' | head -n1 | cut -d: -f1)
jdk_line=$(printf '%s\n' "$out" | grep -n '^jdk:' | head -n1 | cut -d: -f1)
maven_line=$(printf '%s\n' "$out" | grep -n '^maven:' | head -n1 | cut -d: -f1)
if (( access_line >= aos_line || aos_line >= jdk_line || jdk_line >= maven_line )); then
  echo "FAIL maven step did not run after the gate, aos, and jdk"
  printf '%s\n' "$out"
  exit 1
fi
if [[ "$(cat "$JDK_LOG")" != "invoked " || "$(cat "$MAVEN_LOG")" != "invoked " ]]; then
  echo "FAIL missing maven did not follow a missing jdk"
  echo "jdk=$(cat "$JDK_LOG")"
  echo "maven=$(cat "$MAVEN_LOG")"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: ok'; then
  echo "FAIL missing maven path did not succeed"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok up.sh installs a missing maven after the jdk"

reset_logs
UP_PATH=$ok_bin
out=$(run_up)
if [[ -e "$JDK_LOG" || -e "$MAVEN_LOG" ]]; then
  echo "FAIL present maven still called an install script"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -qx 'maven: present'; then
  echo "FAIL up.sh did not skip a present maven"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok up.sh skips the install script when maven is present"

reset_logs
UP_PATH=$bad_bin
run_up >/dev/null
if [[ -e "$JDK_LOG" ]]; then
  echo "FAIL a broken mvn reinstalled the jdk"
  exit 1
fi
if [[ "$(cat "$MAVEN_LOG")" != "invoked " ]]; then
  echo "FAIL broken mvn -v did not reinstall"
  exit 1
fi
echo "ok an mvn that fails -v is treated as missing"

reset_logs
UP_PATH=$jdk_bin
run_up --install-only >/dev/null
if [[ "$(cat "$ACCESS_LOG")" != "invoked --install-only" ]]; then
  echo "FAIL --install-only access flags: $(cat "$ACCESS_LOG")"
  exit 1
fi
if [[ "$(cat "$AOS_LOG")" != "invoked --install-only" ]]; then
  echo "FAIL --install-only aos flags: $(cat "$AOS_LOG")"
  exit 1
fi
if [[ -e "$JDK_LOG" ]]; then
  echo "FAIL --install-only reinstalled a present jdk"
  exit 1
fi
if [[ "$(cat "$MAVEN_LOG")" != "invoked " ]]; then
  echo "FAIL --install-only skipped the maven install"
  exit 1
fi
echo "ok --install-only still installs a missing maven"

reset_logs
run_up --access-only >/dev/null
if [[ ! -f "$ACCESS_LOG" || -e "$AOS_LOG" || -e "$JDK_LOG" || "$(cat "$MAVEN_LOG")" != "invoked " ]]; then
  echo "FAIL --access-only did not still install a missing maven"
  exit 1
fi
echo "ok --access-only still installs a missing maven"

reset_logs
run_up --aos-only >/dev/null
if [[ -e "$ACCESS_LOG" || ! -f "$AOS_LOG" || -e "$JDK_LOG" || "$(cat "$MAVEN_LOG")" != "invoked " ]]; then
  echo "FAIL --aos-only did not still install a missing maven"
  exit 1
fi
echo "ok --aos-only still installs a missing maven"

reset_logs
MAVEN_RC=6
set +e
out=$(run_up 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 6 ]]; then
  echo "FAIL maven failure status was $rc, want 6"
  printf '%s\n' "$out"
  exit 1
fi
if [[ "$(cat "$ACCESS_LOG")" != "invoked " || "$(cat "$AOS_LOG")" != "invoked " ]]; then
  echo "FAIL maven failure skipped a side"
  exit 1
fi
if [[ -e "$JDK_LOG" ]]; then
  echo "FAIL maven failure reinstalled a present jdk"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'ERROR: maven install failed status=6'; then
  echo "FAIL maven failure was not reported"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: failed access=0 aos=0 jdk=0 maven=6'; then
  echo "FAIL maven failure summary missing"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok a maven install failure is reported and fails up.sh"

reset_logs
UP_PATH=$empty_bin
JDK_RC=9
MAVEN_RC=6
set +e
out=$(run_up 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 9 ]]; then
  echo "FAIL first failure status was $rc, want 9"
  printf '%s\n' "$out"
  exit 1
fi
if [[ "$(cat "$JDK_LOG")" != "invoked " || "$(cat "$MAVEN_LOG")" != "invoked " ]]; then
  echo "FAIL jdk failure skipped maven"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: failed access=0 aos=0 jdk=9 maven=6'; then
  echo "FAIL combined jdk and maven summary missing"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok when jdk and maven fail, maven still runs and the jdk status wins"

reset_logs
UP_PATH=$jdk_bin
ACCESS_RC=3
JDK_RC=0
MAVEN_RC=6
set +e
out=$(run_up 2>&1)
rc=$?
set -e
if [[ "$rc" -ne 3 ]]; then
  echo "FAIL first failure status was $rc, want 3"
  printf '%s\n' "$out"
  exit 1
fi
if [[ "$(cat "$AOS_LOG")" != "invoked " || "$(cat "$MAVEN_LOG")" != "invoked " ]]; then
  echo "FAIL access failure skipped aos or maven"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: failed access=3 aos=0 jdk=0 maven=6'; then
  echo "FAIL combined failure summary missing"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok when access and maven fail, maven still runs and the gate status wins"

reset_logs
ACCESS_RC=4
AOS_RC=0
JDK_RC=0
MAVEN_RC=0
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
if [[ -e "$AOS_LOG" || -e "$JDK_LOG" || -e "$MAVEN_LOG" ]]; then
  echo "FAIL stop-on-error still ran aos, jdk, or maven"
  exit 1
fi
echo "ok --stop-on-error returns before the maven step"

reset_logs
ACCESS_RC=0
UP_PATH=$jdk_bin
MAVEN_INSTALL=$TMP/missing-maven.sh
set +e
out=$(run_up 2>&1)
rc=$?
set -e
MAVEN_INSTALL=$TMP/maven-install.sh
if [[ "$rc" -ne 127 ]]; then
  echo "FAIL missing maven script status was $rc"
  printf '%s\n' "$out"
  exit 1
fi
if [[ "$(cat "$ACCESS_LOG")" != "invoked " || "$(cat "$AOS_LOG")" != "invoked " ]]; then
  echo "FAIL missing maven script skipped a side"
  exit 1
fi
if [[ -e "$JDK_LOG" ]]; then
  echo "FAIL missing maven script reinstalled a present jdk"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'maven install entry not executable'; then
  echo "FAIL missing maven script was not reported"
  printf '%s\n' "$out"
  exit 1
fi
if ! printf '%s\n' "$out" | grep -q 'up: failed access=0 aos=0 jdk=0 maven=127'; then
  echo "FAIL missing maven script summary missing"
  printf '%s\n' "$out"
  exit 1
fi
echo "ok a missing maven script is status 127"

reset_logs
UP_PATH=$empty_bin
run_up --help >/dev/null
if [[ -e "$ACCESS_LOG" || -e "$AOS_LOG" || -e "$JDK_LOG" || -e "$MAVEN_LOG" ]]; then
  echo "FAIL --help invoked a side or an install script"
  exit 1
fi
help=$(run_up --help)
if ! printf '%s\n' "$help" | grep -q 'MAVEN_PACKAGE'; then
  echo "FAIL up.sh --help missing MAVEN_PACKAGE"
  exit 1
fi
if ! printf '%s\n' "$help" | grep -q 'apt package (default: maven)'; then
  echo "FAIL up.sh --help missing default maven package"
  exit 1
fi
echo "ok up.sh --help mentions the maven package"
