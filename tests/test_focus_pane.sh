#!/usr/bin/env bash
set -u
source "$(dirname "$0")/harness.sh"

test_focus_live_pane() {
  harness_use_fakes
  run_capture "$ROOT/bin/focus-pane" "com.apple.Terminal" "/tmp/tmux-501/default" "%12"
  assert_exit 0
  assert_log_contains osascript 'tell application id "com.apple.Terminal" to activate'
  assert_log_contains tmux 'select-window'
  assert_log_contains tmux '-S'
  assert_log_contains tmux '/tmp/tmux-501/default'
  assert_log_contains tmux '-t'
  assert_log_contains tmux '%12'
  assert_log_contains tmux 'select-pane'
  assert_log_contains tmux 'switch-client'
  assert_log_lacks tmux ' -c'
}

test_focus_dead_pane_still_activates() {
  harness_use_fakes
  export FAKE_TMUX_SELECT_WINDOW_EXIT=1
  run_capture "$ROOT/bin/focus-pane" "com.apple.Terminal" "/tmp/tmux-501/default" "%12"
  assert_exit 0
  assert_log_contains osascript 'to activate'
  assert_log_contains tmux 'select-pane'
  assert_log_contains tmux 'switch-client'
}

test_focus_empty_socket_skips_tmux() {
  harness_use_fakes
  run_capture "$ROOT/bin/focus-pane" "com.apple.Terminal" "" "%12"
  assert_exit 0
  assert_log_contains osascript 'to activate'
  assert_not_called tmux
}

test_focus_empty_pane_skips_tmux() {
  harness_use_fakes
  run_capture "$ROOT/bin/focus-pane" "com.apple.Terminal" "/tmp/sock" ""
  assert_exit 0
  assert_log_contains osascript 'to activate'
  assert_not_called tmux
}

test_focus_bundle_id_activates_by_id() {
  harness_use_fakes
  run_capture "$ROOT/bin/focus-pane" "com.apple.Terminal" "/tmp/sock" "%1"
  assert_exit 0
  assert_log_contains osascript 'tell application id "com.apple.Terminal" to activate'
  assert_log_lacks osascript '(name of processes) contains'
}

test_focus_empty_bundle_walks_names() {
  harness_use_fakes
  export FAKE_OSA_CONTAINS=$'Terminal false\niTerm2 true'
  run_capture "$ROOT/bin/focus-pane" "" "/tmp/sock" "%1"
  assert_exit 0
  assert_log_contains osascript 'contains "Terminal"'
  assert_log_contains osascript 'contains "iTerm2"'
  assert_log_contains osascript 'tell application "iTerm2" to activate'
  assert_log_lacks osascript 'tell application id'
}

test_focus_name_walk_skips_false_and_nonzero() {
  harness_use_fakes
  export FAKE_OSA_CONTAINS=$'Terminal exit\niTerm2 true'
  run_capture "$ROOT/bin/focus-pane" "" "/tmp/sock" "%1"
  assert_exit 0
  assert_log_contains osascript 'contains "Terminal"'
  assert_log_contains osascript 'tell application "iTerm2" to activate'
}

test_focus_none_running_still_tmux() {
  harness_use_fakes
  run_capture "$ROOT/bin/focus-pane" "" "/tmp/sock" "%9"
  assert_exit 0
  assert_log_lacks osascript 'to activate'
  assert_log_contains tmux 'select-window'
  assert_log_contains tmux 'select-pane'
  assert_log_contains tmux 'switch-client'
}

test_focus_none_running_no_tmux_when_socket_empty() {
  harness_use_fakes
  run_capture "$ROOT/bin/focus-pane" "" "" "%9"
  assert_exit 0
  assert_log_lacks osascript 'to activate'
  assert_not_called tmux
}

test_focus_bundle_quote_uses_name_walk() {
  harness_use_fakes
  export FAKE_OSA_CONTAINS=$'Terminal true'
  run_capture "$ROOT/bin/focus-pane" 'bad"id' "/tmp/sock" "%1"
  assert_exit 0
  assert_log_lacks osascript 'tell application id'
  assert_log_contains osascript 'contains "Terminal"'
}

test_focus_bundle_backslash_uses_name_walk() {
  harness_use_fakes
  export FAKE_OSA_CONTAINS=$'Terminal true'
  run_capture "$ROOT/bin/focus-pane" 'bad\id' "/tmp/sock" "%1"
  assert_exit 0
  assert_log_lacks osascript 'tell application id'
  assert_log_contains osascript 'contains "Terminal"'
}

test_focus_activate_failure_still_tmux() {
  harness_use_fakes
  export FAKE_ACTIVATE_EXIT=1
  run_capture "$ROOT/bin/focus-pane" "com.apple.Terminal" "/tmp/sock" "%3"
  assert_exit 0
  assert_log_lacks osascript '(name of processes) contains'
  assert_log_contains tmux 'select-window'
  assert_log_contains tmux 'select-pane'
  assert_log_contains tmux 'switch-client'
}

run_tests \
  test_focus_live_pane \
  test_focus_dead_pane_still_activates \
  test_focus_empty_socket_skips_tmux \
  test_focus_empty_pane_skips_tmux \
  test_focus_bundle_id_activates_by_id \
  test_focus_empty_bundle_walks_names \
  test_focus_name_walk_skips_false_and_nonzero \
  test_focus_none_running_still_tmux \
  test_focus_none_running_no_tmux_when_socket_empty \
  test_focus_bundle_quote_uses_name_walk \
  test_focus_bundle_backslash_uses_name_walk \
  test_focus_activate_failure_still_tmux
