#!/usr/bin/env bats

# Integration tests for the full vfox-shiv bootstrap chain.
# These simulate a clean machine with no pre-existing shiv clone or global Gum.
# Tests that do not exercise dependency bootstrap opt into a test-owned Gum.

setup() {
  load helpers
  install_plugin

  # Isolate the bootstrap — force a fresh shiv clone per test
  export VFOX_SHIV_PATH="$BATS_TEST_TMPDIR/shiv-bootstrap"
  rm -rf "$VFOX_SHIV_PATH"

  # Ensure clean install state for the test tool
  mise uninstall shiv:readme@0.1.0 2>/dev/null || true
}

teardown() {
  rm -rf "${VFOX_SHIV_PATH:-}"
  mise uninstall shiv:readme@0.1.0 2>/dev/null || true
}

@test "bootstrap installs Gum as a Shiv dependency" {
  run mise install shiv:readme@0.1.0
  [ "$status" -eq 0 ]

  run env MISE_OVERRIDE_CONFIG_FILENAMES=mise.prod.toml mise -C "$VFOX_SHIV_PATH" which gum
  [ "$status" -eq 0 ]
  local gum_path="$output"
  [[ "$gum_path" == "$MISE_DATA_DIR/installs/gum/"* ]]

  run "$gum_path" --version
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "gum version"
}

@test "bootstrap succeeds when GitHub token env vars are set to non-github.com tokens" {
  install_mock_gum

  # Simulate a GHE environment where inherited tokens don't work on github.com.
  export GITHUB_TOKEN="ghp_fake_ghe_token_that_should_not_be_used"
  export GH_TOKEN="ghp_fake_gh_token_that_should_not_be_used"

  run mise install shiv:readme@0.1.0
  [ "$status" -eq 0 ]

  # Verify the tool actually installed
  local install_path
  install_path=$(mise where shiv:readme@0.1.0 2>/dev/null)
  [ -x "$install_path/bin/readme" ]
}

@test "install works when MISE_OVERRIDE_CONFIG_FILENAMES is set by parent" {
  install_mock_gum

  # Simulate okwai CI where the parent sets MISE_OVERRIDE_CONFIG_FILENAMES.
  # vfox-shiv must override this for its own nested mise calls, otherwise
  # shiv's mise.prod.toml is ignored and gum doesn't get installed.
  # Use a real file so the outer mise install doesn't fail reading config.
  local parent_config="$BATS_TEST_TMPDIR/parent-config.toml"
  cat > "$parent_config" <<TOML
[settings]
experimental = true
[plugins]
shiv = "https://github.com/KnickKnackLabs/vfox-shiv"
[tools]
"shiv:readme" = "0.0.1-alpha"
TOML
  mise trust "$parent_config" 2>/dev/null
  export MISE_OVERRIDE_CONFIG_FILENAMES="$parent_config"

  run mise install shiv:readme@0.1.0
  [ "$status" -eq 0 ]

  local install_path
  install_path=$(mise where shiv:readme@0.1.0 2>/dev/null)
  [ -x "$install_path/bin/readme" ]
}

@test "bootstrap fails with clear error for nonexistent shiv ref" {
  export VFOX_SHIV_REF="v99.99.99"

  run mise install shiv:readme@0.1.0
  [ "$status" -ne 0 ]
  # Should get a meaningful error, not a silent swallow
  echo "$output" | grep -qi "failed\|error\|fatal"
}
