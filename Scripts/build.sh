#!/bin/bash
#
# Scripts/build.sh - build agent-vm and agent-vm-guest and sign them, so the host tool carries
# the com.apple.security.virtualization entitlement it needs to start virtual machines. A plain
# `swift build` produces binaries without it: Virtualization then refuses every configuration.
# It also builds linux/agent-vm-guest, the guest daemon for Linux boxes, when this Mac can.
#
# Usage: Scripts/build.sh [--debug] [--identity <identity>] [--output <folder>]
#                         [--require-linux-guest | --no-linux-guest]
#
#   --identity <identity>  codesign identity: "-" for ad hoc (default; runs on this Mac only),
#                          or a Developer ID Application identity (name, team ID or SHA-1 hash),
#                          which also gets a secure timestamp. Default: $AGENT_VM_SIGN_IDENTITY,
#                          else "-".
#   --output <folder>      where the signed binaries go (default: .build/signed/<configuration>)
#   --debug                debug build instead of release
#   --require-linux-guest  fail when linux/agent-vm-guest cannot be built (for a release)
#   --no-linux-guest       do not build it
#
# linux/agent-vm-guest is the same daemon built for 64-bit ARM Linux as one static program. Xcode
# cannot build it: it needs a swift.org toolchain and the static Linux SDK of the same version,
# which Scripts/install-linux-toolchain.sh installs (README.md, "Building"). The compiler is
# $AGENT_VM_LINUX_SWIFT, else the newest release toolchain in ~/Library/Developer/Toolchains
# that has such an SDK, else ~/.swiftly/bin/swift.
# Without one the build goes on, and that agent-vm cannot create Linux images. The Linux daemon
# is not signed: it never runs on a Mac.
#
# Both binaries are signed with the hardened runtime. The guest daemon gets no entitlements:
# it never starts virtual machines. The built-in host packs (Resources/packs.json) and agents
# (Resources/agents.json) go next to them, and so does avm, a symlink to agent-vm (started under
# that name it is `agent-vm connect`). After signing, the script verifies both signatures,
# checks that `agent-vm box packs` reads the packs, that `agent-vm connect agents` reads the
# agents and that avm answers as agent-vm, and runs `agent-vm doctor` with the signed binary as
# the end-to-end check.
#
# Notarization is a manual release step on the package (see Packaging/README.md).

REPO_ROOT="$(cd "$(/usr/bin/dirname "$0")/.." && /bin/pwd -P)"
ENTITLEMENTS="$REPO_ROOT/Resources/agent-vm.entitlements"
IDENTITY="${AGENT_VM_SIGN_IDENTITY:--}"
CONFIGURATION="release"
OUTPUT=""
# auto: build the Linux guest daemon when a compiler for it is found; require; no.
LINUX_GUEST="auto"

die() {
    printf 'build.sh: error: %s\n' "$1" >&2
    exit 1
}

# Signing failed: drop the staged copies. The signed binaries already in place stay: an
# unsigned binary never sits where a signed one is expected.
die_unsigned() {
    /bin/rm -rf "$STAGE"
    die "$1"
}

usage() {
    /usr/bin/sed -n '8,18p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --debug)
            CONFIGURATION="debug"
            ;;
        --identity)
            shift
            [ $# -gt 0 ] || die "--identity needs a value"
            IDENTITY="$1"
            ;;
        --output)
            shift
            [ $# -gt 0 ] || die "--output needs a value"
            OUTPUT="$1"
            ;;
        --require-linux-guest)
            LINUX_GUEST="require"
            ;;
        --no-linux-guest)
            LINUX_GUEST="no"
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
    shift
done

[ -n "$IDENTITY" ] || die "the signing identity is empty; use \"-\" for ad hoc"
[ -f "$ENTITLEMENTS" ] || die "entitlements file missing: $ENTITLEMENTS"
if [ -z "$OUTPUT" ]; then
    OUTPUT="$REPO_ROOT/.build/signed/$CONFIGURATION"
fi

printf 'Building (%s)...\n' "$CONFIGURATION"
/usr/bin/xcrun swift build --package-path "$REPO_ROOT" -c "$CONFIGURATION" --product agent-vm
status=$?
[ "$status" -eq 0 ] || die "swift build of agent-vm failed (status $status)"
/usr/bin/xcrun swift build --package-path "$REPO_ROOT" -c "$CONFIGURATION" --product agent-vm-guest
status=$?
[ "$status" -eq 0 ] || die "swift build of agent-vm-guest failed (status $status)"

