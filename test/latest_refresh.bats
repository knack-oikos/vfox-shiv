#!/usr/bin/env bats

setup() {
  load helpers
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$XDG_CACHE_HOME/mise/shiv-backend"

  install_plugin
  setup_fake_shiv
  setup_mock_curl
  setup_latest_project

  # The suite intentionally shares one isolated Mise root. Keep this fixture's
  # fake package versions independent without creating another state boundary.
  mise uninstall --all shiv:moving >/dev/null 2>&1 || true
}

setup_fake_shiv() {
  export VFOX_SHIV_PATH="$BATS_TEST_TMPDIR/fake-shiv"
  export VFOX_SHIV_REF="vtest"
  export VFOX_SHIV_INSTALL_LOG="$BATS_TEST_TMPDIR/fake-shiv-install.log"

  mkdir -p "$VFOX_SHIV_PATH/.mise/tasks"
  git -C "$VFOX_SHIV_PATH" init -q -b main
  git -C "$VFOX_SHIV_PATH" config user.name "vfox-shiv test"
  git -C "$VFOX_SHIV_PATH" config user.email "test@example.com"
  git -C "$VFOX_SHIV_PATH" config commit.gpgsign false
  git -C "$VFOX_SHIV_PATH" config tag.gpgSign false

  cat > "$VFOX_SHIV_PATH/mise.toml" <<'MISE'
[settings]
quiet = true
task_output = "interleave"
MISE
  cp "$VFOX_SHIV_PATH/mise.toml" "$VFOX_SHIV_PATH/mise.prod.toml"

  cat > "$VFOX_SHIV_PATH/.mise/tasks/install" <<'TASK'
#!/usr/bin/env bash
set -euo pipefail

spec="${1:?spec}"
printf '%s\n' "$spec" >> "${VFOX_SHIV_INSTALL_LOG:?}"

name="${spec%@*}"
mkdir -p "${SHIV_PACKAGES_DIR:?}/$name" "${SHIV_BIN_DIR:?}"
cat > "$SHIV_BIN_DIR/$name" <<SHIM
#!/usr/bin/env bash
echo "$spec"
SHIM
chmod +x "$SHIV_BIN_DIR/$name"
TASK
  chmod +x "$VFOX_SHIV_PATH/.mise/tasks/install"

  printf '{}\n' > "$VFOX_SHIV_PATH/sources.json"
  touch "$VFOX_SHIV_PATH/.vfox-shiv-deps-ready"
  git -C "$VFOX_SHIV_PATH" add .
  git -C "$VFOX_SHIV_PATH" commit -qm init
  git -c tag.gpgSign=false -C "$VFOX_SHIV_PATH" tag vtest

  mise trust "$VFOX_SHIV_PATH/mise.toml" 2>/dev/null
  MISE_OVERRIDE_CONFIG_FILENAMES=mise.prod.toml mise trust -C "$VFOX_SHIV_PATH" 2>/dev/null
}

setup_mock_curl() {
  export VFOX_SHIV_SOURCES_URL="https://mock.local/sources.json"
  export VFOX_SHIV_TAG_STATE="$BATS_TEST_TMPDIR/tag-state"
  printf 'old\n' > "$VFOX_SHIV_TAG_STATE"

  local mock_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail

output=""
url=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output="$2"
      shift 2
      ;;
    --max-time|-H)
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

case "$url" in
  https://mock.local/sources.json)
    body='{"moving":"Acme/moving"}'
    ;;
  https://api.github.com/repos/Acme/moving/tags)
    case "$(cat "${VFOX_SHIV_TAG_STATE:?}")" in
      old)
        body='[{"name":"v0.9.3"}]'
        ;;
      new)
        body='[{"name":"v0.9.4"},{"name":"v0.9.3"}]'
        ;;
      *)
        echo "unknown tag state" >&2
        exit 22
        ;;
    esac
    ;;
  *)
    echo "unexpected curl URL: $url" >&2
    exit 22
    ;;
esac

if [ -n "$output" ]; then
  printf '%s\n' "$body" > "$output"
else
  printf '%s\n' "$body"
fi
CURL
  chmod +x "$mock_bin/curl"
  export CURL="$mock_bin/curl"
}

setup_latest_project() {
  export PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$PROJECT_DIR"
  cat > "$PROJECT_DIR/mise.toml" <<MISE
[settings]
experimental = true

[tools]
"shiv:moving" = "latest"
MISE
  mise trust "$PROJECT_DIR/mise.toml" 2>/dev/null
}

@test "latest install resolves to the newest release tag" {
  (
    cd "$PROJECT_DIR"
    env -u GITHUB_TOKEN -u GH_TOKEN mise install --force 'shiv:moving@latest'
  )

  run tail -n 1 "$VFOX_SHIV_INSTALL_LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "moving@v0.9.3" ]

  run bash -c 'cd "$PROJECT_DIR" && mise where shiv:moving@latest'
  [ "$status" -eq 0 ]
  [[ "$output" == */shiv-moving/0.9.3 ]]
}

@test "main is the explicit branch-tracking version" {
  (
    cd "$PROJECT_DIR"
    env -u GITHUB_TOKEN -u GH_TOKEN mise install --force 'shiv:moving@main'
  )

  run tail -n 1 "$VFOX_SHIV_INSTALL_LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "moving@main" ]

  run bash -c 'cd "$PROJECT_DIR" && mise where shiv:moving@main'
  [ "$status" -eq 0 ]
  [[ "$output" == */shiv-moving/main ]]
}

@test "install resolves raw minor stream when mise passes it through" {
  cat > "$PROJECT_DIR/mise.toml" <<MISE
[settings]
experimental = true

[tools]
"shiv:moving" = "0.9"
MISE
  mise trust "$PROJECT_DIR/mise.toml" 2>/dev/null

  (
    cd "$PROJECT_DIR"
    env -u GITHUB_TOKEN -u GH_TOKEN VFOX_SHIV_SKIP_TAG_FETCH=1 mise install
  )

  run tail -n 1 "$VFOX_SHIV_INSTALL_LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "moving@v0.9.3" ]
}

@test "explicit latest install does not stay on an older concrete install" {
  (
    cd "$PROJECT_DIR"
    env -u GITHUB_TOKEN -u GH_TOKEN mise install --force 'shiv:moving@0.9.3'
  )

  run tail -n 1 "$VFOX_SHIV_INSTALL_LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "moving@v0.9.3" ]

  run bash -c 'cd "$PROJECT_DIR" && mise where shiv:moving@0.9.3'
  [ "$status" -eq 0 ]
  [[ "$output" == */shiv-moving/0.9.3 ]]

  printf 'new\n' > "$VFOX_SHIV_TAG_STATE"

  (
    cd "$PROJECT_DIR"
    env -u GITHUB_TOKEN -u GH_TOKEN mise install --force 'shiv:moving@latest'
  )

  run tail -n 1 "$VFOX_SHIV_INSTALL_LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "moving@v0.9.4" ]

  run bash -c 'cd "$PROJECT_DIR" && mise where shiv:moving@latest'
  [ "$status" -eq 0 ]
  [[ "$output" == */shiv-moving/0.9.4 ]]
}
