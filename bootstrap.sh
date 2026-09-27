#!/usr/bin/env bash
# Backward-compatible name for ./up.sh.
# Forwards every argument (--install-only, --no-watchdogs, --skip-clone, ...).
here=$(cd "$(dirname "$0")" && pwd) || exit 1
exec "$here/up.sh" "$@"
