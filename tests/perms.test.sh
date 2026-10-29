#!/usr/bin/env bash
# perms/ensure-perms.sh: fix wrong mode, leave right mode, warn on missing,
# skip symlinks, reject malformed lines. Temp dir only; never touches /home/box.
# File contents must stay byte-identical.
set -euo pipefail

ROOT=$(realpath "$(dirname "$0")/..")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ ! -x "$ROOT/perms/ensure-perms.sh" ]]; then
  echo "FAIL perms/ensure-perms.sh is not executable"
  exit 1
fi
if ! grep -q 'set -euo pipefail' "$ROOT/perms/ensure-perms.sh"; then
  echo "FAIL perms/ensure-perms.sh missing set -euo pipefail"
  exit 1
fi
if [[ ! -f "$ROOT/perms/perms.txt" ]]; then
  echo "FAIL perms/perms.txt is missing"
  exit 1
fi
if ! grep -q '/home/box/.config/youtube-coding' "$ROOT/perms/perms.txt"; then
  echo "FAIL perms/perms.txt missing youtube-coding entry"
  exit 1
fi
if ! grep -q 'client_secret.json' "$ROOT/perms/perms.txt"; then
  echo "FAIL perms/perms.txt missing client_secret.json"
  exit 1
fi
if ! grep -q 'token.json' "$ROOT/perms/perms.txt"; then
  echo "FAIL perms/perms.txt missing token.json"
  exit 1
fi
if ! grep -q 'auth.py' "$ROOT/perms/perms.txt"; then
  echo "FAIL perms/perms.txt missing auth.py"
  exit 1
fi
if ! grep -q 'youtube-coding-post' "$ROOT/perms/perms.txt"; then
  echo "FAIL perms/perms.txt missing youtube-coding-post"
  exit 1
fi
if ! grep -q 'survives a wipe' "$ROOT/perms/perms.txt"; then
  echo "FAIL perms/perms.txt missing wipe comment"
  exit 1
fi
if ! grep -q 'never copied' "$ROOT/perms/perms.txt"; then
  echo "FAIL perms/perms.txt missing never-copied comment"
  exit 1
fi
if ! grep -q 'python/venvs.txt' "$ROOT/perms/perms.txt"; then
  echo "FAIL perms/perms.txt missing venvs.txt comment"
  exit 1
fi

ens=$(env -u PERMS_ENSURE bash -c 'source "$1"; printf %s "$PERMS_ENSURE"' _ "$ROOT/lib/common.sh")
if [[ "$ens" != "$ROOT/perms/ensure-perms.sh" ]]; then
  echo "FAIL PERMS_ENSURE default was $ens"
  exit 1
fi
lst=$(env -u PERMS_LIST bash -c 'source "$1"; printf %s "$PERMS_LIST"' _ "$ROOT/lib/common.sh")
if [[ "$lst" != "$ROOT/perms/perms.txt" ]]; then
  echo "FAIL PERMS_LIST default was $lst"
  exit 1
fi
echo "ok perms scripts and defaults"

run_perms() {
  PERMS_LIST="$1" /bin/bash "$ROOT/perms/ensure-perms.sh"
}

# Wrong mode is fixed; right mode is left alone; contents stay identical.
mkdir -p "$TMP/priv"
printf 'secret-a\n' > "$TMP/priv/a.json"
printf 'secret-b\n' > "$TMP/priv/b.json"
chmod 644 "$TMP/priv/a.json"
chmod 600 "$TMP/priv/b.json"
cp -a "$TMP/priv/a.json" "$TMP/priv/a.json.before"
cp -a "$TMP/priv/b.json" "$TMP/priv/b.json.before"
cat > "$TMP/list-fix.txt" <<EOF
600 $TMP/priv/a.json
600 $TMP/priv/b.json
EOF
out=$(run_perms "$TMP/list-fix.txt" 2>"$TMP/err-fix")
rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL fix/ok status was $rc"; printf '%s\n' "$out"; cat "$TMP/err-fix"; exit 1; }
printf '%s\n' "$out" | grep -qx "perms: fixed 600 $TMP/priv/a.json" || {
  echo "FAIL wrong mode not fixed"; printf '%s\n' "$out"; exit 1
}
printf '%s\n' "$out" | grep -qx "perms: ok $TMP/priv/b.json" || {
  echo "FAIL right mode not ok"; printf '%s\n' "$out"; exit 1
}
[[ "$(stat -c '%a' "$TMP/priv/a.json")" == 600 ]] || {
  echo "FAIL a.json mode after fix was $(stat -c '%a' "$TMP/priv/a.json")"
  exit 1
}
[[ "$(stat -c '%a' "$TMP/priv/b.json")" == 600 ]] || {
  echo "FAIL b.json mode changed unexpectedly"
  exit 1
}
cmp -s "$TMP/priv/a.json" "$TMP/priv/a.json.before" || {
  echo "FAIL a.json contents changed"
  exit 1
}
cmp -s "$TMP/priv/b.json" "$TMP/priv/b.json.before" || {
  echo "FAIL b.json contents changed"
  exit 1
}
echo "ok wrong mode fixed and right mode untouched"

