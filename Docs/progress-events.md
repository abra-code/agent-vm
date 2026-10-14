# Progress events

Long commands tell what they are doing as they go. For a person, that is lines of text on standard output. With `--json`, the same information goes to standard error as one JSON object per line, so a program can show the current step and a progress bar without reading prose. Standard output then holds only the command's result: the image record, the box's status.

Commands that report progress: `image create` (from a restore image or `--from` an image), `image update`, `image update-guest`, `image setup`, `image view`, `image fetch-ipsw`, `box start`, `box stop` and `box send`.

Run as a job (`agent-vm job start -- <command>`, see the README), a command's events are kept in the job's log: `job list --json` gives each job's last `progress` event and last notice, and `job log <id> --json` all of its events.

```sh
agent-vm image create dev-node --from dev --recipe Recipes/homebrew/recipe.json --json 2> events.jsonl > record.json
```

```json
{"event":"progress","image":"dev-node","message":"Cloning dev (macOS 26A428)","step":"clone"}
{"event":"progress","image":"dev-node","message":"Booting","step":"boot"}
{"event":"log","image":"dev-node","message":"agent-vm-guest 0.1.8 answers over vsock"}
{"event":"progress","image":"dev-node","message":"Recipe: Homebrew (3 steps, 1 checks)","step":"recipe"}
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
| `index`, `count` | `recipe-step`, `recipe-check`, `tools-update`, `tools-check` | This step's (check's, recipe's) number, from 1, and how many there are. |
| `expectedSeconds` | `boot` of `image update` | How long the last update of this image took that installed no macOS update, when one is on record: what this one will take unless it finds a macOS update. |
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
| `first-boot` | The first boot creates the account, logs it in and turns on SSH. A `notice` follows when this Mac has refused every connection to the guest for 30 seconds (Local Network access; since 0.6.13). |
| `guest-daemon` | Installing `agent-vm-guest` over SSH. |
| `command-line-tools` | Installing Xcode's Command Line Tools (unless `--no-command-line-tools`). |
| `recipe`, `recipe-input`, `recipe-step`, `recipe-check` | With `--recipe`: the recipe begins, each input file is sent, each step runs, each check runs. |
| `shutdown` | Shutting the guest down. |

`image create --linux` (a new Linux image from a distribution's cloud image; since 0.7.4):

| Step | What happens |
|---|---|
| `base-check` | Asking the distribution's host for the cloud image's checksum (with `--cloud-image`: reading your file). A `log` event follows when the downloaded file is checked, and one when it is the one the list names; a `notice` when the list could not be fetched and a checked copy is used. |
| `download` | Downloading the cloud image, with `fraction` at every whole percent. Left out when the downloaded file is still the one the list names. |
| `unpack` | Unpacking the disk into the image. |
| `first-boot` | The first boot: the system installs `agent-vm-guest` from the seed disk. |
| `guest-daemon` | The daemon answers. |
| `linux-setup` | Each setup step, with `index` and `count` over all of them (waiting for the first boot to finish, the account, the packages, git's settings; then, after `seal`, the sealing steps), and `fraction`. A step's output lines follow as `log` events with `output`. |
| `shutdown`, `check-boot` | Only when the image gets another kernel than the cloud image has (a Debian image, by default): after the setup steps that install it (the package lists, the kernel), shutting down and booting again on that kernel. The other `linux-setup` steps follow. |
| `recipe`, `recipe-step`, `recipe-check` | With `--recipe`, as above. |
| `seal` | Sealing begins; its steps follow as `linux-setup`. |
| `shutdown` | Shutting the guest down. |

`image create --from` (an image from an image):

| Step | What happens |
|---|---|
| `clone` | Cloning the base image. |
| `grow-disk` | With a larger `--disk-gb`: moving the recovery container (a Linux image: making the disk file longer). |
| `boot` | Booting the clone. |
| `linux-setup` | A Linux image: waiting for the network, and the compiler and make when asked for and missing, each with `index` and `count`. |
| `command-line-tools`, `recipe`, `recipe-input`, `recipe-step`, `recipe-check` | As above. |
| `replace-guest-daemon` | Putting this agent-vm's `agent-vm-guest` into the image, when it differs. |
| `shutdown` | Shutting the guest down. |
| `check-guest-daemon` | Booting again to check the new `agent-vm-guest` (only when it was replaced), then `shutdown`. |

`image update`, for each image in turn:

| Step | What happens |
|---|---|
| `boot` | Booting a copy of the image's disk. |
| `macos-check` | Asking Apple which macOS updates exist (unless `--tools` alone). |
| `macos-download` | An update is offered: `softwareupdate` downloads and prepares it, with `fraction` at every 10% (it stays in the nineties for minutes while it prepares); its output lines follow as `log` events with `output`. |
| `macos-restart` | The guest restarts and installs; the step ends when its daemon answers on the new build. |
| `command-line-tools` | A newer Command Line Tools package is installed. |
| `system-update` | A Linux image (since 0.7.8), in place of the three `macos-` steps: the distribution's package updates begin. Its steps follow as `linux-setup` with `index` and `count` (the network, the package lists, the updates, the cleanup), their output as `log` events with `output`. |
| `tools-update` | One recipe's update steps begin, with `index` and `count` (which recipe of how many that have update steps). |
| `recipe-step` | Each update step, as in `image create`. |
| `recipe-check` | Each of the recipe's checks, with `index` and `count`. |
| `tools-check` | The checks of a recipe that has no update steps begin (`index` and `count` among such recipes), after every recipe's update steps; `recipe-check` follows for each check. |
| `replace-guest-daemon` | Putting this agent-vm's `agent-vm-guest` into the image, when it differs (unless `--system` or `--tools` alone). |
| `shutdown` | Shutting the guest down. |
| `check-guest-daemon` | Booting again to check the new `agent-vm-guest` (only when it was replaced), then `shutdown` again. |
| `check-boot` | A Linux image whose update installed a new kernel, when the daemon was not replaced too: booting again to check that the system comes up on it, then `shutdown` again. Also, before `system-update`, when the update installs a kernel with another page size: `shutdown`, then booting again on that kernel. |
| `commit` | The updated disk takes the image's place. Left out when there was nothing to update. |

`image rebuild`: the steps of `image create` (with `--ipsw`, `--linux`, or `--from`), their `image` being the image's own name and not the name it is built under, then `replace`: the rebuilt image takes the old one's place.

`image update-guest`: `boot`, then, when the daemon differs, `replace-guest-daemon`, `shutdown`, `check-guest-daemon` and `shutdown` again (otherwise just `shutdown`), for each image in turn. A failure in one image skips the rest, with a `notice` naming them.

`image view` (since 0.6.14): `boot`, `window` (the window is open; the step lasts until it is closed), `shutdown`.

`image setup`: `boot`, `full-disk-access` (the window is open: waiting for the grant, or, when agent-vm-guest has it already, for the window to close), `shutdown`.

`box start`: `starting`, then `running`, following the supervisor's state (`stopping` when the box this command started is stopped before it runs; the command then fails). A box that is already running reports no steps; one that another `box start` is starting reports its state from then on. A box that is stopping reports `stopping` (message `waiting for the box to stop`) until it has stopped, then `starting` and `running` as it is started again. A `notice` comes first when the boxes that run, with this one, leave this Mac less than 6 GB of its memory.

`box stop`: `shutdown`.

`box send`: `send` for each item, with `index` and `count` (which item of how many), and `fraction` from 0 at every whole percent (the archive's bytes over the size of the files, so it may reach 1 a little early). A `log` event follows each item sent (`Sent Setup.pkg to Downloads as Setup 2.pkg`). A `notice` says when the box waits on a permission prompt on its screen. SIGINT or SIGTERM ends the send with a `notice` and exit status 128 + the signal.

`image fetch-ipsw`: `resolve` (asking Apple for the latest restore image), `download` with `fraction` at every whole percent (its first event says whether the download starts or resumes), then `check` (Virtualization loads the file). An image already downloaded reports a `log` line and no `download`. SIGINT or SIGTERM ends the download with a `notice` (what was downloaded is kept for the next run) and exit status 128 + the signal.

## Canceling

SIGINT or SIGTERM during `image create`, `image update` or `image update-guest` stops the command at the next safe point (an image being updated is left as it was). When the guest was running, a `shutdown` step with the message `Canceled; shutting down` follows while it shuts down (a guest still booting is given up to 30 seconds for its daemon to answer, then as long to shut down, before it is stopped); then a `notice` says what became of the image (`Image dev-node is marked failed (canceled): canceled by SIGTERM; ...`, or `Image dev is unchanged: ...` for an update canceled before the daemon was replaced), and the command exits with 128 + the signal (143 for SIGTERM) without printing a result on standard output. The image record's `failure` is `canceled`.

## Notices

`notice` events are what the text form prints as `note: ...`: for example, a Full Disk Access grant lost to a new guest daemon (run `image setup` again), a desktop that could not be set up, Spotlight indexing that could not be turned off. The command goes on after a notice.
