-- Announcer.lua
--
-- Soundbook 3.0's replacement for the old Mini Soundbook/Favourites window
-- (FavouritesWindow.lua, no longer loaded - see Soundbook.toc). The old
-- window bundled a Favourite grid, Now Playing, Last Sound, mute controls,
-- Send menus, lock and resize into one frame; the Announcer owns exactly
-- one job - "what is Soundbook doing right now" - while the Favourite grid
-- itself moves into the Main Soundbook's Sound Library (a later 3.0 stage).
--
-- Idle: a small movable app icon, nothing else - no permanent panel.
-- Active: the icon expands into a compact banner (name / sender+channel /
-- progress) for as long as a Soundbook sound (local or received) is
-- playing, then collapses back to the icon.

local ADDON_NAME, SB = ...
local Theme = SB.Theme
local V3 = Theme.V3

local icon           -- idle/always-visible app icon (a Button, draggable)
local banner         -- expanding "now playing" content, anchored to icon
local muteDot        -- small indicator: incoming receive-mute is active
local raidDot        -- small indicator: raid-admin currently restricts you

-- The most recently seen PLAYBACK_PROGRESS_STARTED, consumed by the very
-- next LOCAL_SOUND_PLAYED/REMOTE_SOUND_PLAYED for the SAME soundID. These
-- two events are fired back-to-back from SB:PlaySound/SB:TriggerSound for
-- one play (STARTED first, from inside SB:PlaySound; LOCAL/REMOTE_SOUND_
-- PLAYED right after, from the caller) - see SoundPlayer.lua.
local pendingStart = nil

-- Every Soundbook sound currently known to be playing that the Announcer is
-- tracking, oldest first. The LAST entry is always the primary (what the
-- banner shows); anything before it is summarized as "+N" (3.0 spec
-- section 11 - "newest/highest-priority active sound becomes primary").
-- { handle, soundID, name, sender, channelLabel, duration, startedAt }
local activeDisplays = {}
local collapseTimer

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------

local function SoundName(soundID)
    return (SB.GetSoundDisplayName and SB:GetSoundDisplayName(soundID)) or soundID or "?"
end

local function SoundIcon(soundID)
    local info = SB.registry and SB.registry[soundID]
    local saved = soundID and SB.GetSoundSaved and SB:GetSoundSaved(soundID)
    return (saved and saved.icon) or (info and info.icon) or SB.DEFAULT_ICON
end

local function FormatTime(seconds)
    seconds = math.max(0, seconds)
    return string.format("%.1f", seconds)
end

------------------------------------------------------------------------
-- Frame construction
------------------------------------------------------------------------

local ICON_SIZE = 36

