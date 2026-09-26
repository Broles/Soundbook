-- NewSoundsWindow.lua
-- Intro.lua's little sibling for a RETURNING player (introSeen already
-- true - a genuinely fresh install gets the normal onboarding instead) -
-- shows the persisted "latest update batch" (SoundRegistry.lua's
-- SB:GetLatestSoundUpdateSoundIDs/SB.db.latestSoundUpdate), a small popup
-- listing whichever sounds the most recent Soundbook update actually
-- introduced. Every sound here is clickable and always plays SELF-only -
-- this is for trying things out locally, never a broadcast. Also carries
-- the New Sounds task's own Add/Remove Favourite controls per row.
--
-- Deliberately decoupled from the temporary "New" tag (SB:IsSoundNew,
-- SoundRegistry.lua's own 5-day addedAt window): that tag is short-lived
-- and stops early once a player has personally heard a sound enough, but
-- this window - and Settings' "Latest Sound Updates" button - must keep
-- showing the same batch indefinitely, long after every one of its
-- sounds has stopped being tagged "New". SB.db.latestSoundUpdate is the
-- one persistent record of "which sounds were the last update", replaced
-- wholesale whenever a later update introduces another batch (never
-- merged/archived - only the single most recent batch is ever kept).
--
-- Opt-out checkbox controls the AUTOMATIC first-login popup only
-- (SB.db.latestSoundUpdate.autoShown, set once the automatic trigger has
-- shown a given batch so it never repeats) - manual access from Settings'
-- "Latest Sound Updates" button always works regardless of the opt-out or
-- whether the automatic popup already fired for this batch.

local ADDON_NAME, SB = ...

local WINDOW_W, WINDOW_H = 380, 460
local ROW_H, ROW_GAP = 34, 4
local popup
local rows = {}
local scrollWidget
local emptyText
local checkbox

-- True only once a real batch has actually been recorded (SoundRegistry.
-- lua's BackfillAddedAt - never on a fresh install, never a manufactured
-- "whole current library" placeholder) - the one thing that decides
-- whether this window is allowed to open at all (explicit requirement:
-- never a blank popup when nothing has ever been recorded).
local function HasRecordedBatch()
    local batch = SB.db and SB.db.latestSoundUpdate
    return batch and type(batch.soundIDs) == "table" and #batch.soundIDs > 0
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

    -- Add/Remove Favourite - explicit requirement: far right of the row,
    -- vertically centred, existing Soundbook button styling (no new visual
    -- style), enough right padding to clear the row border. A real Button
    -- sitting on top of `row` (itself a Button) intercepts its own clicks
    -- before they ever reach row's own OnClick - the same "control sits on
    -- top of a clickable row without triggering the row's own click"
    -- pattern UI.lua's section-header Keybinds button already relies on -
    -- so this can never accidentally trigger the SELF-only preview below.
    local favBtn = SB.Theme.CreateFlatButton(row, "Add Favourite", 112, 22)
    favBtn:SetPoint("RIGHT", -8, 0)
    row.favBtn = favBtn

    local name = row:CreateFontString(nil, "OVERLAY")
    name:SetFontObject(SB.Fonts.HighlightSmall)
    name:SetPoint("LEFT", iconSlot, "RIGHT", 8, 0)
    name:SetPoint("RIGHT", favBtn, "LEFT", -8, 0)
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
    -- reasoning/pattern as AnalyticsUI.lua's own row click). SB:TriggerSound
    -- passing "SELF" as an explicit override already takes precedence over
    -- both the global Default Output setting AND any per-sound "Default
    -- Output" override (SB:ResolveOutputTarget checks the explicit
    -- override first), and SB:DispatchDefaultOutput returns immediately
    -- for target=="SELF" without sending anything - nothing here needs to
    -- duplicate that.
    --
    -- Explicit isolation requirement: this preview surface must behave
    -- like an exclusive one-sound-at-a-time player EVEN when the player's
    -- own "Allow overlapping sounds" setting is on - SB:PlaySound only
    -- self-stops when that setting is off. SB:StopAllSounds() is the same
    -- existing public stop path the Mini Soundbook's own Stop button and
    -- "/sb stop" already use - called explicitly here, every click,
    -- BEFORE the new preview starts, without touching the saved
    -- allowOverlap setting itself (still exactly what it was before and
    -- after this window is open/closed) or any other saved setting.
    row:SetScript("OnClick", function(self)
        if not self.soundID then return end
        SB:StopAllSounds()
        SB:TriggerSound(self.soundID, "SELF")
    end)
    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Try it out", 1, 0.82, 0)
        GameTooltip:AddLine("Plays for you only - never sent to anyone else.", 0.86, 0.90, 0.96, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Favourite action only - explicit requirement: never plays the sound,
    -- regardless of what the surrounding row's own OnClick does. Reuses
    -- the exact same Favourite functions the rest of the addon already
    -- uses (SB:AddFavourite/RemoveFavourite - first-empty-slot placement,
    -- no compaction, SB:Fire("FAVOURITES_CHANGED")) rather than touching
    -- SB.db.favourites directly - no second Favourite state, no duplicated
    -- slot logic. "Favourites are full" is detected BEFORE ever calling
    -- SB:AddFavourite (which would otherwise only report that failure to
    -- chat) so the Replace Favourite modal is the real, primary path for
    -- that case, not a fallback after a chat message.
    row.favBtn:SetScript("OnClick", function(self)
        local r = self:GetParent()
        if not r.soundID then return end
        if SB:IsFavourite(r.soundID) then
            SB:RemoveFavourite(r.soundID)
        elseif SB:GetFavouriteCount() >= SB.MAX_FAVOURITES then
            SB:ShowReplaceFavouriteWindow(r.soundID)
        else
            SB:AddFavourite(r.soundID)
        end
    end)

    rows[index] = row
    return row
end

-- Just the button label - called on every FAVOURITES_CHANGED while the
-- window is open (add/remove/replace, from this window or anywhere else
-- that touches Favourites) so a row always reflects the real, current
-- Favourite state without needing to reopen New Sounds. Deliberately NOT
-- RefreshList() - New Sounds membership itself never depends on Favourite
-- status, only the button label does.
local function RefreshFavButton(row)
    if not row.soundID then return end
    row.favBtn.label:SetText(SB:IsFavourite(row.soundID) and "Remove Favourite" or "Add Favourite")
end

local function RefreshAllFavButtons()
    for _, row in ipairs(rows) do
        if row.soundID then RefreshFavButton(row) end
    end
end

local function RefreshList()
    -- The persisted batch, filtered to sounds still in the registry
    -- (SoundRegistry.lua) - never filtered by SB:IsSoundNew, the 5-day
    -- timer, or the local heard counters: explicit requirement, this list
    -- must keep showing the same batch long after all three have expired.
    local list = SB:GetLatestSoundUpdateSoundIDs()
    table.sort(list, function(a, b)
        return SB:GetSoundDisplayName(a) < SB:GetSoundDisplayName(b)
    end)
    emptyText:SetShown(#list == 0)
    for i = 1, math.max(#list, #rows) do
        local row = AcquireRow(i)
        local soundID = list[i]
        if soundID then
            row.soundID = soundID
            row.icon:SetTexture(SB:GetSoundIcon(soundID))
            row.name:SetText(SB:GetSoundDisplayName(soundID))
            RefreshFavButton(row)
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

SB:On("FAVOURITES_CHANGED", function()
    if popup and popup:IsShown() then RefreshAllFavButtons() end
end)

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
    emptyText:SetText("None of the sounds from the last update are available right now.")
    emptyText:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    emptyText:SetWidth(WINDOW_W - 60)
    emptyText:SetJustifyH("CENTER")
    emptyText:SetWordWrap(true)

    return popup
end

--- Rebuilds the list and shows the window right now - used both by the
--- real first-login trigger below and Settings' "Latest Sound Updates"
--- button, always the same way: manual access is never gated by the
--- opt-out setting or by whether the automatic popup already fired for
--- this batch (explicit requirement). If no batch has ever been recorded,
--- attempts SB:RecoverLatestSoundUpdateBatch() first - an existing install
--- that already had real addedAt timestamps from before this batch
--- concept existed must not be stuck seeing "no update recorded" forever;
--- recovery persists whatever it finds immediately, so this same call
--- both fixes the stored state AND opens the result in one step, no
--- reload/relog/second click needed. Only once recovery ALSO finds
--- nothing does this print a short chat message instead of opening a
--- blank window.
function SB:ShowNewSoundsWindow()
    if not HasRecordedBatch() and SB.RecoverLatestSoundUpdateBatch then
        SB:RecoverLatestSoundUpdateBatch()
    end
    if not HasRecordedBatch() then
        SB:Print("No sound update has been recorded yet.")
        return
    end
    BuildPopup()
    checkbox:SetChecked(SB.db.settings.newSoundsPopupOptOut and true or false)
    RefreshList()
    popup:Show()
end

-- Real first-login trigger - only for a returning player (introSeen
-- already true; a fresh install gets the normal Intro instead) who hasn't
-- opted out, and only when a real batch exists AND hasn't already been
-- auto-shown (SB.db.latestSoundUpdate.autoShown - explicit requirement:
-- never repeat the same batch on every login). A few seconds after
-- Intro's own 2s delay so the two can never compete for attention even in
-- the unusual case both would apply. SB.isFreshInstall is checked
-- directly, not just introSeen, as a second, deterministic guard -
-- explicit requirement: "Fresh install must win over any New Sounds
-- detection during that login", so this can never fire on a fresh install
-- even if some future change ever made introSeen true earlier than
-- expected during that same session (introSeen alone was previously the
-- only guard here).
SB:On("PLAYER_LOGIN", function()
    if not (SB.db and SB.db.settings) then return end
    if SB.isFreshInstall then return end
    if not SB.db.settings.introSeen then return end
    if SB.db.settings.newSoundsPopupOptOut then return end
    C_Timer.After(3, function()
        if not (SB.db and SB.db.settings) then return end
        if SB.isFreshInstall then return end
        if SB.db.settings.newSoundsPopupOptOut then return end
        local batch = SB.db.latestSoundUpdate
        if not (batch and type(batch.soundIDs) == "table" and #batch.soundIDs > 0) then return end
        if batch.autoShown then return end
        SB:ShowNewSoundsWindow()
        batch.autoShown = true
    end)
end)
