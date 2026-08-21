#!/usr/bin/env bash
# Own the complete state boundary for the public vfox-shiv test command.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$test_dir/.." && pwd)"
bats_bin="$(command -v bats)"
export VFOX_SHIV_TEST_LUA_BIN="$(command -v lua)"

incoming_data_dir="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
default_data_dir="$HOME/.local/share/mise"
original_path="$PATH"
clean_path=""

IFS=: read -r -a path_entries <<< "$original_path"
for entry in "${path_entries[@]}"; do
  [ -n "$entry" ] || continue
  case "$entry" in
    "$incoming_data_dir/shims"|"$default_data_dir/shims") continue ;;
  esac
  clean_path="${clean_path:+$clean_path:}$entry"
done

isolation_root="$(mktemp -d "${TMPDIR:-/tmp}/vfox-shiv-test.XXXXXX")"
trap 'rm -rf "$isolation_root"' EXIT

export VFOX_SHIV_TEST_ISOLATION_ROOT="$isolation_root"
export VFOX_SHIV_TEST_AMBIENT_MISE_SHIMS="$incoming_data_dir/shims"
unset VFOX_SHIV_TEST_MOCK_BIN
export MISE_DATA_DIR="$isolation_root/mise-data"
export MISE_CACHE_DIR="$isolation_root/mise-cache"
export MISE_CONFIG_DIR="$isolation_root/mise-config"
export MISE_STATE_DIR="$isolation_root/mise-state"
export MISE_GLOBAL_CONFIG_FILE="$MISE_CONFIG_DIR/config.toml"
export MISE_IGNORED_CONFIG_PATHS="$HOME/.config/mise/config.toml"
export MISE_TRUSTED_CONFIG_PATHS="$repo_dir"
export MISE_AUTO_INSTALL=0

export XDG_CACHE_HOME="$isolation_root/xdg/cache"
export XDG_CONFIG_HOME="$isolation_root/xdg/config"
export XDG_DATA_HOME="$isolation_root/xdg/data"
export XDG_STATE_HOME="$isolation_root/xdg/state"
export SHIV_SOURCES_DIR="$isolation_root/shiv-sources"

unset MISE_CONFIG_FILE MISE_CONFIG_ROOT MISE_NO_CONFIG MISE_OVERRIDE_CONFIG_FILENAMES MISE_TASK_NAME
unset GITHUB_TOKEN GH_TOKEN MISE_GITHUB_TOKEN
unset CURL VFOX_SHIV_PATH VFOX_SHIV_REF VFOX_SHIV_REPO VFOX_SHIV_SOURCES_URL
unset VFOX_SHIV_CACHE_TTL VFOX_SHIV_SKIP_TAG_FETCH VFOX_SHIV_INSTALL_LOCK_OWNER
unset SHIV_PACKAGES_DIR SHIV_BIN_DIR SHIV_CONFIG_DIR SHIV_CACHE_DIR
export VFOX_SHIV_PATH="$MISE_DATA_DIR/shiv-backend/shiv"
export PATH="$MISE_DATA_DIR/shims${clean_path:+:$clean_path}"

mkdir -p \
  "$MISE_DATA_DIR" \
  "$MISE_CACHE_DIR" \
  "$MISE_CONFIG_DIR" \
  "$MISE_STATE_DIR" \
  "$XDG_CACHE_HOME" \
  "$XDG_CONFIG_HOME" \
  "$XDG_DATA_HOME" \
  "$XDG_STATE_HOME" \
  "$SHIV_SOURCES_DIR"
printf '# isolated vfox-shiv test config\n' > "$MISE_GLOBAL_CONFIG_FILE"

args=()
has_target=false
for arg in "$@"; do
  if [[ "$arg" != -* && "$arg" != *.bats && -f "$test_dir/$arg.bats" ]]; then
    args+=("$test_dir/$arg.bats")
    has_target=true
  else
    [[ "$arg" == *.bats || -d "$arg" ]] && has_target=true
    args+=("$arg")
  fi
done

if ! $has_target; then
  args+=("$test_dir/")
fi

"$bats_bin" "${args[@]}"
