# tmux-agent-notify Implementation Plan

**Goal:** Make the notifier work for any agentic CLI in a tmux pane. Keep Cursor behaving as it does today, add Claude Code, and leave Codex as one new adapter file.

**Architecture:** Every hook runs `bin/notify <agent> <hook-event>`. An adapter in `bin/agents/<agent>.sh` turns the payload into a kind (`finished`, `failed`, `attention`) and says whether its prompt is on screen. The core in `bin/notify` and `bin/lib.sh` does the pane guard, focus check, notification, and the look-away watcher. `bin/install [agent...]` merges hooks into each agent's config file.

**Tech stack:** bash (macOS `/bin/bash` 3.2), `jq`, `perl` (fork and `setsid`), `tmux`, `terminal-notifier` with an `osascript` fallback.

**Spec:** `docs/superpowers/specs/2026-10-08-tmux-agent-notify-design.md`. It builds on `docs/superpowers/specs/2026-09-29-tmux-cursor-notify-design.md`, which still governs the focus check, the click action, and notification posting.

## Global constraints

- Work on a branch named `agent-notify`, not on `main`. One commit per task. `bash tests/run.sh` passes at the end of every task.
- bash 3.2 only: no associative arrays, no namerefs, no `${var,,}`.
- Every hook path prints `{}` plus a newline and exits 0, including unknown agents, unknown events, bad JSON, and a missing `TMUX_PANE`.
- Payload values are read with `jq` and passed as data. Nothing from a payload or from the pane is ever executed.
- The agent name comes from argv and is used to build a file path. Accept only lowercase letters; anything else is treated as an unknown agent.
- Tests never start a real agent and never read or write the real `~/.cursor`, `~/.claude`, or `~/.codex`. Installer tests use a temp `HOME`.
- `bin/focus-pane` and its tests are not changed.
- The old scripts `bin/notify-on-stop` and `bin/notify-on-approval` stay in place until Task 5, so an existing install keeps working while the work is in progress.

## Review focus

The cases most likely to go wrong. Each has a named test in the task that owns it.

1. Looking when the prompt appears, then away with the prompt still up: must notify. `test_watch_look_then_away` (Task 3, Cursor) and `test_claude_look_then_away` (Task 4).
2. Prompt answered, then away: must stay silent. `test_watch_answered_then_away` (Task 3) and `test_claude_answered_then_away` (Task 4).
3. Pane killed while a watcher runs: must stay silent. `test_watch_pane_gone` (Task 3).
4. Two `attention` events for one pane: one notification at most. `test_watch_second_replaces_first` (Task 3).
5. `Esc to cancel` somewhere above the last line of the pane: not a prompt. `test_claude_marker_not_last_line` (Task 4).
6. Installer removal rules delete our old entries and nothing else. `test_install_removes_old_entries` and `test_install_keeps_unrelated` (Task 5).
7. A second install adds nothing, for both file shapes. `test_install_idempotent` and `test_install_claude_idempotent` (Task 5).
8. No watcher outlives its test. Every watcher test sets `NOTIFY_APPROVAL_MAX_SECONDS`; Task 1 adds a leak check to the harness.

## File map

| File | Task | Change |
| --- | --- | --- |
| `tests/harness.sh`, `tests/fakes/tmux`, `tests/fakes/osascript` | 1 | file-driven fakes, shared wait helpers, leak check |
| `bin/notify` | 2, 3 | new entry point; watcher added in Task 3 |
| `bin/agents/cursor.sh` | 2, 3 | new adapter; prompt check added in Task 3 |
| `bin/lib.sh` | 2, 3 | header comment; watcher helpers |
| `tests/test_notify_core.sh` | 2 | renamed from `test_notify_on_stop.sh` |
| `tests/test_notify_cursor.sh` | 3 | renamed from `test_notify_on_approval.sh` |
| `bin/agents/claude.sh`, `tests/test_notify_claude.sh` | 4 | new |
| `bin/install`, `tests/test_install.sh` | 5 | agent arguments, two file shapes, removal rules |
| `bin/notify-on-stop`, `bin/notify-on-approval` | 5 | deleted |
| `readme.md` | 6 | rewritten |

## Adapter interface

The spec leaves the bash form open. This plan fixes it so the tasks agree. An adapter is sourced, never run, and defines:

