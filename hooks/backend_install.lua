-- Shared libs: mise's vfox adds the plugin's lib/?.lua to package.path,
-- so require("name") loads lib/name.lua.
local Errors = require("errors")
local GitHubAuth = require("github_auth")
local Paths = require("path")
local Lock = require("lock")
local Shell = require("shell")

--- Installs a shiv package by delegating to shiv's install task.
--- Bootstraps shiv if not already present.
--- @param ctx BackendInstallCtx
--- @return BackendInstallResult
function PLUGIN:BackendInstall(ctx)
    local cmd = require("cmd")
    local tool = ctx.tool
    local version = ctx.version
    local install_path = ctx.install_path

    if not tool or tool == "" then
        error("Tool name cannot be empty")
    end
    if not version or version == "" then
        error("Version cannot be empty")
    end
    if not install_path or install_path == "" then
        error("Install path cannot be empty")
    end

    -- Ensure shiv is bootstrapped
    local shiv_path = ensure_shiv(tool)

    -- Create isolated shiv environment pointing at mise's install_path
    local shiv_env = {
        SHIV_PACKAGES_DIR = install_path .. "/packages",
        SHIV_BIN_DIR = install_path .. "/bin",
        SHIV_CONFIG_DIR = install_path .. "/config",
        SHIV_CACHE_DIR = install_path .. "/cache",
    }

    -- Build env string for the command
    local env_prefix = ""
    for k, v in pairs(shiv_env) do
        env_prefix = env_prefix .. k .. "='" .. v .. "' "
    end

    -- Multiple shiv:* tools can be installed in parallel by one `mise install`.
    -- The delegated shiv task may itself run nested `mise install` for package
    -- dependencies. On macOS mise 2026.6.0, repeated/concurrent nested installs
    -- can race or fail while rebuilding runtime symlinks. Serialize this shared
    -- delegated phase, but allow descendant shiv installs from the same package
    -- install to reenter the lock.
    local install_lock_path = shiv_path .. ".install.lock"
    with_lock(install_lock_path, "VFOX_SHIV_INSTALL_LOCK_MAX_ATTEMPTS", "shiv package install", function(lock_owner)
        -- Sync remote sources.json into bundled shiv so it knows about new packages.
        -- Keep this inside the install lock because every package install writes the
        -- same bundled sources.json file.
        sync_bundled_sources(shiv_path)

        local ref = resolve_install_ref(tool, version, shiv_path)
        local tool_spec = tool .. "@" .. ref

        -- Delegate to shiv install via mise. The outer exec provides shiv's
        -- already-installed runtime tools on PATH; the inner run skips another
        -- auto-install/symlink rebuild for those tools.
        local mise_bin = find_mise()
        local quoted_mise = Shell.quote(mise_bin)
        local quoted_shiv_path = Shell.quote(shiv_path)
        local install_cmd = env_prefix .. shiv_mise_env(tool) .. install_lock_env(lock_owner) .. quoted_mise .. " -C " .. quoted_shiv_path ..
            " exec --no-deps -- " .. quoted_mise .. " -C " .. quoted_shiv_path ..
            " run --skip-tools -q install " .. Shell.quote(tool_spec)

        local ok, result = pcall(cmd.exec, install_cmd)
        if not ok then
            error("shiv install failed for " .. tool_spec .. ": " .. Errors.clean_error(tostring(result)))
        end
    end)

    return {}
end

--- Resolve the ref passed to shiv install.
---
--- Normally mise resolves selectors before BackendInstall, so a minor-stream
--- pin such as `0.3` arrives here as `0.3.1`. GitHub macOS runners with mise
--- 2026.6.0 have been observed passing the raw partial version through. Make
--- install robust by resolving numeric partials here too.
--- @param tool string
--- @param version string
--- @param shiv_path string
--- @return string
function resolve_install_ref(tool, version, shiv_path)
    if version == "latest" or version == "main" then
        return version
    end
    if version:match("^%d") then
        return "v" .. resolve_numeric_version(tool, version, shiv_path)
    end
    return version
end

