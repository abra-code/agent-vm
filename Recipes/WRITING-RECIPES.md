# Writing an image recipe: a guide for AI agents

You were asked to write a recipe for agent-vm. This guide is everything you need: read it whole before you write anything. `agent-vm recipe guide` prints it.

## 1. What a recipe is

agent-vm runs AI agents and their tools in macOS virtual machines called boxes. A box is a copy of an image, and an image is macOS plus whatever its recipes installed. A recipe is one JSON file that says what to install: steps that run in the image while it is built, and checks that prove the steps worked.

- **Where to put it:** a folder of its own, named after what it installs, holding `recipe.json` and, when the recipe copies files into the image, a `files/` folder beside it. The folder's name is the recipe's name. Ask the person where the folder should go; never write into agent-vm's own `Recipes/` folder.
- **One recipe, one thing:** a tool and what it needs. Several recipes can go into one image, in order, so do not repeat what another recipe installs (Homebrew, Node): say that yours needs it (section 7).

## 2. The format

A recipe is a JSON object. A key that is not in these tables is an error.

### Recipe keys

| Key | Required | Meaning |
|---|---|---|
| `version` | yes | Always `1`. |
| `description` | no | One line saying what the recipe installs. Always write one. |
| `commandLineTools` | no | `false` skips Xcode's Command Line Tools (git, clang, make, python3). Leave it out unless told otherwise. |
| `steps` | no | A list of steps, run in order while the image is built. |
| `update` | no | A list of steps that bring what the recipe installed up to date. `agent-vm image update` runs them, never the build. |
| `checks` | no | A list of shell commands, run as the box user after the steps and again after every update. Each must exit 0 within 300 seconds. Its first line of output is shown. |
| `inputs` | no | Files the person must give when building, by name. |
| `parameters` | no | Values the person may set when building, by name. |

### Step keys

A step has either `run`, or `copy` with `to`. The same keys are used in `steps` and in `update`.

