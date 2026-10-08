#!/bin/bash
#
# Scripts/install-linux-toolchain.sh - install what Scripts/build.sh needs to build
# linux/agent-vm-guest, the guest daemon for Linux boxes: a swift.org toolchain and the static
# Linux SDK of the same version. Xcode's Swift cannot build for Linux.
#
# Usage: Scripts/install-linux-toolchain.sh [--version <version>] [--check] [--yes]
#
#   --version <version>  the Swift release to install (default: the one named below, whose SDK
#                        checksum is in this file; for another release the SDK's version and
#                        checksum are read from swift.org's list of releases)
#   --check              say what is there and what is missing, and install nothing
#                        (status 0 when nothing is missing, 1 otherwise)
#   --yes                do not ask before installing
#
# It installs up to three things, each only when it is missing, all into your home folder and
# none with administrator rights:
#   1. swiftly, swift.org's installer, into ~/.swiftly (a 10 MB package, which must be signed
#      by the Swift project and notarized by Apple);
#   2. the toolchain, with swiftly, into ~/Library/Developer/Toolchains (about 5 GB);
#   3. the static Linux SDK, with that toolchain's `swift sdk install` and the SDK's checksum,
#      into ~/Library/org.swift.swiftpm/swift-sdks (a 0.3 GB download, about 1 GB).
#
# Xcode's Swift stays the default: no shell startup file is changed, and build.sh calls the
# other compiler by its path. To remove it all later: `~/.swiftly/bin/swiftly uninstall
# <version>`, `swift sdk remove <the name `swift sdk list` shows>`, and delete ~/.swiftly.

# The release build.sh was last used with, and its static Linux SDK (swift.org/install/macos).
SWIFT_VERSION="6.4.0"
SWIFT_TAG="swift-6.4.0-RELEASE"
SDK_VERSION="0.1.0"
SDK_CHECKSUM="47d2fd89eebfdf9eb4d536b6710414297f755c17926cdebc4742c08982b40a9e"

RELEASES_URL="https://www.swift.org/api/v1/install/releases.json"
SWIFTLY_URL="https://download.swift.org/swiftly/darwin/swiftly.pkg"
# Who must have signed swiftly's package (pkgutil --check-signature).
SWIFTLY_SIGNER="Developer ID Installer: Swift Open Source (V9AUD2URP3)"

SWIFTLY="$HOME/.swiftly/bin/swiftly"
TOOLCHAINS="$HOME/Library/Developer/Toolchains"
REQUESTED_VERSION=""
CHECK_ONLY=0
ASSUME_YES=0
WORK=""

die() {
    [ -z "$WORK" ] || /bin/rm -rf "$WORK"
    printf 'install-linux-toolchain.sh: error: %s\n' "$1" >&2
    exit 1
}

usage() {
    /usr/bin/sed -n '7,14p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
}

# A release number: digits and dots only, so it can go into an address and a path.
is_version() {
    case "$1" in
        ""|.*|*.|*..*|*[!0-9.]*) return 1 ;;
    esac
    return 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            [ $# -ge 2 ] || die "--version needs a value"
            REQUESTED_VERSION="$2"
            shift 2
            ;;
        --check)
            CHECK_ONLY=1
            shift
            ;;
        --yes)
            ASSUME_YES=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown argument: $1"
            ;;
    esac
done

[ -n "$HOME" ] && [ -d "$HOME" ] || die "\$HOME is not a folder"

