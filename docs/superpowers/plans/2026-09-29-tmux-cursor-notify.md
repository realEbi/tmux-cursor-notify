# tmux-cursor-notify Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Notify when a Cursor CLI turn finishes in a local tmux pane, unless that pane is the one already on screen.

**Architecture:** `bin/notify-on-stop` is a Cursor `stop` hook. It posts one macOS notification, or stays silent when the terminal is frontmost and the agent's pane is visible. `bin/focus-pane` is the notification click action. `bin/install` merges that hook into `~/.cursor/hooks.json`. Tests drive all three through fakes on `PATH`.

**Tech Stack:** bash (macOS `/bin/bash` 3.2), `jq` with a `python3` fallback, `terminal-notifier` with an `osascript` fallback, `tmux`.

**Spec:** `docs/superpowers/specs/2026-09-29-tmux-cursor-notify-design.md`

## Global Constraints

- Local macOS tmux only. No remote tmux, no Cursor IDE support beyond ignoring a `stop` whose environment has no `TMUX_PANE`.
- v1 uses the Cursor `stop` hook only. Do not hook `beforeShellExecution` or `beforeMCPExecution`. No TPM plugin. No pane polling.
- `bin/notify-on-stop` stdout is the two characters `{}` plus one newline, exit status 0, and it never prints `followup_message`. stderr is unspecified.
- Notify titles are `Cursor finished` and `Cursor hit an error`. Sound name is `Glass`. Group id is `cursor-<conversation_id>` or `cursor-unknown`.
- Stay silent only when the terminal app is frontmost and `tmux` reports the agent's pane visible (`pane_active` 1, `window_active` 1, `session_attached` >= 1).
- Scripts use `#!/usr/bin/env bash` and stay compatible with bash 3.2: no associative arrays, no namerefs.
- The directory is not a git repository yet. Task 1 runs `git init`. Do not change git config. Each later task commits its own files.
- Automated tests do not start Cursor.

## Review Focus

These are the cases most likely to page someone. Each has a named test in the task that owns the code.

1. Terminal focused, another pane active (`0 1 1`) — must notify. Test: `test_notify_other_pane` in Task 3.
2. `TMUX` socket containing `'` — the `-execute` string stays a single shell command. Test: `test_notify_socket_quote` in Task 2.
3. `terminal-notifier` exits non-zero and the body contains `"` — `osascript` gets title, body, and `Glass` as argv, with no click command. Test: `test_notify_fallback_quote_body` in Task 2.
4. `TMUX_PANE` empty on a `completed` payload — no notification, exit 0, trimmed stdout `{}`. Test: `test_notify_no_pane` in Task 2.
5. Second install, and invalid `hooks.json` — no duplicate command, invalid file unchanged. Tests: `test_install_idempotent`, `test_install_invalid_json` in Task 4.

---

## File map

- `tests/harness.sh` — fake `PATH`, log, assertions. Created in Task 1. Tasks 2–4 only call it.
- `tests/fakes/{osascript,terminal-notifier,tmux,mv}` — record argv. `tmux` and `osascript` branch on the arguments the spec names.
- `tests/run.sh` — runs every `tests/test_*.sh`.
- `tests/test_focus_pane.sh` — Task 1.
- `bin/focus-pane` — Task 1.
- `tests/test_notify_on_stop.sh` — Tasks 2 and 3 append cases.
- `bin/notify-on-stop` — Tasks 2 and 3.
- `tests/test_install.sh`, `bin/install`, `readme.md` — Task 4.

No shared library. Each `bin/` script is standalone. JSON parsing is duplicated in the hook and the installer on purpose; extracting it would be a fourth component the spec does not name.

## Test harness contract

Task 1 produces this. Later tasks do not redesign it.

`harness_use_fakes` sets `ROOT` to the repo root, `FAKE_LOG` to an empty temp dir, and `PATH` to `tests/fakes:/bin:/usr/bin`.

`harness_hide NAME` drops an executable named `NAME` into a directory that is prepended to `PATH` and that exits 127. Use it to simulate a missing `jq`, `python3`, or `terminal-notifier`. Real binaries stay reachable on the default `PATH` until hidden.

Fake behavior, controlled by env vars the test exports before invoking a `bin/` script:

