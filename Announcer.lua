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
-- True while the banner is showing DEMO content (Announcer Size slider,
-- explicit request: "damit ich die Größe besser einschätzen kann") rather
-- than an actual playing sound - see ShowAnnouncerQuickOptions/
-- HideDemoBanner below. Never true at the same time a real sound is
-- displayed (activeDisplays takes priority - see AddDisplay).
local demoBannerActive = false

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
    -- Was its own duplicate lookup reading info.icon, a field that doesn't
    -- exist on registry entries (SoundRegistry.lua's own SB:GetSoundIcon
    -- reads info.defaultIcon) - every sound without a player-set custom
    -- icon silently fell through to the question-mark fallback. Delegating
    -- to the one canonical resolver fixes that and keeps both in sync
    -- going forward.
    return (soundID and SB.GetSoundIcon and SB:GetSoundIcon(soundID)) or SB.DEFAULT_ICON
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
    tex:SetTexture(SB.APP_ICON)
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

    -- Explicit request - rebound:
    -- Left click: Favourites quick-play menu (new, see ShowFavMenu below)
    -- Right click: Open Soundbook (was left click)
    -- Shift+Right click: Quick Options (was plain right click)
    icon:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "LeftButton" then
            if SB.ShowFavMenu then SB.ShowFavMenu(self) end
        elseif IsShiftKeyDown() then
            SB.ShowAnnouncerQuickOptions(self)
        else
            SB:Fire("TOGGLE_MAIN_UI")
        end
    end)

    icon:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Soundbook", 1, 1, 1)
        GameTooltip:AddLine("Left Click: Send a Favourite", 0.85, 0.9, 1)
        GameTooltip:AddLine("Right Click: Open Soundbook", 0.85, 0.9, 1)
        GameTooltip:AddLine("Shift + Right Click: Quick Options", 0.85, 0.9, 1)
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

-- BANNER_H is no longer a fixed constant - explicit report: at a large
-- Announcer Text Size, the name/source text grew tall enough to overlap
-- the progress bar, which sat at a fixed distance from the banner's own
-- (also fixed) bottom edge. RelayoutBannerHeight (below BuildBanner)
-- recomputes both the banner's total height and the track's position
-- from the ACTUAL current font metrics every time the font/scale
-- changes, so there's no fixed size for a big font to outgrow.
local BANNER_W = 232
local ICON_SLOT_SIZE = 30
local TRACK_H = 8

