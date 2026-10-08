# tmux-cursor-notify design

Status: implemented. Extended by [tmux-agent-notify design](2026-10-08-tmux-agent-notify-design.md), which makes the tool work for other agents; where the two disagree, the newer document wins.

Date: 2026-09-29

## Goal

Notify the user when a Cursor CLI agent running in a local tmux pane finishes a turn, so they can leave the desk and come back when the result is ready.

Approval-wait notifications were deferred in v1 (see **v2** below). Cursor has no hook that means an approval prompt is on screen. v1 stayed silent while a turn was blocked on approval.

## Decisions

1. **Surface.** Watch `agent` / `cursor-agent` inside a tmux pane. The Cursor IDE is out of scope. A `stop` with no `TMUX_PANE` does not notify. That ignores IDE stops when the IDE process has no `TMUX_PANE`. An IDE launched from a tmux pane can inherit `TMUX_PANE` and is not filtered separately.
2. **Host.** tmux runs locally on this Mac. Remote tmux over SSH is out of scope. Delivery is the macOS notification center.
3. **Signal (v1).** The Cursor `stop` hook only. `completed` and `error` can notify. `aborted` does not. `beforeShellExecution` and `beforeMCPExecution` are not used. **Changed in v2:** approval uses those two hooks as triggers only; see **v2: approval notifications**.
4. **Focus is per pane.** Stay silent only when the terminal app is frontmost and the agent's pane is visible: it is the active pane, in the active window, of a session with an attached client. If you are in the terminal but on another pane, window, or session, notify. No sound when silent.
5. **Shape (v1).** A user-level Cursor hook, plus a click helper that focuses the tmux pane. No pane polling in v1. No TPM plugin. **Changed in v2:** a detached watcher polls the tmux pane for approval cards only.

## Architecture

Three programs, living in this repo under `bin/`:

- `bin/notify-on-stop` is the `stop` hook. It reads JSON on stdin and posts at most one notification.
- `bin/focus-pane` is the notification click action. It activates the terminal and selects the tmux pane.
- `bin/install` merges a `stop` entry into `~/.cursor/hooks.json`. The command is the absolute path of `bin/notify-on-stop`. Existing hooks stay. A second install does not duplicate the entry. User-level hooks also load in the IDE. Stops with no `TMUX_PANE` are dropped. An IDE launched from a tmux pane can inherit `TMUX_PANE` and will notify; that case is not filtered.

**v2:** adds `bin/notify-on-approval` and merges `beforeShellExecution` / `beforeMCPExecution` in `bin/install`. Details in **v2: approval notifications**.

The hook is expected to inherit `TMUX` and `TMUX_PANE` from `agent`, because `agent` was started in that pane. `TMUX` looks like `<socket>,<pid>,<session>`. The socket passed to `focus-pane` is the text of `TMUX` before the first comma. If `TMUX` is missing, the socket is empty. `TMUX_PANE` looks like `%12`. A missing or empty `TMUX_PANE` means no notification. A missing socket still notifies; the click then skips tmux.

`__CFBundleIdentifier` in the hook environment names the terminal app that launched the session, when macOS provided it.

## Data flow

1. Cursor runs `bin/notify-on-stop` when the agent loop ends.
2. If `TMUX_PANE` is unset or empty, the script prints `{}` and exits. No notification.
3. The script reads `status`, `conversation_id`, and `workspace_roots[0]` from stdin with `jq`.
4. If `status` is not `completed` or `error` (including `aborted`, missing, not a string, or input that is not a readable JSON object), the script prints `{}` and exits. No notification.
5. Otherwise it runs the focus check. When the terminal is frontmost and the agent's pane is visible, it prints `{}` and exits.
6. Otherwise it posts a notification:
   - Title `Cursor finished` when `status` is `completed`.
   - Title `Cursor hit an error` when `status` is `error`.
   - Body is the last path component of `workspace_roots[0]` after stripping trailing slashes, when that element is a non-empty string. `/tmp/app/` becomes `app`. If that component is empty, including when the path is `/`, the body is `agent`. A missing list, an empty list, an empty string, or a non-string element also uses `agent`.
   - Sound name `Glass`.
   - Group id is `cursor-<conversation_id>` when `conversation_id` is a non-empty string. Otherwise the group id is `cursor-unknown`.
