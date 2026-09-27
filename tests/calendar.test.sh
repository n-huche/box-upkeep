#!/usr/bin/env bash
# Calendar step against a mock `aos` binary. Does not install a real crontab.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export AOS_ROOT="$TMP/aos"
mkdir -p "$AOS_ROOT/scripts"
cat > "$AOS_ROOT/scripts/aos" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  up)
    printf '%s\n' "${MOCK_OUT:-crontab-installed}"
    exit "${MOCK_RC:-0}"
    ;;
  *)
    echo "unexpected aos args: $*" >&2
    exit 9
    ;;
esac
EOF
chmod +x "$AOS_ROOT/scripts/aos"

export MOCK_LOG=$TMP/aos.log
# shellcheck source=../aos/lib/common.sh
source "$ROOT/aos/lib/common.sh"
# shellcheck source=../aos/steps/04-calendar.sh
source "$ROOT/aos/steps/04-calendar.sh"

MOCK_OUT=crontab-installed MOCK_RC=0 step_calendar >/dev/null
if ! grep -qx 'up' "$MOCK_LOG"; then
  echo "FAIL calendar did not call aos up"
  exit 1
fi
echo "ok calendar calls aos up"

: > "$MOCK_LOG"
export MOCK_OUT=crontab-error:nope
set +e
step_calendar >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL crontab-error was ignored"
  exit 1
fi
echo "ok crontab-error fails the step"

: > "$MOCK_LOG"
export MOCK_OUT=crontab-unavailable
set +e
step_calendar >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL crontab-unavailable was ignored"
  exit 1
fi
echo "ok crontab-unavailable fails the step"

rm -f "$AOS_ROOT/scripts/aos"
set +e
step_calendar >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL missing aos binary was accepted"
  exit 1
fi
echo "ok missing aos binary fails the step"
