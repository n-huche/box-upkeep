# Paths, config, and flags for aos/aos-up.sh.
# Sourced by the AOS orchestrator and by a step that is executed directly.
# The host orchestrator is ../up.sh. The gate is not implemented here.

if [[ -z "${AOS_UPKEEP_COMMON_LOADED:-}" ]]; then
  AOS_UPKEEP_COMMON_LOADED=1
  set -euo pipefail
fi

aos_upkeep_set_paths() {
  local lib_dir
  lib_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  AOS_LIB_DIR=$lib_dir
  REPO=$(cd "$lib_dir/.." && pwd)
  HOME_BOX="${HOME_BOX:-/home/box}"
  INSTALL_ONLY="${INSTALL_ONLY:-0}"
  NO_WATCHDOGS="${NO_WATCHDOGS:-0}"
  SKIP_CLONE="${SKIP_CLONE:-0}"
  aos_upkeep_load_config
  : "${AOS_REPO_URL:=https://github.com/n-huche/aos.git}"
  : "${AOS_ROOT:=/workspace/aos}"
  : "${BOX_TZ:=America/Sao_Paulo}"
  export AOS_REPO_URL AOS_ROOT BOX_TZ HOME_BOX
}

# config/aos.env sets defaults. An already-exported variable wins.
aos_upkeep_load_config() {
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

aos_upkeep_set_paths

log() {
  printf '%s\n' "$*"
}

box_upkeep_usage_aos() {
  cat <<'EOF'
Usage: ./aos/aos-up.sh [--install-only] [--skip-clone] [--no-watchdogs] [--help]
       ./aos-up.sh     same command from the repo root

Keep AOS alive after a reboot or Update. Sources aos/lib/common.sh, then runs
aos/steps/*.sh in order. AOS only. ./aos-up.sh execs this script.

  --install-only   timezone + cronie, then stop (no clone, crontab, or watchdogs)
  --skip-clone     do not git clone AOS (later steps need AOS_ROOT already)
  --no-watchdogs   do not start the cron and aos keep-alive loops
  --help           show this help

Environment (overrides aos/config/aos.env):
  AOS_REPO_URL     git URL (default https://github.com/n-huche/aos.git)
  AOS_ROOT         checkout path (default /workspace/aos)
  BOX_TZ           host localtime (default America/Sao_Paulo)
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
