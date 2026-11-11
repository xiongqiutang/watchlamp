#!/bin/bash
# Feeds a scripted sequence of hook events to the hook handler (in a throwaway state
# directory) and checks the lamp state after each one. Usage: scripts/selftest.sh [binary]
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="${1:-build/Watchlamp.app/Contents/MacOS/Watchlamp}"
export WATCHLAMP_DIR="$(mktemp -d)"
trap 'rm -rf "$WATCHLAMP_DIR"' EXIT
SID="selftest-session"
FILE="$WATCHLAMP_DIR/sessions/$SID.json"
fails=0

send() {  # send <event> [extra json fields]
  local extra="${2:-}"
  printf '{"session_id":"%s","hook_event_name":"%s","cwd":"/tmp/demo-project","transcript_path":""%s}' \
    "$SID" "$1" "${extra:+,$extra}" | "$BIN" hook
  sleep 0.01  # events are ordered by hook start time
}

expect() {  # expect <label> <state> [detail substring]
  local state detail
  state=$(jq -r .state "$FILE" 2>/dev/null)
  detail=$(jq -r .detail "$FILE" 2>/dev/null)
  if [[ "$state" == "$2" && "$detail" == *"${3:-}"* ]]; then
    printf '  ok    %-44s %-8s %s\n' "$1" "$state" "$detail"
  else
    printf '  FAIL  %-44s got %s / "%s", want %s / "*%s*"\n' "$1" "$state" "$detail" "$2" "${3:-}"
    fails=$((fails + 1))
  fi
}

send SessionStart '"source":"startup"';                       expect "session start" idle
send UserPromptSubmit '"prompt":"hi"';                        expect "prompt submitted" working "@thinking"
send PreToolUse '"tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"npm test","description":"运行测试"}'
                                                              expect "tool starts" working "@cmd:运行测试"
send PermissionRequest '"tool_name":"Bash","tool_input":{"command":"npm test","description":"运行测试"}'
                                                              expect "permission prompt" waiting "@perm:@cmd:运行测试"
send Notification '"notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"'
                                                              expect "6s notification, same prompt" waiting "@perm:@cmd:运行测试"
[[ $(jq '.pending | length' "$FILE") == 1 ]] || { echo "  FAIL  duplicate permission waits"; fails=$((fails + 1)); }
send PostToolUse '"tool_name":"Bash","tool_use_id":"t1"';      expect "approved, tool done" working "@thinking"
send PreToolUse '"tool_name":"AskUserQuestion","tool_use_id":"q1"'
                                                              expect "asks a question" waiting "@ask"
send PreToolUse '"agent_id":"sub1","tool_name":"Read","tool_use_id":"t2","tool_input":{"file_path":"/a/b/readme.md"}'
                                                              expect "subagent busy, question still open" waiting "@ask"
send PostToolUse '"tool_name":"AskUserQuestion","tool_use_id":"q1"'
                                                              expect "question answered" working
send SubagentStop '"agent_id":"sub1"';                        expect "subagent finished" working
send Stop '"background_tasks":[{"id":"x","type":"local_agent","status":"running"},{"id":"y","type":"local_bash","status":"running"}]'
                                                              expect "turn ends, 1 background agent" working "@background:1"
send SubagentStop '"agent_id":"bg1"';                         expect "background agent done" idle
send UserPromptSubmit '"prompt":"again"';                     expect "new prompt" working
send PostToolUseFailure '"tool_name":"Bash","tool_use_id":"t3","is_interrupt":true'
                                                              expect "user interrupts" idle "@interrupted"
send UserPromptSubmit '"prompt":"retry"';                     expect "retry" working
send StopFailure '"error":"rate_limit"';                      expect "API error" waiting "@error:rate_limit"
send UserPromptSubmit '"prompt":"go on"';                     expect "user returns" working
send Notification '"notification_type":"idle_prompt","message":"Claude is waiting for your input"'
                                                              expect "idle notice after missed Stop" idle

# Background work after the turn: a test run or a build keeps the lamp on (and wakes Claude when it ends); a dev
# server, a watcher or a monitor does not. Payloads as Claude Code sends them (friendly type labels).
bg() {  # bg <type> <command> <description>
  printf '{"id":"b%s","type":"%s","status":"running","command":"%s","description":"%s"}' "$RANDOM" "$1" "$2" "$3"
}
stop_with() { send UserPromptSubmit '"prompt":"x"'; send Stop "\"background_tasks\":[$1]"; }
stop_with "$(bg shell 'npm test' 'Run the full test suite')"
                                                              expect "background test run" working "@bg:Run the full test suite"
send PreToolUse '"tool_name":"Bash","tool_use_id":"t9","tool_input":{"command":"cat log","description":"Read the results"}'
                                                              expect "woken by the finished run" working "@cmd:Read the results"
[[ $(jq '.turn_started == .state_since' "$FILE") == true ]] && echo "  ok    the clock keeps counting from the first turn" \
  || { echo "  FAIL  the clock restarted"; fails=$((fails + 1)); }
send Stop '"background_tasks":[]';                            expect "nothing left in the background" idle
stop_with "$(bg shell 'npm run dev' 'Start the dev server')"; expect "dev server" idle
stop_with "$(bg shell 'python3 -m http.server 8099 --bind 127.0.0.1' 'Serve the site for testing')"
                                                              expect "local test server" idle
