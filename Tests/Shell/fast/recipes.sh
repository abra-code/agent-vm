#!/bin/bash
#
# Tests/Shell/fast/recipes.sh - image create's checks that run before any virtual machine: the
# choice between --ipsw and --from, recipe validation, and refusing unusable base images.

# write_recipe <json>: writes $SCRATCH/recipe/recipe.json.
write_recipe() {
    /bin/mkdir -p "$SCRATCH/recipe"
    printf '%s\n' "$1" > "$SCRATCH/recipe/recipe.json"
}

test_ipsw_and_from_are_alternatives() {
    run_avm image create x
    assert_status 64 || return 1
    assert_err_contains "either --ipsw" || return 1
    run_avm image create x --ipsw /nowhere.ipsw --from dev --recipe r.json
    assert_status 64 || return 1
}

test_from_needs_a_recipe_and_keeps_the_base_account() {
    run_avm image create x --from dev
    assert_status 64 || return 1
    assert_err_contains "give --recipe" || return 1
    write_recipe '{"version": 1}'
    run_avm image create x --from dev --recipe "$SCRATCH/recipe/recipe.json" --user bob
    assert_status 64 || return 1
    assert_err_contains "come from the base image" || return 1
}

# --disk-gb with --from only grows the disk, by at least 8 GB (the base is 64 GB).
test_a_derived_disk_only_grows() {
    fake_image dev
    write_recipe '{"version": 1}'
    run_avm image create x --from dev --recipe "$SCRATCH/recipe/recipe.json" --disk-gb 60
    assert_status 1 || return 1
    assert_err_contains "the disk can only grow, by at least 8 GB: dev's is 64 GB" || return 1
    run_avm image create x --from dev --recipe "$SCRATCH/recipe/recipe.json" --disk-gb 70
    assert_status 1 || return 1
    assert_err_contains "by at least 8 GB" || return 1
    assert_missing "$AGENT_VM_HOME/Images/x" || return 1
}

# Inputs and parameters are checked against the recipe before anything is built.
test_inputs_and_parameters_are_checked_first() {
    fake_image dev
    write_recipe '{"version": 1, "inputs": {"xcode": {"description": "an Xcode .xip"}}, "parameters": {"platforms": {"default": "iOS"}, "team": {}}}'
    printf 'xip' > "$SCRATCH/Xcode.xip"
    run_avm image create x --from dev --input xcode="$SCRATCH/Xcode.xip"
    assert_status 64 || return 1
    assert_err_contains "add --recipe" || return 1
    run_avm image create x --from dev --recipe "$SCRATCH/recipe/recipe.json" --set team
    assert_status 64 || return 1
    assert_err_contains "team: give name=value" || return 1
    run_avm image create x --from dev --recipe "$SCRATCH/recipe/recipe.json" --set team=a
    assert_status 1 || return 1
    assert_err_contains "needs --input xcode=PATH: an Xcode .xip" || return 1
    run_avm image create x --from dev --recipe "$SCRATCH/recipe/recipe.json" --input xcode="$SCRATCH/Xcode.xip"
    assert_status 1 || return 1
    assert_err_contains "needs --set team=VALUE" || return 1
    run_avm image create x --from dev --recipe "$SCRATCH/recipe/recipe.json" --input xcode="$SCRATCH/Xcode.xip" --set team=a --set size=2
    assert_status 1 || return 1
    assert_err_contains "has no parameter size (its parameters: platforms, team)" || return 1
    run_avm image create x --from dev --recipe "$SCRATCH/recipe/recipe.json" --input xcode="$SCRATCH/nothing.xip" --set team=a
    assert_status 1 || return 1
    assert_err_contains "input xcode: $SCRATCH/nothing.xip does not exist" || return 1
    run_avm image create x --from dev --recipe "$SCRATCH/recipe/recipe.json" --input xcode="$SCRATCH/Xcode.xip" --set team=a --set team=b
    assert_status 64 || return 1
    assert_err_contains "--set team is given twice" || return 1
    assert_missing "$AGENT_VM_HOME/Images/x" || return 1
}

# Several recipes: a name goes to every recipe that declares it, and one none declares is refused.
test_several_recipes_share_inputs_and_parameters() {
    fake_image dev
    /bin/mkdir -p "$SCRATCH/node" "$SCRATCH/xcode"
    printf '%s\n' '{"version": 1, "parameters": {"channel": {"default": "lts"}}}' > "$SCRATCH/node/recipe.json"
    printf '%s\n' '{"version": 1, "inputs": {"xcode": {"description": "an Xcode .xip"}}}' > "$SCRATCH/xcode/recipe.json"
    run_avm image create x --from dev --recipe "$SCRATCH/node/recipe.json" --recipe "$SCRATCH/xcode/recipe.json"
    assert_status 1 || return 1
    assert_err_contains "needs --input xcode=PATH: an Xcode .xip" || return 1
    printf 'xip' > "$SCRATCH/Xcode.xip"
    run_avm image create x --from dev --recipe "$SCRATCH/node/recipe.json" --recipe "$SCRATCH/xcode/recipe.json" --input xcode="$SCRATCH/Xcode.xip" --set size=2
    assert_status 1 || return 1
    assert_err_contains "none of the recipes has a parameter size (they have: channel)" || return 1
    run_avm image create x --from dev --recipe "$SCRATCH/node/recipe.json" --recipe "$SCRATCH/node/recipe.json"
    assert_status 1 || return 1
    assert_err_contains "it is given twice" || return 1
    assert_missing "$AGENT_VM_HOME/Images/x" || return 1
}

test_a_bad_recipe_is_refused_before_anything_is_built() {
    fake_image dev
    write_recipe '{"version": 1, "steps": [{"run": "true", "usr": "root"}]}'
    run_avm image create x --from dev --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 1 || return 1
    assert_err_contains "unknown key \"usr\"" || return 1
    assert_missing "$AGENT_VM_HOME/Images/x" || return 1

    write_recipe '{"version": 1, "steps": [{"copy": "../../etc/hosts", "to": "/tmp/h"}]}'
    run_avm image create x --from dev --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 1 || return 1
    assert_err_contains "recipe" || return 1

    run_avm image create x --from dev --recipe "$SCRATCH/no-such-recipe.json"
    assert_status 1 || return 1
    assert_err_contains "cannot read it" || return 1
}

test_unusable_bases_are_refused() {
    fake_image half provisioning
    write_recipe '{"version": 1, "steps": [{"run": "true"}]}'
    run_avm image create x --from half --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 1 || return 1
    assert_err_contains "it is provisioning" || return 1
    run_avm image create x --from missing --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 1 || return 1
    assert_err_contains "no image missing" || return 1
    assert_missing "$AGENT_VM_HOME/Images/x" || return 1
}

test_the_example_recipes_are_valid() {
    fake_image half provisioning
    local _recipe
    printf 'xip' > "$SCRATCH/Xcode.xip"
    local _inputs
    for _recipe in "$TESTS_DIR/../../Recipes"/*/recipe.json; do
        # A valid recipe gets past its own checks and stops at the unusable base; the Xcode
        # recipe needs its .xip first.
        _inputs=""
        case "$_recipe" in
            */xcode/recipe.json) _inputs="--input xcode=$SCRATCH/Xcode.xip" ;;
        esac
        run_avm image create x --from half --recipe "$_recipe" $_inputs
        assert_status 1 || return 1
        assert_err_contains "it is provisioning" || return 1
    done
}
