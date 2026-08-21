#!/usr/bin/env bash
# Establish the writable state boundary used by the public vfox-shiv test task.

_cleanup_mise_test_isolation() {
  if [ -n "${VFOX_SHIV_TEST_ISOLATION_ROOT:-}" ]; then
    rm -rf "$VFOX_SHIV_TEST_ISOLATION_ROOT"
  fi
}

setup_mise_test_isolation() {
  local repo_dir="${1:?repository root required}"
  local incoming_data_dir="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}"
  local default_data_dir="$HOME/.local/share/mise"
  local original_path="$PATH"
  local clean_path=""
  local isolation_root
  local entry
  local -a path_entries=()

  IFS=: read -r -a path_entries <<< "$original_path"
  for entry in "${path_entries[@]}"; do
    [ -n "$entry" ] || continue
    case "$entry" in
      "$incoming_data_dir/shims"|"$default_data_dir/shims") continue ;;
    esac
    clean_path="${clean_path:+$clean_path:}$entry"
  done

  isolation_root="$(mktemp -d "${TMPDIR:-/tmp}/vfox-shiv-test.XXXXXX")"
  export VFOX_SHIV_TEST_ISOLATION_ROOT="$isolation_root"
  trap _cleanup_mise_test_isolation EXIT

  export VFOX_SHIV_TEST_AMBIENT_MISE_SHIMS="$incoming_data_dir/shims"
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
}