stop_with "$(bg shell 'npx wrangler dev --local --port 8796' 'Run the reviews worker locally')"
                                                              expect "wrangler dev" idle
stop_with "$(bg shell 'python3 feed/server.py 8793 log' 'Run the local feed server')"
                                                              expect "a server script" idle
stop_with "$(bg shell 'npx jest --watch' 'Run the tests in watch mode')"
                                                              expect "tests in watch mode" idle
stop_with "$(bg shell 'tail -f build.log' 'Follow the log')";  expect "log tail" idle
stop_with "$(bg shell 'python3 app.py' 'Start the Flask app')"; expect "app started by description" idle
stop_with "$(bg monitor '' 'Watch CI')";                       expect "monitor" idle
stop_with "$(bg shell 'swift test > /dev/null 2>&1' 'Start the full test run')"
                                                              expect "test run despite Start and /dev/null" working "@bg:Start the full test run"
stop_with "$(bg shell 'NOTARY_PROFILE=x scripts/release.sh' 'Build, sign and notarize the disk image')"
                                                              expect "release build" working "@bg:Build, sign and notarize"
stop_with "$(bg shell 'gh run watch 123' 'Watch the CI run until it finishes')"
                                                              expect "gh run watch ends by itself" working "@bg:Watch the CI run"
stop_with "$(bg shell 'npm run dev' 'Start the dev server'),$(bg shell 'pytest -x' 'Run the unit tests')"
                                                              expect "server and tests: the tests count" working "@bg:Run the unit tests"
stop_with "$(bg subagent '' 'Review the diff'),$(bg shell 'make' 'Build the app')"
                                                              expect "an agent and a build" working "@background:2"
stop_with "$(bg 'memory save' '' 'Save memories')";            expect "Claude Code housekeeping" idle

send SessionEnd '"reason":"exit"'
[[ ! -e "$FILE" ]] && echo "  ok    session end removes the lamp" || { echo "  FAIL  session end"; fails=$((fails + 1)); }

# Hook latency (it runs before and after every tool call).
start=$(python3 -c 'import time; print(time.time())')
for _ in $(seq 20); do send PreToolUse '"tool_name":"Read","tool_input":{"file_path":"/x"}'; done
python3 -c "import time; print('  hook: %.1f ms per event (incl. 10ms test sleep)' % ((time.time() - $start) * 1000 / 20))"

# Connecting edits settings.json in place: other settings keep their order, other hooks survive.
check() { if eval "$2"; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s\n' "$1"; fails=$((fails + 1)); fi; }
export WATCHLAMP_CLAUDE_DIR="$WATCHLAMP_DIR/claude"
mkdir -p "$WATCHLAMP_CLAUDE_DIR"
SETTINGS="$WATCHLAMP_CLAUDE_DIR/settings.json"
printf '%s\n' '{' '  "theme": "auto",' '  "hooks": {' '    "Stop": [' '      {' '        "hooks": [' '          {' \
  '            "type": "command",' '            "command": "say done"' '          }' '        ]' '      }' '    ]' '  },' \
  '  "zeta": [' '    1,' '    2' '  ]' '}' > "$SETTINGS"
cp "$SETTINGS" "$WATCHLAMP_DIR/original.json"
ours='[.hooks[][] | .hooks[] | select(.command | test("Watchlamp"))] | length'
"$BIN" connect >/dev/null
check "connect adds the 16 hooks" '[[ $(jq "$ours" "$SETTINGS") == 16 ]]'
check "connect keeps other hooks" '[[ $(jq -r ".hooks.Stop[0].hooks[0].command" "$SETTINGS") == "say done" ]]'
check "connect keeps the key order" '[[ $(jq -r "keys_unsorted | join(\",\")" "$SETTINGS") == "theme,hooks,zeta" ]]'
check "connection reports connected" '[[ $("$BIN" connection) == connected ]]'
"$BIN" connect >/dev/null
check "connecting twice adds nothing" '[[ $(jq "$ours" "$SETTINGS") == 16 ]]'
"$BIN" disconnect >/dev/null
check "disconnect restores the file byte for byte" 'cmp -s "$SETTINGS" "$WATCHLAMP_DIR/original.json"'
printf '{ "broken": ' > "$SETTINGS"
check "invalid JSON is left alone" '! "$BIN" connect >/dev/null && [[ $(cat "$SETTINGS") == "{ \"broken\": " ]]'

# Every language must translate every English string.
en_keys=$(plutil -convert json -o - Resources/en.lproj/Localizable.strings | jq -r 'keys[]' | sort)
for f in Resources/*.lproj/Localizable.strings; do
  lang=$(basename "$(dirname "$f")" .lproj)
  keys=$(plutil -convert json -o - "$f" | jq -r 'keys[]' | sort)
  if [[ "$keys" == "$en_keys" ]]; then printf '  ok    %-44s %s strings\n' "translations: $lang" "$(wc -l <<< "$keys" | tr -d ' ')"
  else printf '  FAIL  translations: %s has missing or extra strings\n' "$lang"; fails=$((fails + 1)); fi
done

[[ $fails == 0 ]] && echo "All checks passed." || { echo "$fails check(s) failed."; exit 1; }
