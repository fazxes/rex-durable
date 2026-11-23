#!/bin/bash
# End-to-end test of rex-durable on a throwaway Rex server.
#
#   test/e2e.sh                 (needs Rex installed and a C compiler)
#   test/e2e.sh --unit          only the unit tests
#   REX=/path/to/rex test/e2e.sh
#
# It runs its own Rex server on its own socket and state folder, with fake
# fx, Claude Code, Codex, and pi chats that keep their files in a throwaway home
# folder. It never connects to your own Rex server or touches your real chats,
# and it stops only the server it started, by its process ID.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
os=$(uname -s)
if [ -z "${REX:-}" ]; then
  current="$HOME/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex"
  if [ "$os" = Darwin ] && [ -x "$current" ]; then REX=$current; else REX=$(command -v rex); fi
fi

T=$(cd "$(mktemp -d /tmp/rex-durable-e2e.XXXXXX)" && pwd -P)
H=$T/home
mkdir -p "$H" "$T/bin" "$T/state" "$T/durable" "$T/my proj"
: >"$T/init.lua"
SOCK="unix://$T/rex.sock"
passed=0
failed=0

clean_env() { env -u REX_SESSION -u REX_BLOCK -u REX_SERVER -u REX_CLIENT -u REX_CONFIG "$@"; }
R() { clean_env "$REX" --autostart=false -S "$SOCK" "$@"; }
D() { HOME="$H" R do "$here/durable.lua" "state_dir=$T/durable" notify=false "$@"; }
show() { HOME="$H" R do "$here/test/e2e_show.lua" "state_dir=$T/durable"; }

server_pid=""
watch_pid=""
start_server() {
  # Not through a shell function: $! must be the server itself, so stopping
  # it really stops the server, the way a restart does.
  env -u REX_SESSION -u REX_BLOCK -u REX_SERVER -u REX_CLIENT -u REX_CONFIG \
    "$REX" server run --listen "$SOCK" --state-dir "$T/state" --config "$T/init.lua" "$@" \
    >>"$T/server.log" 2>&1 &
  server_pid=$!
  for _ in $(seq 1 50); do
    if R ls >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  echo "the test server didn't start:"; cat "$T/server.log"; exit 1
}
stop_server() {
  if [ -n "$server_pid" ]; then
    kill -TERM "$server_pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$server_pid" 2>/dev/null; then
      echo "the test server didn't stop; killing it"
      kill -KILL "$server_pid" 2>/dev/null || true
      failed=$((failed + 1))
    fi
    wait "$server_pid" 2>/dev/null || true
    server_pid=""
  fi
  sleep 1
}
# Stop only what this test started, by PID: never by a name pattern.
stop_watcher() {
  rm -f "$T/supervise"
  if [ -f "$T/watch.pid" ]; then kill "$(cat "$T/watch.pid")" 2>/dev/null || true; fi
  if [ -n "$watch_pid" ]; then kill "$watch_pid" 2>/dev/null || true; wait "$watch_pid" 2>/dev/null || true; fi
  watch_pid=""
}
cleanup() {
  stop_watcher
  stop_server
  # The fake chats end with their server. Stop any left over: only processes
  # whose program is in this test's own folder.
  for p in $(pgrep -f "^$T/bin/" || true); do kill "$p" 2>/dev/null || true; done
  if [ "$failed" -gt 0 ] || [ "${KEEP:-0}" = 1 ]; then
    echo "Kept the test folder for a look: $T"
  else
    rm -rf "$T"
  fi
}
trap cleanup EXIT

ok() { passed=$((passed + 1)); echo "  ok    $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL  $1"; }
expect() { # description, command...
  local what=$1; shift
  if "$@"; then ok "$what"; else bad "$what"; fi
}
running() { pgrep -f -x "$1" | wc -l | tr -d ' '; }
has_line() { printf '%s\n' "$listing" | grep -E -q -- "$1"; }
# The block ID of a tab in a listing: block LISTING SESSION WINDOW.PANE
block() { printf '%s\n' "$1" | awk -v s="$2" -v tab="$3" '$1 == s && $2 == tab { print $NF }'; }

