#!/usr/bin/env bash
set -u
source "$(dirname "$0")/harness.sh"

STOP_EXPECTED=$(cd "$ROOT/bin" && pwd -P)/notify-on-stop
APPROVAL_EXPECTED=$(cd "$ROOT/bin" && pwd -P)/notify-on-approval

fresh_home() {
  harness_use_fakes
  export HOME
  HOME=$(mktemp -d)
}

run_install() {
  run_capture "$ROOT/bin/install"
}

assert_created() {
  python3 - "$HOME/.cursor/hooks.json" "$STOP_EXPECTED" "$APPROVAL_EXPECTED" <<'PY'
import json, sys
path, stop, approval = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as handle:
    data = json.load(handle)
expected = {
    "version": 1,
    "hooks": {
        "stop": [{"command": stop}],
        "beforeShellExecution": [{"command": approval}],
        "beforeMCPExecution": [{"command": approval}],
    },
}
if data != expected:
    print(f"assert_created: expected {expected!r} got {data!r}", file=sys.stderr)
    sys.exit(1)
PY
}

hooks_path() {
  printf '%s/.cursor/hooks.json' "$HOME"
}

assert_bytes_unchanged() {
  local path="$1" before="$2"
  local after
  after=$(cat "$path")
  if [ "$after" != "$before" ]; then
    echo "assert_bytes_unchanged: file changed" >&2
    echo "before: [$before]" >&2
    echo "after: [$after]" >&2
    exit 1
  fi
}

test_install_creates() {
  fresh_home
  run_install
  assert_exit 0
  assert_created
}

test_install_empty_object() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  printf '%s\n' '{}' > "$(hooks_path)"
  run_install
  assert_exit 0
  assert_created
}

test_install_appends() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  printf '%s\n' '{"version":1,"hooks":{"stop":[{"command":"/bin/other"}]}}' > "$(hooks_path)"
  run_install
  assert_exit 0
  python3 - "$(hooks_path)" "$STOP_EXPECTED" "$APPROVAL_EXPECTED" <<'PY'
import json, sys
path, ours, approval = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as handle:
    data = json.load(handle)
stop = data["hooks"]["stop"]
if len(stop) != 2:
    print(f"expected 2 stop entries, got {len(stop)}", file=sys.stderr)
    sys.exit(1)
if stop[0] != {"command": "/bin/other"}:
    print(f"first entry wrong: {stop[0]!r}", file=sys.stderr)
    sys.exit(1)
if stop[1] != {"command": ours}:
    print(f"second entry wrong: {stop[1]!r}", file=sys.stderr)
    sys.exit(1)
approval = sys.argv[3]
for name in ("beforeShellExecution", "beforeMCPExecution"):
    arr = data["hooks"].get(name, [])
    if len(arr) != 1 or arr[0].get("command") != approval:
        print(f"{name} wrong: {arr!r}", file=sys.stderr)
        sys.exit(1)
PY
}

test_install_keeps_non_object() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  printf '%s\n' '{"hooks":{"stop":[null,"x"]}}' > "$(hooks_path)"
  run_install
  assert_exit 0
  python3 - "$(hooks_path)" "$STOP_EXPECTED" <<'PY'
import json, sys
path, ours = sys.argv[1], sys.argv[2]
with open(path) as handle:
    data = json.load(handle)
stop = data["hooks"]["stop"]
if len(stop) != 3:
    print(f"expected 3 stop entries, got {len(stop)}", file=sys.stderr)
    sys.exit(1)
if stop[0] is not None or stop[1] != "x":
    print(f"prefix wrong: {stop[:2]!r}", file=sys.stderr)
    sys.exit(1)
if stop[2] != {"command": ours}:
    print(f"last entry wrong: {stop[2]!r}", file=sys.stderr)
    sys.exit(1)
PY
}

test_install_idempotent() {
  fresh_home
  run_install
  assert_exit 0
  run_install
  assert_exit 0
  python3 - "$(hooks_path)" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
if len(data["hooks"]["stop"]) != 1:
    print(f"expected stop length 1, got {len(data['hooks']['stop'])}", file=sys.stderr)
    sys.exit(1)
for name in ("beforeShellExecution", "beforeMCPExecution"):
    if len(data["hooks"][name]) != 1:
        print(f"expected {name} length 1", file=sys.stderr)
        sys.exit(1)
PY
}

test_install_registers_approval_idempotent() {
  fresh_home
  run_install
  assert_exit 0
  run_install
  assert_exit 0
  python3 - "$(hooks_path)" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
for name in ("beforeShellExecution", "beforeMCPExecution", "stop"):
    if len(data["hooks"][name]) != 1:
        print(f"duplicate {name}", file=sys.stderr)
        sys.exit(1)
PY
}

