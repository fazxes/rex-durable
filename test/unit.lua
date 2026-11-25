-- Unit tests for durable.lua. They run in Rex's own Lua and only read:
--
--   rex do test/unit.lua root="$PWD"     (from the repository root)
--
-- test/e2e.sh runs them for you.

REX_DURABLE_LIB = true
-- Test this repository's durable.lua. A `rex do` script can't always see its
-- own path, and the current folder may be another checkout, so the caller
-- passes the repository with root=.
local here = rex.args.root or (debug.getinfo(1, "S").source:match("^@(.*)/test/[^/]*$")) or "."
local M = dofile(here .. "/durable.lua")
local HOME = os.getenv("HOME")

local passed, failed = 0, 0

local function show(v)
  if type(v) == "table" then return rex.json.encode(v) end
  return tostring(v)
end

local function check(name, got, want)
  if show(got) == show(want) then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n  got:  " .. show(got) .. "\n  want: " .. show(want))
  end
end

-- No --sessions-v2 in this fx's help, like fx 0.0.16 and later.
local function new_fx(_, option) return option ~= "--sessions-v2" end
local function old_fx() return true end

-- A chat that runs subagents holds their locks too: save the main chat.
local function reader(path)
  if path:find("/SUB1/", 1, true) then return '{"kind":"session_created","id":"SUB1","role":"child","parent":"MAIN1"}' end
  if path:find("/SUB2/", 1, true) then return '{"kind":"session_created","id":"SUB2","role":"child","parent":"SUB1"}' end
  return '{"kind":"session_created","role":"root"}'
end
local v2 = HOME .. "/.fx/sessions/v2/"
check("main chat wins over its subagent",
  { M.fx_session({ v2 .. "SUB1/lock", v2 .. "MAIN1/lock" }, nil, reader) }, { "MAIN1", "v2" })
check("only subagent locks: follow the owners to the main chat",
  { M.fx_session({ v2 .. "SUB2/lock" }, nil, reader) }, { "MAIN1", "v2" })
check("no log: a main chat", { M.fx_session({ v2 .. "PLAIN/lock" }, nil, function() return nil end) }, { "PLAIN", "v2" })

-- Many tabs closed at once
local function snap_with(tabs, chats)
  local windows = {}
  for i = 1, tabs do
    windows[i] = { layout = { pane = { kind = i <= chats and "chat" or "shell", app = "fx", id = "C" .. i } } }
  end
  return { sessions = { { label = "s", windows = windows } } }
end
check("big drop: most tabs gone", M.big_drop(snap_with(10, 8), snap_with(2, 1)), true)
check("no drop: one tab closed", M.big_drop(snap_with(10, 8), snap_with(9, 7)), false)
check("no drop: only two tabs gone", M.big_drop(snap_with(3, 3), snap_with(1, 1)), false)
check("big drop: chats stopped, tabs stayed", M.big_drop(snap_with(10, 8), snap_with(10, 2)), true)

