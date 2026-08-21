#!/usr/bin/env bats

setup() {
  load helpers
}

@test "public tests keep writable state under the task-owned root" {
  local path
  for path in \
    "$MISE_DATA_DIR" \
    "$MISE_CACHE_DIR" \
    "$MISE_CONFIG_DIR" \
    "$MISE_STATE_DIR" \
    "$XDG_CACHE_HOME" \
    "$XDG_CONFIG_HOME" \
    "$XDG_DATA_HOME" \
    "$XDG_STATE_HOME" \
    "$SHIV_SOURCES_DIR" \
    "$VFOX_SHIV_PATH"; do
    [[ "$path" == "$VFOX_SHIV_TEST_ISOLATION_ROOT/"* ]]
  done

  [[ ":$PATH:" != *":$VFOX_SHIV_TEST_AMBIENT_MISE_SHIMS:"* ]]
  [[ ":$PATH:" != *":$HOME/.local/share/mise/shims:"* ]]

  install_plugin
  local plugin="$MISE_DATA_DIR/plugins/shiv"
  [ -L "$plugin" ]
  [ "$(cd "$plugin" && pwd -P)" = "$PLUGIN_DIR" ]

  run bash -c 'cd "$1" && mise config ls' _ "$PLUGIN_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"~/.config/mise/config.toml"* ]]
  [[ "$output" != *"$HOME/.config/mise/config.toml"* ]]
}

@test "test Gum executes wrapped commands and rejects malformed spin calls" {
  install_mock_gum

  run gum spin
  [ "$status" -eq 2 ]

  run gum spin --
  [ "$status" -eq 2 ]

  run gum spin -- printf 'wrapped command ran\n'
  [ "$status" -eq 0 ]
  [ "$output" = "wrapped command ran" ]
}
