-- Validation.lua
-- Shared trust-boundary helpers for SavedVariables, companion addons,
-- macro targets, and multiplayer messages.

local ADDON_NAME, SB = ...

local function Trim(value)
    if type(value) ~= "string" then return nil end
    return value:match("^%s*(.-)%s*$")
end

local function HasControlCharacters(value)
    return value:find("[%z\1-\31\127]") ~= nil
end

local function IsFiniteNumber(value)
    return type(value) == "number" and value == value and value > -1e100 and value < 1e100
end

SB.TrimText = Trim
SB.IsFiniteNumber = IsFiniteNumber

function SB.IsSafeWireText(value, maxBytes)
    return type(value) == "string"
        and #value > 0
        and #value <= (maxBytes or 255)
        and not HasControlCharacters(value)
end

function SB.IsValidSoundName(value)
    value = Trim(value)
    if not value or value == "" or #value > 120 or HasControlCharacters(value) then return false end
    -- These characters either delimit the protocol or cannot form a safe
    -- relative sound-file path on the supported Windows client.
    if value:find("|", 1, true) or value:find("\\", 1, true) or value:find("/", 1, true) then return false end
    if value:find("..", 1, true) or value:find("[:<>\"?*]") then return false end
    return true
end

function SB.IsValidSoundID(value)
    if type(value) ~= "string" or #value == 0 or #value > 200 or HasControlCharacters(value) then return false end
    if value:find("|", 1, true) then return false end
    local category, name = value:match("^([^:]+)::(.+)$")
    if not category or #category > 40 or category:find("[\\/]") then return false end
    return SB.IsValidSoundName(name)
end

function SB.IsValidAddonFolder(value)
    if value == nil then return true end
    return type(value) == "string" and #value > 0 and #value <= 64
        and value:match("^[%w_%-]+$") ~= nil
end

function SB.IsValidPlayerTarget(value)
    value = Trim(value)
    if not value or value == "" or #value > 100 or HasControlCharacters(value) then return false end
    if value:find("|", 1, true) then return false end
    return true
end

local function NormalizedRealm(value)
    if type(value) ~= "string" then return nil end
    value = value:gsub("[%s%-]", "")
    if value == "" then return nil end
    return value:lower()
end

local function CurrentRealm()
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if not realm and GetRealmName then realm = GetRealmName() end
    return NormalizedRealm(realm) or "local"
end

-- Canonical identity used for security/rate-limit decisions. Display names
-- may omit a realm; identity keys never do, preventing two same-named
-- characters on different realms from sharing mutes, cooldowns, or admin
-- authority.
function SB.PlayerKey(name, realm)
    name = Trim(name)
    if not SB.IsValidPlayerTarget(name) then return nil end
    if not realm then
        local parsedName, parsedRealm = name:match("^([^%-]+)%-(.+)$")
        if parsedName and parsedRealm then
            name, realm = parsedName, parsedRealm
        end
    end
    local normalizedRealm = NormalizedRealm(realm) or CurrentRealm()
    return name:lower() .. "-" .. normalizedRealm
end

function SB.GetUnitFullName(unit)
    local name, realm
    if UnitFullName then name, realm = UnitFullName(unit) end
    if not name and UnitName then name, realm = UnitName(unit) end
    if not name then return nil end
    if realm and realm ~= "" and NormalizedRealm(realm) ~= CurrentRealm() then
        return name .. "-" .. realm
    end
    return name
end

-- Explicit request: NEVER show a realm suffix anywhere in the UI, full
-- stop - this used to only strip it for a SAME-realm player (a cross-
-- realm one still showed as "Name-Realm" everywhere, dropdowns included).
-- This is a display-only helper - SB.PlayerKey/the realm-qualified name
-- itself are still what's actually used for whispering/dedup/identity
-- everywhere that matters; only what a human sees changes here.
function SB.GetPlayerDisplayName(value)
    if type(value) ~= "string" then return value end
    local name = value:match("^([^%-]+)%-.+$")
    return name or value
end

function SB.IsValidOutputTarget(value)
    if value == "ALL" or value == "SELF" or value == "FRIENDS"
        or value == "GUILD" or value == "PARTY" or value == "RAID"
        -- Right-side broadcast tabs' combined recipient set (UI.lua's
        -- Guild/Raid/Friends multi-select flyouts) - the actual selection
        -- lives in SB.db.ui.outputRail.selected (one array per bucket),
        -- never encoded into this value itself; see Communication.lua's
        -- SB.ComputeEffectiveRecipients/SB:DispatchDefaultOutput.
        or value == "SUBSET" then
        return true
    end
    local player = type(value) == "string" and value:match("^PLAYER:(.+)$")
    return player ~= nil and SB.IsValidPlayerTarget(player)
end