# Missing path warns with exit 0.
cat > "$TMP/list-missing.txt" <<EOF
600 $TMP/priv/no-such-file.json
EOF
set +e
out=$(run_perms "$TMP/list-missing.txt" 2>"$TMP/err-missing")
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL missing path status was $rc"; exit 1; }
grep -qx "WARN: perms: missing $TMP/priv/no-such-file.json" "$TMP/err-missing" || {
  echo "FAIL missing path warn missing"; cat "$TMP/err-missing"; exit 1
}
echo "ok missing path warns with exit 0"

# Symlink skipped; target mode unchanged.
printf 'target-secret\n' > "$TMP/priv/target.json"
chmod 644 "$TMP/priv/target.json"
ln -s "$TMP/priv/target.json" "$TMP/priv/link.json"
cp -a "$TMP/priv/target.json" "$TMP/priv/target.json.before"
cat > "$TMP/list-link.txt" <<EOF
600 $TMP/priv/link.json
EOF
set +e
out=$(run_perms "$TMP/list-link.txt" 2>"$TMP/err-link")
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL symlink status was $rc"; printf '%s\n' "$out"; cat "$TMP/err-link"; exit 1; }
grep -q "WARN: perms: symlink $TMP/priv/link.json" "$TMP/err-link" || {
  echo "FAIL symlink warn missing"; cat "$TMP/err-link"; exit 1
}
[[ "$(stat -c '%a' "$TMP/priv/target.json")" == 644 ]] || {
  echo "FAIL symlink target mode changed to $(stat -c '%a' "$TMP/priv/target.json")"
  exit 1
}
cmp -s "$TMP/priv/target.json" "$TMP/priv/target.json.before" || {
  echo "FAIL symlink target contents changed"
  exit 1
}
echo "ok symlink skipped and target mode unchanged"

# Malformed line exits non-zero.
cat > "$TMP/list-bad.txt" <<EOF
not-octal $TMP/priv/a.json
EOF
set +e
out=$(run_perms "$TMP/list-bad.txt" 2>"$TMP/err-bad")
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL malformed line exited 0"; printf '%s\n' "$out"; exit 1; }
grep -q 'ERROR: perms list mode is not octal' "$TMP/err-bad" || {
  echo "FAIL malformed line error missing"; cat "$TMP/err-bad"; exit 1
}
echo "ok malformed line exits non-zero"

# Relative path is malformed.
cat > "$TMP/list-rel.txt" <<EOF
600 relative/path.json
EOF
set +e
out=$(run_perms "$TMP/list-rel.txt" 2>"$TMP/err-rel")
rc=$?
set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL relative path exited 0"; exit 1; }
grep -q 'ERROR: perms list path is not absolute' "$TMP/err-rel" || {
  echo "FAIL relative path error missing"; cat "$TMP/err-rel"; exit 1
}
echo "ok relative path exits non-zero"

# Directory mode fix; contents of nested file untouched.
mkdir -p "$TMP/priv/dir"
printf 'nested\n' > "$TMP/priv/dir/nested.json"
chmod 755 "$TMP/priv/dir"
chmod 644 "$TMP/priv/dir/nested.json"
cp -a "$TMP/priv/dir/nested.json" "$TMP/priv/dir/nested.json.before"
cat > "$TMP/list-dir.txt" <<EOF
700 $TMP/priv/dir
EOF
out=$(run_perms "$TMP/list-dir.txt" 2>"$TMP/err-dir")
rc=$?
[[ "$rc" -eq 0 ]] || { echo "FAIL dir fix status was $rc"; exit 1; }
printf '%s\n' "$out" | grep -qx "perms: fixed 700 $TMP/priv/dir" || {
  echo "FAIL dir mode not fixed"; printf '%s\n' "$out"; exit 1
}
[[ "$(stat -c '%a' "$TMP/priv/dir")" == 700 ]] || {
  echo "FAIL dir mode after fix was $(stat -c '%a' "$TMP/priv/dir")"
  exit 1
}
cmp -s "$TMP/priv/dir/nested.json" "$TMP/priv/dir/nested.json.before" || {
  echo "FAIL nested file contents changed"
  exit 1
}
[[ "$(stat -c '%a' "$TMP/priv/dir/nested.json")" == 644 ]] || {
  echo "FAIL nested file mode changed"
  exit 1
}
echo "ok directory mode fixed without touching contents"

echo "ok perms ensure"