- `osascript` appends its argv to `$FAKE_LOG/osascript`. Script text containing `bundle identifier of first` prints `$FAKE_OSA_BUNDLE` (default `com.example.Other`). Script text containing `name of first application process` prints `$FAKE_OSA_NAME` (default `Safari`). Script text containing `(name of processes) contains "NAME"` prints the matching line from `$FAKE_OSA_CONTAINS` (a multiline string `Name true|false`, default every name `false`). `to activate` only logs. `display notification` logs and exits `$FAKE_OSA_DISPLAY_EXIT` (default 0). `$FAKE_OSA_EXIT` (default 0) is the exit for a frontmost query. `$FAKE_ACTIVATE_EXIT` (default 0) is the exit for an activate script.
- `terminal-notifier` appends argv to `$FAKE_LOG/terminal-notifier` and exits `$FAKE_NOTIFIER_EXIT` (default 0).
- `tmux` appends argv to `$FAKE_LOG/tmux`. A command containing `display-message` prints `$FAKE_TMUX_DISPLAY` (default `1 1 1`) and exits `$FAKE_TMUX_DISPLAY_EXIT` (default 0). A command containing `select-window` exits `$FAKE_TMUX_SELECT_WINDOW_EXIT` (default 0). Other tmux commands exit 0.
- `mv` appends argv to `$FAKE_LOG/mv`. If `$FAKE_MV_EXIT` is unset, it runs `/bin/mv "$@"`. If set, it exits with that status and does not move the file.

Assertions used by every test file: `assert_exit CODE`, `assert_stdout_trimmed TEXT`, `assert_log_contains FILE SUBSTR`, `assert_log_lacks FILE SUBSTR`. `assert_log_lacks` fails if the log file is missing only when the test expected a call; a missing log means the command was not run, which satisfies "was not called" via `assert_not_called FILE`.

---

### Task 1: focus-pane

**Files:**
- Create: `tests/harness.sh`
- Create: `tests/fakes/osascript`
- Create: `tests/fakes/terminal-notifier`
- Create: `tests/fakes/tmux`
- Create: `tests/fakes/mv`
- Create: `tests/run.sh`
- Create: `tests/test_focus_pane.sh`
- Create: `bin/focus-pane`
- Test: `tests/test_focus_pane.sh`

**Interfaces:**
- Consumes: nothing
- Produces: executable `bin/focus-pane BUNDLE SOCKET PANE`, each argument a string that may be empty, exit status 0. Produces the harness contract above. `tests/run.sh` executes every executable `tests/test_*.sh` and exits non-zero if any does.

- [ ] **Step 1: Initialize git**

Run: `git init`
Expected: `Initialized empty Git repository` (or a message that `.git` already exists, in which case do nothing else).

- [ ] **Step 2: Write the failing focus-pane tests**

`tests/test_focus_pane.sh` sources `tests/harness.sh`. Each function is one case. The first one, in full, fixes the style:

```bash
test_focus_live_pane() {
  harness_use_fakes
  "$ROOT/bin/focus-pane" "com.apple.Terminal" "/tmp/tmux-501/default" "%12"
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
```

The other functions follow that shape:

- `test_focus_dead_pane_still_activates` — `$FAKE_TMUX_SELECT_WINDOW_EXIT=1`. Activation script is logged. Exit 0. `select-pane` and `switch-client` are still logged.
- `test_focus_empty_socket_skips_tmux` — args `com.apple.Terminal '' %12`. Activation logged. `assert_not_called tmux`. Exit 0.
- `test_focus_empty_pane_skips_tmux` — args `com.apple.Terminal /tmp/sock ''`. Same.
- `test_focus_bundle_id_activates_by_id` — log contains `tell application id "com.apple.Terminal" to activate` and lacks `(name of processes) contains`.
- `test_focus_empty_bundle_walks_names` — first arg `''`. `$FAKE_OSA_CONTAINS` is `Terminal false` then `iTerm2 true`. Log contains `contains "Terminal"`, `contains "iTerm2"`, and `tell application "iTerm2" to activate`. Lacks `tell application id`.
- `test_focus_name_walk_skips_false_and_nonzero` — `$FAKE_OSA_CONTAINS` marks Terminal as a non-zero exit (use a line `Terminal exit`) and iTerm2 as `true`. iTerm2 is activated. The fake treats a map value `exit` as exit 1 and empty stdout for that name.
- `test_focus_none_running_still_tmux` — every name `false`, socket and pane set. No `to activate` line. All three tmux subcommands logged. Exit 0.
- `test_focus_none_running_no_tmux_when_socket_empty` — every name `false`, socket `''`. No activate, no tmux, exit 0.
- `test_focus_bundle_quote_uses_name_walk` — bundle id `bad"id`. No `tell application id`. Name walk runs.
- `test_focus_bundle_backslash_uses_name_walk` — bundle id `bad\id`. Same.
- `test_focus_activate_failure_still_tmux` — `$FAKE_ACTIVATE_EXIT=1`, bundle id set, socket and pane set. Name walk does not run. Three tmux commands logged. Exit 0.

