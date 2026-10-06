# tmux-cursor-notify

A Cursor hooks bundle for the Cursor CLI (`agent`) running inside a local tmux pane. It is not a tmux plugin and it does not use TPM.

When a turn finishes, the `stop` hook posts a macOS notification for `completed` ("Cursor finished") or `error` ("Cursor hit an error"). `aborted` stays silent. With no `TMUX_PANE` the stop hook stays silent, so a normal Cursor IDE session does not notify. If you launch the IDE from inside a tmux pane, that variable can be inherited and a notification can still fire.

When the CLI needs approval, `beforeShellExecution` and `beforeMCPExecution` run `bin/notify-on-approval`. The hook always prints `{}` and exits 0; it never sets `permission`, so it does not change what Cursor allows or asks. Without `TMUX_PANE` it does nothing. Otherwise it starts a detached background watcher and returns at once. The watcher waits for the approval card to appear in the last 15 lines of the pane (matching CLI prompt text and, when the proposed command is at least 8 characters, the first 24 characters of that command). Auto-approved commands stay silent because the card never appears. Once the card is visible, it notifies when you leave that pane (terminal not frontmost, or the pane not active/visible). It stays quiet while you are watching the card, and exits without notifying if the card goes away, a different card appears, or a timeout is reached. Clicking uses the same notification group as the stop hook, so a finished alert replaces a pending approval alert.

Both hooks skip notification when the terminal is the frontmost app and that same tmux pane is already on screen. Clicking a notification activates the terminal and selects the pane when `terminal-notifier` is used.

## Requirements

- macOS, tmux, bash, and the Cursor CLI (`agent`) started inside a tmux pane so hooks inherit `TMUX` and `TMUX_PANE`.
- `jq` for `bin/install` and the approval hook (ships with macOS 15 and later; otherwise `brew install jq`). `perl` (ships with macOS) to start the approval watcher in the background.
- Optional but recommended: `brew install terminal-notifier` for click-to-focus on notifications.
- Notifications: System Settings → Notifications → **terminal-notifier** → allow notifications (banners or alerts, sound on). If you denied it earlier, reset with `tccutil reset UserNotification fr.julienxx.oss.terminal-notifier`, then trigger a notification to get the prompt again.
- If `terminal-notifier` fails, the scripts fall back to `osascript display notification`, which cannot focus the pane on click. Allow **Script Editor** under Notifications for that path.
- Focus / Do Not Disturb hides banners.
- Frontmost and pane visibility use System Events via `osascript`. macOS may ask to allow your terminal to control System Events (Privacy & Security → Automation). Allow it.
- After pulling changes, run `bin/install` again and start a new agent session so hooks reload.

## Install

```bash
bin/install
```

That merges `stop`, `beforeShellExecution`, and `beforeMCPExecution` into `~/.cursor/hooks.json` and leaves any other hooks in place. Running it again does not add duplicates.


## Test it

1. Start `agent` in a tmux pane. Ask for a command that is not on your allowlist. While the approval card is on screen, switch to another app. Expect a "Cursor needs approval" notification; clicking it should focus the pane when `terminal-notifier` is installed.
2. Finish a turn while the terminal is not frontmost. Expect "Cursor finished" or "Cursor hit an error". Clicking selects that pane.
3. Finish a turn while the terminal is frontmost and that pane is selected. No notification.
4. Finish a turn while the terminal is frontmost but another pane or window is selected. Each case notifies.

If nothing appears when the terminal is unfocused, `TMUX_PANE` is not reaching the hook.

Automated checks: `bash tests/run.sh`.

## Environment variables

Approval watcher tuning (seconds for delay/interval; poll counts multiply by `NOTIFY_APPROVAL_INTERVAL` after the initial delay):

| Variable | Default | Role |
| --- | --- | --- |
| `NOTIFY_APPROVAL_DELAY` | `0.4` | Sleep before the first pane capture (hook fires before the CLI draws the card). |
| `NOTIFY_APPROVAL_INTERVAL` | `0.5` | Seconds between pane polls. |
| `NOTIFY_APPROVAL_APPEAR_POLLS` | `40` | Max polls waiting for the card to appear (~20s at default interval). |
| `NOTIFY_APPROVAL_POLLS` | `240` | Max polls after the delay (~2 minutes at default interval). |

## Limitations

- Cursor IDE approval cards are not covered; they are not rendered in a tmux pane.
- Approval detection relies on CLI prompt strings that may change between CLI versions.
- Auto-approved commands do not notify (by design).
