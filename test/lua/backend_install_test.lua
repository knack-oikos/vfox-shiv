test("dependency install retries with all GitHub token env vars scrubbed", function()
    local commands = {}
    local cmd_module = {
        exec = function(command)
            table.insert(commands, command)
            if command:find("env %-u GITHUB_TOKEN %-u GH_TOKEN %-u MISE_GITHUB_TOKEN") then
                return "scrubbed ok"
            end
            error("inherited token rejected")
        end,
    }
    load_backend_install(cmd_module)

    with_env({
        GITHUB_TOKEN = false,
        GH_TOKEN = false,
        MISE_GITHUB_TOKEN = "bad-token",
    }, function()
        install_shiv_dependencies("/tmp/shiv", "/bin/mise")
    end)

    assert_equal(#commands, 2)
    assert_not_contains(commands[1], "env -u GITHUB_TOKEN -u GH_TOKEN -u MISE_GITHUB_TOKEN")
    assert_contains(commands[2], "env -u GITHUB_TOKEN -u GH_TOKEN -u MISE_GITHUB_TOKEN")
end)

test("dependency install reports both inherited and scrubbed failures", function()
    local cmd_module = {
        exec = function(command)
            if command:find("env %-u GITHUB_TOKEN %-u GH_TOKEN %-u MISE_GITHUB_TOKEN") then
                error("scrubbed failed")
            end
            error("inherited failed")
        end,
    }
    load_backend_install(cmd_module)

    with_env({
        GITHUB_TOKEN = "bad-token",
        GH_TOKEN = false,
        MISE_GITHUB_TOKEN = false,
    }, function()
        local ok, err = pcall(function()
            install_shiv_dependencies("/tmp/shiv", "/bin/mise")
        end)
        assert_falsey(ok)
        assert_contains(err, "Attempt with inherited GitHub token failed")
        assert_contains(err, "Retry without GitHub token env vars also failed")
    end)
end)

test("numeric minor install ref resolves to newest matching patch", function()
    load_backend_install({ exec = function() return "" end })

    local original = list_install_versions
    list_install_versions = function(tool, shiv_path)
        assert_equal(tool, "moving")
        assert_equal(shiv_path, "/tmp/shiv")
        return { "0.9.1", "0.9.3", "0.10.0" }
    end

    local ok, err = pcall(function()
        assert_equal(resolve_install_ref("moving", "0.9", "/tmp/shiv"), "v0.9.3")
    end)
    list_install_versions = original
    if not ok then
        error(err)
    end
end)

test("exact numeric install ref keeps its concrete version", function()
    load_backend_install({ exec = function() return "" end })
    assert_equal(resolve_install_ref("moving", "0.9.3", "/tmp/shiv"), "v0.9.3")
end)
