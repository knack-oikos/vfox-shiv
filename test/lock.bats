#!/usr/bin/env bats
# Unit tests for lib/lock.lua

setup() {
  LIB_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/lib"
  LUA_BIN="${VFOX_SHIV_TEST_LUA_BIN:-$(mise which lua)}"
  LOCK="$BATS_TEST_TMPDIR/shiv.lock"
}

# Run a Lua snippet with the real lua binary, having dofile'd lib/lock.lua.
#
# cmd.exec lives in a Rust module inside mise, so we don't have it available
# in a plain lua subprocess. We stub it with a pure-Lua shim that:
#   - executes the command via io.popen
#   - mimics cmd.exec's "raise on non-zero exit" contract
#
# The stub is registered in package.loaded under "cmd" and "file" so
# `require("cmd")` / `require("file")` inside lib/lock.lua resolve to it.
run_lock_lua() {
  "$LUA_BIN" -e "
    -- Stub: minimal cmd.exec replica for test environment.
    local cmd_stub = {}
    function cmd_stub.exec(command)
        local handle = io.popen(command .. '; echo __EXIT__\$?', 'r')
        local out = handle:read('*a')
        handle:close()
        -- Parse the trailing __EXIT__<code>
        local body, code = out:match('^(.-)__EXIT__(%d+)%s*\$')
        code = tonumber(code) or 0
        if code ~= 0 then
            error('Command failed with status ' .. code .. ': ' .. body)
        end
        return body
    end
    package.loaded['cmd'] = cmd_stub

    -- Stub: minimal file.exists replica (lib/lock.lua uses file.exists).
    local file_stub = {}
    function file_stub.exists(path)
        local f = io.open(path, 'r')
        if f then f:close(); return true end
        -- Fall back to a shell stat for directories.
        local h = io.popen('[ -e \"' .. path .. '\" ] && echo y || echo n')
        local r = h:read('*a'); h:close()
        return r:match('^y') ~= nil
    end
    package.loaded['file'] = file_stub

    local Lock = dofile('$LIB_DIR/lock.lua')
    $1
  "
}

# ------------------------------------------------------------------
# read_pid
# ------------------------------------------------------------------

@test "read_pid returns nil when lock directory missing" {
  run run_lock_lua "print(tostring(Lock.read_pid('$LOCK')))"
  [ "$status" -eq 0 ]
  [ "$output" = "nil" ]
}

@test "read_pid returns nil when pid file missing" {
  mkdir -p "$LOCK"
  run run_lock_lua "print(tostring(Lock.read_pid('$LOCK')))"
  [ "$status" -eq 0 ]
  [ "$output" = "nil" ]
}

@test "read_pid returns nil for malformed (non-digit) content" {
  mkdir -p "$LOCK"
  printf 'hello world\n' > "$LOCK/pid"
  run run_lock_lua "print(tostring(Lock.read_pid('$LOCK')))"
  [ "$status" -eq 0 ]
  [ "$output" = "nil" ]
}

@test "read_pid returns nil for injection attempts" {
  mkdir -p "$LOCK"
  printf '1; rm -rf /tmp/evil\n' > "$LOCK/pid"
  run run_lock_lua "print(tostring(Lock.read_pid('$LOCK')))"
  [ "$status" -eq 0 ]
  [ "$output" = "nil" ]
}

@test "read_pid strips trailing whitespace" {
  mkdir -p "$LOCK"
  printf '12345\n' > "$LOCK/pid"
  run run_lock_lua "print(Lock.read_pid('$LOCK'))"
  [ "$status" -eq 0 ]
  [ "$output" = "12345" ]
}

# ------------------------------------------------------------------
# is_stale
# ------------------------------------------------------------------

