#!/usr/bin/env bats

setup() {
  load helpers
  install_mock_gum
  install_plugin
  ensure_bootstrap
}

@test "install a tagged version" {
  setup_mise_project '"shiv:readme" = "0.1.0"'

  run mise install
  [ "$status" -eq 0 ]

  # Verify the install path exists with the expected structure
  local install_path
  install_path=$(mise where shiv:readme@0.1.0 2>/dev/null)
  [ -d "$install_path/bin" ]
  [ -d "$install_path/packages" ]
  [ -x "$install_path/bin/readme" ]
}

@test "installed shim is executable and has correct repo path" {
  setup_mise_project '"shiv:readme" = "0.1.0"'
  mise install 2>/dev/null

  local install_path
  install_path=$(mise where shiv:readme@0.1.0 2>/dev/null)

  # Shim should point to the package inside the install path
  grep -q "REPO=" "$install_path/bin/readme"
  grep -q "$install_path/packages/readme" "$install_path/bin/readme"
}

@test "installed shim delegates to mise run" {
  setup_mise_project '"shiv:readme" = "0.1.0"'
  mise install 2>/dev/null

  local install_path
  install_path=$(mise where shiv:readme@0.1.0 2>/dev/null)

  # Shim should be a bash script that delegates to mise run
  [ -x "$install_path/bin/readme" ]
  grep -q 'mise.*run' "$install_path/bin/readme"
}

@test "install latest release from config" {
  setup_mise_project '"shiv:readme" = "latest"'

  run mise install
  [ "$status" -eq 0 ]

  local install_path
  install_path=$(mise where shiv:readme@latest 2>/dev/null)
  [ -x "$install_path/bin/readme" ]
}

@test "explicit latest install succeeds" {
  setup_mise_project '"shiv:readme" = "latest"'

  run mise install
  [ "$status" -eq 0 ]

  local install_path
  install_path=$(mise where shiv:readme@latest 2>/dev/null)
  [ -x "$install_path/bin/readme" ]
}

@test "install nonexistent package shows clean error" {
  setup_mise_project '"shiv:nonexistent-pkg-xyzzy" = "0.1.0"'

  # NO_COLOR suppresses mise's own red-wrap on the ERROR line so we can
  # assert cleanly on the hook-produced text. In CI (CI=true), mise
  # force-colors stderr even without a TTY; without NO_COLOR, mise's
  # own \e[31m...\e[0m wrappers would leak into $output and trip the
  # "no raw escape codes" check below. The check is about whether our
  # hook outputs clean text — not whether mise decorates the line.
  run env NO_COLOR=1 mise install
  [ "$status" -ne 0 ]
  # Error should mention the package name and be readable (no raw escape codes)
  echo "$output" | grep -qi "shiv install failed\|not found"
  # Should not contain raw ANSI escape sequences
  [[ "$output" != *$'\x1b['* ]]
}
