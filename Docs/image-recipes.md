# Image recipes, version 1

A recipe is a JSON file that says what to install in an image besides macOS: Homebrew, Node, an agent's command-line tool, your dotfiles. There are two ways to run one:

- `agent-vm image create <name> --ipsw <file> --recipe <recipe.json>` runs it while it builds a new image, after macOS is set up and the Command Line Tools are installed, and before the image is sealed.
- `agent-vm image create <name> --from <image> --recipe <recipe.json>` runs it on a clone of a ready image. This takes minutes and leaves the base image untouched.

Give `--recipe` more than once to put several recipes into one image: they run in the order given, each with its own steps and checks, so a later one can use what an earlier one installed (see Several recipes).

Examples are in [../Recipes/](../Recipes/README.md).

```json
{
  "version": 1,
  "description": "Homebrew and Node",
  "commandLineTools": true,
  "steps": [
    { "name": "Homebrew folder", "user": "root", "run": "mkdir -p /opt/homebrew && chown \"$AGENT_VM_BOX_USER\":admin /opt/homebrew" },
    { "name": "Homebrew", "run": "curl -fsSL https://github.com/Homebrew/brew/tarball/HEAD | tar xz --strip-components 1 -C /opt/homebrew" },
    { "name": "Node", "run": "/opt/homebrew/bin/brew install node", "timeoutSeconds": 3600 },
    { "name": "git settings", "copy": "files/gitconfig", "to": "~/.gitconfig", "mode": "0644" }
  ],
  "checks": ["node --version", "git config --get user.name"]
}
```

## Keys

| Key | Required | Meaning |
|---|---|---|
| `version` | yes | The recipe format version: `1`. |
| `description` | no | Shown while building and recorded in `image.json`. |
| `commandLineTools` | no | `false` skips Xcode's Command Line Tools (default `true` for a new image). With `--from`, `true` installs them only if the base image lacks them. `--[no-]command-line-tools` on the command line overrides it. |
| `steps` | no | What to run, in order. |
| `update` | no | Steps that bring what the recipe installed up to date, run by `agent-vm image update` in an image built with the recipe: see Update steps. Never run while an image is built. |
| `checks` | no | Commands run as the box user after the steps, and again after the update steps; each must exit 0 within 300 seconds, and its first line of output is shown. |
| `inputs` | no | Files the builder gives with `--input NAME=PATH`: see Inputs and parameters. |
| `parameters` | no | Values the builder may set with `--set NAME=VALUE`: see Inputs and parameters. |

Each step does one of two things:

| Key | Meaning |
|---|---|
| `run` | A shell command, run with `/bin/bash -c`. Its output appears in the build log line by line. |
| `copy` + `to` | A file from the recipe's folder (a path relative to `recipe.json`, which must stay inside that folder and name the file by its place there: not out of the folder and back in, and not through a linked folder and `..`) written to `to` in the image. `to` is absolute or starts with `~/` (the step user's home); missing folders are created. At most 256 MB: download bigger files in a `run` step. |

Every step can also have:

| Key | Default | Meaning |
|---|---|---|
| `name` | `step N` | Shown while building and in errors. |
| `user` | the box user | `"root"` runs the step as root. |
| `env` | none | Extra environment variables, `{"NAME": "value"}`. |
| `mode` | `"0644"` | Copy steps only: the file's permissions, in octal. |
| `timeoutSeconds` | 1800 | How long the step may go **without any output** before the build gives up (1 to 86400). |

A key that is not in these tables is an error, so a misspelling cannot silently skip a step.

## Inputs and parameters

