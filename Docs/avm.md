# avm and agent-vm connect

`avm` runs an agent (Claude Code, Codex, opencode), a login shell or a command in an agent-vm box, on your terminal, with the current folder shared into the box at the same path. A folder shared read-write is snapshotted first, and afterwards avm reports what changed and lets you keep the changes or undo them. `avm` is a symlink to `agent-vm`: started under that name, agent-vm is `agent-vm connect`, and every form below works with either name (`avm dev1` is `agent-vm connect dev1`).

## Forms

```
avm [to] [<box>] [--box <box>] [--agent <id> | --shell | -- <command> ...] [--project <folder> | --no-project]
    [--read-only] [--no-snapshot] [--secret NAME ...] [--env NAME[=VALUE] ...] [--dry-run]
avm new <image> [--temp | --name <box>] [--allow RULE ...] [--cpus N] [--memory-gb N]
    [the same --agent, --shell, -- <command>, sharing and --dry-run options]
avm list [--json] [--project <folder>]
avm agents [--json]
```

- **`avm`** shows the list of boxes; **`avm <box>`** takes that box; **`avm new <image>`** makes a new box from the image (see [New boxes](#new-boxes)).
- **`to`** is the default subcommand, so `avm dev1` is `avm to dev1`. A box named `new`, `list`, `agents`, `to` or `help` is reached with `--box`: `avm --box list`.
- **What runs:** an agent from the catalog (`--agent <id>`; see [Agents](#agents)), the account's login shell (`--shell`), or the command after `--`; without any of them, avm shows the list of what it can run. An agent or a command runs through the login shell as well (`$SHELL -l -c`), so `~/.zprofile` applies as it does in `agent-vm box shell`, with its words passed unchanged.
- **`--project <folder>`** shares that folder instead of the current one; **`--no-project`** shares none, and the program starts in the box user's home folder.
- **`--read-only`** shares the folder read only: programs in the box cannot change it, so no snapshot is taken. **`--no-snapshot`** shares it read-write without a snapshot, so there is nothing to report or undo afterwards.
- **`--secret`** and **`--env`** are passed on to `agent-vm exec` (see the README's Boxes and exec section): `--secret NAME` takes a value from your Keychain, `--env NAME=VALUE` or `--env NAME` sets a variable.
- **`--dry-run`** prints the steps instead of taking them, and exits 0. It creates, starts, shares, stores and remembers nothing, asks nothing, and needs a terminal only to show a list.
- **`avm --version`** and **`avm help <subcommand>`** work as for agent-vm. `avm --help` lists the subcommands; the options are under `avm to --help`.

## What happens

1. **The folder:** `--project`, or the current folder. It must be a folder you can share: not the disk's root, your home folder or a folder containing it, anything inside `~/Library` or a hidden folder of your home, or the agent-vm store. When the current folder cannot be shared, avm on a terminal asks whether to connect without a folder. A folder named with `--project` that cannot be shared is an error.
2. **The box:** the one named, the one you choose in the list (below), or a new one from an image. Disposable boxes that have stopped are deleted first, as `box list` does (`box gc`).
3. **What to run:** the one named, or the one you choose in the second list: the agents, then the login shell. For a running box, avm first checks which agents it has, and one it lacks cannot be chosen.
4. **Questions, for an agent:** when none of its secrets is set, avm offers to set one; when the box does not allow its hosts, avm asks to add them. See [Agents](#agents).
5. **Create and start:** a new box is created first (`Creating box avm-dev-agents-3f2a91 from dev-agents (temporary: deleted when you leave)`). A stopped box is started (`Starting box dev1`, then `Box dev1 is running (14 s)`). A box that is stopping is waited for, then started again. avm makes itself the owner of a temporary box it created only: that box stops when avm exits, however it exits. Any other box keeps running after avm exits.
6. **Installed?** For an agent not checked in the list (named with `--agent`, or a box that was stopped), avm checks that its command is in the box. When it is not, avm says how to get it and stops (or, when you chose the agent in the list, shows the list again).
7. **Share:** the folder is shared into the box at the same path (`Sharing ~/src/app (read-write)`). A box shares one folder at a time. When programs in the box still use another folder, the box refuses: avm says so and, when you chose the box in the list, shows the list again.
8. **Snapshot:** a folder shared read-write is snapshotted (`Snapshot of ~/src/app taken (session 20260926-101500-7c1e)`), unless `--no-snapshot`; see [Snapshot and report](#snapshot-and-report).
9. **Remember:** the choices are recorded for the folder (below).
10. **The session:** `agent-vm exec --tty` runs as avm's child on your terminal. Your terminal is in raw mode, so keys such as Control-C go to the program, and the window size follows. Exit the agent or the shell (or let the command end) to come back.
11. **After:** the terminal's settings are put back, the cursor is shown and text attributes are reset, even if the session was killed. When it did not end normally, mouse reporting, bracketed paste and the kitty keyboard mode are turned off too.
12. **The report**, when a snapshot was taken: what changed, then keep or undo (below).
13. A kept box is left running: `Box dev1 keeps running; stop it with: agent-vm box stop dev1`. A temporary box is stopped and deleted right after the session, before the report (`Stopping box avm-dev-agents-3f2a91 (temporary)`, then `stopped and deleted (5 s)`), so nothing in it can change the folder during an undo.

avm stops and deletes only the temporary box it created in that run.

`--dry-run` prints the same steps:

```
$ avm dev1 --agent claude --dry-run
avm would:
  offer to set one of: CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY
  ask to allow pack:anthropic in box dev1
  start box dev1
  check that claude is installed in the box
  share /Users/me/src/app (read-write)
  snapshot /Users/me/src/app
  run: agent-vm exec --tty --box dev1 --project /Users/me/src/app --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 -- /bin/sh -c 'exec "$SHELL" -l -c '\''exec "$0" "$@"'\'' "$@"' sh claude
  report what changed in /Users/me/src/app, then keep or undo it
```

## New boxes

- **From the list:** its last section has `Temporary box from an image...` and `Kept box from an image...` (shown but not choosable when no image is ready). Either one shows the ready images (name, macOS version, what the recipe installed), preselecting the one remembered for the folder; an image whose `agent-vm-guest` cannot run terminal sessions is shown with `needs agent-vm image update-guest <image>`. A kept box then asks its name, suggesting the folder's name (`app`, or `app-2` when taken). Escape in the image list or at the name goes back to the box list.
- **From the command line:** `avm new <image>` (temporary, `--temp` says so) or `avm new <image> --name <box>` (kept). The image, the name and `--allow`'s rules are checked before anything is made.
- **Temporary boxes** are named `avm-<image>-<6 hex digits>`. avm is their owner: the box stops when avm exits, however it exits (even `kill -9`), and `agent-vm box gc` (or the next `box list` or avm) deletes it. After the session avm stops and deletes it itself.
- **Kept boxes** stay, with no owner, as `agent-vm box create` makes them.
- **Rules:** a new box's network is an allowlist of the agent's hosts (none for a shell or a command) plus `--allow`'s; nothing is asked. `--cpus N` and `--memory-gb N` set its size (default: the image's).
- **Two VMs at most:** macOS runs at most two macOS virtual machines at once, in any application, and starting a box needs one of them. When none is free, avm says which of your boxes run (and whether a program uses one, or it is another avm's temporary box) and how to stop one, deletes the temporary box it just made, and exits 75; when you chose in the list, it shows the list again instead, where a running box can be joined without a slot.
- If the start fails otherwise, a temporary box that never ran is deleted; a kept one stays (`avm <box>` tries again).

## Agents

`avm agents` lists what avm can run, and the state of each secret:

```
claude  Claude Code  (built-in)
    runs: claude    allows: pack:anthropic
    secrets (one of): CLAUDE_CODE_OAUTH_TOKEN set; ANTHROPIC_API_KEY missing
    Or log in inside a kept box: /login in Claude Code, then open the address it prints in this Mac's browser.
codex  Codex  (built-in)
    runs: codex    allows: pack:openai
    secrets (optional): OPENAI_API_KEY missing
opencode  opencode  (built-in)
    runs: opencode    allows: opencode.ai, models.opencode.ai
```

A secret's state is `set`, `missing`, or `asks`: stored by another build of agent-vm, so macOS asks on this Mac's screen before this one reads it.

| Agent | Needs in the box | Signs in with |
|---|---|---|
| Claude Code | `claude` (Recipes/agent-clis), hosts `pack:anthropic` | `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token` on this Mac, for a Claude subscription) or `ANTHROPIC_API_KEY`; or `/login` inside a kept box. avm sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, and with the token it marks Claude Code's first-run screens done (`"hasCompletedOnboarding": true` in the box user's `~/.claude.json`), since they ask for a login method even when the token is set. Your Claude login on this Mac is not visible in the box. |
| Codex | `codex`, hosts `pack:openai` | `OPENAI_API_KEY` (optional), or `codex login --device-auth` inside a kept box (a ChatGPT account works) |
| opencode | `opencode`, hosts `opencode.ai` and `models.opencode.ai` | nothing for OpenCode Zen's free models; other providers need their key (`--secret`) and their hosts (`agent-vm box network --allow`). avm sets `OPENCODE_DISABLE_AUTOUPDATE=1`. |

- **Secrets:** when an agent needs one of its secrets, none is set, and your own `--env` or `--secret` does not give one of its variables, avm shows a list: set one of them now, or go on without (and log in inside the box). The value is pasted or typed at `Paste or type CLAUDE_CODE_OAUTH_TOKEN (not shown), then Enter:`, is never shown, and goes to your Keychain only, as `agent-vm secret set` stores it; it is never in an argument, a file or the output. The session reads it from the Keychain itself (`exec --secret`). The first of the agent's secrets that is set is the one passed, unless your own `--secret` or `--env` sets its variable; then yours is. When that secret was stored by another build of agent-vm (every ad hoc build counts as another), macOS asks on this Mac's screen before the session reads it (choose Always Allow; over SSH nobody sees the question), so avm shows a list first: use the value in the Keychain (Enter), go on without it, or set a new value.
- **Hosts:** a box in allowlist mode that lacks the agent's rules (compared as written: a box allowing `api.anthropic.com` is still asked about `pack:anthropic`) is asked about them; yes adds them, as `agent-vm box network <box> --allow` does, and a running box takes them at once. No leaves the box as it is, and the agent's connections are refused (`agent-vm box netlog <box> --denied` lists them). A box whose network is `off` gets a warning; an `open` box needs nothing.
- **Installed?** avm looks for the agent's command through the account's login shell, the way the agent is started, so it sees the same `PATH`. An agent installed by its own installer into a folder the login shell does not add to `PATH` (such as `~/.local/bin` without a line in `~/.zprofile`) reads as not installed; run it by its path instead: `avm dev1 -- /path/to/agent`.
- **Your own agents:** a file `Agents/<id>.json` in the agent-vm store, the id lower-case letters, digits, `.`, `_` and `-`. One named like a built-in agent replaces it; others follow the built-in ones, by id. The same object as an entry of `agents.json` next to `agent-vm`, without `id`:

  ```json
  {
    "name": "Aider",
    "command": ["aider", "--no-auto-commits"],
    "allow": ["api.anthropic.com"],
    "secrets": [{"env": "ANTHROPIC_API_KEY", "label": "Anthropic API key"}],
    "secretsNeeded": "one",
    "env": {"AIDER_CHECK_UPDATE": "false"},
    "setup": "mkdir -p ~/.aider",
    "login": "How to log in inside the box instead, if there is a way.",
    "install": "pip install aider-chat",
    "note": "Anything else worth knowing."
  }
  ```

  - `name` and `command` are required; `command` is a list of words, the first a command name or an absolute path.
  - `allow`: hosts, `*.domain`, `host:port` or `pack:<name>`, as `agent-vm box create --allow` takes them (not `public`).
  - `secrets`: each with `env` (the variable) and `label`, and `secret` when its Keychain name differs from `env`. `secretsNeeded` is `one` (offer to set one when none is set) or `optional` (the default).
  - `setup`: a shell script run in the session right before the agent, in the box, with its variables and secret set; its failure does not stop the agent.
  - A file that cannot be used is listed by `avm agents` with the reason, and only that agent is missing; the others still work. Unknown keys are ignored.

## Snapshot and report

Before the session, avm snapshots a folder it shares read-write: an instant copy-on-write copy in the agent-vm store, recorded as a session (see the README's Sessions section; `agent-vm session list` shows them). The folder must be on the same volume as the store.

After the session, avm reports what changed since the snapshot:

```
Session 20260926-101500-7c1e: 13 added in ~/src/app; review first: 1 high, 12 medium
HIGH   A .git/hooks/pre-commit
         git hook: runs automatically on the next git operation
medium A hook1
         executable file added or changed: ...
... and 3 more flagged; r shows every change
k) keep the changes  r) show every change  u) undo them all [K/r/u]
```

- **Flagged** changes are the ones that run code later on this Mac (git hooks and configuration, agent configuration, build scripts, package manifests, executables, links leaving the folder). The first 10 are listed; `r` lists every change.
- **`k`** (or Enter, or Escape) keeps the changes. The session is ended and its snapshot kept, so the run can still be undone later: `Kept. Undo later with: agent-vm session undo <id>`.
- **`u`** undoes them all: what changed is put back from the snapshot, and what the agent left is kept in the session's folder, never deleted (`agent-vm session undo` without options). If something cannot be put back, avm lists it and says how to retry.
- **No changes:** `No changes in ~/src/app.`, and the snapshot is discarded. When something in the folder could not be examined, the report says so and the snapshot is kept, since a change may have been missed.
- **The box keeps running** with the folder shared. A program the agent started in the background can still change files, and avm cannot see it: stop it before you undo. What avm can see is other programs that run in the box through `agent-vm exec` (another terminal or an application); when there are any, it asks before undoing.
- **When no snapshot can be taken**, avm says why and asks:
  - another session is already active for the folder (another avm, or an application): its snapshot covers this run too, so going on is the default;
  - the folder is on another volume than the store, or the snapshot failed: going on means nothing can be undone, so stopping is the default.
- **A session that ends with a signal** (the terminal closed, `kill`): nothing is asked; the session is ended, kept for undo, and avm exits with 128 + the signal. A Control-C while the snapshot is taken, the report is made or the undo runs takes effect after that step, never halfway.
- **Kept snapshots take space** as the folder changes: `agent-vm session discard --older-than 7` frees those that ended more than a week ago.

## The list

```
AgentVM - project ~/src/app  type to filter, arrows, Enter; Esc quits
  Running
  > dev1                   dev-agents  running  project ~/src/app
    avm-dev-agents-3f2a91  dev-agents  running  project ~/src/lib, temporary, ends with process 4711
  Stopped
    try1                   dev         stopped
  New box
    Temporary box from an image...                 deleted when you leave
    Kept box from an image...
```

- **Rows:** every box that is not stopped comes first, with the folder it shares, how many programs run in it, and, for a temporary box, the process whose exit stops it. Then come the stopped boxes, then the two New box rows.
- **Shown but not choosable:** an unresponsive box, and a temporary box that is stopping for good.
- **Not shown:** a temporary (disposable) box that has stopped. It is either garbage or another program's box about to start.
- **Keys:**

  | Key | Does |
  |---|---|
  | Up, Down, Control-P, Control-N | move |
  | Page Up, Page Down | move by a page |
  | Home, End | first or last row |
  | typing | filters: every word must appear in the row, in any case |
  | Backspace, Control-U, Control-W | edit the filter |
  | Enter | choose |
  | Escape | clear the filter; with no filter, quit (status 130) |
  | Control-C | quit (status 130) |
  | Control-D | quit, when the filter is empty |

- **Preselected:** the box remembered for this folder (or `Temporary box from an image...` when a temporary box was), else the first running box that already shares it.
- **Drawing:** the list is drawn under the cursor, not on a separate screen, and erased when done, so the terminal's scrollback keeps what came before.
- **Escape is a lone ESC with nothing after it for 50 ms.** Over a slow connection an arrow key's bytes can arrive further apart than that; they are then taken as Escape, then text for the filter.
- **Without a terminal** (stdin or stdout not a terminal), avm prints the list and exits 64.
- `avm list` prints the same rows, then the ready images for a new box, and needs no terminal. `--json` has `boxes` and `images` (each image's `name`, `macOSVersion`, `description`, `offered` and `reason`).

## Remembered choices

The box (or, for a temporary box, its image) and what ran, chosen for each folder, are kept in `connect.json` in the agent-vm store (`~/Library/Application Support/agent-vm`, or `$AGENT_VM_HOME`). The file is private (mode 0600) and holds the 200 most recent folders. It records folder paths, box or image names, what ran (an agent's id or `shell`; a command after `--` leaves it as it was) and whether the folder was shared read only; nothing secret. It is only used to preselect rows. A missing or damaged file counts as empty and is replaced the next time. `--dry-run` and `--no-project` runs are not remembered.

`avm list --json` shows it:

```json
{
  "boxes" : [
    {"activeExecs" : 0, "image" : "dev-agents", "name" : "dev1", "offered" : true, "ownerPid" : null,
     "project" : "/Users/me/src/app", "projectReadOnly" : false, "reason" : null, "state" : "running", "temporary" : false}
  ],
  "project" : "/Users/me/src/app",
  "projectProblem" : null,
  "remembered" : {"at" : "2026-09-26T10:15:00Z", "box" : "dev1", "launch" : "shell", "readOnly" : false, "target" : "box"}
}
```

`offered` is false, with a `reason`, for the rows the list shows but does not let you choose. `projectProblem` says why the folder cannot be shared; `project` is then null.

## Exit status

| Status | When |
|---|---|
| the program's | a session ran: what `agent-vm exec --tty` returned (the program's, 128 + a signal, 125 when exec itself failed, 126 or 127 when the program could not start) |
| 0 | `list`, `agents`, `--dry-run` |
| 1 | avm could not connect: no such box, a temporary box that is not running, a folder that cannot be shared, a box that did not start, an agent not installed in the box, a refused share, no snapshot and you chose not to go on; `avm agents` when `agents.json` next to agent-vm cannot be used |
| 64 | options that do not go together, a bad `--secret` or `--env`, an unknown agent, or no terminal for a list or the session |
| 75 | no free VM slot for a new or stopped box (macOS runs at most two macOS virtual machines at once) |
| 130 | a list or a question was quit (Escape, Control-C) |
| 128 + n | signal n ended avm, for example 143 for SIGTERM, or 129 when the terminal closed during the session |

Errors go to stderr, prefixed with the name avm was started as (`avm:` or `agent-vm connect:`).

## Terminals

- `NO_COLOR` set to anything (see no-color.org) turns off bold, dim and reverse video; the selected row is still marked with `>`.
- With `TERM=dumb`, or no `TERM` (an Emacs shell buffer, some CI terminals), nothing moves the cursor. The list becomes a numbered menu read as a line:
  - a number chooses that row;
  - Enter chooses the preselected row;
  - other text filters the rows, which keep their numbers;
  - `q` or the end of input quits.
- **A window closed without ending its programs:** a terminal can close a window and keep its programs running (seen once with Ghostty 1.3.1, until the application quit). The session then goes on unseen and the box keeps its folder, so avm refuses another folder there and points to the exec log: `agent-vm box execlog <box> --json` gives the session's `hostPid`; `kill` on that process id ends it.
- **If avm is killed** with SIGKILL while its list is showing, nothing can put the terminal back; type `reset`. The same goes for a killed session (`kill -9` on avm): the program in the box keeps running, and its `agent-vm exec` is left without a terminal. `agent-vm box execlog <box> --json` gives that exec's process id (`hostPid`).

## Completion

zsh, bash and fish complete avm's box names (`avm to <Tab>`, `avm to --box <Tab>`), the images a new box can be made from (`avm new <Tab>`: ready images whose `agent-vm-guest` runs terminal sessions) and agent ids (`--agent`, after `to` or `new`), read from the store when you press Tab; a store that cannot be read completes nothing. The scripts do not know that `to` is the default, so `avm <Tab>` offers only the subcommands (`to`, `new`, `list`, `agents`, `help`). Install the script once:

```sh
mkdir -p ~/.zfunc && avm --generate-completion-script zsh > ~/.zfunc/_avm
# in ~/.zshrc, before compinit:  fpath=(~/.zfunc $fpath)
avm --generate-completion-script bash > ~/.avm-completion.bash   # bash: source it in ~/.bashrc
avm --generate-completion-script fish > ~/.config/fish/completions/avm.fish
```

`agent-vm --generate-completion-script zsh > ~/.zfunc/_agent-vm` does the same for `agent-vm connect` and every other command.

## For applications

`agent-vm connect <box> --shell --no-project` opens a login shell in a box on a terminal, for example to log in to an agent's account inside a kept box; an application can open Terminal on that command. An application that ships agent-vm can make an `avm` symlink next to its copy, as `Scripts/build.sh` does.