# Another release than the one named above: its tag, and its SDK's version and checksum, come
# from swift.org's list.
if [ -n "$REQUESTED_VERSION" ] && [ "$REQUESTED_VERSION" != "$SWIFT_VERSION" ]; then
    is_version "$REQUESTED_VERSION" || die "--version wants a release number such as $SWIFT_VERSION, not \"$REQUESTED_VERSION\""
    SWIFT_VERSION="$REQUESTED_VERSION"
    releases="$(/usr/bin/curl --fail --silent --show-error --location --proto '=https' --max-time 60 "$RELEASES_URL")"
    status=$?
    [ "$status" -eq 0 ] && [ -n "$releases" ] || die "could not read the list of Swift releases from $RELEASES_URL (curl status $status)"
    SWIFT_TAG="$(printf '%s' "$releases" | /usr/bin/jq -r --arg v "$SWIFT_VERSION" '[.[] | select(.name == $v) | .tag][0] // ""')"
    status=$?
    [ "$status" -eq 0 ] || die "the list of Swift releases from $RELEASES_URL is not what was expected (jq status $status)"
    if [ -z "$SWIFT_TAG" ]; then
        # swift.org lists the first release of a line with two parts: 6.3, not 6.3.0.
        case "$SWIFT_VERSION" in
            *.*.0) die "swift.org lists no release $SWIFT_VERSION; it may list it as ${SWIFT_VERSION%.0}" ;;
        esac
        die "swift.org lists no release $SWIFT_VERSION"
    fi
    SDK_VERSION="$(printf '%s' "$releases" | /usr/bin/jq -r --arg v "$SWIFT_VERSION" '[.[] | select(.name == $v) | .platforms[] | select(.platform == "static-sdk") | .version][0] // ""')"
    SDK_CHECKSUM="$(printf '%s' "$releases" | /usr/bin/jq -r --arg v "$SWIFT_VERSION" '[.[] | select(.name == $v) | .platforms[] | select(.platform == "static-sdk") | .checksum][0] // ""')"
    [ -n "$SDK_VERSION" ] && [ -n "$SDK_CHECKSUM" ] || die "swift.org lists no static Linux SDK for Swift $SWIFT_VERSION"
    case "$SWIFT_TAG" in
        swift-*-RELEASE) ;;
        *) die "swift.org names release $SWIFT_VERSION \"$SWIFT_TAG\", which is not a release tag" ;;
    esac
    tag_version="${SWIFT_TAG#swift-}"
    tag_version="${tag_version%-RELEASE}"
    is_version "$tag_version" || die "swift.org names release $SWIFT_VERSION \"$SWIFT_TAG\", which is not a release tag"
    is_version "$SDK_VERSION" || die "swift.org gives \"$SDK_VERSION\" as the static Linux SDK's version for Swift $SWIFT_VERSION"
    case "$SDK_CHECKSUM" in
        *[!0123456789abcdef]*) die "swift.org gives a checksum for the static Linux SDK of Swift $SWIFT_VERSION that is not a SHA-256" ;;
    esac
    [ "${#SDK_CHECKSUM}" -eq 64 ] || die "swift.org gives a checksum for the static Linux SDK of Swift $SWIFT_VERSION that is not a SHA-256"
fi

# swiftly takes a number without its last part, such as 6.3, as "the newest 6.3.x", and calls
# the release swift.org lists as 6.3 "6.3.0": give it all three parts.
SWIFTLY_VERSION="$SWIFT_VERSION"
case "$SWIFT_VERSION" in
    *.*.*) ;;
    *.*) SWIFTLY_VERSION="$SWIFT_VERSION.0" ;;
esac

TOOLCHAIN="$TOOLCHAINS/$SWIFT_TAG.xctoolchain"
TOOLCHAIN_SWIFT="$TOOLCHAIN/usr/bin/swift"
SDK_NAME="${SWIFT_TAG}_static-linux-$SDK_VERSION"
# The folder of a release on download.swift.org is its tag in lower case.
tag_folder="$(printf '%s' "$SWIFT_TAG" | /usr/bin/tr '[:upper:]' '[:lower:]')"
SDK_URL="https://download.swift.org/$tag_folder/static-sdk/$SWIFT_TAG/$SDK_NAME.artifactbundle.tar.gz"

# Sets HAVE_SDK to 1 when the toolchain lists the SDK. Only called when the toolchain is there.
look_for_sdk() {
    HAVE_SDK=0
    local _sdks
    _sdks="$("$TOOLCHAIN_SWIFT" sdk list 2>/dev/null)"
    case "$_sdks" in
        *"$SDK_NAME"*) HAVE_SDK=1 ;;
    esac
}

HAVE_SWIFTLY=0
[ ! -x "$SWIFTLY" ] || HAVE_SWIFTLY=1
HAVE_TOOLCHAIN=0
HAVE_SDK=0
if [ -x "$TOOLCHAIN_SWIFT" ]; then
    HAVE_TOOLCHAIN=1
    look_for_sdk
elif [ -d "$HOME/Library/org.swift.swiftpm/swift-sdks/$SDK_NAME.artifactbundle" ]; then
    # An SDK outlives its toolchain; there is no compiler to ask, so go by its folder. It is
    # asked again once the toolchain is in.
    HAVE_SDK=1
fi

printf 'Swift %s for building the Linux guest daemon:\n' "$SWIFT_VERSION"
if [ "$HAVE_TOOLCHAIN" -eq 1 ]; then
    printf '  toolchain          installed  %s\n' "$TOOLCHAIN"
else
    printf '  toolchain          missing    %s (about 5 GB)\n' "$TOOLCHAIN"
    if [ "$HAVE_SWIFTLY" -eq 1 ]; then
        printf '  swiftly            installed  %s\n' "$SWIFTLY"
    else
        printf '  swiftly            missing    %s (installs the toolchain; 10 MB)\n' "$SWIFTLY"
    fi
fi
if [ "$HAVE_SDK" -eq 1 ]; then
    printf '  static Linux SDK   installed  %s\n' "$SDK_NAME"
else
    printf '  static Linux SDK   missing    %s (a 0.3 GB download, about 1 GB)\n' "$SDK_NAME"
