-- NewSoundsWindow.lua
-- Intro.lua's little sibling for a RETURNING player (introSeen already
-- true - a genuinely fresh install gets the normal onboarding instead,
-- and never has anything "New" to show here anyway, per BackfillAddedAt's
-- own first-run rule in SoundRegistry.lua) - explicit request: the first
-- login after an update adds at least one genuinely new sound they
-- haven't been shown here before, a small popup lists exactly those so a
-- returning player can discover what's new without hunting for the New
-- tag pill themselves. Every sound here is clickable and always plays
-- SELF-only - this is for trying things out locally, never a broadcast.
-- Opt-out checkbox, plus a Settings button ("Latest Sound Updates") to
-- reopen or re-enable it anytime.

local ADDON_NAME, SB = ...

local WINDOW_W, WINDOW_H = 380, 460
local ROW_H, ROW_GAP = 34, 4
local popup
local rows = {}
local scrollWidget
local emptyText
local checkbox

-- Every soundID the popup system has ever accounted for - shown here at
-- some point, or already-existing before this feature shipped, so nothing
-- long-standing can retroactively surface here. Lazily created, same
-- pattern as SoundRegistry.lua's SB.db.knownSoundIDs.
local function SeenTable()
    SB.db.newSoundsPopupSeenIDs = SB.db.newSoundsPopupSeenIDs or {}
    return SB.db.newSoundsPopupSeenIDs
end

--- Every currently-registered soundID still within the New window
--- (SB:IsSoundNew - the exact same 48h window the tag pill uses,
--- SoundRegistry.lua), regardless of whether the popup has already
--- accounted for it - what the window actually displays, for both the
--- automatic first-login trigger and a manual reopen from Settings.
local function ComputeCurrentlyNew()
    local list = {}
    for soundID in pairs(SB.registry) do
        if SB:IsSoundNew(soundID) then
            table.insert(list, soundID)
        end
    end
    table.sort(list, function(a, b)
        return SB:GetSoundDisplayName(a) < SB:GetSoundDisplayName(b)
    end)
    return list
end

--- Subset of the above the popup has never shown before - only this one
--- decides whether the automatic login trigger actually fires; a manual
--- Settings reopen always shows the full current list instead (see below).
local function ComputeUnseenNew()
    local seen = SeenTable()
    local list = {}
    for _, soundID in ipairs(ComputeCurrentlyNew()) do
        if not seen[soundID] then table.insert(list, soundID) end
    end
    return list
end

-- Marks EVERY currently-registered soundID as accounted for, whether it
-- ended up shown or not - called once the window is actually shown, so a
-- later login or a manual reopen never lists the same batch again as
-- "new since your last update", and the automatic trigger stays quiet
-- until the NEXT genuinely new addition.
local function MarkAllAccountedFor()
    local seen = SeenTable()
    for soundID in pairs(SB.registry) do
        seen[soundID] = true
    end
end

