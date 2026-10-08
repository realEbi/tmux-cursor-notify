#!/usr/bin/env bash
# Self-tests for the harness and the fakes.
set -u
source "$(dirname "$0")/harness.sh"

test_harness_state_dirs() {
  harness_use_fakes
  [ -d "$FAKE_STATE" ] || { echo "FAKE_STATE is not a directory" >&2; exit 1; }
  [ -d "$TMPDIR" ] || { echo "TMPDIR is not a directory" >&2; exit 1; }
  [ "$TMPDIR" != "$FAKE_STATE" ] || { echo "TMPDIR equals FAKE_STATE" >&2; exit 1; }
  [ "$(bash -c 'printf %s "$FAKE_STATE $TMPDIR"')" = "$FAKE_STATE $TMPDIR" ] ||
    { echo "FAKE_STATE or TMPDIR not exported" >&2; exit 1; }
}

test_harness_fake_set_skips_mv_log() {
  harness_use_fakes
  fake_set osa-name Terminal
  assert_not_called mv
  [ "$(ls -A "$FAKE_STATE")" = "osa-name" ] ||
    { echo "unexpected files: $(ls -A "$FAKE_STATE")" >&2; exit 1; }
}

test_harness_capture_env_fallback() {
  harness_use_fakes
  export FAKE_TMUX_CAPTURE='from env'
  run_capture tmux capture-pane -p -t %1
  assert_exit 0
  assert_stdout_trimmed 'from env'
  export FAKE_TMUX_CAPTURE_EXIT=3
  run_capture tmux capture-pane -p -t %1
  assert_exit 3
}

test_harness_capture_changes() {
  harness_use_fakes
  export FAKE_TMUX_CAPTURE='from env'
  fake_set tmux-capture $'line one\nline two'
  run_capture tmux capture-pane -p -t %1
  assert_exit 0
  assert_stdout_trimmed $'line one\nline two'
  fake_set tmux-capture 'changed'
  run_capture tmux capture-pane -p -t %1
  assert_stdout_trimmed 'changed'
}

test_harness_capture_exit() {
  harness_use_fakes
  export FAKE_TMUX_CAPTURE_EXIT=3
  fake_set tmux-capture-exit 1
  run_capture tmux capture-pane -p -t %1
  assert_exit 1
  fake_set tmux-capture-exit 0
  run_capture tmux capture-pane -p -t %1
  assert_exit 0
}

test_harness_display_changes() {
  harness_use_fakes
  run_capture tmux display-message -p -t %1 fmt
  assert_stdout_trimmed '1 1 1'
  export FAKE_TMUX_DISPLAY='0 1 1'
  run_capture tmux display-message -p -t %1 fmt
  assert_stdout_trimmed '0 1 1'
  fake_set tmux-display '1 0 1'
  run_capture tmux display-message -p -t %1 fmt
  assert_stdout_trimmed '1 0 1'
}

test_harness_osa_bundle_changes() {
  harness_use_fakes
  local q='tell application "System Events" to get bundle identifier of first application process whose frontmost is true'
  run_capture osascript -e "$q"
  assert_stdout_trimmed 'com.example.Other'
  export FAKE_OSA_BUNDLE=com.apple.Terminal
  run_capture osascript -e "$q"
  assert_stdout_trimmed 'com.apple.Terminal'
  fake_set osa-bundle com.example.Browser
  run_capture osascript -e "$q"
  assert_stdout_trimmed 'com.example.Browser'
}

test_harness_osa_name_changes() {
  harness_use_fakes
  local q='tell application "System Events" to get name of first application process whose frontmost is true'
  run_capture osascript -e "$q"
  assert_stdout_trimmed 'Safari'
  export FAKE_OSA_NAME=Terminal
  run_capture osascript -e "$q"
  assert_stdout_trimmed 'Terminal'
  fake_set osa-name Finder
  run_capture osascript -e "$q"
  assert_stdout_trimmed 'Finder'
}

# A process that is already running sees the new value: the point of fake_set.
test_harness_running_process_sees_change() {
  harness_use_fakes
  fake_set tmux-capture before
  (
    i=0
    while [ "$i" -lt 50 ]; do
      if [ "$(tmux capture-pane -p)" = after ]; then
        : > "$FAKE_LOG/saw-after"
        exit 0
      fi
      sleep 0.1
      i=$((i + 1))
    done
  ) &
  sleep 0.3
  fake_set tmux-capture after
  wait
  [ -f "$FAKE_LOG/saw-after" ] || { echo "running reader never saw the change" >&2; exit 1; }
}

test_harness_notifier_calls() {
  harness_use_fakes
  assert_notifier_calls 0
  terminal-notifier -title One -message 'body' -group g
  assert_notifier_calls 1
  terminal-notifier -title Two -message 'other' -group g
  assert_notifier_calls 2
  if (assert_notifier_calls 1) 2>/dev/null; then
    echo "assert_notifier_calls accepted a wrong count" >&2
    exit 1
  fi
}

test_harness_wait_for_notifier() {
  harness_use_fakes
  (sleep 0.3; terminal-notifier -title Late) &
  wait_for_notifier
  assert_notifier_calls 1
  wait
}

test_harness_no_watchers() {
  harness_use_fakes
  local pane="%h$$"
  assert_no_watchers "$pane"
  # Stands in for "bin/notify --watch <agent> <pane> ...". Exits within the grace period.
  bash -c 'sleep 1' fake-notify --watch cursor "$pane" title &
  assert_no_watchers "$pane"
  wait
  # One that stays alive is reported.
  bash -c 'trap "kill %1" TERM; sleep 30 & wait' fake-notify --watch cursor "$pane" title &
  local pid=$!
  local ok=0
  (assert_no_watchers "$pane") 2>/dev/null || ok=1
  # A different pane id that merely starts with the same text is not matched.
  assert_no_watchers "${pane}9" || ok=0
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  [ "$ok" = 1 ] || { echo "assert_no_watchers missed a live watcher" >&2; exit 1; }
}

run_tests \
  test_harness_state_dirs \
  test_harness_fake_set_skips_mv_log \
  test_harness_capture_env_fallback \
  test_harness_capture_changes \
  test_harness_capture_exit \
  test_harness_display_changes \
  test_harness_osa_bundle_changes \
  test_harness_osa_name_changes \
  test_harness_running_process_sees_change \
  test_harness_notifier_calls \
  test_harness_wait_for_notifier \
  test_harness_no_watchers
