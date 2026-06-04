-- Shared libs: mise's vfox implementation adds the plugin's lib/?.lua to
-- package.path, so require("name") loads lib/name.lua. See
-- jdx/mise crates/vfox/src/plugin.rs (set_paths).
local GitHubAuth = require("github_auth")
local Paths = require("path")
local Shell = require("shell")

--- Lists available versions (git tags) for a shiv package.
--- Resolves tool name to a GitHub repo via shiv's source files,
--- then queries the GitHub API for tags.
--- @param ctx BackendListVersionsCtx
--- @return BackendListVersionsResult
function PLUGIN:BackendListVersions(ctx)
    local cmd = require("cmd")
    local json = require("json")
    local tool = ctx.tool

    if not tool or tool == "" then
        error("Tool name cannot be empty")
    end

    -- Resolve tool name to GitHub repo slug
    local repo = resolve_repo(tool)
    if not repo then
        error("Package '" .. tool .. "' not found in any shiv source file")
    end

    -- List tags via GitHub API using curl.
    -- curl is always available; gh may not be on PATH inside mise's Lua sandbox.
    -- Tests can set CURL=/path/to/mock because mise's vfox cmd.exec does not
    -- preserve PATH overlays reliably.
    -- Pass GitHub token env for auth if available (avoids rate limits in CI).
    local versions = {}
    table.insert(versions, "main")
    if os.getenv("VFOX_SHIV_SKIP_TAG_FETCH") == "1" then
        return { versions = versions }
    end
    local auth_header = GitHubAuth.curl_auth_header()
    local tags_url = "https://api.github.com/repos/" .. repo .. "/tags"
    local ok, output = pcall(cmd.exec,
        curl_command() .. " -sf --max-time 10 " .. auth_header .. Shell.quote(tags_url))
    if ok and output and output ~= "" then
        -- Parse tag names in Lua instead of piping through jq so tests can
        -- inject CURL without also depending on the command environment's PATH.
        local tags = {}
        for tag in output:gmatch('"name"%s*:%s*"([^"]+)"') do
            -- Strip leading 'v' prefix for mise's version model
            local version = tag:gsub("^v", "")
            table.insert(tags, version)
        end

        -- Reverse so oldest is first (GitHub returns newest first; mise expects ascending order)
        for i = #tags, 1, -1 do
            table.insert(versions, tags[i])
        end
    end

    -- Do not append a literal "latest" version here. Mise treats `@latest` as
    -- a selector for the newest listed version; exposing "latest" as a real
    -- backend version can make stale concrete installs keep winning resolution.
    -- `main` is the explicit branch-tracking pseudo-version.
    return { versions = versions }
end

--- Resolve a tool name to a GitHub repo slug.
--- Resolution order:
---   1. Cached remote sources.json (TTL-based)
---   2. Fresh fetch from GitHub (on cache miss/stale, with timeout)
---   3. User's shiv sources dir (~/.config/shiv/sources/)
---   4. Plugin's bundled shiv sources.json
--- @param tool string
--- @return string|nil
function resolve_repo(tool)
    local cmd = require("cmd")

    -- 1. Check cached remote sources (fetches if stale)
    local cached = get_cached_remote_sources()
    if cached then
        local repo = lookup_in_table(cached, tool)
        if repo then return repo end
    end

    -- 2. Check user's shiv sources directory
    local sources_dir = os.getenv("SHIV_SOURCES_DIR")
        or os.getenv("XDG_CONFIG_HOME") and (os.getenv("XDG_CONFIG_HOME") .. "/shiv/sources")
        or (os.getenv("HOME") .. "/.config/shiv/sources")

    local ok, listing = pcall(cmd.exec, "ls " .. sources_dir .. "/*.json 2>/dev/null")
    if ok and listing and listing ~= "" then
        for file_path in listing:gmatch("[^\n]+") do
            local repo = lookup_in_source(file_path, tool)
            if repo then return repo end
        end
    end

    -- 3. Fall back to the plugin's bootstrapped shiv clone
    local shiv_path = get_shiv_path()
    local bundled = shiv_path .. "/sources.json"
    local repo = lookup_in_source(bundled, tool)
    if repo then return repo end

    return nil
