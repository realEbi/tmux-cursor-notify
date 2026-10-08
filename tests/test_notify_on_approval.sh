#!/usr/bin/env bash
set -u
source "$(dirname "$0")/harness.sh"

run_hook() {
  local json=$1
  export NOTIFY_APPROVAL_POLLS=1
  export NOTIFY_APPROVAL_INTERVAL=0
  if [ "${KEEP_PANE_UNSET-}" = 1 ]; then
    unset TMUX_PANE
  elif [ -z "${TMUX_PANE+x}" ]; then
    export TMUX_PANE=%12
  fi
  run_capture "$ROOT/bin/notify-on-approval" <<<"$json"
}

shell_json='{"command":"npm install deps","conversation_id":"c1","workspace_roots":["/tmp/app"]}'
mcp_json='{"tool_name":"search_docs","tool_input":"{\"query\":\"long enough\"}","conversation_id":"c1","workspace_roots":["/tmp/app"]}'

prompt_shell=$'line1\nRun this command?\nAllow once (y)\nnpm install deps'
prompt_mcp=$'Run this MCP tool?\nAllow once\nsearch_docs'

test_approval_no_pane() {
  harness_use_fakes
  KEEP_PANE_UNSET=1
  export NOTIFY_APPROVAL_DELAY=0
  run_hook "$shell_json"
  assert_exit 0
  assert_stdout_trimmed '{}'
  wait_quiet
  assert_not_called terminal-notifier
}

test_approval_no_prompt() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_TMUX_CAPTURE=$'agent working\nno card here'
  run_hook "$shell_json"
  assert_exit 0
  assert_stdout_trimmed '{}'
  wait_quiet
  assert_not_called terminal-notifier
}

test_approval_shell_notifies() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  export FAKE_TMUX_CAPTURE="$prompt_shell"
  export TMUX=/tmp/sock,1,0
  export TMUX_PANE=%12
  export __CFBundleIdentifier=com.apple.Terminal
  run_hook "$shell_json"
  assert_exit 0
  assert_stdout_trimmed '{}'
  wait_for_notifier
  assert_log_contains terminal-notifier 'Cursor needs approval'
  assert_log_contains terminal-notifier 'npm install deps'
  assert_log_contains terminal-notifier 'cursor-c1'
  assert_log_contains terminal-notifier 'Glass'
  local fp
  fp=$(cd "$ROOT/bin" && pwd -P)/focus-pane
  assert_log_contains terminal-notifier "'$fp'"
  assert_log_contains terminal-notifier "'%12'"
}

test_approval_mcp_notifies() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  export FAKE_TMUX_CAPTURE="$prompt_mcp"
  run_hook "$mcp_json"
  wait_for_notifier
  assert_log_contains terminal-notifier 'Cursor needs approval'
  assert_log_contains terminal-notifier 'cursor-c1'
}

test_approval_stale_prompt_skipped() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  local pad i
  pad=$'Run this command?\nAllow once\nother-command-xyz'
  for i in $(seq 1 16); do
    pad=$pad$'\n'"pad-$i"
  done
  export FAKE_TMUX_CAPTURE="$pad"
  run_hook "$shell_json"
  wait_quiet
  assert_not_called terminal-notifier
}

test_approval_short_snippet_ok() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  export FAKE_TMUX_CAPTURE=$'Run this command?\nAllow once\nls'
  run_hook '{"command":"ls","conversation_id":"c1"}'
  wait_for_notifier
  assert_log_contains terminal-notifier 'Cursor needs approval'
}

test_approval_visible_pane_silent() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Terminal
  export FAKE_TMUX_DISPLAY='1 1 1'
  export FAKE_TMUX_CAPTURE="$prompt_shell"
  run_hook "$shell_json"
  wait_quiet
  assert_not_called terminal-notifier
}

test_approval_returns_before_delay() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=5
  export FAKE_TMUX_CAPTURE="$prompt_shell"
  export TMUX_PANE=%12
  # Avoid command substitution: bash waits for orphaned workers inside $().
  "$ROOT/bin/notify-on-approval" <<<"$shell_json" >"$FAKE_LOG/hook.stdout"
  LAST_STDOUT=$(cat "$FAKE_LOG/hook.stdout")
  LAST_STATUS=0
  assert_exit 0
  assert_stdout_trimmed '{}'
  assert_not_called terminal-notifier
}


test_approval_wrapped_snippet_prefix() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  long_cmd='npm install very-long-package-name-that-wraps'
  export FAKE_TMUX_CAPTURE=$'Run this command?\nAllow once (y)\nnpm install very-long-\npackage-name-that-wraps'
  run_hook "$(printf '{"command":"%s","conversation_id":"c1"}' "$long_cmd")"
  wait_for_notifier
  assert_log_contains terminal-notifier 'Cursor needs approval'
}

test_approval_command_is_not_run() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  local cmd="echo 'it' \$(touch $FAKE_LOG/ran)"
  export FAKE_TMUX_CAPTURE=$'Run this command?\n'"$cmd"
  run_hook "$(jq -nc --arg c "$cmd" '{command: $c, conversation_id: "c1"}')"
  assert_stdout_trimmed '{}'
  wait_for_notifier
  assert_log_contains terminal-notifier "\$(touch"
  if [ -e "$FAKE_LOG/ran" ]; then
    echo "command from hook input was executed" >&2
    exit 1
  fi
}

test_approval_bad_json() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_TMUX_CAPTURE=$'agent working'
  run_hook 'not json'
  assert_exit 0
  assert_stdout_trimmed '{}'
}

run_tests \
  test_approval_command_is_not_run \
  test_approval_bad_json \
  test_approval_no_pane \
  test_approval_no_prompt \
  test_approval_shell_notifies \
  test_approval_mcp_notifies \
  test_approval_stale_prompt_skipped \
  test_approval_short_snippet_ok \
  test_approval_visible_pane_silent \
  test_approval_wrapped_snippet_prefix \
  test_approval_returns_before_delay
