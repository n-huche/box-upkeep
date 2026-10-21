#!/usr/bin/env bash
# Runtime directories a fresh image may get wrong. ./up.sh runs this first,
# before the gate: /var/run must be a symlink to /run. A non-zero exit is
# reported there, and the other sides still run. Idempotent: a box that is
# already right is a no-op.

set -euo pipefail

# shellcheck source=lib.sh
source "$(dirname "$(/usr/bin/realpath "$0")")/lib.sh"

box_upkeep_ensure_var_run
