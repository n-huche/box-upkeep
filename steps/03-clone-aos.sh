#!/usr/bin/env bash
# Git-clone the AOS repo when AOS_ROOT has no .git.
# URL: AOS_REPO_URL, else config/aos.env, else https://github.com/n-huche/aos.git.
# --skip-clone leaves the tree alone. Does not clone private aos/user.

step_clone_aos() {
  local parent
  if [[ "${SKIP_CLONE:-0}" -eq 1 ]]; then
    echo "clone: skipped (--skip-clone)"
    return 0
  fi
  if [[ -z "${AOS_REPO_URL:-}" ]]; then
    echo "ERROR: AOS_REPO_URL is empty" >&2
    return 1
  fi
  if [[ -z "${AOS_ROOT:-}" ]]; then
    echo "ERROR: AOS_ROOT is empty" >&2
    return 1
  fi
  if [[ -e "$AOS_ROOT/.git" ]]; then
    echo "git: present $AOS_ROOT"
    return 0
  fi
  if [[ -e "$AOS_ROOT" ]]; then
    echo "ERROR: $AOS_ROOT exists and is not a git clone" >&2
    return 1
  fi
  parent=$(dirname "$AOS_ROOT")
  if [[ ! -d "$parent" ]]; then
    echo "ERROR: parent directory missing: $parent" >&2
    return 1
  fi
  if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is not installed" >&2
    return 1
  fi
  echo "git: clone $AOS_REPO_URL -> $AOS_ROOT"
  GIT_TERMINAL_PROMPT=0 git clone "$AOS_REPO_URL" "$AOS_ROOT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  box_upkeep_parse_aos_args "$@"
  step_clone_aos
fi
