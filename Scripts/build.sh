#!/bin/bash
#
# Scripts/build.sh - build agent-vm and agent-vm-guest and sign them, so the host tool carries
# the com.apple.security.virtualization entitlement it needs to start virtual machines. A plain
# `swift build` produces binaries without it: Virtualization then refuses every configuration.
#
# Usage: Scripts/build.sh [--debug] [--identity <identity>] [--output <folder>]
#
#   --identity <identity>  codesign identity: "-" for ad hoc (default; runs on this Mac only),
#                          or a Developer ID Application identity (name, team ID or SHA-1 hash),
#                          which also gets a secure timestamp. Default: $AGENT_VM_SIGN_IDENTITY,
#                          else "-".
#   --output <folder>      where the signed binaries go (default: .build/signed/<configuration>)
#   --debug                debug build instead of release
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
    /usr/bin/sed -n '7,14p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
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
"$OUTPUT/agent-vm" doctor
status=$?
if [ "$status" -ne 0 ]; then
    printf '\nbuild.sh: agent-vm doctor reports a problem (status %s); the binaries are signed, but boxes will not run on this Mac.\n' "$status" >&2
    exit 2
fi
exit 0