- [ ] **Step 3: Run the focus tests and confirm they fail**

Run: `tests/run.sh`
Expected: FAIL because `bin/focus-pane` does not exist.

- [ ] **Step 4: Implement `bin/focus-pane`**

Bash 3.2 script. Arguments `$1` bundle id, `$2` socket, `$3` pane id. Copy the `osascript -e` strings and the three `tmux -S` commands from the spec's Click section. Ignore non-zero exits from activate and from each tmux command. Exit 0.

- [ ] **Step 5: Run the focus tests and confirm they pass**

Run: `tests/run.sh`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add tests bin/focus-pane
git commit -m "feat: focus the tmux pane from a notification click"
```

---

### Task 2: notify on stop, without the visible-pane silence

**Files:**
- Create: `tests/test_notify_on_stop.sh`
- Create: `bin/notify-on-stop`
- Test: `tests/test_notify_on_stop.sh`

**Interfaces:**
- Consumes: harness from Task 1. Resolves `bin/focus-pane` as the symlink-resolved directory of `bin/notify-on-stop` plus `/focus-pane` (`pwd -P`).
- Produces: executable `bin/notify-on-stop` reading JSON on stdin. Exit 0. Stdout `{}\n`. With the fakes' default frontmost app `Safari`, the terminal is not frontmost, so the pane check must not run.

This task's tests leave the default frontmost name `Safari`, so they do not exercise silence. Task 3 adds that.

- [ ] **Step 1: Write the failing notify tests**

`tests/test_notify_on_stop.sh` sources the harness. Helper `run_hook JSON` exports `TMUX_PANE=%12` unless the test unsets it, pipes JSON to `bin/notify-on-stop`, and records status and stdout.

- `test_notify_completed` — stdin `{"status":"completed","conversation_id":"c1","workspace_roots":["/tmp/app"]}`. Notifier argv contains `-title`, `Cursor finished`, `-message`, `app`, `-sound`, `Glass`, `-group`, `cursor-c1`. Exit 0. Trimmed stdout `{}`.
- `test_notify_error` — `status` `error`. Title `Cursor hit an error`.
- `test_notify_body_trailing_slash` — `workspace_roots` `["/tmp/app/"]`. Message `app`.
- `test_notify_body_root` — `workspace_roots` `["/"]`. Message `agent`.
- `test_notify_body_missing` — no `workspace_roots` key. Message `agent`.
- `test_notify_body_empty_list` — `workspace_roots` `[]`. Message `agent`.
- `test_notify_body_empty_string` — `workspace_roots` `[""]`. Message `agent`.
- `test_notify_body_number` — `workspace_roots` `[1]`. Message `agent`.
- `test_notify_group` — two runs, ids `c1` and `c1`, both log `-group` `cursor-c1`. A third run with `c2` logs `cursor-c2`.
- `test_notify_group_unknown` — `conversation_id` missing, then `""`, then `1`. Each logs `-group` `cursor-unknown`.
- `test_notify_execute_parts` — `__CFBundleIdentifier=com.apple.Terminal`, `TMUX=/tmp/sock,123,0`, `TMUX_PANE=%12`. The `-execute` value contains the single-quoted absolute `focus-pane` path, then `'com.apple.Terminal'`, then `'/tmp/sock'`, then `'%12'`.
- `test_notify_socket_quote` — `TMUX` is `/tmp/so'ck,1,0`. The `-execute` value contains `'/tmp/so'\''ck'`.
- `test_notify_no_tmux_env` — `TMUX` unset, `TMUX_PANE=%12`. Notifier is called. Socket argument in `-execute` is `''`.
- `test_notify_execute_absolute` — `-execute` begins with a single quote and the `pwd -P` path of `bin/focus-pane`.
- `test_notify_no_pane` — `TMUX_PANE` unset, payload `completed`. `assert_not_called terminal-notifier`. Exit 0. Trimmed stdout `{}`.
- `test_notify_empty_pane` — `TMUX_PANE=''`. Same as no pane.
- `test_notify_no_pane_bad_json` — `TMUX_PANE` unset, stdin `not-json`. Notifier not called. Exit 0. Trimmed stdout `{}`.
- `test_notify_aborted` — `status` `aborted`. Notifier not called.
- `test_notify_other_status` — `status` `running`. Notifier not called.
- `test_notify_status_missing` — object `{}`. Notifier not called.
- `test_notify_status_number` — `status` `1`. Notifier not called.
- `test_notify_bad_json` — stdin `not-json`, pane set. Title `Cursor finished`, message `agent`, group `cursor-unknown`, sound `Glass`. Trimmed stdout `{}`.
- `test_notify_empty_stdin` — same titles as bad JSON.
- `test_notify_json_array` — stdin `[]`. Same.
- `test_notify_json_null` — stdin `null`. Same.
- `test_notify_json_string` — stdin `"hi"`. Same.
- `test_notify_python_fallback` — `harness_hide jq`, payload `completed`. Notifier called with title `Cursor finished`.
- `test_notify_no_parsers` — hide `jq` and `python3`, payload `completed`, pane set. Title `Cursor finished`, message `agent`, group `cursor-unknown`, sound `Glass`. Trimmed stdout `{}`.
- `test_notify_fallback_missing_notifier` — `harness_hide terminal-notifier`. osascript log contains `display notification` and `Glass`, and the logged argv includes the title and the body as separate arguments. Log lacks `-execute` and lacks `focus-pane`.
- `test_notify_fallback_notifier_fails` — `$FAKE_NOTIFIER_EXIT=1`. Same osascript fallback.
- `test_notify_fallback_quote_body` — `$FAKE_NOTIFIER_EXIT=1`, `workspace_roots` `["/tmp/say\"hi"]`. osascript argv contains the body `say"hi` as its own argument, not inside the `-e` script text.
- `test_notify_stdout_always` — runs aborted, bad JSON, missing pane, and a failing display-notification fallback (`$FAKE_NOTIFIER_EXIT=1` and `$FAKE_OSA_DISPLAY_EXIT=1`). Each exits 0 with trimmed stdout `{}`.

