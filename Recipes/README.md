# Example recipes

Recipes for `agent-vm image create --recipe`. The format is described in [../Docs/image-recipes.md](../Docs/image-recipes.md); `agent-vm recipe check <file>` says what a build would refuse in a recipe of your own, without building.

| Recipe | Installs | Needs |
|---|---|---|
| [homebrew](homebrew/recipe.json) | Homebrew in `/opt/homebrew` (owned by the box user, so no `sudo`), and a `~/.zprofile` that puts it on the login shell's path. Nothing else: the recipes below install what they need with it | the Command Line Tools (default) |
| [node](node/recipe.json) | Node and npm, from Homebrew | Homebrew: the homebrew recipe before it |
| [python](python/recipe.json) | A current Python (3.14 at this writing) and uv, from Homebrew: `python3`, `pip3`, and `python` and `pip` without the 3, all ahead of Apple's on the path. Apple's own Python 3.9 stays at `/usr/bin/python3`, where Xcode and its debugger expect it. Homebrew's Python refuses `pip install` outside a virtual environment, so work in one (`python3 -m venv .venv`, or `uv venv`); boxes on the allowlist network need `--allow pack:pypi` | Homebrew: the homebrew recipe before it |
| [agent-clis](agent-clis/recipe.json) | Claude Code, Codex and opencode, from npm (what `avm` runs) | Node: the homebrew and node recipes before it |
| [acp-agents](acp-agents/recipe.json) | The Agent Client Protocol (ACP) adapters that applications such as Cadabra drive: Claude Agent ACP (`claude-agent-acp`, built on the Claude Agent SDK, so it does not need the Claude Code package) and Codex ACP (`codex-acp`), plus opencode, which speaks ACP itself (`opencode acp`). Versions are pinned (`--set claude_acp=latest` and so on to change them), except what the adapters depend on in turn: Codex ACP takes any Codex CLI 0.156.x; the checks print the versions installed, and run each adapter's own program, which npm can skip without a word; `--set extras="@google/gemini-cli @github/copilot"` adds more packages | Node: the homebrew and node recipes before it |
| [xcode](xcode/recipe.json) | Xcode from a `.xip` you give (`--input xcode=...`), checked to be signed by Apple, selected with `xcode-select`, its license accepted and first-launch packages installed; debugging without an administrator prompt. The Command Line Tools stay too. | an Xcode `.xip` (see below) |
| [xcode-platforms](xcode-platforms/recipe.json) | Simulator runtimes (`--set platforms="iOS watchOS"`, default `iOS`; `iOS@26.5` for an older one) and Xcode components (`--set components=...`, default `MetalToolchain`), downloaded from Apple in the guest, no Apple ID needed | Xcode: an image built with xcode |

Put the ones you want into one image, in an order that satisfies "Needs" (`--recipe` is repeatable; `--input` and `--set` go to the recipes that declare the name): A recipe that needs another says so in its first step: without Homebrew or Node in the image it fails at once, naming the recipe to put before it.

```sh
agent-vm image create dev --ipsw <restore image>                                        # macOS alone, about 6 minutes
agent-vm image create tools --from dev --recipe Recipes/homebrew/recipe.json --recipe Recipes/node/recipe.json --recipe Recipes/python/recipe.json --recipe Recipes/agent-clis/recipe.json --recipe Recipes/acp-agents/recipe.json
agent-vm box create work --image tools --allow pack:anthropic --allow pack:openai --allow pack:npm
```

One image with every tool is the simplest to keep. While you are still working on a recipe, layers are quicker to try: build each from the one before (`image create dev-node --from dev --recipe ...`, then `image create dev-agents --from dev-node --recipe ...`), and a change to a later layer rebuilds in about a minute. Each layer is its own image, though, and does not follow the one below it.

Keep the image current with `agent-vm image update tools`: besides macOS, it runs each recipe's update steps. homebrew upgrades Homebrew and everything installed with it, which covers the node and python recipes (they need no update steps of their own; their checks run again after the upgrade, as do those of every recipe without update steps); agent-clis installs the newest Claude Code, Codex and opencode; acp-agents installs the versions set (`image update tools --tools --set claude_acp=latest` moves a pin). The Xcode recipes have none: a newer Xcode is a new `.xip` and a new image.

The agents need their own logins or API keys inside the box: nothing from your Mac's Keychain reaches it.

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
- **Device SDKs come with Xcode**: building for iOS, watchOS, tvOS and visionOS devices works in `dev-xcode`; the platforms recipe adds the simulators to run and test on (an iPhone simulator boots in a box in about 40 s).