7. The click command is one shell string passed to `terminal-notifier -execute`. It is the absolute path of `bin/focus-pane` plus three single-quoted arguments, in order: bundle id, socket, pane id. A missing value is an empty single-quoted argument (`''`). The absolute path of `bin/focus-pane` is single-quoted too. A single quote inside the path or any argument is escaped as `'\''`.
8. Stdout is the two characters `{}` followed by one newline. The script never sets `followup_message`. Tests strip trailing whitespace and require the remainder to be `{}`.
9. A later stop with the same `conversation_id` passes the same `-group` value. Replacing the previous notification is `terminal-notifier` behavior and is not unit-tested. A different `conversation_id` uses a different group id. Starting the next prompt does not dismiss the notification.

`terminal-notifier` is the poster. It returns after the notification is delivered, not after the click. The invocation is `terminal-notifier -title <title> -message <body> -sound Glass -group <group-id> -execute <click command>`.

## Focus check

Run this only after the `TMUX_PANE` check has passed.

Comparisons use `osascript` stdout with trailing whitespace removed, including the newline it prints. The same trim applies to the `true` / `false` results in Click.

If `__CFBundleIdentifier` is set and non-empty:

```
osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true'
```

Stdout is the frontmost bundle id. If that stdout equals `__CFBundleIdentifier`, the terminal is frontmost. If `osascript` exits non-zero, the focus check failed.

Otherwise (unset or empty):

```
osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true'
```

Stdout is the frontmost app name. If it is one of Terminal, iTerm2, Ghostty, WezTerm, kitty, Alacritty, the terminal is frontmost. If `osascript` exits non-zero, the focus check failed.

If the terminal is not frontmost, notify. If it is frontmost, run the pane check below.

### Pane check

When the socket (the text of `TMUX` before the first comma) is non-empty, run:

```
tmux -S <socket> display-message -p -t <TMUX_PANE> '#{pane_active} #{window_active} #{session_attached}'
```

When the socket is empty, run the same command without `-S <socket>`.

Trim trailing whitespace from stdout. The pane is visible when the first field is `1`, the second field is `1`, and the third field is an integer of 1 or more. Otherwise it is not visible. If `tmux` exits non-zero or prints something else, the pane check failed.

A failed frontmost check or a failed pane check notifies. Tests replace `osascript` and `terminal-notifier` by putting fakes earlier on `PATH`. The fake records argv. It treats the `bundle identifier of first application process` script as the bundle-id query, the `name of first application process` script as the name query, and `display notification` as the fallback poster.

## Click

`bin/focus-pane` is invoked as `focus-pane <bundle-id> <socket> <pane-id>`. Each argument may be an empty string.

