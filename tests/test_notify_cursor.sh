#!/usr/bin/env bash
set -u
source "$(dirname "$0")/harness.sh"

run_hook() {
  local event=$1 json=$2
  export NOTIFY_APPROVAL_POLLS=1
  export NOTIFY_APPROVAL_INTERVAL=0
  export NOTIFY_APPROVAL_MAX_SECONDS=2
  if [ "${KEEP_PANE_UNSET-}" = 1 ]; then
    unset TMUX_PANE
  elif [ -z "${TMUX_PANE+x}" ]; then
    export TMUX_PANE=%12
  fi
  run_capture "$ROOT/bin/notify" cursor "$event" <<<"$json"
}

shell_json='{"command":"npm install deps","conversation_id":"c1","workspace_roots":["/tmp/app"]}'
mcp_json='{"tool_name":"search_docs","tool_input":"{\"query\":\"long enough\"}","conversation_id":"c1","workspace_roots":["/tmp/app"]}'

prompt_shell=$'line1\nRun this command?\nAllow once (y)\nnpm install deps'
prompt_mcp=$'Run this MCP tool?\nAllow once\nsearch_docs'

test_approval_no_pane() {
  harness_use_fakes
  KEEP_PANE_UNSET=1
  export NOTIFY_APPROVAL_DELAY=0
  run_hook beforeShellExecution "$shell_json"
  assert_exit 0
  assert_stdout_trimmed '{}'
  wait_quiet
  assert_not_called terminal-notifier
}

test_approval_no_prompt() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_TMUX_CAPTURE=$'agent working\nno card here'
  run_hook beforeShellExecution "$shell_json"
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
  run_hook beforeShellExecution "$shell_json"
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
  run_hook beforeMCPExecution "$mcp_json"
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
  run_hook beforeShellExecution "$shell_json"
  wait_quiet
  assert_not_called terminal-notifier
}

test_approval_short_snippet_ok() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  export FAKE_TMUX_CAPTURE=$'Run this command?\nAllow once\nls'
  run_hook beforeShellExecution '{"command":"ls","conversation_id":"c1"}'
  wait_for_notifier
  assert_log_contains terminal-notifier 'Cursor needs approval'
}

test_approval_visible_pane_silent() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Terminal
  export FAKE_TMUX_DISPLAY='1 1 1'
  export FAKE_TMUX_CAPTURE="$prompt_shell"
  run_hook beforeShellExecution "$shell_json"
  wait_quiet
  assert_not_called terminal-notifier
}

test_approval_returns_before_delay() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=5
  export FAKE_TMUX_CAPTURE="$prompt_shell"
  export TMUX_PANE=%w7
  # Avoid command substitution: bash waits for orphaned workers inside $().
  "$ROOT/bin/notify" cursor beforeShellExecution <<<"$shell_json" >"$FAKE_LOG/hook.stdout"
  LAST_STDOUT=$(cat "$FAKE_LOG/hook.stdout")
  LAST_STATUS=0
  assert_exit 0
  assert_stdout_trimmed '{}'
  assert_not_called terminal-notifier
  # The watcher is still in its delay. Stop it so it does not outlive the test.
  local pid rest
  while read -r pid rest; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done <<<"$(harness_watchers %w7)"
  assert_no_watchers %w7
}

test_approval_other_command_silent() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  export FAKE_TMUX_CAPTURE=$'Run this command?\nAllow once\nother-command-xyz'
  run_hook beforeShellExecution "$shell_json"
  wait_quiet
  assert_not_called terminal-notifier
}

test_approval_body_is_folder_without_detail() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  export FAKE_TMUX_CAPTURE="$prompt_shell"
  run_hook beforeShellExecution '{"conversation_id":"c1","workspace_roots":["/tmp/app/"]}'
  wait_for_notifier
  assert_log_contains terminal-notifier 'Cursor needs approval'
  [ "$(grep -A1 -x -e '-message' "$FAKE_LOG/terminal-notifier" | tail -n 1)" = app ] ||
    { echo "body is not the folder" >&2; cat "$FAKE_LOG/terminal-notifier" >&2; exit 1; }
}

