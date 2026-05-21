#!/usr/bin/env bats

setup() {
  REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  HOOK="$REPO_DIR/hooks/backend_install.lua"
  LIB_DIR="$REPO_DIR/lib"
  LUA_BIN="$(mise which lua)"
}

run_dependency_lua() {
  local snippet="$1"
  shift

  LAST_EXEC_LOG="$BATS_TEST_TMPDIR/exec.log"
  local harness="$BATS_TEST_TMPDIR/dependency-harness.lua"
  : > "$LAST_EXEC_LOG"

  cat > "$harness" <<LUA
package.path = "$LIB_DIR/?.lua;" .. package.path
PLUGIN = {}

local log_path = assert(os.getenv("EXEC_LOG"), "EXEC_LOG missing")

package.loaded["cmd"] = {
  exec = function(command)
    local log = assert(io.open(log_path, "a"))
    log:write(command, "\n")
    log:close()

    if command:match("env %-u GITHUB_TOKEN %-u GH_TOKEN") then
      if os.getenv("SCRUBBED_FAIL") == "1" then
        error("scrubbed failed")
      end
      return "scrubbed ok"
    end

    if os.getenv("INHERITED_FAIL") == "1" then
      error("inherited failed")
    end
    return "inherited ok"
  end,
}

dofile("$HOOK")
$snippet
LUA

  run env \
    -u GITHUB_TOKEN \
    -u GH_TOKEN \
    -u INHERITED_FAIL \
    -u SCRUBBED_FAIL \
    "$@" \
    EXEC_LOG="$LAST_EXEC_LOG" \
    "$LUA_BIN" "$harness"
}

@test "dependency install uses inherited GitHub auth first" {
  run_dependency_lua 'install_shiv_dependencies("/tmp/shiv", "/bin/mise")' GITHUB_TOKEN=good
  [ "$status" -eq 0 ]

  local line_count
  line_count="$(wc -l < "$LAST_EXEC_LOG" | tr -d ' ')"
  [ "$line_count" -eq 1 ]
  ! grep -q 'env -u GITHUB_TOKEN -u GH_TOKEN' "$LAST_EXEC_LOG"
  grep -q "MISE_OVERRIDE_CONFIG_FILENAMES=mise.prod.toml /bin/mise install -q -C '/tmp/shiv'" "$LAST_EXEC_LOG"
}

@test "dependency install retries with GitHub auth scrubbed after token failure" {
  run_dependency_lua 'install_shiv_dependencies("/tmp/shiv", "/bin/mise")' \
    GITHUB_TOKEN=bad \
    INHERITED_FAIL=1
  [ "$status" -eq 0 ]

  local line_count
  line_count="$(wc -l < "$LAST_EXEC_LOG" | tr -d ' ')"
  [ "$line_count" -eq 2 ]
  ! head -n 1 "$LAST_EXEC_LOG" | grep -q 'env -u GITHUB_TOKEN -u GH_TOKEN'
  tail -n 1 "$LAST_EXEC_LOG" | grep -q 'env -u GITHUB_TOKEN -u GH_TOKEN'
}

@test "dependency install reports both failures when auth retry also fails" {
  run_dependency_lua '
local ok, err = pcall(function()
  install_shiv_dependencies("/tmp/shiv", "/bin/mise")
end)
if ok then
  error("expected dependency install to fail")
end
print(err)
' \
    GITHUB_TOKEN=bad \
    INHERITED_FAIL=1 \
    SCRUBBED_FAIL=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Attempt with inherited GitHub token failed"* ]]
  [[ "$output" == *"Retry without GITHUB_TOKEN/GH_TOKEN also failed"* ]]

  local line_count
  line_count="$(wc -l < "$LAST_EXEC_LOG" | tr -d ' ')"
  [ "$line_count" -eq 2 ]
}

@test "dependency install without GitHub auth does not retry scrubbed" {
  run_dependency_lua '
local ok, err = pcall(function()
  install_shiv_dependencies("/tmp/shiv", "/bin/mise")
end)
if ok then
  error("expected dependency install to fail")
end
print(err)
' INHERITED_FAIL=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Failed to install shiv dependencies (gum):"* ]]
  [[ "$output" != *"Retry without GITHUB_TOKEN/GH_TOKEN"* ]]

  local line_count
  line_count="$(wc -l < "$LAST_EXEC_LOG" | tr -d ' ')"
  [ "$line_count" -eq 1 ]
}
