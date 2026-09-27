# Shared paths, logging, and flags for ./up.sh and ./aos-up.sh.
# Sourced by the orchestrators and by a step that is executed directly.
# Does not implement the gate. That stays in box-access.

if [[ -z "${BOX_UPKEEP_COMMON_LOADED:-}" ]]; then
  BOX_UPKEEP_COMMON_LOADED=1
  set -euo pipefail
fi

box_upkeep_set_paths() {
  local lib_dir
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  BOX_LIB_DIR=$lib_dir
  REPO=$(cd "$lib_dir/.." && pwd)
  HOME_BOX="${HOME_BOX:-/home/box}"
  INSTALL_ONLY="${INSTALL_ONLY:-0}"
  NO_WATCHDOGS="${NO_WATCHDOGS:-0}"
  SKIP_CLONE="${SKIP_CLONE:-0}"
  ACCESS_ONLY="${ACCESS_ONLY:-0}"
  AOS_ONLY="${AOS_ONLY:-0}"
  STOP_ON_ERROR="${STOP_ON_ERROR:-0}"
  box_upkeep_load_config
  : "${AOS_REPO_URL:=https://github.com/n-huche/aos.git}"
  : "${AOS_ROOT:=/workspace/aos}"
  : "${BOX_TZ:=America/Sao_Paulo}"
  if [[ -z "${BOX_ACCESS_UP:-}" ]]; then
    BOX_ACCESS_UP="$(cd "$REPO/.." && pwd)/box-access/up.sh"
  fi
  if [[ -z "${AOS_UP:-}" ]]; then
    AOS_UP="$REPO/aos-up.sh"
  fi
  if [[ -z "${JDK_INSTALL:-}" ]]; then
    JDK_INSTALL="$REPO/java/install-jdk.sh"
  fi
  : "${JDK_PACKAGE:=default-jdk}"
  export AOS_REPO_URL AOS_ROOT BOX_TZ BOX_ACCESS_UP AOS_UP HOME_BOX
  export JDK_INSTALL JDK_PACKAGE
}

# config/aos.env sets defaults. An already-exported variable wins.
box_upkeep_load_config() {
  local file="$REPO/config/aos.env"
  [[ -f "$file" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [[ -z "$line" ]] && continue
    key=${line%%=*}
    val=${line#*=}
    if [[ "$val" == \"*\" && "$val" == *\" ]]; then
      val=${val:1:${#val}-2}
    fi
    case "$key" in
      AOS_REPO_URL|AOS_ROOT|BOX_TZ|BOX_ACCESS_UP) ;;
      *)
        echo "WARN: ignoring unknown key in config/aos.env: $key" >&2
        continue
        ;;
    esac
    if [[ -z "${!key:-}" ]]; then
      printf -v "$key" '%s' "$val"
      export "$key"
    fi
  done < "$file"
}

box_upkeep_set_paths

log() {
  printf '%s\n' "$*"
}

# A JDK is present when both the runtime and the compiler run.
# A missing or broken binary fails the check and does not abort the caller.
box_upkeep_jdk_present() {
  command -v java >/dev/null 2>&1 || return 1
  command -v javac >/dev/null 2>&1 || return 1
  java -version >/dev/null 2>&1 || return 1
  javac -version >/dev/null 2>&1 || return 1
}

box_upkeep_usage_aos() {
  cat <<'EOF'
Usage: ./aos-up.sh [--install-only] [--skip-clone] [--no-watchdogs] [--help]

Keep AOS alive after a reboot or Update. Sources lib/common.sh, then runs
steps/*.sh in order. AOS only.

  --install-only   timezone + cronie, then stop (no clone, crontab, or watchdogs)
  --skip-clone     do not git clone AOS (later steps need AOS_ROOT already)
  --no-watchdogs   do not start the cron and aos keep-alive loops
  --help           show this help

Environment (overrides config/aos.env):
  AOS_REPO_URL     git URL (default https://github.com/n-huche/aos.git)
  AOS_ROOT         checkout path (default /workspace/aos)
  BOX_TZ           host localtime (default America/Sao_Paulo)
EOF
}

box_upkeep_usage_up() {
  cat <<'EOF'
Usage: ./up.sh [--install-only] [--no-watchdogs] [--skip-clone]
               [--access-only] [--aos-only] [--stop-on-error] [--help]

Cold start: run ../box-access/up.sh, then ./aos-up.sh. If java or javac
does not run, install a JDK afterward (JDK_PACKAGE, default default-jdk).
This repo does not implement the gate. The gate stays in that orchestrator.

  ../box-access/up.sh   the gate (packages, identity, keep-alive live there)
  ./aos-up.sh           timezone, cronie, AOS clone, calendar, cron/AOS loops
  java/install-jdk.sh   JDK when java or javac does not run (after both sides)

Failure policy: the gate and AOS both run. The JDK step runs after them
when java or javac is missing, including with --install-only, --access-only,
and --aos-only. A failing side is reported and the others still run. The
exit status is the first non-zero status (access, then aos, then jdk).
  --stop-on-error  if box-access/up.sh fails, do not run aos-up.sh
                   (the JDK step is not reached either)
  --access-only    box-access/up.sh only; a missing JDK is still installed
  --aos-only       AOS only; a missing JDK is still installed
  --install-only   forwarded to both orchestrators; a missing JDK is still installed
  --no-watchdogs   forwarded to both orchestrators
  --skip-clone     aos-up.sh only (not forwarded to box-access)
  --help           show this help

  BOX_ACCESS_UP    gate entry (default: ../box-access/up.sh)
  AOS_UP           AOS entry (default: ./aos-up.sh)
  JDK_INSTALL      JDK script (default: ./java/install-jdk.sh)
  JDK_PACKAGE      apt package (default: default-jdk)
EOF
}

box_upkeep_parse_aos_args() {
  INSTALL_ONLY=0
  NO_WATCHDOGS=0
  SKIP_CLONE=0
  local arg
  for arg in "$@"; do
    case "$arg" in
      --install-only) INSTALL_ONLY=1 ;;
      --no-watchdogs) NO_WATCHDOGS=1 ;;
      --skip-clone) SKIP_CLONE=1 ;;
      --help|-h)
        box_upkeep_usage_aos
        exit 0
        ;;
      *)
        echo "ERROR: unknown argument: $arg" >&2
        box_upkeep_usage_aos >&2
        exit 1
        ;;
    esac
  done
}

box_upkeep_parse_up_args() {
  INSTALL_ONLY=0
  NO_WATCHDOGS=0
  SKIP_CLONE=0
  ACCESS_ONLY=0
  AOS_ONLY=0
  STOP_ON_ERROR=0
  local arg
  for arg in "$@"; do
    case "$arg" in
      --install-only) INSTALL_ONLY=1 ;;
      --no-watchdogs) NO_WATCHDOGS=1 ;;
      --skip-clone) SKIP_CLONE=1 ;;
      --access-only) ACCESS_ONLY=1 ;;
      --aos-only) AOS_ONLY=1 ;;
      --stop-on-error) STOP_ON_ERROR=1 ;;
      --help|-h)
        box_upkeep_usage_up
        exit 0
        ;;
      *)
        echo "ERROR: unknown argument: $arg" >&2
        box_upkeep_usage_up >&2
        exit 1
        ;;
    esac
  done
  if [[ "$ACCESS_ONLY" -eq 1 && "$AOS_ONLY" -eq 1 ]]; then
    echo "ERROR: --access-only and --aos-only cannot be combined" >&2
    exit 1
  fi
}
