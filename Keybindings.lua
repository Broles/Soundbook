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

------------------------------------------------------------------------
-- Keybinding Mode panel (Settings restructure) - the Main Soundbook's
-- Favourites view's own temporary mode for assigning/clearing bindings,
-- replacing Settings.lua's old always-visible 20-button grid (removed
-- entirely - keybindings belong with Favourite management, not general
-- configuration). Built and swapped into main.content the same way
-- UI.lua's own Settings/Admin panels are (SB.BuildXPanel(main, content)),
-- so Library/Settings/Admin/Keybind-Mode visibility can never overlap.
-- Shows all SB.MAX_FAVOURITES slots at once, each paired with whichever
-- REAL sound currently occupies it (if any) - a binding is independent of
-- slot occupancy in the backend above, so an empty slot can still carry a
-- saved key for later, exactly as it always could.
------------------------------------------------------------------------

local ROW_H = 30
local ICON_SIZE = 22

local keybindPanel
local slotRows = {}
local activeCaptureSlot

local function StopKeybindCapture()
    if not activeCaptureSlot then return end
    local row = slotRows[activeCaptureSlot]
    activeCaptureSlot = nil
    if row then
        row.bindBtn:EnableKeyboard(false)
        row.bindBtn:SetScript("OnKeyDown", nil)
    end
end

local function RefreshKeybindSlotRow(slot)
    local row = slotRows[slot]
    if not row then return end
    local soundID = SB:GetFavourites()[slot]
    if soundID and SB.registry[soundID] then
        row.icon:SetTexture(SB:GetSoundIcon(soundID))
        row.icon:Show()
        row.nameText:SetText(SB:GetSoundDisplayName(soundID))
        row.nameText:SetTextColor(unpack(SB.Theme.TEXT))
    else
        row.icon:Hide()
        -- Explicit requirement: an empty slot still shows its position,
        -- clearly communicated as empty rather than left blank/ambiguous.
        row.nameText:SetText("Empty slot")
        row.nameText:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    end
    if slot ~= activeCaptureSlot then
        local key = SB:GetFavouriteHotkeyLabel(slot)
        row.bindBtn.label:SetText(key or "Not bound")
        row.clearBtn:SetShown(key ~= nil)
    end
end

local function RefreshAllKeybindSlotRows()
    for slot = 1, SB.MAX_FAVOURITES do RefreshKeybindSlotRow(slot) end
end

local function StartKeybindCapture(slot)
    StopKeybindCapture()
    activeCaptureSlot = slot
    local row = slotRows[slot]
    row.bindBtn.label:SetText("Press a key...")
    row.clearBtn:Hide()
    row.bindBtn:EnableKeyboard(true)
    row.bindBtn:SetScript("OnKeyDown", function(_, key)
        -- Wait for a real key - a modifier pressed alone isn't a usable
        -- standalone binding (same rule the old Settings grid used).
        if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL"
            or key == "LALT" or key == "RALT" or key == "UNKNOWN" then
            return
        end
        StopKeybindCapture()
        if key == "ESCAPE" then
            -- Explicit requirement: Escape cancels capture, it must never
            -- ambiguously delete the existing binding - Clear (below) is
            -- the only thing that does that.
            RefreshKeybindSlotRow(slot)
            return
        end
        local parts = {}
        if IsControlKeyDown() then table.insert(parts, "CTRL") end
        if IsAltKeyDown() then table.insert(parts, "ALT") end
        if IsShiftKeyDown() then table.insert(parts, "SHIFT") end
        table.insert(parts, key)
        SB:SetFavouriteKeybind(slot, table.concat(parts, "-"))
    end)
end

