# Shared by notify and install. Source it; do not run it.
LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# Talk to the tmux server the agent runs under.
tmux_cmd() {
  if [ -n "${TMUX-}" ]; then
    tmux -S "${TMUX%%,*}" "$@"
  else
    tmux "$@"
  fi
}

# Source the adapter for an agent. The name becomes part of a path, so only
# lowercase letters are accepted. Fails when there is no such adapter.
load_adapter() {
  case $1 in
    '' | *[!abcdefghijklmnopqrstuvwxyz]*) return 1 ;;
  esac
  [ -f "$LIB_DIR/agents/$1.sh" ] || return 1
  . "$LIB_DIR/agents/$1.sh"
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

# number_or VALUE DEFAULT
# Print VALUE when it is a decimal number that is not negative, like 2, 0.5 or
# .5. Print DEFAULT for anything else.
number_or() {
  local number='^([0-9]+(\.[0-9]*)?|\.[0-9]+)$'
  if [[ $1 =~ $number ]]; then
    printf '%s\n' "$1"
  else
    printf '%s\n' "$2"
  fi
}

# count_or VALUE DEFAULT
# Print VALUE when it is a whole number above zero, of nine digits at most so
# that shell arithmetic can hold it. Print DEFAULT for anything else.
count_or() {
  local count='^[0-9]{1,9}$'
  if [[ $1 =~ $count ]] && [ "$((10#$1))" -gt 0 ]; then
    printf '%s\n' "$((10#$1))"
  else
    printf '%s\n' "$2"
  fi
}

# One watcher per pane. A watcher that sees its prompt writes its process id to
# the pane file, and an earlier one stops when it reads another id there.
# PANE_FILE is empty until then, and stays empty when the file cannot be
# written; the watcher then runs without the check.
PANE_FILE=

# Take over the pane. The file is named after the tmux socket and the pane id,
# because every tmux server has a pane %0. Characters other than letters and
# digits (and % in the pane id, which looks like %12) are replaced, and both
# parts are cut short, so the name cannot point outside the directory or grow
# too long.
pane_claim() {
  local dir="${TMPDIR:-/tmp}/tmux-agent-notify" socket= pane file
  local safe=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789
  [ -n "${TMUX-}" ] && socket=${TMUX%%,*}
  socket=${socket//[!$safe]/_}
  pane=${1//[!%$safe]/_}
  # The end of a socket path is the part that differs between servers.
  [ "${#socket}" -gt 100 ] && socket=${socket:$((${#socket} - 100))}
  file="$dir/pane-$socket-${pane:0:40}"
  { mkdir -p "$dir" && printf '%s\n' "$$" >"$file"; } 2>/dev/null || return 0
  PANE_FILE=$file
}

# True when another watcher has taken over the pane. A file that is missing or
# unreadable does not count: a duplicate is better than no notification.
pane_taken() {
  local holder=
  [ -n "$PANE_FILE" ] || return 1
  { read -r holder <"$PANE_FILE"; } 2>/dev/null || return 1
  [ -n "$holder" ] && [ "$holder" != "$$" ]
}

# Remove the pane file when it still holds this watcher's id.
pane_release() {
  local holder=
  [ -n "$PANE_FILE" ] || return 0
  { read -r holder <"$PANE_FILE"; } 2>/dev/null || return 0
  if [ "$holder" = "$$" ]; then
    rm -f "$PANE_FILE"
  fi
}
