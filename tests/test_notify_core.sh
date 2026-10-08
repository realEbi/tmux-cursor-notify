#!/usr/bin/env bash
set -u
source "$(dirname "$0")/harness.sh"

run_hook() {
  local json=$1
  if [ "${KEEP_PANE_UNSET-}" = 1 ]; then
    unset TMUX_PANE
  elif [ -z "${TMUX_PANE+x}" ]; then
    export TMUX_PANE=%12
  fi
  run_capture "$ROOT/bin/notify" cursor stop <<<"$json"
}

completed='{"status":"completed","conversation_id":"c1","workspace_roots":["/tmp/app"]}'

test_notify_completed() {
  harness_use_fakes
  run_hook "$completed"
  assert_exit 0
  assert_stdout_trimmed '{}'
  assert_notifier_calls 1
  assert_notifier_arg -title 'Cursor finished'
  assert_notifier_arg -message app
  assert_notifier_arg -sound Glass
  assert_notifier_arg -group cursor-c1
}

test_notify_error() {
  harness_use_fakes
  run_hook '{"status":"error","conversation_id":"c1","workspace_roots":["/tmp/app"]}'
  assert_exit 0
  assert_notifier_arg -title 'Cursor hit an error'
}

test_notify_body_trailing_slash() {
  harness_use_fakes
  run_hook '{"status":"completed","workspace_roots":["/tmp/app/"]}'
  assert_notifier_arg -message app
}

test_notify_body_root() {
  harness_use_fakes
  run_hook '{"status":"completed","workspace_roots":["/"]}'
  assert_notifier_arg -message agent
}

test_notify_body_missing() {
  harness_use_fakes
  run_hook '{"status":"completed"}'
  assert_notifier_arg -message agent
}

test_notify_body_empty_list() {
  harness_use_fakes
  run_hook '{"status":"completed","workspace_roots":[]}'
  assert_notifier_arg -message agent
}

test_notify_body_empty_string() {
  harness_use_fakes
  run_hook '{"status":"completed","workspace_roots":[""]}'
  assert_notifier_arg -message agent
}

test_notify_body_number() {
  harness_use_fakes
  run_hook '{"status":"completed","workspace_roots":[1]}'
  assert_notifier_arg -message agent
}

test_notify_group() {
  harness_use_fakes
  run_hook '{"status":"completed","conversation_id":"c1"}'
  run_hook '{"status":"completed","conversation_id":"c1"}'
  run_hook '{"status":"completed","conversation_id":"c2"}'
  assert_notifier_arg -group cursor-c1 1
  assert_notifier_arg -group cursor-c1 2
  assert_notifier_arg -group cursor-c2 3
}

test_notify_group_unknown() {
  harness_use_fakes
  run_hook '{"status":"completed"}'
  run_hook '{"status":"completed","conversation_id":""}'
  run_hook '{"status":"completed","conversation_id":1}'
  assert_notifier_calls 3
  assert_notifier_arg -group cursor-unknown 1
  assert_notifier_arg -group cursor-unknown 2
  assert_notifier_arg -group cursor-unknown 3
}

test_notify_execute_parts() {
  harness_use_fakes
  export __CFBundleIdentifier=com.apple.Terminal
  export TMUX=/tmp/sock,123,0
  export TMUX_PANE=%12
  run_hook "$completed"
  local fp
  fp=$(cd "$ROOT/bin" && pwd -P)/focus-pane
  assert_log_contains terminal-notifier "'$fp'"
  assert_log_contains terminal-notifier "'com.apple.Terminal'"
  assert_log_contains terminal-notifier "'/tmp/sock'"
  assert_log_contains terminal-notifier "'%12'"
}

test_notify_socket_quote() {
  harness_use_fakes
  export TMUX="/tmp/so'ck,1,0"
  export TMUX_PANE=%12
  run_hook "$completed"
  assert_log_contains terminal-notifier "'/tmp/so'\\''ck'"
}

test_notify_no_tmux_env() {
  harness_use_fakes
  unset TMUX
  export TMUX_PANE=%12
  run_hook "$completed"
  assert_log_contains terminal-notifier "''"
}

