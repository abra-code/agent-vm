# Images and boxes: how they relate and how to manage them

This guide explains how agent-vm's images and boxes relate, what changes reach what, and the everyday procedures: first setup, adding tools, upgrading agent-vm, refreshing a box and freeing disk space. The README describes each command in detail; this page is about how to use them together.

## The model in one paragraph

An **image** is a template: macOS installed and set up once, plus the tools you chose, sealed and never run for work. A **box** is a working copy of an image: an instant clone you start, run programs in, stop, and eventually delete. A box is made from its image once, at `box create`, and from then on the two are independent: nothing you do to the image later reaches an existing box, and nothing done in a box reaches the image. To give a box something new, change the image (or make a new one), then make the box again.

```
restore image (.ipsw)
      |  image create --ipsw        (about 6 minutes)
      v
    image "dev" ----------------------------+
      |  image create --from --recipe       |  box create --image dev   (instant)
      |  (minutes)                          v
      v                                   box "work"  -- start / exec / stop, as often as you like
    image "dev-node"                        |
      |  box create                         |  box delete  (when done, or to refresh it)
      v                                     v
    box "web"                             gone; your project folder is untouched
```

## What lives where

| | Image | Box |
|---|---|---|
| What it is | A sealed template | A working copy of one image |
| Made by | `image create` (from a restore image, or `--from` another image with a recipe) | `box create --image <image>`: an APFS clone, instant, free until the box writes |
| Runs programs | Only while agent-vm builds or updates it | Yes: `exec`, `box shell`, `box view` |
| Changed by | `image update-guest`, `image setup` | Whatever runs in it; `box network` for its network rules |
| Its own settings | CPUs, memory, disk size, account name | CPUs and memory (default: the image's), network mode and rules |
| Folder (shown by `image list`, `box list`) | `~/Library/Application Support/agent-vm/Images/<name>/` | `~/Library/Application Support/agent-vm/Boxes/<name>/` |

Your **project folder** is neither: it stays on your Mac and is shared into a box while a program runs with `--project`. Deleting a box never touches it. Take a session snapshot (`agent-vm session start`) before an agent works on it, to review and undo its changes.

## What a box takes from its image, and when

At `box create`, the box gets a copy of everything the image has at that moment:

- the macOS installation, the account and its password, and the tools installed by recipes;
- the guest daemon (`agent-vm-guest`), the program in the box that `exec` and `box shell` talk to, with the features it has;
- the image's Full Disk Access grant for the guest daemon, if `image setup` was done;
- the image's desktop picture and settings (the box then sets its own wallpaper at its first start, when its daemon supports it).

After that, the box does not follow its image. In particular, these do **not** reach an existing box:

- `image update-guest` (a newer guest daemon and its features, such as the terminal or the wallpaper);
- `image setup` (Full Disk Access granted after the box was made);
- a new derived image, or a rebuilt one with the same name.

A box made before one of these keeps what it had. That is by design: a box is a disposable copy, and making it again takes seconds.

## What a box keeps between starts

`box stop` shuts the box down; `box start` boots the same disk again (about 20 seconds). Everything written in the box stays: files in the account's home, tools installed by hand, settings changed in System Settings. Its logs (`box execlog`, `box netlog`, `supervisor.log`) are kept on your Mac and last until the box is deleted.

Because the box keeps everything, it also keeps whatever an agent left behind. Treat a box as something to throw away: keep your work in the project folder, and put tools you want every time into an image recipe rather than installing them by hand in a box.

## Procedures

### First setup

```sh
Scripts/build.sh                                           # agent-vm and agent-vm-guest, signed
agent-vm image fetch-ipsw                                  # the latest macOS restore image (about 27 GB; resumes)
agent-vm image create dev --ipsw latest                    # about 6 minutes, no clicks
agent-vm image setup dev                                   # once: Full Disk Access for the guest daemon
agent-vm box create work --image dev --allow pack:github
agent-vm box start work
```

`image setup` opens the image in a window with System Settings on Full Disk Access; the README's Images section walks through it. Without it, a program in a box that opens the account's Desktop, Documents or Downloads waits on a permission prompt that nobody sees.

### Adding tools

Build a derived image with a recipe instead of installing tools into a box you want to keep:

```sh
agent-vm image create dev-node --from dev --recipe Recipes/homebrew-node/recipe.json   # about 2 minutes
agent-vm box create web --image dev-node
```

The recipe records what was installed, so the image can be built again the same way. Tools that need room, such as Xcode and its simulator runtimes (about 4 GB, then 8 GB per runtime), get it with `--disk-gb`: a derived image's disk can be larger than its base's, and images built from it inherit the size. A recipe can also ask for a file you downloaded yourself, such as Xcode's `.xip` (`--input`), and for choices (`--set`); [Recipes/](../Recipes/README.md) has an Xcode example. Recipes are described in [image-recipes.md](image-recipes.md), and examples are in [Recipes/](../Recipes/README.md). A derived image is a clone too: it does not change when its base image changes later.

### After upgrading agent-vm

A newer agent-vm can bring a newer guest daemon. `image list` names what each image's daemon lacks.

```sh
Scripts/build.sh
agent-vm image list                                        # "agent-vm-guest lacks ..." under each image
agent-vm image update-guest dev dev-node dev-agents        # one after another, about 45 seconds each
agent-vm image setup dev                                   # again for each image: the update drops Full Disk Access
```

Then make your boxes again (next procedure): existing boxes keep their old daemon. The update drops Full Disk Access because macOS ties the grant to the daemon's code signature, and the default signature (ad hoc) changes with every build; signing with a Developer ID (`Scripts/build.sh --identity ...`) should keep it.

### Refreshing a box

A box cannot be updated in place. To bring it up to date with its image, or to get rid of whatever accumulated in it, make it again:

```sh
agent-vm box stop work
agent-vm box delete work
agent-vm box create work --image dev --allow pack:github   # repeat the options you used before
agent-vm box start work
```

`box list` shows each box's network mode and `box network work` its rules, so you can note them before deleting.

### Freeing disk space

`image list` and `box list` show each one's folder and the space it takes, for example:

```
try1  stopped   image dev (macOS 26A428)  4 CPUs  8 GB  network allowlist
    /Users/you/Library/Application Support/agent-vm/Boxes/try1
    35.4 GB, of which 1.2 GB not shared with its image or other boxes (what box delete frees)
```

The first number counts everything the box's disk holds, most of it shared with its image, so adding these numbers up overstates the space used. The second is what only this one holds, and what deleting it gives back.

The second number changes as clones come and go: an image that a later image or box was built from holds little of its own, because the later one shares its data. `dev-xcode` with Xcode installed showed only 440 MB of its own, since `dev-xcode-ios` shares its Xcode. So `image list` gives a third line for an image built with `--from`: what its disk added over the image it was built from (`7.3 GB added over base "dev" image`), which stays the same whatever else is built, so each layer's growth can be followed. Starting the base image again (`image update-guest`, `image setup`) makes it grow a little: blocks the base rewrites were shared with the derived image, and now only the derived image holds the old ones. Besides what the recipe installed, it includes what the build itself wrote, such as a moved recovery container (about 1.5 GB when a disk grows) and what the guest changed while it ran; files the guest deleted are given back to the Mac and do not count.

- `box delete <name>` gives back what the box wrote, and also the image's blocks the image changed after the box was made (`image update-guest` changes some), since the box then holds the old ones alone.
- `image delete <name>` gives back what only that image holds. Space an image shares with its boxes and derived images stays in use until the last of them is deleted too, because they are clones of the same data. Deleting an image can therefore make a box's unshared space grow: what only the image and that box shared becomes the box's alone.
- Failed or interrupted image builds stay in `image list`; delete them.

## Questions and answers

**How do I update a box's guest daemon?**
You don't: update the image (`image update-guest`), then delete the box and create it again. A box has no update command on purpose: a replaced daemon would lose the box's Full Disk Access, and only an image can be set up again to grant it.

**How do I tell which guest daemon a box has?**
While it runs, `agent-vm box status <name>` shows it (`agent-vm-guest 0.1.6 (terminal, prompt-notices, wallpaper)`). Its `supervisor.log` also says so at every start: `Ready in 20 s: agent-vm-guest 0.1.2`. The log is in `~/Library/Application Support/agent-vm/Boxes/<name>/`. `image list` shows what an image lacks; a box made from it before its update lacks at least that much.

**I updated the image, but my box still shows the old wallpaper and the desktop widgets. Why?**
The box was made before the update and still runs the old daemon; its `supervisor.log` says "this agent-vm-guest predates wallpapers". Make the box again.

**Does stopping a box reset it?**
No. A box keeps its disk until it is deleted. Only deleting and creating it again starts from the image.

**Can I turn a box into an image?**
No. Put the steps into a recipe and build a derived image (`image create --from`): the image then records how it was made and can be built again.

**Does deleting an image break the boxes made from it?**
No, a box keeps working fully. Only `box create` reads the image: it clones the image's disk and auxiliary storage and copies its hardware model and account password into the box's folder, and gives the box its own machine identifier. From then on, starting, stopping, `exec`, `box shell` and `box view` use only the box's own files. Tested: a box made from an image that was then deleted started, ran programs, and kept what it wrote across a stop and a start.

What changes:

- `box list` still names the deleted image, as where the box came from.
- You can no longer make new boxes from that image, and there is nothing to refresh the box from: to make the box again, build the image again first (from the same recipe).
- The image's disk space is not all freed: whatever its boxes (or images built from it) still share stays in use until they are deleted too. Space the image shared with only one box becomes that box's own in `box list`.
- An image built from the deleted one no longer shows what it added over its base in `image list`, since there is no base to compare with.

**Does changing an image change the images derived from it?**
No. A derived image is a clone made at `image create --from`. To pass a change on, delete the derived image and build it again from the same recipe.

**Can I change a box's CPUs or memory, or rename a box or an image?**
Not after creation. For a box, make it again with `box create --cpus N --memory-gb N`. The network is the exception: `box network` changes the rules at once, and the mode while the box is stopped.

**How do I update macOS in an image?**
Not supported yet. Build a new image from a newer restore image (`image create --ipsw`), then build the derived images again from their recipes.

**How many boxes can I have?**
As many as your disk holds: a stopped box costs only the space it wrote. At most two can run at once, because macOS runs at most two macOS virtual machines at a time, counting image builds and updates and other apps' virtual machines (`agent-vm doctor` shows how many are running).

**Can I update an image while boxes made from it are running?**
Yes. Running boxes use their own disks, not the image's. The update does need one of the two virtual machine slots. While another agent-vm command uses an image (building or updating it, or building a derived image from it), `box create` from it is refused as busy; try again when that command ends.

**Where does my work go when I delete a box?**
Work in your project folder is on your Mac and stays. Anything written only inside the box (files in the box account's home, build products kept on the box's disk) is deleted with it.