for app in fx claude codex pi; do
  cc -O0 -o "$T/bin/$app" -DAPP="\"$app\"" -DFAKE_HOME="\"$H\"" "$here/test/fake.c"
done
CODEX_ID=11111111-2222-4333-8444-555555555555

echo "0. Unit tests"
start_server
# From another folder, so the tests prove they load this repository's durable.lua.
if (cd / && R do "$here/test/unit.lua" "root=$here") >"$T/unit.log" 2>&1; then ok "$(tail -1 "$T/unit.log")"; else cat "$T/unit.log"; bad "unit tests"; fi
if [ "${1:-}" = "--unit" ]; then echo; echo "$passed passed, $failed failed"; [ "$failed" = 0 ]; exit; fi

echo "1. Save what runs in each tab"
R do "$here/test/e2e_setup.lua" "bin=$T/bin" "dir=$T/my proj" >/dev/null
sleep 3
D mode=save
listing=$(show)
expect "fx chat and its conversation" has_line '^work 1\.1 chat fx FXA '
expect "codex chat from its open rollout file" has_line "^work 1\.2 chat codex $CODEX_ID "
expect "new claude chat from its newest session file" has_line '^work 2\.1 chat claude 00000000-0000-4000-8000-'
expect "another program and its command" has_line '^work 3\.1 program - sleep 4242 '
expect "a plain shell" has_line '^work 4\.1 shell '
expect "a second session" has_line '^side 1\.1 chat fx FXB '
before=$listing
CLAUDE_ID=$(printf '%s\n' "$listing" | awk '$2 == "2.1" { print $5 }')

echo "2. Restart: Rex brings back the tabs, rex-durable the programs"
stop_server
expect "the fake chats stopped with the server" test "$(running "$T/bin/fx --resume FXA")" = 0
start_server
# A chat already open outside Rex must not be opened a second time.
(cd "$T" && exec "$T/bin/fx" --resume FXC >/dev/null) &
outside_pid=$!
sleep 1
# A restored tab that is busy for a few seconds, as when a shell's startup runs
# commands: rex-durable must wait for it, then reopen its chat.
R do -s side -e "rex.block.call('com.superlogical.terminal', 'write', \
  { block_id = '$(block "$before" side 1.1)', data = 'sleep 8\\n' }) return 'ok'" >/dev/null
# Wait until it really runs: a shell that is still starting runs it later.
for _ in $(seq 1 40); do
  [ "$(running "sleep 8")" = 1 ] && break
  sleep 0.25
done
D mode=startup >"$T/startup.log"
sleep 3
D mode=save
listing=$(show)
expect "fx chat reopened in the same tab" has_line "^work 1\.1 chat fx FXA $(block "$before" work 1.1)\$"
expect "codex chat reopened on its conversation" has_line "^work 1\.2 chat codex $CODEX_ID "
expect "claude chat reopened on its conversation" has_line "^work 2\.1 chat claude $CLAUDE_ID "
expect "a busy tab was waited for" grep -q 'trying again' "$T/startup.log"
expect "second session's chat reopened once its tab was free" has_line '^side 1\.1 chat fx FXB '
expect "program typed, not run" test "$(running "sleep 4242")" = 0
expect "program's command is waiting at the prompt" \
  sh -c "'$REX' --autostart=false -S '$SOCK' capture --trim -s work -b '$(block "$before" work 3.1)' | tail -1 | grep -q 'sleep 4242'"
expect "chat already open elsewhere left alone" grep -q 'fx chat FXC is already open' "$T/startup.log"
expect "one copy of each chat" test "$(running "$T/bin/fx --resume FXA")" = 1
expect "the outside copy is the only FXC" test "$(running "$T/bin/fx --resume FXC")" = 1

echo "3. Run again on the same server: nothing is opened twice"
D mode=startup >"$T/startup2.log"
sleep 2
expect "no second copy of a chat" test "$(running "$T/bin/fx --resume FXA")" = 1
expect "no second claude" test "$(running "$T/bin/claude --resume $CLAUDE_ID")" = 1
expect "nothing typed the second time" sh -c "! grep -q ' type ' '$T/startup2.log'"

