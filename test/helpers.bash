# Test helpers for vfox-shiv BATS tests

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Install the plugin locally under a given name for testing.
# Uses a fresh mise plugin link each time.
install_plugin() {
  local name="${1:-shiv}"
  mise plugins link --force "$name" "$PLUGIN_DIR" 2>/dev/null
}

# Uninstall the plugin.
uninstall_plugin() {
  local name="${1:-shiv}"
  mise plugins uninstall "$name" 2>/dev/null || true
}

# Create a temporary mise.toml with the given tools section.
# Sets TESTDIR and cd's into it.
# Usage: setup_mise_project '"shiv:shimmer" = "0.0.1-alpha"'
setup_mise_project() {
  local tools_lines="$1"
  TESTDIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$TESTDIR"
  cat > "$TESTDIR/mise.toml" <<EOF
[settings]
experimental = true

[tools]
$tools_lines
EOF
  cd "$TESTDIR"
  mise trust "$TESTDIR/mise.toml" 2>/dev/null
}

# Ensure the shiv backend clone exists at the expected ref.
# On fresh machines (CI), no bootstrap has happened yet. On existing machines,
# a previous vfox-shiv run may have bootstrapped an older shiv ref.
# Triggers bootstrap by installing a lightweight package.
ensure_bootstrap() {
  local shiv_path="${VFOX_SHIV_PATH:-$HOME/.local/share/mise/shiv-backend/shiv}"
  local expected_ref="${VFOX_SHIV_REF:-v0.5.1}"
  local current_ref=""

  if [ -d "$shiv_path/.git" ]; then
    current_ref=$(git -C "$shiv_path" describe --tags --exact-match HEAD 2>/dev/null || true)
  fi

  if [ ! -d "$shiv_path/.git" ] || [ "$current_ref" != "$expected_ref" ] || [ ! -f "$shiv_path/.vfox-shiv-deps-ready" ]; then
    local tmpdir="$BATS_TEST_TMPDIR/bootstrap-trigger"
    local data_dir="$BATS_TEST_TMPDIR/bootstrap-mise-data"
    local cfg_dir="$BATS_TEST_TMPDIR/bootstrap-mise-config"
    local sources_dir="$BATS_TEST_TMPDIR/bootstrap-shiv-sources"
    mkdir -p "$tmpdir" "$data_dir" "$cfg_dir" "$sources_dir"
    printf '{"empty":"KnickKnackLabs/empty"}\n' > "$sources_dir/empty.json"
    cat > "$tmpdir/mise.toml" <<MISE
[settings]
experimental = true
[tools]
"shiv:empty" = "latest"
MISE
    MISE_DATA_DIR="$data_dir" MISE_CONFIG_DIR="$cfg_dir" \
      mise trust "$tmpdir/mise.toml" 2>/dev/null
    MISE_DATA_DIR="$data_dir" MISE_CONFIG_DIR="$cfg_dir" \
      mise plugins link --force shiv "$PLUGIN_DIR" 2>/dev/null
    (
      cd "$tmpdir"
      VFOX_SHIV_PATH="$shiv_path" SHIV_SOURCES_DIR="$sources_dir" VFOX_SHIV_SKIP_TAG_FETCH=1 \
        MISE_DATA_DIR="$data_dir" MISE_CONFIG_DIR="$cfg_dir" \
        mise install
    )
  fi
}

# Suppress the git remote warning noise in test output
export MISE_QUIET=1