- `AGENT_LABEL` — `Cursor`, `Claude`.
- `AGENT_PROMPT_APPEARS_LATER` — `1` when the prompt shows up after the `attention` hook (Cursor), `0` when it is already up (Claude Code).
- `AGENT_CONFIG` — config path relative to `HOME`: `.cursor/hooks.json`, `.claude/settings.json`.
- `AGENT_CONFIG_SHAPE` — `flat` (Cursor's `{command}` entries with `version: 1`) or `nested` (Claude Code's `{matcher?, hooks: [{type, command}]}`).
- `agent_hooks` — prints one line per hook: the event name, a tab, and the matcher (empty for none).
- `agent_parse EVENT INPUT` — sets the globals `kind`, `session`, `folder`, `detail`, `title`. `folder` is the raw path; the core takes its last component. An event it does not know leaves `kind` empty.
- `agent_prompt_on_screen SCREEN DETAIL` — returns 0 when this agent's prompt is in the pane text.

Watcher invocation, used by the core only: `bin/notify --watch <agent> <pane> <title> <body> <group> <detail>`.

---

### Task 1: test harness that can change state mid-run

The look-away tests need the fakes to give a different answer on a later call. Today they read fixed environment variables. No `bin/` file changes in this task.

**Files:** `tests/harness.sh`, `tests/fakes/tmux`, `tests/fakes/osascript`.

- [ ] `harness_use_fakes` creates `FAKE_STATE` (a temp dir), exports it, and exports `TMPDIR` set to another temp dir.
- [ ] Add `fake_set NAME VALUE` to the harness. It writes `$FAKE_STATE/NAME` through a temp file and `/bin/mv`, so a watcher never reads a half-written value.
- [ ] Fake `tmux`: for `capture-pane`, print `$FAKE_STATE/tmux-capture` when that file exists, otherwise `$FAKE_TMUX_CAPTURE`; exit with `$FAKE_STATE/tmux-capture-exit` when that file exists, otherwise `$FAKE_TMUX_CAPTURE_EXIT`, otherwise 0. For `display-message`, print `$FAKE_STATE/tmux-display` when it exists, otherwise the current variable.
- [ ] Fake `osascript`: for the two frontmost queries, print `$FAKE_STATE/osa-bundle` or `$FAKE_STATE/osa-name` when the file exists, otherwise the current variables.
- [ ] Move `wait_for_notifier` and `wait_followup` from `tests/test_notify_on_approval.sh` into the harness. Rename `wait_followup` to `wait_quiet`.
- [ ] Add `assert_notifier_calls N`: counts `-title` lines in the notifier log and fails when the count differs. A missing log counts as 0.
- [ ] Add `assert_no_watchers PANE`: fails when a process whose command line contains both `--watch` and that pane id is still alive after a short grace period. Each watcher test uses its own pane id, such as `%w3`, so the match cannot hit another test's watcher.
- [ ] Run `bash tests/run.sh`. All 87 existing tests still pass, since every new input falls back to the old variable.
- [ ] Commit: `test: let fakes change their answers while a watcher runs`.

### Task 2: entry point and the Cursor adapter for finished and failed

**Files:** create `bin/notify`, `bin/agents/cursor.sh`; rename `tests/test_notify_on_stop.sh` to `tests/test_notify_core.sh`; edit the header comment of `bin/lib.sh`.

- [ ] `git mv tests/test_notify_on_stop.sh tests/test_notify_core.sh`. Change `run_hook` to call `"$ROOT/bin/notify" cursor stop`. Rename nothing else; the 52 cases stay as they are.
- [ ] Add failing tests to `tests/test_notify_core.sh`, each asserting exit 0, stdout `{}`, and no notifier call:
  - `test_core_unknown_agent` — `bin/notify nosuch stop`.
  - `test_core_bad_agent_name` — `bin/notify ../lib stop` and `bin/notify 'cur sor' stop`.
  - `test_core_unknown_event` — `bin/notify cursor nosuch`.
  - `test_core_no_args` — `bin/notify` with a valid payload on stdin.
