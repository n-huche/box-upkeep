#!/usr/bin/env bash
# Ensure declared private paths have the declared modes.
# List file: PERMS_LIST (default ./perms/perms.txt).
# Each non-comment line: <octal mode> <absolute path>
# If the path exists and its mode differs, chmod it and print
# `perms: fixed <mode> <path>`. Matching mode prints `perms: ok <path>`.
# Missing paths warn and continue. Symlinks are skipped with a WARN.
# Never create, copy, move, read, or delete the paths (they hold secrets).
# Never follow symlinks.
# ./up.sh runs this after python venvs and before the tickets step.
# Exit non-zero only on a malformed line or a chmod failure.

set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(dirname "$(/usr/bin/realpath "$0")")/../lib/common.sh"

list=${PERMS_LIST:-}

if [[ -z "$list" ]]; then
  echo "ERROR: PERMS_LIST is empty" >&2
  exit 1
fi
if [[ ! -f "$list" ]]; then
  echo "ERROR: perms list not found: $list" >&2
  exit 1
fi

failed=0
while IFS= read -r line || [[ -n "$line" ]]; do
  line=${line%%#*}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  [[ -z "$line" ]] && continue

  # shellcheck disable=SC2086
  set -- $line
  if [[ "$#" -ne 2 ]]; then
    echo "ERROR: perms list line needs <octal mode> <absolute path>: $line" >&2
    failed=1
    continue
  fi
  mode=$1
  path=$2

  if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then
    echo "ERROR: perms list mode is not octal: $line" >&2
    failed=1
    continue
  fi
  if [[ "$path" != /* ]]; then
    echo "ERROR: perms list path is not absolute: $line" >&2
    failed=1
    continue
  fi

  if [[ -L "$path" ]]; then
    echo "WARN: perms: symlink $path" >&2
    continue
  fi
  if [[ ! -e "$path" ]]; then
    echo "WARN: perms: missing $path" >&2
    continue
  fi

  current=$(stat -c '%a' -- "$path")
  if [[ $((8#$current)) -eq $((8#$mode)) ]]; then
    echo "perms: ok $path"
    continue
  fi

  if ! chmod -- "$mode" "$path"; then
    echo "ERROR: chmod $mode failed for $path" >&2
    failed=1
    continue
  fi
  echo "perms: fixed $mode $path"
done < "$list"

if [[ "$failed" -ne 0 ]]; then
  exit 1
fi
