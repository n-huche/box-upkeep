#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
readme=$ROOT/README.md
entry=$ROOT/up.sh
aos=$ROOT/aos/aos-up.sh
aos_wrap=$ROOT/aos-up.sh
wrapper=$ROOT/bootstrap.sh

need() {
  local file=$1 needle=$2
  if ! grep -qF -- "$needle" "$file"; then
    echo "FAIL missing [$needle] in ${file#"$ROOT"/}"
    exit 1
  fi
}

need "$readme" "cd /workspace/box-upkeep && ./up.sh"
need "$readme" "VM console"
need "$readme" "No systemd"
need "$readme" "kills those loops"
need "$readme" "./aos-up.sh"
need "$readme" "aos/aos-up.sh"
need "$readme" "exec ./aos/aos-up.sh"
need "$readme" "./bootstrap.sh"
need "$readme" "lib/common.sh"
need "$readme" "aos/lib/common.sh"
need "$readme" "aos/config/aos.env"
need "$readme" "aos/steps/01-timezone.sh"
need "$readme" "aos/steps/02-cronie.sh"
need "$readme" "aos/steps/03-clone-aos.sh"
need "$readme" "aos/steps/04-calendar.sh"
need "$readme" "aos/steps/05-watchdogs.sh"
need "$readme" "aos/units/cron-watchdog.sh"
need "$readme" "aos/units/aos-watchdog.sh"
need "$readme" "aos/packages.txt"
need "$readme" "America/Sao_Paulo"
need "$readme" "cronie"
need "$readme" "https://github.com/n-huche/aos.git"
need "$readme" "/workspace/aos"
need "$readme" "--install-only"
need "$readme" "--no-watchdogs"
need "$readme" "--skip-clone"
need "$readme" "--stop-on-error"
need "$readme" "--access-only"
need "$readme" "--aos-only"
need "$readme" "BOX_ACCESS_UP"
need "$readme" "not systemd"
need "$readme" "box-access"
need "$entry" "lib/common.sh"
need "$entry" "aos-up.sh"
need "$entry" "--stop-on-error"
need "$entry" "--access-only"
need "$entry" "--aos-only"
need "$aos" "lib/common.sh"
need "$aos" "steps/01-timezone.sh"
need "$aos" "steps/03-clone-aos.sh"
need "$aos" "steps/05-watchdogs.sh"
need "$aos" "--install-only"
need "$aos" "--no-watchdogs"
need "$ROOT/aos/lib/common.sh" "AOS_REPO_URL"
need "$ROOT/aos/lib/common.sh" "https://github.com/n-huche/aos.git"
need "$ROOT/lib/common.sh" "aos/aos-up.sh"
need "$ROOT/aos/steps/03-clone-aos.sh" "git clone"
need "$ROOT/aos/steps/03-clone-aos.sh" "--skip-clone"
need "$ROOT/aos/steps/04-calendar.sh" "up"
need "$ROOT/aos/steps/05-watchdogs.sh" "cron-watchdog.sh"
need "$ROOT/aos/steps/05-watchdogs.sh" "aos-watchdog.sh"
need "$ROOT/aos/steps/01-timezone.sh" "America/Sao_Paulo"
need "$ROOT/aos/config/aos.env" "https://github.com/n-huche/aos.git"
need "$wrapper" "exec"
need "$wrapper" "up.sh"
need "$aos_wrap" "exec"
need "$aos_wrap" "aos/aos-up.sh"
need "$ROOT/aos/units/aos-watchdog.sh" "--watch-only"
need "$ROOT/aos/units/aos-watchdog.sh" "flock -n 9"
need "$ROOT/aos/units/cron-watchdog.sh" "flock -n 9"
need "$ROOT/aos/packages.txt" "cronie"
need "$readme" "java/install-jdk.sh"
need "$readme" "default-jdk"
need "$readme" "JDK_PACKAGE"
need "$readme" "openjdk-21-jdk"
need "$readme" "jdk: present"
need "$entry" "box_upkeep_jdk_present"
need "$entry" "jdk_rc"
need "$ROOT/lib/common.sh" "JDK_PACKAGE"
need "$ROOT/lib/common.sh" "default-jdk"
need "$ROOT/java/install-jdk.sh" "apt-get install"
need "$ROOT/java/install-jdk.sh" "box_upkeep_jdk_present"

if grep -q 'tailscale up' "$entry" || grep -q 'tailscale up' "$aos"; then
  echo "FAIL orchestrators must not run tailscale up"
  exit 1
fi
if grep -q 'apt-get' "$wrapper"; then
  echo "FAIL bootstrap.sh is not a thin wrapper"
  exit 1
fi
if grep -q 'apt-get' "$aos_wrap"; then
  echo "FAIL aos-up.sh is not a thin wrapper"
  exit 1
fi
if [[ -e "$ROOT/start.sh" ]]; then
  echo "FAIL start.sh is still the cold start; up.sh replaced it"
  exit 1
fi
if [[ -e "$ROOT/units/tailscale-watchdog.sh" || -e "$ROOT/units/sshd-watchdog.sh" || -e "$ROOT/units/timezone.sh" ]]; then
  echo "FAIL legacy unit still present"
  exit 1
fi
if [[ -e "$ROOT/aos/units/tailscale-watchdog.sh" || -e "$ROOT/aos/units/sshd-watchdog.sh" || -e "$ROOT/aos/units/timezone.sh" ]]; then
  echo "FAIL legacy unit still present under aos/units"
  exit 1
fi
if find "$ROOT" -name '*.service' -o -name '*.timer' | grep -q .; then
  echo "FAIL systemd unit file in the tree"
  exit 1
fi
echo "ok readme and entrypoints describe the layout"
