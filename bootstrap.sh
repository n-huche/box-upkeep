#!/usr/bin/env bash
# Backward-compatible name for ./up.sh.
# Forwards every argument (--install-only, --no-watchdogs, --skip-clone, ...).
here=$(dirname "$(/usr/bin/realpath "$0")") || exit 1
exec "$here/up.sh" "$@"