Default frontmost stays `Safari` in every test in this task. None of them assert on `display-message`.

- [ ] **Step 2: Run the notify tests and confirm they fail**

Run: `tests/run.sh`
Expected: FAIL because `bin/notify-on-stop` does not exist. Task 1 tests still PASS.

- [ ] **Step 3: Implement `bin/notify-on-stop`**

Copy the `osascript` frontmost queries, the `terminal-notifier` argument list, and the `display notification` argv form from the spec. Parse with `jq` if `command -v jq` succeeds, else `python3`. A missing or empty `TMUX_PANE` returns before any notifier call. Unparseable payloads and non-objects notify with the defaults in the spec. Parsed statuses other than `completed` and `error` return without notifying. When the frontmost app is not the terminal, do not call `tmux`. Build `-execute` with single quotes as the spec states. If `terminal-notifier` is missing or returns non-zero, run the `osascript` fallback. Always print `{}` and exit 0, including when the fallback fails.

Leave the "terminal is frontmost" branch calling the notifier as well. Task 3 replaces that branch with the pane check. Until then, a frontmost terminal still notifies, and this task's tests do not cover that.

- [ ] **Step 4: Run the suite and confirm it passes**

Run: `tests/run.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/test_notify_on_stop.sh bin/notify-on-stop
git commit -m "feat: notify when a Cursor CLI turn finishes"
```

---