1. Activate a terminal app.
   - If `<bundle-id>` is non-empty and contains neither `"` nor `\`, run:

```
osascript -e 'tell application id "<bundle-id>" to activate'
```

   - Otherwise, walk this list in order: Terminal, iTerm2, Ghostty, WezTerm, kitty, Alacritty. For each name, run:

```
osascript -e 'tell application "System Events" to (name of processes) contains "<name>"'
```

     Stdout `true` means it is running. Stdout `false`, or a non-zero exit, means try the next name. On the first `true`, run:

```
osascript -e 'tell application "<name>" to activate'
```

     and stop the walk. If none return `true`, skip activation.
2. Run tmux only when both `<socket>` and `<pane-id>` are non-empty. Otherwise skip this step. The commands, in order, are:
   - `tmux -S <socket> select-window -t <pane-id>`
   - `tmux -S <socket> select-pane -t <pane-id>`
   - `tmux -S <socket> switch-client -t <pane-id>`
   `switch-client` is run with no `-c`. Outside tmux, that updates the most recently used attached client. A failure of any one command is ignored and the next command still runs.
3. A non-zero exit from an activate script is ignored. It does not start the name walk. Step 2 still runs. The helper exits 0, including when activation was skipped, activation failed, tmux was skipped, or tmux failed because the pane or server is gone.

## Installer file

`bin/install` requires `jq` on `PATH` (macOS 15 and later ship `/usr/bin/jq`; otherwise install via Homebrew). If `jq` is missing, it prints `install: jq not found` on stderr, exits non-zero, and does not write. Tests compare parsed JSON. Key order and whitespace are not specified.

If `~/.cursor/` does not exist, `bin/install` creates it with `mkdir -p` and then writes `hooks.json`. If `mkdir` fails, it exits non-zero and does not write a file.

A missing `hooks.json` is created as a JSON value equal to:

```json
{
  "version": 1,
  "hooks": {
    "stop": [
      { "command": "/absolute/path/to/bin/notify-on-stop" }
    ]
  }
}
```

The command string is the absolute path of this repo's `bin/notify-on-stop`.

That path is `<dir>/notify-on-stop`, where `<dir>` is the directory of `bin/install` after resolving symlinks with `pwd -P`. It does not depend on the current working directory. `bin/focus-pane` in the click command is resolved the same way from `bin/notify-on-stop`.

If the file exists and is valid JSON, `jq` merges hook entries: set `version` to `1` when missing; refuse when `version` is present and is not the number `1` (print an `install:` error on stderr, exit non-zero, leave the file unchanged). Keep existing hook entries; append `{ "command": "<absolute path>" }` only when no entry has the same `command`. If `jq` cannot merge (invalid JSON, unsupported version, or other merge error), print an `install:` error on stderr, exit non-zero, and leave `hooks.json` unchanged.

Write the new JSON to a temporary file in `~/.cursor/` and replace `hooks.json` with `mv`. If the write or `mv` fails, print an `install:` error, exit non-zero, remove any temp file, and leave the previous `hooks.json` in place when it existed.

If `hooks.json` exists and is not a regular file, including when it is a directory, `bin/install` exits non-zero and leaves it untouched.

## Error handling

`bin/notify-on-stop` always prints `{}` and exits 0. A hook bug must not continue the agent and must not block it. stderr content is unspecified and untested.

- `TMUX_PANE` unset or empty: no notification. This includes IDE stops.
- JSON that cannot be parsed, a non-object JSON value (`[]`, `null`, a string, a number), empty stdin, or a missing or non-string `status`: no notification. (v1 notified a generic `Cursor finished` for unreadable input; dropped once `jq` became required.)
- Frontmost-app check fails: notify anyway.
- Pane check fails (`tmux` missing, non-zero exit, or unexpected output): notify anyway.
- `terminal-notifier` missing or exiting non-zero: post with `osascript`, no click action and no group id:

```
osascript -e 'on run argv
  display notification (item 2 of argv) with title (item 1 of argv) sound name (item 3 of argv)
end run' -- <title> <body> Glass
```

  Title and body are argv items, not string literals inside the script, so `"` and `\` in a workspace name need no extra escaping.
- Dead pane or dead tmux server on click: activation from Click step 1 still stands. The helper exits 0.

The script does not require a Homebrew install of `terminal-notifier`.

## Testing

Automated tests do not start Cursor. Fakes for `osascript`, `terminal-notifier`, `tmux`, and `mv` record argv and can be told what to print and what exit code to use. The fake `osascript` classifies a call by the script text in Focus check and Click.

Hook tests run `bin/notify-on-stop` with fixture JSON on stdin and fakes earlier on `PATH`. They set `TMUX_PANE` unless a bullet says otherwise. They assert:

