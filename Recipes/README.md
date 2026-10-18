# Example recipes

Recipes for `agent-vm image create --recipe`. The format is described in [../Docs/image-recipes.md](../Docs/image-recipes.md); `agent-vm recipe check <file>` says what a build would refuse in a recipe of your own, without building. To have an AI agent write one, tell it: "Run `agent-vm recipe guide` and follow it to write a recipe that installs ..."; the guide is [WRITING-RECIPES.md](WRITING-RECIPES.md).

| Recipe | Installs | Needs |
|---|---|---|
| [homebrew](homebrew/recipe.json) | Homebrew in `/opt/homebrew` (owned by the box user, so no `sudo`), and a `~/.zprofile` that puts it on the login shell's path. Nothing else: the recipes below install what they need with it | the Command Line Tools (default) |
| [node](node/recipe.json) | Node and npm, from Homebrew | Homebrew: the homebrew recipe before it |
| [python](python/recipe.json) | A current Python (3.15 at this writing) and uv, from Homebrew: `python3` and `pip3`, ahead of Apple's on the path; there is no `python` or `pip` without the 3. Homebrew moves `python3` to each new Python when it comes out, and the recipe's update step follows it. Apple's own Python 3.9 stays at `/usr/bin/python3`, where Xcode and its debugger expect it. Homebrew's Python refuses `pip install` outside a virtual environment, so work in one (`python3 -m venv .venv`, or `uv venv`); boxes on the allowlist network need `--allow pack:pypi` | Homebrew: the homebrew recipe before it |
| [agent-clis](agent-clis/recipe.json) | Claude Code, Codex and opencode, from npm (what `avm` runs) | Node: the homebrew and node recipes before it |
| [acp-agents](acp-agents/recipe.json) | The Agent Client Protocol (ACP) adapters that applications such as Cadabra drive: Claude Agent ACP (`claude-agent-acp`, built on the Claude Agent SDK, so it does not need the Claude Code package) and Codex ACP (`codex-acp`), plus opencode, which speaks ACP itself (`opencode acp`). Versions are pinned (`--set claude_acp=latest` and so on to change them), except what the adapters depend on in turn: Codex ACP takes any Codex CLI 0.156.x; the checks print the versions installed, and run each adapter's own program, which npm can skip without a word; `--set extras="@google/gemini-cli @github/copilot"` adds more packages | Node: the homebrew and node recipes before it |
| [agent-clis-native](agent-clis-native/recipe.json) | Agent CLIs that come as native programs from their makers' own installers, no Node: Grok Build from xAI (`grok`), Muse Code from Meta (`muse`, a 350 MB download) and Antigravity CLI from Google (`agy`), linked into `/usr/local/bin`. Each installer fetches the newest release (none can pin a version); Muse Code and Antigravity CLI check the download against a checksum from their own servers, Grok Build's installer checks none. The update steps install the newest of each (Grok only when xAI lists a newer version). The installers of Grok Build and Antigravity CLI add their folders to the path in the shell's startup files, and Grok Build also installs its program under a second name, `agent`. Each agent signs in with its own account or key in the box. Muse Code and Antigravity CLI update themselves when they run, on a box network that lets them | nothing |
| [agent-clis-china](agent-clis-china/recipe.json) | Agent CLIs of Chinese model makers, from their own installers, each with its own runtime, so no Node recipe: Kimi Code from Moonshot (`kimi`, a native program), Qwen Code from Alibaba (`qwen`, with its own Node) and MiniMax Code from MiniMax (`mcode`, from npm, with a Node 24 of its own when the image has no suitable one), linked into `/usr/local/bin`. Each installer checks its download against a checksum its maker publishes (MiniMax Code: its Node runtime; the package comes from npm); Qwen Code's archive is fetched from its GitHub release by the recipe, since its installer allows each download only 5 minutes. They install the newest release, and the update steps install a newer one when there is one. In a Linux image without a compiler, the recipe installs `build-essential`, which MiniMax Code needs when its prebuilt SQLite module cannot be downloaded. Startup files are left alone. Each agent signs in with its own account or key in the box | nothing |
| [xcode](xcode/recipe.json) | Xcode from a `.xip` you give (`--input xcode=...`), checked to be signed by Apple, selected with `xcode-select`, its license accepted and first-launch packages installed; debugging without an administrator prompt. The Command Line Tools stay too. | an Xcode `.xip` (see below) |
| [xcode-platforms](xcode-platforms/recipe.json) | Simulator runtimes (`--set platforms="iOS watchOS"`, default `iOS`; `iOS@26.5` for an older one) and Xcode components (`--set components=...`, default `MetalToolchain`), downloaded from Apple in the guest, no Apple ID needed | Xcode: an image built with xcode |