bin_dir="$(/usr/bin/xcrun swift build --package-path "$REPO_ROOT" -c "$CONFIGURATION" --show-bin-path)"
status=$?
[ "$status" -eq 0 ] && [ -d "$bin_dir" ] || die "could not find the build products folder"

# Prints the swift of a toolchain that can build for Linux: one that has a static Linux SDK of
# its own version. Nothing when there is none.
find_linux_swift() {
    local _candidate
    local _version
    local _sdks
    if [ -n "$AGENT_VM_LINUX_SWIFT" ]; then
        printf '%s\n' "$AGENT_VM_LINUX_SWIFT"
        return 0
    fi
    # Newest first, by version number (6.10 after 6.9).
    local _toolchains
    _toolchains="$(/bin/ls -1d "$HOME"/Library/Developer/Toolchains/swift-*-RELEASE.xctoolchain 2>/dev/null | /usr/bin/sort -rV)"
    local _toolchain
    while IFS= read -r _toolchain; do
        [ -n "$_toolchain" ] || continue
        _candidate="$_toolchain/usr/bin/swift"
        [ -x "$_candidate" ] || continue
        _version="$(/usr/bin/basename "$_toolchain" .xctoolchain)"
        _sdks="$("$_candidate" sdk list 2>/dev/null)"
        case "$_sdks" in
            *"${_version}_static-linux"*)
                printf '%s\n' "$_candidate"
                return 0
                ;;
        esac
    done <<EOF_TOOLCHAINS
$_toolchains
EOF_TOOLCHAINS
    _candidate="$HOME/.swiftly/bin/swift"
    if [ -x "$_candidate" ]; then
        _sdks="$("$_candidate" sdk list 2>/dev/null)"
        case "$_sdks" in
            *static-linux*)
                printf '%s\n' "$_candidate"
                return 0
                ;;
        esac
    fi
    return 0
}

# Said where the step is passed over and again as the last lines of the build, where a person
# who builds for the first time looks.
linux_guest_missing_note() {
    printf '\nNote: linux/agent-vm-guest was not built, so this build cannot create Linux images or run Linux boxes.\n'
    printf '  It needs a swift.org toolchain and the static Linux SDK of the same version (Xcode cannot build for Linux):\n'
    printf '  Scripts/install-linux-toolchain.sh installs both into your home folder (about 6 GB; --check shows what is missing).\n'
    printf '  Then run this script again. README.md, "Building", has the details; --no-linux-guest leaves the step out without this note.\n'
}

# The Linux guest daemon: built in a scratch folder of its own (another compiler, another
# target), then stripped of its symbols, which are most of the file.
LINUX_SDK="aarch64-swift-linux-musl"
linux_binary=""
linux_guest_missing=0
if [ "$LINUX_GUEST" != "no" ]; then
    linux_swift="$(find_linux_swift)"
    if [ -z "$linux_swift" ]; then
        [ "$LINUX_GUEST" != "require" ] || die "no swift.org toolchain with the static Linux SDK was found, and --require-linux-guest was given (README.md, \"Building\")"
        linux_guest_missing=1
        linux_guest_missing_note
    else
        [ -x "$linux_swift" ] || die "the Linux compiler $linux_swift is not an executable (\$AGENT_VM_LINUX_SWIFT?)"
        printf 'Building agent-vm-guest for Linux (%s) with %s...\n' "$CONFIGURATION" "$linux_swift"
        "$linux_swift" build --package-path "$REPO_ROOT" --scratch-path "$REPO_ROOT/.build/linux-guest" \
            --swift-sdk "$LINUX_SDK" -c "$CONFIGURATION" --product agent-vm-guest
        status=$?
        [ "$status" -eq 0 ] || die "swift build of agent-vm-guest for Linux failed (status $status); is the static Linux SDK of this toolchain installed? ($linux_swift sdk list)"
        linux_bin_dir="$("$linux_swift" build --package-path "$REPO_ROOT" --scratch-path "$REPO_ROOT/.build/linux-guest" \
            --swift-sdk "$LINUX_SDK" -c "$CONFIGURATION" --show-bin-path)"
        status=$?
        [ "$status" -eq 0 ] && [ -f "$linux_bin_dir/agent-vm-guest" ] || die "could not find the Linux build of agent-vm-guest"
        linux_binary="$linux_bin_dir/agent-vm-guest"
        linux_objcopy="$(/usr/bin/dirname "$linux_swift")/llvm-objcopy"
        if [ ! -x "$linux_objcopy" ]; then
            # swiftly's swift is a launcher with no tools beside it: the toolchain it installed
            # is the newest one in the user's Toolchains folder.
            linux_objcopy="$HOME/Library/Developer/Toolchains/swift-latest.xctoolchain/usr/bin/llvm-objcopy"
        fi
        [ -x "$linux_objcopy" ] || die "llvm-objcopy was not found next to $linux_swift; it strips the Linux daemon"
    fi
