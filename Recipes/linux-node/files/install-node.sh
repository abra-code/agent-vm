#!/bin/bash
#
# install-node.sh <major> - installs the newest Node of one major version from nodejs.org into
# /usr/local, in a Linux image. Run as root. The archive must have the SHA-256 that nodejs.org's
# own list gives for it (both come over HTTPS from nodejs.org). With that version already
# installed it does nothing, so it serves as the update step too.

major="$1"
case "$major" in
    ''|*[!0-9]*)
        printf 'install-node: give a major version, like 24 (got "%s")\n' "$major" >&2
        exit 2
        ;;
esac

machine="$(/usr/bin/uname -m)"
case "$machine" in
    aarch64) arch="arm64" ;;
    x86_64) arch="x64" ;;
    *)
        printf 'install-node: nodejs.org has no build for %s\n' "$machine" >&2
        exit 1
        ;;
esac

base="https://nodejs.org/dist/latest-v${major}.x"
work="$(/usr/bin/mktemp -d)"
if [ -z "$work" ] || [ ! -d "$work" ]; then
    printf 'install-node: cannot make a temporary folder\n' >&2
    exit 1
fi
trap '/usr/bin/rm -rf "$work"' EXIT

/usr/bin/curl --fail --silent --show-error --location --proto '=https' --output "$work/SHASUMS256.txt" "$base/SHASUMS256.txt"
status=$?
if [ "$status" -ne 0 ]; then
    printf 'install-node: cannot fetch %s/SHASUMS256.txt (curl status %s); is there a Node %s?\n' "$base" "$status" "$major" >&2
    exit 1
fi

# The list's line for this machine: "<sha256>  node-v24.9.0-linux-arm64.tar.xz".
line="$(/usr/bin/grep -E "^[0-9a-f]{64}  node-v${major}\.[0-9]+\.[0-9]+-linux-${arch}\.tar\.xz\$" "$work/SHASUMS256.txt")"
count="$(printf '%s\n' "$line" | /usr/bin/grep -c .)"
if [ "$count" != "1" ]; then
    printf 'install-node: the checksum list names %s archives for linux-%s, not one\n' "$count" "$arch" >&2
    exit 1
fi
file="${line#*  }"
top="${file%.tar.xz}"
version="${top#node-}"
version="${version%-linux-*}"

if [ -x /usr/local/bin/node ]; then
    installed="$(/usr/local/bin/node --version 2> /dev/null)"
    if [ "$installed" = "$version" ]; then
        printf 'Node %s is already installed\n' "$version"
        exit 0
    fi
fi

printf 'Downloading %s\n' "$file"
/usr/bin/curl --fail --silent --show-error --location --proto '=https' --output "$work/$file" "$base/$file"
status=$?
if [ "$status" -ne 0 ]; then
    printf 'install-node: cannot fetch %s/%s (curl status %s)\n' "$base" "$file" "$status" >&2
    exit 1
fi

cd "$work"
status=$?
if [ "$status" -ne 0 ]; then
    printf 'install-node: cannot enter %s\n' "$work" >&2
    exit 1
fi
printf '%s\n' "$line" | /usr/bin/sha256sum --check --status
status=$?
if [ "$status" -ne 0 ]; then
    printf 'install-node: %s does not have the SHA-256 that nodejs.org lists for it; nothing was installed\n' "$file" >&2
    exit 1
fi
cd /

# What an older Node left that the new archive would not overwrite file by file.
/usr/bin/rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /usr/local/include/node
/usr/bin/tar -xJf "$work/$file" -C /usr/local --strip-components=1 --no-same-owner \
    --anchored --exclude="$top/CHANGELOG.md" --exclude="$top/LICENSE" --exclude="$top/README.md"
status=$?
if [ "$status" -ne 0 ]; then
    printf 'install-node: cannot unpack %s into /usr/local (tar status %s)\n' "$file" "$status" >&2
    exit 1
fi

installed="$(/usr/local/bin/node --version)"
if [ "$installed" != "$version" ]; then
    printf 'install-node: /usr/local/bin/node says "%s" after installing %s\n' "$installed" "$version" >&2
    exit 1
fi
printf 'Node %s installed in /usr/local\n' "$version"