test_install_invalid_json() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  local path
  path=$(hooks_path)
  printf '%s' 'not-json' > "$path"
  local before
  before=$(cat "$path")
  run_install
  assert_exit 1
  assert_bytes_unchanged "$path" "$before"
}

test_install_hooks_json_is_directory() {
  fresh_home
  mkdir -p "$HOME/.cursor/hooks.json"
  run_install
  assert_exit 1
  if [ ! -d "$HOME/.cursor/hooks.json" ]; then
    echo "hooks.json directory missing" >&2
    exit 1
  fi
}

test_install_cursor_is_file() {
  fresh_home
  printf '%s' 'keep' > "$HOME/.cursor"
  run_install
  assert_exit 1
  if [ -f "$(hooks_path)" ]; then
    echo "hooks.json should not exist" >&2
    exit 1
  fi
  if [ "$(cat "$HOME/.cursor")" != 'keep' ]; then
    echo ".cursor file changed" >&2
    exit 1
  fi
}

test_install_mv_fails() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  printf '%s\n' '{"version":1,"hooks":{"stop":[{"command":"/bin/other"}]}}' > "$(hooks_path)"
  export FAKE_MV_EXIT=1
  run_install
  assert_exit 1
  python3 - "$(hooks_path)" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
cmd = data["hooks"]["stop"][0]["command"]
if cmd != "/bin/other":
    print(f"expected /bin/other got {cmd!r}", file=sys.stderr)
    sys.exit(1)
PY
}

test_install_via_symlink() {
  fresh_home
  ln -s "$ROOT/bin/install" "$HOME/install-link"
  set +e
  LAST_STDOUT=$(cd / && HOME="$HOME" PATH="$PATH" "$HOME/install-link" 2>>"$FAKE_LOG/stderr")
  LAST_STATUS=$?
  set -e
  assert_exit 0
  assert_created
  python3 - "$(hooks_path)" "$HOME" <<'PY'
import json, sys
path, home = sys.argv[1], sys.argv[2]
with open(path) as handle:
    data = json.load(handle)
cmd = data["hooks"]["stop"][0]["command"]
if cmd.startswith(home):
    print(f"command must not start with HOME: {cmd!r}", file=sys.stderr)
    sys.exit(1)
PY
}

test_install_bad_version() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  local path
  path=$(hooks_path)
  printf '%s\n' '{"version":2,"hooks":{"stop":[]}}' > "$path"
  local before
  before=$(cat "$path")
  run_install
  assert_exit 1
  assert_bytes_unchanged "$path" "$before"
}

test_install_root_array() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  local path
  path=$(hooks_path)
  printf '%s\n' '[]' > "$path"
  local before
  before=$(cat "$path")
  run_install
  assert_exit 1
  assert_bytes_unchanged "$path" "$before"
}

test_install_hooks_not_object() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  local path
  path=$(hooks_path)
  printf '%s\n' '{"hooks":[]}' > "$path"
  local before
  before=$(cat "$path")
  run_install
  assert_exit 1
  assert_bytes_unchanged "$path" "$before"
}

test_install_stop_not_array() {
  fresh_home
  mkdir -p "$HOME/.cursor"
  local path
  path=$(hooks_path)
  printf '%s\n' '{"hooks":{"stop":{}}}' > "$path"
  local before
  before=$(cat "$path")
  run_install
  assert_exit 1
  assert_bytes_unchanged "$path" "$before"
}


test_install_python_rejects_bool_version() {
  fresh_home
  harness_hide jq
  mkdir -p "$HOME/.cursor"
  printf '%s\n' '{"version":true,"hooks":{"stop":[]}}' > "$HOME/.cursor/hooks.json"
  before=$(cat "$HOME/.cursor/hooks.json")
  run_install
  if [ "$LAST_STATUS" -eq 0 ]; then echo "expected non-zero" >&2; exit 1; fi
  if [ "$(cat "$HOME/.cursor/hooks.json")" != "$before" ]; then echo "changed" >&2; exit 1; fi
}

test_install_python_fallback() {
  fresh_home
  harness_hide jq
  run_install
  assert_exit 0
  assert_created
  assert_not_called mv
}

test_install_no_parsers() {
  fresh_home
  harness_hide jq
  harness_hide python3
  run_install
  assert_exit 1
  if [ -e "$(hooks_path)" ]; then
    echo "hooks.json should not exist" >&2
    exit 1
  fi
}

run_tests \
  test_install_creates \
  test_install_empty_object \
  test_install_appends \
  test_install_keeps_non_object \
  test_install_idempotent \
  test_install_registers_approval_idempotent \
  test_install_invalid_json \
  test_install_hooks_json_is_directory \
  test_install_cursor_is_file \
  test_install_mv_fails \
  test_install_via_symlink \
  test_install_bad_version \
  test_install_root_array \
  test_install_hooks_not_object \
  test_install_stop_not_array \
  test_install_python_rejects_bool_version \
  test_install_python_fallback \
  test_install_no_parsers
