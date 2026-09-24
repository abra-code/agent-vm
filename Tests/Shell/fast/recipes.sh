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

test_from_needs_a_recipe_and_keeps_the_base_disk() {
    run_avm image create x --from dev
    assert_status 64 || return 1
    assert_err_contains "give --recipe" || return 1
    write_recipe '{"version": 1}'
    run_avm image create x --from dev --recipe "$SCRATCH/recipe/recipe.json" --disk-gb 80
    assert_status 64 || return 1
    assert_err_contains "come from the base image" || return 1
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
    for _recipe in "$TESTS_DIR/../../Recipes"/*/recipe.json; do
        # A valid recipe gets past its own checks and stops at the unusable base.
        run_avm image create x --from half --recipe "$_recipe"
        assert_status 1 || return 1
        assert_err_contains "it is provisioning" || return 1
    done
}
