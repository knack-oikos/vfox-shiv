#!/usr/bin/env bats

setup() {
  load helpers
  install_plugin

  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  export SHIV_SOURCES_DIR="$BATS_TEST_TMPDIR/sources"
  mkdir -p "$XDG_CACHE_HOME/mise/shiv-backend" "$SHIV_SOURCES_DIR"
  cat > "$SHIV_SOURCES_DIR/test.json" <<'EOF'
{
  "readme": "KnickKnackLabs/readme",
  "shimmer": "KnickKnackLabs/shimmer"
}
EOF

  local mock_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url="${!#}"
case "$url" in
  https://api.github.com/repos/KnickKnackLabs/shimmer/tags)
    printf '[{"name":"v0.1.0"}]\n'
    ;;
  https://api.github.com/repos/KnickKnackLabs/readme/tags)
    printf '[]\n'
    ;;
  *)
    exit 22
    ;;
esac
EOF
  chmod +x "$mock_bin/curl"
  export CURL="$mock_bin/curl"
  export VFOX_SHIV_SOURCES_URL="http://localhost:1/sources.json"
}

@test "lists versions for a package with tags" {
  run mise ls-remote shiv:shimmer
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "0.1.0"
}

@test "version list includes main pseudo-version" {
  run mise ls-remote shiv:shimmer
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "main"
}

@test "version list does not expose latest as a backend version" {
  run mise ls-remote shiv:shimmer
  [ "$status" -eq 0 ]
  [[ "$output" != *latest* ]]
}

@test "package with no tags still exposes main" {
  run mise ls-remote shiv:readme
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "main"
}

@test "unknown package errors" {
  run mise ls-remote shiv:nonexistent-package-that-does-not-exist
  [ "$status" -ne 0 ]
}