- `completed` uses the title `Cursor finished`.
- `error` uses the title `Cursor hit an error`.
- Body is the last path component of `workspace_roots[0]` after stripping trailing slashes. `/tmp/app/` yields `app`. The body is `agent` when that component is empty, when the path is `/`, when `workspace_roots` is missing or empty, or when its first element is an empty string or not a string.
- Group id is `cursor-<conversation_id>` when that field is a non-empty string.
- Group id is `cursor-unknown` when `conversation_id` is missing or not a non-empty string.
- Two `completed` payloads with the same `conversation_id` pass the same `-group`. Two different ids pass different groups.
- Sound is `Glass`.
- The `-execute` string is `focus-pane` with the bundle id, socket, and pane id, and an empty argument where a value is missing.
- `TMUX=/tmp/sock,123,0` puts `/tmp/sock` in the socket argument of `-execute`.
- An unset `TMUX`, with `TMUX_PANE` set, still notifies, and the socket argument is empty.
- The `-execute` string begins with the absolute path of `bin/focus-pane`, single-quoted.
- A socket containing a single quote produces an `-execute` string where that quote is escaped as `'\''` and the `focus-pane` path is single-quoted.
- An unset or empty `TMUX_PANE` does not call the notifier, for both a `completed` object and bad JSON.
- `aborted` does not call the notifier.
- A `status` other than `completed` or `error`, and a parsed object with a missing or non-string `status`, do not call the notifier.
- When `__CFBundleIdentifier` is set, a matching frontmost bundle id does not call the notifier, and a different bundle id does.
- When `__CFBundleIdentifier` is unset, a frontmost name in the name list does not call the notifier, and a name outside the list does.
- A failed frontmost check (fake `osascript` exits non-zero on the frontmost query) still calls the notifier.
- Terminal frontmost and fake `tmux display-message` prints `1 1 1`: the notifier is not called.
- Terminal frontmost and the pane is not visible: `0 1 1` (another pane active), `1 0 1` (another window active), and `1 1 0` (session not attached) each call the notifier.
- Terminal frontmost and fake `tmux display-message` exits non-zero or prints unexpected text: the notifier is called.
- Terminal not frontmost: the notifier is called and `tmux display-message` is not run.
- `TMUX=/tmp/sock,123,0` makes the pane check pass `-S /tmp/sock` and `-t` set to `TMUX_PANE`.
- Bad JSON, empty stdin, and a JSON array, `null`, or string do not notify, and stdout is `{}`.
- A workspace path containing quotes and `$(...)` appears literally in the body and is never executed.
- With `terminal-notifier` absent, the script calls the `display notification` argv form with the same title, body, and `Glass`, and that call has no click command.
- With `terminal-notifier` exiting non-zero, the same `display notification` fallback runs.
- A body containing `"` is passed as an argv item to that fallback, not interpolated into the AppleScript text.
- Trimmed stdout is `{}` and the exit status is 0 in every hook case, including a missing `TMUX_PANE`, bad JSON, a failing `terminal-notifier`, and a failing fallback `osascript`.

`bin/focus-pane` tests fake `osascript` and `tmux`:

- A live socket and pane id record `select-window`, `select-pane`, and `switch-client`, each with `-S` set to that socket and `-t` set to that pane id. `switch-client` has no `-c`. The helper exits 0.
- A dead pane (fake `tmux` exits non-zero) still runs the activation script and exits 0.
- An empty socket or an empty pane id runs activation, does not call `tmux`, and exits 0.
- A non-empty bundle id without `"` or `\` runs `tell application id "<bundle-id>" to activate` and does not walk the name list.
- An empty bundle id walks the name list with `(name of processes) contains`, activates the first name whose fake returns `true`, and does not run `tell application id`.
- The name walk continues when a fake returns `false` or exits non-zero, and activates the next name that returns `true`.
- When every name returns `false`, the helper does not run an activate script, does not call `tmux` if the socket or pane is empty, and exits 0. When socket and pane are non-empty, it still runs the three tmux commands.
- A bundle id containing `"` or `\` does not run `tell application id`, and uses the name walk instead.
- If `select-window` exits non-zero, `select-pane` and `switch-client` are still invoked.
- If the activate script exits non-zero, the name walk does not run, the three tmux commands still run when socket and pane are non-empty, and the helper exits 0.