local function BuildBanner()
    if banner then return banner end

    banner = SB.CreateFrame("Frame", "SoundbookAnnouncerBanner", UIParent)
    banner:SetWidth(BANNER_W)
    banner:SetHeight(48)
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

    -- Explicit report, twice: too small/subtle, wants it as prominent as
    -- the old 2.7 HUD's bar - "nicht nur ein kleiner dünner Balken". A real
    -- bordered bar in its own dedicated row (both corners anchored purely
    -- to `banner` itself, not bridged across two different sibling
    -- frames - unambiguous position/size, no anchor-resolution guessing)
    -- instead of a thin line squeezed against the bottom border.
    local track = SB.CreateFrame("Frame", nil, banner)
    -- Positioned by RelayoutBannerHeight below, not a fixed offset from
    -- banner's own bottom - that's exactly what let it collide with the
    -- text above it at a large font size.
    track:SetHeight(TRACK_H)
    track:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    track:SetBackdropColor(0, 0, 0, 0.7)
    track:SetBackdropBorderColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.75)
    banner.track = track

    local fill = track:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMLEFT", 1, 1)
    fill:SetWidth(1)
    fill:SetTexture("Interface\\Buttons\\WHITE8X8")
    fill:SetVertexColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 1)
    banner.fill = fill

    local overlapBadge = banner:CreateFontString(nil, "OVERLAY")
    overlapBadge:SetFontObject(SB.Fonts.DisableSmall)
    overlapBadge:SetPoint("BOTTOMRIGHT", timeText, "BOTTOMLEFT", -4, 0)
    overlapBadge:SetTextColor(unpack(V3.ARCANE_CYAN))
    banner.overlapBadge = overlapBadge

    banner:SetScript("OnMouseUp", function(self, mouseButton)
        -- Explicit report: this must interrupt playback (a quick "stop the
        -- sound that's bothering me right now"), not permanently mute the
        -- sound - permanent per-sound mute already has its own dedicated
        -- control (Edit Sound's "Muted" checkbox).
        --
        -- REGRESSION FOUND: the previous version tried to stop only THIS
        -- one handle via SB:StopSoundHandle - explicit report that it
        -- stopped every currently-playing Soundbook sound instead, not
        -- just this one. StopAllOwnSounds (SoundPlayer.lua) has always
        -- called StopSound(handle, 0) per-handle in a loop too and never
        -- been reported doing anything OTHER than "stop everything" - but
        -- that's also its entire intended job, so a channel-wide side
        -- effect there would never have surfaced as a bug. This is the
        -- first place this addon ever needed genuine single-handle
        -- precision, and apparently WoW's StopSound doesn't reliably give
        -- it (plausibly channel-wide, since every Soundbook sound shares
        -- one channel - SoundPlayer.lua's GetChannel()). Falling back to
        -- the one call this codebase has actually verified stays scoped
        -- to Soundbook's own sounds, even though it now stops every
        -- concurrently overlapping Soundbook sound, not just this one.
        if mouseButton ~= "RightButton" or not self.soundbookSoundID then return end
        local soundID = self.soundbookSoundID
        if SB.StopAllSounds then SB:StopAllSounds() end
        SB:Print(string.format('Stopped "%s"', SoundName(soundID)))
        SB.RemoveAnnouncerDisplayForSound(soundID)
    end)

    banner:SetScript("OnEnter", function(self)
        if not self.soundbookSoundID then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        -- Deliberately the minimal 4-arg form (text, r, g, b) only - this
        -- addon spans Classic Era through Retail (see Soundbook.toc's
        -- multi-Interface line) and adding alpha/wrapText here previously
        -- still threw "bad argument #5" on at least one of those clients,
        -- meaning that argument's real position/type isn't consistent
        -- across all of them. Every client accepts this base form.
        GameTooltip:SetText("Right-click to stop Soundbook playback", 1, 0.85, 0.4)
        GameTooltip:Show()
    end)
    banner:SetScript("OnLeave", function() GameTooltip:Hide() end)

    banner:SetScale(SB.db.ui.announcer.scale or 1.0)
    SB:RefreshAnnouncerFont()
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

-- A sound's reported duration can come from third-party/companion sound
-- registrations (SB.RegisterSounds) whose values this addon doesn't
-- control - guard against NaN/inf/non-numeric before ever dividing by it.
local function ValidDuration(d)
    return type(d) == "number" and d == d and d ~= math.huge and d > 0
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
    -- Explicit request: the progress bar takes on the channel's own colour
    -- (green for Guild, etc.) instead of always gold - same SB.CHANNEL_COLOR
    -- semantics used everywhere else a channel is shown.
    banner.fill:SetVertexColor(color.r, color.g, color.b, 1)

    local extra = #activeDisplays - 1
    banner.overlapBadge:SetText(extra > 0 and ("+" .. extra) or "")

    local queued = (SB.GetPendingQueueSize and SB:GetPendingQueueSize()) or 0
    if queued > 0 then
        banner.timeText:SetText(string.format("+%d queued", queued))
    elseif ValidDuration(entry.duration) then
        banner.timeText:SetText("")
    else
        banner.timeText:SetText("Playing")
    end

    if ValidDuration(entry.duration) then
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
    if ValidDuration(entry.duration) then
        local trackW = math.max(1, (banner.track:GetWidth() or 1) - 2) -- fill sits 1px inset from the track's own border on each side
        banner.fill:SetWidth(0.01)
        progressTicker = C_Timer.NewTicker(0.1, function()
            local top = activeDisplays[#activeDisplays]
            if not top or top ~= entry then StopProgressTicker(); return end
            local elapsed = GetTime() - (entry.startedAt or GetTime())
            if elapsed ~= elapsed then elapsed = 0 end -- NaN guard
            local displayElapsed = math.max(0, math.min(elapsed, entry.duration))
            local pct = math.max(0, math.min(1, displayElapsed / entry.duration))
            banner.fill:SetWidth(math.max(0.01, trackW * pct))
            banner.timeText:SetText(string.format("%s / %s", FormatTime(displayElapsed), FormatTime(entry.duration)))
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
    demoBannerActive = false -- a real sound always wins over the size-preview demo
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

-- Explicit request: while adjusting the Announcer Size slider, show a
-- demo "now playing" banner (placeholder name/sender/bar/time) so the
-- player can actually judge the size - only while no REAL sound is
-- currently displayed there (never overrides genuine playback).
local function ShowDemoBanner()
    if #activeDisplays > 0 then return end
    BuildBanner()
    demoBannerActive = true
    banner.soundbookSoundID = nil
    banner.slot.texture:SetTexture(SB.DEFAULT_ICON)
    banner.nameText:SetText("Sound Name")
    banner.nameText:SetTextColor(unpack(V3.TEXT_PRIMARY))
    local selfColor = SB.GetChannelColor("Self")
    banner.subText:SetText(string.format("You |cff%s- Self|r", selfColor.hex))
    banner.timeText:SetText("2.0 / 2.0")
    banner.overlapBadge:SetText("")
    banner.track:Show()
    banner.fill:Show()
    local trackW = math.max(1, (banner.track:GetWidth() or 1) - 2)
    banner.fill:SetWidth(trackW * 0.6)
    LayoutBanner()
    banner:Show()
    icon:SetAlpha(1)
end

local function HideDemoBanner()
    if not demoBannerActive then return end
    demoBannerActive = false
    if #activeDisplays == 0 then CollapseToIdle() end
end

------------------------------------------------------------------------
-- Favourites quick-play menu - explicit request: left-click the icon
-- opens up to 20 Favourites as an icon grid (2 or 3 columns, same
-- icon+name row style as the Library's own entries - see UI.lua's
-- LayoutEntries), titled with exactly where a click will actually send
-- them ("Send Sound to Guild (2):", matching the Output Rail's own
-- current selection). Column count follows the Announcer Size setting
-- (SB.db.ui.announcer.scale) - a bigger Announcer gets the wider 3-column
-- grid. Picking a sound plays it through SB:TriggerSound with no
-- override, identical to a normal Library click.
------------------------------------------------------------------------

local favMenu

-- Mirrors the Output Rail's own "P/R shows whichever you're actually in,
-- (N) is the real reachable count" language (UI.lua's RailGroupLabel/
-- ConfigureHeader) so this menu's title always says the same thing the
-- Rail itself would show for the current selection.
local function GetSendTargetLabel()
    local target = SB.db.settings.defaultOutputTarget or "ALL"
    local reachable = SB.ComputeReachablePlayers and SB.ComputeReachablePlayers()
    if target == "ALL" then
        return "Send Sound to All:"
    elseif target == "SELF" then
        return "Send Sound to Self:"
    elseif target == "SUBSET" then
        local rail = SB.db.ui.outputRail
        local mode = rail and rail.mode
        local count = rail and #(rail.recipients or {}) or 0
        local label = (mode == "GUILD" and "Guild") or (mode == "FRIENDS" and "Friends")
            or (mode == "RAID" and (IsInRaid() and "Raid" or (IsInGroup() and "Party" or "Raid/Party")))
            or "Selected"
        return string.format("Send Sound to %s (%d):", label, count)
    elseif target == "GUILD" then
        return string.format("Send Sound to Guild (%d):", reachable and #reachable.GUILD or 0)
    elseif target == "FRIENDS" then
        return string.format("Send Sound to Friends (%d):", reachable and #reachable.FRIENDS or 0)
    elseif target == "RAID" or target == "PARTY" then
        local label = IsInRaid() and "Raid" or (IsInGroup() and "Party" or "Raid/Party")
        return string.format("Send Sound to %s (%d):", label, reachable and #reachable.RAID or 0)
    elseif type(target) == "string" and target:match("^PLAYER:") then
        local name = target:match("^PLAYER:(.+)$")
        return string.format("Send Sound to %s:", (SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(name)) or name)
    end
    return "Send Sound:"
end

-- Up to 8 rows visible before scrolling (24px each) - "wenn zu lang dann
-- scrollbar" - taller than that and the thumb (already part of
-- Theme.CreateScrollFrame) takes over, same as every other scroll area
-- in this addon. Declared here (above every function that closes over it)
-- so those functions actually capture it as an upvalue - a local declared
-- below the function that references it would instead resolve to a global.
local FAV_MENU_VISIBLE_ROWS = 8
local FAV_MENU_ROW_H = 24

-- Column count mirrors UI.lua's own 2-vs-3 column switch, but keyed off
-- the Announcer Size slider (SB.db.ui.announcer.scale, 0.7-1.6) instead of
-- the Library's window width - explicit request: "zwei bzw drei Spaltig,
-- je nach dem wie groß die size eingestellt ist beim announcer". 1.15 is
-- simply the midpoint of that slider's range.
local FAV_COL_W = { [2] = 150, [3] = 118 }
local function GetFavMenuColumns()
    local scale = (SB.db.ui.announcer and SB.db.ui.announcer.scale) or 1
    return scale >= 1.15 and 3 or 2
end

-- Icon+name row, same visual language as UI.lua's CreateEntryButton (icon
-- left, name right, flat accent hover) just compact enough to tile 2-3 per
-- line. The keybind moved to a hover tooltip instead of its own label -
-- there isn't enough per-tile width left for it once the row is narrowed
-- down to a grid column.
local function GetOrCreateFavMenuRow(index)
    if favMenu.rows[index] then return favMenu.rows[index] end
    local row = CreateFrame("Button", nil, favMenu.scroll.content)
    row:SetHeight(FAV_MENU_ROW_H)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(Theme.ACCENT[1], Theme.ACCENT[2], Theme.ACCENT[3], 0.15)
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", 4, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon
    local text = row:CreateFontString(nil, "OVERLAY")
    text:SetFontObject(SB.Fonts.HighlightSmall)
    text:SetPoint("LEFT", icon, "RIGHT", 5, 0)
    text:SetPoint("RIGHT", -4, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    row.text = text
    row:SetScript("OnClick", function(self)
        if self.soundID then SB:TriggerSound(self.soundID) end
        favMenu:Hide()
    end)
    row:SetScript("OnEnter", function(self)
        if self.hotkey and self.hotkey ~= "" then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.hotkey, 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    favMenu.rows[index] = row
    return row
end

local function BuildFavMenu()
    if favMenu then return favMenu end
    favMenu = SB.CreateFrame("Frame", "SoundbookFavMenu", UIParent)
    -- Real width is set every PopulateFavMenu call once the column count
    -- (2 or 3) is known; this is just a sane initial value before the
    -- first populate.
    favMenu:SetWidth(FAV_COL_W[2] * 2 + 8)
    favMenu:SetFrameStrata("DIALOG")
    Theme.CleanPanel(favMenu)
    favMenu:SetClampedToScreen(true)
    favMenu:Hide()

    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("DIALOG")
    catcher:SetFrameLevel(favMenu:GetFrameLevel() > 1 and favMenu:GetFrameLevel() - 1 or 1)
    catcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    catcher:Hide()
    catcher:SetScript("OnClick", function() favMenu:Hide(); catcher:Hide() end)
    favMenu.catcher = catcher
    favMenu:SetScript("OnHide", function() catcher:Hide() end)

    favMenu.title = favMenu:CreateFontString(nil, "OVERLAY")
    favMenu.title:SetFontObject(SB.Fonts.Highlight)
    favMenu.title:SetPoint("TOPLEFT", 10, -8)
    favMenu.title:SetPoint("RIGHT", -10, 0)
    favMenu.title:SetJustifyH("LEFT")
    favMenu.title:SetWordWrap(false)
    favMenu.title:SetTextColor(unpack(SB.Theme.GOLD))

    favMenu.emptyText = favMenu:CreateFontString(nil, "OVERLAY")
    favMenu.emptyText:SetFontObject(SB.Fonts.DisableSmall)
    favMenu.emptyText:SetPoint("TOPLEFT", 10, -32)
    favMenu.emptyText:SetPoint("RIGHT", -10, 0)
    favMenu.emptyText:SetJustifyH("LEFT")
    favMenu.emptyText:SetWordWrap(true)
    favMenu.emptyText:SetText("No Favourites yet.")
    favMenu.emptyText:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    favMenu.emptyText:Hide()

    local sf = SB.Theme.CreateScrollFrame(favMenu)
    sf.scroll:SetPoint("TOPLEFT", 4, -30)
    sf.scroll:SetPoint("BOTTOMRIGHT", -4, 8)
    -- Single TOPLEFT anchor + explicit SetWidth on the scroll child, never
    -- a second (RIGHT-edge) anchor point - a ScrollFrame's own scroll
    -- child breaks (GetLeft/GetTop go unresolvable, everything anchored
    -- off it collapses) the moment it's ever actually scrolled if it has
    -- two anchor points instead of one. This exact bug already cost a
    -- long debugging session on the Library's own ScrollFrame earlier -
    -- see UI.lua's RefreshLibraryImpl for the full writeup.
    sf.content:SetPoint("TOPLEFT", 0, 0)
    sf.content:SetWidth(206)
    favMenu.scroll = sf
    favMenu.rows = {}

    return favMenu
end

local function PopulateFavMenu()
    favMenu.title:SetText(GetSendTargetLabel())

    -- Grid width/columns first, everything below positions against it.
    local columns = GetFavMenuColumns()
    local colW = FAV_COL_W[columns]
    local gridW = columns * colW
    favMenu:SetWidth(gridW + 8)
    favMenu.scroll.content:SetWidth(gridW)

    local favourites = SB.GetFavourites and SB:GetFavourites() or {}
    local shown = 0
    for slot = 1, SB.MAX_FAVOURITES do
        local soundID = favourites[slot]
        if soundID then
            shown = shown + 1
            local row = GetOrCreateFavMenuRow(shown)
            -- Same col/row grid math as UI.lua's LayoutEntries.
            local col = (shown - 1) % columns
            local gridRow = math.floor((shown - 1) / columns)
            row:ClearAllPoints()
            row:SetSize(colW, FAV_MENU_ROW_H)
            row:SetPoint("TOPLEFT", col * colW, -(gridRow * FAV_MENU_ROW_H))
            row.soundID = soundID
            row.icon:SetTexture(SB:GetSoundIcon(soundID))
            row.text:SetText(SB:GetSoundDisplayName(soundID))
            row.hotkey = (SB.GetFavouriteHotkeyLabel and SB:GetFavouriteHotkeyLabel(slot)) or ""
            row:Show()
        end
    end
    for i = shown + 1, #favMenu.rows do favMenu.rows[i]:Hide() end

    favMenu.emptyText:SetShown(shown == 0)
    local totalRows = math.ceil(shown / columns)
    favMenu.scroll.content:SetHeight(math.max(1, totalRows * FAV_MENU_ROW_H))
    local visibleRows = math.min(totalRows, FAV_MENU_VISIBLE_ROWS)
    local visibleH = visibleRows * FAV_MENU_ROW_H
    favMenu.scroll.scroll:SetHeight(math.max(FAV_MENU_ROW_H, visibleH))
    favMenu.scroll.UpdateThumb()

    local titleH = (shown == 0) and 46 or 24
    favMenu:SetHeight(30 + math.max(titleH - 22, visibleH == 0 and 24 or visibleH) + 10)
end

-- Exposed on SB (not a plain local) - BuildIcon's OnClick handler above
-- calls this by name before this point in the file is even reached at
-- load time; only actually invoked later, on a real click, by which time
-- this assignment has long since run (same pattern SB.ShowAnnouncerQuickOptions
-- already used successfully here).
function SB.ShowFavMenu(anchor)
    BuildFavMenu()
    PopulateFavMenu()
    favMenu:ClearAllPoints()
    favMenu:SetPoint("TOP", anchor, "BOTTOM", 0, -4)
    favMenu.catcher:Show()
    favMenu:Show()
end

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
        quickMenu:SetScript("OnHide", function() catcher:Hide(); HideDemoBanner() end)

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

        -- Announcer size - explicit request ("irgendwie clever größer/
        -- kleiner machen können, aktuell zu klein"). SetScale on both the
        -- idle icon and the active banner scales everything about them
        -- (icon, text, the progress bar) together, proportionally, rather
        -- than this menu trying to independently resize a dozen elements.
        local sizeLabel = quickMenu:CreateFontString(nil, "OVERLAY")
        sizeLabel:SetFontObject(SB.Fonts.HighlightSmall)
        sizeLabel:SetPoint("TOP", rows[#rows], "BOTTOM", 0, -12)
        sizeLabel:SetText("Announcer Size")
        sizeLabel:SetTextColor(unpack(Theme.TEXT_DIM))

        -- The value/label update live (Theme.CreateSlider's own Refresh),
        -- but the icon/banner only actually rescale on mouse-up - explicit
        -- report: this menu is itself anchored to the icon, so rescaling
        -- it on every drag tick moved the icon (and this menu right along
        -- with it) under the player's cursor. Resolving the visual resize
        -- once, on release, keeps this menu's own live anchor to the icon
        -- both simple and always correct instead of trying to out-guess
        -- where a rescaling icon's edge will land.
        local sizeSlider = Theme.CreateSlider(quickMenu, 70, 160, 5, 120, function(value)
            SB.db.ui.announcer.scale = value / 100
        end)
        sizeSlider:SetScript("OnMouseUp", function() SB:RefreshAnnouncerScale() end)
        sizeSlider:SetPoint("TOP", sizeLabel, "BOTTOM", -14, -8)
        quickMenu.sizeSlider = sizeSlider

        quickMenu:SetSize(184, #rows * 26 + 66)
    end

    quickMenu.sizeSlider:SetValue(math.floor((SB.db.ui.announcer.scale or 1.0) * 100 + 0.5))

    quickMenu.muteBtn.label:SetText(SB:IsReceiveMuted() and "Unmute Incoming" or "Mute Incoming")
    quickMenu.lockBtn.label:SetText(SB.db.ui.layoutLocked and "Unlock Interface" or "Lock Interface")

    -- A plain live anchor to anchor's own BOTTOM - explicit report on an
    -- earlier attempt at a scale-independent snapshot (manual GetLeft/
    -- GetBottom math): it opened "way too far from the icon". WoW's own
    -- anchor resolution always places this correctly relative to the
    -- icon's CURRENT rendered position/scale, which manual coordinate
    -- math evidently didn't reproduce correctly. The Announcer Size
    -- slider's jitter (this menu moving while its own icon rescales
    -- live) is now fixed at the source instead - the icon/banner only
    -- actually rescale on the slider's mouse-up, not on every drag tick,
    -- so this menu has nothing moving under it while being dragged.
    -- SetClampedToScreen(true) above keeps it fully on-screen regardless
    -- of which edge the icon is near.
    quickMenu:ClearAllPoints()
    quickMenu:SetPoint("TOP", anchor, "BOTTOM", 0, -4)
    quickMenu.catcher:Show()
    quickMenu:Show()
    ShowDemoBanner()
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
    SB:RefreshAnnouncerScale()
    RefreshIndicators()
    if #activeDisplays > 0 then
        BuildBanner()
        RenderPrimary()
    end
end

-- SetScale scales a frame and everything anchored to/inside it (icon,
-- text, the progress bar) together, proportionally - applied to the icon
-- immediately, and to the banner too so a sound already playing when the
-- size changes doesn't stay stuck at the old scale until it next re-shows.
function SB:RefreshAnnouncerScale()
    local scale = SB.db.ui.announcer.scale or 1.0
    if icon then icon:SetScale(scale) end
    if banner then banner:SetScale(scale) end
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

-- Explicit report: Settings' "Announcer Font"/"Announcer Text Size"
-- controls (SB.db.settings.miniFont/miniFontScale) had no effect - this
-- was a placeholder stub, never actually implemented after the 3.0
-- rewrite. Sets the font directly on the Announcer's own FontStrings
-- (never via SB.Fonts' shared objects - those are the MAIN Soundbook
-- window's, and mutating them would also resize Settings/Edit Sound/
-- everything else that shares them), same approach the old Mini
-- Soundbook's footerText always used for this exact setting.
-- Explicit report: at a large Announcer Text Size, the name/source text
-- overlapped the progress bar below it - both were at fixed positions
-- within a fixed-height banner. Recomputes the banner's total height and
-- the track's position from the SAME font metrics just applied above, so
-- there's no fixed geometry for a bigger font to outgrow. Uses the
-- known base sizes/line-height math rather than querying rendered
-- GetHeight() (which needs an extra frame to settle after SetFont) -
-- deterministic and correct the instant this runs.
local function RelayoutBannerHeight()
    local scale = SB.db.settings.miniFontScale or 1
    local nameH = math.ceil((SB.Fonts.HighlightSmall.baseSize or 12) * scale * 1.4)
    local subH = math.ceil((SB.Fonts.DisableSmall.baseSize or 10) * scale * 1.4)
    local textBottom = 1 + nameH + 2 + subH -- top inset + name + gap + sub
    local contentH = math.max(ICON_SLOT_SIZE, textBottom)
    banner:SetHeight(math.max(40, contentH + 6 + TRACK_H + 5))
    banner.track:ClearAllPoints()
    banner.track:SetPoint("TOPLEFT", banner, "TOPLEFT", 41, -(contentH + 6))
    banner.track:SetPoint("RIGHT", banner, "RIGHT", -8, 0)
end

function SB:RefreshAnnouncerFont()
    if not banner then return end
    local path = SB.db.settings.miniFont or SB.AVAILABLE_FONTS[1].path
    local scale = SB.db.settings.miniFontScale or 1
    local function Apply(fs, baseFontObj)
        local size = math.max(6, math.floor((baseFontObj.baseSize or 12) * scale + 0.5))
        fs:SetFont(path, size, "")
    end
    Apply(banner.nameText, SB.Fonts.HighlightSmall)
    Apply(banner.subText, SB.Fonts.DisableSmall)
    Apply(banner.timeText, SB.Fonts.DisableSmall)
    RelayoutBannerHeight()
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