### Task 3: stay silent only when the agent's pane is on screen

**Files:**
- Modify: `tests/test_notify_on_stop.sh`
- Modify: `bin/notify-on-stop`
- Test: `tests/test_notify_on_stop.sh`

**Interfaces:**
- Consumes: `bin/notify-on-stop` from Task 2. Fake `tmux` `display-message` from Task 1.
- Produces: the same executable, now silent when the spec's focus check says the pane is visible.

- [ ] **Step 1: Append the failing focus tests**

Add these functions to `tests/test_notify_on_stop.sh`. Payload for each is `{"status":"completed","conversation_id":"c1","workspace_roots":["/tmp/app"]}`. `TMUX_PANE=%12`.

- `test_notify_front_bundle_match_visible` — `__CFBundleIdentifier=com.apple.Terminal`, `$FAKE_OSA_BUNDLE=com.apple.Terminal`, `$FAKE_TMUX_DISPLAY='1 1 1'`. Notifier not called. tmux log contains `display-message`, `-S` is absent (TMUX unset), `-t`, `%12`, and the format string `#{pane_active} #{window_active} #{session_attached}`.
- `test_notify_front_bundle_differs` — bundle env `com.apple.Terminal`, fake bundle `com.example.Other`. Notifier called. `display-message` not called.
- `test_notify_front_name_in_list` — `__CFBundleIdentifier` unset, `$FAKE_OSA_NAME=Ghostty`, display `1 1 1`. Notifier not called.
- `test_notify_front_name_outside_list` — `$FAKE_OSA_NAME=Safari`. Notifier called. `display-message` not called.
- `test_notify_bundle_quote_uses_name` — `__CFBundleIdentifier=a"b`, `$FAKE_OSA_NAME=Safari`. osascript log contains `name of first application process` and lacks `bundle identifier of first`. Notifier called.
- `test_notify_bundle_backslash_uses_name` — `__CFBundleIdentifier=a\b`. Same.
- `test_notify_frontmost_query_fails` — `$FAKE_OSA_EXIT=1`. Notifier called.
- `test_notify_pane_visible` — name `Terminal`, display `1 1 1`. Notifier not called.
- `test_notify_other_pane` — name `Terminal`, display `0 1 1`. Notifier called.
- `test_notify_other_window` — display `1 0 1`. Notifier called.
- `test_notify_session_detached` — display `1 1 0`. Notifier called.
- `test_notify_session_attached_two` — display `1 1 2`. Notifier not called.
- `test_notify_pane_check_fails` — `$FAKE_TMUX_DISPLAY_EXIT=1`. Notifier called.
- `test_notify_pane_check_garbage` — display `visible`. Notifier called.
- `test_notify_pane_check_socket` — `TMUX=/tmp/sock,123,0`, name `Terminal`, display `0 1 1`. tmux log contains `-S`, `/tmp/sock`, `-t`, `%12`.
- `test_notify_not_frontmost_skips_pane_check` — name `Safari`. Notifier called. `assert_not_called` is wrong if an earlier test in the same function ran tmux; this function starts from `harness_use_fakes` and asserts the tmux log does not contain `display-message`.

- [ ] **Step 2: Run the suite and confirm the new tests fail**

Run: `tests/run.sh`
Expected: FAIL on the silence cases (`test_notify_front_bundle_match_visible`, `test_notify_front_name_in_list`, `test_notify_pane_visible`, `test_notify_session_attached_two`). Task 1 and Task 2 tests still PASS.

- [ ] **Step 3: Implement the focus and pane checks in `bin/notify-on-stop`**

After a payload is allowed to notify, run the spec's frontmost query. If it fails, notify. If the terminal is not frontmost, notify and do not call `tmux`. If it is frontmost, run the spec's `display-message` command, with `-S` only when the socket is non-empty. Visible means the three fields parse as `1`, `1`, and an integer >= 1. Otherwise notify. Copy the format string from the spec.

- [ ] **Step 4: Run the suite and confirm it passes**

Run: `tests/run.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/test_notify_on_stop.sh bin/notify-on-stop
git commit -m "feat: stay quiet when the agent pane is already visible"
```

---

### Task 4: installer

