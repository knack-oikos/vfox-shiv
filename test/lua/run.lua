#!/usr/bin/env lua

local repo_dir = assert(arg[1], "usage: run.lua <repo-dir>")
_G.REPO_DIR = repo_dir
_G.LIB_DIR = repo_dir .. "/lib"
_G.HOOKS_DIR = repo_dir .. "/hooks"

package.path = _G.LIB_DIR .. "/?.lua;" .. package.path

local tests = {}

function test(name, fn)
    table.insert(tests, { name = name, fn = fn })
end

function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. "\nexpected: " .. tostring(expected) .. "\nactual:   " .. tostring(actual), 2)
    end
end

function assert_truthy(value, message)
    if not value then
        error(message or "expected truthy value", 2)
    end
end

function assert_falsey(value, message)
    if value then
        error((message or "expected falsey value") .. "\nactual: " .. tostring(value), 2)
    end
end

function assert_contains(haystack, needle, message)
    if not tostring(haystack):find(needle, 1, true) then
        error((message or "missing expected text") .. "\nneedle: " .. needle .. "\nhaystack: " .. tostring(haystack), 2)
    end
end

function assert_not_contains(haystack, needle, message)
    if tostring(haystack):find(needle, 1, true) then
        error((message or "found unexpected text") .. "\nneedle: " .. needle .. "\nhaystack: " .. tostring(haystack), 2)
    end
end

function with_env(env, fn)
    local previous_getenv = os.getenv
    os.getenv = function(name)
        if env[name] ~= nil then
            if env[name] == false then
                return nil
            end
            return env[name]
        end
        return previous_getenv(name)
    end

    local ok, err = xpcall(fn, debug.traceback)
    os.getenv = previous_getenv
    if not ok then
        error(err, 0)
    end
end

function load_backend_install(cmd_module)
    package.loaded["cmd"] = cmd_module or package.loaded["cmd"]
    PLUGIN = {}
    dofile(_G.HOOKS_DIR .. "/backend_install.lua")
end

function load_backend_list_versions(cmd_module, file_module, json_module)
    package.loaded["cmd"] = cmd_module
    package.loaded["file"] = file_module
    package.loaded["json"] = json_module
    PLUGIN = {}
    RUNTIME = { osType = "darwin" }
    dofile(_G.HOOKS_DIR .. "/backend_list_versions.lua")
end

local test_files = {
    repo_dir .. "/test/lua/github_auth_test.lua",
    repo_dir .. "/test/lua/backend_install_test.lua",
    repo_dir .. "/test/lua/backend_list_versions_test.lua",
}

for _, file in ipairs(test_files) do
    dofile(file)
end

local passed = 0
local failed = 0

for _, case in ipairs(tests) do
    local ok, err = xpcall(case.fn, debug.traceback)
    if ok then
        passed = passed + 1
        print("ok - " .. case.name)
    else
        failed = failed + 1
        print("not ok - " .. case.name)
        print(err)
    end
end

print(string.format("%d passed, %d failed", passed, failed))

if failed > 0 then
    os.exit(1)
end
