--- GitHub API auth helpers shared by vfox-shiv hooks.

local M = {}

local TOKEN_ENV_VARS = {
    "GITHUB_TOKEN",
    "GH_TOKEN",
    "MISE_GITHUB_TOKEN",
}

--- Return true when an env var is set to a non-empty value.
--- @param name string
--- @return boolean
function M.env_present(name)
    local value = os.getenv(name)
    return value ~= nil and value ~= ""
end

--- Return true when any supported GitHub token env var is present.
--- @return boolean
function M.token_env_present()
    for _, name in ipairs(TOKEN_ENV_VARS) do
        if M.env_present(name) then
            return true
        end
    end
    return false
end

--- Return the curl auth header shell fragment, or an empty string when no token exists.
---
--- The token itself stays out of the command string. The shell expands the first
--- non-empty supported env var at execution time, so verbose mise logs do not
--- print credentials.
--- @return string
function M.curl_auth_header()
    if not M.token_env_present() then
        return ""
    end
    return [[-H "Authorization: token ${GITHUB_TOKEN:-${GH_TOKEN:-$MISE_GITHUB_TOKEN}}" ]]
end

--- Return an env prefix that scrubs supported GitHub token env vars.
--- @return string
function M.scrub_env_prefix()
    return "env -u GITHUB_TOKEN -u GH_TOKEN -u MISE_GITHUB_TOKEN "
end

return M