**Files:**
- Create: `tests/test_install.sh`
- Create: `bin/install`
- Modify: `readme.md`
- Test: `tests/test_install.sh`

**Interfaces:**
- Consumes: absolute path of `bin/notify-on-stop`, resolved from `bin/install` with `pwd -P`, independent of the caller's working directory.
- Produces: executable `bin/install`. Reads and writes `$HOME/.cursor/hooks.json`. Exit 0 on success. Exit non-zero when the spec says not to write.

- [ ] **Step 1: Write the failing installer tests**

Each test sets `HOME` to a fresh temp dir and compares parsed JSON (`python3 -c` or `jq`), not bytes.

- `test_install_creates` — no `.cursor` directory. After install, `version` is number 1, `hooks.stop` has one object, `command` equals `$(cd dir && pwd -P)/notify-on-stop` where dir is the directory of `bin/install`.
- `test_install_empty_object` — existing file `{}` becomes that same shape.
- `test_install_appends` — existing `stop` command `/bin/other` is kept, and ours is appended.
- `test_install_keeps_non_object` — `stop` is `[null, "x"]`. Both elements remain, ours is appended, exit 0.
- `test_install_idempotent` — run twice. `stop` length stays 1.
- `test_install_invalid_json` — file contents `not-json`. Exit non-zero. File bytes unchanged.
- `test_install_hooks_json_is_directory` — `hooks.json` is a directory. Exit non-zero. Directory still exists.
- `test_install_cursor_is_file` — `$HOME/.cursor` is a regular file. Exit non-zero. No `hooks.json` written. The file is unchanged.
- `test_install_mv_fails` — seed a valid `hooks.json` whose `stop` command is `/bin/other`. `$FAKE_MV_EXIT=1`. Exit non-zero. Parsed `command` is still `/bin/other`.
- `test_install_via_symlink` — invoke a symlink to `bin/install` with cwd `/`. `command` is the `pwd -P` path, not the symlink path.
- `test_install_bad_version` — `version` is `2`. Exit non-zero. File unchanged.
- `test_install_root_array` — file `[]`. Exit non-zero. File unchanged.
- `test_install_hooks_not_object` — `hooks` is `[]`. Exit non-zero. File unchanged.
- `test_install_stop_not_array` — `hooks.stop` is `{}`. Exit non-zero. File unchanged.
- `test_install_python_fallback` — `harness_hide jq`. Missing file is still created with the same shape. `mv` is not required on this path; the fake log for `mv` is empty.
- `test_install_no_parsers` — hide `jq` and `python3`. Exit non-zero. No `hooks.json` created.

- [ ] **Step 2: Run the suite and confirm the installer tests fail**

Run: `tests/run.sh`
Expected: FAIL because `bin/install` does not exist. Tasks 1–3 still PASS.

- [ ] **Step 3: Implement `bin/install`**

Follow the spec's Installer file section. `jq` path writes a temp file in `$HOME/.cursor` and replaces `hooks.json` with `mv`. `python3` path uses `os.replace`. Refuse a non-regular `hooks.json`, a non-object root, a `version` other than the number 1, a non-object `hooks`, and a non-array `hooks.stop`. Keep non-object `stop` entries. Append our command only when no object has that exact `command`.

- [ ] **Step 4: Run the suite and confirm it passes**

Run: `tests/run.sh`
Expected: PASS

- [ ] **Step 5: Replace `readme.md`**

State that this is a Cursor `stop` hook, not a TPM plugin. Document `bin/install`, the requirement that `agent` is started inside the tmux pane so `TMUX_PANE` is inherited, and the manual check from the spec: unfocused terminal notifies and the click selects the pane; focused terminal with that pane selected stays silent; focused terminal on another pane, then another window, notifies each time. Mention `terminal-notifier` is optional.

- [ ] **Step 6: Commit**

```bash
git add tests/test_install.sh bin/install readme.md
git commit -m "feat: install the stop hook into Cursor user config"
```

- [ ] **Step 7: Manual check, after the suite is green**

This does not block the commit. Run `bin/install`, start `agent` in a tmux pane, and walk the three situations in the spec's Testing section. If no notification appears while the terminal is unfocused, `TMUX_PANE` is not reaching the hook; stop and report that instead of changing the silence rule.
