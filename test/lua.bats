#!/usr/bin/env bats

setup() {
  REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LUA_BIN="${VFOX_SHIV_TEST_LUA_BIN:-$(mise which lua)}"
}

@test "Lua unit tests pass" {
  run "$LUA_BIN" "$REPO_DIR/test/lua/run.lua" "$REPO_DIR"
  [ "$status" -eq 0 ]
}