test_notify_execute_absolute() {
  harness_use_fakes
  export TMUX_PANE=%12
  run_hook "$completed"
  local fp
  fp=$(cd "$ROOT/bin" && pwd -P)/focus-pane
  assert_log_contains terminal-notifier "'$fp'"
}

test_notify_no_pane() {
  harness_use_fakes
  KEEP_PANE_UNSET=1
  run_hook "$completed"
  assert_not_called terminal-notifier
  assert_exit 0
  assert_stdout_trimmed '{}'
}

test_notify_empty_pane() {
  harness_use_fakes
  export TMUX_PANE=
  run_hook "$completed"
  assert_not_called terminal-notifier
  assert_exit 0
  assert_stdout_trimmed '{}'
}

test_notify_no_pane_bad_json() {
  harness_use_fakes
  KEEP_PANE_UNSET=1
  run_hook 'not-json'
  assert_not_called terminal-notifier
  assert_exit 0
  assert_stdout_trimmed '{}'
}

test_notify_aborted() {
  harness_use_fakes
  run_hook '{"status":"aborted"}'
  assert_not_called terminal-notifier
}

test_notify_other_status() {
  harness_use_fakes
  run_hook '{"status":"running"}'
  assert_not_called terminal-notifier
}

test_notify_status_missing() {
  harness_use_fakes
  run_hook '{}'
  assert_not_called terminal-notifier
}

test_notify_status_number() {
  harness_use_fakes
  run_hook '{"status":1}'
  assert_not_called terminal-notifier
}

test_notify_folder_is_not_run() {
  harness_use_fakes
  export FAKE_OSA_NAME=Safari
  local root="/tmp/it's \$(touch ran)"
  cd "$FAKE_LOG" || exit 1
  run_hook "$(jq -nc --arg r "$root" '{status: "completed", conversation_id: "c1", workspace_roots: [$r]}')"
  assert_notifier_arg -message "it's \$(touch ran)"
  if [ -e "$FAKE_LOG/ran" ]; then
    echo "workspace path from hook input was executed" >&2
    exit 1
  fi
}

expect_silent() {
  assert_exit 0
  assert_not_called terminal-notifier
  assert_not_called osascript
  assert_stdout_trimmed '{}'
}

test_notify_bad_json() {
  harness_use_fakes
  run_hook 'not-json'
  expect_silent
}

test_notify_empty_stdin() {
  harness_use_fakes
  export TMUX_PANE=%12
  run_capture "$ROOT/bin/notify" cursor stop </dev/null
  expect_silent
}

test_notify_json_array() {
  harness_use_fakes
  run_hook '[]'
  expect_silent
}

test_notify_json_null() {
  harness_use_fakes
  run_hook 'null'
  expect_silent
}

test_notify_json_string() {
  harness_use_fakes
  run_hook '"hi"'
  expect_silent
}

test_notify_fallback_missing_notifier() {
  harness_use_fakes
  harness_hide terminal-notifier
  run_hook "$completed"
  assert_log_contains osascript 'display notification'
  assert_log_contains osascript 'Glass'
  assert_log_line osascript 'Cursor finished'
  assert_log_line osascript app
  assert_log_lacks osascript '-execute'
  assert_log_lacks osascript 'focus-pane'
}

test_notify_fallback_notifier_fails() {
  harness_use_fakes
  export FAKE_NOTIFIER_EXIT=1
  run_hook "$completed"
  assert_log_contains osascript 'display notification'
  assert_log_contains osascript 'Glass'
  assert_log_lacks osascript '-execute'
  assert_log_lacks osascript 'focus-pane'
}

test_notify_fallback_quote_body() {
  harness_use_fakes
  export FAKE_NOTIFIER_EXIT=1
  run_hook '{"status":"completed","workspace_roots":["/tmp/say\"hi"]}'
  assert_log_line osascript 'say"hi'
  if grep -F 'on run argv' "$FAKE_LOG/osascript" | grep -F 'say"hi' >/dev/null; then
    echo "body was interpolated into the AppleScript" >&2
    exit 1
  fi
}

