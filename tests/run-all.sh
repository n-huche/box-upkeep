#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

bash -n up.sh
bash -n bootstrap.sh
bash -n aos-up.sh
bash -n java/install-jdk.sh
bash -n lib/common.sh
for step in steps/*.sh; do
  bash -n "$step"
done
bash -n units/cron-watchdog.sh
bash -n units/aos-watchdog.sh

for test in tests/*.test.sh; do
  echo "== $test =="
  bash "$test"
done
echo "all tests passed"
