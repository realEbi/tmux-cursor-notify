# Shared by notify-on-stop and notify-on-approval. Source it; do not run it.
LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# Talk to the tmux server the agent runs under.
tmux_cmd() {
  if [ -n "${TMUX-}" ]; then
    tmux -S "${TMUX%%,*}" "$@"
  else
    tmux "$@"
  fi
}

shell_quote() {
  local escaped=${1//\'/\'\\\'\'}
  printf "'%s'" "$escaped"
}

# True when the terminal that started the agent is the frontmost app.
terminal_is_front() {
  local bundle=${__CFBundleIdentifier-} front
  if [ -n "$bundle" ]; then
    front=$(osascript -e 'tell application "System Events" to get bundle identifier of first application process whose frontmost is true') || return 1
    [ "$front" = "$bundle" ]
    return
  fi
  front=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true') || return 1
  case "$front" in
    Terminal|iTerm2|Ghostty|WezTerm|kitty|Alacritty) return 0 ;;
  esac
  return 1
}

# True when the pane is on screen: active pane, active window, attached session.
pane_is_visible() {
  local out active window attached
  out=$(tmux_cmd display-message -p -t "$1" '#{pane_active} #{window_active} #{session_attached}') || return 1
  read -r active window attached <<<"$out"
  [ "$active" = 1 ] && [ "$window" = 1 ] && [ "${attached:-0}" -ge 1 ] 2>/dev/null
}

# Post a notification. Clicking it runs focus-pane for the given pane.
notify() {
  local title=$1 body=$2 group=$3 pane=$4 socket= click
  [ -n "${TMUX-}" ] && socket=${TMUX%%,*}
  click="$(shell_quote "$LIB_DIR/focus-pane") $(shell_quote "${__CFBundleIdentifier-}") $(shell_quote "$socket") $(shell_quote "$pane")"
  terminal-notifier -title "$title" -message "$body" -sound Glass -group "$group" -execute "$click" ||
    osascript -e 'on run argv
  display notification (item 2 of argv) with title (item 1 of argv) sound name (item 3 of argv)
end run' -- "$title" "$body" Glass || true
}