test_notify_stdout_always() {
  harness_use_fakes
  run_hook '{"status":"aborted"}'
  assert_exit 0
  assert_stdout_trimmed '{}'

  harness_use_fakes
  run_hook 'not-json'
  assert_exit 0
  assert_stdout_trimmed '{}'

  harness_use_fakes
  KEEP_PANE_UNSET=1
  run_hook "$completed"
  assert_exit 0
  assert_stdout_trimmed '{}'

  harness_use_fakes
  export FAKE_NOTIFIER_EXIT=1
  export FAKE_OSA_DISPLAY_EXIT=1
  run_hook "$completed"
  assert_exit 0
  assert_stdout_trimmed '{}'
}

test_notify_front_bundle_match_visible() {
  harness_use_fakes
  export __CFBundleIdentifier=com.apple.Terminal
  export FAKE_OSA_BUNDLE=com.apple.Terminal
  export FAKE_TMUX_DISPLAY='1 1 1'
  run_hook "$completed"
  assert_not_called terminal-notifier
  assert_log_contains tmux 'display-message'
  assert_log_lacks tmux '-S'
  assert_log_contains tmux '-t'
  assert_log_contains tmux '%12'
  assert_log_contains tmux '#{pane_active} #{window_active} #{session_attached}'
}

test_notify_front_bundle_differs() {
  harness_use_fakes
  export __CFBundleIdentifier=com.apple.Terminal
  export FAKE_OSA_BUNDLE=com.example.Other
  run_hook "$completed"
  assert_notifier_arg -title 'Cursor finished'
  assert_log_lacks tmux 'display-message'
}

test_notify_front_name_in_list() {
  harness_use_fakes
  export FAKE_OSA_NAME=Ghostty
  export FAKE_TMUX_DISPLAY='1 1 1'
  run_hook "$completed"
  assert_not_called terminal-notifier
}

test_notify_front_name_outside_list() {
  harness_use_fakes
  export FAKE_OSA_NAME=Safari
  run_hook "$completed"
  assert_notifier_arg -title 'Cursor finished'
  assert_log_lacks tmux 'display-message'
}

test_notify_frontmost_query_fails() {
  harness_use_fakes
  export FAKE_OSA_EXIT=1
  export __CFBundleIdentifier=com.apple.Terminal
  run_hook "$completed"
  assert_notifier_arg -title 'Cursor finished'
}

test_notify_pane_visible() {
  harness_use_fakes
  export FAKE_OSA_NAME=Terminal
  export FAKE_TMUX_DISPLAY='1 1 1'
  run_hook "$completed"
  assert_not_called terminal-notifier
}

test_notify_other_pane() {
  harness_use_fakes
  export FAKE_OSA_NAME=Terminal
  export FAKE_TMUX_DISPLAY='0 1 1'
  run_hook "$completed"
  assert_notifier_arg -title 'Cursor finished'
}

test_notify_other_window() {
  harness_use_fakes
  export FAKE_OSA_NAME=Terminal
  export FAKE_TMUX_DISPLAY='1 0 1'
  run_hook "$completed"
  assert_notifier_arg -title 'Cursor finished'
}

test_notify_session_detached() {
  harness_use_fakes
  export FAKE_OSA_NAME=Terminal
  export FAKE_TMUX_DISPLAY='1 1 0'
  run_hook "$completed"
  assert_notifier_arg -title 'Cursor finished'
}

test_notify_session_attached_two() {
  harness_use_fakes
  export FAKE_OSA_NAME=Terminal
  export FAKE_TMUX_DISPLAY='1 1 2'
  run_hook "$completed"
  assert_not_called terminal-notifier
}

test_notify_pane_check_fails() {
  harness_use_fakes
  export FAKE_OSA_NAME=Terminal
  export FAKE_TMUX_DISPLAY_EXIT=1
  run_hook "$completed"
  assert_notifier_arg -title 'Cursor finished'
}

test_notify_pane_check_garbage() {
  harness_use_fakes
  export FAKE_OSA_NAME=Terminal
  export FAKE_TMUX_DISPLAY='visible'
  run_hook "$completed"
  assert_notifier_arg -title 'Cursor finished'
}