- [ ] Run the suite and confirm the renamed file fails (no `bin/notify` yet).
- [ ] Write `bin/agents/cursor.sh`: the variables above, `agent_hooks` with the three Cursor events, and `agent_parse` for `stop`. It maps `status: completed` to `finished` with title `Cursor finished`, `status: error` to `failed` with title `Cursor hit an error`, and anything else to an empty kind. Reuse the single `jq` read from `bin/notify-on-stop`.
- [ ] Write `bin/notify`:
  1. Source `lib.sh`. Read stdin.
  2. When `TMUX_PANE` is empty, the agent name is not lowercase letters only, or `agents/<agent>.sh` does not exist, print `{}` and exit.
  3. Source the adapter, call `agent_parse`.
  4. Derive the folder name (last path component, `agent` when empty) and the group id (`<agent>-<session>` or `<agent>-unknown`).
  5. For `finished` and `failed`: notify unless the terminal is frontmost and the pane is visible.
  6. Print `{}`.
- [ ] `chmod +x bin/notify`. Run the suite; everything passes.
- [ ] Commit: `feat: add bin/notify entry point with a Cursor adapter`.

### Task 3: the watcher, and Cursor approvals through it

The loop in `bin/notify-on-approval` moves into the core and gains four things: an adapter-supplied prompt check, a silent exit when the pane is gone, one watcher per pane, and the longer budget.

**Files:** `bin/notify`, `bin/lib.sh`, `bin/agents/cursor.sh`; rename `tests/test_notify_on_approval.sh` to `tests/test_notify_cursor.sh`.

- [ ] `git mv tests/test_notify_on_approval.sh tests/test_notify_cursor.sh`. Change `run_hook` to take the event as an argument and call `"$ROOT/bin/notify" cursor <event>`; existing cases pass `beforeShellExecution`, and the MCP case passes `beforeMCPExecution`. Add `export NOTIFY_APPROVAL_MAX_SECONDS=2` to `run_hook`.
- [ ] Add failing tests. Each uses its own pane id and ends with `assert_no_watchers <pane id>`:
  - `test_watch_look_then_away` — card on screen, terminal frontmost and pane visible; after a short wait `fake_set osa-bundle com.example.Other`; expect one `Cursor needs approval`.
  - `test_watch_answered_then_away` — card on screen while looking; `fake_set tmux-capture 'agent working'`; then switch the frontmost app; expect no notifier call.
  - `test_watch_pane_gone` — card on screen while looking; `fake_set tmux-capture-exit 1`; then switch the frontmost app; expect no notifier call.
  - `test_watch_second_replaces_first` — card on screen while looking; run the hook twice; switch the frontmost app; `assert_notifier_calls 1`.
  - `test_watch_budget_reached` — card on screen while looking, `NOTIFY_APPROVAL_MAX_SECONDS=1`; wait two seconds; then switch the frontmost app; expect no notifier call.
  - `test_watch_slow_phase_still_notifies` — `NOTIFY_APPROVAL_POLLS=1`, `NOTIFY_APPROVAL_SLOW_INTERVAL=0.1`, `NOTIFY_APPROVAL_MAX_SECONDS=3`; look, then away after the fast phase is over; expect one notification.
- [ ] Add to `bin/agents/cursor.sh`: `agent_parse` for `beforeShellExecution` and `beforeMCPExecution` (kind `attention`, `detail` from `command` or `tool_name`, title `Cursor needs approval`), and `agent_prompt_on_screen`, which is today's `card_is_shown` and `card_is_for` applied to the last 15 lines.
- [ ] Add the watcher to `bin/notify`, entered through `--watch`. Follow the poll order in the spec's **Watcher** section exactly:
  1. Take over the pane: write this process id to `${TMPDIR:-/tmp}/tmux-agent-notify/pane-<pane id>`.
  2. When `AGENT_PROMPT_APPEARS_LATER` is 1, sleep `NOTIFY_APPROVAL_DELAY`.
  3. Loop. Exit when the pane file holds another id. Capture the pane; exit when that fails. Apply the appear rule and the notify rule.
  4. Sleep `NOTIFY_APPROVAL_INTERVAL` for the first `NOTIFY_APPROVAL_POLLS` polls and `NOTIFY_APPROVAL_SLOW_INTERVAL` after that. Stop when `$SECONDS` reaches `NOTIFY_APPROVAL_MAX_SECONDS`.
  5. On every exit path, remove the pane file when it still holds this process id.