Installer tests use a temporary `HOME`. They compare parsed JSON:

- Missing `hooks.json` and a missing `~/.cursor/` directory: the directory is created and the file parses as `version` 1, `hooks.stop` a one-element array, `command` the absolute path of `bin/notify-on-stop`.
- A file that is `{}` becomes that same value.
- An existing file with another `stop` command keeps that command and appends ours.
- A `stop` array containing a non-object (for example `null` or a string) keeps that element, appends our command, and exits 0.
- When `hooks.json` exists as a directory, the installer exits non-zero and does not remove that directory.
- When `~/.cursor` exists as a file, `mkdir` cannot create the directory, the installer exits non-zero, and it does not write `hooks.json`.
- A fake `mv` that exits non-zero makes the installer exit non-zero, leaves the previous `hooks.json` contents in place, and does not leave `hooks.json.*` temp files in `~/.cursor/`.
- Running `bin/install` via a symlink, from a current directory that is not the repo, stores the symlink-resolved absolute path of `bin/notify-on-stop` in `command`.
- A second run does not add a duplicate of our command.
- Invalid JSON is left unchanged and the installer exits non-zero.
- `version` present and not the number `1` (including boolean): file unchanged, exit non-zero, `install:` error on stderr.
- With `jq` absent, the installer exits non-zero, prints `install: jq not found`, and does not write.

One manual check, not automated: with the hook installed, finish a turn in `agent` while the terminal is not frontmost, confirm the notification, and confirm the click selects that pane. Repeat while the terminal is frontmost and that pane is selected, and confirm silence. Repeat while the terminal is frontmost but another pane, then another window, is selected, and confirm a notification each time. If this produces no notification even when the terminal is unfocused, `TMUX_PANE` is not reaching the hook.

## Out of scope for v1

- Approval-wait alerts in v1, including forcing `permission: "ask"`. **In scope in v2** (observational hooks + pane polling; still no `permission` field).
- Clearing the notification on the next prompt.
- Supporting or testing the Cursor IDE, cloud agents, and remote tmux. IDE stops are ignored only when that process has no `TMUX_PANE`. An IDE started inside a tmux pane can inherit `TMUX_PANE` and is not filtered.
- TPM install, pane polling, status-line widgets, Telegram, Pushover, and Discord.
- Accept and Reject buttons on the notification.
- Tab completions, and notifications for each tool call or thought.
- A repeating nag while a turn is still running.


## v2: approval notifications

**Problem.** Cursor exposes no hook for “approval card is on screen.” The CLI draws the card in the tmux pane after `beforeShellExecution` / `beforeMCPExecution` return.

**Approach.** Use those hooks as a trigger only: read `conversation_id` and the proposed `command` (shell) or `tool_name` (MCP) from stdin with `jq`; print `{}` without `permission` so the hook abstains from the permission merge and does not change what Cursor allows. If `TMUX_PANE` is unset, print `{}` and exit. Otherwise start the same script again as `notify-on-approval --watch <pane> <command> <group>`, forked by `perl` into its own session (`setsid`) with its output on `/dev/null`, so it outlives the hook and Cursor does not wait for it. Then print `{}` at once.