Some things cannot be written into a recipe: a file too big for a `copy` step that cannot be downloaded without an account (Xcode's `.xip` needs an Apple ID), or a choice that differs from one image to the next (which simulator runtimes to install). A recipe declares these, and whoever builds the image gives them:

```json
{
  "version": 1,
  "inputs": {
    "xcode": { "description": "an Xcode .xip from https://developer.apple.com/download/all/" }
  },
  "parameters": {
    "platforms": { "description": "simulator runtimes, separated by spaces", "default": "iOS" }
  },
  "steps": [
    { "name": "Expand Xcode", "user": "root", "run": "mkdir -p /private/var/tmp/xcode && cd /private/var/tmp/xcode && xip --expand \"$AGENT_VM_INPUT_XCODE\" && mv /private/var/tmp/xcode/*.app /Applications/" },
    { "name": "Runtimes", "run": "for p in $AGENT_VM_PARAM_PLATFORMS; do xcodebuild -downloadPlatform \"$p\" || exit 1; done" }
  ]
}
```

```sh
agent-vm image create dev-xcode --from dev --recipe recipe.json --input xcode=~/Downloads/Xcode_27.xip --set platforms="iOS watchOS"
```

- **Names**: lower-case letters, digits and `_`, starting with a letter, at most 32; an input and a parameter cannot share one. Each declaration is an object with an optional `description`, shown when a value is missing; a parameter can also have a `default`.
- **Inputs** are all required. Before the first step, agent-vm streams each file into the guest as `/private/var/tmp/agent-vm-inputs/<name>/<file name>` (readable by every account), and deletes that folder after the checks, so the image keeps only what the steps made of them. A file that changes while it is sent fails the build.
- **Parameters** without a `default` must be set. Values are text, any text but a NUL character; an empty value is a value.
- **Steps and checks see them** as environment variables: `AGENT_VM_INPUT_<NAME>` (the file's path in the guest) and `AGENT_VM_PARAM_<NAME>` (the value), the name in capitals. A step's own `env` cannot change them.
- **Mistakes are refused before anything is built**: a missing input or required parameter, a name the recipe does not declare, an input that is not a readable file.

## Update steps

```json
{
  "version": 1,
  "description": "Agent command-line tools",
  "steps":  [{ "run": "npm install --global @anthropic-ai/claude-code" }],
  "update": [{ "run": "npm install --global @anthropic-ai/claude-code@latest" }],
  "checks": ["claude --version"]
}
```

`agent-vm image update <image>` runs the `update` steps of every recipe the image keeps, in the order the recipes were applied, and each recipe's `checks` after its update steps. An update step is written like any other step (`run` or `copy` + `to`, with `name`, `user`, `env`, `mode`, `timeoutSeconds`), and can rely on the same things.

- **Write them to be run again and again**: an update step runs at every `image update`, on an image where it may have run before (`brew upgrade`, `npm install ...@latest`, `softwareupdate` is not needed: `image update` does macOS itself).
- **Parameters** have the values the image recorded when it was built; `image update --set name=value` changes one and records it, so the next update uses it too. A recipe that pins a version as a parameter moves the pin that way.
- **Inputs are not there**: an input was streamed in for the build and deleted after it, so update steps and checks see no `AGENT_VM_INPUT_` variables. What needs the file again (a newer Xcode `.xip`) is a rebuild: `agent-vm image rebuild <image> --input xcode=<file>`.
- **Nothing is kept from a failed update**: a failing update step or check leaves the image as it was before `image update`.
- **The recipe is the one the image keeps**, as it was when the image was built (`Recipes/` in the image's folder): changing the recipe file later does not change what `image update` runs.
- **The digest** covers the files update steps copy, after the files the steps copy.

## Several recipes

```sh
agent-vm image create dev --ipsw latest \
    --recipe Recipes/homebrew/recipe.json --recipe Recipes/node/recipe.json --recipe Recipes/agent-clis/recipe.json \
    --recipe Recipes/xcode/recipe.json --input xcode=~/Downloads/Xcode_27.xip --disk-gb 128
```

- **Order**: as given. Each recipe's checks run right after its steps, so a failure names the recipe that caused it.
- **Inputs and parameters**: `--input` and `--set` go to every recipe that declares the name. Two recipes that declare the same parameter get the same value when it is set, and each its own default when it is not. A name that no recipe declares is refused before anything is built.
- **The same recipe twice** is refused.
- **The Command Line Tools** are installed when any of the recipes asks for them, and skipped only when the recipes that say anything all say `false` (`--[no-]command-line-tools` overrides both).
- **A recipe's name** is its folder's name when the file is called `recipe.json` (`Recipes/xcode/recipe.json` is `xcode`), else the file's name without its extension.

## What steps can rely on

- **The internet**: the image is built on NAT, so downloads work, but a box's allowlist does not apply to the build.
- **The step user's environment**:
  - `HOME`, `USER`, `SHELL` and `LANG=en_US.UTF-8`;
  - `PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`, so tools installed in those folders are found by later steps and checks;
  - `AGENT_VM_BOX_USER`, the box user's account name, in every step: root steps use it to hand files over, for example `chown "$AGENT_VM_BOX_USER"`.

  Steps run in their user's home folder.
- **The Command Line Tools** (git, clang, swift, make, python3), unless the recipe turns them off.
- **No terminal and no input**: standard input is closed and there is no terminal, so a program that asks a question usually fails at once. Pass the answers instead: `--yes`, `NONINTERACTIVE=1`, `CI=1`. The box user is an administrator, but `sudo` asks for a password, so use `"user": "root"` for steps that need root.

## Failures

A step that exits with a non-zero status, or stays silent past its timeout, fails the build. The image is kept with state `failed` and a reason naming the step and the end of its output. `agent-vm image list` shows it; delete the image and build it again. A recipe with a mistake (malformed JSON, an unknown key, a missing `copy` file) is refused before anything is built, and a `copy` file that changes while the image is being built fails its step, so the recorded digest always matches what went into the image.

## Provenance

The image records the recipe's description and a SHA-256 digest of the recipe and every file it copies (`recipe` in `image.json`), and keeps the recipe itself as `recipe.json` in the image folder. The digest is of the recipe file followed by the copied files in step order, so `cat recipe.json <copied files in order> | shasum -a 256` reproduces it.

Every recipe is also kept whole, with the files it copies, in the image's `Recipes/<n>-<name>/` folder (`n` counts from 1 in the order they ran), and listed in `recipes` in `image.json`: `name`, `folder`, `description`, `digest`, `inputs` and `parameters` for each. Each input is recorded with its `name`, the `file`'s name, `bytes`, `sha256` and, since 0.5.6, its `path` on the Mac that built the image, which is where `image rebuild` looks for it again. An image built with `--from` starts with its base's list and folders, each entry marked `inheritedFrom` with the base's name, and adds its own after them, so the list says everything that ran on the disk.

For an image built with several recipes, `recipe` describes them together: the descriptions joined by "; ", the inputs one after another, the parameters merged (leaving out a name that has different values in two recipes), and as digest the SHA-256 of the recipes' digests joined by newlines (`printf '%s\n%s' <digest 1> <digest 2> | shasum -a 256`). There is no `recipe.json` beside `image.json` in that case; the recipes are in `Recipes/`. Images built before agent-vm 0.4.5 have no `recipes` list and no `Recipes/` folder.

Inputs are not part of that digest: the same recipe can be built with another Xcode. `recipe.inputs` records each one's name, file name, size and SHA-256 (of the bytes sent, computed while sending), and `recipe.parameters` every parameter's value, given or default.
