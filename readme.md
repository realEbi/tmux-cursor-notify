# tmux-cursor-notify

macOS notifications for the Cursor CLI (`agent`) running in tmux. Get a ping when a turn finishes or when the agent is waiting for you to approve a command, then click the notification to jump back to the right pane.

![Notifications from tmux-cursor-notify](docs/notification-sample.png)

## What you get

| Notification | When | Body |
| --- | --- | --- |
| **Cursor needs approval** | The CLI shows an approval card for a shell command or MCP tool | The command |
| **Cursor finished** | A turn completes | The workspace folder |
| **Cursor hit an error** | A turn ends with an error | The workspace folder |

Nothing is sent when you are already looking at the pane (terminal in front, that pane visible), when you abort a turn, or when the agent is not running in tmux. Clicking a notification brings the terminal forward and selects the pane. When the turn finishes, "Cursor finished" replaces the approval notification for that chat.

## How it works

`bin/install` adds three user-level Cursor hooks to `~/.cursor/hooks.json`:

- `stop` runs `bin/notify-on-stop` when a turn ends.
- `beforeShellExecution` and `beforeMCPExecution` run `bin/notify-on-approval` when the agent proposes a command.

Cursor has no hook for "an approval card is on screen", so the approval hook only uses the proposal as a trigger. It answers Cursor with `{}` right away, so it never allows or denies anything. It then starts a background watcher that reads the tmux pane. The watcher notifies once the card appears and you look away, and stops quietly if the card goes away or after about two minutes. Commands that run without asking never show a card, so they never notify.

## Requirements

- macOS, tmux, and the Cursor CLI started inside a tmux pane.
- `jq` (ships with macOS 15 and later, otherwise `brew install jq`) and `perl` (ships with macOS).
- Recommended: `brew install terminal-notifier` for click-to-focus. Without it, notifications fall back to `osascript`, which cannot focus the pane.

## Install

```bash
bin/install
```

It adds the three hooks and keeps any others in the file. Running it again does not add duplicates. Run it again after pulling changes, then start a new `agent` session so the hooks load.

### macOS setup

- **Notifications:** System Settings → Notifications → **terminal-notifier** → allow notifications, with banners or alerts and sound on. If you denied it earlier, run `tccutil reset UserNotification fr.julienxx.oss.terminal-notifier` and trigger a notification to get the prompt again. For the `osascript` fallback, allow **Script Editor** too.
- **Automation:** if macOS asks whether your terminal may control System Events, allow it. That is how the hooks tell whether you are looking at the pane.
- Focus and Do Not Disturb hide banners.

## Try it

1. In a tmux pane, start `agent` and ask it to run a command that is not on your allowlist.
2. While the approval card is up, switch to another app. You should get **Cursor needs approval**.
3. Approve it and stay away until the turn ends. You should get **Cursor finished**.

If nothing shows up, check the macOS setup above, and that `agent` was started inside tmux so the hooks see `TMUX_PANE`.

Run the tests with `bash tests/run.sh`.

## Settings

Environment variables tune the approval watcher. The defaults suit normal use; the tests shorten them.

| Variable | Default | Meaning |
| --- | --- | --- |
| `NOTIFY_APPROVAL_DELAY` | `0.4` | Seconds before the first check of the pane |
| `NOTIFY_APPROVAL_INTERVAL` | `0.5` | Seconds between checks |
| `NOTIFY_APPROVAL_APPEAR_POLLS` | `40` | Checks to wait for the card to appear (about 20 seconds) |
| `NOTIFY_APPROVAL_POLLS` | `240` | Most checks in total (about 2 minutes) |

## Limitations

- Approval cards in the Cursor IDE are not covered, because they are not shown in a tmux pane.
- Approval detection matches the CLI's prompt text (`Run this command?`, `Run this command outside the sandbox?`, `Run this MCP tool?`), which may change between CLI versions.
- If you launch the Cursor IDE from inside a tmux pane, it can inherit `TMUX_PANE`, and its turns can notify too.
