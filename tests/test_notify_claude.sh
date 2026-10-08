#!/usr/bin/env bash
set -u
source "$(dirname "$0")/harness.sh"

# run_hook EVENT JSON
# For hooks that start no watcher, or whose watcher is not looked at.
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
  run_capture "$ROOT/bin/notify" claude "$event" <<<"$json"
}

stop_json='{"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/app","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done."}'
failure_json='{"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/app","hook_event_name":"StopFailure","error":"rate_limit"}'
prompt_json='{"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/app","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}'
idle_json='{"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/app","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}'

# Pane text as measured on Claude Code 2.1.294.
pane_approval=$'⏺ Bash(touch /tmp/app/x)\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, and always allow access to /tmp/app from this project\n   4. No\n\n Esc to cancel · Tab to amend'
pane_subagent=$' Do you want to proceed?\n ❯ 1. Yes\n   4. No\n\n Esc to cancel · Tab to amend · ctrl+x ctrl+k twice to stop background agents'
pane_question=$' Which color?\n ❯ 1. Red\n   2. Blue\n\nEnter to select · ↑/↓ to navigate · Esc to cancel'
pane_working=$'⏺ Bash(sleep 30)\n  ⎿  Running…\n\n✻ Working… (12s)\n\n❯ \n  ⏸ manual mode on · esc to interrupt · ← for agents'

# The watcher tests start with you looking at the pane and an approval on
# screen. watch_setup PANE sets that scene; a test may change it before
# watch_hook starts the watcher.
watch_setup() {
  harness_use_fakes
  export TMUX_PANE=$1
  export __CFBundleIdentifier=com.apple.Terminal
  fake_set osa-bundle com.apple.Terminal
  fake_set tmux-display '1 1 1'
  fake_set tmux-capture "$pane_approval"
  export NOTIFY_APPROVAL_INTERVAL=0.1
  export NOTIFY_APPROVAL_POLLS=1000
  export NOTIFY_APPROVAL_SLOW_INTERVAL=0.1
  export NOTIFY_APPROVAL_MAX_SECONDS=5
}

# watch_hook [JSON]
# Not through run_capture: bash waits for orphaned workers inside $().
watch_hook() {
  "$ROOT/bin/notify" claude Notification <<<"${1-$prompt_json}" >"$FAKE_LOG/hook.stdout"
  [ "$(cat "$FAKE_LOG/hook.stdout")" = '{}' ] || { echo "hook did not print {}" >&2; exit 1; }
}

look_away() {
  fake_set osa-bundle com.example.Other
}

# Count the lines in the fake tmux log that are exactly WORD.
tmux_calls() {
  local n=0
  if [ -f "$FAKE_LOG/tmux" ]; then
    n=$(grep -c -x -e "$1" "$FAKE_LOG/tmux")
  fi
  printf '%s\n' "${n:-0}"
}

