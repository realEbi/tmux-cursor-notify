# Cursor adapter. Sourced by notify and install; do not run it.
AGENT_LABEL=Cursor
# The approval card shows up just after the hook runs.
AGENT_PROMPT_APPEARS_LATER=1
AGENT_CONFIG=.cursor/hooks.json
AGENT_CONFIG_SHAPE=flat

# One line per hook: the event name, a tab, and the matcher (none for Cursor).
agent_hooks() {
  printf '%s\t\n' stop beforeShellExecution beforeMCPExecution
}

# agent_parse EVENT INPUT
# Sets kind, session, folder, detail and title. An unknown event leaves kind empty.
agent_parse() {
  local event=$1 input=$2 status=
  kind= session= folder= detail= title=
  case $event in
    stop)
      # The folder is the first workspace path; the core takes its last part.
      eval "$(printf '%s' "$input" | jq -r '
        @sh "status=\(.status | strings // "")",
        @sh "session=\(.conversation_id | strings // "")",
        @sh "folder=\(.workspace_roots[0]? | strings // "")"
      ' 2>/dev/null)"
      case $status in
        completed) kind=finished title="$AGENT_LABEL finished" ;;
        error) kind=failed title="$AGENT_LABEL hit an error" ;;
      esac
      ;;
    beforeShellExecution | beforeMCPExecution)
      # Shell calls carry "command"; MCP calls carry "tool_name".
      eval "$(printf '%s' "$input" | jq -r '
        objects |
        @sh "kind=attention",
        @sh "detail=\(.command // .tool_name // "" | tostring)",
        @sh "session=\(.conversation_id | strings // "")",
        @sh "folder=\(.workspace_roots[0]? | strings // "")"
      ' 2>/dev/null)"
      title="$AGENT_LABEL needs approval"
      ;;
  esac
}

# Card titles from cursor-agent 2026.09.28 (6949.index.js).
card_is_shown() {
  case "$1" in
    *'Run this command?'* | *'Run this command outside the sandbox?'* | *'Run this MCP tool?'*) return 0 ;;
  esac
  return 1
}

# True when the first 24 characters of the command are on screen, so a card for
# a different command does not count. Commands under 8 characters are not checked.
card_is_for() {
  local screen=${1//$'\n'/} cmd=${2//$'\n'/}
  [ "${#cmd}" -lt 8 ] && return 0
  [[ $screen == *"${cmd:0:24}"* ]]
}

# agent_prompt_on_screen SCREEN DETAIL
# True when the approval card for DETAIL is in the last 15 lines of the pane text.
agent_prompt_on_screen() {
  local screen
  screen=$(printf '%s\n' "$1" | tail -n 15)
  card_is_shown "$screen" && card_is_for "$screen" "$2"
}
