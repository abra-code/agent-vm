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
| [linux-desktop](linux-desktop/recipe.json) | The XFCE desktop with its terminal, the LightDM login manager and the X server, without recommended packages (92 MB to download, about 420 MB on disk). The box user is logged in by itself at start and the screen never blanks. The recipe says `"screen": true`, so the image and its boxes get a display, keyboard and pointer, and `agent-vm box view` shows the desktop. See "A desktop in a Linux box" below | nothing |
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

A Linux box has no screen unless its image installed a desktop (since agent-vm 0.8.0). `Recipes/linux-desktop` installs XFCE and asks for a screen:

```sh
agent-vm image create deb-desk --from deb --recipe Recipes/linux-desktop/recipe.json   # about 90 seconds
agent-vm box create gui --image deb-desk
agent-vm box start gui
agent-vm box view gui --interactive
```

- **Logged in by itself:** the box user has no password, so LightDM logs it in to XFCE at every start, and nothing locks or blanks the screen. The window has no Type Password button.
- **Drawn in software:** a Linux guest gets no 3D acceleration, so keep to light applications.
- **The packages it updates with the system:** `image update --system` brings Debian's updates to the desktop too; the recipe has no update steps of its own.
- **Put it with the others** in one image (`--recipe Recipes/linux-node/recipe.json --recipe Recipes/agent-clis/recipe.json --recipe Recipes/linux-desktop/recipe.json`): an agent in such a box can open windows on the desktop when it is told the display (`DISPLAY=:0`).
- More in [../Docs/linux-boxes.md](../Docs/linux-boxes.md#a-desktop).

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
