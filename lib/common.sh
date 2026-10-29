# Shared paths and flags for ./up.sh, java/install-jdk.sh,
# java/install-maven.sh, gh/install-gh.sh, and docker/ensure-dockerd.sh.
# AOS paths, config, and flags live in aos/lib/common.sh.
# Does not implement the gate. That stays in box-access.

if [[ -z "${BOX_UPKEEP_COMMON_LOADED:-}" ]]; then
  BOX_UPKEEP_COMMON_LOADED=1
  set -euo pipefail
fi

_box_lib=$(dirname "$(/usr/bin/realpath "${BASH_SOURCE[0]}")")
# shellcheck source=../aos/lib/proc.sh
source "$_box_lib/../aos/lib/proc.sh"
unset _box_lib

box_upkeep_set_paths() {
  local lib_dir
  lib_dir=$(box_upkeep_script_dir "${BASH_SOURCE[0]}")
  BOX_LIB_DIR=$lib_dir
  REPO=$(box_upkeep_realpath "$lib_dir/..")
  HOME_BOX="${HOME_BOX:-/home/box}"
  INSTALL_ONLY="${INSTALL_ONLY:-0}"
  NO_WATCHDOGS="${NO_WATCHDOGS:-0}"
  SKIP_CLONE="${SKIP_CLONE:-0}"
  ACCESS_ONLY="${ACCESS_ONLY:-0}"
  AOS_ONLY="${AOS_ONLY:-0}"
  STOP_ON_ERROR="${STOP_ON_ERROR:-0}"
  box_upkeep_load_access_config
  if [[ -z "${BOX_ACCESS_UP:-}" ]]; then
    # Sibling of this checkout's real path, not of a symlink used to invoke it.
    BOX_ACCESS_UP="$(dirname "$REPO")/box-access/up.sh"
  fi
  if [[ -z "${AOS_UP:-}" ]]; then
    AOS_UP="$REPO/aos/aos-up.sh"
  fi
  if [[ -z "${JDK_INSTALL:-}" ]]; then
    JDK_INSTALL="$REPO/java/install-jdk.sh"
  fi
  : "${JDK_PACKAGE:=default-jdk}"
  if [[ -z "${MAVEN_INSTALL:-}" ]]; then
    MAVEN_INSTALL="$REPO/java/install-maven.sh"
  fi
  : "${MAVEN_PACKAGE:=maven}"
  if [[ -z "${GH_INSTALL:-}" ]]; then
    GH_INSTALL="$REPO/gh/install-gh.sh"
  fi
  : "${GH_EXPECTED_USER:=n-huche}"
  if [[ -z "${DOCKERD_ENSURE:-}" ]]; then
    DOCKERD_ENSURE="$REPO/docker/ensure-dockerd.sh"
  fi
  : "${DOCKER_PACKAGE:=docker.io}"
  : "${TICKETS_CLI:=/workspace/tickets/tickets}"
  if [[ -z "${RUN_ENSURE:-}" ]]; then
    RUN_ENSURE="$REPO/run/ensure-run.sh"
  fi
  if [[ -z "${GH_CONFIG_DIR:-}" ]]; then
    GH_CONFIG_DIR="${HOME_BOX}/.config/gh"
  fi
  if [[ -z "${BOX_ACCESS_SECRETS:-}" ]]; then
    BOX_ACCESS_SECRETS="${HOME_BOX}/.config/box-access/secrets.env"
  fi
  export BOX_ACCESS_UP AOS_UP HOME_BOX
  export JDK_INSTALL JDK_PACKAGE
  export MAVEN_INSTALL MAVEN_PACKAGE
  export GH_INSTALL GH_EXPECTED_USER GH_CONFIG_DIR BOX_ACCESS_SECRETS
  export DOCKERD_ENSURE DOCKER_PACKAGE RUN_ENSURE TICKETS_CLI
}