-- UI/UX polish pass (explicit requirement, section 10: "establish clear
-- columns for slot number, icon/name, binding and Clear action... use
-- consistent row spacing") - four columns on one baseline: slot # ->
-- icon+name -> binding -> Clear, now with a real left safe-area inset and
-- the same alternating-row-tint/separator language the Main Library's own
-- sound rows use (UI.lua's CreateEntryButton), so this reads as the same
-- product family instead of a bare, un-decorated list.
local ROW_PAD = 6

local function CreateKeybindSlotRow(parent, slot)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_H)

    local rowBg = row:CreateTexture(nil, "BACKGROUND")
    rowBg:SetAllPoints()
    rowBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    rowBg:SetVertexColor(0.015, 0.055, 0.12, (slot % 2 == 0) and 0.42 or 0.24)

    local separator = row:CreateTexture(nil, "BORDER")
    separator:SetPoint("BOTTOMLEFT", ROW_PAD, 0)
    separator:SetPoint("BOTTOMRIGHT", -ROW_PAD, 0)
    separator:SetHeight(1)
    separator:SetTexture("Interface\\Buttons\\WHITE8X8")
    separator:SetVertexColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.18)

    local slotLabel = row:CreateFontString(nil, "OVERLAY")
    slotLabel:SetFontObject(SB.Fonts.DisableSmall)
    slotLabel:SetPoint("LEFT", ROW_PAD, 0)
    slotLabel:SetWidth(20)
    slotLabel:SetJustifyH("LEFT")
    slotLabel:SetText(tostring(slot))
    slotLabel:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    row.slotLabel = slotLabel

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("LEFT", slotLabel, "RIGHT", SB.Theme.LAYOUT.GAP_S, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon

    -- Explicit clear action, separate from the binding button itself -
    -- required so a bound slot can be unbound without ambiguity (Escape
    -- during capture only cancels, it never deletes - see StartKeybindCapture).
    local clearBtn = SB.Theme.CreateSecondaryButton(row, "Clear", 46, 20)
    clearBtn:SetPoint("RIGHT", -ROW_PAD, 0)
    clearBtn:SetScript("OnClick", function()
        StopKeybindCapture()
        SB:SetFavouriteKeybind(slot, nil)
    end)
    row.clearBtn = clearBtn

    local bindBtn = SB.Theme.CreateFlatButton(row, "Not bound", 110, 22)
    bindBtn:SetPoint("RIGHT", clearBtn, "LEFT", -SB.Theme.LAYOUT.GAP_S, 0)
    row.bindBtn = bindBtn
    bindBtn:SetScript("OnClick", function()
        if activeCaptureSlot == slot then
            StopKeybindCapture()
            RefreshKeybindSlotRow(slot)
        else
            StartKeybindCapture(slot)
        end
    end)

    local nameText = row:CreateFontString(nil, "OVERLAY")
    nameText:SetFontObject(SB.Fonts.HighlightSmall)
    nameText:SetPoint("LEFT", icon, "RIGHT", SB.Theme.LAYOUT.GAP_S, 0)
    nameText:SetPoint("RIGHT", bindBtn, "LEFT", -SB.Theme.LAYOUT.GAP_M, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    row.nameText = nameText

    return row
end

-- Same width-recompute pattern the rest of this addon uses for a
-- ScrollFrame's content (single TOPLEFT anchor + explicit SetWidth, never
-- a second RIGHT-edge anchor on the scroll child itself - see UI.lua's
-- RefreshLibraryImpl for why that breaks as soon as it's actually
-- scrolled). Rows are ordinary children of that content frame, not the
-- scroll child WoW owns, but are still kept on the same explicit-width
-- discipline for consistency.
local function ReflowKeybindRows(sf)
    local w = math.max(220, (sf.scroll:GetWidth() or 300) - 12)
    sf.content:SetWidth(w)
    for slot = 1, SB.MAX_FAVOURITES do
        if slotRows[slot] then slotRows[slot]:SetWidth(w) end
    end
end

function SB.BuildKeybindModePanel(main, content)
    if keybindPanel then return keybindPanel end
    keybindPanel = CreateFrame("Frame", "SoundbookKeybindModePanel", main)
    keybindPanel:SetAllPoints(content)
    keybindPanel:Hide()

    -- UI/UX polish pass: no second in-panel title any more - the Main
    -- toolbar's own context header ("< Library" + "Keybindings", see
    -- UI.lua's RefreshMainWindow) already names this screen using the
    -- ONE shared title treatment every screen uses, so a second
    -- "Favourite Keybindings" heading directly below it was pure
    -- duplication and part of what made "the instruction text, title and
    -- Done button compete visually" (explicit requirement, section 10).
    -- Done keeps its own safe-area inset (LAYOUT.SAFE_INSET, not a bare
    -- 8) instead of doubling as a de facto second header row.
    local L = SB.Theme.LAYOUT
    local doneBtn = SB.Theme.CreatePrimaryButton(keybindPanel, "Done", 90, L.CONTROL_H)
    doneBtn:SetPoint("TOPRIGHT", -L.SAFE_INSET, -L.SAFE_INSET)
    keybindPanel.doneBtn = doneBtn

    local hint = keybindPanel:CreateFontString(nil, "OVERLAY")
    hint:SetFontObject(SB.Fonts.DisableSmall)
    hint:SetPoint("TOPLEFT", keybindPanel, "TOPLEFT", L.SAFE_INSET, -L.SAFE_INSET)
    hint:SetPoint("RIGHT", doneBtn, "LEFT", -L.GAP_M, 0)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetText("Click a slot's binding, then press the key combination - Escape cancels without changing it.")
    keybindPanel.hint = hint

    local sf = SB.Theme.CreateScrollFrame(keybindPanel)
    sf.scroll:SetPoint("TOPLEFT", keybindPanel, "TOPLEFT", L.SAFE_INSET - 8, -(L.SAFE_INSET + L.CONTROL_H + L.GAP_M))
    sf.scroll:SetPoint("BOTTOMRIGHT", -(L.SAFE_INSET + 2), L.SAFE_INSET)
    sf.content:SetPoint("TOPLEFT", 0, 0)
    sf.content:SetWidth(1)

    for slot = 1, SB.MAX_FAVOURITES do
        local row = CreateKeybindSlotRow(sf.content, slot)
        row:SetPoint("TOPLEFT", 0, -(slot - 1) * ROW_H)
        slotRows[slot] = row
    end
    sf.content:SetHeight(SB.MAX_FAVOURITES * ROW_H)

    local function Reflow() ReflowKeybindRows(sf) end
    sf.scroll:SetScript("OnSizeChanged", Reflow)
    Reflow()

    keybindPanel:SetScript("OnShow", RefreshAllKeybindSlotRows)
    keybindPanel:SetScript("OnHide", StopKeybindCapture)

    SB:On("FAV_KEYBIND_CHANGED", function()
        if keybindPanel:IsShown() then RefreshAllKeybindSlotRows() end
    end)
    SB:On("FAVOURITES_CHANGED", function()
        if keybindPanel:IsShown() then RefreshAllKeybindSlotRows() end
    end)

    return keybindPanel
end