**Shared code.** `bin/lib.sh` holds what both notify scripts need: `tmux_cmd` (tmux on the agent's socket), `shell_quote`, `terminal_is_front`, `pane_is_visible`, and `notify` (terminal-notifier with click-to-focus, `osascript` fallback). Both scripts source it, which replaces the v1 rule that each script is standalone.

**Polling.** After `NOTIFY_APPROVAL_DELAY` (default 0.4s), the watcher loops at `NOTIFY_APPROVAL_INTERVAL` (default 0.5s), up to `NOTIFY_APPROVAL_POLLS` (default 240, ~2 minutes). Each iteration runs `tmux capture-pane` on the hook pane and inspects the last 15 lines.

**Timing rules.**

1. **Wait for card:** Until a matching card is seen, count polls without a marker; exit quietly after `NOTIFY_APPROVAL_APPEAR_POLLS` (default 40, ~20s) so auto-approved commands stay silent.
2. **Notify when user leaves:** Once a matching card is seen, post when the terminal is not frontmost or the pane is not visible (same focus/pane rules as `stop`).
3. **Stop watching:** Exit without notifying if the marker disappears after the card was seen, if a marker appears but the snippet does not match (different card), or when the poll budget is exhausted.

**Matching.** Card markers from cursor-agent 2026.09.28 bundle strings: `Run this command?`, `Run this command outside the sandbox?`, `Run this MCP tool?`. When the hook snippet is at least 8 characters, the pane text (newlines removed) must contain the first 24 characters of the snippet so unrelated cards are ignored.

**Suppression.** No notification while the user is frontmost on that pane. Same `terminal_is_front` / `pane_is_visible` helpers as `stop`.

**Notification.** Title `Cursor needs approval`. Body: the command or MCP tool name, cut to 80 characters, or `agent` when neither is present. Group `cursor-<conversation_id>` (same as `stop`, so a finish notification replaces a pending approval). Sound `Glass`. Click runs `bin/focus-pane` via `terminal-notifier -execute`; `osascript display notification` fallback has no click action.

**Installer.** `bin/install` idempotently merges `beforeShellExecution` and `beforeMCPExecution` entries pointing at `bin/notify-on-approval` using `jq`, keeping other hooks.

**Tests.** `tests/run.sh` runs shell tests with fakes for `tmux`, `osascript`, `terminal-notifier`, and timing env vars.

**Known limitations.** IDE approval cards are not in a tmux pane. Prompt text may change between CLI versions. Auto-approved commands never show a card and never notify.

## Background

This is why v1 is a hook and not a tmux-notify clone. It is context, not a requirement.

[tmux-notify](https://github.com/rickstaa/tmux-notify) polls a pane for a shell prompt (`$`, `#`, `%`), then calls `notify-send` or `osascript`. You start it with `prefix + m`. It does not know whether a Cursor turn finished. [cursor-notifier](https://github.com/dnielbowen/cursor-notifier) polls tmux for a `cursor-agent` pane and treats a disappearing token counter as idle, then posts to Discord. [claude-tmux-notifier](https://github.com/ddzero2c/claude-tmux-notifier) is the closest behavior: Claude Code `Stop` and permission-prompt hooks, `terminal-notifier`, and a click that focuses the tmux pane. Cursor has `stop` and does not have Claude's `Notification` / `permission_prompt` hook. [vde-notifier](https://github.com/yuki-yano/vde-notifier) is a macOS click-to-pane tool you invoke yourself. Cursor's own System Notifications cover the IDE when it is unfocused, not the CLI in tmux.

## Sources

- https://github.com/rickstaa/tmux-notify
- https://github.com/dnielbowen/cursor-notifier
- https://github.com/ddzero2c/claude-tmux-notifier
- https://github.com/aquemy/claude-notifier
- https://github.com/yuki-yano/vde-notifier
- https://cursor.com/docs/hooks
- https://forum.cursor.com/t/fire-a-hook-when-agent-waits-for-command-tool-approval/166947
- https://forum.cursor.com/t/expose-agent-approval-waiting-state-via-hooks-cli-events/159912
- https://forum.cursor.com/t/cursor-cli-doesnt-send-all-events-defined-in-hooks/148316
