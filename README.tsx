/** @jsxImportSource jsx-md */

import { readFileSync, readdirSync } from "fs";
import { join, resolve } from "path";

import {
  Heading, Paragraph, CodeBlock,
  Bold, Code, Link, LineBreak,
  Badge, Badges, Center, Section, Details,
} from "readme/src/components";

// ── Dynamic data ─────────────────────────────────────────────

const REPO_DIR = resolve(import.meta.dirname);

// Count tests
const testDir = join(REPO_DIR, "test");
const testFiles = readdirSync(testDir).filter((f) => f.endsWith(".bats"));
const testCount = testFiles.reduce((sum, f) => {
  const content = readFileSync(join(testDir, f), "utf-8");
  return sum + (content.match(/@test /g)?.length ?? 0);
}, 0);

// Read pinned shiv version from backend_install.lua
const installHook = readFileSync(join(REPO_DIR, "hooks/backend_install.lua"), "utf-8");
const shivRef = installHook.match(/shiv_ref.*or "([^"]+)"/)?.[1] ?? "v0.1.0";

// ── README ───────────────────────────────────────────────────

const readme = (
  <>
    <Center>
      <Heading level={1}>vfox-shiv</Heading>

      <Paragraph>
        <Bold>{`mise backend plugin for [shiv](https://github.com/KnickKnackLabs/shiv) packages.`}</Bold>
      </Paragraph>

      <Badges>
        <Badge label="plugin" value="lua" color="000080" logo="lua" logoColor="white" />
        <Badge label="runtime" value="mise" color="7c3aed" href="https://mise.jdx.dev" />
        <Badge label="tests" value={`${testCount} passing`} color="brightgreen" />
        <Badge label="shiv" value={shivRef} color="blue" href="https://github.com/KnickKnackLabs/shiv" />
        <Badge label="License" value="MIT" color="blue" href="LICENSE" />
      </Badges>
    </Center>

    <Paragraph>
      Declare <Link href="https://github.com/KnickKnackLabs/shiv">shiv</Link>{" "}
      packages as tool dependencies in <Code>mise.toml</Code> — with version
      pinning, per-project isolation, and zero setup beyond what mise already
      provides.
    </Paragraph>

    <CodeBlock lang="toml">{`[plugins]
shiv = "https://github.com/KnickKnackLabs/vfox-shiv"

[tools]
"shiv:shimmer" = "0.0.1-alpha"
"shiv:notes" = "latest"`}</CodeBlock>

    <Paragraph>
      One <Code>mise install</Code>. Plugin auto-installs from GitHub, shiv
      bootstraps in the background, packages clone and shim. The
      shiv-generated shim — with space-to-colon resolution, tab completions,
      and task map caching — is the binary mise puts on PATH.
    </Paragraph>

    <Section title="How it works">
      <Paragraph>
        The plugin is a thin adapter between{" "}
        <Link href="https://mise.jdx.dev/backend-plugin-development.html">
          mise's backend protocol
        </Link>{" "}
        and shiv's CLI. It doesn't reimplement shiv — it delegates.
      </Paragraph>

      <CodeBlock lang="text">{`mise install "shiv:shimmer@0.0.1-alpha"
  │
  ├─ BackendListVersions
  │    resolve "shimmer" → KnickKnackLabs/shimmer (via shiv sources)
  │    list git tags + branch pseudo-version → ["main", "0.0.1-alpha"]
  │
  ├─ BackendInstall
  │    ensure shiv is bootstrapped (pinned to ${shivRef})
  │    SHIV_PACKAGES_DIR=<install_path>/packages \\
  │    SHIV_BIN_DIR=<install_path>/bin \\
  │      mise -C <shiv> run install shimmer@v0.0.1-alpha
  │
  └─ BackendExecEnv
       PATH += <install_path>/bin`}</CodeBlock>

      <Paragraph>
        The plugin maintains its own shiv clone at{" "}
        <Code>~/.local/share/mise/shiv-backend/shiv/</Code>,
        pinned to <Code>{shivRef}</Code> for reproducibility. This is separate
        from any user-installed shiv — the plugin's build infrastructure
        doesn't change unless you deliberately update it.
      </Paragraph>

      <Paragraph>
        Version isolation comes from overriding shiv's path environment
        variables. Each version gets its own directory under mise's installs,
        so project A can pin <Code>shimmer@0.0.1-alpha</Code> while project B
        tracks the newest release with <Code>latest</Code>.
      </Paragraph>
    </Section>

    <Section title="Versions">
      <Paragraph>
        Git tags are listed as versions (<Code>v0.1.0</Code> →{" "}
        <Code>0.1.0</Code>). Mise's <Code>latest</Code> selector resolves to
        the newest listed release tag. A <Code>main</Code> pseudo-version is
        also listed for explicit default-branch tracking.
      </Paragraph>

      <CodeBlock lang="bash">{`# See available versions
mise ls-remote shiv:shimmer

# Pin to a tag
mise use shiv:shimmer@0.0.1-alpha

# Track the newest release
mise use shiv:shimmer@latest

# Track the default branch explicitly
mise use shiv:shimmer@main`}</CodeBlock>
    </Section>

    <Section title="Configuration">
      <Paragraph>
        The plugin reads package sources from{" "}
        <Code>~/.config/shiv/sources/</Code> (shared with your shiv
        installation) and falls back to the bundled{" "}
        <Code>sources.json</Code> in the bootstrapped shiv clone.
      </Paragraph>

      <Details summary="Environment variables">
        <CodeBlock lang="text">{`VFOX_SHIV_PATH     Path to plugin's shiv clone
                   Default: ~/.local/share/mise/shiv-backend/shiv

VFOX_SHIV_REF      Pinned shiv version for bootstrap
                   Default: ${shivRef}

VFOX_SHIV_REPO     Shiv repository URL
                   Default: https://github.com/KnickKnackLabs/shiv.git`}</CodeBlock>
      </Details>
    </Section>

    <Section title="Development">
      <CodeBlock lang="bash">{`git clone https://github.com/KnickKnackLabs/vfox-shiv.git
cd vfox-shiv && mise trust && mise install
mise run test`}</CodeBlock>
    </Section>

    <Center>
      <Paragraph>
        <LineBreak />
        MIT · Built with{" "}
        <Link href="https://github.com/KnickKnackLabs/readme">readme</Link>.
        {" "}Shiv gets a backend; mise gets a package manager.
      </Paragraph>
    </Center>
  </>
);

console.log(readme);