The recipes above are for macOS images, except the four agent recipes (agent-clis, acp-agents, agent-clis-native and agent-clis-china), which serve both systems. For Linux images (since 0.7.7; see Linux images below):

| Recipe | Installs | Needs |
|---|---|---|
| [linux-node](linux-node/recipe.json) | Node and npm from nodejs.org in `/usr/local`: the newest release of one major version (`--set node=24`, the default), checked against nodejs.org's checksum list. `npm install --global` is set to put packages into `~/.local` for the box user, so it needs no root | nothing |
| [linux-python](linux-python/recipe.json) | the distribution's Python (3.13 in Debian 13, 3.14 in Ubuntu 26.04) with `venv`, `pip3`, `pipx` and the headers (`python3`; there is no `python` without the 3); uv, from PyPI through pipx, in `~/.local/bin`. Debian's pip refuses `pip install` outside a virtual environment, so work in one (`python3 -m venv .venv`, or `uv venv`); boxes on the allowlist network need `--allow pack:pypi` | nothing |
| [linux-sudo](linux-sudo/recipe.json) | A rule that lets the box user run anything as root with `sudo`, without a password. Read "sudo in a Linux box" below before you use it | nothing |
| [linux-gnome](linux-gnome/recipe.json) | The GNOME desktop on Wayland with its terminal and file manager, the GDM login manager and the accessibility bus, without recommended packages (about 210 MB to download, about 950 MB on disk). The box user is logged in by itself at start, and the screen never locks, blanks or sleeps. GNOME needs polkitd: `--set polkit=deny` (the default) or `--set polkit=debian` says how it answers; read "polkitd in a GNOME or KDE image" below before you choose. With `"screen": true`, as linux-xfce. Debian images only | nothing |
| [linux-kde](linux-kde/recipe.json) | The KDE Plasma desktop on Wayland with its terminal, file manager and settings, the SDDM login manager, PipeWire and the accessibility bus, without recommended packages (about 340 MB to download, about 1.35 GB on disk). Logged in by itself at start, Plasma's own screen lock switched off, and the panel's launchers set to the settings, the file manager and the terminal (Discover, the software store, is left out). Plasma needs polkitd: the same `polkit` choice as linux-gnome. With `"screen": true`. Debian images only | nothing |
| [linux-xfce](linux-xfce/recipe.json) | The XFCE desktop with its terminal, the LightDM login manager and the X server, without recommended packages except the SVG image loader its wallpaper and icons need (94 MB to download, about 430 MB on disk). The box user is logged in by itself at start and the screen never blanks. The recipe says `"screen": true`, so the image and its boxes get a display, keyboard and pointer, and `agent-vm box view` shows the desktop. See "A desktop in a Linux box" below | nothing |
| [linux-xfce-extras](linux-xfce-extras/recipe.json) | The packages XFCE recommends that suit a box, without the ones they in turn recommend: Debian's themes and wallpapers (to pick in the desktop's settings; XFCE's own stays the default), the Tango icons, thumbnails in the file manager, notifications, the Desktop and Documents folders, the accessibility and session buses, the X tools (35 MB to download, about 130 MB on disk, about 50 MB more of the box's memory). Not the ones a box must not have or cannot use: polkitd (and its password dialog), a screen locker (the account has no password to unlock it), disk mounting, power and color management, the sound server, and the X drivers for real graphics cards | Desktop: the linux-xfce recipe before it |
| [agent-clis](agent-clis/recipe.json), [acp-agents](acp-agents/recipe.json) | As above: the same npm commands | Node: the linux-node recipe before it |
| [agent-clis-native](agent-clis-native/recipe.json), [agent-clis-china](agent-clis-china/recipe.json) | As above: the same installers, which pick the Linux build themselves | nothing |

Put the ones you want into one image, in an order that satisfies "Needs" (`--recipe` is repeatable; `--input` and `--set` go to the recipes that declare the name): A recipe that needs another says so in its first step: without Homebrew or Node in the image it fails at once, naming the recipe to put before it.