-- Repair: what is missing compared with a save
local saved_r = { sessions = {
  { session_id = "s1", label = "work", windows = {
    { layout = { pane = { block_id = "k1", kind = "chat", app = "fx", id = "A" } } },
    { layout = { pane = { block_id = "k2", kind = "shell", cwd = "/w" } } },
    { layout = { pane = { block_id = "k3", kind = "chat", app = "fx", id = "B" } } },
  } },
  { session_id = "gone", label = "old", windows = {
    { layout = { pane = { block_id = "k9", kind = "shell", cwd = "/w" } } },
  } },
} }
local live_r = { sessions = { { session_id = "s1", label = "work", windows = {
  { layout = { pane = { block_id = "k1", kind = "chat", app = "fx", id = "A" } } },
} } } }
local function actions(open)
  local out = {}
  for _, a in ipairs(M.plan_repair(saved_r, live_r, open)) do
    out[#out + 1] = a.kind == "session" and ("session " .. a.saved.label) or (a.label .. " tab " .. a.index)
  end
  return out
end
check("repair adds missing tabs and sessions", actions({}), { "work tab 2", "work tab 3", "session old" })
check("repair skips a tab whose chat is open elsewhere", actions({ ["fx:B"] = true }), { "work tab 2", "session old" })
-- A tab an earlier repair put back has new IDs; the record of it counts.
saved_r.sessions[1].windows[2].window_id = "window:saved-2"
table.insert(live_r.sessions[1].windows, { window_id = "window:new-2",
  layout = { pane = { block_id = "k2-new", kind = "shell", cwd = "/w" } } })
local again = {}
for _, a in ipairs(M.plan_repair(saved_r, live_r, {}, { ["window:saved-2"] = "window:new-2" })) do
  again[#again + 1] = a.kind == "session" and ("session " .. a.saved.label) or (a.label .. " tab " .. a.index)
end
check("repair doesn't add a tab it already put back", again, { "work tab 3", "session old" })

-- ps and lsof output
check("etime seconds", M.parse_etime("05:07"), 307)
check("etime hours", M.parse_etime("1:02:03"), 3723)
check("etime days", M.parse_etime("2-01:00:00"), 2 * 86400 + 3600)
local ps = M.parse_ps("  101 01:00 /usr/bin/fx --resume abc\n  202 2-00:00:01 zsh\n")
check("ps args", ps[101].args, "/usr/bin/fx --resume abc")
check("ps age", ps[202].age, 2 * 86400 + 1)
local files = M.parse_lsof("p101\nfcwd\nn/tmp\np202\nn/a b/c.jsonl\n")
check("lsof files", files, { [101] = { "/tmp" }, [202] = { "/a b/c.jsonl" } })

-- Which conversation a chat is on
check("fx v2 lock", { M.fx_session({ "/x", HOME .. "/.fx/sessions/v2/Xy7_q-Z/lock" }) }, { "Xy7_q-Z", "v2" })
check("fx v1 lock", { M.fx_session({ HOME .. "/.fx/sessions/AbC123/session.lock" }) }, { "AbC123", "v1" })
check("fx other profile", M.fx_session({ "/tmp/aig-fx-home/.fx/sessions/v2/X/lock" }), nil)
local rollout = HOME .. "/.codex/sessions/2026/11/13/rollout-2026-11-13T10-00-00-aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb.jsonl"
check("codex rollout", (M.session_file("codex", { rollout })), "aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb")
check("claude slug", M.claude_slug("/Users/me/my.proj"), "-Users-me-my-proj")
local claude_file = HOME .. "/.claude/projects/-Users-me/cccccccc-4444-4555-8666-dddddddddddd.jsonl"
check("claude file", (M.session_file("claude", { claude_file })), "cccccccc-4444-4555-8666-dddddddddddd")
local uuid = "cccccccc-4444-4555-8666-dddddddddddd"
check("claude --resume", M.argv_session("claude", { "claude", "--resume", uuid }), uuid)
check("claude --resume=", M.argv_session("claude", { "claude", "--resume=" .. uuid }), uuid)
check("codex resume", M.argv_session("codex", { "codex", "resume", uuid }), uuid)
check("codex --last", M.argv_session("codex", { "codex", "resume", "--last" }), nil)
local pi_id = "01a1e33b-a4d0-704d-bedf-cacda769dbf1"
local pi_file = HOME .. "/.pi/agent/sessions/--Users-me-proj--/2026-11-16T07-00-00-000Z_" .. pi_id .. ".jsonl"
check("pi file", (M.session_file("pi", { pi_file })), pi_id)
check("pi slug, : as - like pi", M.pi_slug("/Users/me/a:b"), "--Users-me-a-b--")
check("pi --session", M.argv_session("pi", { "pi", "--session", pi_id }), pi_id)
check("pi --session-id", M.argv_session("pi", { "pi", "--session-id", pi_id }), pi_id)
check("pi --session wants a UUID", M.argv_session("pi", { "pi", "--session", "latest" }), nil)
local omp_id = "01a1ea4c-b3d1-750d-abf3-977f0f58083d"
local omp_file = HOME .. "/.omp/agent/sessions/-projects-x/2026-11-17T16-17-37-745Z_" .. omp_id .. ".jsonl"
check("omp file", (M.session_file("omp", { omp_file })), omp_id)
check("omp file is not a pi file", (M.session_file("pi", { omp_file })), nil)
check("omp slug under home", M.omp_slug("/home/me/projects/x", "/home/me", "/tmp"), "-projects-x")
check("omp slug of home", M.omp_slug("/home/me", "/home/me", "/tmp"), "-")
check("omp slug under tmp", M.omp_slug("/tmp/scratch/omp-fleet", "/home/me", "/tmp"), "-tmp-scratch-omp-fleet")
check("omp slug elsewhere", M.omp_slug("/srv/a", "/home/me", "/tmp"), "--srv-a--")
check("omp --resume", M.argv_session("omp", { "omp", "--resume", omp_id }), omp_id)
check("omp --resume wants a UUID", M.argv_session("omp", { "omp", "--resume", "01a1ea4c" }), nil)

-- ~/.claude/sessions/<pid>.json
check("procStart is UTC", M.parse_utc("Sun Nov 22 21:40:38 2026"), 1795383638)
check("procStart with a padded day", M.parse_utc("Mon Nov  2 01:02:03 2026"), 1793581323)
check("procStart that isn't a date", M.parse_utc("yesterday"), nil)
check("procStart with a month that doesn't exist", M.parse_utc("Sun Foo 22 21:40:38 2026"), nil)
local started = 1795383638
local function pid_file(body)
  return function(path) if path == HOME .. "/.claude/sessions/63279.json" then return body end end
end
local function claude_file(fields) return pid_file('{"pid":63279,"sessionId":"' .. uuid .. '"' .. fields .. "}") end
local proc_start = ',"procStart":"Sun Nov 22 21:40:38 2026"'
check("claude pid file", M.claude_pid_session(63279, started + 1, nil, claude_file(proc_start)), uuid)
check("claude pid file, ps a little behind", M.claude_pid_session(63279, started - 2, nil, claude_file(proc_start)), uuid)
check("claude pid file of an older process with the same pid",
  M.claude_pid_session(63279, started + 600, nil, claude_file(proc_start)), nil)
check("claude pid file that names another pid",
  M.claude_pid_session(63280, started, nil, function() return '{"pid":63279,"sessionId":"' .. uuid .. '"' .. proc_start .. "}" end), nil)
check("claude pid file with only startedAt",
  M.claude_pid_session(63279, started, nil, claude_file(string.format(',"startedAt":%d', (started + 1) * 1000))), uuid)
check("claude pid file with a late startedAt",
  M.claude_pid_session(63279, started, nil, claude_file(string.format(',"startedAt":%d', (started + 900) * 1000))), nil)
check("claude pid file with no start time", M.claude_pid_session(63279, started, nil, claude_file("")), nil)
check("claude pid file that isn't JSON", M.claude_pid_session(63279, started, nil, pid_file("{not json")), nil)
check("claude pid file with a bad session ID", M.claude_pid_session(63279, started, nil,
  pid_file('{"pid":63279,"sessionId":"../../etc/passwd"' .. proc_start .. "}")), nil)
check("no claude pid file", M.claude_pid_session(63279, started, nil, function() return nil end), nil)
check("claude via node", M.is_app("claude", "node", { "node", "/usr/local/bin/claude" }), true)
check("codex binary", M.is_app("codex", "codex", { "/opt/homebrew/bin/codex" }), true)
check("not claude", M.is_app("claude", "node", { "node", "server.js" }), false)

-- Commands that reopen a chat
local function cmd(pane, accepts) return M.join(M.resume_argv(pane, accepts or new_fx)) end
check("fx keeps real options, drops relaunch internals",
  cmd({ app = "fx", id = "ID1", store = "v2",
        argv = { "fx", "resume", "OLD", "--upgrade-relaunch", "abc123", "--model", "m1", "--fast" } }),
  "fx --model m1 --fast --resume ID1")
check("fx drops --sessions-v2 when unsupported",
  cmd({ app = "fx", id = "ID2", store = "v2", argv = { "fx", "--sessions-v2", "--resume", "ID2" } }),
  "fx --resume ID2")
check("older fx keeps --sessions-v2",
  cmd({ app = "fx", id = "ID3", store = "v2", argv = { "fx" } }, old_fx),
  "fx --sessions-v2 --resume ID3")
check("fx missing dev build falls back to fx",
  cmd({ app = "fx", id = "ID4", argv = { "/nonexistent/zig-out/bin/fx" } }), "fx --resume ID4")
check("fx option=value",
  cmd({ app = "fx", id = "ID5", argv = { "fx", "--effort=high", "-r", "OLD" } }), "fx --effort=high --resume ID5")
check("claude keeps permission mode",
  cmd({ app = "claude", id = uuid,
        argv = { "node", "/usr/local/bin/claude", "--permission-mode", "plan", "--verbose" } }),
  "claude --permission-mode plan --resume " .. uuid)
check("codex resume with model",
  cmd({ app = "codex", id = uuid, argv = { "codex", "-m", "gpt-5", "--full-auto" } }),
  "codex resume -m gpt-5 " .. uuid)
check("pi keeps model, drops the rest",
  cmd({ app = "pi", id = pi_id, argv = { "pi", "--model", "m1", "--verbose", "--thinking", "high" } }),
  "pi --model m1 --thinking high --session " .. pi_id)
check("omp keeps model, drops the rest",
  cmd({ app = "omp", id = omp_id, argv = { "omp", "--model", "m1", "--yolo", "--thinking", "high" } }),
  "omp --model m1 --thinking high --resume " .. omp_id)
check("codex --yolo kept on resume",
  cmd({ app = "codex", id = uuid, argv = { "codex", "--yolo" } }),
  "codex resume --yolo " .. uuid)
check("quote spaces", M.join({ "cd", "/a b/it's" }), "cd '/a b/it'\\''s'")

-- What a tab runs (process IDs above any real pid_max, so /proc never answers)
local proc = {
  foreground = { pid = 90000003, name = "fx", cwd = "/w" },
  ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" }, { pid = 90000001, name = "login" } },
}
local info = {
  ps = { [90000003] = { age = 10, args = "fx --resume ID9" } },
  files = { [90000003] = { HOME .. "/.fx/sessions/v2/ID9/lock" } },
  now = os.time(),
}
local pane = M.describe(proc, info)
check("describe fx chat", { pane.kind, pane.app, pane.id, pane.cwd }, { "chat", "fx", "ID9", "/w" })
pane = M.describe({ foreground = { pid = 90000002, name = "-zsh", cwd = "/w" } }, { ps = {}, files = {}, now = 0 })
check("describe shell", { pane.kind, pane.cwd }, { "shell", "/w" })
pane = M.describe({ foreground = { pid = 90000005, name = "sleep", cwd = "/w" },
                    ancestors = { { pid = 90000002, name = "zsh", cwd = "/w" } } },
                  { ps = { [90000005] = { age = 1, args = "sleep 4242" } }, files = {}, now = 0 })
check("describe program", { pane.kind, pane.argv }, { "program", { "sleep", "4242" } })
pane = M.describe({ foreground = { pid = 90000007, name = "bash", cwd = "/w" },
                    ancestors = { { pid = 90000006, name = "claude", cwd = "/w" }, { pid = 90000002, name = "zsh" } } },
                  { ps = { [90000006] = { age = 1, args = "claude --resume " .. uuid }, [90000007] = { age = 1, args = "bash -c ls" } },
                    files = {}, now = 0 })
check("describe claude running a tool", { pane.kind, pane.app, pane.id }, { "chat", "claude", uuid })

-- Blank sessions
local function shell_session(cwd)
  return { windows = { { layout = { pane = { kind = "shell", cwd = cwd } } } } }
end
check("default session", M.is_default_session(shell_session(HOME)), true)
check("not default elsewhere", M.is_default_session(shell_session("/w")), false)
check("blank server", M.is_blank({ sessions = { shell_session(HOME) } }), true)

-- Matching saved tabs to the tabs Rex restored
local function leaf(p) return { pane = p } end
local saved = { sessions = {
  { session_id = "s1", label = "work", windows = {
    { layout = { split = { direction = "horizontal", ratio = 0.5,
      before = leaf({ block_id = "b1", kind = "chat", app = "fx", id = "A", store = "v2", argv = { "fx" }, cwd = "/w" }),
      after = leaf({ block_id = "b2", kind = "program", argv = { "sleep", "4242" }, cwd = "/w" }) } } },
    { layout = leaf({ block_id = "b3", kind = "chat", app = "fx", id = "B", store = "v2", argv = { "fx" }, cwd = "/w" }) },
    { layout = leaf({ block_id = "b4", kind = "chat", app = "fx", id = "C", store = "v2", argv = { "fx" }, cwd = "/w" }) },
    { layout = leaf({ block_id = "b5", kind = "chat", app = "fx", id = "D", store = "v2", argv = { "fx" }, cwd = "/other" }) },
  } },
  { session_id = "gone", label = "renamed-elsewhere", windows = {
    { layout = leaf({ block_id = "x1", kind = "chat", app = "fx", id = "E", store = "v2", argv = { "fx" }, cwd = "/w" }) },
  } },
} }
local live = { sessions = {
  { session_id = "s1", label = "work", windows = {
    { layout = { split = { direction = "horizontal", ratio = 0.5,
      before = leaf({ block_id = "b1", kind = "shell", cwd = "/w" }),
      after = leaf({ block_id = "b2", kind = "shell", cwd = "/w" }) } } },
    { layout = leaf({ block_id = "b3", kind = "program", argv = { "vim" }, cwd = "/w" }) },
    { layout = leaf({ block_id = "b4", kind = "shell", cwd = "/w" }) },
    { layout = leaf({ block_id = "b5", kind = "shell", cwd = "/w" }) },
  } },
  { session_id = "new-id", label = "renamed-elsewhere", windows = {
    { layout = leaf({ block_id = "y1", kind = "shell", cwd = "/w" }) },
  } },
} }
local opts = { dir_exists = function() return true end }
local function plan(open, extra)
  for k, v in pairs(extra or {}) do opts[k] = v end
  local writes, notes = M.plan_reopen(saved, live, open or {}, opts)
  local out = {}
  for _, w in ipairs(writes) do out[#out + 1] = w.block_id .. "=" .. w.data end
  return out, notes
end
-- fx --help is looked up for real; make it a version without --sessions-v2.
local real_exec = rex.exec
rex.exec = function(argv, o)
  if argv[2] == "--help" then return { ok = true, code = 0, stdout = "-r, --resume [last|<id>]", stderr = "" } end
  return real_exec(argv, o)
end
local writes, notes = plan({ ["fx:C"] = true })
check("reopen plan", writes, {
  "b1=fx --resume A\n",
  "b2=sleep 4242",
  "b5=cd /other && fx --resume D\n",
  "y1=fx --resume E\n",
})
check("reopen notes", notes, {
  "work tab 2: the tab is busy, left alone",
  "work tab 3: fx chat C is already open",
})
writes = plan({}, { programs = false })
check("programs=false only reopens chats", #writes, 4)
live.sessions[1].windows[1].layout.split.before.pane = { block_id = "b1", kind = "chat", app = "fx", id = "A" }
writes = plan({}, { programs = true })
check("a chat already in its tab is left alone", writes[1], "b2=sleep 4242")
live.sessions[1].windows[1].layout.split.after.pane = { block_id = "b2", kind = "program", argv = { "sleep", "4242" } }
writes, notes = plan({})
check("a program still running in its tab is left alone quietly",
  { writes[1], notes }, { "b4=fx --resume C\n", { "work tab 2: the tab is busy, left alone" } })
-- pi keeps no lock: next to a pi of unknown session, a pi chat is only typed.
local pi_saved = { sessions = { { session_id = "s1", label = "work", windows = {
  { layout = leaf({ block_id = "p1", kind = "chat", app = "pi", id = pi_id, argv = { "pi" }, cwd = "/w" }) },
  { layout = leaf({ block_id = "p2", kind = "chat", app = "fx", id = "F", store = "v2", argv = { "fx" }, cwd = "/w" }) },
} } } }
local pi_live = { sessions = { { session_id = "s1", label = "work", windows = {
  { layout = leaf({ block_id = "p1", kind = "shell", cwd = "/w" }) },
  { layout = leaf({ block_id = "p2", kind = "shell", cwd = "/w" }) },
} } } }
local pi_writes = {}
for _, w in ipairs((M.plan_reopen(pi_saved, pi_live, { unknown_pi = true }, opts))) do
  pi_writes[#pi_writes + 1] = w.block_id .. "=" .. w.data
end
check("pi typed, not run, next to a pi of unknown session", pi_writes,
  { "p1=pi --session " .. pi_id, "p2=fx --resume F\n" })
rex.exec = real_exec

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then rex.stop(1) end