test_notify_pane_check_socket() {
  harness_use_fakes
  export TMUX=/tmp/sock,123,0
  export FAKE_OSA_NAME=Terminal
  export FAKE_TMUX_DISPLAY='0 1 1'
  run_hook "$completed"
  assert_log_contains tmux '-S'
  assert_log_contains tmux '/tmp/sock'
  assert_log_contains tmux '-t'
  assert_log_contains tmux '%12'
}

test_notify_not_frontmost_skips_pane_check() {
  harness_use_fakes
  export FAKE_OSA_NAME=Safari
  run_hook "$completed"
  assert_notifier_arg -title 'Cursor finished'
  assert_log_lacks tmux 'display-message'
}

# run_notify ARGS...
# Run bin/notify with the given arguments and a valid stop payload on stdin.
run_notify() {
  export TMUX_PANE=%12
  run_capture "$ROOT/bin/notify" "$@" <<<"$completed"
}

test_core_unknown_agent() {
  harness_use_fakes
  run_notify nosuch stop
  expect_silent
}

test_core_bad_agent_name() {
  harness_use_fakes
  run_notify ../lib stop
  expect_silent

  harness_use_fakes
  run_notify 'cur sor' stop
  expect_silent
}

test_core_unknown_event() {
  harness_use_fakes
  run_notify cursor nosuch
  expect_silent
}

test_core_no_args() {
  harness_use_fakes
  run_notify
  expect_silent
}

# number_or and count_or keep a valid setting and replace any other value.
test_core_setting_values() {
  harness_use_fakes
  local got want
  got=$(
    . "$ROOT/bin/lib.sh"
    for value in 0.5 .5 5. 5 0 007 abc 1e3 -1 '' '1 2' 1.2.3 $'1\n2' '$(touch ran)'; do
      printf '%s ' "$(number_or "$value" D)"
    done
    printf '\n'
    for value in 5 010 240 0 000 1.5 abc -3 '' '4 5' 12345678901234567890 '$(touch ran)'; do
      printf '%s ' "$(count_or "$value" D)"
    done
  )
  want=$'0.5 .5 5. 5 0 007 D D D D D D D D \n5 10 240 D D D D D D D D D '
  [ "$got" = "$want" ] || { echo "setting values: got [$got]" >&2; exit 1; }
}

run_tests \
  test_notify_folder_is_not_run \
  test_notify_completed \
  test_notify_error \
  test_notify_body_trailing_slash \
  test_notify_body_root \
  test_notify_body_missing \
  test_notify_body_empty_list \
  test_notify_body_empty_string \
  test_notify_body_number \
  test_notify_group \
  test_notify_group_unknown \
  test_notify_execute_parts \
  test_notify_socket_quote \
  test_notify_no_tmux_env \
  test_notify_execute_absolute \
  test_notify_no_pane \
  test_notify_empty_pane \
  test_notify_no_pane_bad_json \
  test_notify_aborted \
  test_notify_other_status \
  test_notify_status_missing \
  test_notify_status_number \
  test_notify_bad_json \
  test_notify_empty_stdin \
  test_notify_json_array \
  test_notify_json_null \
  test_notify_json_string \
  test_notify_fallback_missing_notifier \
  test_notify_fallback_notifier_fails \
  test_notify_fallback_quote_body \
  test_notify_stdout_always \
  test_notify_front_bundle_match_visible \
  test_notify_front_bundle_differs \
  test_notify_front_name_in_list \
  test_notify_front_name_outside_list \
  test_notify_frontmost_query_fails \
  test_notify_pane_visible \
  test_notify_other_pane \
  test_notify_other_window \
  test_notify_session_detached \
  test_notify_session_attached_two \
  test_notify_pane_check_fails \
  test_notify_pane_check_garbage \
  test_notify_pane_check_socket \
  test_notify_not_frontmost_skips_pane_check \
  test_core_unknown_agent \
  test_core_bad_agent_name \
  test_core_unknown_event \
  test_core_no_args \
  test_core_setting_values