test_approval_long_body_cut() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  local cmd body
  cmd=$(printf 'x%.0s' $(seq 1 100))
  export FAKE_TMUX_CAPTURE=$'Run this command?\n'"$cmd"
  run_hook beforeShellExecution "$(jq -nc --arg c "$cmd" '{command: $c, conversation_id: "c1"}')"
  wait_for_notifier
  body=$(grep -A1 -x -e '-message' "$FAKE_LOG/terminal-notifier" | tail -n 1)
  [ "$body" = "${cmd:0:79}…" ] || { echo "body not cut to 79 plus ellipsis: [$body]" >&2; exit 1; }
}

test_approval_non_object_payload() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  export FAKE_TMUX_CAPTURE="$prompt_shell"
  run_hook beforeShellExecution '["npm install deps"]'
  assert_exit 0
  assert_stdout_trimmed '{}'
  wait_quiet 1
  assert_not_called terminal-notifier
  assert_not_called tmux
}

# The watcher tests below start with the card up and you looking at the pane.
# watch_setup PANE sets that scene; a test may change the pacing before
# watch_hook starts the watcher.
watch_setup() {
  harness_use_fakes
  export TMUX_PANE=$1
  export __CFBundleIdentifier=com.apple.Terminal
  fake_set osa-bundle com.apple.Terminal
  fake_set tmux-display '1 1 1'
  fake_set tmux-capture "$prompt_shell"
  export NOTIFY_APPROVAL_DELAY=0
  export NOTIFY_APPROVAL_INTERVAL=0.1
  export NOTIFY_APPROVAL_POLLS=1000
  export NOTIFY_APPROVAL_SLOW_INTERVAL=0.1
  export NOTIFY_APPROVAL_MAX_SECONDS=5
}

watch_hook() {
  "$ROOT/bin/notify" cursor beforeShellExecution <<<"$shell_json" >"$FAKE_LOG/hook.stdout"
}

look_away() {
  fake_set osa-bundle com.example.Other
}