local function BuildIcon()
    if icon then return icon end

    icon = SB.CreateFrame("Button", "SoundbookAnnouncerIcon", UIParent)
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetFrameStrata("MEDIUM")
    icon:SetMovable(true)
    icon:EnableMouse(true)
    icon:RegisterForDrag("LeftButton")
    icon:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    icon:SetClampedToScreen(true)

    icon:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    icon:SetBackdropColor(V3.DEEP_NAVY[1], V3.DEEP_NAVY[2], V3.DEEP_NAVY[3], 0.92)
    icon:SetBackdropBorderColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.85)

    local tex = icon:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", 3, -3)
    tex:SetPoint("BOTTOMRIGHT", -3, 3)
    tex:SetTexture("Interface\\Icons\\INV_Misc_Bell_01")
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon.texture = tex

    -- Bottom-right: incoming receive-mute. Bottom-left: raid-admin
    -- restriction. Kept as two SEPARATE dots (3.0 spec section 7) - a
    -- player muting themselves and a raid leader muting the raid are
    -- different facts and must never be collapsed into one ambiguous state.
    muteDot = icon:CreateTexture(nil, "OVERLAY")
    muteDot:SetSize(9, 9)
    muteDot:SetPoint("BOTTOMRIGHT", 1, -1)
    muteDot:SetTexture("Interface\\Buttons\\WHITE8X8")
    muteDot:SetVertexColor(1, 0.3, 0.3, 1)
    muteDot:Hide()

    raidDot = icon:CreateTexture(nil, "OVERLAY")
    raidDot:SetSize(9, 9)
    raidDot:SetPoint("BOTTOMLEFT", -1, -1)
    raidDot:SetTexture("Interface\\Buttons\\WHITE8X8")
    raidDot:SetVertexColor(1, 0.65, 0.15, 1)
    raidDot:Hide()

    icon:SetScript("OnDragStart", function(self)
        if SB.db.ui.layoutLocked then return end
        self:StartMoving()
    end)
    icon:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        SB.db.ui.announcer.pos = { point = point, relPoint = relPoint, x = x, y = y }
    end)

    icon:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "LeftButton" then
            SB:Fire("TOGGLE_MAIN_UI")
        else
            SB.ShowAnnouncerQuickOptions(self)
        end
    end)

    icon:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Soundbook", 1, 1, 1)
        GameTooltip:AddLine("Left Click: Open Soundbook", 0.85, 0.9, 1)
        GameTooltip:AddLine("Right Click: Quick Options", 0.85, 0.9, 1)
        GameTooltip:Show()
    end)
    icon:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Idle-vs-hover opacity (Settings -> Interface, migrated from the old
    -- Mini Soundbook's own alphaIdle/alphaHover) - hooked once here rather
    -- than re-hooked every time a setting changes (see SB:RefreshAnnouncerAlpha).
    icon:HookScript("OnEnter", function()
        icon:SetAlpha((SB.db.ui.announcer.alphaHover or 100) / 100)
    end)
    icon:HookScript("OnLeave", function()
        if not (banner and banner:IsShown()) then
            icon:SetAlpha((SB.db.ui.announcer.alphaIdle or 100) / 100)
        end
    end)

    return icon
end

------------------------------------------------------------------------
-- The active banner
------------------------------------------------------------------------

local BANNER_W, BANNER_H = 232, 40

local function BuildBanner()
    if banner then return banner end

    banner = SB.CreateFrame("Frame", "SoundbookAnnouncerBanner", UIParent)
    banner:SetSize(BANNER_W, BANNER_H)
    banner:SetFrameStrata("MEDIUM")
    banner:EnableMouse(true)
    banner:Hide()

    banner:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    banner:SetBackdropColor(V3.DEEP_NAVY[1], V3.DEEP_NAVY[2], V3.DEEP_NAVY[3], 0.94)
    banner:SetBackdropBorderColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.55)

    local slot = Theme.CreateIconSlot(banner, 30)
    slot:SetPoint("LEFT", 5, 0)
    banner.slot = slot

    local nameText = banner:CreateFontString(nil, "OVERLAY")
    nameText:SetFontObject(SB.Fonts.HighlightSmall)
    nameText:SetPoint("TOPLEFT", slot, "TOPRIGHT", 6, -1)
    nameText:SetPoint("RIGHT", -8, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    banner.nameText = nameText

    local timeText = banner:CreateFontString(nil, "OVERLAY")
    timeText:SetFontObject(SB.Fonts.DisableSmall)
    timeText:SetPoint("TOPRIGHT", -6, -3)
    timeText:SetTextColor(unpack(V3.TEXT_SECONDARY))
    banner.timeText = timeText

    local subText = banner:CreateFontString(nil, "OVERLAY")
    subText:SetFontObject(SB.Fonts.DisableSmall)
    subText:SetPoint("TOPLEFT", nameText, "BOTTOMLEFT", 0, -2)
    subText:SetPoint("RIGHT", -8, 0)
    subText:SetJustifyH("LEFT")
    subText:SetWordWrap(false)
    banner.subText = subText

    local track = banner:CreateTexture(nil, "ARTWORK")
    track:SetPoint("BOTTOMLEFT", slot, "TOPRIGHT", 6, -2)
    track:SetPoint("BOTTOMRIGHT", -8, 2)
    track:SetHeight(2)
    track:SetTexture("Interface\\Buttons\\WHITE8X8")
    track:SetVertexColor(1, 1, 1, 0.12)
    banner.track = track

    local fill = banner:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", track, "TOPLEFT")
    fill:SetPoint("BOTTOMLEFT", track, "BOTTOMLEFT")
    fill:SetWidth(1)
    fill:SetTexture("Interface\\Buttons\\WHITE8X8")
    fill:SetVertexColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.9)
    banner.fill = fill

    local overlapBadge = banner:CreateFontString(nil, "OVERLAY")
    overlapBadge:SetFontObject(SB.Fonts.DisableSmall)
    overlapBadge:SetPoint("BOTTOMRIGHT", timeText, "BOTTOMLEFT", -4, 0)
    overlapBadge:SetTextColor(unpack(V3.ARCANE_CYAN))
    banner.overlapBadge = overlapBadge

    banner:SetScript("OnMouseUp", function(self, mouseButton)
        if mouseButton ~= "RightButton" or not self.soundbookSoundID then return end
        local soundID = self.soundbookSoundID
        local saved = SB:GetSoundSaved(soundID)
        if not saved then return end
        saved.muted = true
        SB:Fire("SOUND_DISPLAY_CHANGED", soundID)
        SB:Print(string.format('Muted "%s"', SoundName(soundID)))
        SB.RemoveAnnouncerDisplayForSound(soundID)
    end)

    banner:SetScript("OnEnter", function(self)
        if not self.soundbookSoundID then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Right-click to mute this sound", 1, 0.85, 0.4, true)
        GameTooltip:Show()
    end)
    banner:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return banner