fi

/bin/mkdir -p "$OUTPUT"
status=$?
[ "$status" -eq 0 ] || die "cannot create $OUTPUT"

# Copies are signed in a staging folder next to the output and then renamed into place: a
# running box supervisor keeps its old file, where rewriting the file under it would get it
# killed (macOS stops a process whose signed code changes), and the box with it.
STAGE="$OUTPUT/.staging"
/bin/rm -rf "$STAGE"
/bin/mkdir -p "$STAGE"
status=$?
[ "$status" -eq 0 ] || die "cannot create $STAGE"

# Sign copies, so the next `swift build` (which relinks in place) cannot silently replace a
# signed binary with an unsigned one.
for product in agent-vm agent-vm-guest; do
    /bin/cp -f "$bin_dir/$product" "$STAGE/$product"
    status=$?
    [ "$status" -eq 0 ] || die_unsigned "cannot copy $bin_dir/$product to $STAGE"
done
if [ -n "$linux_binary" ]; then
    /bin/mkdir -p "$STAGE/linux"
    status=$?
    [ "$status" -eq 0 ] || die_unsigned "cannot create $STAGE/linux"
    "$linux_objcopy" --strip-all "$linux_binary" "$STAGE/linux/agent-vm-guest"
    status=$?
    [ "$status" -eq 0 ] || die_unsigned "cannot strip $linux_binary into $STAGE"
    /bin/chmod 0755 "$STAGE/linux/agent-vm-guest"
    status=$?
    [ "$status" -eq 0 ] || die_unsigned "cannot set the mode of $STAGE/linux/agent-vm-guest"
fi
# The built-in host packs, read from next to agent-vm (NetworkPacks), so a host can change
# without a rebuild.
/bin/cp -f "$REPO_ROOT/Resources/packs.json" "$STAGE/packs.json"
status=$?
[ "$status" -eq 0 ] || die_unsigned "cannot copy $REPO_ROOT/Resources/packs.json to $STAGE"
# The agents avm offers, read from next to agent-vm too (AgentCatalog).
/bin/cp -f "$REPO_ROOT/Resources/agents.json" "$STAGE/agents.json"
status=$?
[ "$status" -eq 0 ] || die_unsigned "cannot copy $REPO_ROOT/Resources/agents.json to $STAGE"

timestamp="--timestamp"
if [ "$IDENTITY" = "-" ]; then
    timestamp="--timestamp=none"
fi

printf 'Signing with identity "%s"...\n' "$IDENTITY"
/usr/bin/codesign --force --sign "$IDENTITY" --options runtime "$timestamp" \
    --identifier com.abracode.agent-vm --entitlements "$ENTITLEMENTS" "$STAGE/agent-vm"
status=$?
[ "$status" -eq 0 ] || die_unsigned "codesign of agent-vm failed (status $status); is the identity in your keychain? (security find-identity -v -p codesigning)"
/usr/bin/codesign --force --sign "$IDENTITY" --options runtime "$timestamp" \
    --identifier com.abracode.agent-vm-guest "$STAGE/agent-vm-guest"
status=$?
[ "$status" -eq 0 ] || die_unsigned "codesign of agent-vm-guest failed (status $status)"

for product in agent-vm agent-vm-guest; do
    /usr/bin/codesign --verify --strict --verbose=1 "$STAGE/$product"
    status=$?
    [ "$status" -eq 0 ] || die_unsigned "signature of $product does not verify"
done

entitlements="$(/usr/bin/codesign --display --entitlements - --xml "$STAGE/agent-vm" 2>/dev/null)"
case "$entitlements" in
    *com.apple.security.virtualization*) ;;
    *) die_unsigned "the signed agent-vm does not carry com.apple.security.virtualization" ;;
esac

for product in packs.json agents.json agent-vm agent-vm-guest; do
    /bin/mv -f "$STAGE/$product" "$OUTPUT/$product"
    status=$?
    [ "$status" -eq 0 ] || die_unsigned "cannot move the signed $product into $OUTPUT"
done
# The Linux daemon has the macOS one's name, so it is in a folder of its own. It goes with the
# agent-vm of the same build, or not at all: one left from an earlier build would be another
# version than the agent-vm beside it.
if [ -n "$linux_binary" ]; then
    /bin/mkdir -p "$OUTPUT/linux"
    status=$?
    [ "$status" -eq 0 ] || die_unsigned "cannot create $OUTPUT/linux"
    /bin/mv -f "$STAGE/linux/agent-vm-guest" "$OUTPUT/linux/agent-vm-guest"
    status=$?
    [ "$status" -eq 0 ] || die_unsigned "cannot move linux/agent-vm-guest into $OUTPUT"
