#!/usr/bin/env python3
# Scripts/recipe-history.py
#
# Writes Recipes/history.json: for each recipe that ships with agent-vm, the digest of every
# version it ever had in this repository (each commit that touched its folder, and the working
# tree). `agent-vm image update` reads the file: an image that keeps a recipe whose digest is
# listed here keeps a built-in recipe, and takes the installed one in its place when that is
# another version. A recipe of the person's own that only has the same name is not listed and
# is left alone.
#
# Run it after changing a recipe (a test fails until the new digest is in the file):
#
#   python3 Scripts/recipe-history.py
#
# The digest is ImageRecipe's: SHA-256 over the recipe file's bytes, then the bytes of each
# file a "copy" step names, in the order of "steps" and then "update".

import hashlib
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RECIPES = "Recipes"
RECIPE_FILE = "recipe.json"
HISTORY = os.path.join(REPO, RECIPES, "history.json")


def git(*arguments):
    result = subprocess.run(["/usr/bin/git", "-C", REPO] + list(arguments), capture_output=True)
    if result.returncode != 0:
        return None
    return result.stdout


def digest(read):
    """The digest of one version of a recipe; `read` returns a file's bytes by its path in
    the recipe's folder, or None. None when that version cannot be read as a recipe."""
    text = read(RECIPE_FILE)
    if text is None:
        return None
    try:
        root = json.loads(text.decode("utf-8-sig"))
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(root, dict):
        return None
    hasher = hashlib.sha256(text)
    for key in ("steps", "update"):
        steps = root.get(key) or []
        if not isinstance(steps, list):
            return None
        for step in steps:
            if isinstance(step, dict) and isinstance(step.get("copy"), str):
                contents = read(os.path.normpath(step["copy"]))
                if contents is None:
                    return None
                hasher.update(contents)
    return hasher.hexdigest()


def from_commit(commit, name):
    def read(path):
        return git("show", "%s:%s/%s/%s" % (commit, RECIPES, name, path))
    return digest(read)


def from_working_tree(name):
    def read(path):
        try:
            with open(os.path.join(REPO, RECIPES, name, path), "rb") as file:
                return file.read()
        except OSError:
            return None
    return digest(read)


def main():
    names = sorted(entry for entry in os.listdir(os.path.join(REPO, RECIPES))
                   if os.path.isfile(os.path.join(REPO, RECIPES, entry, RECIPE_FILE)))
    recipes = {}
    for name in names:
        listed = []
        log = git("log", "--reverse", "--format=%H", "--", "%s/%s" % (RECIPES, name))
        if log is None:
            sys.exit("cannot read the git history of %s/%s" % (RECIPES, name))
        for commit in log.decode().split():
            value = from_commit(commit, name)
            if value is not None and value not in listed:
                listed.append(value)
        current = from_working_tree(name)
        if current is None:
            sys.exit("cannot read %s/%s/%s as a recipe" % (RECIPES, name, RECIPE_FILE))
        # The current one last, also when an older version was the same.
        if current in listed:
            listed.remove(current)
        listed.append(current)
        recipes[name] = listed
    with open(HISTORY, "w") as file:
        json.dump({"version": 1, "recipes": recipes}, file, indent=2, sort_keys=True)
        file.write("\n")
    for name in names:
        print("%s: %d version%s" % (name, len(recipes[name]), "" if len(recipes[name]) == 1 else "s"))


if __name__ == "__main__":
    main()
