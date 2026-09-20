#!/usr/bin/env bash
# Host birth + keep: clone siblings if missing, run the gate, install
# watchdogs, start. Does not create a Tailscale identity or write SSH keys
# (box-access does). Persistence of tailscaled/sshd/cron/AOS is this repo.

set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
HOME_BOX="${HOME_BOX:-/home/box}"
UPKEEP_DST="${HOME_BOX}/upkeep"
WORKSPACE="${WORKSPACE:-/workspace}"
ACCESS="${WORKSPACE}/box-access/bootstrap.sh"
INSTALL_ONLY=0

if [[ "${1:-}" == "--install-only" ]]; then
  INSTALL_ONLY=1
fi

ensure_pkg() {
  local pkg=$1
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "pkg-ok: $pkg"
    return 0
  fi
  echo "pkg-install: $pkg"
  sudo apt-get update -y
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
}

github_owner() {
  if [[ -n "${GITHUB_OWNER:-}" ]]; then
    printf '%s\n' "$GITHUB_OWNER"
    return
  fi
  local url
  url=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
  if [[ "$url" =~ github.com[:/]([^/]+) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return
  fi
  printf '%s\n' "n-huche"
}

clone_repo() {
  local url=$1 dest=$2
  if [[ -d "$dest/.git" ]]; then
    echo "git: present $dest"
    return 0
  fi
  if [[ -e "$dest" ]]; then
    echo "ERROR: $dest exists and is not a git clone" >&2
    return 1
  fi
  echo "git: clone $url -> $dest"
  git clone "$url" "$dest"
}

ensure_gh_auth() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh not found (needed to clone private aos-user)." >&2
    return 1
  fi
  if gh auth status >/dev/null 2>&1; then
    echo "gh: already authenticated"
    gh auth setup-git >/dev/null 2>&1 || true
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "ERROR: gh not logged in and stdin is not a TTY." >&2
    return 1
  fi
  echo "gh: login (HTTPS, github.com)"
  gh auth login --hostname github.com --git-protocol https
  gh auth setup-git >/dev/null 2>&1 || true
}

install_units() {
  mkdir -p "$UPKEEP_DST"
  install -m 755 "$REPO/start.sh" "${HOME_BOX}/start.sh"
  install -m 755 "$REPO/units/tailscale-watchdog.sh" "${UPKEEP_DST}/tailscale-watchdog.sh"
  install -m 755 "$REPO/units/sshd-watchdog.sh" "${UPKEEP_DST}/sshd-watchdog.sh"
  install -m 755 "$REPO/units/cron-watchdog.sh" "${UPKEEP_DST}/cron-watchdog.sh"
  install -m 755 "$REPO/units/aos-watchdog.sh" "${UPKEEP_DST}/aos-watchdog.sh"
  echo "installed: ${HOME_BOX}/start.sh + ${UPKEEP_DST}/*.sh"
}

birth() {
  local owner url_access url_aos url_user
  owner=$(github_owner)
  url_access="https://github.com/${owner}/box-access.git"
  url_aos="https://github.com/${owner}/aos.git"
  url_user="https://github.com/${owner}/aos-user.git"

  echo "birth: workspace=$WORKSPACE owner=$owner"

  clone_repo "$url_access" "${WORKSPACE}/box-access"
  clone_repo "$url_aos" "${WORKSPACE}/aos"

  if [[ ! -d "${WORKSPACE}/aos/user/.git" ]]; then
    ensure_gh_auth
  fi
  clone_repo "$url_user" "${WORKSPACE}/aos/user"

  if [[ ! -x "$ACCESS" ]]; then
    echo "ERROR: missing $ACCESS" >&2
    return 1
  fi
  echo "access: $ACCESS"
  "$ACCESS"
}

echo "repo=$REPO"
echo "home=$HOME_BOX"

if [[ "$INSTALL_ONLY" -eq 0 ]]; then
  birth
fi

while read -r pkg; do
  [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
  ensure_pkg "$pkg"
done < "$REPO/packages.txt"

install_units

if [[ "$INSTALL_ONLY" -eq 1 ]]; then
  echo "install-only: skip start"
  exit 0
fi

exec "${HOME_BOX}/start.sh"