@test "is_stale returns false when lock does not exist" {
  run run_lock_lua "print(tostring(Lock.is_stale('$LOCK')))"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "is_stale returns true when lock exists without pid file" {
  mkdir -p "$LOCK"
  run run_lock_lua "print(tostring(Lock.is_stale('$LOCK')))"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "is_stale returns true for dead PID" {
  mkdir -p "$LOCK"
  # 2999999 is well above typical PID ranges (Linux default max ~32768,
  # macOS configurable; pick big enough to be reliably absent).
  printf '2999999\n' > "$LOCK/pid"
  run run_lock_lua "print(tostring(Lock.is_stale('$LOCK')))"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "is_stale returns false for alive PID" {
  mkdir -p "$LOCK"
  # PID 1 (launchd / init) is always alive on any unix host.
  printf '1\n' > "$LOCK/pid"
  run run_lock_lua "print(tostring(Lock.is_stale('$LOCK')))"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "is_stale returns true for malformed pid file (treated as orphan)" {
  mkdir -p "$LOCK"
  printf 'not-a-pid\n' > "$LOCK/pid"
  run run_lock_lua "print(tostring(Lock.is_stale('$LOCK')))"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

# ------------------------------------------------------------------
# try_acquire
# ------------------------------------------------------------------

@test "try_acquire returns 'acquired' and writes pid when lock is free" {
  run run_lock_lua "print(Lock.try_acquire('$LOCK'))"
  [ "$status" -eq 0 ]
  [ "$output" = "acquired" ]
  [ -d "$LOCK" ]
  [ -f "$LOCK/pid" ]
  grep -qE '^[0-9]+$' "$LOCK/pid"
}

@test "try_acquire returns 'held_alive' when lock is held by live process" {
  mkdir -p "$LOCK"
  printf '1\n' > "$LOCK/pid"
  run run_lock_lua "print(Lock.try_acquire('$LOCK'))"
  [ "$status" -eq 0 ]
  [ "$output" = "held_alive" ]
}

@test "try_acquire returns 'stale' when lock's PID is dead" {
  mkdir -p "$LOCK"
  printf '2999999\n' > "$LOCK/pid"
  run run_lock_lua "print(Lock.try_acquire('$LOCK'))"
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
  # try_acquire must NOT reclaim automatically — caller's responsibility.
  [ -d "$LOCK" ]
}

@test "try_acquire returns 'stale' when lock has no pid file" {
  mkdir -p "$LOCK"
  run run_lock_lua "print(Lock.try_acquire('$LOCK'))"
  [ "$status" -eq 0 ]
  [ "$output" = "stale" ]
}

# ------------------------------------------------------------------
# reclaim / release
# ------------------------------------------------------------------

@test "reclaim removes the lock directory" {
  mkdir -p "$LOCK"
  printf '2999999\n' > "$LOCK/pid"
  run run_lock_lua "Lock.reclaim('$LOCK'); print('done')"
  [ "$status" -eq 0 ]
  [ ! -e "$LOCK" ]
}

@test "reclaim is safe on missing path" {
  run run_lock_lua "Lock.reclaim('$LOCK'); print('done')"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

@test "release removes the lock directory" {
  mkdir -p "$LOCK"
  printf '12345\n' > "$LOCK/pid"
  run run_lock_lua "Lock.release('$LOCK'); print('done')"
  [ "$status" -eq 0 ]
  [ ! -e "$LOCK" ]
}

@test "release is safe on missing path" {
  run run_lock_lua "Lock.release('$LOCK'); print('done')"
  [ "$status" -eq 0 ]
  [ "$output" = "done" ]
}

# ------------------------------------------------------------------
# full acquire → reclaim → re-acquire round-trip
# ------------------------------------------------------------------

@test "try_acquire rolls back mkdir if PID write fails" {
  # Regression for the acquired-but-no-PID race (self-review of #8):
  # if the PID write fails after a successful mkdir, a naive try_acquire
  # returns "acquired" with a pid-less lock on disk. A concurrent caller
  # then sees is_stale() == true, reclaims, and races into a duplicate
  # clone. Fix: detect the write failure, roll back the mkdir, report
  # "held_alive" so the caller sleeps and retries.
  #
  # Force the failure by making the lock path's parent read-only so that
  # `echo $PPID > $lock/pid` fails with EACCES even though `mkdir $lock`
  # succeeded.
  local lock="$BATS_TEST_TMPDIR/shiv-write-fail.lock"

  "$LUA_BIN" -e "
    local cmd_stub = {}
    function cmd_stub.exec(command)
        -- Make only the PID-write command fail.
        if command:find('echo %\$PPID') then
            error('Command failed with status 1: simulated write failure')
        end
        local handle = io.popen(command .. '; echo __EXIT__\$?', 'r')
        local out = handle:read('*a'); handle:close()
        local body, code = out:match('^(.-)__EXIT__(%d+)%s*\$')
        code = tonumber(code) or 0
        if code ~= 0 then
            error('Command failed with status ' .. code .. ': ' .. body)
        end
        return body
    end
    package.loaded['cmd'] = cmd_stub
    local file_stub = {}
    function file_stub.exists(path)
        local f = io.open(path, 'r')
        if f then f:close(); return true end
        local h = io.popen('[ -e \"' .. path .. '\" ] && echo y || echo n')
        local r = h:read('*a'); h:close()
        return r:match('^y') ~= nil
    end
    package.loaded['file'] = file_stub

    local Lock = dofile('$LIB_DIR/lock.lua')
    local state = Lock.try_acquire('$lock')
    if state ~= 'held_alive' then
        error('expected held_alive (rollback), got ' .. tostring(state))
    end
    -- The lock dir must have been cleaned up as part of the rollback.
    local f = io.open('$lock/pid', 'r')
    if f then f:close(); error('pid file should not exist after rollback') end
    print('ok')
  "
  # Sanity: lock dir should not persist.
  [ ! -d "$lock" ]
}

@test "stale lock can be reclaimed and re-acquired" {
  mkdir -p "$LOCK"
  printf '2999999\n' > "$LOCK/pid"
  run run_lock_lua "
    local s1 = Lock.try_acquire('$LOCK')
    if s1 ~= 'stale' then error('expected stale, got ' .. s1) end
    Lock.reclaim('$LOCK')
    local s2 = Lock.try_acquire('$LOCK')
    if s2 ~= 'acquired' then error('expected acquired, got ' .. s2) end
    print('ok')
  "
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
