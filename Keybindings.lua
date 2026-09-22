-- Keybindings.lua
--
-- Custom, fully in-addon keybind system for the first
-- SB.KEYBIND_FAV_SLOT_COUNT Favourite slots - NOT Blizzard's native
-- Bindings.xml. That route was tried first (Bindings.xml + BINDING_NAME_*/
-- BINDING_HEADER_* globals, the standard approach) and abandoned after
-- being confirmed live, repeatedly, that this specific client build throws
-- "Unrecognized XML: Binding" and never registers a single <Binding>
-- element at all, regardless of the XML declaration, per-binding header
-- attribute, or binding count - so this addon owns the whole key-capture
-- and dispatch mechanism itself instead, via SetOverrideBindingClick.
--
-- SB.db.settings.favKeybinds[slot] = a raw WoW binding-key string ("CTRL-A"
-- etc. - the exact format GetBindingKey/SetOverrideBindingClick both use),
-- assigned through Settings.lua's own "click to bind" row per slot (see
-- SB:SetFavouriteKeybind below).

local ADDON_NAME, SB = ...

-- All SB.MAX_FAVOURITES (20) slots are bindable - explicit requirement.
SB.KEYBIND_FAV_SLOT_COUNT = SB.MAX_FAVOURITES

-- SetOverrideBindingClick's override lives exactly as long as its owner
-- frame is shown - parenting to a dedicated frame that's ALWAYS shown
-- (never tied to any Soundbook window being open) makes these bindings
-- permanently active for the whole session, not just while some panel
-- happens to be visible.
local owner = CreateFrame("Frame", "SoundbookKeybindOwner", UIParent)
owner:Show()

for i = 1, SB.KEYBIND_FAV_SLOT_COUNT do
    local btn = CreateFrame("Button", "SoundbookFavKeyBind" .. i, UIParent)
    btn:Hide()
    btn:SetScript("OnClick", function()
        local soundID = SB:GetFavourites()[i]
        if soundID then
            SB:TriggerSound(soundID)
        end
    end)
end

-- Re-applies every saved keybind from scratch - called once at login and
-- after every individual change, simplest way to guarantee the live
-- override bindings can never drift out of sync with SB.db.settings.
-- favKeybinds (e.g. after a /reload, or a binding cleared elsewhere).
--
-- Explicit requirement: never touch bindings mid-combat - deferred to the
-- moment combat actually ends instead. SB.db.settings.favKeybinds itself
-- is still written immediately regardless (a plain table write, nothing
-- combat-protected about it) - only the real ClearOverrideBindings/
-- SetOverrideBindingClick registration below waits.
local pendingApplyAfterCombat = false

local function ApplyAllKeybinds()
    if InCombatLockdown and InCombatLockdown() then
        pendingApplyAfterCombat = true
        return
    end
    pendingApplyAfterCombat = false
    ClearOverrideBindings(owner)
    local saved = SB.db.settings.favKeybinds
    if not saved then return end
    for slot = 1, SB.KEYBIND_FAV_SLOT_COUNT do
        local key = saved[slot]
        if key and key ~= "" then
            SetOverrideBindingClick(owner, false, key, "SoundbookFavKeyBind" .. slot)
        end
    end
end

SB:On("COMBAT_END", function()
    if pendingApplyAfterCombat then ApplyAllKeybinds() end
end)

--- Assigns `key` (a raw binding-key string, or nil/"" to clear) to
--- `slot` (1..SB.KEYBIND_FAV_SLOT_COUNT). If `key` is already used by
--- another Soundbook favourite slot, that other slot is cleared first -
--- one physical key can only ever trigger one favourite at a time.
--- Returns the slot (if any) that got bumped, so the caller (Settings.lua)
--- can refresh that row's display too.
function SB:SetFavouriteKeybind(slot, key)
    if slot < 1 or slot > SB.KEYBIND_FAV_SLOT_COUNT then return end
    SB.db.settings.favKeybinds = SB.db.settings.favKeybinds or {}
    local saved = SB.db.settings.favKeybinds

    local bumpedSlot
    if key and key ~= "" then
        for otherSlot = 1, SB.KEYBIND_FAV_SLOT_COUNT do
            if otherSlot ~= slot and saved[otherSlot] == key then
                saved[otherSlot] = nil
                bumpedSlot = otherSlot
            end
        end
    end

    saved[slot] = (key and key ~= "") and key or nil
    ApplyAllKeybinds()
    SB:Fire("FAV_KEYBIND_CHANGED", slot, bumpedSlot)
    return bumpedSlot
end

function SB:GetFavouriteKeybind(slot)
    local saved = SB.db.settings.favKeybinds
    return saved and saved[slot] or nil
end

-- "CTRL-A" (WoW's own raw binding-key format) -> "CTRL+A" (what's shown
-- under a favourite's name in UI.lua's Favourites tab, and on Settings.lua's
-- own bind buttons).
function SB:GetFavouriteHotkeyLabel(slot)
    local key = SB:GetFavouriteKeybind(slot)
    if not key then return nil end
    return (key:gsub("-", "+"))
end

SB:On("DB_READY", ApplyAllKeybinds)