--- Resolve a numeric partial version to the newest matching release version.
--- @param tool string
--- @param version string
--- @param shiv_path string
--- @return string
function resolve_numeric_version(tool, version, shiv_path)
    -- Exact patch/pre-release pins already point at one concrete tag.
    if not (version:match("^%d+$") or version:match("^%d+%.%d+$")) then
        return version
    end

    local versions = list_install_versions(tool, shiv_path)
    local prefix = version .. "."
    local matches = {}
    for _, candidate in ipairs(versions) do
        if candidate:sub(1, #prefix) == prefix then
            table.insert(matches, candidate)
        end
    end

    if #matches == 0 then
        error(
            "Could not resolve shiv:" .. tool .. "@" .. version ..
            " to a concrete release tag. Expected a matching tag like v" .. version .. ".x; " ..
            "GitHub tag fetch may have failed or no matching release exists."
        )
    end

    table.sort(matches, semver_less)
    return matches[#matches]
end

--- List release versions for install-time fallback resolution.
--- @param tool string
--- @param shiv_path string
--- @return table
function list_install_versions(tool, shiv_path)
    local cmd = require("cmd")
    local repo = resolve_install_repo(tool, shiv_path)
    if not repo then
        return {}
    end

    local auth_header = GitHubAuth.curl_auth_header()

    local tags_url = "https://api.github.com/repos/" .. repo .. "/tags"
    local ok, output = pcall(cmd.exec,
        curl_command() .. " -sf --max-time 10 " .. auth_header .. Shell.quote(tags_url))
    if not ok or not output or output == "" then
        error(
            "Could not fetch GitHub tags for shiv:" .. tool ..
            "; cannot resolve partial numeric version without release tags."
        )
    end

    local versions = {}
    for tag in output:gmatch('"name"%s*:%s*"([^"]+)"') do
        local version = tag:gsub("^v", "")
        table.insert(versions, version)
    end
    return versions
end

--- Resolve a shiv package name to a GitHub repo for install-time fallback.
--- @param tool string
--- @param shiv_path string
--- @return string|nil
function resolve_install_repo(tool, shiv_path)
    local cmd = require("cmd")
    local sources_dir = os.getenv("SHIV_SOURCES_DIR")
        or os.getenv("XDG_CONFIG_HOME") and (os.getenv("XDG_CONFIG_HOME") .. "/shiv/sources")
        or ((os.getenv("HOME") or "") .. "/.config/shiv/sources")

    local ok, listing = pcall(cmd.exec, "ls " .. Shell.quote(sources_dir) .. "/*.json 2>/dev/null")
    if ok and listing and listing ~= "" then
        for file_path in listing:gmatch("[^\n]+") do
            local repo = lookup_install_source(file_path, tool)
            if repo then return repo end
        end
    end

    return lookup_install_source(shiv_path .. "/sources.json", tool)
end

--- Look up a package in a simple shiv sources JSON file.
--- @param file_path string
--- @param tool string
--- @return string|nil
function lookup_install_source(file_path, tool)
    local file = require("file")
    local ok, data = pcall(file.read, file_path)
    if not ok or not data or data == "" then
        return nil
    end
    for key, repo in data:gmatch('"([^"]+)"%s*:%s*"([^"]+)"') do
        if key == tool and repo ~= "" then
            return repo
        end
    end
    return nil
end

--- Return true when version a sorts before version b.
--- @param a string
--- @param b string
--- @return boolean
function semver_less(a, b)
    local an = numeric_parts(a)
    local bn = numeric_parts(b)
    for i = 1, 3 do
        local av = an[i] or 0
        local bv = bn[i] or 0
        if av ~= bv then
            return av < bv
        end
    end
    return a < b
end

--- Return numeric version components.
--- @param version string
--- @return table
function numeric_parts(version)
    local parts = {}
    for part in version:gmatch("%d+") do
        table.insert(parts, tonumber(part) or 0)
        if #parts == 3 then break end
    end
    return parts
end

--- Run a callback under a directory lock, reclaiming dead-holder locks.
---
--- The shiv install task runs package-local `mise install` for dependencies.
--- Those dependency installs can include more shiv:* tools, so this lock must be
--- reentrant for descendants of the process that already holds it. The holder
--- writes an owner token into the lock directory and passes that token to nested
--- mise commands via VFOX_SHIV_INSTALL_LOCK_OWNER.
--- @param lock_path string
--- @param max_attempts_env string
--- @param lock_name string
--- @param callback function
function with_lock(lock_path, max_attempts_env, lock_name, callback)
    local inherited_owner = inherited_lock_owner(lock_path)
    if inherited_owner then
        return callback(inherited_owner)
    end

    local cmd = require("cmd")
    local parent_dir = lock_path:match("(.+)/[^/]+$")
    if parent_dir then
        pcall(cmd.exec, "mkdir -p " .. Shell.quote(parent_dir))
    end

    local max_attempts = tonumber(os.getenv(max_attempts_env) or "120") or 120
    local got_lock = false
    for _ = 1, max_attempts do
        local state = Lock.try_acquire(lock_path)
        if state == "acquired" then
            got_lock = true
            break
        end
        if state == "stale" then
            Lock.reclaim(lock_path)
        else
            pcall(cmd.exec, "sleep 0.5")
        end
    end

    if not got_lock then
        error(
            "Timed out waiting for " .. lock_name .. " lock at " .. lock_path ..
            ".\nIf no other mise install is running, remove the stale lock:\n" ..
            "  rm -rf " .. Shell.quote(lock_path)
        )
    end

    local owner = new_lock_owner()
    local owner_ok, owner_err = pcall(cmd.exec,
        "printf '%s' " .. Shell.quote(owner) .. " > " .. Shell.quote(lock_owner_path(lock_path)))
    if not owner_ok then
        Lock.release(lock_path)
        error("Failed to write " .. lock_name .. " lock owner: " .. Errors.clean_error(tostring(owner_err)))
    end

    local ok, result = pcall(function()
        return callback(owner)
    end)
    Lock.release(lock_path)
    if not ok then
        error(result)
    end
    return result
end

--- Return the env prefix propagated to nested shiv dependency installs.
--- @param lock_owner string
--- @return string
function install_lock_env(lock_owner)
    return "VFOX_SHIV_INSTALL_LOCK_OWNER=" .. Shell.quote(lock_owner) .. " MISE_JOBS=1 "
end

--- Return the inherited lock owner when it matches the current lock directory.
--- @param lock_path string
--- @return string|nil
function inherited_lock_owner(lock_path)
    local owner = trim(os.getenv("VFOX_SHIV_INSTALL_LOCK_OWNER") or "")
    if owner == "" then
        return nil
    end

    local cmd = require("cmd")
    local ok, current = pcall(cmd.exec, "cat " .. Shell.quote(lock_owner_path(lock_path)) .. " 2>/dev/null")
    if ok and trim(current) == owner then
        return owner
    end
    return nil
end

--- Path of the owner token inside a lock directory.
--- @param lock_path string
--- @return string
function lock_owner_path(lock_path)
    return lock_path .. "/owner"
end

--- Create a best-effort unique owner token for reentrant install locking.
--- @return string
function new_lock_owner()
    local cmd = require("cmd")
    local ok, token = pcall(cmd.exec,
        "printf '%s:%s:%s' \"$PPID\" \"$$\" \"$(date +%s%N 2>/dev/null || date +%s)\"")
    if ok and token and trim(token) ~= "" then
        return trim(token)
    end
    return tostring(os.time()) .. ":" .. tostring(math.random(1000000000))
end

--- Sync the bundled shiv's sources.json with the remote version.
--- Uses the same cached remote sources as backend_list_versions.
--- Falls back silently if fetch fails (bundled sources still work).
function sync_bundled_sources(shiv_path)
    local cmd = require("cmd")
    local file = require("file")

    local sources_url = os.getenv("VFOX_SHIV_SOURCES_URL")
        or "https://raw.githubusercontent.com/KnickKnackLabs/shiv/main/sources.json"
    local target = shiv_path .. "/sources.json"

    -- Tests can set CURL=/path/to/mock because mise's vfox cmd.exec does not
    -- preserve PATH overlays reliably.
    pcall(cmd.exec, curl_command() .. " -sf --max-time 3 -o " .. Shell.quote(target) .. " " .. Shell.quote(sources_url))
end

--- Ensure the plugin's shiv clone exists and is at the pinned ref.
--- Bootstraps via git clone if not present.
--- @param tool string Tool being installed, excluded from nested mise calls
--- @return string Path to the shiv clone
function ensure_shiv(tool)
    local cmd = require("cmd")
    local file = require("file")

    local shiv_path = get_shiv_path()

    -- Pin to a specific shiv version for reproducibility
    local shiv_ref = os.getenv("VFOX_SHIV_REF") or "v0.5.3"
    local shiv_repo = os.getenv("VFOX_SHIV_REPO") or "https://github.com/KnickKnackLabs/shiv.git"

    if shiv_bootstrap_ready(shiv_path, shiv_ref) then
        return shiv_path
    end

    -- Bootstrap: clone shiv at the pinned ref and install its runtime deps.
    -- Multiple shiv:* tools may try to bootstrap simultaneously via
    -- parallel mise install. Use mkdir as an atomic lock, with PID-based
    -- staleness detection (see lib/lock.lua) so a crashed mise session
    -- doesn't wedge every future install for the full retry budget.
    local lock_path = shiv_path .. ".lock"
    local parent_dir = shiv_path:match("(.+)/[^/]+$")
    if parent_dir then
        pcall(cmd.exec, "mkdir -p '" .. parent_dir .. "'")
    end

    -- Retry budget: 30 × 0.5s = 15s. A shallow clone of shiv plus gum install
    -- takes <10s on a normal network; 15s is generous for a legitimate
    -- concurrent bootstrap and fast enough that users don't wonder if mise hung.
    -- Override for tests via VFOX_SHIV_LOCK_MAX_ATTEMPTS.
    local max_attempts = tonumber(os.getenv("VFOX_SHIV_LOCK_MAX_ATTEMPTS") or "30") or 30

    local got_lock = false
    for _ = 1, max_attempts do
        -- Check if another installer already finished
        if shiv_bootstrap_ready(shiv_path, shiv_ref) then
            return shiv_path
        end
        local state = Lock.try_acquire(lock_path)
        if state == "acquired" then
            got_lock = true
            break
        end
        if state == "stale" then
            -- Holder is dead — reclaim and retry immediately.
            Lock.reclaim(lock_path)
        else
            -- Lock held by a live installer — wait and retry.
            pcall(cmd.exec, "sleep 0.5")
        end
    end

    if not got_lock then
        -- Final check before giving up
        if shiv_bootstrap_ready(shiv_path, shiv_ref) then
            return shiv_path
        end
        error(
            "Timed out waiting for shiv bootstrap lock at " .. lock_path ..
            ".\nIf no other mise install is running, remove the stale lock:\n" ..
            "  rm -rf '" .. lock_path .. "'"
        )
    end

    -- We hold the lock. Re-check in case someone finished just before us.
    if shiv_bootstrap_ready(shiv_path, shiv_ref) then
        Lock.release(lock_path)
        return shiv_path
    end

    -- The plugin owns this clone. If the pinned ref changed, or if a previous
    -- bootstrap died before writing the dependency-ready marker, replace the old
    -- bootstrap so existing users pick up shiv fixes without manual cleanup.
    if file.exists(shiv_path .. "/.git/HEAD") then
        pcall(cmd.exec, "rm -rf '" .. shiv_path .. "'")
    end

    -- Clone shiv
    local clone_cmd = "git clone --quiet --branch " .. shiv_ref .. " --depth 1 --single-branch "
        .. shiv_repo .. " '" .. shiv_path .. "'"

    local ok, result = pcall(cmd.exec, clone_cmd)
    if not ok then
        Lock.release(lock_path)
        -- Clean up partial clone
        pcall(cmd.exec, "rm -rf '" .. shiv_path .. "'")
        error("Failed to bootstrap shiv: " .. tostring(result))
    end

    -- Trust the mise config so shiv's tasks can run
    local mise_bin = find_mise()
    pcall(cmd.exec, shiv_mise_env(tool) .. mise_bin .. " trust -q -C '" .. shiv_path .. "'")

    local deps_ok, deps_err = pcall(install_shiv_dependencies, shiv_path, mise_bin, tool)
    if deps_ok then
        pcall(cmd.exec, "touch " .. Shell.quote(shiv_dependencies_marker(shiv_path)))
    end
    Lock.release(lock_path)
    if not deps_ok then
        error(deps_err)
    end

    return shiv_path
end

--- Install shiv's runtime dependencies.
---
--- Prefer the ambient GitHub token when present so GitHub Actions avoids
--- anonymous API limits. If that token is invalid for github.com (for example
--- a GHE token inherited from a parent environment), retry once with the token
--- variables scrubbed.
--- @param shiv_path string
--- @param mise_bin string
--- @param tool string Tool being installed, excluded from this nested install
function install_shiv_dependencies(shiv_path, mise_bin, tool)
    local cmd = require("cmd")
    local install_cmd = shiv_mise_env(tool) .. mise_bin .. " install -q -C " .. Shell.quote(shiv_path)

    local install_ok, install_err = pcall(cmd.exec, install_cmd)
    if install_ok then
        return
    end

    if GitHubAuth.token_env_present() then
        local scrubbed_cmd = GitHubAuth.scrub_env_prefix() .. install_cmd
        local scrubbed_ok, scrubbed_err = pcall(cmd.exec, scrubbed_cmd)
        if scrubbed_ok then
            return
        end

        error(
            "Failed to install shiv dependencies (gum). " ..
            "Attempt with inherited GitHub token failed: " .. Errors.clean_error(tostring(install_err)) ..
            "\nRetry without GitHub token env vars also failed: " .. Errors.clean_error(tostring(scrubbed_err))
        )
    end

    error("Failed to install shiv dependencies (gum): " .. Errors.clean_error(tostring(install_err)))
end

--- Check whether the plugin-managed shiv clone and runtime deps are ready.
--- @param shiv_path string
--- @param shiv_ref string
--- @return boolean
function shiv_bootstrap_ready(shiv_path, shiv_ref)
    local file = require("file")
    return shiv_ready(shiv_path, shiv_ref) and file.exists(shiv_dependencies_marker(shiv_path))
end

--- Return the marker path written after shiv runtime deps install.
--- @param shiv_path string
--- @return string
function shiv_dependencies_marker(shiv_path)
    return shiv_path .. "/.vfox-shiv-deps-ready"
end

--- Check whether the plugin-managed shiv clone exists at the desired ref.
--- @param shiv_path string
--- @param shiv_ref string
--- @return boolean
function shiv_ready(shiv_path, shiv_ref)
    local file = require("file")
    if not file.exists(shiv_path .. "/.git/HEAD") then
        return false
    end

    local cmd = require("cmd")
    local ok, current = pcall(cmd.exec, "git -C '" .. shiv_path .. "' describe --tags --exact-match HEAD 2>/dev/null")
    if ok and trim(current) == shiv_ref then
        return true
    end

    local head_ok, head = pcall(cmd.exec, "git -C '" .. shiv_path .. "' rev-parse HEAD 2>/dev/null")
    local ref_ok, ref = pcall(cmd.exec, "git -C '" .. shiv_path .. "' rev-parse '" .. shiv_ref .. "^{commit}' 2>/dev/null")
    return head_ok and ref_ok and trim(head) == trim(ref)
end

--- Trim leading/trailing whitespace.
--- @param value string
--- @return string
function trim(value)
    return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

--- Find the mise binary.
--- @return string
function find_mise()
    local cmd = require("cmd")
    local ok, path = pcall(cmd.exec, "command -v mise")
    if ok and path and path ~= "" then
        return path:gsub("%s+$", "")
    end
    -- Fall back to common locations
    local home = os.getenv("HOME") or ""
    local candidates = {
        home .. "/.local/bin/mise",
        "/usr/local/bin/mise",
        "/usr/bin/mise",
    }
    for _, p in ipairs(candidates) do
        local file = require("file")
        if file.exists(p) then return p end
    end
    error("mise not found on PATH or in common locations")
end

--- Build an env prefix for nested mise calls into the shiv clone.
--- Points mise at mise.prod.toml (runtime-only dependencies) so dev/test
--- tools like bats aren't installed during bootstrap. This also prevents
--- the parent's MISE_OVERRIDE_CONFIG_FILENAMES from leaking in.
--- @param tool? string Tool being installed, excluded from the nested call
--- @return string
function shiv_mise_env(tool)
    local prefix = "MISE_OVERRIDE_CONFIG_FILENAMES=mise.prod.toml "
    if tool and tool ~= "" then
        prefix = prefix .. nested_disable_tools(tool)
    end
    return prefix
end

--- Exclude the tool being installed from nested mise calls.
---
--- mise takes its own flock on a tool before calling BackendInstall, and config
--- resolution is hierarchical: -C into the shiv clone does not shed the user's
--- global config. Without this the nested install reads that config back, sees
--- the tool it is already inside as missing, and blocks forever on the flock its
--- own ancestor holds. Appending preserves an outer install's exclusions.
--- @param tool string
--- @return string
function nested_disable_tools(tool)
    local qualified = backend_prefix() .. ":" .. tool
    local inherited = trim(os.getenv("MISE_DISABLE_TOOLS") or "")
    if inherited ~= "" then
        qualified = inherited .. "," .. qualified
    end
    return "MISE_DISABLE_TOOLS=" .. Shell.quote(qualified) .. " "
end

--- Return the backend prefix this plugin is served under.
--- mise names the backend after the plugin directory, so a plugin installed as
--- `shiv` answers for `shiv:<tool>` and must disable it under that same name.
--- @return string
function backend_prefix()
    local ok, dir = pcall(function() return RUNTIME.pluginDirPath end)
    if ok and dir then
        local name = tostring(dir):match("([^/]+)/*$")
        if name and name ~= "" then
            return name
        end
    end
    return "shiv"
end

--- Get the path to the plugin's shiv clone.
--- Delegates to lib/path.lua.
--- @return string
function get_shiv_path()
    return Paths.get_shiv_path()
end

--- Get shell-quoted curl command, honoring tests' CURL override.
--- @return string
function curl_command()
    return Shell.command_from_env("CURL", "curl")
end
