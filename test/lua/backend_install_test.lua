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

test("install lock env propagates owner and serializes nested mise", function()
    load_backend_install({ exec = function() return "" end })

    local env = install_lock_env("owner-token")
    assert_contains(env, "VFOX_SHIV_INSTALL_LOCK_OWNER='owner-token'")
    assert_contains(env, "MISE_JOBS=1 ")
end)

test("with_lock passes owner token to callback", function()
    local commands = {}
    local cmd_module = {
        exec = function(command)
            table.insert(commands, command)
            if command:find("^printf '%%s:%%s:%%s'") then
                return "owner-token\n"
            end
            return ""
        end,
    }
    load_backend_install(cmd_module)

    local callback_owner
    local result
    with_env({ VFOX_SHIV_INSTALL_LOCK_OWNER = false }, function()
        result = with_lock("/tmp/vfox-shiv-install.lock", "VFOX_TEST_LOCK_MAX_ATTEMPTS", "test install", function(owner)
            callback_owner = owner
            return "done"
        end)
    end)

    assert_equal(result, "done")
    assert_equal(callback_owner, "owner-token")
    local log = table.concat(commands, "\n")
    assert_contains(log, "mkdir '/tmp/vfox-shiv-install.lock' 2>/dev/null")
    assert_contains(log, "printf '%s' 'owner-token' > '/tmp/vfox-shiv-install.lock/owner'")
    assert_contains(log, "rm -rf '/tmp/vfox-shiv-install.lock'")
end)

