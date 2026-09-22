-- Macros.lua
--
-- Soundbook does not create or edit macros directly (that used the
-- protected CreateMacro/EditMacro API, which is blocked in combat, limited
-- by macro slot counts, and generally opaque to the user about what it did).
-- Instead, the Edit window shows a ready-to-use macro command inline that
-- the player copies into a macro they create themselves through WoW's own
-- macro UI - simpler, always available, and impossible to get into a
-- broken state.
--
-- The command always goes through the exact same central playback function
-- as every other trigger (see SoundPlayer.lua / Core.lua's slash handler):
--   /sb play 2::wir wipen
--
-- Optional output override - a trailing "::<Target>" segment - lets a
-- specific macro always send to one particular place instead of whatever
-- Settings -> Default Output Channel is currently set to:
--   /sb play German Memes::Auf Alkohol::Guild
--   /sb play German Memes::Auf Alkohol::Friends
--   /sb play German Memes::Auf Alkohol::Party
--   /sb play German Memes::Auf Alkohol::PlayerABC
-- Omitting it (the plain "/sb play <category::name>" form every macro used
-- before this existed) keeps behaving exactly as before - local play, then
-- SB:DispatchDefaultOutput's normal Default-Output-Channel logic.

local ADDON_NAME, SB = ...

-- Recognized channel keywords for the trailing "::<Target>" (case-
-- insensitive) - mirrors the GUILD/PARTY/RAID/FRIENDS/PLAYER: shape
-- Settings -> Default Output Channel already uses (Communication.lua/
-- Settings.lua's SB.ComputeOutputTargetOptions), just spelled the way a
-- human types it into a macro. Anything that doesn't match one of these is
-- treated as a player name instead.
local TARGET_KEYWORDS = {
    guild = "GUILD",
    party = "PARTY",
    raid = "RAID",
    friends = "FRIENDS",
    self = "SELF", -- local-only: still plays for you, never sent anywhere
}

-- "Guild" -> "GUILD", "Friends" -> "FRIENDS", "PlayerABC" -> "PLAYER:PlayerABC".
function SB.MacroTargetToOutputTarget(text)
    text = SB.TrimText(text)
    if not text or text == "" then return nil end
    local keyword = TARGET_KEYWORDS[text:lower()]
    if keyword then return keyword end
    if not SB.IsValidPlayerTarget(text) then return nil end
    return "PLAYER:" .. text
end

-- The reverse, for building a human-readable macro suffix out of a stored
-- output-target value ("GUILD" -> "Guild", "PLAYER:Foo" -> "Foo", "ALL"/nil
-- -> nil - no suffix, the default/omitted form).
function SB.OutputTargetToMacroTarget(target)
    if not target or target == "ALL" or not SB.IsValidOutputTarget(target) then return nil end
    local playerName = target:match("^PLAYER:(.+)$")
    if playerName then return playerName end
    -- "RAID" is the merged Raid/Party target (see SB.ResolveGroupChannel,
    -- Communication.lua) - the macro preview shown to the player follows
    -- whichever of the two is actually live right now, same as every other
    -- Raid/Party display in the addon. "PARTY" only still appears here as a
    -- defensive fallback for a stray pre-merge saved value.
    if target == "RAID" or target == "PARTY" then
        return SB.ResolveGroupChannel and SB.ResolveGroupChannel() == "PARTY" and "Party" or "Raid"
    end
    for word, code in pairs(TARGET_KEYWORDS) do
        if code == target then
            return word:sub(1, 1):upper() .. word:sub(2)
        end
    end
    return nil
end

-- `target` is an output-target value (see above) - nil/"ALL" produces the
-- plain, suffix-free macro.
function SB:GetMacroString(soundID, target)
    if not SB.registry[soundID] then return nil end
    local suffix = SB.OutputTargetToMacroTarget(target)
    if suffix then
        return "/sb play " .. soundID .. "::" .. suffix
    end
    return "/sb play " .. soundID
end

-- Splits a raw "/sb play" argument into (soundID, target). Tries the whole
-- string as a sound id FIRST - this is what keeps every macro that existed
-- before this feature (and any sound name that happens to itself contain
-- "::") resolving exactly as before, unchanged. Only when that fails does
-- it peel off a trailing "::<Target>" and re-check the remainder.
function SB.ParsePlayArg(rest)
    if type(rest) ~= "string" or #rest == 0 or #rest > 300 or rest:find("[%z\1-\31\127]") then return rest, nil end
    if SB.registry[rest] then
        return rest, nil
    end
    local base, targetText = rest:match("^(.*)::(.*)$")
    if base and SB.registry[base] then
        return base, SB.MacroTargetToOutputTarget(targetText)
    end
    return rest, nil
end
