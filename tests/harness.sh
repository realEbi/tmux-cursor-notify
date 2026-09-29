#!/usr/bin/env bash
# Shared fakes and assertions for bin/ tests.
set -u

HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$HARNESS_DIR/.." && pwd -P)

harness_use_fakes() {
  FAKE_LOG=$(mktemp -d)
  HIDE_DIR=$(mktemp -d)
  export FAKE_LOG HIDE_DIR ROOT
  export PATH="$HIDE_DIR:$HARNESS_DIR/fakes:/bin:/usr/bin"
  unset FAKE_OSA_BUNDLE FAKE_OSA_NAME FAKE_OSA_CONTAINS FAKE_OSA_EXIT
  unset FAKE_ACTIVATE_EXIT FAKE_OSA_DISPLAY_EXIT
  unset FAKE_NOTIFIER_EXIT FAKE_TMUX_DISPLAY FAKE_TMUX_DISPLAY_EXIT
  unset FAKE_TMUX_SELECT_WINDOW_EXIT FAKE_MV_EXIT
  LAST_STATUS=0
  LAST_STDOUT=
}

harness_hide() {
  local name="$1"
  printf '%s\n' '#!/bin/sh' 'exit 127' > "$HIDE_DIR/$name"
  chmod +x "$HIDE_DIR/$name"
}

run_capture() {
  set +e
  LAST_STDOUT=$("$@" 2>>"$FAKE_LOG/stderr")
  LAST_STATUS=$?
  set -e
}

assert_exit() {
  if [ "$LAST_STATUS" != "$1" ]; then
    echo "assert_exit: expected $1 got $LAST_STATUS" >&2
    echo "stdout: [$LAST_STDOUT]" >&2
    if [ -f "$FAKE_LOG/stderr" ]; then
      echo "stderr:" >&2
      cat "$FAKE_LOG/stderr" >&2
    fi
    exit 1
  fi
}

assert_stdout_trimmed() {
  local got
  got=$(printf '%s' "$LAST_STDOUT" | sed 's/[[:space:]]*$//')
  if [ "$got" != "$1" ]; then
    echo "stdout: expected [$1] got [$got]" >&2
    exit 1
  fi
}

assert_log_contains() {
  local file="$FAKE_LOG/$1"
  if [ ! -f "$file" ] || ! grep -F -q -- "$2" "$file"; then
    echo "log $1 missing [$2]" >&2
    if [ -f "$file" ]; then
      echo "--- $1 ---" >&2
      cat "$file" >&2
    fi
    exit 1
  fi
}

assert_log_lacks() {
  local file="$FAKE_LOG/$1"
  if [ -f "$file" ] && grep -F -q -- "$2" "$file"; then
    echo "log $1 unexpectedly contains [$2]" >&2
    cat "$file" >&2
    exit 1
  fi
}

assert_not_called() {
  local file="$FAKE_LOG/$1"
  if [ -f "$file" ]; then
    echo "$1 was called:" >&2
    cat "$file" >&2
    exit 1
  fi
}

run_tests() {
  local status=0
  local name
  for name in "$@"; do
    if (
      set -e
      "$name"
    ); then
      echo "PASS $name"
    else
      echo "FAIL $name" >&2
      status=1
    fi
  done
  exit "$status"
}
