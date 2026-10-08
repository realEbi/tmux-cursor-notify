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
  esac
}
