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

- **The system** is Debian 13 for ARM, built from Debian's own cloud image. Ubuntu 26.04 is built by the same code and withheld for now: [Debian or Ubuntu](#debian-or-ubuntu) says why and what differs.
- **No password, no ssh, and no screen unless you add a desktop.** A Linux box is reached through `exec`, `box shell` and `avm`, and nothing else listens in it. An image built with `Recipes/linux-desktop` has XFCE and a screen that `box view` shows ([A desktop](#a-desktop)).
- **The same protections as a macOS box:** only the folders you share, the allowlist network through the proxy on your Mac, a snapshot and a report around every `avm` session, disposable boxes.

## Sizes and times

Measured on a MacBook Air M5 with Debian 13; Ubuntu's numbers are under [Debian or Ubuntu](#debian-or-ubuntu).

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

## Debian or Ubuntu

**Ubuntu is withheld** (since 0.7.41): `image create --linux ubuntu` and `image rebuild --linux ubuntu` are refused, and `agent-vm version` does not list it. Ubuntu packages kernels with 4 KiB and with 64 KiB pages and none with 16 KiB; on macOS 27 a box on the first can lose kernel memory and stop, and the second does not start on a Mac ([The kernel's page size](#the-kernels-page-size)). It comes back when there is a kernel for it that is safe, or when macOS no longer has the defect. An Ubuntu image that exists is used and updated as before. To build one all the same, for a test, set `AGENT_VM_WITHHELD_LINUX=1`.

Both are built, sealed, run and updated by the same commands, and every test of Linux boxes passed on both. The table says what differs.

| | Debian 13 | Ubuntu 26.04 (since 0.7.11) |
|---|---|---|
| `--linux` | `debian-13`, or `debian` | `ubuntu-26.04`, or `ubuntu` |
| The download | 0.2 GB from `cloud.debian.org`, checked against its SHA-512 list | 0.9 GB from `cloud-images.ubuntu.com`, checked against its SHA-256 list |
| A new image, after the download | about 1 minute | about 2 minutes |
| The image on disk | about 2 GB | about 3.4 GB |
| Node, Python and three agents on top (the recipes) | about 1 minute | about 50 seconds |
| A box starts | about 3 seconds | about 5 seconds |
| An idle box's memory | about 0.5 GB of the Mac's | about 0.7 GB |
| Kernel | 6.12, with 16 KiB memory pages (since 0.7.30) | 7.0, with 4 KiB memory pages |
| Python (`Recipes/linux-python`) | 3.13 | 3.14 |
| `sudo`, and `ls`, `cp` and the like | sudo, GNU's tools | sudo-rs and uutils, written in Rust; scripts that parse their messages may see other words |
| apt's servers, and the pack for them | HTTPS; `pack:debian` | plain HTTP through the proxy; `pack:ubuntu` |
| Removed when the image is sealed | the ssh server, unattended-upgrades, polkitd | those, and snapd, the Ubuntu Pro client, the update and news notices, the firmware updater, the crash reporter, the release upgrader, needrestart, VMware's tools, multipath, iSCSI and udisks2 |
| A file changed on the Mac | read right at once | can be read with its old length for a second (see [The shared folder](#the-shared-folder)) |

## The kernel's page size

A kernel manages memory in pages of one size, fixed when the kernel is built: 4 KiB on most Linux systems for 64-bit ARM, 16 KiB on a Mac. Since 0.7.30 a Debian image boots Debian's own kernel with 16 KiB pages.

- **Why:** on macOS 27.0 a Linux guest whose kernel has 4 KiB pages can lose memory of the kernel's own when the Mac runs short of memory and pushes the guest's memory out: the lost memory reads as zeros, the kernel meets a fault, and the box stops (the README's "A kernel fault stops the box"). It is not agent-vm's defect, and other tools that use the Virtualization framework see it too. In our tests two Debian boxes of 8 GB that used their memory faulted in 2 of 8 runs with 4 KiB pages and in none of 16 with 16 KiB pages, while the Mac was made to push about 3 GB out; Ubuntu boxes faulted in 8 of 8.
- **Debian:** the image is built with `linux-image-arm64-16k` in place of the cloud image's kernel, the same kernel version with another page size. The kernel is the first thing a build installs: the image is then booted again and must come up with 16 KiB pages, and the rest of the setup (the account, the updates, the packages, the recipes) runs on that kernel, so that as little as can be runs on the one that can fault (since 0.7.32; before, the whole build ran on the cloud image's kernel). The package is Debian's full kernel; the cloud image's own, a smaller build for virtual machines, is removed.
- **An image built before 0.7.30** gets that kernel at its next `agent-vm image update <image> --system`, which says so, installs it first and boots the copy on it before the updates; then `agent-vm box recreate <box>` gives each box the new disk.
- **Ubuntu** packages no kernel with 16 KiB pages, and its images keep the 4 KiB kernel. That is why new Ubuntu images are withheld (since 0.7.41; [Debian or Ubuntu](#debian-or-ubuntu)).
- **Ubuntu's kernel with 64 KiB pages does not help** (since 0.7.40 `--page-size 64k` is refused; 0.7.37 to 0.7.39 offered it for Ubuntu): Apple's processors have pages of 4 KiB and 16 KiB only, and a kernel built for 64 KiB pages (`linux-image-generic-64k`) stops before it prints its first line. An update that tried it failed at the boot on the new kernel and left its image as it was.
- **agent-vm says where this applies** (since 0.7.31): `agent-vm doctor` has a line "linux kernels" that names the ready Linux images whose kernel has 4 KiB pages and the command that moves those that can be moved; `box start` and `avm` add a note when the box they start is such a one; `image create` says so before it builds one. A box keeps the kernel it was made with until `box recreate`, and its note goes by what its record says: a kernel you installed by hand is not seen.
- **The Mac's memory is looked at before an image job boots on a 4 KiB kernel** (since 0.7.33): the first boot of every `image create --linux` (until the 16 KiB kernel is installed; the whole build for Ubuntu), an `image create --from` of an image with such a kernel, and an `image update` of one. With less to spare than the guest's memory, or when macOS reports memory pressure, the job says so in a note and goes on; when macOS reports critical memory pressure, or pressure with less than 1 GB to spare, it is refused before anything is made or booted (the image's name stays free), since it would most likely fail part of the way. "To spare" is what macOS can give without compressing or swapping: free memory, cached files, and purgeable memory.
- **`--page-size 4k`** on `image create --linux debian`, or on `image update --system`, is the way back, for a program that does not run with 16 KiB pages. The programs the recipes install do (Node, Python, Claude Code, Codex, OpenCode). A program can fail when it carries its own memory allocator built for 4 KiB pages; it then says so at its start ("unsupported system page size"). `getconf PAGESIZE` in a box prints the size, and an image's record has it as `linux.pageSize`.

## What differs, command by command

| Command | With a Linux image or box |
|---|---|
| `image create --linux <release>` | Builds the image from the release's cloud image: `debian-13` (`debian` alone means the newest known of it; `ubuntu-26.04` is withheld). `--cloud-image` takes a file of your own. |
| `image create --from`, `--recipe`, `--input`, `--set`, `--cpus`, `--memory-gb`, `--disk-gb`, `--user` | As for macOS. A recipe must be for Linux (`"guest": "linux"` or `"any"`); see [image-recipes.md](image-recipes.md). |
| `image create --command-line-tools` | Means the compiler and make (`build-essential`). On by default. |
| `image update --system` | Installs the distribution's package updates. `--macos` is refused, with this name. |
| `image update --tools`, `--guest`, `--set`, `--if-older-than` | As for macOS. |
| `image rebuild --linux <release>`, or `--from` | Builds again from a fresh cloud image, or from a Linux image. |
| `image setup` | Refused: there is no Full Disk Access to grant. |
| `box view` | Refused, unless the image installed a desktop ([A desktop](#a-desktop)); then as for macOS, without Type Password (the account has none). |
| `image view` | Refused: it does not open a Linux image yet. Make a box of the image and use `box view`. |
| `image update-guest` | Refused: use `image update <image> --guest`. |
| `store secure-passwords`, the account password | Nothing to do: a Linux image has no password. |
| `box start`, `box stop`, `box status`, `box network`, `box netlog`, `box execlog`, `box sync-clock` | As for macOS. |
| `exec`, `box shell`, `avm` | As for macOS. `exec --prompts` is accepted and has no effect: there are no privacy prompts. |
| `exec --project`, `box shell --project` | As for macOS, with the notes under [The shared folder](#the-shared-folder). |
| `box send` | As for macOS (since 0.7.10): each item lands in the box user's `~/Downloads` under a free name, complete or not at all. See [Sending files](#sending-files). |
| `image list`, `box list`, `status`, `avm list` | Show the system where a macOS entry shows its macOS version: "Debian 13" or "Ubuntu 26.04" in `box list` and `avm list`, "Debian GNU/Linux 13 (trixie)" or "Ubuntu 26.04.1 LTS" in `image list` and `status`. With `--json`, every entry has `guest` (`macos` or `linux`) and `system`. |
| `doctor`, `status` | Count macOS guests against the limit of two; your running Linux boxes are counted apart (`linuxBoxes`), and so is a Linux image while a command builds or updates it (`linuxImages`). |

## The account, and root

- **The box user** (`agent` unless you chose another name) has the home `/home/agent`, `bash` as its shell, no password, and no group but its own.
- **It cannot become root by itself:** there is no sudo rule for it. Root is yours, from the Mac: `agent-vm exec --box work --user root -- apt-get install -y ripgrep` (on the allowlist network, with `--allow pack:debian`). Better still, a recipe, so that the next box has the package too.
- **`Recipes/linux-sudo`** gives an image passwordless sudo for the box user, if you accept that every program in a box of it can be root. [The Recipes page](../Recipes/README.md) says what that widens.
- **What an agent wanted root for** is in the box's journal: `agent-vm exec --box work --user root -- journalctl -t sudo` lists each refused `sudo` with its command (a `sudo -n`, which gives up before it asks for a password, leaves no line). That is Debian's sudo; Ubuntu's (sudo-rs) refuses with "I'm sorry agent. I'm afraid I can't do that" and writes no line for a refusal.

## Where programs are found

- **The path of a program run with `exec`** is `~/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin`.
- **`~/.local/bin` is the box user's own tool folder**, as `/opt/homebrew/bin` is in a macOS box: `pip`, `pipx`, `uv` and, with `Recipes/linux-node`, `npm install --global` put programs there without root.
- **A login shell** (`box shell`, and everything `avm` runs) reads Debian's own profile, which puts `/usr/local/bin:/usr/bin:/bin` on the path (no `sbin` folders, unlike `exec`) and adds `~/.local/bin` when the folder exists. Images made since 0.7.9 have the folder from the start (an image built from an older image gets it then); in an older image it is there once a recipe or a program made it.
- **The locale** is `C.UTF-8`.

## The network

- **On the allowlist and `off` networks the box has no network card.** `ls /sys/class/net` shows the loopback and nothing else: no address, no route, no name lookup. The only way out is the proxy at `127.0.0.1:3128`, which the guest daemon relays to your Mac.
- **Programs run with `exec`, `box shell` and `avm` get the proxy variables.** `apt` and `ssh` have their own settings, written at each start of the box. A program that reads none of these has no network at all, and most say so at once.
- **Node needs version 24 or later** for `fetch` through a proxy; `Recipes/linux-node` installs it. Debian's own Node 20 cannot.
- **`pack:debian`** allows Debian's package servers, for `apt-get` as root in a box; **`pack:ubuntu`** Ubuntu's.
- **On the `open` network** the box has a card on the Mac's NAT. Boxes started together can get the same address, so do not reach a box by its address.

## The shared folder

The folder is mounted at the path it has on your Mac, read-write or read-only, and `git` works in it at once. A Linux box shares up to 8 folders at once (since 0.7.48), so sessions on different projects can share one box; they are not kept apart from each other (below). These things differ from a folder on a Linux disk:

- **Every user in the box sees every file as its own**, and a file made in the box belongs to you on the Mac. Inside the box the share has no access control between users.
- **Several folders in one box are one trust zone.** Every program in the box runs as the same account and reaches every folder the box shares at that moment: a session's agent can read the other folders and change those shared for writing, and what it changes in another session's folder shows in that session's report and is taken back by its undo. avm and `exec` say so when the box already shares another folder. A box of its own keeps a project apart, at the cost of its memory and processors.
- **It is as case-insensitive as your Mac's disk:** `Foo` and `foo` are one file.
- **File watchers in the box do not see edits made on the Mac.** The content is current when it is read; the events are missing. A build tool that waits for changes needs polling (`CHOKIDAR_USEPOLLING=1`, `--poll`), or run it on the Mac.
- **Many small files are slow:** 6 to 15 times slower than on the box's own disk. Keep build products and `node_modules` on the box's disk when a project allows it.
- **In an Ubuntu box, a file's length can be a second old.** When a program in the box has just looked at a file and you change it on the Mac within about a second, the next read in the box can stop at the old length. A second later it is right. A Debian 13 box asks the Mac at every open and does not show this.

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
- **The image is never half updated:** an update works on a copy and takes the image's place only when everything passed. A new kernel is booted once before it is kept. An image whose kernel has 4 KiB pages where its system has one with 16 KiB gets that one ([The kernel's page size](#the-kernels-page-size)).

## A desktop

```sh
agent-vm image create deb-desk --from deb --recipe Recipes/linux-desktop/recipe.json   # about 90 seconds, 92 MB of packages
agent-vm box create gui --image deb-desk
agent-vm box start gui
agent-vm box view gui --interactive
```

A Linux box has no screen unless its image installed a desktop with a recipe that says `"screen": true` (since 0.8.0). `Recipes/linux-desktop` is that recipe: XFCE, its terminal, the LightDM login manager and the X server, about 420 MB on disk. The image and every box made from it then have a display, a keyboard and a pointer, and `box view` shows the desktop as it shows a macOS box's: view only unless `--interactive`, with Send for files. Boxes made before the desktop was added stay without one: `box recreate` gives it to them.

- **The box user is logged in by itself** at start: the account has no password, so there is no login window and no screen lock, and the screen never blanks. The window has no Type Password button, and `box view --type-password` is refused.
- **The same seal:** the packages are installed without the ones they only recommend, so no network manager, sound server, printing service or polkitd comes with them. With the desktop running nothing listens for the network (measured; the build's own check runs before the desktop has started).
- **Drawn by the processors:** Virtualization gives a Linux guest no 3D acceleration, so the desktop and everything on it are drawn in software. XFCE is light enough for that; a browser or a heavy application is slow.
- **Sizes and times:** the box starts in about 4 seconds with the desktop logged in, which takes about 200 MB of its memory; 4 GB suits a box with a desktop and an agent. The display is 1280 by 800, as a macOS box's.
- **No clipboard between your Mac and the box.** Send files with Send or `box send`; text goes through `exec` or the shared folder.
- **Programs started with `exec` do not appear on the screen** unless they are told the display: `agent-vm exec --box gui -- env DISPLAY=:0 XAUTHORITY=/home/agent/.Xauthority xfce4-terminal`.
- **Another desktop** is a recipe of your own with `"screen": true` that does the same; `Recipes/WRITING-RECIPES.md` says what it must do.

## What a Linux image is made of

- **The distribution's cloud image:** Debian's from `cloud.debian.org`, checked against Debian's SHA-512 list, or Ubuntu's from `cloud-images.ubuntu.com`, checked against Ubuntu's SHA-256 list, before anything reads it. The README's Images section says what is trusted.
- **Set up by agent-vm**, every step in the build log: the box user, the system's updates, `git`, `jq`, `unzip`, `zip`, the compiler and make, then your recipes.
- **Sealed:** no ssh server (removed, not only disabled), no background updates, the first-boot setup switched off, nothing listening for the network, no account with a usable password; in an Ubuntu image also no snapd and none of Ubuntu's background services. The build checks each of these and fails if one is not so.
- **Its files** in the store: `Disk.img`, `EFIVariableStore` (the boot firmware's variables), `MachineIdentifier`, and `console.log`, what the guest printed at its last boot (at most 2 MB, in two files). A box has the same, and when a box does not come up, the error ends with the console's last lines.

## Not there, and why

| | |
|---|---|
| Other distributions | Each has its own package tool and its own list of what to seal. Debian 13 and Ubuntu 26.04 are the ones that were measured. |
| `snap` and `add-apt-repository` in an Ubuntu box | snapd is a daemon of root's that any user can reach and that updates programs by itself; `add-apt-repository` needs polkitd. Add a source by its file in `/etc/apt/sources.list.d`, in a recipe. |
| Docker in the box | Wants its own settings for the proxy and its own measurements. |
| Port forwards from the Mac into a box | Not built for either system. |
| Memory given back to the Mac | A box keeps what it has touched until it stops. |
| A name per box | Every box's host name is `box`. |
| An easy way for an agent to install a system package | Today: a recipe, root from the Mac, or the sudo recipe. |

## For applications

- **Read `guest` and `system`** from `image list --json`, `box list --json`, `status --json` and `avm list --json`. `macOSVersion`, `macOSBuild` and `passwordStorage` are absent for Linux entries (in `avm list --json` an image's `macOSVersion` is there and null).
- **A Linux record has format 3**, which an agent-vm older than 0.7.2 refuses to read.
- **"N of 2 virtual machines"** is `runningVMs.count - runningVMs.linuxBoxes - runningVMs.linuxImages` of `runningVMs.limit`.
- **Offer the Linux systems agent-vm lists, not a list of your own** (since 0.7.13). `version --json` has `linuxReleases`: one entry per system `image create --linux` takes, with `id` (the word `--linux` takes: lower-case letters, digits, "." and "-", never starting with "-"), `name` ("Debian 13"), `distribution` and `version`, all strings. The order is agent-vm's, and the first entry of a distribution is its newest. It reads no store and asks nothing of the network.
- **Take a new image's sizes from `imageSizes`** in the same answer (since 0.7.13): under `macos` and under `linux`, `cpuCount`, `memoryBytes` and `diskBytes` (what `image create` uses when `--cpus`, `--memory-gb` and `--disk-gb` are not given), `minimumDiskBytes` (a smaller disk is refused) and `minimumDiskGrowthBytes` (with `--from` and `--disk-gb`: the least the disk may be larger than the base's by; the base's own size is taken as it is). Every byte count is a whole number of GB.
- **Check a new box name against `maxBoxNameLength`** in the same answer (since 0.7.53, for every box, not only Linux ones): the longest name a box of the store in use can start with, at most 63, and 0 when the store's folder leaves no room for any. A box's control socket, `Boxes/<name>/control.sock`, must fit the 103 bytes macOS allows a socket's path, so it depends on the store's path (`AGENT_VM_HOME` counts). `box create` and `box rename` refuse a longer name; `box start` and `box recreate` refuse a box that has one, with the `box rename` that fixes it.
- **Box and image names may have capital letters** (since 0.7.54): letters, digits, `.`, `_` and `-`, starting with a letter or a digit, at most 63 (a box less, see `maxBoxNameLength`). Every command matches a name with its case, and refuses a new name that another box (or image) has in other case: "box Work already exists, and work differs from it in case only". An app that checks a name before passing it, or compares names, must accept capitals and compare without case for "taken".
- **Recipes** say which system they are for: `guest` in `recipe check --json`.
- **Offer `box view` for a Linux box only when it has a screen** (since 0.8.0): `screen` is `true` in the box's record (`box list --json`, under `box`) and in its image's (`image list --json`, `image info --json`) when a recipe installed a desktop, and absent otherwise. Every macOS box and image has a screen, whatever `screen` says. Offer no Type Password for a Linux box.
- **Do not copy Mac programs into a Linux box.** A tool the box runs must be built for 64-bit ARM Linux.
