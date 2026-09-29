#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
status=0
for t in tests/test_*.sh; do
  [ -e "$t" ] || continue
  echo "== $t =="
  bash "$t" || status=1
done
exit "$status"
