# rex-durable

Keep the programs in your [Rex](https://www.superlogical.com/rex) tabs across server restarts and reboots.

Rex saves your sessions, tabs, and splits when its server stops, and restores them when it starts again. The programs that were running in them don't come back: every tab returns as an empty shell. rex-durable remembers what was running in each tab and puts it back.

| Running in the tab | After a restart |
| --- | --- |
| [fx](https://fx.sh) chat | Reopens on its conversation: `fx --resume <id>` |
| Claude Code chat | Reopens on its conversation: `claude --resume <id>` |
| Codex chat | Reopens on its conversation: `codex resume <id>` |
| pi chat | Reopens on its session: `pi --session <id>` |
| agy chat | Reopens on its conversation: `agy --conversation <id>` |
| Any other program | Typed at the prompt, not run. Press Enter if you want it. |
| Plain shell | Left alone |

Chats keep their options, such as `--model`, and come back in the same tab, split, and folder.

## Install

```sh
git clone https://github.com/fazxes/rex-durable
cd rex-durable
./install.sh --add-to-config
```

The installer:

1. Finds Rex's `rex` command. On macOS it uses the copy Rex keeps up to date in `~/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/`, so Rex updates don't break it.
2. Copies `durable.lua` to `~/Library/Application Support/rex-durable/` on macOS, or `~/.local/share/rex-durable/` on Linux.
3. Starts it as a login service: a launchd agent on macOS, a systemd user service on Linux.
4. Adds command palette actions (`rex_durable.lua` in your Rex config folder). `--add-to-config` also loads them from `init.lua` for you. Without it, the installer prints the one line to add.

Run `./install.sh` again to update. Use `--no-service` to install the files without the service, or `REX=/path/to/rex ./install.sh` to choose the `rex` command.

Requirements: Rex for Mac, or the Rex server on Linux, recent enough to have the Lua API's `rex.exec`, `rex.json`, `rex.every`, and `rex.on`. The installer checks this. You also need `lsof`, or `/proc` on Linux.

## Using it

There's nothing to do day to day. Every 30 seconds, and a few seconds after any change, rex-durable saves what runs in each tab. After a restart, it brings everything back within seconds and shows a notification such as "Reopened 12 chats."

To check on it, or to do something by hand:

```sh
S="$HOME/Library/Application Support/rex-durable/durable.lua"   # Linux: ~/.local/share/rex-durable/durable.lua

rex do "$S" mode=status                    # what is saved, and the last restore
rex do "$S" mode=save                      # save now
rex do "$S" mode=reopen dry_run=true       # show what a reopen would type
rex do "$S" mode=reopen                    # reopen programs in their tabs
rex do "$S" mode=repair dry_run=true       # show which closed tabs a repair would put back
rex do "$S" mode=repair                    # put back tabs that closed while Rex kept running
rex do "$S" mode=checkpoint name=before-update
rex do "$S" mode=reopen from=before-update # reopen from a pinned checkpoint
rex do "$S" mode=rebuild from=before-update yes=true  # recreate saved sessions
```

The command palette has the same actions: search for "durable".

Add `programs=false` to any mode to reopen chats only, and never type other programs' commands.

### If many tabs close at once

Sometimes every tab closes while Rex keeps running: a crash, or a command that kills the wrong processes. Rex then has nothing to bring back, because its server never restarted.

rex-durable notices when a save loses most of the tabs or chats of the save before it. It keeps that earlier save as a checkpoint named `auto-before-drop-<time>`, which later saves never replace, and shows a notification. To put the tabs back:

```sh
rex do "$S" mode=repair dry_run=true   # check what it will add
rex do "$S" mode=repair                # add it
```

Or run **Repair Missing Tabs** from the command palette. Repair adds each missing tab with its splits, in its old place in the session, and recreates missing sessions. It reopens chats in them, never a chat that is already open, and running it again adds nothing. Add `from=NAME` to repair from another checkpoint.

## How it works

`durable.lua` is a [Rex Lua script](https://www.superlogical.com/rex/docs/automate/lua-scripts). The service runs it with `rex do durable.lua --all`, which hears events from every session. It uses only Rex's public API:

- **Watching.** On a timer (`rex.every`) and after layout and terminal events (`rex.on`), it starts a short `rex do durable.lua mode=save`. Each save runs on its own connection, so reading every session never affects the watcher.
- **Saving.** For each tab, it records the block ID, the folder, and the program from the terminal's `process` method. It then works out which conversation each chat is on:
  - **fx** holds a lock file for its session (`~/.fx/sessions/v2/<id>/lock`). A chat that runs subagents holds their locks too. rex-durable always saves the main chat, because fx can't reopen a subagent on its own.
  - **Codex** keeps its rollout file open (`~/.codex/sessions/…/rollout-…-<id>.jsonl`), or the ID is on its command line (`codex resume <id>`).
  - **Claude Code** writes `~/.claude/sessions/<pid>.json` while it runs, with the session the chat is on now, also after `/clear` or `/resume`. rex-durable uses it when its pid and start time match the chat's process, so chats that share a folder each come back on their own conversation. Without that file, it uses the session on the command line (`--resume <id>`), or else the newest session file for that folder written since the chat started. If two such chats share a folder, it can't tell them apart, so they come back typed, not run.
  - **pi** names the session on its command line (`--session <id>`), or writes it to `~/.pi/agent/sessions/`. An idle pi writes nothing, so rex-durable remembers the command it typed on restore and binds it to the pi that starts in that tab. pi holds no lock, so while a pi whose session isn't known runs in Rex, a pi chat comes back typed, not run.
  - **agy** keeps `~/.gemini/antigravity-cli/presence/<id>.lock` open for the conversation it is on, also when idle and after `/resume`. agy hides its arguments, so options such as `--model` aren't kept.

  Saves go to `~/Library/Application Support/rex-durable/` on macOS, or `~/.local/state/rex-durable/` on Linux. It keeps the last save of each of the latest 10 servers, a copy every 10 minutes for the last 24 hours in `history/`, and the 10 newest automatic checkpoints.
- **Restoring.** When the watcher connects to a server instance it hasn't seen, it takes the last save from the previous server. Rex restores its own sessions with the same block IDs, so each program goes back into exactly the tab it came from, by block ID first and then by session name and position. If the server starts empty, for example after `rex server stop --discard`, rex-durable creates the saved sessions itself.

## Safety

- It only types into a tab that is sitting at an idle shell. A tab where something is running is left alone.
- It never opens a chat twice: not if the chat is already running in a Rex tab, and not if another process holds its session file, such as the same chat open in another terminal.
- It acts once per server start. Running it again on the same server only saves.
- Programs other than chats are typed, never run.
- Saves older than 30 days are never restored on their own.
- When many tabs close at once, the save from before is kept as a checkpoint, so it can't be lost.
- `dry_run=true` shows what a reopen or a repair would do, without doing it.

## Limits

- A chat that was in the middle of a reply reopens, but the reply in progress is gone, so re-ask its last step. Commands a chat had running in the background don't come back.
- Only chats in your own home folder's profile are reopened. An fx chat run with a different `HOME`, such as a test profile, comes back typed, not run.
- It works with the server it runs next to. For a remote Rex server, install rex-durable on that machine.
- A sudden power cut loses at most about the last 30 seconds of changes.

## Uninstall

```sh
./uninstall.sh          # stop the service and remove the files, keep your saves
./uninstall.sh --purge  # remove the saves too
```

Your Rex sessions and the programs in them are not touched. If you added `require("rex_durable")` to `init.lua`, remove that line too.

## Development

```sh
test/e2e.sh            # unit tests, then end-to-end tests on a throwaway Rex server
test/e2e.sh --unit     # unit tests only
lua5.1 test/platform.lua   # process and file helpers on Linux, without Rex
```

The end-to-end test needs Rex and a C compiler. It runs its own Rex server on its own socket, with fake fx, Claude Code, Codex, pi, and agy chats in a throwaway home folder. It never connects to your Rex server and never touches your real chats.

rex-durable is not made by or affiliated with Superlogical.

## License

[MIT](LICENSE)
