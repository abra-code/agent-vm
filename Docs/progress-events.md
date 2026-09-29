# Progress events

Long commands tell what they are doing as they go. For a person, that is lines of text on standard output. With `--json`, the same information goes to standard error as one JSON object per line, so a program can show the current step and a progress bar without reading prose. Standard output then holds only the command's result: the image record, the box's status.

Commands that report progress: `image create` (from a restore image or `--from` an image), `image update-guest`, `image setup`, `image fetch-ipsw`, `box start`, `box stop` and `box send`.

Run as a job (`agent-vm job start -- <command>`, see the README), a command's events are kept in the job's log: `job list --json` gives each job's last `progress` event and last notice, and `job log <id> --json` all of its events.

```sh
agent-vm image create dev-node --from dev --recipe Recipes/homebrew-node/recipe.json --json 2> events.jsonl > record.json
```

```json
{"event":"progress","image":"dev-node","message":"Cloning dev (macOS 26A428)","step":"clone"}
{"event":"progress","image":"dev-node","message":"Booting","step":"boot"}
{"event":"log","image":"dev-node","message":"agent-vm-guest 0.1.8 answers over vsock"}
{"event":"progress","image":"dev-node","message":"Recipe: Homebrew and Node (3 steps, 2 checks)","step":"recipe"}
{"count":3,"event":"progress","fraction":0,"image":"dev-node","index":1,"message":"[1/3] Homebrew","step":"recipe-step"}
{"event":"log","image":"dev-node","message":"==> Downloading and installing Homebrew...","output":true}
{"event":"progress","image":"dev-node","message":"Shutting down","step":"shutdown"}
```

## Fields

| Field | In | Meaning |
|---|---|---|
| `event` | every event | `progress`: a step began or moved on. `log`: a line of the log. `notice`: something the user may need to act on; the command goes on. |
| `message` | every event | The text a person would see, without its indentation. |
| `step` | `progress` | The step's name, from the tables below. Names are stable; the messages are not. |
| `fraction` | some `progress` | How far the step is, from 0 to 1: the macOS install, and recipe steps (steps done out of all). |
| `index`, `count` | `recipe-step` | This step's number, from 1, and how many there are. |
| `image` | image commands | The image the event is about. `image update-guest` with several images names each one. |
| `box` | box commands | The box the event is about. |
| `output` | some `log` | `true` for a line printed by a program in the guest (a recipe step's output), cut to 200 characters; its `message` is the line as printed, without the indentation and bar the text form puts before it. |

Keys are written in sorted order, and a key is left out when it has no value. A program should ignore keys it does not know: new ones may be added. A failed command ends with a plain-text message on standard error, which is not JSON, and a non-zero exit status: it begins with `Error: ` and may run over several lines (a failed recipe step adds the end of its output), so a program should treat everything from that line on as the error. A command refused because macOS already runs as many macOS virtual machines as it allows exits with status 75, and its message starts with `Error: no free VM slot`.

## Steps

`image create --ipsw` (a new image from a restore image):

| Step | What happens |
|---|---|
| `restore-image` | Reading the restore image. |
| `install` | Installing macOS, with `fraction` every 10%. About 3 minutes. |
| `first-boot` | The first boot creates the account, logs it in and turns on SSH. |
| `guest-daemon` | Installing `agent-vm-guest` over SSH. |
| `command-line-tools` | Installing Xcode's Command Line Tools (unless `--no-command-line-tools`). |
| `recipe`, `recipe-input`, `recipe-step` | With `--recipe`: the recipe begins, each input file is sent, each step runs. |
| `shutdown` | Shutting the guest down. |

`image create --from` (an image from an image):

| Step | What happens |
|---|---|
| `clone` | Cloning the base image. |
| `grow-disk` | With a larger `--disk-gb`: moving the recovery container. |
| `boot` | Booting the clone. |
| `command-line-tools`, `recipe`, `recipe-input`, `recipe-step` | As above. |
| `replace-guest-daemon` | Putting this agent-vm's `agent-vm-guest` into the image, when it differs. |
| `shutdown` | Shutting the guest down. |
| `check-guest-daemon` | Booting again to check the new `agent-vm-guest` (only when it was replaced), then `shutdown`. |

`image update-guest`: `boot`, then, when the daemon differs, `replace-guest-daemon`, `shutdown`, `check-guest-daemon` and `shutdown` again (otherwise just `shutdown`), for each image in turn. A failure in one image skips the rest, with a `notice` naming them.

`image setup`: `boot`, `full-disk-access` (the window is open: waiting for the grant, or, when agent-vm-guest has it already, for the window to close), `shutdown`.

`box start`: `starting`, then `running`, following the supervisor's state (`stopping` when the box this command started is stopped before it runs; the command then fails). A box that is already running reports no steps; one that another `box start` is starting reports its state from then on. A box that is stopping reports `stopping` (message `waiting for the box to stop`) until it has stopped, then `starting` and `running` as it is started again.

`box stop`: `shutdown`.

`box send`: `send` for each item, with `index` and `count` (which item of how many), and `fraction` from 0 at every whole percent (the archive's bytes over the size of the files, so it may reach 1 a little early). A `log` event follows each item sent (`Sent Setup.pkg to Downloads as Setup 2.pkg`). A `notice` says when the box waits on a permission prompt on its screen. SIGINT or SIGTERM ends the send with a `notice` and exit status 128 + the signal.

`image fetch-ipsw`: `resolve` (asking Apple for the latest restore image), `download` with `fraction` at every whole percent (its first event says whether the download starts or resumes), then `check` (Virtualization loads the file). An image already downloaded reports a `log` line and no `download`. SIGINT or SIGTERM ends the download with a `notice` (what was downloaded is kept for the next run) and exit status 128 + the signal.

## Canceling

SIGINT or SIGTERM during `image create` or `image update-guest` stops the command at the next safe point. When the guest was running, a `shutdown` step with the message `Canceled; shutting down` follows while it shuts down (a guest still booting is given up to 30 seconds for its daemon to answer, then as long to shut down, before it is stopped); then a `notice` says what became of the image (`Image dev-node is marked failed (canceled): canceled by SIGTERM; ...`, or `Image dev is unchanged: ...` for an update canceled before the daemon was replaced), and the command exits with 128 + the signal (143 for SIGTERM) without printing a result on standard output. The image record's `failure` is `canceled`.

## Notices

`notice` events are what the text form prints as `note: ...`: for example, a Full Disk Access grant lost to a new guest daemon (run `image setup` again), a desktop that could not be set up, Spotlight indexing that could not be turned off. The command goes on after a notice.
