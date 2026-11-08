#!/bin/bash
#
# install-homebrew.sh - installs Homebrew into /opt/homebrew the way Homebrew's own installer
# does (https://github.com/Homebrew/install, install.sh): a git copy of Homebrew/brew, fetched
# with up to 5 tries, with the newest release tag checked out as the branch "stable", then
# `brew update --force`. Run as the box user; /opt/homebrew must exist and be theirs (the
# recipe's root step makes it). install.sh itself cannot run in a recipe: it refuses to run as
# root, and as the box user it needs sudo, which the box user does not have.

prefix="/opt/homebrew"
remote="https://github.com/Homebrew/brew"
git="/usr/bin/git"

fail() {
    printf 'install-homebrew: %s\n' "$1" >&2
    exit 1
}

# Runs a command and stops the script when it fails.
run() {
    "$@"
    local status=$?
    if [ "$status" -ne 0 ]; then
        fail "status $status from: $*"
    fi
}

# Runs a git fetch up to 5 times, waiting 2, 4, 8 and 16 seconds between tries, as install.sh.
fetch() {
    local pause=2
    local try
    local status
    for try in 1 2 3 4 5; do
        "$git" fetch --quiet --force "$@" origin
        status=$?
        if [ "$status" -eq 0 ]; then
            return 0
        fi
        if [ "$try" -lt 5 ]; then
            printf 'install-homebrew: git fetch %s failed (status %s); trying again in %s s\n' "$*" "$status" "$pause" >&2
            /bin/sleep "$pause"
            pause=$((pause * 2))
        fi
    done
    fail "git fetch $* from $remote failed 5 times"
}

if [ ! -d "$prefix" ] || [ ! -w "$prefix" ]; then
    fail "$prefix must be a folder the box user can write to"
fi
cd "$prefix" || fail "cannot change into $prefix"

run "$git" -c init.defaultBranch=main init --quiet
run "$git" config remote.origin.url "$remote"
run "$git" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
run "$git" config --bool fetch.prune true
run "$git" config --bool core.autocrlf false
run "$git" config --bool core.symlinks true

fetch
fetch --tags

run "$git" remote set-head origin --auto > /dev/null

tags="$("$git" -c column.ui=never tag --list --sort=-version:refname)"
status=$?
if [ "$status" -ne 0 ]; then
    fail "cannot list the tags of $remote (git status $status)"
fi
tag="$(printf '%s\n' "$tags" | /usr/bin/head -n 1)"
if [ -z "$tag" ]; then
    fail "$remote has no release tag"
fi
run "$git" checkout --quiet --force -B stable "$tag"

run "$prefix/bin/brew" update --force --quiet
printf 'Homebrew %s installed in %s\n' "$tag" "$prefix"
