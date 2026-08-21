#!/usr/bin/env bats
# Unit tests for lib/path.lua

setup() {
  LIB="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/lib/path.lua"
  # Resolve the real lua binary — going through the mise shim in env -i
  # re-reads mise config and fails if $PWD's config isn't trusted.
  LUA_BIN="${VFOX_SHIV_TEST_LUA_BIN:-$(mise which lua)}"
}

# Run a Lua snippet with a controlled environment.
# Pass KEY=value assignments as $1; these are the *only* env vars (plus PATH)
# the Lua process sees. Then loads lib/path.lua and runs $2.
#
# Usage: run_path_lua 'MISE_DATA_DIR=/tmp/foo HOME=/home/x' 'print(Paths.get_shiv_path())'
run_path_lua() {
  local env_assignments="$1"
  local snippet="$2"
  env -i $env_assignments \
    "$LUA_BIN" -e "local Paths = dofile('$LIB'); $snippet"
}

@test "VFOX_SHIV_PATH override wins over everything" {
  run run_path_lua 'VFOX_SHIV_PATH=/custom/shiv MISE_DATA_DIR=/tmp/data HOME=/home/u' \
    'print(Paths.get_shiv_path())'
  [ "$status" -eq 0 ]
  [ "$output" = "/custom/shiv" ]
}

@test "VFOX_SHIV_PATH empty string falls through" {
  # Empty string should be treated as unset — fall through to MISE_DATA_DIR.
  run run_path_lua 'VFOX_SHIV_PATH= MISE_DATA_DIR=/tmp/data HOME=/home/u' \
    'print(Paths.get_shiv_path())'
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/data/shiv-backend/shiv" ]
}

@test "MISE_DATA_DIR is respected when set" {
  run run_path_lua 'MISE_DATA_DIR=/tmp/isolated HOME=/home/u' \
    'print(Paths.get_shiv_path())'
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/isolated/shiv-backend/shiv" ]
}

@test "MISE_DATA_DIR wins over HOME when both set" {
  run run_path_lua 'MISE_DATA_DIR=/tmp/ci-job-42 HOME=/home/u' \
    'print(Paths.get_shiv_path())'
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/ci-job-42/shiv-backend/shiv" ]
}

@test "MISE_DATA_DIR empty string falls through to HOME" {
  run run_path_lua 'MISE_DATA_DIR= HOME=/home/u' \
    'print(Paths.get_shiv_path())'
  [ "$status" -eq 0 ]
  [ "$output" = "/home/u/.local/share/mise/shiv-backend/shiv" ]
}

@test "HOME fallback when nothing else set" {
  run run_path_lua 'HOME=/home/alice' \
    'print(Paths.get_shiv_path())'
  [ "$status" -eq 0 ]
  [ "$output" = "/home/alice/.local/share/mise/shiv-backend/shiv" ]
}

@test "HOME unset yields a relative default (last-resort)" {
  # Nothing reasonable to return here; document the current behavior so
  # a regression that crashes on nil HOME gets caught.
  run run_path_lua '' 'print(Paths.get_shiv_path())'
  [ "$status" -eq 0 ]
  [ "$output" = "/.local/share/mise/shiv-backend/shiv" ]
}

@test "VFOX_SHIV_PATH whitespace-only falls through" {
  run run_path_lua 'VFOX_SHIV_PATH=    MISE_DATA_DIR=/tmp/data HOME=/home/u' \
    'print(Paths.get_shiv_path())'
  [ "$status" -eq 0 ]
  [ "$output" = "/tmp/data/shiv-backend/shiv" ]
}

@test "MISE_DATA_DIR whitespace-only falls through to HOME" {
  run run_path_lua 'MISE_DATA_DIR=    HOME=/home/u' \
    'print(Paths.get_shiv_path())'
  [ "$status" -eq 0 ]
  [ "$output" = "/home/u/.local/share/mise/shiv-backend/shiv" ]
}

@test "VFOX_SHIV_PATH with surrounding whitespace is trimmed" {
  # Leading/trailing whitespace (from a fat-fingered copy-paste) should
  # be trimmed rather than returned verbatim.
  run env -i VFOX_SHIV_PATH="  /trimmed  " HOME=/home/u "$LUA_BIN" -e \
    "local Paths = dofile('$LIB'); print(Paths.get_shiv_path())"
  [ "$status" -eq 0 ]
  [ "$output" = "/trimmed" ]
}