echo "4. A server that starts empty: rex-durable rebuilds the sessions"
stop_server
start_server --restore=false
expect "the new server starts with no sessions" \
  test "$(R do -e 'return #((rex.call("session.list") or {}).sessions or {})')" = 0
D mode=startup >"$T/startup3.log"
sleep 3
D mode=save
listing=$(show)
expect "work session rebuilt with its chats" has_line '^work 1\.1 chat fx FXA '
expect "split rebuilt" has_line "^work 1\.2 chat codex $CODEX_ID "
expect "side session rebuilt" has_line '^side 1\.1 chat fx FXB '
expect "still only the outside FXC" test "$(running "$T/bin/fx --resume FXC")" = 1
kill "$outside_pid" 2>/dev/null || true

echo "5. The watcher, kept running like a login service, brings programs back by itself"
# launchd and systemd start the watcher again whenever it exits; so does this loop.
touch "$T/supervise"
(
  while [ -e "$T/supervise" ]; do
    env -u REX_SESSION -u REX_BLOCK -u REX_SERVER -u REX_CLIENT -u REX_CONFIG HOME="$H" \
      "$REX" --autostart=false -S "$SOCK" do "$here/durable.lua" --all mode=watch "rex=$REX" \
      "script=$here/durable.lua" "server=$SOCK" "state_dir=$T/durable" notify=false >>"$T/watch.log" 2>&1 &
    echo $! >"$T/watch.pid"
    wait $! || true
    sleep 1
  done
) &
watch_pid=$!
sleep 4
expect "watcher started" grep -q 'watching' "$T/watch.log"
# The tabs rebuilt in step 4 got new block IDs, so this restart also checks
# finding tabs by session and position.
stop_server
start_server
for _ in $(seq 1 40); do
  grep -q 'reopened [1-9]' "$T/watch.log" && break
  sleep 0.5
done
expect "watcher reopened the chats after the restart" grep -q 'reopened [1-9]' "$T/watch.log"
sleep 2
D mode=save
listing=$(show)
expect "fx chat back in its tab" has_line '^work 1\.1 chat fx FXA '
expect "codex chat back in its split" has_line "^work 1\.2 chat codex $CODEX_ID "
expect "claude chat back" has_line "^work 2\.1 chat claude $CLAUDE_ID "
expect "side session's chat back" has_line '^side 1\.1 chat fx FXB '
expect "one copy of each chat" test "$(running "$T/bin/fx --resume FXA")" = 1
rm -f "$T/supervise"
stop_watcher

echo "6. The command palette actions load"
sed -e "s|@REX@|$REX|" -e "s|@SCRIPT@|$here/durable.lua|" "$here/rex_durable.lua" >"$T/rex_durable.lua"
printf 'package.path = "%s/?.lua;" .. package.path\nrequire("rex_durable")\n' "$T" >"$T/check.lua"
expect "rex config check passes" sh -c "'$REX' config check '$T/check.lua' >'$T/check.log' 2>&1"

echo "7. Many tabs close at once while Rex keeps running"
HOME="$H" R do "$here/test/e2e_more.lua" action=sub "bin=$T/bin" "dir=$T/my proj" >/dev/null
sleep 2
D mode=save
listing=$(show)
expect "a chat that runs a subagent is saved as the main chat" has_line '^sub 1\.1 chat fx FXP '
before_panes=$(printf '%s\n' "$listing" | grep -c '^work ')
HOME="$H" R do "$here/test/e2e_more.lua" action=close label=work >/dev/null
sleep 2
expect "the closed tabs' chats stopped" test "$(running "$T/bin/fx --resume FXA")" = 0
D mode=save >"$T/drop.log"
expect "the drop is noticed" grep -q 'closed at once' "$T/drop.log"
expect "a copy from before the drop is kept" sh -c "ls '$T/durable/checkpoints'/auto-before-drop-*.json >/dev/null"
D mode=repair dry_run=true >"$T/repair-dry.log"
expect "a dry run lists the missing tabs" grep -q 'would add work tab 1' "$T/repair-dry.log"
expect "a dry run opens nothing" test "$(running "$T/bin/fx --resume FXA")" = 0
D mode=repair >"$T/repair.log"
sleep 4
D mode=save
listing=$(show)
expect "repair brings back the fx chat" has_line '^work 1\.1 chat fx FXA '
expect "repair brings back the codex split" has_line "^work 1\.2 chat codex $CODEX_ID "
expect "repair brings back the claude chat" has_line "^work 2\.1 chat claude $CLAUDE_ID "
expect "repair brings back every pane" test "$(printf '%s\n' "$listing" | grep -c '^work ')" = "$before_panes"
expect "repair opens each chat once" test "$(running "$T/bin/fx --resume FXA")" = 1
expect "the subagent's chat was not touched" test "$(running "$T/bin/fx --resume FXP --child SUBC1")" = 1
D mode=repair >"$T/repair2.log"
sleep 2
expect "a second repair adds nothing" grep -q 'Added 0 tabs and 0 sessions' "$T/repair2.log"
expect "still one copy of each chat" test "$(running "$T/bin/fx --resume FXA")" = 1

