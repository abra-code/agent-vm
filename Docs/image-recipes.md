# Image recipes, version 1

A recipe is a JSON file that says what to install in an image besides macOS: Homebrew, Node, an agent's command-line tool, your dotfiles. There are two ways to run one:

- `agent-vm image create <name> --ipsw <file> --recipe <recipe.json>` runs it while it builds a new image, after macOS is set up and the Command Line Tools are installed, and before the image is sealed.
- `agent-vm image create <name> --from <image> --recipe <recipe.json>` runs it on a clone of a ready image. This takes minutes and leaves the base image untouched.

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
| `checks` | no | Commands run as the box user after the steps; each must exit 0 within 300 seconds, and its first line of output is shown. |

Each step does one of two things:

| Key | Meaning |
|---|---|
| `run` | A shell command, run with `/bin/bash -c`. Its output appears in the build log line by line. |
| `copy` + `to` | A file from the recipe's folder (a path relative to `recipe.json`, which must stay inside that folder) written to `to` in the image. `to` is absolute or starts with `~/` (the step user's home); missing folders are created. At most 256 MB: download bigger files in a `run` step. |

Every step can also have:

| Key | Default | Meaning |
|---|---|---|
| `name` | `step N` | Shown while building and in errors. |
| `user` | the box user | `"root"` runs the step as root. |
| `env` | none | Extra environment variables, `{"NAME": "value"}`. |
| `mode` | `"0644"` | Copy steps only: the file's permissions, in octal. |
| `timeoutSeconds` | 1800 | How long the step may go **without any output** before the build gives up (1 to 86400). |

A key that is not in these tables is an error, so a misspelling cannot silently skip a step.

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