# wait_for_polls N
# Wait up to 5 seconds until N polls found you looking. Such a poll ends with
# the pane check, which the fake tmux logs as a display-message line.
wait_for_polls() {
  local i=0 n=0
  while [ "$i" -lt 50 ]; do
    n=$(grep -c -x -e 'display-message' "$FAKE_LOG/tmux" 2>/dev/null)
    if [ "${n:-0}" -ge "$1" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "timeout waiting for $1 polls, saw ${n:-0}" >&2
  exit 1
}

# wait_for_watchers PANE N
# Wait up to 3 seconds until exactly N watchers run for PANE.
wait_for_watchers() {
  local i=0 found n=0
  while [ "$i" -lt 30 ]; do
    found=$(harness_watchers "$1") || exit 1
    n=0
    [ -n "$found" ] && n=$(printf '%s\n' "$found" | grep -c .)
    if [ "$n" = "$2" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "expected $2 watchers for pane $1, found $n" >&2
  exit 1
}

test_watch_look_then_away() {
  watch_setup %w1
  watch_hook
  wait_for_polls 2
  assert_not_called terminal-notifier
  look_away
  wait_for_notifier
  assert_log_contains terminal-notifier 'Cursor needs approval'
  assert_log_contains terminal-notifier 'npm install deps'
  assert_no_watchers %w1
  assert_notifier_calls 1
}

test_watch_answered_then_away() {
  watch_setup %w2
  watch_hook
  wait_for_polls 2
  fake_set tmux-capture 'agent working'
  assert_no_watchers %w2
  look_away
  wait_quiet 0.5
  assert_not_called terminal-notifier
}

test_watch_pane_gone() {
  watch_setup %w3
  watch_hook
  wait_for_polls 2
  fake_set tmux-capture-exit 1
  assert_no_watchers %w3
  look_away
  wait_quiet 0.5
  assert_not_called terminal-notifier
}

test_watch_second_replaces_first() {
  watch_setup %w4
  watch_hook
  wait_for_polls 1
  wait_for_watchers %w4 1
  watch_hook
  wait_for_watchers %w4 1
  wait_for_polls 4
  look_away
  wait_for_notifier
  wait_quiet 0.5
  assert_notifier_calls 1
  assert_no_watchers %w4
  # The last watcher cleans up the pane file.
  [ -z "$(ls -A "$TMPDIR/tmux-agent-notify")" ] ||
    { echo "pane file left behind: $(ls -A "$TMPDIR/tmux-agent-notify")" >&2; exit 1; }
}

test_watch_budget_reached() {
  watch_setup %w5
  export NOTIFY_APPROVAL_MAX_SECONDS=1
  watch_hook
  wait_for_polls 1
  wait_quiet 2
  assert_no_watchers %w5
  look_away
  wait_quiet 0.5
  assert_not_called terminal-notifier
}

test_watch_slow_phase_still_notifies() {
  watch_setup %w6
  export NOTIFY_APPROVAL_POLLS=1
  export NOTIFY_APPROVAL_SLOW_INTERVAL=0.1
  export NOTIFY_APPROVAL_MAX_SECONDS=3
  watch_hook
  # Three polls: the fast phase is one poll long, so the rest are slow ones.
  wait_for_polls 3
  look_away
  wait_for_notifier
  assert_log_contains terminal-notifier 'Cursor needs approval'
  assert_no_watchers %w6
  assert_notifier_calls 1
}

test_watch_hook_returns_while_watching() {
  watch_setup %w8
  SECONDS=0
  watch_hook
  [ "$SECONDS" -le 1 ] || { echo "hook took $SECONDS seconds" >&2; exit 1; }
  [ "$(cat "$FAKE_LOG/hook.stdout")" = '{}' ] || { echo "hook did not print {}" >&2; exit 1; }
  wait_for_polls 2
  wait_for_watchers %w8 1
  fake_set tmux-capture 'agent working'
  assert_no_watchers %w8
  assert_not_called terminal-notifier
}

# A pane id is data: it must not be read as a path or a printf format.
test_watch_odd_pane_id() {
  watch_setup '%s/../%d'
  watch_hook
  wait_for_polls 2
  [ "$(ls -A "$TMPDIR/tmux-agent-notify")" = 'pane-%s____%d' ] ||
    { echo "unexpected pane file: $(ls -A "$TMPDIR/tmux-agent-notify")" >&2; exit 1; }
  look_away
  wait_for_notifier
  assert_log_contains terminal-notifier "'%s/../%d'"
  assert_no_watchers '%s/../%d'
}


test_approval_wrapped_snippet_prefix() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  long_cmd='npm install very-long-package-name-that-wraps'
  export FAKE_TMUX_CAPTURE=$'Run this command?\nAllow once (y)\nnpm install very-long-\npackage-name-that-wraps'
  run_hook beforeShellExecution "$(printf '{"command":"%s","conversation_id":"c1"}' "$long_cmd")"
  wait_for_notifier
  assert_log_contains terminal-notifier 'Cursor needs approval'
}

test_approval_command_is_not_run() {
  harness_use_fakes
  export NOTIFY_APPROVAL_DELAY=0
  export FAKE_OSA_NAME=Safari
  local cmd="echo 'it' \$(touch $FAKE_LOG/ran)"
  export FAKE_TMUX_CAPTURE=$'Run this command?\n'"$cmd"
  run_hook beforeShellExecution "$(jq -nc --arg c "$cmd" '{command: $c, conversation_id: "c1"}')"
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
  run_hook beforeShellExecution 'not json'
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
  test_approval_returns_before_delay \
  test_approval_other_command_silent \
  test_approval_body_is_folder_without_detail \
  test_approval_long_body_cut \
  test_approval_non_object_payload \
  test_watch_look_then_away \
  test_watch_answered_then_away \
  test_watch_pane_gone \
  test_watch_second_replaces_first \
  test_watch_budget_reached \
  test_watch_slow_phase_still_notifies \
  test_watch_hook_returns_while_watching \
  test_watch_odd_pane_id
