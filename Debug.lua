-- Debug.lua
-- Central debug logging. Only prints when Settings > Debug Mode is enabled.

local ADDON_NAME, SB = ...

function SB:IsDebug()
    return SB.db and SB.db.settings and SB.db.settings.debug
end

function SB:Debug(fmt, ...)
    if not SB:IsDebug() then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    local frame = DEFAULT_CHAT_FRAME
    if frame then
        frame:AddMessage("|cff888888Soundbook Debug:|r " .. msg)
    end
end
