#!/usr/bin/env bash
# Calendar step against a mock `aos` binary. Does not install a real crontab.
set -euo pipefail

ROOT=$(realpath "$(dirname "$0")/..")
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

# Symlink checkout: aos up and the installed crontab see the real path.
real_aos=$TMP/aos-real
link_aos=$TMP/aos-link
mkdir -p "$real_aos/scripts" "$real_aos/logs"
ln -s "$real_aos" "$link_aos"
CRON_FILE=$TMP/crontab.txt
export CRON_FILE
cat > "$CRON_FILE" << EOF
CRON_TZ=America/Sao_Paulo
AOS_ROOT=$link_aos
0 0 * * * $link_aos/scripts/aos daily-close >> $link_aos/logs/daily-close.log 2>&1
EOF
cat > "$TMP/crontab" << 'EOF'
#!/usr/bin/env bash
file=${CRON_FILE:?}
if [[ "${1:-}" == "-l" ]]; then
  cat "$file"
  exit 0
fi
if [[ "${1:-}" == "-" ]]; then
  cat > "$file"
  exit 0
fi
echo "unexpected crontab args: $*" >&2
exit 1
EOF
chmod +x "$TMP/crontab"
cat > "$real_aos/scripts/aos" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$AOS_ROOT" > "$AOS_SEEN"
printf '%s\n' "$*" >> "$MOCK_LOG"
printf '%s\n' "${MOCK_OUT:-crontab-installed}"
exit "${MOCK_RC:-0}"
EOF
chmod +x "$real_aos/scripts/aos"
export AOS_SEEN=$TMP/aos-seen AOS_ROOT=$link_aos MOCK_LOG=$TMP/cron-aos.log
export MOCK_OUT=crontab-installed MOCK_RC=0
: > "$MOCK_LOG"
PATH="$TMP:$PATH" step_calendar >/dev/null
seen=$(cat "$AOS_SEEN")
if [[ "$seen" != "$real_aos" ]]; then
  echo "FAIL calendar passed AOS_ROOT=$seen, want $real_aos"
  exit 1
fi
if ! grep -q "AOS_ROOT=$real_aos" "$CRON_FILE"; then
  echo "FAIL crontab did not store the canonical AOS root"
  cat "$CRON_FILE"
  exit 1
fi
if grep -q "$link_aos" "$CRON_FILE"; then
  echo "FAIL crontab still has the symlink path"
  cat "$CRON_FILE"
  exit 1
fi
if ! grep -q "$real_aos/scripts/aos daily-close" "$CRON_FILE"; then
  echo "FAIL crontab command was not rewritten to the real aos binary"
  cat "$CRON_FILE"
  exit 1
fi
echo "ok calendar crontab stores the canonical AOS root"