end

------------------------------------------------------------------------
-- Layout: banner expands away from whichever screen edge the icon is
-- closest to, so it always stays fully on-screen (3.0 spec section 15).
-- The icon's own anchor is never touched by this.
------------------------------------------------------------------------

local function LayoutBanner()
    banner:ClearAllPoints()
    local iconCenterX = icon:GetCenter() or 0
    local screenW = UIParent:GetWidth() or 0
    if (screenW - iconCenterX) < (BANNER_W + 16) then
        banner:SetPoint("RIGHT", icon, "LEFT", -6, 0)
    else
        banner:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    end
end

------------------------------------------------------------------------
-- Rendering the primary (last) entry in activeDisplays
------------------------------------------------------------------------

local progressTicker

local function StopProgressTicker()
    if progressTicker then
        progressTicker:Cancel()
        progressTicker = nil
    end
end

local function RenderPrimary()
    local entry = activeDisplays[#activeDisplays]
    if not entry then return end

    banner.soundbookSoundID = entry.soundID
    banner.slot.texture:SetTexture(SoundIcon(entry.soundID))
    banner.nameText:SetText(SoundName(entry.soundID))
    banner.nameText:SetTextColor(unpack(V3.TEXT_PRIMARY))

    -- Plain ASCII separator, not a Unicode middle dot - WoW's bundled
    -- fonts don't reliably cover every codepoint (same reasoning as the
    -- Library's section-header carets in UI.lua).
    local color = SB.GetChannelColor(entry.channelLabel or "Self")
    banner.subText:SetText(string.format("%s |cff%s- %s|r", entry.sender or "?", color.hex, entry.channelLabel or "Self"))

    local extra = #activeDisplays - 1
    banner.overlapBadge:SetText(extra > 0 and ("+" .. extra) or "")

    local queued = (SB.GetPendingQueueSize and SB:GetPendingQueueSize()) or 0
    if queued > 0 then
        banner.timeText:SetText(string.format("+%d queued", queued))
    elseif entry.duration and entry.duration > 0 then
        banner.timeText:SetText("")
    else
        banner.timeText:SetText("Playing")
    end

    if entry.duration and entry.duration > 0 then
        banner.track:Show()
        banner.fill:Show()
    else
        -- Never fake a percentage for an unknown duration (3.0 spec
        -- section 10) - hide the bar entirely rather than guess.
        banner.track:Hide()
        banner.fill:Hide()
    end

    LayoutBanner()
    banner:Show()
    icon:SetAlpha(1)
    if UIFrameFadeIn then UIFrameFadeIn(banner, 0.15, banner:GetAlpha() or 0, 1) else banner:SetAlpha(1) end

    StopProgressTicker()
    if entry.duration and entry.duration > 0 then
        local trackW = banner.track:GetWidth() or 1
        banner.fill:SetWidth(0.01)
        progressTicker = C_Timer.NewTicker(0.1, function()
            local top = activeDisplays[#activeDisplays]
            if not top or top ~= entry then StopProgressTicker(); return end
            local elapsed = GetTime() - (entry.startedAt or GetTime())
            local pct = math.max(0, math.min(1, elapsed / entry.duration))
            banner.fill:SetWidth(math.max(0.01, trackW * pct))
            banner.timeText:SetText(string.format("%s / %s", FormatTime(elapsed), FormatTime(entry.duration)))
        end)
    end
end

local function CollapseToIdle()
    StopProgressTicker()
    banner.soundbookSoundID = nil
    if UIFrameFadeOut then
        UIFrameFadeOut(banner, 0.12, banner:GetAlpha() or 1, 0)
        C_Timer.After(0.13, function() if #activeDisplays == 0 then banner:Hide() end end)
    else
        banner:Hide()
    end
end

local function ScheduleCollapse()
    if collapseTimer then collapseTimer:Cancel() end
    collapseTimer = C_Timer.NewTimer(0.12, function()
        collapseTimer = nil
        if #activeDisplays == 0 then CollapseToIdle() end
    end)
end

------------------------------------------------------------------------
-- Public: remove a sound from tracking immediately (used by the mute
-- action above, and by an explicit Stop).
------------------------------------------------------------------------

function SB.RemoveAnnouncerDisplayForSound(soundID)
    for i = #activeDisplays, 1, -1 do
        if activeDisplays[i].soundID == soundID then
            table.remove(activeDisplays, i)
        end
    end
    if not banner then return end
    if #activeDisplays > 0 then
        RenderPrimary()
    else
        CollapseToIdle()
    end
end

------------------------------------------------------------------------
-- Event wiring - same event contract the old Mini Soundbook used
-- (SoundPlayer.lua / Communication.lua), so nothing there needed to change.
------------------------------------------------------------------------

local LOCAL_TARGET_LABEL = { GUILD = "Guild", PARTY = "Party", RAID = "Raid", FRIENDS = "Friends", ALL = "All" }
local function LocalTargetToChannelLabel(target)
    if not target or target == "SELF" then return "Self" end
    if type(target) == "string" and target:match("^PLAYER:") then return "Direct" end
    return LOCAL_TARGET_LABEL[target] or "Self"
end

local function AddDisplay(soundID, sender, channelLabel)
    -- Matches the old Mini Soundbook's own behaviour: no Now Playing
    -- display at all while the HUD itself is hidden (a fresh install
    -- defaults to hidden - see Core.lua's "safer first start").
    if not icon or not icon:IsShown() then return end
    BuildBanner()
    local start = pendingStart
    local handle, duration, startedAt = nil, nil, GetTime()
    if start and start.soundID == soundID then
        handle, duration, startedAt = start.handle, start.duration, start.startedAt or GetTime()
    end
    -- A retriggered sound that's already displayed restarts its own entry
    -- (fresh timing) instead of stacking a second identical-looking row.
    SB.RemoveAnnouncerDisplayForSound(soundID)
    table.insert(activeDisplays, {
        handle = handle, soundID = soundID, sender = sender,
        channelLabel = channelLabel, duration = duration, startedAt = startedAt,
    })
    if collapseTimer then collapseTimer:Cancel(); collapseTimer = nil end
    RenderPrimary()
end

SB:On("PLAYBACK_PROGRESS_STARTED", function(state)
    if not state then return end
    pendingStart = { soundID = state.soundID, handle = state.handle, duration = state.duration, startedAt = GetTime() }
end)

SB:On("PLAYBACK_PROGRESS_ENDED", function(state)
    if not state or not state.handle then return end
    for i, entry in ipairs(activeDisplays) do
        if entry.handle == state.handle then
            table.remove(activeDisplays, i)
            if #activeDisplays > 0 then
                RenderPrimary()
            else
                ScheduleCollapse()
            end
            return
        end
    end
end)

SB:On("REMOTE_SOUND_PLAYED", function(soundID, sender, channelLabel)
    AddDisplay(soundID, sender, channelLabel)
end)

SB:On("LOCAL_SOUND_PLAYED", function(soundID, target)
    local recipientName = type(target) == "string" and target:match("^PLAYER:(.+)$")
    AddDisplay(soundID, recipientName and (SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(recipientName) or recipientName) or "You",
        LocalTargetToChannelLabel(target))
end)

SB:On("PLAYBACK_STOPPED", function()
    wipe(activeDisplays)
    if collapseTimer then collapseTimer:Cancel(); collapseTimer = nil end
    if banner then CollapseToIdle() end
end)

SB:On("SOUND_DISPLAY_CHANGED", function(soundID)
    -- A sound just muted/renamed elsewhere (Edit Sound) while it happens to
    -- be showing here - refresh so the banner never shows stale text, and
    -- drop it entirely if it just became muted mid-display.
    local saved = soundID and SB.db and SB.db.sounds and SB.db.sounds[soundID]
    if saved and saved.muted then
        SB.RemoveAnnouncerDisplayForSound(soundID)
    elseif banner and banner.soundbookSoundID == soundID then
        RenderPrimary()
    end
end)

local function RefreshIndicators()
    if not icon then return end
    muteDot:SetShown(SB:IsReceiveMuted() and true or false)
    local ov = SB.raidOverride
    raidDot:SetShown((ov and (ov.mutedAll or ov.mutedSend)) and true or false)
end

SB:On("RAID_OVERRIDE_CHANGED", RefreshIndicators)
SB:On("RECEIVE_MUTE_CHANGED", RefreshIndicators)

------------------------------------------------------------------------
-- Quick Options - compact right-click menu on the idle icon (3.0 spec
-- sections 13/51, minimal first pass: mute incoming, lock, muted players,
-- open Settings - the full Quick Audio panel is a later 3.0 stage).
------------------------------------------------------------------------

local quickMenu

function SB.ShowAnnouncerQuickOptions(anchor)
    if quickMenu and quickMenu:IsShown() then
        quickMenu:Hide()
        return
    end
    if not quickMenu then
        quickMenu = SB.CreateFrame("Frame", "SoundbookAnnouncerQuickOptions", UIParent)
        quickMenu:SetFrameStrata("DIALOG")
        Theme.CleanPanel(quickMenu)
        quickMenu:SetClampedToScreen(true)

        local catcher = CreateFrame("Button", nil, UIParent)
        catcher:SetAllPoints(UIParent)
        catcher:SetFrameStrata("DIALOG")
        catcher:SetFrameLevel(quickMenu:GetFrameLevel() > 1 and quickMenu:GetFrameLevel() - 1 or 1)
        catcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        catcher:Hide()
        catcher:SetScript("OnClick", function() quickMenu:Hide(); catcher:Hide() end)
        quickMenu.catcher = catcher
        quickMenu:SetScript("OnHide", function() catcher:Hide() end)

        local rows = {}
        local function AddRow(label, onClick)
            local btn = Theme.CreateSecondaryButton(quickMenu, label, 168, 22)
            local prevRow = rows[#rows]
            if prevRow then
                btn:SetPoint("TOP", prevRow, "BOTTOM", 0, -4)
            else
                btn:SetPoint("TOP", 0, -10)
            end
            btn:SetScript("OnClick", function()
                onClick()
                quickMenu:Hide()
            end)
            rows[#rows + 1] = btn
            return btn
        end

        quickMenu.muteBtn = AddRow("Mute Incoming", function()
            if SB:IsReceiveMuted() then SB:StopReceiveMute() else SB:StartReceiveMute(nil, nil) end
        end)
        quickMenu.lockBtn = AddRow("Lock Interface", function()
            SB:SetAnnouncerLocked(not SB.db.ui.layoutLocked)
        end)
        AddRow("Muted Players...", function()
            if SB.OpenMutePlayersMenu then SB.OpenMutePlayersMenu() end
        end)
        -- Deep-linking straight to the Settings tab needs UI.lua to expose
        -- its (currently local) ToggleSettings - later 3.0 stage, once
        -- Settings becomes its own Main-shell view. For now this just opens
        -- the Main Soundbook, same as clicking the icon itself would.
        AddRow("Open Settings", function()
            SB:Fire("TOGGLE_MAIN_UI")
        end)

        quickMenu:SetSize(184, #rows * 26 + 16)
    end

    quickMenu.muteBtn.label:SetText(SB:IsReceiveMuted() and "Unmute Incoming" or "Mute Incoming")
    quickMenu.lockBtn.label:SetText(SB.db.ui.layoutLocked and "Unlock Interface" or "Lock Interface")

    quickMenu:ClearAllPoints()
    quickMenu:SetPoint("TOP", anchor, "BOTTOM", 0, -4)
    quickMenu.catcher:Show()
    quickMenu:Show()
end

------------------------------------------------------------------------
-- Public API - mirrors the old SB:ShowFavWindow/HideFavWindow/
-- ToggleFavWindow/SetFavWindowLocked shape so every existing caller
-- (Core.lua's "/sb fav", the minimap button's TOGGLE_FAV_UI, Settings.lua)
-- keeps working unchanged, just pointed at the Announcer now.
------------------------------------------------------------------------

function SB:ShowAnnouncer()
    BuildIcon()
    SB.db.ui.announcer.shown = true
    icon:ClearAllPoints()
    local pos = SB.db.ui.announcer.pos
    icon:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
    icon:Show()
    SB:RefreshAnnouncerAlpha()
    RefreshIndicators()
    if #activeDisplays > 0 then
        BuildBanner()
        RenderPrimary()
    end
end

function SB:HideAnnouncer()
    SB.db.ui.announcer.shown = false
    if icon then icon:Hide() end
    if banner then banner:Hide() end
    if quickMenu then quickMenu:Hide() end
end

function SB:ToggleAnnouncer()
    if SB.db.ui.announcer.shown then
        SB:HideAnnouncer()
    else
        SB:ShowAnnouncer()
    end
end

function SB:SetAnnouncerLocked(locked)
    SB.db.ui.layoutLocked = locked and true or false
end

-- Applies the current idle alpha immediately (e.g. right after a Settings
-- slider changes it) - the actual idle-vs-hover SWITCHING is wired once in
-- BuildIcon above via HookScript, reading these same live db values.
function SB:RefreshAnnouncerAlpha()
    if not icon then return end
    if not icon:IsMouseOver() then
        icon:SetAlpha((SB.db.ui.announcer.alphaIdle or 100) / 100)
    end
end

-- Compatibility shim: SendMenu.lua's right-click popup pins the always-
-- visible HUD element fully opaque while it's open (its own OnEnter/OnLeave
-- would otherwise hand hover away to the popup and fade it out mid-click) -
-- previously FavouritesWindow.lua's SB:PinFavAlpha, called unconditionally
-- by SendMenu.lua regardless of which UI a sound slot lives in.
local favAlphaPinned = false
function SB:PinFavAlpha(pinned)
    favAlphaPinned = pinned and true or false
    if not icon then return end
    if favAlphaPinned then
        icon:SetAlpha(1)
    elseif not icon:IsMouseOver() then
        icon:SetAlpha((SB.db.ui.announcer.alphaIdle or 100) / 100)
    end
end

-- Placeholder for the eventual Announcer-specific font/scale (3.0 spec
-- section 49 - seeded from the old Mini font settings at migration time,
-- see Settings.lua). Banner text currently uses Soundbook's shared font
-- objects (SB.Fonts), which SB:RefreshMainFont already keeps in sync.
function SB:RefreshAnnouncerFont()
end

SB:On("TOGGLE_FAV_UI", function()
    SB:ToggleAnnouncer()
end)

SB:On("PLAYER_LOGIN", function()
    if SB.db.ui.announcer.shown then
        SB:ShowAnnouncer()
    else
        BuildIcon()
    end
end)