else
    /bin/rm -rf "$OUTPUT/linux"
    status=$?
    [ "$status" -eq 0 ] || die_unsigned "cannot remove the linux/agent-vm-guest of an earlier build from $OUTPUT"
fi
/bin/rm -rf "$STAGE"

# avm, after the signed files are in place: a relative link, so the folder can be moved.
/bin/ln -sfn agent-vm "$OUTPUT/avm"
status=$?
[ "$status" -eq 0 ] || die "cannot link $OUTPUT/avm to agent-vm"

# The recipes and the guide to writing them, where the installer puts them: in Recipes next to
# agent-vm (RecipeGuide). A link to the repository's folder, so an edit needs no rebuild.
# Onto a real folder ln would put the link inside it, and agent-vm would read a stale guide.
[ -L "$OUTPUT/Recipes" ] || [ ! -e "$OUTPUT/Recipes" ] || die "$OUTPUT/Recipes is a folder, not the link this script makes; remove it and run again"
/bin/ln -sfn "$REPO_ROOT/Recipes" "$OUTPUT/Recipes"
status=$?
[ "$status" -eq 0 ] || die "cannot link $OUTPUT/Recipes to $REPO_ROOT/Recipes"
# The installer takes the whole Recipes folder, so what Finder and development tools leave in it
# goes now: .DS_Store files, and .claude folders when they hold nothing but empty folders.
/usr/bin/find "$REPO_ROOT/Recipes" -name .DS_Store -type f -delete
status=$?
[ "$status" -eq 0 ] || die "cannot remove the .DS_Store files in $REPO_ROOT/Recipes"
/usr/bin/find "$REPO_ROOT/Recipes" -depth -type d \( -name .claude -o -path '*/.claude/*' \) -empty -delete
status=$?
[ "$status" -eq 0 ] || die "cannot remove the empty .claude folders in $REPO_ROOT/Recipes"

printf '\nSigned binaries in %s\n\n' "$OUTPUT"
# Without $AGENT_VM_PACKS_FILE, so the check reads the packs.json just put there.
AGENT_VM_PACKS_FILE="" "$OUTPUT/agent-vm" box packs > /dev/null
status=$?
[ "$status" -eq 0 ] || die "agent-vm cannot read $OUTPUT/packs.json (status $status); run \"$OUTPUT/agent-vm box packs\" to see why"
# The same for the agents file.
AGENT_VM_AGENTS_FILE="" "$OUTPUT/agent-vm" connect agents > /dev/null
status=$?
[ "$status" -eq 0 ] || die "agent-vm cannot read $OUTPUT/agents.json (status $status); run \"$OUTPUT/agent-vm connect agents\" to see why"
# And the guide `agent-vm recipe guide` prints.
"$OUTPUT/agent-vm" recipe guide > /dev/null
status=$?
[ "$status" -eq 0 ] || die "agent-vm cannot read $OUTPUT/Recipes/WRITING-RECIPES.md (status $status); run \"$OUTPUT/agent-vm recipe guide\" to see why"
agent_vm_version="$("$OUTPUT/agent-vm" --version)"
avm_version="$("$OUTPUT/avm" --version)"
status=$?
[ "$status" -eq 0 ] && [ -n "$avm_version" ] && [ "$avm_version" = "$agent_vm_version" ] \
    || die "$OUTPUT/avm does not answer as agent-vm ($avm_version, expected $agent_vm_version)"
# agent-vm's own look at the Linux daemon: a 64-bit ARM Linux program, with a digest.
if [ -n "$linux_binary" ]; then
    linux_digest="$("$OUTPUT/agent-vm" version --json | /usr/bin/jq -r 'if .linuxGuestDaemon.error then "" else (.linuxGuestDaemon.digest // "") end')"
    status=$?
    [ "$status" -eq 0 ] && [ -n "$linux_digest" ] || die "agent-vm does not take $OUTPUT/linux/agent-vm-guest for a Linux guest daemon; run \"$OUTPUT/agent-vm version\" to see why"
fi
"$OUTPUT/agent-vm" doctor
status=$?
[ "$linux_guest_missing" -eq 0 ] || linux_guest_missing_note
if [ "$status" -ne 0 ]; then
    printf '\nbuild.sh: agent-vm doctor reports a problem (status %s); the binaries are signed, but boxes will not run on this Mac.\n' "$status" >&2
    exit 2
fi
exit 0