# wait_for_polls N
# Wait up to 5 seconds until N polls found you looking. Such a poll ends with
# the pane check, which the fake tmux logs as a display-message line.
wait_for_polls() {
  local i=0 n=0
  while [ "$i" -lt 50 ]; do
    n=$(tmux_calls display-message)
    if [ "$n" -ge "$1" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "timeout waiting for $1 polls, saw $n" >&2
  exit 1
}

# Wait up to 5 seconds until the watcher has read the pane once.
wait_for_capture() {
  local i=0
  while [ "$i" -lt 50 ]; do
    if [ "$(tmux_calls capture-pane)" -ge 1 ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  echo "timeout waiting for capture-pane" >&2
  exit 1
}

# The line after -message in the notifier log, for the first notification.
notifier_body() {
  grep -A1 -x -e '-message' "$FAKE_LOG/terminal-notifier" | sed -n 2p
}

assert_body() {
  local got
  got=$(notifier_body)
  [ "$got" = "$1" ] || {
    echo "body: expected [$1] got [$got]" >&2
    cat "$FAKE_LOG/terminal-notifier" >&2
    exit 1
  }
}

expect_silent() {
  assert_exit 0
  assert_not_called terminal-notifier
  assert_not_called osascript
  assert_stdout_trimmed '{}'
}

# expect_not_a_prompt PANE
# The watcher reads the pane once, finds no prompt and stops, although you are
# away. A prompt that shows up afterwards is not its business any more.
expect_not_a_prompt() {
  wait_for_capture
  assert_no_watchers "$1"
  fake_set tmux-capture "$pane_approval"
  wait_quiet 0.3
  assert_not_called terminal-notifier
  [ "$(tmux_calls capture-pane)" = 1 ] ||
    { echo "expected one capture-pane, saw $(tmux_calls capture-pane)" >&2; exit 1; }
}

test_claude_adapter_values() {
  harness_use_fakes
  local got want
  got=$(
    . "$ROOT/bin/agents/claude.sh"
    printf '%s|%s|%s|%s\n' "$AGENT_LABEL" "$AGENT_PROMPT_APPEARS_LATER" "$AGENT_CONFIG" "$AGENT_CONFIG_SHAPE"
    agent_hooks
  )
  want=$'Claude|0|.claude/settings.json|nested\nStop\t\nStopFailure\t\nNotification\tpermission_prompt'
  [ "$got" = "$want" ] || { echo "adapter values: got [$got]" >&2; exit 1; }
}

test_claude_stop() {
  harness_use_fakes
  export TMUX=/tmp/sock,1,0
  run_hook Stop "$stop_json"
  assert_exit 0
  assert_stdout_trimmed '{}'
  assert_notifier_calls 1
  assert_log_contains terminal-notifier 'Claude finished'
  assert_body app
  assert_log_contains terminal-notifier 'claude-s1'
  assert_log_contains terminal-notifier "'%12'"
  assert_log_lacks tmux 'capture-pane'
}

test_claude_stop_failure() {
  harness_use_fakes
  run_hook StopFailure "$failure_json"
  assert_exit 0
  assert_stdout_trimmed '{}'
  assert_notifier_calls 1
  assert_log_contains terminal-notifier 'Claude hit an error'
  assert_body app
  assert_log_contains terminal-notifier 'claude-s1'
}

test_claude_stop_while_looking() {
  harness_use_fakes
  export __CFBundleIdentifier=com.apple.Terminal
  fake_set osa-bundle com.apple.Terminal
  fake_set tmux-display '1 1 1'
  run_hook Stop "$stop_json"
  run_hook StopFailure "$failure_json"
  assert_exit 0
  assert_stdout_trimmed '{}'
  assert_not_called terminal-notifier
  # Both hooks got as far as the pane check.
  [ "$(tmux_calls display-message)" = 2 ] ||
    { echo "expected two pane checks, saw $(tmux_calls display-message)" >&2; exit 1; }
}

test_claude_prompt_away() {
  watch_setup %c1
  export TMUX=/tmp/sock,1,0
  look_away
  watch_hook
  wait_for_notifier
  assert_log_contains terminal-notifier 'Claude is waiting for you'
  assert_body app
  assert_log_contains terminal-notifier 'claude-s1'
  assert_log_contains terminal-notifier "'%c1'"
  assert_log_contains terminal-notifier "'/tmp/sock'"
  assert_no_watchers %c1
  assert_notifier_calls 1
}

test_claude_question_away() {
  watch_setup %c2
  fake_set tmux-capture "$pane_question"
  look_away
  watch_hook
  wait_for_notifier
  assert_log_contains terminal-notifier 'Claude is waiting for you'
  assert_body app
  assert_log_contains terminal-notifier 'claude-s1'
  assert_no_watchers %c2
  assert_notifier_calls 1
}

test_claude_subagent_prompt_away() {
  watch_setup %c3
  fake_set tmux-capture "$pane_subagent"
  look_away
  watch_hook
  wait_for_notifier
  assert_log_contains terminal-notifier 'Claude is waiting for you'
  assert_no_watchers %c3
  assert_notifier_calls 1
}

test_claude_look_then_away() {
  watch_setup %c4
  watch_hook
  wait_for_polls 2
  assert_not_called terminal-notifier
  look_away
  wait_for_notifier
  assert_log_contains terminal-notifier 'Claude is waiting for you'
  assert_body app
  assert_no_watchers %c4
  assert_notifier_calls 1
}

test_claude_answered_then_away() {
  watch_setup %c5
  watch_hook
  wait_for_polls 2
  fake_set tmux-capture "$pane_working"
  assert_no_watchers %c5
  look_away
  wait_quiet 0.5
  assert_not_called terminal-notifier
}

test_claude_prompt_already_gone() {
  watch_setup %c6
  fake_set tmux-capture "$pane_working"
  look_away
  watch_hook
  expect_not_a_prompt %c6
}

# The words are in the conversation, above an ordinary last line.
test_claude_marker_not_last_line() {
  watch_setup %c7
  fake_set tmux-capture $'⏺ Press Esc to cancel · Tab to amend\n Esc to cancel · Tab to amend\n\n❯ \n  ? for shortcuts'
  look_away
  watch_hook
  expect_not_a_prompt %c7
}

# A working pane says "esc to interrupt", in lower case.
test_claude_working_footer() {
  watch_setup %c8
  fake_set tmux-capture $'⏺ Bash(sleep 30)\n  ⎿  Running…\n\n  ⏸ manual mode on · esc to interrupt · ← for agents'
  look_away
  watch_hook
  expect_not_a_prompt %c8
}

# A pane taller than its text ends in empty lines, and some hold only spaces.
test_claude_trailing_blank_lines() {
  watch_setup %c9
  fake_set tmux-capture "$pane_approval"$'\n\n   \n \t \n\n'
  look_away
  watch_hook
  wait_for_notifier
  assert_log_contains terminal-notifier 'Claude is waiting for you'
  assert_no_watchers %c9
  assert_notifier_calls 1
}

test_claude_other_notification_type() {
  watch_setup %c10
  look_away
  watch_hook "$idle_json"
  wait_quiet 0.5
  [ -z "$(harness_watchers %c10)" ] || { echo "a watcher was started" >&2; exit 1; }
  assert_not_called terminal-notifier
  assert_log_lacks tmux 'capture-pane'

  # A missing or non-string type is not a permission prompt either.
  watch_hook '{"session_id":"s1","cwd":"/tmp/app","hook_event_name":"Notification"}'
  watch_hook '{"session_id":"s1","cwd":"/tmp/app","notification_type":["permission_prompt"]}'
  watch_hook '{"session_id":"s1","cwd":"/tmp/app","notification_type":"permission_prompt_x"}'
  wait_quiet 0.5
  assert_not_called terminal-notifier
  assert_log_lacks tmux 'capture-pane'
  assert_no_watchers %c10
}

test_claude_no_session() {
  watch_setup %c11
  look_away
  watch_hook '{"cwd":"/tmp/app","hook_event_name":"Notification","notification_type":"permission_prompt"}'
  wait_for_notifier
  assert_log_contains terminal-notifier 'Claude is waiting for you'
  [ "$(grep -A1 -x -e '-group' "$FAKE_LOG/terminal-notifier" | sed -n 2p)" = claude-unknown ] ||
    { echo "group is not claude-unknown" >&2; cat "$FAKE_LOG/terminal-notifier" >&2; exit 1; }
  assert_no_watchers %c11
}

test_claude_no_cwd() {
  watch_setup %c12
  look_away
  watch_hook '{"session_id":"s1","hook_event_name":"Notification","notification_type":"permission_prompt"}'
  wait_for_notifier
  assert_body agent
  assert_no_watchers %c12

  harness_use_fakes
  run_hook Stop '{"session_id":"s1","cwd":"","hook_event_name":"Stop"}'
  assert_log_contains terminal-notifier 'Claude finished'
  assert_body agent

  harness_use_fakes
  run_hook Stop '{"session_id":7,"cwd":7,"hook_event_name":"Stop"}'
  assert_body agent
  assert_log_contains terminal-notifier 'claude-unknown'
}

test_claude_unknown_event() {
  harness_use_fakes
  run_hook PostToolUse "$stop_json"
  expect_silent
  assert_not_called tmux

  # Event names are matched exactly, as Claude Code spells them.
  harness_use_fakes
  run_hook stop "$stop_json"
  expect_silent
  run_hook '' "$prompt_json"
  expect_silent
  assert_not_called tmux
}

test_claude_bad_json() {
  local event json
  for event in Stop StopFailure Notification; do
    for json in 'not json' '' '[]' 'null' '"permission_prompt"' '{"notification_type":'; do
      harness_use_fakes
      run_hook "$event" "$json"
      expect_silent
      assert_not_called tmux
    done
  done
}

test_claude_no_pane() {
  local event
  for event in Stop StopFailure Notification; do
    harness_use_fakes
    KEEP_PANE_UNSET=1
    run_hook "$event" "$prompt_json"
    expect_silent
    assert_not_called tmux
  done

  harness_use_fakes
  export TMUX_PANE=
  run_hook Notification "$prompt_json"
  expect_silent
  assert_not_called tmux
}

# The folder reaches the notifier through the hook and through the watcher's
# arguments. Neither may run it.
test_claude_cwd_is_not_run() {
  watch_setup %c13
  look_away
  local cwd="/tmp/it's \$(touch ran) \`touch ran\`" json
  cd "$FAKE_LOG" || exit 1
  json=$(jq -nc --arg d "$cwd" '{session_id: "s1", cwd: $d, hook_event_name: "Stop"}')
  run_capture "$ROOT/bin/notify" claude Stop <<<"$json"
  assert_stdout_trimmed '{}'
  assert_body "it's \$(touch ran) \`touch ran\`"

  json=$(jq -nc --arg d "$cwd" --arg s "s'1 \$(touch ran)" \
    '{session_id: $s, cwd: $d, notification_type: "permission_prompt"}')
  watch_hook "$json"
  assert_no_watchers %c13
  assert_notifier_calls 2
  [ "$(grep -c -F -x "it's \$(touch ran) \`touch ran\`" "$FAKE_LOG/terminal-notifier")" = 2 ] ||
    { echo "cwd is not the body of both notifications" >&2; cat "$FAKE_LOG/terminal-notifier" >&2; exit 1; }
  assert_log_contains terminal-notifier "claude-s'1 \$(touch ran)"
  if [ -e "$FAKE_LOG/ran" ]; then
    echo "text from hook input was executed" >&2
    exit 1
  fi
}

# Pane text is data too.
test_claude_pane_is_not_run() {
  watch_setup %c14
  cd "$FAKE_LOG" || exit 1
  fake_set tmux-capture $'$(touch ran)\n`touch ran`\n * \n $(touch ran) Esc to cancel `touch ran`'
  look_away
  watch_hook
  wait_for_notifier
  assert_no_watchers %c14
  if [ -e "$FAKE_LOG/ran" ]; then
    echo "text from the pane was executed" >&2
    exit 1
  fi
}

run_tests \
  test_claude_adapter_values \
  test_claude_stop \
  test_claude_stop_failure \
  test_claude_stop_while_looking \
  test_claude_prompt_away \
  test_claude_question_away \
  test_claude_subagent_prompt_away \
  test_claude_look_then_away \
  test_claude_answered_then_away \
  test_claude_prompt_already_gone \
  test_claude_marker_not_last_line \
  test_claude_working_footer \
  test_claude_trailing_blank_lines \
  test_claude_other_notification_type \
  test_claude_no_session \
  test_claude_no_cwd \
  test_claude_unknown_event \
  test_claude_bad_json \
  test_claude_no_pane \
  test_claude_cwd_is_not_run \
  test_claude_pane_is_not_run
