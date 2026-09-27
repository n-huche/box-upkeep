#!/usr/bin/env bash
# Clone step with a mock git on PATH. Does not touch the network.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

MOCK_LOG=$TMP/git.log
mkdir -p "$TMP/bin" "$TMP/workspace"
cat > "$TMP/bin/git" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MOCK_LOG"
if [[ "${1:-}" == "clone" ]]; then
  dest=${3:-}
  if [[ -z "$dest" ]]; then
    echo "mock-git: clone needs a dest" >&2
    exit 1
  fi
  mkdir -p "$dest/.git"
  printf '%s\n' "mock" > "$dest/.git/HEAD"
fi
exit 0
EOF
chmod +x "$TMP/bin/git"

export PATH="$TMP/bin:$PATH"
export MOCK_LOG
export AOS_ROOT="$TMP/workspace/aos"
export AOS_REPO_URL="https://github.com/n-huche/aos.git"
unset SKIP_CLONE

# shellcheck source=../aos/lib/common.sh
source "$ROOT/aos/lib/common.sh"
# shellcheck source=../aos/steps/03-clone-aos.sh
source "$ROOT/aos/steps/03-clone-aos.sh"

if [[ "$(command -v git)" != "$TMP/bin/git" ]]; then
  echo "FAIL mock git is not first on PATH"
  exit 1
fi

step_clone_aos >/dev/null
if [[ ! -f "$AOS_ROOT/.git/HEAD" ]]; then
  echo "FAIL clone did not create .git"
  exit 1
fi
if ! grep -q "clone $AOS_REPO_URL $AOS_ROOT" "$MOCK_LOG"; then
  echo "FAIL mock git was not invoked with the configured URL"
  cat "$MOCK_LOG"
  exit 1
fi
echo "ok clone uses the mock and the configured URL"

lines=$(wc -l < "$MOCK_LOG")
step_clone_aos >/dev/null
if [[ "$(wc -l < "$MOCK_LOG")" -ne "$lines" ]]; then
  echo "FAIL second run cloned again"
  exit 1
fi
echo "ok present checkout is not cloned again"

rm -rf "$AOS_ROOT"
mkdir -p "$AOS_ROOT"
set +e
step_clone_aos >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
  echo "FAIL non-git destination was accepted"
  exit 1
fi
if [[ "$(wc -l < "$MOCK_LOG")" -ne "$lines" ]]; then
  echo "FAIL non-git destination still invoked git"
  exit 1
fi
echo "ok non-git destination is an error and does not clone"

rm -rf "$AOS_ROOT"
: > "$MOCK_LOG"
box_upkeep_parse_aos_args --skip-clone
step_clone_aos >/dev/null
if [[ -s "$MOCK_LOG" ]]; then
  echo "FAIL --skip-clone invoked git"
  exit 1
fi
if [[ -e "$AOS_ROOT" ]]; then
  echo "FAIL --skip-clone created AOS_ROOT"
  exit 1
fi
echo "ok --skip-clone does not clone"

# Fresh shell so config defaults apply and the mock stays on PATH.
default_url=$(
  PATH="$TMP/bin:$PATH" AOS_ROOT="$TMP/workspace/aos-default" \
    env -u AOS_REPO_URL bash -c 'source "'"$ROOT"'/aos/lib/common.sh"; printf "%s\n" "$AOS_REPO_URL"'
)
if [[ "$default_url" != "https://github.com/n-huche/aos.git" ]]; then
  echo "FAIL default AOS_REPO_URL is $default_url"
  exit 1
fi
override_url=$(
  PATH="$TMP/bin:$PATH" AOS_REPO_URL="https://example.invalid/aos.git" \
    bash -c 'source "'"$ROOT"'/aos/lib/common.sh"; printf "%s\n" "$AOS_REPO_URL"'
)
if [[ "$override_url" != "https://example.invalid/aos.git" ]]; then
  echo "FAIL env AOS_REPO_URL did not override config"
  exit 1
fi
echo "ok default URL is n-huche/aos and env overrides config"
