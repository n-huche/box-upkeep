#!/usr/bin/env bash
# Install a JDK when java or javac does not run. Skip when both already do.
# Default package is default-jdk (Debian/Ubuntu; openjdk-21-jdk on Ubuntu 24.04).
# Override the package with JDK_PACKAGE.
# ./up.sh runs this after the gate and AOS when the JDK is missing.
# A non-zero exit is reported there and counts toward the first non-zero status.

set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

pkg=$JDK_PACKAGE

if box_upkeep_jdk_present; then
  echo "jdk: present"
  exit 0
fi

echo "jdk-install: $pkg"
if ! sudo apt-get update -y; then
  echo "ERROR: apt-get update failed while installing $pkg" >&2
  exit 1
fi
if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"; then
  echo "ERROR: apt-get install failed for $pkg" >&2
  exit 1
fi
if ! box_upkeep_jdk_present; then
  echo "ERROR: $pkg installed but java or javac still does not run" >&2
  exit 1
fi
echo "jdk: installed $pkg"