- [ ] In `bin/notify`, handle `attention`: fork the watcher with the `perl` and `setsid` line from `bin/notify-on-approval`, passing agent, pane, title, body, group, and detail. The hook does not notify.
- [ ] Run the suite. The existing approval cases and the six new ones pass.
- [ ] Commit: `feat: move the approval watcher into the core`.

Notes for this task:

- `capture-pane` must not be piped straight into `tail`, or its exit status is lost. Capture first, check the status, then cut to the last lines inside the adapter.
- `$SECONDS` counts whole seconds, which is enough for a budget measured in minutes.
- An unwritable pane file is not an error. The watcher continues without the takeover check.

### Task 4: Claude Code adapter

**Files:** create `bin/agents/claude.sh`, `tests/test_notify_claude.sh`.

Fixture payloads use the fields the hooks send: `session_id`, `transcript_path`, `cwd`, `hook_event_name`, plus `notification_type` and `message` for `Notification`, and `error` for `StopFailure`.

A realistic pane for the prompt tests, taken from the measurements:

```
 Do you want to proceed?
 ❯ 1. Yes
   4. No

 Esc to cancel · Tab to amend
```

and for a question: `Enter to select · ↑/↓ to navigate · Esc to cancel` as the last line.

- [ ] Write failing tests:
  - `test_claude_stop` — title `Claude finished`, body `app` for `cwd` `/tmp/app`, group `claude-s1`.
  - `test_claude_stop_failure` — title `Claude hit an error`.
  - `test_claude_stop_while_looking` — terminal frontmost and pane visible: no notifier call.
  - `test_claude_prompt_away` — `Notification` with `permission_prompt`, approval pane, terminal not frontmost: one `Claude is waiting for you`, body `app`, group `claude-s1`.
  - `test_claude_question_away` — the same with the question pane.
  - `test_claude_look_then_away` — looking, then the frontmost app changes: one notification.
  - `test_claude_answered_then_away` — looking, the pane changes to a working screen, then the frontmost app changes: no notifier call.
  - `test_claude_prompt_already_gone` — the pane shows no prompt at the first poll and the user is away: no notifier call.
  - `test_claude_marker_not_last_line` — `Esc to cancel` on an earlier line with an ordinary last line: no notifier call.
  - `test_claude_trailing_blank_lines` — the prompt's footer followed by blank lines still counts.
  - `test_claude_other_notification_type` — `idle_prompt`: no notifier call, and no watcher started.
  - `test_claude_unknown_event` — `bin/notify claude PostToolUse`: silent.
  - `test_claude_bad_json` and `test_claude_no_pane` — silent, stdout `{}`.
  - `test_claude_cwd_is_not_run` — a `cwd` containing quotes and `$(...)` appears literally in the body.
- [ ] Write `bin/agents/claude.sh`: label `Claude`, `AGENT_PROMPT_APPEARS_LATER=0`, config `.claude/settings.json`, shape `nested`, `agent_hooks` printing `Stop`, `StopFailure`, and `Notification` with matcher `permission_prompt`. `agent_parse` maps the three events as in the spec's table, with `detail` empty. `agent_prompt_on_screen` finds the last non-empty line of the pane text and tests it for `Esc to cancel`.
- [ ] Run the suite; all pass.
- [ ] Commit: `feat: add the Claude Code adapter`.

### Task 5: installer

**Files:** `bin/install`, `tests/test_install.sh`; delete `bin/notify-on-stop`, `bin/notify-on-approval`.

