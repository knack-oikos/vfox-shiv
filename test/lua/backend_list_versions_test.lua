local function decode_json_object(data)
    local parsed = {}
    for key, value in tostring(data):gmatch('"([^"]+)"%s*:%s*"([^"]+)"') do
        parsed[key] = value
    end
    return parsed
end

local function list_versions_with_env(env)
    local commands = {}
    local cmd_module = {
        exec = function(command)
            table.insert(commands, command)
            if command:find("raw.githubusercontent.com", 1, true) or command:find("example.invalid", 1, true) then
                error("remote sources unavailable")
            end
            if command:find("ls /tmp/sources/*.json", 1, true) then
                return "/tmp/sources/test.json\n"
            end
            if command:find("https://api.github.com/repos/KnickKnackLabs/shimmer/tags", 1, true) then
                return '[{"name":"v0.2.0"}]\n'
            end
            error("unexpected command: " .. command)
        end,
    }
    local file_module = {
        exists = function()
            return false
        end,
        read = function(path)
            if path == "/tmp/sources/test.json" then
                return '{"shimmer":"KnickKnackLabs/shimmer"}'
            end
            return "{}"
        end,
    }
    local json_module = { decode = decode_json_object }

    load_backend_list_versions(cmd_module, file_module, json_module)

    local result
    with_env(env, function()
        result = PLUGIN:BackendListVersions({ tool = "shimmer" })
    end)

    return result, commands
end

local function find_tags_command(commands)
    for _, command in ipairs(commands) do
        if command:find("/tags", 1, true) then
            return command
        end
    end
    error("no tags command recorded")
end

test("list versions authorizes GitHub tag fetch with MISE_GITHUB_TOKEN", function()
    local result, commands = list_versions_with_env({
        GITHUB_TOKEN = "",
        GH_TOKEN = "",
        MISE_GITHUB_TOKEN = "mise-token",
        SHIV_SOURCES_DIR = "/tmp/sources",
        VFOX_SHIV_SOURCES_URL = "https://example.invalid/sources.json",
        HOME = "/tmp/home",
        XDG_CACHE_HOME = "/tmp/cache",
    })

    assert_equal(result.versions[1], "main")
    assert_equal(result.versions[2], "0.2.0")

    local tags_command = find_tags_command(commands)
    assert_contains(tags_command, "Authorization: token")
    assert_contains(tags_command, "MISE_GITHUB_TOKEN")
    assert_not_contains(tags_command, "mise-token", "tag fetch command must not inline credential material")
end)

test("list versions omits auth header when token env vars are empty", function()
    local _, commands = list_versions_with_env({
        GITHUB_TOKEN = "",
        GH_TOKEN = "",
        MISE_GITHUB_TOKEN = "",
        SHIV_SOURCES_DIR = "/tmp/sources",
        VFOX_SHIV_SOURCES_URL = "https://example.invalid/sources.json",
        HOME = "/tmp/home",
        XDG_CACHE_HOME = "/tmp/cache",
    })

    local tags_command = find_tags_command(commands)
    assert_not_contains(tags_command, "Authorization: token")
end)
