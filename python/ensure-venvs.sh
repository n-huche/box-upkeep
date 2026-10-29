#!/usr/bin/env bash
# Recreate declared Python venvs when they are missing or unhealthy.
# List file: PYTHON_VENVS_LIST (default ./python/venvs.txt).
# Each non-comment line: <venv path> <pkg> [<pkg>...]
#   or <venv path> -r <requirements file> (absolute path)
#   or a mix of package tokens plus one -r <file>.
# Healthy = <venv>/bin/python -c 'import sys' runs and
# <venv>/bin/pip show <pkg> succeeds for every declared package
# (from loose tokens and, for -r, every requirement name in the file:
# strip comments, blank lines, env markers after ;, extras [..], and
# version specifiers ==, >=, <=, ~=, !=, <, >).
# Unhealthy: ensure python3 and python3-venv, then
# python3 -m venv --clear <path> and pip install the packages
# (pip install -r <file> plus any loose packages).
# A missing requirements file is an error for that line; the venv is not touched.
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

# Print the distribution name from one requirements line, or nothing.
box_upkeep_req_name() {
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
  # Drop extras: name[extra,...]
  if [[ "$line" == *"["* ]]; then
    line="${line%%\[*}"
  fi
  line=${line%"${line##*[![:space:]]}"}
  # Drop version specifiers from the first operator onward.
  line=$(printf '%s\n' "$line" | sed -E 's/[[:space:]]*(==|>=|<=|~=|!=|<|>).*//')
  line=${line%"${line##*[![:space:]]}"}
  [[ -n "$line" ]] && printf '%s\n' "$line"
}

# Print one distribution name per requirements-file line (stdout).
box_upkeep_req_names_from_file() {
  local file=$1
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    box_upkeep_req_name "$line"
  done < "$file"
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

# Recreate venv and pip install "$@". Post-install health is checked by the caller.
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
  if [[ "$#" -gt 0 ]]; then
    if ! "$path/bin/pip" install "$@"; then
      echo "ERROR: pip install failed for $path" >&2
      return 1
    fi
  fi
  return 0
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
    echo "ERROR: venvs list line needs <path> <pkg> [...] or -r <file>: $line" >&2
    failed=1
    continue
  fi
  venv_path=$1
  shift

  req_file=
  loose_pkgs=()
  parse_ok=1
  while [[ "$#" -gt 0 ]]; do
    if [[ "$1" == "-r" ]]; then
      if [[ -n "$req_file" ]]; then
        echo "ERROR: venvs list line has more than one -r: $line" >&2
        parse_ok=0
        break
      fi
      if [[ "$#" -lt 2 ]]; then
        echo "ERROR: venvs list -r needs a requirements file: $line" >&2
        parse_ok=0
        break
      fi
      req_file=$2
      shift 2
      continue
    fi
    loose_pkgs+=("$1")
    shift
  done
  if [[ "$parse_ok" -eq 0 ]]; then
    failed=1
    continue
  fi
  if [[ -z "$req_file" && "${#loose_pkgs[@]}" -eq 0 ]]; then
    echo "ERROR: venvs list line needs <path> <pkg> [...] or -r <file>: $line" >&2
    failed=1
    continue
  fi

  if [[ -n "$req_file" && ! -f "$req_file" ]]; then
    echo "ERROR: requirements file not found: $req_file" >&2
    failed=1
    continue
  fi

  check_pkgs=()
  if [[ -n "$req_file" ]]; then
    while IFS= read -r req_name || [[ -n "$req_name" ]]; do
      [[ -n "$req_name" ]] && check_pkgs+=("$req_name")
    done < <(box_upkeep_req_names_from_file "$req_file")
  fi
  if [[ "${#loose_pkgs[@]}" -gt 0 ]]; then
    check_pkgs+=("${loose_pkgs[@]}")
  fi

  if box_upkeep_venv_healthy "$venv_path" "${check_pkgs[@]}"; then
    echo "venv: present $venv_path"
    continue
  fi

  install_args=()
  if [[ -n "$req_file" ]]; then
    install_args+=(-r "$req_file")
  fi
  if [[ "${#loose_pkgs[@]}" -gt 0 ]]; then
    install_args+=("${loose_pkgs[@]}")
  fi

  if ! box_upkeep_venv_recreate "$venv_path" "${install_args[@]}"; then
    failed=1
    continue
  fi
  if ! box_upkeep_venv_healthy "$venv_path" "${check_pkgs[@]}"; then
    echo "ERROR: venv still unhealthy after recreate: $venv_path" >&2
    failed=1
    continue
  fi
  echo "venv: installed $venv_path"
done < "$list"

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
