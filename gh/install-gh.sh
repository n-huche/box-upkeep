#!/usr/bin/env bash
# Install GitHub CLI when gh --version does not run. Skip when it already does.
# Adds the official apt repository (https://cli.github.com/packages) and the
# keyring /etc/apt/keyrings/githubcli-archive-keyring.gpg, then installs gh.
# ./up.sh runs this after Maven when gh is missing.
# A non-zero exit is reported there and counts toward the first non-zero status.
# Login is handled by ./up.sh, not here.

set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(dirname "$(/usr/bin/realpath "$0")")/../lib/common.sh"

pkg=gh
key_url=https://cli.github.com/packages/githubcli-archive-keyring.gpg
keyring=/etc/apt/keyrings/githubcli-archive-keyring.gpg
list=/etc/apt/sources.list.d/github-cli.list

if box_upkeep_gh_present; then
  echo "gh: present"
  exit 0
fi

echo "gh-install: $pkg"

tmp=
cleanup() {
  if [[ -n "${tmp:-}" ]]; then
    /bin/rm -f "$tmp"
  fi
}
trap cleanup EXIT
tmp=$(/usr/bin/mktemp)

download_keyring() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp" "$key_url"
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -nv -O "$tmp" "$key_url"
    return
  fi
  echo "ERROR: curl or wget is required to download the GitHub CLI keyring" >&2
  return 1
}

if ! download_keyring; then
  echo "ERROR: failed to download the GitHub CLI keyring" >&2
  exit 1
fi

if ! sudo mkdir -p -m 755 /etc/apt/keyrings; then
  echo "ERROR: could not create /etc/apt/keyrings" >&2
  exit 1
fi
# stdin is the temp file, which this user can read. tee runs as root.
# shellcheck disable=SC2024
if ! sudo tee "$keyring" >/dev/null < "$tmp"; then
  echo "ERROR: could not install the GitHub CLI keyring" >&2
  exit 1
fi
if ! sudo chmod go+r "$keyring"; then
  echo "ERROR: could not set permissions on the GitHub CLI keyring" >&2
  exit 1
fi

if ! arch=$(dpkg --print-architecture); then
  echo "ERROR: dpkg --print-architecture failed" >&2
  exit 1
fi
repo_line="deb [arch=${arch} signed-by=${keyring}] https://cli.github.com/packages stable main"

if ! sudo mkdir -p -m 755 /etc/apt/sources.list.d; then
  echo "ERROR: could not create /etc/apt/sources.list.d" >&2
  exit 1
fi
if ! printf '%s\n' "$repo_line" | sudo tee "$list" >/dev/null; then
  echo "ERROR: could not write the GitHub CLI apt source" >&2
  exit 1
fi

if ! sudo apt-get update -y; then
  echo "ERROR: apt-get update failed while installing $pkg" >&2
  exit 1
fi
if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"; then
  echo "ERROR: apt-get install failed for $pkg" >&2
  exit 1
fi
if ! box_upkeep_gh_present; then
  echo "ERROR: $pkg installed but gh --version still does not run" >&2
  exit 1
fi
echo "gh: installed $pkg"
