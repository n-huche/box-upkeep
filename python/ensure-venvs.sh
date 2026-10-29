#!/usr/bin/env bash
# Recreate declared Python venvs when they are missing or unhealthy.
# List file: PYTHON_VENVS_LIST (default ./python/venvs.txt).
# Each non-comment line: <venv path> <pkg> [<pkg>...]
# Healthy = <venv>/bin/python -c 'import sys' runs and
# <venv>/bin/pip show <pkg> succeeds for every declared package.
# Unhealthy: ensure python3 and python3-venv, then
# python3 -m venv --clear <path> and pip install the packages.
# Parent directory is created mode 700 only when missing.
# Sibling files in the parent (secrets, tokens, scripts) are never touched.
# ./up.sh runs this after dockerd and before the tickets step.
# A non-zero exit is reported there and counts toward the first non-zero status.

set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(dirname "$(/usr/bin/realpath "$0")")/../lib/common.sh"

list=${PYTHON_VENVS_LIST:-}

if [[ -z "$list" ]]; then
  echo "ERROR: PYTHON_VENVS_LIST is empty" >&2
  exit 1
fi
if [[ ! -f "$list" ]]; then
  echo "ERROR: python venvs list not found: $list" >&2
  exit 1
fi

box_upkeep_python3_ready() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 -c 'import venv' >/dev/null 2>&1 || return 1
}

box_upkeep_ensure_python3() {
  if box_upkeep_python3_ready; then
    return 0
  fi
  echo "python-install: python3 python3-venv"
  if ! sudo apt-get update -y; then
    echo "ERROR: apt-get update failed while installing python3 python3-venv" >&2
    return 1
  fi
  if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv; then
    echo "ERROR: apt-get install failed for python3 python3-venv" >&2
    return 1
  fi
  if ! box_upkeep_python3_ready; then
    echo "ERROR: python3 python3-venv installed but python3 -m venv still unavailable" >&2
    return 1
  fi
  echo "python: installed python3 python3-venv"
}

box_upkeep_venv_healthy() {
  local path=$1
  shift
  local pkg
  [[ -x "$path/bin/python" ]] || return 1
  "$path/bin/python" -c 'import sys' >/dev/null 2>&1 || return 1
  [[ -x "$path/bin/pip" ]] || return 1
  for pkg in "$@"; do
    "$path/bin/pip" show "$pkg" >/dev/null 2>&1 || return 1
  done
  return 0
}

box_upkeep_venv_recreate() {
  local path=$1
  shift
  local parent
  parent=$(dirname "$path")
  if [[ ! -d "$parent" ]]; then
    mkdir -m 700 -p "$parent"
  fi
  if ! box_upkeep_ensure_python3; then
    return 1
  fi
  echo "venv: recreate $path"
  if ! python3 -m venv --clear "$path"; then
    echo "ERROR: python3 -m venv --clear failed for $path" >&2
    return 1
  fi
  if ! "$path/bin/pip" install "$@"; then
    echo "ERROR: pip install failed for $path" >&2
    return 1
  fi
  if ! box_upkeep_venv_healthy "$path" "$@"; then
    echo "ERROR: venv still unhealthy after recreate: $path" >&2
    return 1
  fi
  echo "venv: installed $path"
}

failed=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line=${line%%#*}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  [[ -z "$line" ]] && continue

  # shellcheck disable=SC2086
  set -- $line
  if [[ "$#" -lt 2 ]]; then
    echo "ERROR: venvs list line needs <path> <pkg> [...]: $line" >&2
    failed=1
    continue
  fi
  venv_path=$1
  shift

  if box_upkeep_venv_healthy "$venv_path" "$@"; then
    echo "venv: present $venv_path"
    continue
  fi
  if ! box_upkeep_venv_recreate "$venv_path" "$@"; then
    failed=1
  fi
done < "$list"

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
