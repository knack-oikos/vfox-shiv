#!/usr/bin/env bats

setup() {
  load helpers
  install_plugin
  ensure_bootstrap
}

@test "shiv bootstrap creates clone at expected path" {
  local shiv_path="${VFOX_SHIV_PATH:-$HOME/.local/share/mise/shiv-backend/shiv}"
  [ -d "$shiv_path/.git" ]
}

@test "bootstrapped shiv is pinned to expected ref" {
  local shiv_path="${VFOX_SHIV_PATH:-$HOME/.local/share/mise/shiv-backend/shiv}"
  local expected_ref="${VFOX_SHIV_REF:-v0.5.3}"

  run git -C "$shiv_path" describe --tags --exact-match HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "$expected_ref" ]
}

@test "bootstrapped shiv has sources.json" {
  local shiv_path="${VFOX_SHIV_PATH:-$HOME/.local/share/mise/shiv-backend/shiv}"
  [ -f "$shiv_path/sources.json" ]
}

@test "bootstrapped shiv has runtime dependency marker" {
  local shiv_path="${VFOX_SHIV_PATH:-$HOME/.local/share/mise/shiv-backend/shiv}"
  [ -f "$shiv_path/.vfox-shiv-deps-ready" ]
}

# Isolated mise invocation helper for the lock tests below. Uses a fresh
# MISE_DATA_DIR (plugin/backend state) and MISE_CONFIG_DIR (skip the
# user's global config — otherwise ~/.config/mise/config.toml tools drag
# into the run). Writes stdout/stderr to $3.
_isolated_install() {
  local shiv_path="$1"
  local max_attempts="$2"
  local out="$3"

  local data_dir="$BATS_TEST_TMPDIR/mise-data"
  local cfg_dir="$BATS_TEST_TMPDIR/mise-config"
  local sources_dir="$BATS_TEST_TMPDIR/shiv-sources"
  local tmpdir="$BATS_TEST_TMPDIR/project"
  mkdir -p "$data_dir" "$cfg_dir" "$sources_dir" "$tmpdir"
  printf '{"empty":"KnickKnackLabs/empty"}\n' > "$sources_dir/empty.json"

  cat > "$tmpdir/mise.toml" <<MISE
[settings]
experimental = true
[tools]
"shiv:empty" = "latest"
MISE

  MISE_DATA_DIR="$data_dir" MISE_CONFIG_DIR="$cfg_dir" \
    mise trust "$tmpdir/mise.toml" >/dev/null 2>&1
  MISE_DATA_DIR="$data_dir" MISE_CONFIG_DIR="$cfg_dir" \
    mise plugins link --force shiv "$PLUGIN_DIR" >/dev/null 2>&1

  (
    cd "$tmpdir"
    unset VFOX_SHIV_PATH  # make sure the caller's export wins
    VFOX_SHIV_PATH="$shiv_path" VFOX_SHIV_LOCK_MAX_ATTEMPTS="$max_attempts" \
      SHIV_SOURCES_DIR="$sources_dir" VFOX_SHIV_SKIP_TAG_FETCH=1 \
      MISE_DATA_DIR="$data_dir" MISE_CONFIG_DIR="$cfg_dir" \
      mise install
  ) > "$out" 2>&1
}

@test "bootstrap respects MISE_DATA_DIR" {
  # Regression for vfox-shiv#7: the shiv clone + bootstrap lock must live
  # under MISE_DATA_DIR when set, not under HOME. Otherwise one hung mise
  # session blocks every other session on the machine via a global lock.
  # This test runs a clone directly into an isolated MISE_DATA_DIR — no
  # VFOX_SHIV_PATH override — so it's exercising the resolver's
  # MISE_DATA_DIR branch end-to-end, not _isolated_install above.
  local isolated="$BATS_TEST_TMPDIR/mise-isolated"
  local cfgdir="$BATS_TEST_TMPDIR/mise-config-path"
  local sources_dir="$BATS_TEST_TMPDIR/mise-data-dir-sources"
  local expected="$isolated/shiv-backend/shiv"
  mkdir -p "$isolated" "$cfgdir" "$sources_dir"
  printf '{"empty":"KnickKnackLabs/empty"}\n' > "$sources_dir/empty.json"

  local tmpdir="$BATS_TEST_TMPDIR/mise-data-dir-trigger"
  mkdir -p "$tmpdir"
  cat > "$tmpdir/mise.toml" <<MISE
[settings]
experimental = true
[tools]
"shiv:empty" = "latest"
MISE
  MISE_DATA_DIR="$isolated" MISE_CONFIG_DIR="$cfgdir" \
    mise trust "$tmpdir/mise.toml" 2>/dev/null
  MISE_DATA_DIR="$isolated" MISE_CONFIG_DIR="$cfgdir" \
    mise plugins link --force shiv "$PLUGIN_DIR" 2>/dev/null

  (
    cd "$tmpdir"
    unset VFOX_SHIV_PATH
    SHIV_SOURCES_DIR="$sources_dir" VFOX_SHIV_SKIP_TAG_FETCH=1 \
      MISE_DATA_DIR="$isolated" MISE_CONFIG_DIR="$cfgdir" \
      mise install 2>/dev/null
  ) || true

  [ -d "$expected/.git" ]
}

@test "bootstrap reclaims a stale lock with a dead PID" {
  # Regression for vfox-shiv#8: pre-existing lock held by a long-dead PID
  # must not wedge the bootstrap. Pre-create a lock with a dead PID and
  # expect `mise install` to reclaim it and proceed to a successful clone.
  local shiv_path="$BATS_TEST_TMPDIR/stale-lock-shiv"
  local lock_path="$shiv_path.lock"
  mkdir -p "$lock_path"
  printf '2999999\n' > "$lock_path/pid"

  _isolated_install "$shiv_path" 6 "$BATS_TEST_TMPDIR/stale.log" || true

  # Stale lock must have been reclaimed and the clone must have succeeded.
  [ -d "$shiv_path/.git" ]
  [ ! -e "$lock_path" ]
}

@test "bootstrap refuses to reclaim a lock held by a live PID" {
  # A lock with a live holder must NOT be reclaimed. Use PID 1 (launchd /
  # init) as a cheap always-alive stand-in. Low retry budget keeps the
  # test fast.
  local shiv_path="$BATS_TEST_TMPDIR/live-lock-shiv"
  local lock_path="$shiv_path.lock"
  mkdir -p "$lock_path"
  printf '1\n' > "$lock_path/pid"

  _isolated_install "$shiv_path" 2 "$BATS_TEST_TMPDIR/live.log" || true

  # The live lock must still be there (not reclaimed).
  [ -d "$lock_path" ]
  [ "$(cat $lock_path/pid)" = "1" ]
  # And the clone must NOT have happened.
  [ ! -d "$shiv_path/.git" ]
  # Error message should mention the recovery command.
  grep -q "Timed out waiting for shiv bootstrap lock" "$BATS_TEST_TMPDIR/live.log"
  grep -q "rm -rf" "$BATS_TEST_TMPDIR/live.log"
}