end

--- Get cached remote sources, fetching if stale or missing.
--- Returns a parsed table on success, nil on failure.
--- @return table|nil
function get_cached_remote_sources()
    local file = require("file")
    local json = require("json")
    local cmd = require("cmd")

    local cache_path = get_cache_path()
    local ttl_seconds = tonumber(os.getenv("VFOX_SHIV_CACHE_TTL")) or 300

    -- Check if cache exists and is fresh
    if file.exists(cache_path) then
        local age = get_file_age(cache_path)
        if age and age < ttl_seconds then
            local ok, data = pcall(file.read, cache_path)
            if ok and data and data ~= "" then
                local parse_ok, parsed = pcall(json.decode, data)
                if parse_ok and parsed then
                    return parsed
                end
            end
        end
    end

    -- Cache is stale or missing — fetch from GitHub
    -- NOTE: http.get cannot be wrapped in pcall due to mise's Lua coroutine sandbox
    -- ("attempt to yield across metamethod/C-call boundary"). Use curl instead.
    local sources_url = get_sources_url()
    local ok, body = pcall(cmd.exec, curl_command() .. " -sf --max-time 3 " .. Shell.quote(sources_url))

    if ok and body and body ~= "" then
        local parse_ok, parsed = pcall(json.decode, body)
        if parse_ok and parsed then
            write_cache(cache_path, sources_url)
            return parsed
        end
    end

    return nil
end

--- Look up a tool name in a parsed sources table.
--- @param sources table
--- @param tool string
--- @return string|nil
function lookup_in_table(sources, tool)
    local repo = sources[tool]
    if repo and repo ~= "" then
        return repo
    end
    return nil
end

--- Look up a tool name in a single sources.json file.
--- @param file_path string
--- @param tool string
--- @return string|nil
function lookup_in_source(file_path, tool)
    local file = require("file")
    local json = require("json")

    local ok, data = pcall(file.read, file_path)
    if not ok or not data or data == "" then
        return nil
    end

    local parse_ok, parsed = pcall(json.decode, data)
    if not parse_ok or not parsed then
        return nil
    end

    return lookup_in_table(parsed, tool)
end

--- Get the age of a file in seconds.
--- @param path string
--- @return number|nil
function get_file_age(path)
    local cmd = require("cmd")
    -- stat -f %m gives mtime as epoch seconds on macOS
    -- stat -c %Y gives mtime as epoch seconds on Linux
    local stat_cmd = RUNTIME.osType == "darwin"
        and "stat -f %m '" .. path .. "'"
        or "stat -c %Y '" .. path .. "'"
    local ok, mtime_str = pcall(cmd.exec, stat_cmd)
    if ok and mtime_str then
        local cleaned = mtime_str:gsub("%s+$", "")
        local mtime = tonumber(cleaned)
        if mtime then
            return os.time() - mtime
        end
    end
    return nil
end

--- Get the cache file path for remote sources.
--- @return string
function get_cache_path()
    local home = os.getenv("HOME") or ""
    local cache_dir = os.getenv("XDG_CACHE_HOME")
        or (home .. "/.cache")
    return cache_dir .. "/mise/shiv-backend/sources.json"
end

--- Write remote sources to the cache file.
--- Re-downloads from the URL to avoid shell escaping issues with content.
--- @param path string
--- @param url string The URL to download from
function write_cache(path, url)
    local cmd = require("cmd")
    local dir = path:match("(.+)/[^/]+$")
    if dir then
        pcall(cmd.exec, "mkdir -p '" .. dir .. "'")
    end
    pcall(cmd.exec, curl_command() .. " -sf --max-time 3 -o " .. Shell.quote(path) .. " " .. Shell.quote(url))
end

--- Get the remote sources URL.
--- @return string
function get_sources_url()
    return os.getenv("VFOX_SHIV_SOURCES_URL")
        or "https://raw.githubusercontent.com/KnickKnackLabs/shiv/main/sources.json"
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
