<div align="center">

# vfox-shiv

**mise backend plugin for [shiv](https://github.com/KnickKnackLabs/shiv) packages.**

![plugin: lua](https://img.shields.io/badge/plugin-lua-000080?style=flat&logo=lua&logoColor=white)
[![runtime: mise](https://img.shields.io/badge/runtime-mise-7c3aed?style=flat)](https://mise.jdx.dev)
![tests: 79 passing](https://img.shields.io/badge/tests-79%20passing-brightgreen?style=flat)
[![shiv: v0.2.8](https://img.shields.io/badge/shiv-v0.2.8-blue?style=flat)](https://github.com/KnickKnackLabs/shiv)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue?style=flat)](LICENSE)

</div>

Declare [shiv](https://github.com/KnickKnackLabs/shiv) packages as tool dependencies in `mise.toml` — with version pinning, per-project isolation, and zero setup beyond what mise already provides.

```toml
[plugins]
shiv = "https://github.com/KnickKnackLabs/vfox-shiv"

[tools]
"shiv:shimmer" = "0.0.1-alpha"
"shiv:notes" = "latest"
```

One `mise install`. Plugin auto-installs from GitHub, shiv bootstraps in the background, packages clone and shim. The shiv-generated shim — with space-to-colon resolution, tab completions, and task map caching — is the binary mise puts on PATH.

## How it works

The plugin is a thin adapter between [mise's backend protocol](https://mise.jdx.dev/backend-plugin-development.html) and shiv's CLI. It doesn't reimplement shiv — it delegates.

```text
mise install "shiv:shimmer@0.0.1-alpha"
  │
  ├─ BackendListVersions
  │    resolve "shimmer" → KnickKnackLabs/shimmer (via shiv sources)
  │    list git tags + branch pseudo-version → ["main", "0.0.1-alpha"]
  │
  ├─ BackendInstall
  │    ensure shiv is bootstrapped (pinned to v0.2.8)
  │    SHIV_PACKAGES_DIR=<install_path>/packages \
  │    SHIV_BIN_DIR=<install_path>/bin \
  │      mise -C <shiv> run install shimmer@v0.0.1-alpha
  │
  └─ BackendExecEnv
       PATH += <install_path>/bin
```

The plugin maintains its own shiv clone at `~/.local/share/mise/shiv-backend/shiv/`, pinned to `v0.2.8` for reproducibility. This is separate from any user-installed shiv — the plugin's build infrastructure doesn't change unless you deliberately update it.

Version isolation comes from overriding shiv's path environment variables. Each version gets its own directory under mise's installs, so project A can pin `shimmer@0.0.1-alpha` while project B tracks the newest release with `latest`.

## Versions

Git tags are listed as versions (`v0.1.0` → `0.1.0`). Mise's `latest` selector resolves to the newest listed release tag. A `main` pseudo-version is also listed for explicit default-branch tracking.

```bash
# See available versions
mise ls-remote shiv:shimmer

# Pin to a tag
mise use shiv:shimmer@0.0.1-alpha

# Track the newest release
mise use shiv:shimmer@latest

# Track the default branch explicitly
mise use shiv:shimmer@main
```

## Configuration

The plugin reads package sources from `~/.config/shiv/sources/` (shared with your shiv installation) and falls back to the bundled `sources.json` in the bootstrapped shiv clone.

<details>
<summary><b>Environment variables</b></summary>

```text
VFOX_SHIV_PATH     Path to plugin's shiv clone
                   Default: ~/.local/share/mise/shiv-backend/shiv

VFOX_SHIV_REF      Pinned shiv version for bootstrap
                   Default: v0.2.8

VFOX_SHIV_REPO     Shiv repository URL
                   Default: https://github.com/KnickKnackLabs/shiv.git
```

</details>

## Development

```bash
git clone https://github.com/KnickKnackLabs/vfox-shiv.git
cd vfox-shiv && mise trust && mise install
mise run test
```

<div align="center">

<br />

MIT · Built with [readme](https://github.com/KnickKnackLabs/readme). Shiv gets a backend; mise gets a package manager.

</div>
