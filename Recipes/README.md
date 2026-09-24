# Example recipes

Recipes for `agent-vm image create --recipe`. The format is described in [../Docs/image-recipes.md](../Docs/image-recipes.md).

| Recipe | Installs | Needs |
|---|---|---|
| [homebrew-node](homebrew-node/recipe.json) | Homebrew in `/opt/homebrew` (owned by the box user, so no `sudo`), Node and npm, and a `~/.zprofile` that puts Homebrew on the login shell's path | the Command Line Tools (default) |
| [agent-clis](agent-clis/recipe.json) | Claude Code, Codex and opencode, from npm | Node: an image built with homebrew-node |

Build them as layers, each from the one before (`--from`), so a change to a later layer rebuilds in about a minute:

```sh
agent-vm image create dev --ipsw <restore image>                                        # about 6 minutes
agent-vm image create dev-node --from dev --recipe Recipes/homebrew-node/recipe.json    # about 2 minutes
agent-vm image create dev-agents --from dev-node --recipe Recipes/agent-clis/recipe.json  # about 1 minute
agent-vm box create work --image dev-agents --allow pack:anthropic --allow pack:openai --allow pack:npm
```

The agents need their own logins or API keys inside the box: nothing from your Mac's Keychain reaches it.
