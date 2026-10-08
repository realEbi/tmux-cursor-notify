#!/usr/bin/env bash
# Shared fakes and assertions for bin/ tests.
set -u

HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$HARNESS_DIR/.." && pwd -P)

harness_use_fakes() {
  FAKE_LOG=$(mktemp -d)
  HIDE_DIR=$(mktemp -d)
  # FAKE_STATE holds answers the fakes re-read on every call (see fake_set).
  FAKE_STATE=$(mktemp -d)
  # Created before TMPDIR is replaced, so it does not nest inside an older one.
  HARNESS_TMPDIR=$(mktemp -d)
  export FAKE_LOG HIDE_DIR FAKE_STATE ROOT
  export TMPDIR="$HARNESS_TMPDIR"
  export PATH="$HIDE_DIR:$HARNESS_DIR/fakes:/bin:/usr/bin"
  unset FAKE_OSA_BUNDLE FAKE_OSA_NAME FAKE_OSA_CONTAINS FAKE_OSA_EXIT
  unset FAKE_ACTIVATE_EXIT FAKE_OSA_DISPLAY_EXIT
  unset FAKE_NOTIFIER_EXIT FAKE_TMUX_DISPLAY FAKE_TMUX_DISPLAY_EXIT
  unset FAKE_TMUX_SELECT_WINDOW_EXIT FAKE_MV_EXIT FAKE_TMUX_CAPTURE_EXIT
  unset TMUX TMUX_PANE __CFBundleIdentifier KEEP_PANE_UNSET
  LAST_STATUS=0
  LAST_STDOUT=
}

harness_hide() {
  local name="$1"
  printf '%s\n' '#!/bin/sh' 'exit 127' > "$HIDE_DIR/$name"
  chmod +x "$HIDE_DIR/$name"
}

# fake_set NAME VALUE
# Change what a fake answers from its next call on, even for a process that is
# already running. Names: tmux-capture, tmux-capture-exit, tmux-display,
# osa-bundle, osa-name. Written through a temp file and renamed, so a reader
# never sees a half-written value. /bin/mv, not the fake mv, to keep its log clean.
fake_set() {
  local name="$1" value="$2"
  local tmp="$FAKE_STATE/.$name.$$.tmp"
  printf '%s' "$value" > "$tmp"
  /bin/mv -f "$tmp" "$FAKE_STATE/$name"
}

# wait_quiet [SECONDS]
# Give a background worker time to (wrongly) notify before asserting silence.
wait_quiet() {
  sleep "${1:-3}"
}

# Wait up to 5 seconds for the first terminal-notifier call.
wait_for_notifier() {
  local i=0
  while [ "$i" -lt 50 ]; do
    if [ -f "$FAKE_LOG/terminal-notifier" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "timeout waiting for terminal-notifier" >&2
  exit 1
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

# assert_notifier_calls N
# terminal-notifier was called exactly N times. Each call logs one "-title"
# line. A missing log counts as 0.
assert_notifier_calls() {
  local file="$FAKE_LOG/terminal-notifier" got=0
  if [ -f "$file" ]; then
    got=$(grep -c -x -e '-title' "$file")
  fi
  if [ "$got" != "$1" ]; then
    echo "terminal-notifier: expected $1 calls got $got" >&2
    if [ -f "$file" ]; then
      cat "$file" >&2
    fi
    exit 1
  fi
}

# Print the processes whose command line has both "--watch" and PANE as whole
# arguments. Filtered in bash, so no helper process carries the pattern.
harness_watchers() {
  local pane="$1" listing pid cmd
  listing=$(ps -axo pid=,command=) || {
    echo "harness_watchers: ps failed" >&2
    return 1
  }
  while read -r pid cmd; do
    case " $cmd " in
      *" --watch "*) ;;
      *) continue ;;
    esac
    case " $cmd " in
      *" $pane "*) printf '%s %s\n' "$pid" "$cmd" ;;
    esac
  done <<EOF_PS
$listing
EOF_PS
}

# assert_no_watchers PANE
# No watcher for PANE is left running. Polls for about 3 seconds first, so a
# watcher that is on its way out is not a failure.
assert_no_watchers() {
  local pane="$1" i=0 found
  while :; do
    found=$(harness_watchers "$pane") || exit 1
    if [ -z "$found" ]; then
      return 0
    fi
    if [ "$i" -ge 30 ]; then
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "watcher still running for pane $pane:" >&2
  printf '%s\n' "$found" >&2
  exit 1
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
