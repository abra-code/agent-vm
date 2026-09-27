# avm and agent-vm connect

`avm` runs a login shell or a command in an agent-vm box, on your terminal, with the current folder shared into the box at the same path. `avm` is a symlink to `agent-vm`: started under that name, agent-vm is `agent-vm connect`, and every form below works with either name (`avm dev1` is `agent-vm connect dev1`).

## Forms

```
avm [to] [<box>] [--box <box>] [--shell | -- <command> ...] [--project <folder> | --no-project]
    [--secret NAME ...] [--env NAME[=VALUE] ...] [--dry-run]
avm list [--json] [--project <folder>]
```

- **`avm`** shows the list of boxes; **`avm <box>`** takes that box.
- **`to`** is the default subcommand, so `avm dev1` is `avm to dev1`. A box named `list`, `to` or `help` is reached with `--box`: `avm --box list`.
- **What runs:** the account's login shell (`--shell`, the default), or the command after `--`. A command runs through the login shell as well (`$SHELL -l -c`), so `~/.zprofile` applies as it does in `agent-vm box shell`, with its words passed unchanged.
- **`--project <folder>`** shares that folder instead of the current one; **`--no-project`** shares none, and the program starts in the box user's home folder.
- **`--secret`** and **`--env`** are passed on to `agent-vm exec` (see the README's Boxes and exec section): `--secret NAME` takes a value from your Keychain, `--env NAME=VALUE` or `--env NAME` sets a variable.
- **`--dry-run`** prints the steps instead of taking them, and exits 0. It creates, starts, shares and remembers nothing, and needs a terminal only to show the list.
- **`avm --version`** and **`avm help <subcommand>`** work as for agent-vm. `avm --help` lists the subcommands; the options are under `avm to --help`.

## What happens

1. **The folder:** `--project`, or the current folder. It must be a folder you can share: not the disk's root, your home folder or a folder containing it, anything inside `~/Library` or a hidden folder of your home, or the agent-vm store. When the current folder cannot be shared, avm on a terminal asks whether to connect without a folder. A folder named with `--project` that cannot be shared is an error.
2. **The box:** the one named, or the one you choose in the list (below). Disposable boxes that have stopped are deleted first, as `box list` does (`box gc`).
3. **Start:** a stopped box is started (`Starting box dev1`, then `Box dev1 is running (14 s)`). A box that is stopping is waited for, then started again. avm never makes itself the box's owner, so the box keeps running after avm exits.
4. **Share:** the folder is shared into the box at the same path (`Sharing ~/src/app (read-write)`). A box shares one folder at a time. When programs in the box still use another folder, the box refuses: avm says so and, when you chose the box in the list, shows the list again.
5. **Remember:** the choice is recorded for the folder (below).
6. **The session:** `agent-vm exec --tty` runs as avm's child on your terminal. Your terminal is in raw mode, so keys such as Control-C go to the program, and the window size follows. Exit the shell (or let the command end) to come back.
7. **After:** the terminal's settings are put back, the cursor is shown and text attributes are reset, even if the session was killed. When it did not end normally, mouse reporting, bracketed paste and the kitty keyboard mode are turned off too. A kept box is left running: `Box dev1 keeps running; stop it with: agent-vm box stop dev1`.

avm never stops or deletes a box.

`--dry-run` prints the same steps:

```
avm would:
  start box dev1
  share /Users/me/src/app (read-write)
  run: agent-vm exec --tty --box dev1 --project /Users/me/src/app -- /bin/sh -c 'exec "$SHELL" -l'
```

## The list

```
AgentVM - project ~/src/app  type to filter, arrows, Enter; Esc quits
  Running
  > dev1                   dev-agents  running  project ~/src/app
    avm-dev-agents-3f2a91  dev-agents  running  project ~/src/lib, temporary, ends with process 4711
  Stopped
    try1                   dev         stopped
```

- **Rows:** every box that is not stopped comes first, with the folder it shares, how many programs run in it, and, for a temporary box, the process whose exit stops it. Then come the stopped boxes.
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

- **Preselected:** the box remembered for this folder, else the first running box that already shares it.
- **Drawing:** the list is drawn under the cursor, not on a separate screen, and erased when done, so the terminal's scrollback keeps what came before.
- **Escape is a lone ESC with nothing after it for 50 ms.** Over a slow connection an arrow key's bytes can arrive further apart than that; they are then taken as Escape, then text for the filter.
- **Without a terminal** (stdin or stdout not a terminal), avm prints the list and exits 64.
- `avm list` prints the same rows, and needs no terminal.

## Remembered choices

The box chosen for each folder is kept in `connect.json` in the agent-vm store (`~/Library/Application Support/agent-vm`, or `$AGENT_VM_HOME`). The file is private (mode 0600) and holds the 200 most recent folders. It records folder paths, box names and whether a login shell ran; nothing secret. It is only used to preselect a row. A missing or damaged file counts as empty and is replaced the next time. `--dry-run` and `--no-project` runs are not remembered.

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
| 0 | `list`, `--dry-run` |
| 1 | avm could not connect: no such box, a temporary box that is not running, a folder that cannot be shared, a box that did not start, a refused share |
| 64 | options that do not go together, a bad `--secret` or `--env`, or no terminal for the list or the session |
| 75 | no free VM slot (macOS runs at most two macOS virtual machines at once) |
| 130 | the list was quit (Escape, Control-C) |
| 128 + n | signal n ended avm, for example 143 for SIGTERM, or 129 when the terminal closed during the session |

Errors go to stderr, prefixed with the name avm was started as (`avm:` or `agent-vm connect:`).

## Terminals

- `NO_COLOR` set to anything (see no-color.org) turns off bold, dim and reverse video; the selected row is still marked with `>`.
- With `TERM=dumb`, or no `TERM` (an Emacs shell buffer, some CI terminals), nothing moves the cursor. The list becomes a numbered menu read as a line:
  - a number chooses that row;
  - Enter chooses the preselected row;
  - other text filters the rows, which keep their numbers;
  - `q` or the end of input quits.
- **If avm is killed** with SIGKILL while its list is showing, nothing can put the terminal back; type `reset`. The same goes for a killed session (`kill -9` on avm): the program in the box keeps running, and its `agent-vm exec` is left without a terminal. `agent-vm box execlog <box> --json` gives that exec's process id (`hostPid`).

## For applications

`agent-vm connect <box> --shell --no-project` opens a login shell in a box on a terminal, for example to log in to an agent's account inside the box. An application that ships agent-vm can make an `avm` symlink next to its copy.