local function AcquireRow(index)
    local row = rows[index]
    if row then return row end

    row = SB.CreateFrame("Button", nil, scrollWidget.content)
    row:SetSize(WINDOW_W - 40, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(index - 1) * (ROW_H + ROW_GAP))
    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    row:SetBackdropColor(0.01, 0.035, 0.075, (index % 2 == 0) and 0.78 or 0.58)
    row:SetBackdropBorderColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.32)
    row:RegisterForClicks("LeftButtonUp")

    local iconSlot = SB.Theme.CreateIconSlot(row, 26)
    iconSlot:SetPoint("LEFT", 6, 0)
    row.icon = iconSlot.texture

    local name = row:CreateFontString(nil, "OVERLAY")
    name:SetFontObject(SB.Fonts.HighlightSmall)
    name:SetPoint("LEFT", iconSlot, "RIGHT", 8, 0)
    name:SetPoint("RIGHT", -8, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    name:SetTextColor(unpack(SB.Theme.TEXT))
    row.name = name

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(SB.Theme.ACCENT[1], SB.Theme.ACCENT[2], SB.Theme.ACCENT[3], 0.14)

    -- Always SELF-only - explicit requirement: this is a local "try it
    -- out" click, never a broadcast to guild/friends, regardless of
    -- whatever the player's own Default Output Channel setting is (same
    -- reasoning/pattern as AnalyticsUI.lua's own row click).
    row:SetScript("OnClick", function(self)
        if self.soundID then SB:TriggerSound(self.soundID, "SELF") end
    end)
    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Try it out", 1, 0.82, 0)
        GameTooltip:AddLine("Plays for you only - never sent to anyone else.", 0.86, 0.90, 0.96, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    rows[index] = row
    return row
end

local function RefreshList()
    local list = ComputeCurrentlyNew()
    emptyText:SetShown(#list == 0)
    for i = 1, math.max(#list, #rows) do
        local row = AcquireRow(i)
        local soundID = list[i]
        if soundID then
            row.soundID = soundID
            row.icon:SetTexture(SB:GetSoundIcon(soundID))
            row.name:SetText(SB:GetSoundDisplayName(soundID))
            row:Show()
        else
            row.soundID = nil
            row:Hide()
        end
    end
    -- content's own OnSizeChanged (Theme.CreateScrollFrame) keeps the
    -- scrollbar thumb in sync automatically - nothing further needed here.
    scrollWidget.content:SetSize(WINDOW_W - 40, math.max(1, #list) * (ROW_H + ROW_GAP))
end

local function BuildPopup()
    if popup then return popup end

    popup = SB.CreateFrame("Frame", "SoundbookNewSoundsWindow", UIParent)
    popup:SetSize(WINDOW_W, WINDOW_H)
    popup:SetPoint("CENTER")
    popup:SetFrameStrata("DIALOG")
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
    popup:SetClampedToScreen(true)
    popup:SetToplevel(true)
    SB.Theme.Panel(popup)
    popup:Hide()
    tinsert(UISpecialFrames, "SoundbookNewSoundsWindow") -- Escape key closes it

    local title = popup:CreateFontString(nil, "OVERLAY")
    title:SetFontObject(SB.Fonts.NormalLarge)
    title:SetPoint("TOP", 0, -16)
    title:SetText("New Sounds")
    title:SetTextColor(1, 0.82, 0)

    local subtitle = popup:CreateFontString(nil, "OVERLAY")
    subtitle:SetFontObject(SB.Fonts.HighlightSmall)
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -6)
    subtitle:SetText("Added since your last update - give them a try.")
    subtitle:SetTextColor(unpack(SB.Theme.TEXT_DIM))

    local info = popup:CreateFontString(nil, "OVERLAY")
    info:SetFontObject(SB.Fonts.DisableSmall)
    info:SetPoint("TOP", subtitle, "BOTTOM", 0, -6)
    info:SetPoint("LEFT", 20, 0)
    info:SetPoint("RIGHT", -20, 0)
    info:SetJustifyH("CENTER")
    info:SetWordWrap(true)
    info:SetText("Click a sound to try it - it always plays just for you, never sent to your guild or friends.")
    info:SetTextColor(unpack(SB.Theme.TEXT_DIM))

    local closeBtn = SB.Theme.CreateCloseGlyph(popup, 18)
    closeBtn:SetPoint("TOPRIGHT", -8, -8)
    closeBtn:SetScript("OnClick", function() popup:Hide() end)

    -- Anchored to info's own bottom (not a fixed offset from the popup
    -- top) so however many lines the info text wraps to, the list always
    -- starts right below it with no gap or overlap.
    local listTop = SB.CreateFrame("Frame", nil, popup)
    listTop:SetPoint("TOPLEFT", info, "BOTTOMLEFT", 0, -10)
    listTop:SetPoint("RIGHT", -20, 0)
    listTop:SetHeight(1)

    checkbox = SB.Theme.CreateCheckbox(popup, "Don't show this for future updates", function(checked)
        SB.db.settings.newSoundsPopupOptOut = checked
    end)
    checkbox:SetPoint("BOTTOMLEFT", 20, 44)

    local closeButton = SB.Theme.CreateFlatButton(popup, "Close", 120, 24)
    closeButton:SetPoint("BOTTOM", 0, 14)
    closeButton:SetScript("OnClick", function() popup:Hide() end)

    -- Anchored TOP (below the info text, whatever it wrapped to) AND
    -- BOTTOM (above the checkbox) instead of a fixed height - fills
    -- whatever space actually remains between them regardless of exact
    -- pixel math elsewhere, so nothing can ever silently overlap.
    local sf = SB.Theme.CreateScrollFrame(popup)
    scrollWidget = sf
    sf.scroll:SetPoint("TOPLEFT", listTop, "BOTTOMLEFT", 0, -4)
    sf.scroll:SetPoint("RIGHT", -20, 0)
    sf.scroll:SetPoint("BOTTOM", checkbox, "TOP", 0, 10)

    emptyText = popup:CreateFontString(nil, "OVERLAY")
    emptyText:SetFontObject(SB.Fonts.Highlight)
    emptyText:SetPoint("CENTER", sf.scroll, "CENTER", 0, 0)
    emptyText:SetText("No new sounds right now - check back after the next update.")
    emptyText:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    emptyText:SetWidth(WINDOW_W - 60)
    emptyText:SetJustifyH("CENTER")
    emptyText:SetWordWrap(true)

    return popup
end

--- Rebuilds the list and shows the window right now - used both by the
--- real first-login trigger below and Settings' "Latest Sound Updates"
--- button. Always shows whatever's currently within the New window,
--- regardless of whether it's ever been shown before - a manual reopen is
--- meant to let you look again, not just the untouched-since-last-time set.
function SB:ShowNewSoundsWindow()
    BuildPopup()
    checkbox:SetChecked(SB.db.settings.newSoundsPopupOptOut and true or false)
    RefreshList()
    MarkAllAccountedFor()
    popup:Show()
end

-- Real first-login trigger - only for a returning player (introSeen
-- already true; a fresh install gets the normal Intro instead and has
-- nothing New to show here anyway) who hasn't opted out, and only when
-- there's actually at least one unseen New sound to show - an empty
-- popup would just be annoying. A few seconds after Intro's own 2s delay
-- so the two can never compete for attention even in the unusual case
-- both would apply.
SB:On("PLAYER_LOGIN", function()
    if not (SB.db and SB.db.settings) then return end
    if not SB.db.settings.introSeen then return end
    if SB.db.settings.newSoundsPopupOptOut then return end
    C_Timer.After(3, function()
        if not (SB.db and SB.db.settings) then return end
        if SB.db.settings.newSoundsPopupOptOut then return end
        if #ComputeUnseenNew() == 0 then return end
        SB:ShowNewSoundsWindow()
    end)
end)
