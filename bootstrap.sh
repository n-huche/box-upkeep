#!/usr/bin/env bash
# Pacotes do upkeep + scripts em /home/box/upkeep e (por padrão) start.sh.
# Se box-access estiver ao lado, instala o portão primeiro (--install-only).

set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
HOME_BOX="${HOME_BOX:-/home/box}"
UPKEEP_DST="${HOME_BOX}/upkeep"
WORKSPACE="${WORKSPACE:-/workspace}"
ACCESS="${WORKSPACE}/box-access/bootstrap.sh"
LEGACY_ACCESS="${WORKSPACE}/box-infra/bootstrap.sh"
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

echo "repo=$REPO"
echo "home=$HOME_BOX"

if [[ -x "$ACCESS" ]]; then
  echo "access: $ACCESS --install-only"
  "$ACCESS" --install-only
elif [[ -x "$LEGACY_ACCESS" ]]; then
  echo "access-legacy: $LEGACY_ACCESS --install-only"
  "$LEGACY_ACCESS" --install-only
else
  echo "WARN: box-access not found; skip gate packages" >&2
fi

while read -r pkg; do
  [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
  ensure_pkg "$pkg"
done < "$REPO/packages.txt"

mkdir -p "$UPKEEP_DST"
install -m 755 "$REPO/start.sh" "${HOME_BOX}/start.sh"
install -m 755 "$REPO/units/tailscale-watchdog.sh" "${UPKEEP_DST}/tailscale-watchdog.sh"
install -m 755 "$REPO/units/sshd-watchdog.sh" "${UPKEEP_DST}/sshd-watchdog.sh"
install -m 755 "$REPO/units/cron-watchdog.sh" "${UPKEEP_DST}/cron-watchdog.sh"
install -m 755 "$REPO/units/aos-watchdog.sh" "${UPKEEP_DST}/aos-watchdog.sh"
echo "installed: ${HOME_BOX}/start.sh + ${UPKEEP_DST}/*.sh"

if [[ "$INSTALL_ONLY" -eq 1 ]]; then
  echo "install-only: skip start"
  exit 0
fi

exec "${HOME_BOX}/start.sh"