fi

if [ "$HAVE_TOOLCHAIN" -eq 1 ] && [ "$HAVE_SDK" -eq 1 ]; then
    printf 'Nothing to install. Scripts/build.sh builds linux/agent-vm-guest with it.\n'
    exit 0
fi
if [ "$CHECK_ONLY" -eq 1 ]; then
    printf 'Run this script without --check to install what is missing.\n'
    exit 1
fi

if [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || die "this is not a terminal, so there is nobody to ask: give --yes to install what is missing"
    printf 'Install what is missing into your home folder, from swift.org? [y/N] '
    read -r reply
    case "$reply" in
        y|Y|yes|Yes|YES) ;;
        *)
            printf 'Nothing was installed.\n'
            exit 1
            ;;
    esac
fi

if [ "$HAVE_TOOLCHAIN" -ne 1 ]; then
    if [ "$HAVE_SWIFTLY" -ne 1 ]; then
        WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/agent-vm-swiftly.XXXXXX")"
        status=$?
        [ "$status" -eq 0 ] && [ -d "$WORK" ] || die "cannot create a temporary folder"
        trap 'die "interrupted while installing swiftly"' HUP INT TERM
        printf 'Downloading swiftly...\n'
        /usr/bin/curl --fail --silent --show-error --location --proto '=https' --max-time 600 \
            --output "$WORK/swiftly.pkg" "$SWIFTLY_URL"
        status=$?
        [ "$status" -eq 0 ] || die "could not download $SWIFTLY_URL (curl status $status)"
        signature="$(/usr/sbin/pkgutil --check-signature "$WORK/swiftly.pkg" 2>&1)"
        status=$?
        [ "$status" -eq 0 ] || die "the package from $SWIFTLY_URL has no valid signature (pkgutil status $status): $signature"
        case "$signature" in
            *"$SWIFTLY_SIGNER"*) ;;
            *) die "the package from $SWIFTLY_URL is not signed by \"$SWIFTLY_SIGNER\": $signature" ;;
        esac
        case "$signature" in
            *"trusted by the Apple notary service"*) ;;
            *) die "the package from $SWIFTLY_URL is not notarized by Apple: $signature" ;;
        esac
        printf 'Installing swiftly into %s...\n' "$HOME/.swiftly"
        /usr/sbin/installer -pkg "$WORK/swiftly.pkg" -target CurrentUserHomeDirectory
        status=$?
        [ "$status" -eq 0 ] || die "installing swiftly failed (installer status $status)"
        /bin/rm -rf "$WORK"
        WORK=""
        trap - HUP INT TERM
        [ -x "$SWIFTLY" ] || die "swiftly's package was installed, and $SWIFTLY is not there"
    fi
    # Also when an earlier run put swiftly there and stopped before this step: without its
    # configuration swiftly installs nothing.
    if [ ! -f "${SWIFTLY_HOME_DIR:-$HOME/.swiftly}/config.json" ]; then
        # No toolchain of swiftly's own choice, and no change to a shell startup file: `swift`
        # in a shell stays Xcode's.
        "$SWIFTLY" init --no-modify-profile --skip-install --quiet-shell-followup --assume-yes
        status=$?
        [ "$status" -eq 0 ] || die "swiftly init failed (status $status)"
    fi
    printf 'Installing the Swift %s toolchain (a download of over 1 GB)...\n' "$SWIFT_VERSION"
    "$SWIFTLY" install "$SWIFTLY_VERSION" --assume-yes
    status=$?
    [ "$status" -eq 0 ] || die "swiftly install $SWIFTLY_VERSION failed (status $status)"
    [ -x "$TOOLCHAIN_SWIFT" ] || die "swiftly installed Swift $SWIFT_VERSION, and $TOOLCHAIN_SWIFT is not there (is \$SWIFTLY_TOOLCHAINS_DIR set to another folder? build.sh looks in $TOOLCHAINS, or takes a compiler from \$AGENT_VM_LINUX_SWIFT)"
    look_for_sdk
fi

if [ "$HAVE_SDK" -ne 1 ]; then
    printf 'Installing the static Linux SDK %s...\n' "$SDK_NAME"
    "$TOOLCHAIN_SWIFT" sdk install "$SDK_URL" --checksum "$SDK_CHECKSUM"
    status=$?
    [ "$status" -eq 0 ] || die "swift sdk install of $SDK_URL failed (status $status)"
    look_for_sdk
    [ "$HAVE_SDK" -eq 1 ] || die "the SDK was installed, and \"$TOOLCHAIN_SWIFT sdk list\" does not name $SDK_NAME"
fi

printf 'Done. Run Scripts/build.sh: it builds linux/agent-vm-guest with %s.\n' "$TOOLCHAIN_SWIFT"
exit 0