```sh
agent-vm image create dev --ipsw <restore image>                                        # macOS alone, about 6 minutes
agent-vm image create tools --from dev --recipe Recipes/homebrew/recipe.json --recipe Recipes/node/recipe.json --recipe Recipes/python/recipe.json --recipe Recipes/agent-clis/recipe.json --recipe Recipes/acp-agents/recipe.json
agent-vm box create work --image tools --allow pack:anthropic --allow pack:openai --allow pack:npm
```

One image with every tool is the simplest to keep. While you are still working on a recipe, layers are quicker to try: build each from the one before (`image create dev-node --from dev --recipe ...`, then `image create dev-agents --from dev-node --recipe ...`), and a change to a later layer rebuilds in about a minute. Each layer is its own image, though, and does not follow the one below it.

Keep the image current with `agent-vm image update tools`: besides macOS, it runs each recipe's update steps. homebrew upgrades Homebrew and everything installed with it, which covers the node and python recipes (they need no update steps of their own; their checks run again after the upgrade, as do those of every recipe without update steps); agent-clis installs the newest Claude Code, Codex and opencode; acp-agents installs the versions set (`image update tools --tools --set claude_acp=latest` moves a pin). The Xcode recipes have none: a newer Xcode is a new `.xip` and a new image.

The agents need their own logins or API keys inside the box: nothing from your Mac's Keychain reaches it.

## Linux images

```sh
agent-vm image create deb --linux debian-13                                              # Debian alone, about a minute
agent-vm image create deb-tools --from deb --recipe Recipes/linux-node/recipe.json --recipe Recipes/linux-python/recipe.json --recipe Recipes/agent-clis/recipe.json
agent-vm box create work --image deb-tools --allow pack:anthropic --allow pack:openai --allow pack:npm
```

- **About a minute for all three** on a clone of a ready image (measured: Node 2 s, Python 41 s, the three agents 13 s). `--linux debian-13 --recipe ...` builds the same thing in one image.
- **A recipe says which system it is for** (`"guest"` in the recipe; see [../Docs/image-recipes.md](../Docs/image-recipes.md)). One for the other system is refused before anything is built, so `Recipes/homebrew` cannot end up in Debian by mistake.
- **Why not Debian's own Node:** Debian 13 has Node 20, whose `fetch` cannot use a proxy, and the proxy is a box's only way out. Node 24 can (`exec` sets `NODE_USE_ENV_PROXY=1`).
- **Where the tools are:** `/usr/local/bin` (Node) and `~/.local/bin` (uv, and everything `npm install --global` installs, the agents among them). `~/.local/bin` is first on the path of every program run with `exec`.
- **`image update`** (since 0.7.8) installs Debian's package updates and runs the recipes' update steps: linux-node installs the newest release of its major version, linux-python the distribution's newest packages and the newest uv, agent-clis the newest agents. `agent-vm image update deb-tools --tools` does only the recipes' part.

### sudo in a Linux box

The box user of a Linux image cannot become root: it has no password, no sudo rule and no group but its own. Root is yours, from the Mac: `agent-vm exec --box <box> --user root -- apt-get install -y ripgrep` (on the allowlist network with `--allow pack:debian`, or `pack:ubuntu`), or better a recipe, so that the next box has the package too.

`Recipes/linux-sudo` changes that for an image: `agent-vm image create deb-sudo --from deb --recipe Recipes/linux-sudo/recipe.json`. In every box of such an image, any program, an agent included, runs anything as root.

- **What it widens.** Root in a box can load kernel modules and talk to the virtual machine's devices in ways a user cannot, so more of the code between the box and your Mac is within its reach; it can also change everything in the box, its proxy settings among them. The proxy itself, the allowlist and your Mac's files stay where they are, outside the box. A box is still a separate machine: this is a wider surface, not an open door.
- **The image says so.** `agent-vm image list` shows the recipe for the image built with it. An image built from that one shows its base's name there, and has the recipe in its record (`recipes` in `image info --json`, marked `inheritedFrom`).
- **No other bundled recipe needs it,** and a recipe should not add a rule of its own.
- **Seeing what an agent wanted root for,** in a box without the rule: each refused `sudo` is in the system's journal with its command. `agent-vm exec --box <box> --user root -- journalctl -t sudo` lists them (`user NOT in sudoers ; ... COMMAND=/usr/bin/apt-get install -y ripgrep`). The same packages asked for again and again belong in a recipe.

### A desktop in a Linux box

