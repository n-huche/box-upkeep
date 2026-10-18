#!/usr/bin/env bash
# Install Maven when mvn -v does not run. Skip when it already does.
# Default package is maven. Debian 13 (trixie) ships Maven 3.9.9, which
# runs on the JDK 21 that default-jdk installs. Override with MAVEN_PACKAGE.
# ./up.sh runs this after the JDK when Maven is missing.
# A non-zero exit is reported there and counts toward the first non-zero status.

set -euo pipefail

# shellcheck source=../lib/common.sh
source "$(dirname "$(/usr/bin/realpath "$0")")/../lib/common.sh"

pkg=$MAVEN_PACKAGE

if box_upkeep_maven_present; then
  echo "maven: present"
  exit 0
fi

echo "maven-install: $pkg"
if ! sudo apt-get update -y; then
  echo "ERROR: apt-get update failed while installing $pkg" >&2
  exit 1
fi
if ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"; then
  echo "ERROR: apt-get install failed for $pkg" >&2
  exit 1
fi
if ! box_upkeep_maven_present; then
  echo "ERROR: $pkg installed but mvn -v still does not run" >&2
  exit 1
fi
echo "maven: installed $pkg"