# aos/config/aos.env may set BOX_ACCESS_UP when it is not already exported.
# AOS_REPO_URL, AOS_ROOT, and BOX_TZ are applied by aos/lib/common.sh.
# Other keys are left for that file so an unknown key is warned about once.
box_upkeep_load_access_config() {
  local file="$REPO/aos/config/aos.env"
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
    [[ "$key" == "BOX_ACCESS_UP" ]] || continue
    if [[ -z "${BOX_ACCESS_UP:-}" ]]; then
      printf -v BOX_ACCESS_UP '%s' "$val"
      export BOX_ACCESS_UP
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

# Maven is present when mvn -v runs.
# A missing or broken binary fails the check and does not abort the caller.
box_upkeep_maven_present() {
  command -v mvn >/dev/null 2>&1 || return 1
  mvn -v >/dev/null 2>&1 || return 1
}

# GitHub CLI is present when gh --version runs.
# A missing or broken binary fails the check and does not abort the caller.
box_upkeep_gh_present() {
  command -v gh >/dev/null 2>&1 || return 1
  gh --version >/dev/null 2>&1 || return 1
}

# Run gh with the persisted config and without ambient tokens.
# gh auth status treats GH_TOKEN / GITHUB_TOKEN as a login, which would hide
# an empty /home/box/.config/gh. The child environment drops those variables.
box_upkeep_gh_cmd() {
  local config_dir=$1
  shift
  (
    unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
    export GH_CONFIG_DIR="$config_dir"
    gh "$@"
  )
}

# Print the active github.com login, or return 1.
# Stdout is only a GitHub username. Token-shaped text is rejected.
box_upkeep_gh_login_name() {
  local config_dir=$1 login rc
  set +e
  login=$(box_upkeep_gh_cmd "$config_dir" auth status \
    --hostname github.com \
    --active \
    --json hosts \
    --jq '.hosts["github.com"][] | select(.state=="success") | .login' 2>/dev/null)
  rc=$?
  set -e
  login=${login%%$'\n'*}
  login=${login%$'\r'}
  if [[ "$rc" -ne 0 || ${#login} -gt 39 || ! "$login" =~ ^[A-Za-z0-9]([A-Za-z0-9]|-[A-Za-z0-9])*$ ]]; then
    return 1
  fi
  printf '%s' "$login"
}

# Read GH_TOKEN from the box-access secrets file. Do not source the file:
# it also holds other secrets, and sourcing would expand them under set -x.
# Prints the value on stdout. Callers disable xtrace before calling.
box_upkeep_read_gh_token() {
  local file=$1 line val xtrace=0
  case $- in *x*) xtrace=1; set +x ;; esac
  if [[ ! -f "$file" || ! -r "$file" ]]; then
    if [[ "$xtrace" -eq 1 ]]; then set -x; fi
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" == export[[:space:]]* ]]; then
      line=${line#export}
      line=${line#"${line%%[![:space:]]*}"}
    fi
    [[ "$line" == GH_TOKEN=* ]] || continue
    val=${line#GH_TOKEN=}
    if [[ ${#val} -ge 2 && "$val" == \"*\" && "$val" == *\" ]]; then
      val=${val:1:${#val}-2}
    elif [[ ${#val} -ge 2 && "$val" == \'*\' && "$val" == *\' ]]; then
      val=${val:1:${#val}-2}
    fi
    if [[ -z "$val" ]]; then
      unset val
      continue
    fi
    printf '%s' "$val"
    unset val line
    return 0
  done < "$file"
  unset val line
  if [[ "$xtrace" -eq 1 ]]; then set -x; fi
  return 1
}

# Pipe the secrets-file GH_TOKEN into gh auth login. Never print the value.
# Returns 0 on success, 2 when the token is absent, 1 when login fails.
# Restores the caller's xtrace and errexit. A failing return must not run
# under set -e, or the caller exits before it can warn.
box_upkeep_gh_login_with_token() {
  local config_dir=$1 secrets=$2 token rc xtrace=0 errexit=0
  local -a pipe_rc
  case $- in *x*) xtrace=1 ;; esac
  case $- in *e*) errexit=1 ;; esac
  set +x
  set +e
  token=$(box_upkeep_read_gh_token "$secrets") || true
  if [[ -z "${token:-}" ]]; then
    unset token
    if [[ "$errexit" -eq 1 ]]; then set -e; fi
    if [[ "$xtrace" -eq 1 ]]; then set -x; fi
    return 2
  fi
  printf '%s\n' "$token" | box_upkeep_gh_cmd "$config_dir" auth login \
    --hostname github.com --git-protocol https --with-token >/dev/null 2>&1
  pipe_rc=("${PIPESTATUS[@]}")
  unset token
  if [[ "$errexit" -eq 1 ]]; then set -e; fi
  if [[ "$xtrace" -eq 1 ]]; then set -x; fi
  rc=${pipe_rc[1]:-1}
  if [[ "${pipe_rc[0]:-1}" -ne 0 || "$rc" -ne 0 ]]; then
    return 1
  fi
  return 0
}

box_upkeep_gh_warn() {
  local reason=$1 config_dir=$2
  echo "WARNING: ${reason}. The login in ${config_dir} survives a wipe. Run: GH_CONFIG_DIR=${config_dir} gh auth login --hostname github.com" >&2
}

box_upkeep_gh_setup_git() {
  local config_dir=$1 login=$2 rc
  set +e
  box_upkeep_gh_cmd "$config_dir" auth setup-git --hostname github.com >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    box_upkeep_gh_warn "gh auth setup-git failed for github.com" "$config_dir"
    return 0
  fi
  echo "gh: logged in as ${login}"
}

# Check github.com on the persisted config. Install failures are separate.
# A missing login, a missing GH_TOKEN, a failed token login, or an unexpected
# account warns and returns 0. The token is never printed.
box_upkeep_gh_auth() {
  local config_dir expected secrets login token_rc
  config_dir=${GH_CONFIG_DIR:-${HOME_BOX}/.config/gh}
  expected=${GH_EXPECTED_USER:-n-huche}
  secrets=${BOX_ACCESS_SECRETS:-${HOME_BOX}/.config/box-access/secrets.env}

  if login=$(box_upkeep_gh_login_name "$config_dir"); then
    if [[ "$login" == "$expected" ]]; then
      box_upkeep_gh_setup_git "$config_dir" "$login"
      return 0
    fi
    box_upkeep_gh_warn "gh on github.com is logged in as ${login}, expected ${expected}" "$config_dir"
    return 0
  fi

  set +e
  box_upkeep_gh_login_with_token "$config_dir" "$secrets"
  token_rc=$?
  set -e
  if [[ "$token_rc" -eq 2 ]]; then
    box_upkeep_gh_warn "gh is not logged in to github.com" "$config_dir"
    return 0
  fi
  if [[ "$token_rc" -ne 0 ]]; then
    box_upkeep_gh_warn "gh auth login failed for github.com" "$config_dir"
    return 0
  fi

  if login=$(box_upkeep_gh_login_name "$config_dir"); then
    if [[ "$login" == "$expected" ]]; then
      box_upkeep_gh_setup_git "$config_dir" "$login"
      return 0
    fi
    box_upkeep_gh_warn "gh on github.com is logged in as ${login}, expected ${expected}" "$config_dir"
    return 0
  fi
  box_upkeep_gh_warn "gh auth login failed for github.com" "$config_dir"
  return 0
}

box_upkeep_usage_up() {
  cat <<'EOF'
Usage: ./up.sh [--install-only] [--no-watchdogs] [--skip-clone]
               [--access-only] [--aos-only] [--stop-on-error] [--help]

Cold start: run ./run/ensure-run.sh (/var/run -> /run symlink),
then ../box-access/up.sh, then ./aos/aos-up.sh. If java or javac
does not run, install a JDK afterward (JDK_PACKAGE, default default-jdk).
If mvn -v does not run, install Maven after the JDK (MAVEN_PACKAGE, default
maven). If gh --version does not run, install GitHub CLI after Maven from
the official apt repository. docker/ensure-dockerd.sh then installs
docker.io (DOCKER_PACKAGE) and docker-cli when dockerd or docker is missing,
starts dockerd if it is down, and starts the dockerd keep-alive loop.
This repo does not implement the gate. The gate stays in that orchestrator.

  ./run/ensure-run.sh    /var/run -> /run symlink (first, every flag)
  ../box-access/up.sh    the gate (packages, identity, keep-alive live there)
  ./aos/aos-up.sh        timezone, cronie, AOS clone, calendar, cron/AOS loops
  java/install-jdk.sh    JDK when java or javac does not run (after both sides)
  java/install-maven.sh  Maven when mvn -v does not run (after the JDK)
  gh/install-gh.sh       gh when gh --version does not run (after Maven)
  docker/ensure-dockerd.sh  dockerd after GitHub CLI (install, start, watchdog)

Failure policy: the gate and AOS both run. The JDK step runs after them
when java or javac is missing, including with --install-only, --access-only,
and --aos-only. The Maven step runs after the JDK on those same flags.
The GitHub CLI step runs after Maven on those same flags. The Docker step
runs after GitHub CLI on those same flags. A failing side is reported and
the others still run. The exit status is the first non-zero status
(access, then aos, then jdk, then maven, then gh, then docker, then run). A missing
github.com login, a missing GH_TOKEN, a failed token login, or an
unexpected account is a warning and does not change the exit status.
  --stop-on-error  if box-access/up.sh fails, do not run aos/aos-up.sh
                   (the JDK, Maven, GitHub CLI, and Docker steps are not reached either)
  --access-only    box-access/up.sh only; a missing JDK, Maven, or gh is still installed; dockerd still starts
  --aos-only       AOS only; a missing JDK, Maven, or gh is still installed; dockerd still starts
  --install-only   forwarded to both orchestrators; a missing JDK, Maven, or gh is still installed; dockerd still starts
  --no-watchdogs   forwarded to both orchestrators; dockerd still starts once, without its keep-alive loop
  --skip-clone     aos/aos-up.sh only (not forwarded to box-access)
  --help           show this help

  BOX_ACCESS_UP      gate entry (default: ../box-access/up.sh next to this checkout)
  AOS_UP             AOS entry (default: ./aos/aos-up.sh)
  JDK_INSTALL        JDK script (default: ./java/install-jdk.sh)
  JDK_PACKAGE        apt package (default: default-jdk)
  MAVEN_INSTALL      Maven script (default: ./java/install-maven.sh)
  MAVEN_PACKAGE      apt package (default: maven)
  GH_INSTALL         GitHub CLI script (default: ./gh/install-gh.sh)
  GH_EXPECTED_USER   account that may run gh auth setup-git (default: n-huche)
  GH_CONFIG_DIR      persisted gh config (default: /home/box/.config/gh)
  BOX_ACCESS_SECRETS secrets file; only a GH_TOKEN line is read
                     (default: /home/box/.config/box-access/secrets.env)
  DOCKERD_ENSURE     dockerd script (default: ./docker/ensure-dockerd.sh)
  DOCKER_PACKAGE     apt package for dockerd (default: docker.io); docker-cli is always installed with it
  RUN_ENSURE         runtime-directory script (default: ./run/ensure-run.sh)
  TICKETS_CLI        ticket monitor CLI; runs "service ensure" last
                     (default: /workspace/tickets/tickets); missing or failing only warns
EOF
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