- [ ] Update the existing 18 tests: `run_install` passes `cursor`; the expected commands become `<bin>/notify cursor stop`, `<bin>/notify cursor beforeShellExecution`, and `<bin>/notify cursor beforeMCPExecution`.
- [ ] Add failing tests:
  - `test_install_removes_old_entries` — a `hooks.json` holding `<bin>/notify-on-stop`, `/elsewhere/tmux-cursor-notify/bin/notify-on-approval`, and `/elsewhere/tmux-cursor-notify/bin/notify cursor stop`: all three are gone and the new entries are present.
  - `test_install_keeps_unrelated` — entries such as `/usr/local/bin/notify cursor stop` and `/x/other-tool/bin/notify-on-stop` survive.
  - `test_install_claude_creates` — no `~/.claude`: `bin/install claude` creates the directory and a file with the three events, the matcher only on `Notification`, `type` `command`, and the path single-quoted.
  - `test_install_claude_merges` — existing keys (`permissions`, `env`) and existing hooks under `Stop` are kept.
  - `test_install_claude_idempotent` — a second run changes nothing.
  - `test_install_claude_removes_stale` — a group whose only hook is our command under another `tmux-agent-notify` path is removed entirely; a group that also holds someone else's hook keeps that hook.
  - `test_install_claude_invalid` — invalid JSON, an array root, a non-object `hooks`, and a non-array `Stop` each leave the file unchanged and exit non-zero.
  - `test_install_claude_path_with_quote` — a checkout path containing `'` produces a command that a shell splits back into the original path and two arguments.
  - `test_install_detects_agents` — no arguments with only `~/.claude` present installs Claude Code and does not create `~/.cursor`; with both present installs both; with neither exits non-zero with an `install:` error.
  - `test_install_unknown_agent` — `bin/install cursor nosuch` exits non-zero and writes nothing for either.
  - `test_install_one_fails_other_continues` — an invalid `hooks.json` and a valid `settings.json`: Claude Code is installed, the exit status is non-zero.
  - `test_install_prints_agents` — one line per agent installed.
- [ ] Rewrite `bin/install`:
  1. Resolve `bin_dir` as today. Check `jq`.
  2. Build the agent list from the arguments, or from the adapters whose config directory exists. Validate every name before writing anything.
  3. For each agent, source its adapter in a subshell and read `AGENT_CONFIG`, `AGENT_CONFIG_SHAPE`, and `agent_hooks`.
  4. Run one `jq` program per shape. Both first apply the removal rules to every event, then append the missing entries. The `flat` program keeps today's `version` handling.
  5. Write through a temp file and `mv`, as today. Track failures and exit non-zero when any agent failed.
- [ ] `git rm bin/notify-on-stop bin/notify-on-approval`. Confirm nothing else refers to them: `grep -rn 'notify-on-' bin tests`.
- [ ] Run the suite; all pass.
- [ ] Commit: `feat: install hooks for each agent and remove the old scripts`.

Notes for this task:

- The removal rules compare the command with single quotes stripped, so they match both the unquoted Cursor form and the quoted Claude Code form.
- "This checkout" in the third rule means `bin_dir`. An entry that already points at `bin_dir` is not removed; the append step then finds it and adds nothing.

### Task 6: readme, rename, and the manual check

**Files:** `readme.md`.

- [ ] Rewrite `readme.md`: new name; a table of notifications per agent; how it works (one entry point, adapters, the watcher reading the pane); requirements; `bin/install [agent...]`; the settings table with `NOTIFY_APPROVAL_SLOW_INTERVAL` and `NOTIFY_APPROVAL_MAX_SECONDS` and the new meaning of `NOTIFY_APPROVAL_POLLS`; the limitations from the spec.
- [ ] Commit: `docs: rewrite the readme for tmux-agent-notify`.
- [ ] Rename, done by the owner since it touches things outside the repo:
  1. `mv ~/Projects/tmux-cursor-notify ~/Projects/tmux-agent-notify`
  2. `gh repo rename tmux-agent-notify`, when the repository is on GitHub.
  3. `bin/install` from the new location. Check that `~/.cursor/hooks.json` holds only the new commands and that `~/.claude/settings.json` gained three hooks.
- [ ] Manual check, Claude Code, in a new session inside tmux:
  1. Trigger a permission prompt, switch app before it appears. Expect `Claude is waiting for you` about six seconds later; clicking it selects the pane.
  2. Trigger a prompt while looking, wait ten seconds, switch app. Expect the notification at the switch.
  3. Trigger a prompt while looking, then approve, deny, and press Esc in turn, switching app after each. Expect silence each time.
  4. Approve a long command such as `sleep 30` and switch app while it runs. Expect silence, then `Claude finished`.
  5. Ask a multiple-choice question and switch app. Expect `Claude is waiting for you`.
- [ ] Manual check, Cursor: repeat the three steps under "Try it" in the current readme, to confirm nothing regressed.

## After this plan

Codex is one adapter file plus one measurement session: find the words on its approval screen, confirm `PermissionRequest` fires before the screen appears, and confirm `Stop` does not fire on an error. The installer's `nested` shape already fits `~/.codex/hooks.json`.
