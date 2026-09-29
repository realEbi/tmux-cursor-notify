# tmux-cursor-notify

A Cursor `stop` hook for the Cursor CLI (`agent`) running inside a local tmux pane. It is not a tmux plugin and it does not use TPM.

When a turn finishes with status `completed` or `error`, it posts a macOS notification, unless the terminal is the frontmost app and that same pane is already on screen. Clicking the notification activates the terminal and selects the pane. `aborted` stays silent. A stop with no `TMUX_PANE` stays silent, so a normal Cursor IDE session does not notify. If you launch the IDE from inside a tmux pane, that variable can be inherited and a notification can still fire.

## Install

`agent` must be started inside the tmux pane so the hook inherits `TMUX` and `TMUX_PANE`.

```bash
bin/install
```

That merges a `stop` command into `~/.cursor/hooks.json` and leaves any other hooks in place. Running it again does not add a duplicate.

`terminal-notifier` is optional. Without it, the hook falls back to `osascript`, which cannot focus the pane when you click.

## Manual check

1. Finish a turn in `agent` while the terminal is not the frontmost app. A notification appears. Clicking it selects that pane.
2. Finish a turn while the terminal is frontmost and that pane is selected. No notification.
3. Finish a turn while the terminal is frontmost but another pane is selected, then again with another window selected. Each one notifies.

If nothing appears even when the terminal is unfocused, `TMUX_PANE` is not reaching the hook.
