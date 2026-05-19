--- Shell command helpers for vfox-shiv hooks.

local M = {}

--- Quote a value for safe use as a shell word.
--- @param value string
--- @return string
function M.quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Return a shell-quoted command path/name from an env override.
--- @param env_name string
--- @param fallback string
--- @return string
function M.command_from_env(env_name, fallback)
    local value = os.getenv(env_name)
    if not value or value == "" then
        value = fallback
    end
    return M.quote(value)
end

return M