test("with_lock is reentrant for matching inherited owner", function()
    local commands = {}
    local cmd_module = {
        exec = function(command)
            table.insert(commands, command)
            if command:find("^cat '/tmp/vfox%-shiv%-install%.lock/owner'") then
                return "owner-token\n"
            end
            error("unexpected command: " .. command)
        end,
    }
    load_backend_install(cmd_module)

    local callback_owner
    local result
    with_env({ VFOX_SHIV_INSTALL_LOCK_OWNER = "owner-token" }, function()
        result = with_lock("/tmp/vfox-shiv-install.lock", "VFOX_TEST_LOCK_MAX_ATTEMPTS", "test install", function(owner)
            callback_owner = owner
            return "nested-done"
        end)
    end)

    assert_equal(result, "nested-done")
    assert_equal(callback_owner, "owner-token")
    assert_equal(#commands, 1)
    assert_contains(commands[1], "cat '/tmp/vfox-shiv-install.lock/owner' 2>/dev/null")
end)

test("with_lock allows nested callbacks from same owner", function()
    local commands = {}
    local cmd_module = {
        exec = function(command)
            table.insert(commands, command)
            if command:find("^printf '%%s:%%s:%%s'") then
                return "owner-token\n"
            end
            if command:find("^cat '/tmp/vfox%-shiv%-install%.lock/owner'") then
                return "owner-token\n"
            end
            return ""
        end,
    }
    load_backend_install(cmd_module)

    local nested_owner
    with_env({ VFOX_SHIV_INSTALL_LOCK_OWNER = false }, function()
        with_lock("/tmp/vfox-shiv-install.lock", "VFOX_TEST_LOCK_MAX_ATTEMPTS", "test install", function(owner)
            with_env({ VFOX_SHIV_INSTALL_LOCK_OWNER = owner }, function()
                with_lock("/tmp/vfox-shiv-install.lock", "VFOX_TEST_LOCK_MAX_ATTEMPTS", "test install", function(owner_from_nested)
                    nested_owner = owner_from_nested
                end)
            end)
        end)
    end)

    assert_equal(nested_owner, "owner-token")
    local log = table.concat(commands, "\n")
    assert_contains(log, "cat '/tmp/vfox-shiv-install.lock/owner' 2>/dev/null")
    assert_contains(log, "rm -rf '/tmp/vfox-shiv-install.lock'")
end)

test("BackendInstall lets delegated dependency installs reenter lock", function()
    local nested_owner
    local saw_delegated_install = false
    local commands = {}
    local cmd_module = {
        exec = function(command)
            table.insert(commands, command)
            if command == "command -v mise" then
                return "/bin/mise\n"
            end
            if command:find("^git %-C '/tmp/shiv' describe") then
                return "v0.5.1\n"
            end
            if command:find("^printf '%%s:%%s:%%s'") then
                return "owner-token\n"
            end
            if command:find("^cat '/tmp/shiv%.install%.lock/owner'") then
                return "owner-token\n"
            end
            if command:find("run %-%-skip%-tools %-q install 'emails@v0%.6%.2'") then
                saw_delegated_install = true
                assert_contains(command, "VFOX_SHIV_INSTALL_LOCK_OWNER='owner-token'")
                assert_contains(command, "MISE_JOBS=1")
                with_env({ VFOX_SHIV_INSTALL_LOCK_OWNER = "owner-token" }, function()
                    with_lock("/tmp/shiv.install.lock", "VFOX_TEST_LOCK_MAX_ATTEMPTS", "test install", function(owner)
                        nested_owner = owner
                    end)
                end)
                return ""
            end
            return ""
        end,
    }
    local previous_file = package.loaded["file"]
    package.loaded["file"] = {
        exists = function(path)
            return path == "/tmp/shiv/.git/HEAD" or path == "/tmp/shiv/.vfox-shiv-deps-ready"
        end,
    }
    load_backend_install(cmd_module)

    with_env({ VFOX_SHIV_PATH = "/tmp/shiv", VFOX_SHIV_INSTALL_LOCK_OWNER = false }, function()
        PLUGIN:BackendInstall({ tool = "emails", version = "0.6.2", install_path = "/tmp/install" })
    end)
    package.loaded["file"] = previous_file

    assert_truthy(saw_delegated_install)
    assert_equal(nested_owner, "owner-token")
    local log = table.concat(commands, "\n")
    assert_contains(log, "printf '%s' 'owner-token' > '/tmp/shiv.install.lock/owner'")
    assert_contains(log, "cat '/tmp/shiv.install.lock/owner' 2>/dev/null")
    assert_contains(log, "rm -rf '/tmp/shiv.install.lock'")
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

test("numeric minor install ref fails clearly with no matching patch", function()
    load_backend_install({ exec = function() return "" end })

    local original = list_install_versions
    list_install_versions = function(tool, shiv_path)
        assert_equal(tool, "moving")
        assert_equal(shiv_path, "/tmp/shiv")
        return { "0.8.9", "0.10.0" }
    end

    local ok, err = pcall(function()
        resolve_install_ref("moving", "0.9", "/tmp/shiv")
    end)
    list_install_versions = original

    assert_falsey(ok)
    assert_contains(err, "Could not resolve shiv:moving@0.9 to a concrete release tag")
    assert_contains(err, "Expected a matching tag like v0.9.x")
end)

test("numeric minor install ref fails clearly when tag fetch fails", function()
    local cmd_module = {
        exec = function(command)
            if command:find("/tags", 1, true) then
                error("rate limited")
            end
            if command:find("ls '/tmp/sources'/*.json", 1, true) then
                return "/tmp/sources/test.json\n"
            end
            return ""
        end,
    }
    local previous_file = package.loaded["file"]
    package.loaded["file"] = {
        read = function(path)
            if path == "/tmp/sources/test.json" then
                return '{"moving":"Acme/moving"}'
            end
            return "{}"
        end,
        exists = function()
            return false
        end,
    }
    load_backend_install(cmd_module)

    local ok, err = pcall(function()
        with_env({ SHIV_SOURCES_DIR = "/tmp/sources" }, function()
            resolve_install_ref("moving", "0.9", "/tmp/shiv")
        end)
    end)
    package.loaded["file"] = previous_file

    assert_falsey(ok)
    assert_contains(err, "Could not fetch GitHub tags for shiv:moving")
    assert_contains(err, "cannot resolve partial numeric version without release tags")
end)

test("exact numeric install ref keeps its concrete version", function()
    load_backend_install({ exec = function() return "" end })
    assert_equal(resolve_install_ref("moving", "0.9.3", "/tmp/shiv"), "v0.9.3")
end)