echo "8. An idle pi chat, which names its session nowhere, survives two restarts"
# The fake pi writes nothing and blanks its arguments, like pi brought back on
# --session and left alone. Only what the last restore typed says which it is.
PI_ID=22222222-3333-4444-8555-666666666666
pi_dir="$H/.pi/agent/sessions/--$(printf '%s' "${T#/}/my proj" | tr '/' '-')--"
mkdir -p "$pi_dir"
: >"$pi_dir/2026-11-17T00-00-00-000Z_$PI_ID.jsonl"
pi_window=$(R window new -s work -c "$T/my proj" --focus=false --json | jq -r .window_id)
sleep 1
pi_tab=$(R window ls -s work --json | jq -r --arg w "$pi_window" '.windows[] | select(.window_id == $w) | .focused_block_id')
# First run: pi is started on its session, so its file is the newest there.
R do -s work -e "rex.block.call('com.superlogical.terminal', 'write', \
  { block_id = '$pi_tab', data = [['$T/bin/pi' --session $PI_ID]] .. '\n' }) return 'ok'" >/dev/null
sleep 1
touch "$pi_dir/2026-11-17T00-00-00-000Z_$PI_ID.jsonl"
sleep 1
D mode=save
listing=$(show)
pi_pos=$(printf '%s\n' "$listing" | awk -v b="$pi_tab" '$NF == b { print $2 }')
expect "pi chat found by its new session file" has_line "^work $pi_pos chat pi $PI_ID "
for round in 1 2; do
  stop_server
  start_server
  D mode=startup >"$T/startup-pi-$round.log"
  sleep 3
  D mode=save
  listing=$(show)
  expect "restart $round: pi reopened on its session" grep -q "pi --session $PI_ID (run)" "$T/startup-pi-$round.log"
  expect "restart $round: the save still knows its session" has_line "^work $pi_pos chat pi $PI_ID "
done
expect "one copy of the pi chat" test "$(pgrep -f "$T/bin/pi" | wc -l | tr -d ' ')" = 1

echo "9. Repair after a restart keeps the idle pi chat's session"
D mode=repair >"$T/repair-pi.log" 2>&1
sleep 1
D mode=save
listing=$(show)
expect "after repair: the save still knows the pi session" has_line "^work $pi_pos chat pi $PI_ID "

echo "10. A pi typed before many other tabs is still known after a restart"
PI2_ID=33333333-4444-4555-8666-777777777777
mkdir -p "$T/other proj"
pi2_dir="$H/.pi/agent/sessions/--$(printf '%s' "${T#/}/other proj" | tr '/' '-')--"
mkdir -p "$pi2_dir"
: >"$pi2_dir/2026-11-17T00-00-00-000Z_$PI2_ID.jsonl"
new_tab() { # folder -> block ID of a new tab at the end of session work
  local w
  w=$(R window new -s work -c "$1" --focus=false --json | jq -r .window_id)
  sleep 1
  R window ls -s work --json | jq -r --arg w "$w" '.windows[] | select(.window_id == $w) | .focused_block_id'
}
type_in() { # block ID, command
  R do -s work -e "rex.block.call('com.superlogical.terminal', 'write', \
    { block_id = '$1', data = [[$2]] .. '\n' }) return 'ok'" >/dev/null
}
pi2_tab=$(new_tab "$T/other proj")
type_in "$pi2_tab" "'$T/bin/pi' --session $PI2_ID"
sleep 1
touch "$pi2_dir/2026-11-17T00-00-00-000Z_$PI2_ID.jsonl"
for n in $(seq 1 16); do type_in "$(new_tab "$T")" "'$T/bin/fx' --resume FILL$n"; done
sleep 2
D mode=save
listing=$(show)
pi2_pos=$(printf '%s\n' "$listing" | awk -v b="$pi2_tab" '$NF == b { print $2 }')
expect "second pi found by its new session file" has_line "^work $pi2_pos chat pi $PI2_ID "
expect "16 more chats saved after it" test "$(printf '%s\n' "$listing" | grep -c ' chat fx FILL')" = 16
stop_server
start_server
D mode=startup >"$T/startup-many.log"
sleep 3
D mode=save
listing=$(show)
echo "  typed in one try: $(grep -c ' type ' "$T/startup-many.log") tabs"
expect "many tabs: pi reopened on its session" grep -q "pi --session $PI2_ID (run)" "$T/startup-many.log"
expect "many tabs: the save still knows the pi session" has_line "^work $pi2_pos chat pi $PI2_ID "

echo "11. A pi resumed by hand in another tab is not opened twice by repair"
pis() { pgrep -f "$T/bin/pi" | wc -l | tr -d ' '; }
work_id=$(R ls --json | jq -r '(.sessions // .)[] | select(.label == "work") | .session_id')
before=$(pis)
# Keep the layout with the pi tab, then close that tab.
D mode=checkpoint name=pi-before-close >/dev/null
R do -s work -e "rex.call('session.close_window', { session_id = '$work_id', window_id = '$pi_window' }) return 'ok'" >/dev/null
sleep 2
expect "the closed tab's pi stopped" test "$(pis)" = "$((before - 1))"
# Resume the same pi session by hand in another tab, then repair.
type_in "$(new_tab "$T/my proj")" "'$T/bin/pi' --session $PI_ID"
sleep 2
D mode=repair from=pi-before-close >"$T/repair-double.log" 2>&1 || echo "  repair failed: exit $?"
sleep 3
expect "after repair: no second pi on that session" test "$(pis)" = "$before"

echo "12. Claude chats that share a folder each come back on their own conversation"
OLD_ID=aaaaaaaa-1111-4222-8333-444444444444
NEW_ID=bbbbbbbb-5555-4666-8777-888888888888
HOME="$H" R do "$here/test/e2e_more.lua" action=claudes "bin=$T/bin" "dir=$T/my proj" \
  "old=$OLD_ID" "new=$NEW_ID" >/dev/null
sleep 2
D mode=save
listing=$(show)
pair_id() { printf '%s\n' "$listing" | awk -v tab="$1" '$1 == "pair" && $2 == tab && $3 == "chat" { print $5 }'; }
A_ID=$(pair_id 1.1)
B_ID=$(pair_id 2.1)
expect "first new chat found by its pid file" has_line '^pair 1\.1 chat claude 00000000-0000-4000-8000-'
expect "second new chat in the same folder found too" has_line '^pair 2\.1 chat claude 00000000-0000-4000-8000-'
expect "the two chats are told apart" test "$A_ID" != "$B_ID"
expect "a chat that switched sessions is saved on the new one" has_line "^pair 3\.1 chat claude $NEW_ID "
stop_server
start_server
D mode=startup >"$T/startup-pair.log"
sleep 3
expect "restart: first chat reopened on its conversation" grep -q "claude --resume $A_ID (run)" "$T/startup-pair.log"
expect "restart: second chat reopened on its conversation" grep -q "claude --resume $B_ID (run)" "$T/startup-pair.log"
expect "restart: switched chat reopened on the new session" grep -q "claude --resume $NEW_ID (run)" "$T/startup-pair.log"
expect "one copy of each of them" test "$(running "$T/bin/claude --resume $A_ID")$(running "$T/bin/claude --resume $B_ID")$(running "$T/bin/claude --resume $NEW_ID")" = 111

echo
echo "$passed passed, $failed failed"
[ "$failed" = 0 ]
