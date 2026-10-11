# Using a snapshot of the git folders only

`avm --git-snapshot` and `agent-vm session start --git-only` (since 0.7.34) snapshot every entry named `.git` under the shared folder and nothing else. This page says what that protects, what it does not, and how to work with it without losing changes by accident. How the snapshot is taken and what it costs is in [avm.md](avm.md#a-snapshot-of-the-git-folders-only).

The one thing to remember: **the snapshot holds what git has stored, not your files.** Work that was committed, staged or stashed before the session can always be brought back. Work that existed only as files in the folder cannot.

## What is protected

Everything inside each `.git` at the moment the snapshot is taken:

- commits, branches, tags and stashes;
- the staging area (what `git add` recorded), with the content of staged files;
- the reflogs, hooks, configuration, remotes and `info/exclude`;
- the git folders of submodules (they are kept in `.git/modules`) and the records of worktrees;
- the `.git` file of a worktree or a submodule.

For these the report lists every change and flags what can run a program later on this Mac (a hook, `core.fsmonitor`, `core.hooksPath`, a filter in `info/attributes`). Undo puts them back as they were, also when a repository was deleted with its folder: undo makes the missing folders again, at any depth (since 0.7.35), and puts the `.git` into them.

## What is not protected

- **Working files.** Changes you had not staged, files git does not track, and files git ignores (build output, `.env`, local settings). They are neither reported nor undone. If an agent runs `git reset --hard`, `git checkout .`, `git clean` or plain `rm`, what those files held is gone.
- **Files outside any repository** in the shared folder.
- **Anything already sent away.** A `git push` (a forced one too) has changed the remote; undo changes only this Mac.
- **A repository whose data is not in a `.git`:** a bare repository, or one made with `--separate-git-dir` whose data folder is elsewhere. A worktree whose main repository is outside the shared folder has only its `.git` file covered.
- **Repositories in a folder that could not be read** when the snapshot was taken. They are named then, and in every report.
- **Permissions of the folders above a git folder.** Folders that undo has to make again get the permissions of any new folder.

## Before the session

1. **Put your own unfinished work into git.** Commit it, or run `git stash push --include-untracked` (add `--all` to take ignored files too; that also takes build output and installed dependencies out of the folder until you pop the stash). It is then in `.git`, and so in the snapshot. This is the only protection your uncommitted work gets from this kind of snapshot. A change you only staged (`git add`) is covered as well.
2. **Copy what git ignores and you cannot make again** (a `.env` with keys, a local database) somewhere outside the shared folder.
3. **Decide which of the two cases below you are in,** and in the second one do not give the box what it needs to push (no ssh key, no token).
4. **Do not use git yourself in the shared folder while the session is open,** on the Mac or in the box. The snapshot cannot tell your commit from the agent's: an undo takes both away.

## Reading the report

A session in which git was only read (`git status`, `git log`, `git diff`) usually reports no changes; at most `.git/index` is listed as modified, because git refreshes it. `git fetch` adds objects and changes `FETCH_HEAD` and the branches under `refs/remotes`.

A commit looks like this, and none of it is flagged:

```
       M repo/.git/COMMIT_EDITMSG
       M repo/.git/index
       M repo/.git/logs/HEAD
       M repo/.git/logs/refs/heads/main
       A repo/.git/objects/3e/ (1 entries inside)
       A repo/.git/objects/58/ (1 entries inside)
       A repo/.git/objects/6c/ (1 entries inside)
       M repo/.git/refs/heads/main
```

What deserves a look in either case:

- every flagged line (`HIGH`): a hook, `config`, `info/attributes`, or a `.git` added, replaced or deleted as a whole;
- a deleted or modified entry under `refs/heads`, `refs/tags` or `refs/stash`, or a changed `packed-refs`: a branch, tag or stash was removed or moved;
- a modified `HEAD`: another branch is checked out;
- deleted entries under `objects`: git packed or pruned its store (`git gc`), which is harmless by itself but is also how dropped commits disappear for good.

## Case A: the agent may commit

Changes in `.git` are expected, so an undo of everything is rarely what you want. The snapshot is there for three things: taking out what the agent planted, getting back history it destroyed, and taking back the whole run if you reject it.

- **Review with git as well as with the report:** `git log`, `git status`, and `git reflog` to see whether a branch was reset or rebased. The reflog is in `.git` too, so an agent can rewrite it; the report's list of changed refs cannot be rewritten.
- **Take out one planted entry and keep the commits:**
  ```
  agent-vm session undo <id> --path repo/.git/hooks/pre-commit
  agent-vm session undo <id> --path repo/.git/config
  ```
  A hook or the configuration can be put back alone. For anything else in a git folder, put back the whole folder (below): the other files of a git folder depend on each other, and half of an older state with half of a newer one is not a repository git can rely on.
- **Take back the run in one repository:** `agent-vm session undo <id> --path repo/.git`. The other repositories stay as the agent left them, and what changed in them can still be undone.
- **Take back the run everywhere:** `agent-vm session undo <id>`, or `u` at avm's question.
- **Keep the session** until you are sure. While it exists, a commit the agent removed can still be brought back. `agent-vm session discard <id>` ends that.

**If you may still want the agent's commits, save them before the undo.** Undo moves the changed files of the git folder into the session's folder one by one; they are kept, but they are not a repository you can fetch from. Make a bundle first, outside the shared folder:

```
git -C repo bundle create ~/agent-run.bundle --all
agent-vm session undo <id> --path repo/.git
git -C repo fetch ~/agent-run.bundle 'refs/heads/*:refs/remotes/agent-run/*'
```

The agent's branches are then under `agent-run/`, to compare, cherry-pick or merge.

## Case B: the agent is not expected to change git

Here the report should be empty or list only `.git/index`. Anything more means the agent did what it was not asked to do, and the right answer is nearly always the plain undo:

```
agent-vm session undo <id>
```

Since nothing in git was meant to change, this takes away nothing you wanted, with one exception: commits you made yourself in the folder during the session (see "Before the session"). The agent's edits to working files stay where they are, for you to review with `git diff` and commit yourself.

If the report shows a push-shaped change (branches under `refs/remotes` moved without a fetch you expected), look at the remote: undo cannot take a push back.

## After an undo

Undo puts the git folder back and leaves the working files alone, so the two no longer match, and git reports the difference as uncommitted changes. That is expected, and nothing is lost by it:

- **After commits were undone,** the files still hold what the agent's last commit held. `git status` shows it all as modified and untracked files. The content of the agent's work is there; only its commits are gone. Review it with `git diff` and commit what you want.
- **What you had staged before the session is staged again,** as it was.
- **If the agent had checked out another branch,** `HEAD` names your branch again while the files are those of the agent's branch. `git status` then lists every difference between the two as a change. Read it before you do anything else.

Precautions, in this order:

1. **Stop the agent first.** A program still running in the box can change the folder again while or after the undo runs.
2. **Look before you clean up:** `git status`, then `git diff`. Do not start with `git restore .`, `git checkout .`, `git reset --hard` or `git clean`. Each of them overwrites or removes working files, and working files are exactly what this snapshot cannot give back: they would take the agent's uncommitted work and your own with it. (`git stash` keeps what it takes away, but mixes the agent's work with yours in one stash.)
3. **Discard changes path by path** once you know what they are (`git restore path/to/file`), not for the whole tree.
4. **Take stashes of your own back** with `git stash pop` when you are done, if you stashed before the session.

### After a deleted repository came back

When the agent deleted a repository with its folder, undo makes the folder again with only `.git` in it. `git status` lists every tracked file as deleted. Then:

```
git -C repo status          # everything "deleted"? then nothing here can be overwritten
git -C repo restore .       # writes the tracked files from the staging area
git -C repo submodule foreach --recursive git restore .    # if it has submodules: the same in each
```

`git restore .` gives the files as they were staged: the last commit, plus what you had added with `git add`. Not staged changes, untracked files and ignored files do not come back; a stash made before the session does, with `git stash pop`.

If only some files show as deleted, the folder was not removed whole and other files in it may hold work: restore the deleted ones by name instead of `.`.

A file or a link that the agent left where a folder above a repository was is not moved away by undo. Undo says which git folder it could not put back; move that entry away yourself and run the undo again.

## A repository the agent made

A `.git` that did not exist at the snapshot is listed as added, flagged, and a plain undo moves it out of the folder into the session's folder (`replaced-...`, the path is printed), leaving the working files. To keep a repository the agent cloned or initialized while undoing the rest, undo by path and leave that one out, or move its `.git` back from the session's folder before you discard the session.