A Linux box has no screen unless its image installed a desktop (since agent-vm 0.8.0). Three recipes install one and ask for a screen; each logs the box user in by itself at start:

| Recipe | Desktop | To download | On disk | Memory the box uses, idle | Build from a ready image |
|---|---|---|---|---|---|
| `linux-xfce` (since 0.8.0) | XFCE 4.20 on X11, with LightDM | 94 MB | about 430 MB | about 0.9 GB | about 1.5 minutes |
| `linux-gnome` (since 0.8.3) | GNOME 48 on Wayland, with GDM | about 210 MB | about 950 MB | 1.1 to 1.4 GB | about 2.5 minutes |
| `linux-kde` (since 0.8.3) | KDE Plasma 6.3 on Wayland, with SDDM | about 340 MB | about 1.35 GB | 1.6 to 1.9 GB | about 4 minutes |

Measured on Debian 13 in boxes of 4 GB; a box without a desktop uses about 0.7 GB.

```sh
agent-vm image create deb-gnome --from deb --recipe Recipes/linux-gnome/recipe.json   # about 2.5 minutes
agent-vm box create gui --image deb-gnome
agent-vm box start gui
agent-vm box view gui --interactive
```

- **Which one:** XFCE is the lightest and the quickest to draw. GNOME and KDE Plasma are the two desktops most Linux users have (GNOME is the default of Debian, Ubuntu and Fedora), so they are the ones to see an application of yours in. Both run on Wayland, as on a current Linux computer; a program that knows only the older X11 runs through Xwayland, as there.
- **One desktop to an image:** the last desktop recipe of an image decides which login manager starts.
- **Memory:** 4 GB, the default, suits a box with a desktop and an agent; give 8 GB to a box in which an agent builds and runs the application you look at (`--memory-gb 8`). Since 0.8.3, agent-vm notes a box with a desktop under 4 GB as small.
- **Drawn in software:** a Linux guest gets no 3D acceleration, so the processors draw the desktop. XFCE is quick; GNOME's and Plasma's animations are slower than on a computer, and an application that uses OpenGL gets Mesa's software renderer.
- **Logged in by itself, and no lock:** the box user has no password, so the login manager logs it in at every start, and nothing locks, blanks or sleeps the screen. In GNOME locking is switched off. In Plasma its own Lock is switched off, but a program can still ask the system to lock the screen (`loginctl lock-session`), and no password unlocks it: `agent-vm exec --box gui --user root -- loginctl unlock-sessions` does. The window has no Type Password button.
- **Logging out** leaves the login screen, where no password works: stop and start the box to be logged in again.
- **polkitd, in GNOME and KDE:** see below.
- **A fuller XFCE:** add `Recipes/linux-xfce-extras` after it for Debian's themes and wallpapers to pick from, thumbnails, notifications and the user folders (the table above says what it leaves out and why). GNOME and KDE have their user folders already.
- **The packages it updates with the system:** `image update --system` brings Debian's updates to the desktop too. linux-xfce's own update step only installs the SVG image loader in an image built before the recipe had it; linux-gnome's and linux-kde's write polkitd's rules again, as the `polkit` parameter says.
- **Put it with the others** in one image (`--recipe Recipes/linux-node/recipe.json --recipe Recipes/agent-clis/recipe.json --recipe Recipes/linux-gnome/recipe.json`): an agent in such a box can open windows on the desktop when it is told where the desktop is ([../Docs/linux-boxes.md](../Docs/linux-boxes.md#a-desktop) has the commands).
- More in [../Docs/linux-boxes.md](../Docs/linux-boxes.md#a-desktop).

### polkitd in a GNOME or KDE image

polkitd is a service of the system's, running as root, that decides whether a program may do something the system keeps for administrators: power the system off, mount a disk, change the clock. Any program can ask it. The images agent-vm builds have none: their seal removes it. GNOME and KDE Plasma cannot be installed without it, so `linux-gnome` and `linux-kde` keep it, and their `polkit` parameter sets how it answers:

- **`deny`, the default:** polkitd refuses every request, except switching the screen between the system's consoles, which Plasma needs to start. Whatever on the desktop asks for privileges does nothing, and no password dialog appears: Power Off and Restart in the desktop's menu (use `agent-vm box stop`), mounting a disk, changing the date, an application's own request for administrator rights. What is left is polkitd itself, a program of root's that every program in the box can talk to: a flaw in it can give root (one did in 2021, CVE-2021-3560). The services that ask it (the disk service udisks2, the accounts service, the color service) get its no.
- **`debian`:** polkitd follows Debian's own rules, as on a Linux computer. The account logged in at the screen may, without a password, power the system off and restart it, mount disks and disk images through udisks2, and change its own account's details, among others. What Debian keeps for administrators asks for a password that no account has, so it cannot be done. Choose it to try an application that asks polkitd for something, and see what its users see.

**What `debian` means for an agent in the box.** What the desktop's user may do, every program of the box user may do, an agent included. A program started with `exec` is not part of the desktop's session, but one command (`systemd-run --user`) puts it there (measured). So, in a box of such an image, an agent can:

- power the box off or restart it, which ends its own work and your session in it (an image whose system powers itself off during `image view` is marked failed);
- make a disk image of its own, with a file system it designed, and have the system mount it (measured): the kernel then reads a file system the agent made, a way to root that flaws have opened before (in 2025, CVE-2025-6019 in udisks2 and its library). The mount allows no setuid programs.

With `deny`, none of this goes through polkitd, and an agent's requests get the same no as yours. Use `debian` for an image whose boxes you use to try applications yourself, and `deny` for one where an agent works unattended.

**Changing it later:** `agent-vm image update deb-gnome --tools --set polkit=debian` writes the new rules into the image with the recipe's update step, and the image records the value for the next update. Boxes made before keep their own until `agent-vm box recreate`.

**What agent-vm checks:** the seal keeps polkitd only beside the rules file these recipes write (`/etc/polkit-1/rules.d/00-agent-vm.rules`). Its check, at the first build, at `image view` and around `image update --system`, accepts polkitd only with one of the two: the refusing rule, unchanged and read before any other rules file; or Debian's rules, the file then naming them and adding nothing, and every other rules file one that a package installed. A rules file put there by hand, or by another recipe, fails it.

## Xcode

Apple offers Xcode's `.xip` only to someone signed in with an Apple ID (any Apple ID, no paid membership), so the image build cannot download it; you download it once and give it to the recipe. Everything after that downloads in the guest without an account: simulator runtimes and components come from Apple's public servers through `xcodebuild`.

1. Download Xcode from [developer.apple.com/download/all](https://developer.apple.com/download/all/) (search for Xcode), for example `~/Downloads/Xcode_27.xip`. Any Xcode that runs on the image's macOS works.
2. Build one image with Xcode and the simulators, or layers:

```sh
agent-vm image create dev-xcode-ios --from dev --disk-gb 128 --recipe Recipes/xcode/recipe.json --recipe Recipes/xcode-platforms/recipe.json --input xcode=~/Downloads/Xcode_27.xip
# or, as layers:
agent-vm image create dev-xcode --from dev --disk-gb 128 --recipe Recipes/xcode/recipe.json --input xcode=~/Downloads/Xcode_27.xip
agent-vm image create dev-xcode-ios --from dev-xcode --recipe Recipes/xcode-platforms/recipe.json                       # iOS and the Metal toolchain
agent-vm image create dev-xcode-all --from dev-xcode --recipe Recipes/xcode-platforms/recipe.json --set platforms="iOS watchOS tvOS visionOS"
```

- **Disk space**: Xcode takes about 4 GB and each simulator runtime about 8 GB, so give the Xcode image a bigger disk than the default 64 GB (`--disk-gb` with `--from`); the images built from it inherit that size. The disk file is sparse: unused room costs nothing.
- **What is checked**: `xip` itself does not check the archive's signature ("validation not attempted"), so the recipe runs `codesign --verify --strict` on the expanded app with the requirement `anchor apple and identifier "com.apple.dt.Xcode"`: only Apple's own Xcode passes. The image records the `.xip`'s name, size and SHA-256 (`image.json`, `recipe.inputs`).
- **The .xip does not stay in the image**: it is streamed into the guest for the build and deleted after it.
- **A newer Xcode, in place**: `agent-vm image update dev-xcode --tools --input xcode=~/Downloads/Xcode_27.1.xip` runs the recipe again with the new .xip (since agent-vm 0.7.57); boxes made before need `box recreate`.
- **Device SDKs come with Xcode**: building for iOS, watchOS, tvOS and visionOS devices works in `dev-xcode`; the platforms recipe adds the simulators to run and test on (an iPhone simulator boots in a box in about 40 s).
