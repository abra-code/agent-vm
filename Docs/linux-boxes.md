# Linux boxes

A box can run Linux instead of macOS (since 0.7.4 for images, 0.7.5 for boxes). The commands are the same; what you get is a smaller, quicker box for work that does not need a Mac: an agent with a shell, git, Node, Python, a compiler.

This page says what a Linux box is, what differs from a macOS box, and what to know before you rely on one. The security side is in [threat-model.md](threat-model.md#linux-boxes); the tools and the proxy in [tools-and-the-proxy.md](tools-and-the-proxy.md).

## The short version

```sh
agent-vm image create deb --linux debian-13          # about a minute after a 0.2 GB download; no clicks
agent-vm image create deb-tools --from deb --recipe Recipes/linux-node/recipe.json --recipe Recipes/agent-clis/recipe.json
agent-vm box create work --image deb-tools --allow pack:anthropic --allow pack:npm
agent-vm box start work                              # ready in about 3 seconds
agent-vm exec --box work --project ~/Development/app -- npm test
avm new deb-tools                                    # or a temporary box with your folder, on this terminal
```

- **The system** is Debian 13 for ARM, built from Debian's own cloud image.
- **No screen, no password, no ssh.** A Linux box is reached through `exec`, `box shell` and `avm`, and nothing else listens in it.
- **The same protections as a macOS box:** one shared folder, the allowlist network through the proxy on your Mac, a snapshot and a report around every `avm` session, disposable boxes.

## Sizes and times

Measured on a MacBook Air M5 with Debian 13.

| | Linux | macOS |
|---|---|---|
| A new image | about 1 minute, after a 0.2 GB download | about 6 minutes, from a 27 GB restore image |
| The image on disk | about 2 GB (a 32 GB disk that takes what the system takes) | about 30 GB |
| An image with Node and three agents, from a ready image | about 20 seconds | about 3 minutes |
| A box starts | about 3 seconds | about 10 seconds |
| A box stops | about 1 second | a few seconds |
| An idle box's memory | about 0.5 GB of the Mac's, growing to its size as programs use it | its whole size, from about a minute after it starts |
| A system update | about 10 seconds for a few packages | about 15 minutes |
| How many at once | as many as the Mac's memory holds | two (a macOS limit) |

Defaults for a new Linux image: 4 CPUs, 4 GB of memory, a 32 GB disk, the user `agent`.

## What differs, command by command

| Command | With a Linux image or box |
|---|---|
| `image create --linux <release>` | Builds the image from the release's cloud image (`debian-13`; `debian` means the newest known). `--cloud-image` takes a file of your own. |
| `image create --from`, `--recipe`, `--input`, `--set`, `--cpus`, `--memory-gb`, `--disk-gb`, `--user` | As for macOS. A recipe must be for Linux (`"guest": "linux"` or `"any"`); see [image-recipes.md](image-recipes.md). |
| `image create --command-line-tools` | Means the compiler and make (`build-essential`). On by default. |
| `image update --system` | Installs Debian's package updates. `--macos` is refused, with this name. |
| `image update --tools`, `--guest`, `--set`, `--if-older-than` | As for macOS. |
| `image rebuild --linux <release>`, or `--from` | Builds again from a fresh cloud image, or from a Linux image. |
| `image setup`, `image view`, `box view` | Refused: there is no screen, and no Full Disk Access to grant. |
| `image update-guest` | Refused: use `image update <image> --guest`. |
| `store secure-passwords`, the account password | Nothing to do: a Linux image has no password. |
| `box start`, `box stop`, `box status`, `box network`, `box netlog`, `box execlog`, `box sync-clock` | As for macOS. |
| `exec`, `box shell`, `avm` | As for macOS. `exec --prompts` is accepted and has no effect: there are no privacy prompts. |
| `exec --project`, `box shell --project` | As for macOS, with the notes under [The shared folder](#the-shared-folder). |
| `box send` | As for macOS (since 0.7.10): each item lands in the box user's `~/Downloads` under a free name, complete or not at all. See [Sending files](#sending-files). |
| `image list`, `box list`, `status`, `avm list` | Show the system where a macOS entry shows its macOS version: "Debian 13" in `box list` and `avm list`, "Debian GNU/Linux 13 (trixie)" in `image list` and `status`. With `--json`, every entry has `guest` (`macos` or `linux`) and `system`. |
| `doctor`, `status` | Count macOS guests against the limit of two; your running Linux boxes are counted apart (`linuxBoxes`). |

## The account, and root

- **The box user** (`agent` unless you chose another name) has the home `/home/agent`, `bash` as its shell, no password, and no group but its own.
- **It cannot become root by itself:** there is no sudo rule for it. Root is yours, from the Mac: `agent-vm exec --box work --user root -- apt-get install -y ripgrep` (on the allowlist network, with `--allow pack:debian`). Better still, a recipe, so that the next box has the package too.
- **`Recipes/linux-sudo`** gives an image passwordless sudo for the box user, if you accept that every program in a box of it can be root. [The Recipes page](../Recipes/README.md) says what that widens.
- **What an agent wanted root for** is in the box's journal: `agent-vm exec --box work --user root -- journalctl -t sudo` lists each refused `sudo` with its command (a `sudo -n`, which gives up before it asks for a password, leaves no line).

## Where programs are found

- **The path of a program run with `exec`** is `~/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin`.
- **`~/.local/bin` is the box user's own tool folder**, as `/opt/homebrew/bin` is in a macOS box: `pip`, `pipx`, `uv` and, with `Recipes/linux-node`, `npm install --global` put programs there without root.
- **A login shell** (`box shell`, and everything `avm` runs) reads Debian's own profile, which puts `/usr/local/bin:/usr/bin:/bin` on the path (no `sbin` folders, unlike `exec`) and adds `~/.local/bin` when the folder exists. Images made since 0.7.9 have the folder from the start (an image built from an older image gets it then); in an older image it is there once a recipe or a program made it.
- **The locale** is `C.UTF-8`.

## The network

- **On the allowlist and `off` networks the box has no network card.** `ls /sys/class/net` shows the loopback and nothing else: no address, no route, no name lookup. The only way out is the proxy at `127.0.0.1:3128`, which the guest daemon relays to your Mac.
- **Programs run with `exec`, `box shell` and `avm` get the proxy variables.** `apt` and `ssh` have their own settings, written at each start of the box. A program that reads none of these has no network at all, and most say so at once.
- **Node needs version 24 or later** for `fetch` through a proxy; `Recipes/linux-node` installs it. Debian's own Node 20 cannot.
- **`pack:debian`** allows Debian's package servers, for `apt-get` as root in a box.
- **On the `open` network** the box has a card on the Mac's NAT. Boxes started together can get the same address, so do not reach a box by its address.

## The shared folder

The folder is mounted at the path it has on your Mac, read-write or read-only, and `git` works in it at once. Four things differ from a folder on a Linux disk:

- **Every user in the box sees every file as its own**, and a file made in the box belongs to you on the Mac. Inside the box the share has no access control between users.
- **It is as case-insensitive as your Mac's disk:** `Foo` and `foo` are one file.
- **File watchers in the box do not see edits made on the Mac.** The content is current when it is read; the events are missing. A build tool that waits for changes needs polling (`CHOKIDAR_USEPOLLING=1`, `--poll`), or run it on the Mac.
- **Many small files are slow:** 6 to 15 times slower than on the box's own disk. Keep build products and `node_modules` on the box's disk when a project allows it.

## Sending files

`agent-vm box send work ~/Downloads/data.tar.gz ~/Development/fixtures` copies files and folders from your Mac into the box user's `~/Downloads`. Use it for what is not in the shared folder: an installer, test data, a folder too large or too full of small files to work on through the share.

- **Nothing is replaced, and nothing arrives by halves.** A name in use gets a number (`data.tar 2.gz`); an item shows in `~/Downloads` only once it is whole; a send that is stopped (Control-C) leaves nothing of the item under way.
- **What arrives:** contents, permissions (an executable stays executable), symbolic links as links, empty folders, hidden files, and files with holes as files with holes.
- **What does not:** extended attributes, access control lists and file flags, which mean nothing in Linux, and the `._` files that would carry them. The quarantine mark of a download is one of these.
- **Everything belongs to the box user,** whoever owned it on the Mac.
- **Names** are sent as they are, spaces and quotes included. An accented letter is spelled as one character, the way Linux tools write it: your Mac's disk takes either spelling as the same name, a Linux disk does not.
- **Speed:** about 200 MB a second for large files; an unpacked SDK of 30,721 files and 6,714 links took 5 seconds.

## Keeping an image current

```sh
agent-vm image update deb-tools                      # Debian's packages, the recipes' tools, the guest daemon
agent-vm image update deb-tools --tools --if-older-than 24
agent-vm image rebuild deb --linux debian-13         # from Debian's newest cloud image
agent-vm box recreate work                           # each box, to get what the image now has
```

- **Nothing updates by itself.** The timers that update packages in the background are off in an image, so a box changes only by what runs in it.
- **The image is never half updated:** an update works on a copy and takes the image's place only when everything passed. A new kernel is booted once before it is kept.

## What a Linux image is made of

- **Debian's cloud image**, fetched from `cloud.debian.org` and checked against Debian's SHA-512 list before anything reads it. The README's Images section says what is trusted.
- **Set up by agent-vm**, every step in the build log: the box user, the system's updates, `git`, `jq`, `unzip`, `zip`, the compiler and make, then your recipes.
- **Sealed:** no ssh server (removed, not only disabled), no background updates, the first-boot setup switched off, nothing listening for the network, no account with a usable password. The build checks each of these and fails if one is not so.
- **Its files** in the store: `Disk.img`, `EFIVariableStore` (the boot firmware's variables), `MachineIdentifier`, and `console.log`, what the guest printed at its last boot (at most 2 MB, in two files). A box has the same, and when a box does not come up, the error ends with the console's last lines.

## Not there, and why

| | |
|---|---|
| A screen (`box view`) and a desktop | Several GB of packages and a second display path, for a box whose use is the terminal. |
| Other distributions | Each has its own package tool and its own list of what to seal. Debian 13 is the one that was measured. |
| Docker in the box | Wants its own settings for the proxy and its own measurements. |
| Port forwards from the Mac into a box | Not built for either system. |
| Memory given back to the Mac | A box keeps what it has touched until it stops. |
| A name per box | Every box's host name is `box`. |
| An easy way for an agent to install a system package | Today: a recipe, root from the Mac, or the sudo recipe. |

## For applications

- **Read `guest` and `system`** from `image list --json`, `box list --json`, `status --json` and `avm list --json`. `macOSVersion`, `macOSBuild` and `passwordStorage` are absent for Linux entries (in `avm list --json` an image's `macOSVersion` is there and null).
- **A Linux record has format 3**, which an agent-vm older than 0.7.2 refuses to read.
- **"N of 2 virtual machines"** is `runningVMs.count - runningVMs.linuxBoxes` of `runningVMs.limit`.
- **Recipes** say which system they are for: `guest` in `recipe check --json`.
- **Do not copy Mac programs into a Linux box.** A tool the box runs must be built for 64-bit ARM Linux.