| Key | Default | Meaning |
|---|---|---|
| `run` | | A shell command, run with `/bin/bash -c`. |
| `copy` | | A file in the recipe's folder, as a path relative to `recipe.json` (`files/gitconfig`). At most 256 MB. |
| `to` | | With `copy`: where the file goes in the image. Absolute, or starting with `~/` (the step user's home). Missing folders are made. |
| `mode` | `"0644"` | With `copy`: the file's permissions, in octal. |
| `name` | `step N` (`update step N` in `update`) | Shown while building and in errors. Always write one. |
| `user` | the box user | `"root"` runs the step as root. No other value. |
| `env` | none | Extra environment variables, `{"NAME": "value"}`. |
| `timeoutSeconds` | 1800 | How long the step may print nothing before the build gives up (1 to 86400). |

### Input keys

`inputs` maps a name to an object. A name is lower-case letters, digits and `_`, starting with a letter, at most 32. A step sees the file's path in the image as `$AGENT_VM_INPUT_<NAME>` (the name in capitals). Every input is required. Use one only for a file that cannot be downloaded by a step and is too big to copy (an installer behind a login).

| Key | Meaning |
|---|---|
| `description` | Shown when the file is not given: say what the file is and where to get it. |

### Parameter keys

`parameters` maps a name (same rules) to an object. Steps and checks see the value as `$AGENT_VM_PARAM_<NAME>`.

| Key | Meaning |
|---|---|
| `description` | Shown when the value is missing. |
| `default` | The value when none is set. Without it the parameter is required. |

### A full example

```json
{
  "version": 1,
  "description": "ripgrep and a settings file for it (needs Homebrew: put Recipes/homebrew before it)",
  "parameters": {
    "extras": { "description": "more Homebrew packages, separated by spaces", "default": "" }
  },
  "steps": [
    {
      "name": "Homebrew is there",
      "run": "[ -x /opt/homebrew/bin/brew ] || { echo 'Homebrew is not in this image: put Recipes/homebrew before this recipe' >&2; exit 1; }"
    },
    {
      "name": "ripgrep",
      "run": "/opt/homebrew/bin/brew install ripgrep $AGENT_VM_PARAM_EXTRAS",
      "env": { "HOMEBREW_NO_ANALYTICS": "1", "HOMEBREW_NO_ENV_HINTS": "1" },
      "timeoutSeconds": 3600
    },
    { "name": "settings", "copy": "files/ripgreprc", "to": "~/.config/ripgrep/config", "mode": "0644" },
    { "name": "settings for every user", "user": "root", "run": "mkdir -p /etc/ripgrep && cp \"/Users/$AGENT_VM_BOX_USER/.config/ripgrep/config\" /etc/ripgrep/config" }
  ],
  "update": [
    { "name": "newest ripgrep", "run": "/opt/homebrew/bin/brew upgrade ripgrep || true" }
  ],
  "checks": ["rg --version", "test -f ~/.config/ripgrep/config"]
}
```

## 3. What steps can rely on, and the traps

- **Who runs a step:** the box user (an administrator account, in its home folder), or root with `"user": "root"`.
- **Never `sudo` as the box user.** It asks for a password and there is nobody to type it. A step that needs root says `"user": "root"`. (Inside a root step, `sudo -u "$AGENT_VM_BOX_USER" <command>` runs one command as the box user.) Root steps hand files to the box user with `chown "$AGENT_VM_BOX_USER"`; that variable is set in every step.
- **No terminal and no input.** Standard input is closed. A program that asks a question fails or waits forever. Pass the answers: `--yes`, `-y`, `NONINTERACTIVE=1`, `CI=1`.
- **The path** is `/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`. A tool installed elsewhere (`~/.local/bin`, `~/.cargo/bin`) is not found by later steps, by checks, or by programs run in a box. Install into one of those folders, link the tool into `/usr/local/bin` in a root step, or call it by its full path.
- **Each step is a new shell.** A `cd` or an `export` in one step is gone in the next. Put what belongs together in one step, joined with `&&`.
- **A step fails when its command exits non-zero.** In a step with several commands, join them with `&&`, or a failure in the middle is not noticed.
- **A silent step hits its timeout.** The timeout counts seconds without output, not the step's whole time. A long download that prints nothing needs a larger `timeoutSeconds` or a flag that makes it print progress.
- **The network differs between build and box.** The build reaches the whole internet. A box, by default, reaches only the hosts its rules allow. If the tool needs the network when it runs (a registry, an API), say so in the recipe's `description` and tell the person which hosts or packs the box will need (`agent-vm box packs` lists the packs, such as `pack:npm`, `pack:pypi`, `pack:github`).
- **Update steps run again and again,** on an image where they ran before: `brew upgrade x || true`, `npm install --global x@latest`. They must succeed when there is nothing to update. Do not update macOS in a recipe.
- **Inputs are gone after the build.** Do not use `$AGENT_VM_INPUT_...` in an update step or in a check: checks run again at every update.
- **Checks must hold forever:** after the build and after any later update. Check that the tool runs (`tool --version`), not an exact version number.
- **Pin nothing you do not have to.** If a version must be pinned, make it a parameter with a default, so it can be moved without editing the recipe.

## 4. The loop: check, then build

Work in two rounds. Do not skip the first, and do not stop after it.

### Round 1: check (a second, as often as needed)

```sh
agent-vm recipe check --strict path/to/recipe.json
```

- **On success** it prints `path/to/recipe.json: ok (<name>: 2 steps, 1 update step, 2 checks)` and exits 0. A line starting with `note` is not a problem.
- **On a mistake** it prints `path/to/recipe.json: error: <what is wrong and where>` and exits 1. It reports the first mistake only: fix it and run again.
- **A warning** (`warning (step 3): ...`) also exits 1 with `--strict`. Fix what it names. If you are sure a warning is wrong, say so to the person and go on without `--strict`.
- This needs no virtual machine and changes nothing, so it also works inside a sandbox.
- It reads the recipe; it does not run it. Passing means a build will accept the file, not that the steps work.

### Round 2: build (minutes, once round 1 passes)

1. Find a ready image to build from: `agent-vm image list --json` (each has a `name` and a `state`; use one whose state is `ready`). If there are several, or none, ask the person (section 5).
2. Build under a scratch name that no image has, starting with `scratch-`:

   ```sh
   agent-vm image create scratch-mytool --from <ready image> --recipe path/to/recipe.json --json
   ```

   Add `--input NAME=PATH` and `--set NAME=VALUE` for the recipe's inputs and parameters. Recipes yours needs go before it, each with its own `--recipe`, unless the image already has them.
3. **On success** the command exits 0 and prints the new image's record as JSON on standard output. Progress lines, one JSON object each, go to standard error; each check's first output line is among them.
4. **On failure** it exits non-zero, and the last lines on standard error are `Error: ...`, naming the step or check that failed and the end of its output. When a step or check failed, the same text is kept: `agent-vm image list --json` shows the scratch image with state `failed` and the reason in `failure`. A build refused before it started (a mistake in the recipe, a missing input, no free virtual machine) leaves no image.
5. Delete the scratch image if `image list` shows one, whether it failed or not: `agent-vm image delete scratch-mytool`.
6. Fix the recipe, run round 1 again, then build again. Repeat until a build succeeds.
7. When it succeeds, delete the scratch image and tell the person: where the recipe is, the exact `image create` command to build their real image with it, and which hosts or packs a box will need.

If a build fails for a reason that is not the recipe's (no free virtual machine, no disk space, the error in section 6 about virtual machines), stop and tell the person. Do not retry in a loop.

## 5. When to stop and ask the person

- **A file only they can get:** an installer behind a login (Xcode's `.xip` needs an Apple ID), a license file. Declare it as an input, and ask them for the path.
- **Which image to build from,** when more than one is ready or none is.
- **Anything that needs an account, a login or a payment.** A recipe never logs in to anything.
- **Where the recipe folder should go,** if they did not say.
- **A choice the request leaves open** that changes what is installed (which version, which variant).

## 6. Rules of conduct

- **Never put a secret in a recipe or a parameter:** no token, password or key. Recipes are kept with the image, and parameter values are recorded and can be read by every user of the Mac. If the tool needs a login, the person does it in the box afterwards.
- **Build only under a scratch name, and delete it afterwards.** Leave no scratch image behind.
- **Never change, update or delete the person's existing images or boxes.** `image delete` only on a scratch image you made in this session. No `image update`, `image rebuild`, `box delete` or `box recreate`.
- **Download only from the tool's own source:** its official site, its repository, a package manager. Use `https`. Do not pipe a script from an address you guessed.
- **agent-vm cannot run virtual machines inside a sandbox.** If you run in one, `image create` fails with an error that may not name the sandbox: an operation that is not permitted, or a virtual machine that cannot start. `agent-vm doctor` tells: inside a sandbox it prints a line starting with `FAIL  virtualization`, saying that this process cannot run virtual machines. Do not retry and do not look for another way: ask the person to allow agent-vm to run outside the sandbox. `recipe check` and `recipe guide` work inside one.
- **Do not edit the shipped recipes.** Copy from them into your own.

## 7. Examples to copy from

The shipped recipes are in the `Recipes` folder beside the agent-vm program, the folder this guide is in (`agent-vm recipe guide --path` prints the guide's path). Read the one nearest to what you are writing:

| Recipe | Shows |
|---|---|
| `homebrew/recipe.json` | A root step that makes a folder for the box user, a download without `sudo`, a copied file, an update step. |
| `node/recipe.json` | Needing another recipe: a first step that fails with a clear message when Homebrew is missing. |
| `python/recipe.json` | Links that give a tool a second name on the path (`python` and `pip` without the 3); a check that proves more than `--version`. |
| `agent-clis/recipe.json` | Global npm installs, and an update step that installs the newest. |
| `acp-agents/recipe.json` | Versions pinned as parameters with defaults; checks that run each program. |
| `xcode/recipe.json` | An input file; what was unpacked from it is checked before it is used; root steps. |
| `xcode-platforms/recipe.json` | Parameters that hold a list; a long download with a large timeout. |

**Saying what your recipe needs:** when it needs something another recipe installs, make its first step test for that and fail with a message that names the recipe to put before it, as node's does:

```json
{ "name": "Homebrew is there", "run": "[ -x /opt/homebrew/bin/brew ] || { echo 'Homebrew is not in this image: put Recipes/homebrew before this recipe' >&2; exit 1; }" }
```

Say the same in the `description`: `"... (needs Homebrew: put Recipes/homebrew before it)"`.
