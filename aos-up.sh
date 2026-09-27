#!/usr/bin/env bash
# Thin wrapper. Canonical AOS entry is aos/aos-up.sh.
# Forwards every argument (--install-only, --skip-clone, --no-watchdogs, ...).
here=$(cd "$(dirname "$0")" && pwd) || exit 1
exec "$here/aos/aos-up.sh" "$@"
