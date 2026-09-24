-- Announcer.lua
--
-- Soundbook's always-on HUD: idle icon plus the Mini Soundbook favourites
-- popup and Quick Options menu.
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
-- Forward-declared: defined further down (drag-preview machinery) but
-- called as upvalues from BuildIcon's OnDragStart/OnDragStop above it.
local StartIconDragPreview, StopIconDragPreview
-- Forward-declared: defined further down alongside the proximity/hover
-- system (favMenu/quickMenu), but called as upvalues from BuildIcon.
-- HandleMiniIconHoverEnter is the icon's hover-open OnEnter hook;
-- SetMiniActiveInteraction flags an active drag/interaction so the
-- proximity ticker does not auto-close while it's set.
local HandleMiniIconHoverEnter, SetMiniActiveInteraction, NoteMiniSurfaceHidden
-- True while the banner shows PREVIEW content (icon-drag preview) rather
-- than a real playing sound. Set only by Start/StopIconDragPreview - never
-- tied to menu-open state or option changes. RenderPrimary/CollapseToIdle
-- check IsPreviewActive() and skip repainting while it's true; activeDisplays
-- keeps tracking real playback underneath, and RestoreRealAnnouncerState()
-- catches the banner up once the preview ends.
local dragPreviewActive = false

local function IsPreviewActive()
    return dragPreviewActive
end

-- The most recently seen PLAYBACK_PROGRESS_STARTED, consumed by the very
-- next LOCAL_SOUND_PLAYED/REMOTE_SOUND_PLAYED for the SAME soundID. These
-- two events are fired back-to-back from SB:PlaySound/SB:TriggerSound for
-- one play (STARTED first, from inside SB:PlaySound; LOCAL/REMOTE_SOUND_
-- PLAYED right after, from the caller) - see SoundPlayer.lua.
local pendingStart = nil

-- Every Soundbook sound currently known to be playing that the Announcer is
-- tracking, oldest first. The LAST entry is always the primary (what the
-- banner shows); anything before it is summarized as "+N".
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
    return (soundID and SB.GetSoundIcon and SB:GetSoundIcon(soundID)) or SB.DEFAULT_ICON
end

local function FormatTime(seconds)
    seconds = math.max(0, seconds)
    return string.format("%.1f", seconds)
end

-- mm:ss, distinct from FormatTime above (which is a "12.3 / 45.0" style
-- elapsed/duration pair for a real sound's progress) - used only for the
-- Raid Admin mute countdown below, matching AdminPanel.lua's own
-- FormatCountdown.
local function FormatCountdown(seconds)
    seconds = math.max(0, math.floor(seconds))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Semantic label for an event-cleared duration (F/B/R): never show the
-- internal 90-minute safety-net timer as if it were the real duration -
-- show what will actually clear it instead. Matches AdminPanel.lua's
-- DURATION_TAG.
local RAID_DURATION_LABEL = {
    F = "Until fight ends", B = "Until boss ends", R = "Until raid ends",
}

-- The live-countdown-or-semantic-label text for the CURRENT SB.raidOverride
-- - shared by the icon's tooltip and the persistent "RAID MUTED" banner
-- below, so the two can never say something different for the same state.
local function RaidOverrideDurationText()
    local ov = SB.raidOverride
    if not ov then return nil end
    if ov.expiresAt and (ov.durationCode == "30" or ov.durationCode == "60") then
        return FormatCountdown(ov.expiresAt - GetTime())
    end
    return RAID_DURATION_LABEL[ov.durationCode] or "Active"
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

    -- Bottom-right: personal receive-mute dot. Bottom-left: Raid Admin
    -- restriction, shown as a shield glyph (SB.ADMIN_ICON) tinted red/orange
    -- so it reads as unmistakable, not a tiny dot. Kept as two SEPARATE
    -- indicators - a player's own mute and a raid leader's restriction are
    -- independent facts that can coexist and must never be collapsed into one.
    muteDot = icon:CreateTexture(nil, "OVERLAY")
    muteDot:SetSize(9, 9)
    muteDot:SetPoint("BOTTOMRIGHT", 1, -1)
    muteDot:SetTexture("Interface\\Buttons\\WHITE8X8")
    muteDot:SetVertexColor(1, 0.3, 0.3, 1)
    muteDot:Hide()

    raidDot = icon:CreateTexture(nil, "OVERLAY")
    raidDot:SetSize(14, 14)
    raidDot:SetPoint("BOTTOMLEFT", -2, -2)
    raidDot:SetTexture(SB.ADMIN_ICON)
    raidDot:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    raidDot:SetVertexColor(1, 0.32, 0.18, 1)
    raidDot:Hide()

    icon:SetScript("OnDragStart", function(self)
        if SB.db.ui.layoutLocked then return end
        self:StartMoving()
        StartIconDragPreview()
        -- Interaction priority: repositioning the trigger itself must never
        -- be interrupted by proximity auto-close.
        if SetMiniActiveInteraction then SetMiniActiveInteraction(true) end
    end)
    icon:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        SB.db.ui.announcer.pos = { point = point, relPoint = relPoint, x = x, y = y }
        StopIconDragPreview()
        if SetMiniActiveInteraction then SetMiniActiveInteraction(false) end
    end)

    -- Click bindings:
    -- Left click: Favourites quick-play menu (see ShowFavMenu below)
    -- Right click: Open Soundbook
    -- Shift+Right click: Quick Options
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
        -- Explains the ACTUAL scope of an active Raid Admin restriction, who
        -- applied it, and that local Self playback still works - shown
        -- alongside the player's own receive-mute state below it.
        local ov = SB.raidOverride
        if ov and (ov.mutedSend or ov.mutedAll) then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Raid Admin restriction active", 1, 0.4, 0.25)
            if ov.mutedAll then
                GameTooltip:AddLine("Sending and receiving Soundbook sounds is disabled.", 1, 0.7, 0.6, true)
            else
                GameTooltip:AddLine("Sending to Raid/Party and Guild is disabled.", 1, 0.7, 0.6, true)
            end
            local durationText = RaidOverrideDurationText()
            if durationText then
                GameTooltip:AddLine(durationText, 1, 0.7, 0.6)
            end
            if ov.source then
                GameTooltip:AddLine("Applied by " .. (SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(ov.source) or ov.source), 0.7, 0.75, 0.85)
            end
            GameTooltip:AddLine("Local (Self) playback still works.", 0.7, 0.75, 0.85)
        end
        if SB:IsReceiveMuted() then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Your own receive-mute is also active.", 1, 0.5, 0.5)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left Click: Send a Favourite", 0.85, 0.9, 1)
        GameTooltip:AddLine("Right Click: Open Soundbook", 0.85, 0.9, 1)
        GameTooltip:AddLine("Shift + Right Click: Quick Options", 0.85, 0.9, 1)
        GameTooltip:Show()
    end)
    icon:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Idle-vs-hover opacity (Settings -> Interface) - hooked once here rather
    -- than re-hooked every time a setting changes (see SB:RefreshAnnouncerAlpha).
    icon:HookScript("OnEnter", function()
        icon:SetAlpha((SB.db.ui.announcer.alphaHover or 100) / 100)
    end)
    icon:HookScript("OnLeave", function()
        if not (banner and banner:IsShown()) then
            icon:SetAlpha((SB.db.ui.announcer.alphaIdle or 100) / 100)
        end
    end)

    -- Hover-open, gated by SB.db.ui.announcer.openOnHover - purely native
    -- OnEnter-edge-triggered (fires once per genuine transition into the
    -- icon's bounds, never on a poll), so nothing re-opens the menu just
    -- because the cursor is still resting on the icon after some OTHER
    -- surface closed - a new open only follows a real OnLeave. Left-click
    -- keeps working regardless of this setting; this hook only ADDS the
    -- hover trigger. HandleMiniIconHoverEnter is defined later alongside the
    -- proximity/surface system and referenced here as a forward-declared upvalue.
    icon:HookScript("OnEnter", function()
        if HandleMiniIconHoverEnter then HandleMiniIconHoverEnter() end
    end)

    return icon
end

------------------------------------------------------------------------
-- The active banner
------------------------------------------------------------------------

-- Banner height is not a fixed constant: at a large Announcer Text Size
-- the name/source text can grow tall enough to overlap a fixed-position
-- progress bar. RelayoutBannerHeight (below BuildBanner) recomputes both
-- the banner's height and the track's position from the actual current
-- font metrics whenever the font/scale changes.
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
    banner:SetClampedToScreen(true)
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

    -- A real bordered progress bar in its own row, both corners anchored
    -- directly to `banner` (not bridged across sibling frames) for
    -- unambiguous position/size.
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
        -- Right-click interrupts playback (not a permanent mute - that's
        -- Edit Sound's "Muted" checkbox). Uses SB:StopAllSounds() rather than
        -- stopping only this handle: WoW's StopSound is plausibly channel-wide
        -- (every Soundbook sound shares one channel, SoundPlayer.lua's
        -- GetChannel()), so a single-handle stop was observed to stop every
        -- concurrently playing Soundbook sound anyway. This call is the one
        -- verified to stay scoped to Soundbook's own sounds.
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
-- Popout Direction - ONE shared resolver + positioner, used by every
-- surface that opens off the permanent Soundbook icon (this banner, the
-- Favourites popup, and Quick Options below) so they can never
-- independently pick contradictory sides for the same icon position.
-- SB.db.ui.popoutDirection is "AUTO" or one of the four manual sides;
-- Quick Options exposes it as a dropdown.
------------------------------------------------------------------------

local POPOUT_GAP = 4

-- Automatic mode's screen-region model: horizontal A(0-40%)/B(40-60%)/
-- C(60-100%), vertical 1(top half)/2(bottom half), classified off the
-- ANCHOR's own current CENTER point in UIParent's coordinate space (never
-- a hardcoded resolution, so this stays correct at any resolution/UI
-- scale). A1/A2->RIGHT, C1/C2->LEFT, B1->DOWN, B2->UP: this prioritizes
-- horizontal expansion across most of the screen, and only opens
-- vertically while the icon sits in the narrow centre band - the design
-- goal is "always opens toward the usable centre of the screen", not
-- "always opens away from the nearest edge".
function SB.ResolvePopoutDirection(anchorFrame)
    local mode = SB.db.ui.popoutDirection or "AUTO"
    if mode ~= "AUTO" then return mode end

    local screenW = UIParent:GetWidth() or 0
    local screenH = UIParent:GetHeight() or 0
    local cx, cy = anchorFrame:GetCenter()
    if screenW <= 0 or screenH <= 0 or not cx or not cy then return "RIGHT" end

    -- GetCenter() and GetWidth()/GetHeight() are each returned in their OWN
    -- frame's local unit space (1 unit = that frame's effective-scale
    -- pixels) - comparing them directly only works when anchorFrame and
    -- UIParent share the same effective scale. The Announcer icon carries
    -- its own independent SetScale (Announcer Size slider), so converting
    -- into UIParent's coordinate space first is required at every scale.
    local scaleRatio = (anchorFrame:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
    cx = cx * scaleRatio
    cy = cy * scaleRatio

    local xPct = cx / screenW
    -- WoW's coordinate origin is bottom-up, so a larger cy IS the upper
    -- half - no separate flip needed to match the user-facing diagram.
    local yPct = cy / screenH

    if xPct < 0.4 then
        return "RIGHT" -- region A
    elseif xPct > 0.6 then
        return "LEFT" -- region C
    else
        return (yPct > 0.5) and "DOWN" or "UP" -- region B: 1 (top) / 2 (bottom)
    end
end

-- Anchors `frame` to `anchorFrame` (always the icon, or the icon-shaped
-- preview during a drag) for the given resolved direction. Every
-- direction's anchor pair is chosen so WoW's own point resolution centres
-- the popup on the icon for free (LEFT/RIGHT points are their edge's
-- vertical centre, TOP/BOTTOM points are their edge's horizontal centre) -
-- no separate centring math needed. SetClampedToScreen(true) on every
-- surface this is used for keeps a manual direction from ever placing a
-- popup off-screen, without silently switching it to a different side.
function SB.PositionRelativeToIcon(frame, anchorFrame, direction)
    frame:ClearAllPoints()
    if direction == "LEFT" then
        frame:SetPoint("RIGHT", anchorFrame, "LEFT", -POPOUT_GAP, 0)
    elseif direction == "UP" then
        frame:SetPoint("BOTTOM", anchorFrame, "TOP", 0, POPOUT_GAP)
    elseif direction == "DOWN" then
        frame:SetPoint("TOP", anchorFrame, "BOTTOM", 0, -POPOUT_GAP)
    else -- "RIGHT", and the fallback for any unrecognised stored value
        frame:SetPoint("LEFT", anchorFrame, "RIGHT", POPOUT_GAP, 0)
    end
end

local function LayoutBanner()
    SB.PositionRelativeToIcon(banner, icon, SB.ResolvePopoutDirection(icon))
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

------------------------------------------------------------------------
-- Persistent "RAID MUTED" banner - explicit requirement: an active Raid
-- Admin restriction must be unmistakable even while the Announcer is
-- otherwise idle (no sound currently playing), using the existing header
-- area rather than a new floating window. Reuses the exact same banner
-- frame/elements RenderPrimary above uses for a real sound - just fed
-- different content - so this is the SAME "header extension" mechanism,
-- not a second implementation. Wired into CollapseToIdle below, which is
-- already the one place every "nothing real left to show" path already
-- funnels through (ScheduleCollapse, RemoveAnnouncerDisplayForSound,
-- RestoreRealAnnouncerState) - so it doesn't need its own call sites.
------------------------------------------------------------------------

local raidMuteTicker
local function StopRaidMuteTicker()
    if raidMuteTicker then
        raidMuteTicker:Cancel()
        raidMuteTicker = nil
    end
end

local RAID_MUTE_COLOR = { 1, 0.32, 0.18 }

local function TickRaidMuteBanner()
    local ov = SB.raidOverride
    if not banner or not banner.soundbookRaidMuted or not ov then StopRaidMuteTicker(); return end
    if not (ov.expiresAt and (ov.durationCode == "30" or ov.durationCode == "60")) then return end
    local remaining = ov.expiresAt - GetTime()
    banner.timeText:SetText(FormatCountdown(remaining))
    local trackW = math.max(1, (banner.track:GetWidth() or 1) - 2)
    local total = (ov.durationCode == "30") and 1800 or 3600
    local pct = math.max(0, math.min(1, remaining / total))
    banner.fill:SetWidth(math.max(0.01, trackW * pct))
end

local function ShowRaidMuteBanner()
    local ov = SB.raidOverride
    if not ov then return end
    BuildBanner()
    banner.soundbookSoundID = nil
    banner.soundbookRaidMuted = true
    banner.slot.texture:SetTexture(SB.ADMIN_ICON)
    banner.slot.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    banner.slot.texture:SetVertexColor(RAID_MUTE_COLOR[1], RAID_MUTE_COLOR[2], RAID_MUTE_COLOR[3], 1)
    -- Primary state reads clearly as MUTED, per explicit requirement -
    -- "RAID MUTED" covers both an individual admin mute and Mute All
    -- alike (the subtitle line spells out the actual scope difference).
    banner.nameText:SetText("RAID MUTED")
    banner.nameText:SetTextColor(RAID_MUTE_COLOR[1], RAID_MUTE_COLOR[2], RAID_MUTE_COLOR[3])
    banner.subText:SetText(ov.mutedAll and "Sending & receiving disabled" or "Sending to Raid/Party + Guild disabled")
    banner.subText:SetTextColor(unpack(V3.TEXT_SECONDARY))
    banner.overlapBadge:SetText("")
    banner.fill:SetVertexColor(RAID_MUTE_COLOR[1], RAID_MUTE_COLOR[2], RAID_MUTE_COLOR[3], 1)

    StopRaidMuteTicker()
    if ov.expiresAt and (ov.durationCode == "30" or ov.durationCode == "60") then
        -- Live countdown, explicit requirement ("RAID MUTED · 24:18") -
        -- the fill also drains as a visual progress-style cue, same
        -- element a real sound's own duration bar already uses.
        banner.track:Show()
        banner.fill:Show()
        TickRaidMuteBanner()
        raidMuteTicker = C_Timer.NewTicker(1, TickRaidMuteBanner)
    else
        -- F/B/R - semantic label only, explicit requirement: never show
        -- the internal safety-net timer as if it were the real duration.
        banner.track:Hide()
        banner.fill:Hide()
        banner.timeText:SetText(RAID_DURATION_LABEL[ov.durationCode] or "Active")
    end

    LayoutBanner()
    -- Same stale-alpha fix as StartIconDragPreview above -
    -- this can fire right after CollapseToIdle's own fade-to-0 (a mute
    -- expiring and this immediately re-showing the "still restricted"
    -- state, for instance), which would otherwise leave it invisible too.
    if UIFrameFadeRemoveFrame then UIFrameFadeRemoveFrame(banner) end
    banner:SetAlpha(1)
    banner:Show()
    icon:SetAlpha(1)
end

local function RenderPrimary()
    -- A resize/drag preview currently owns the banner's content and
    -- position - a real playback event must not overwrite it (explicit
    -- requirement). activeDisplays itself was already updated normally by
    -- the caller; RestoreRealAnnouncerState() repaints from it once the
    -- preview ends.
    if IsPreviewActive() then return end
    local entry = activeDisplays[#activeDisplays]
    if not entry then return end

    -- Real playback always takes over the banner from the persistent
    -- Raid Admin display while it's actually active - see CollapseToIdle
    -- below for the reverse transition once playback ends.
    StopRaidMuteTicker()
    banner.soundbookRaidMuted = nil

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
            -- This self-termination check runs regardless of any active
            -- preview, so a real sound that finishes mid-preview still
            -- correctly stops its own ticker instead of leaking it - only
            -- the VISUAL update below is skipped while a preview owns the
            -- banner (same reasoning as RenderPrimary's own guard above).
            if not top or top ~= entry then StopProgressTicker(); return end
            if IsPreviewActive() then return end
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
    -- Same reasoning as RenderPrimary above - never hide/fade the banner
    -- out from under an active preview just because real playback ended.
    if IsPreviewActive() then return end
    StopProgressTicker()
    banner.soundbookSoundID = nil

    -- Nothing real left to show - fall back to the persistent Raid Admin
    -- display instead of the bare idle icon while a restriction is still
    -- active (explicit requirement: unmistakable even while collapsed).
    -- This is THE one place every "nothing real left" path already
    -- funnels through, so a genuine mute/unmute/expiry (RAID_OVERRIDE_
    -- CHANGED, further below) simply calls this again to pick the right
    -- one, without needing its own separate show/hide logic.
    local ov = SB.raidOverride
    if ov and (ov.mutedSend or ov.mutedAll) then
        ShowRaidMuteBanner()
        return
    end

    banner.soundbookRaidMuted = nil
    StopRaidMuteTicker()
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

-- Called the instant either preview ends (resize slider released, icon
-- drag dropped) - repaints the banner from whatever activeDisplays
-- genuinely holds right now (a real sound may well have started or ended
-- while the preview was up), or collapses it if there's nothing real to
-- show. Never loses real playback backend state: activeDisplays was kept
-- accurate throughout by AddDisplay/PLAYBACK_PROGRESS_ENDED regardless of
-- any preview being active.
local function RestoreRealAnnouncerState()
    if IsPreviewActive() or not banner then return end
    if #activeDisplays > 0 then
        RenderPrimary()
    else
        CollapseToIdle()
    end
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
    local handle, duration, startedAt, instanceID = nil, nil, GetTime(), nil
    if start and start.soundID == soundID then
        handle, duration, startedAt, instanceID = start.handle, start.duration, start.startedAt or GetTime(), start.instanceID
    end
    -- A retriggered sound that's already displayed restarts its own entry
    -- (fresh timing) instead of stacking a second identical-looking row.
    SB.RemoveAnnouncerDisplayForSound(soundID)
    table.insert(activeDisplays, {
        handle = handle, soundID = soundID, sender = sender,
        channelLabel = channelLabel, duration = duration, startedAt = startedAt,
        -- instanceID (SoundPlayer.lua's own playback-instance token, may
        -- be nil if this AddDisplay call couldn't be paired with a
        -- PLAYBACK_PROGRESS_STARTED - e.g. a fully synthetic/test call) -
        -- the one true correlator for PLAYBACK_PROGRESS_ENDED below, never
        -- the WoW handle (which can legitimately be nil, and can't
        -- distinguish two different handle-less instances from each
        -- other) and never soundID alone (a retrigger/overlap would
        -- confuse two different instances of the same sound).
        instanceID = instanceID,
    })
    if collapseTimer then collapseTimer:Cancel(); collapseTimer = nil end
    RenderPrimary()
end

-- Instance-scoped removal (unlike SB.RemoveAnnouncerDisplayForSound above,
-- which is deliberately soundID-scoped for its own callers - a retrigger's
-- own dedup, and a sound going muted). Used by the ENDED handler below,
-- including from inside a deferred minimum-display-duration timer - safe
-- to call on an instanceID that's already gone (retriggered/muted/stopped
-- out from under it in the meantime): finds nothing, does nothing.
local function RemoveDisplayByInstance(instanceID)
    local removed = false
    for i = #activeDisplays, 1, -1 do
        if activeDisplays[i].instanceID == instanceID then
            table.remove(activeDisplays, i)
            removed = true
        end
    end
    if not removed then return end
    if #activeDisplays > 0 then
        RenderPrimary()
    else
        ScheduleCollapse()
    end
end

SB:On("PLAYBACK_PROGRESS_STARTED", function(state)
    if not state then return end
    pendingStart = { soundID = state.soundID, handle = state.handle, duration = state.duration, startedAt = GetTime(), instanceID = state.instanceID }
end)

-- Regression fix (explicit requirement - the Announcer must never
-- disappear before the configured Announcement Duration minimum, but
-- must also never depend on a WoW handle or linger past a known duration
-- just because C_Sound.IsPlaying still claims otherwise - see
-- SoundPlayer.lua's own duration-ceiling fix). Matched purely by
-- instanceID now, never by handle (which SoundPlayer.lua now allows to
-- be nil, and which can't tell two handle-less instances apart anyway).
SB:On("PLAYBACK_PROGRESS_ENDED", function(state)
    if not state or not state.instanceID then return end
    for _, entry in ipairs(activeDisplays) do
        if entry.instanceID == state.instanceID then
            -- An explicit Stop or an overlap-disabled replacement cutting
            -- this sound off must clear it immediately, bypassing the
            -- minimum entirely (SoundPlayer.lua marks state.stopped for
            -- exactly this case) - only a genuine natural/duration-
            -- ceiling end is ever held to the minimum below.
            if state.stopped or entry.naturalEndPending then
                RemoveDisplayByInstance(state.instanceID)
                return
            end
            local minDisplay = tonumber(SB.db and SB.db.settings and SB.db.settings.announceDuration) or 3
            local minUntil = (entry.startedAt or 0) + math.max(0, minDisplay)
            local now = GetTime()
            if minDisplay > 0 and now < minUntil then
                -- The real sound has genuinely ended (or hit its known-
                -- duration ceiling), but the configured minimum hasn't
                -- elapsed yet - keep the entry fully visible/ticking
                -- (RenderPrimary's own progress ticker already holds at
                -- 100% once elapsed reaches duration) and defer the
                -- actual removal to exactly when the minimum is reached,
                -- rather than vanishing early.
                entry.naturalEndPending = true
                local instanceID = state.instanceID
                C_Timer.After(minUntil - now, function()
                    RemoveDisplayByInstance(instanceID)
                end)
                return
            end
            RemoveDisplayByInstance(state.instanceID)
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

SB:On("RAID_OVERRIDE_CHANGED", function()
    RefreshIndicators()
    -- Explicit requirement: the persistent header state appears/clears
    -- automatically the moment the restriction is applied/lifted/expires
    -- - CollapseToIdle is the one place that already decides between the
    -- Raid Admin display and the bare idle icon, so a genuine change just
    -- re-runs it (only while nothing real is currently playing - a real
    -- sound's own banner already wins, see RenderPrimary above, and will
    -- itself fall through to CollapseToIdle the moment it naturally ends).
    if icon and #activeDisplays == 0 then
        BuildBanner()
        CollapseToIdle()
    end
end)
SB:On("RECEIVE_MUTE_CHANGED", RefreshIndicators)

------------------------------------------------------------------------
-- Quick Options - compact right-click menu on the idle icon (3.0 spec
-- sections 13/51, minimal first pass: mute incoming, lock, muted players,
-- open Settings - the full Quick Audio panel is a later 3.0 stage).
------------------------------------------------------------------------

local quickMenu

-- Shared preview content for BOTH the Announcer Size slider's resize
-- preview and the icon-drag preview (explicit requirement: "the same
-- populated Announcer preview... do not create a second fake
-- implementation" - one content function, reusing the REAL banner frame
-- and all its real elements, rather than a second mocked-up layout).
-- Deliberately fixed/deterministic (never real user data) - see the
-- "must not pollute user data" requirement in SB:PlaySound's own "test"
-- source handling.
local function PopulatePreviewBanner()
    BuildBanner()
    banner.soundbookSoundID = nil
    banner.slot.texture:SetTexture(SB.APP_ICON or SB.DEFAULT_ICON)
    banner.nameText:SetText("Announcer Preview")
    banner.nameText:SetTextColor(unpack(V3.TEXT_PRIMARY))
    local color = SB.GetChannelColor("Raid")
    banner.subText:SetText(string.format("Preview |cff%s- Raid|r", color.hex))
    banner.fill:SetVertexColor(color.r, color.g, color.b, 1)
    banner.overlapBadge:SetText("")
    banner.track:Show()
    banner.fill:Show()
end

------------------------------------------------------------------------
-- Icon-drag preview - explicit request: while Popout Direction is
-- Automatic and the player drags the Soundbook icon, show the same
-- populated Announcer preview as above, repositioning live as the icon
-- crosses screen regions (A/B/C, 1/2 - see SB.ResolvePopoutDirection), so
-- the automatic placement rule is understandable just by watching it
-- happen. Also carries the deliberate 10-second easter egg (section 16):
-- while the preview's own progress bar completes a 10-second cycle, one
-- random LOCAL-ONLY sound plays and the cycle restarts, for as long as
-- the drag continues.
------------------------------------------------------------------------

local DRAG_SOUND_CYCLE = 10.0
local dragPreviewElapsed = 0
local dragCandidateSounds -- built lazily, once per drag session (never rebuilt mid-drag)

-- Valid, currently playable candidates for the easter egg: excludes
-- muted and Hidden sounds (SB.db.sounds[id].hidden - UI.lua's own "Hide"
-- category flag) so the joke can't surface something the player
-- deliberately buried or silenced. Built once per drag (StartIconDragPreview
-- clears the cache), not rebuilt every 10-second cycle.
local function BuildDragCandidateSounds()
    local list = {}
    for soundID in pairs(SB.registry) do
        local saved = SB.db.sounds and SB.db.sounds[soundID]
        if not (saved and (saved.muted or saved.hidden)) then
            list[#list + 1] = soundID
        end
    end
    return list
end

local function PlayRandomLocalDragSound()
    dragCandidateSounds = dragCandidateSounds or BuildDragCandidateSounds()
    if #dragCandidateSounds == 0 then return end
    local soundID = dragCandidateSounds[math.random(#dragCandidateSounds)]
    -- SB:PlaySound(soundID, "test") directly - deliberately NEVER
    -- SB:TriggerSound. TriggerSound is what dispatches to the Output
    -- Rail/broadcasts to Guild/Raid/Friends/a direct target; PlaySound on
    -- its own only ever plays audio on THIS client, full stop - no
    -- addon message, no ACK, no History entry, no routing. The "test"
    -- source additionally excludes it from the New-Sound-heard counter
    -- (SoundPlayer.lua). This is a UI easter egg, never multiplayer
    -- behaviour.
    SB:PlaySound(soundID, "test")
end

-- Runs every frame ONLY while the icon is actively being dragged (section
-- 24 explicitly allows OnUpdate here: "the user is actively moving the
-- frame"); StopIconDragPreview below unconditionally detaches it the
-- instant the drag ends. Recomputing the resolved direction and
-- repositioning every tick is deliberately simple rather than diffing
-- against the last-known region - both are O(1) and this is exactly the
-- sanctioned exception to "no idle polling" (there is no idle polling:
-- this handler exists for zero frames outside an active drag).
local function DragPreviewOnUpdate(_, elapsed)
    LayoutBanner()

    dragPreviewElapsed = dragPreviewElapsed + elapsed
    local pct = math.min(1, dragPreviewElapsed / DRAG_SOUND_CYCLE)
    local trackW = math.max(1, (banner.track:GetWidth() or 1) - 2)
    banner.fill:SetWidth(math.max(0.01, trackW * pct))
    banner.timeText:SetText(string.format("%s / %s", FormatTime(dragPreviewElapsed), FormatTime(DRAG_SOUND_CYCLE)))

    if dragPreviewElapsed >= DRAG_SOUND_CYCLE then
        dragPreviewElapsed = 0
        PlayRandomLocalDragSound()
    end
end

function StartIconDragPreview()
    dragPreviewActive = true
    dragPreviewElapsed = 0
    dragCandidateSounds = nil
    PopulatePreviewBanner()
    LayoutBanner()
    -- BUGFIX (3.0 QA round, section 3) - "idle drag shows no preview, but
    -- dragging while a sound plays works": the actual root cause was
    -- never playback state at all, it was stale alpha. CollapseToIdle
    -- fades the banner to alpha 0 and then Hides it once nothing real is
    -- left to show; a bare banner:Show() (what this used to do) leaves
    -- that alpha 0 in place, so an idle drag's preview was technically
    -- shown but fully transparent. Dragging DURING active playback never
    -- hit this because RenderPrimary's own fade always finishes at alpha
    -- 1 first.
    if UIFrameFadeRemoveFrame then UIFrameFadeRemoveFrame(banner) end
    banner:SetAlpha(1)
    banner:Show()
    icon:SetAlpha(1)
    icon:SetScript("OnUpdate", DragPreviewOnUpdate)
end

-- No delayed callback (C_Timer.After) is used anywhere in this feature -
-- the entire 10-second cycle runs synchronously inside DragPreviewOnUpdate,
-- which this unconditionally detaches before this function returns. That
-- makes "a sound fires after the mouse was already released" structurally
-- impossible (section 20's explicit edge case) without needing a
-- drag-session token/generation ID - there is no async window for a stale
-- callback to fire from in the first place.
function StopIconDragPreview()
    if not dragPreviewActive then return end
    dragPreviewActive = false
    icon:SetScript("OnUpdate", nil)
    dragCandidateSounds = nil
    RestoreRealAnnouncerState()
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

local BUCKET_LABEL = { GUILD = "Guild", RAID = "Raid", FRIENDS = "Friends" }

-- Main Soundbook redesign: the title now describes exactly what the
-- SAME single-select Default Output SB:ResolveOutputTarget/
-- SB:DispatchDefaultOutput would actually use for a normal click
-- (SB.db.settings.defaultOutputTarget - the Main window's own "Send to:"
-- control, see UI.lua) - never a separately-computed guess. The old
-- right-side broadcast tabs' own multi-select outputRail state has no
-- surviving UI to drive it any more; this reads live reachable-player
-- counts (SB.ComputeReachablePlayers, the same source used everywhere
-- else in the addon) instead.
-- @return total (int), perBucket ({GUILD=n, RAID=n, FRIENDS=n}),
--         isLocal (bool), directName (string or nil), isAllTarget (bool)
local function ComputeLiveTargetCounts()
    local target = (SB.db.settings and SB.db.settings.defaultOutputTarget) or "ALL"
    local reachable = SB.ComputeReachablePlayers and SB.ComputeReachablePlayers() or { GUILD = {}, RAID = {}, FRIENDS = {} }
    local modes = (SB.db.settings and SB.db.settings.broadcastModes) or {}
    local perBucket, total = {}, 0
    local function CountBucket(bucket)
        local n = #(reachable[bucket] or {})
        if n > 0 then
            perBucket[bucket] = n
            total = total + n
        end
    end

    if target == "SELF" then
        return 0, {}, true, nil, false
    end
    local playerName = type(target) == "string" and target:match("^PLAYER:(.+)$")
    if playerName then
        local displayName = (SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(playerName)) or playerName
        return 1, {}, false, displayName, false
    end
    if target == "GUILD" or target == "RAID" or target == "FRIENDS" then
        CountBucket(target)
        return total, perBucket, total == 0, nil, false
    end
    -- "ALL" (default/fallback) - every currently Send-enabled channel,
    -- exactly matching SB:BroadcastSound's own modes-driven fan-out.
    for _, bucket in ipairs({ "GUILD", "RAID", "FRIENDS" }) do
        if modes[bucket] then CountBucket(bucket) end
    end
    return total, perBucket, total == 0, nil, true
end

-- Describes the CURRENT Default Output target as a short phrase
-- ("Guild (10)", "People (6)", "Bob", ...) plus an optional secondary
-- breakdown line ("Guild (4)  -  Friends (2)") for the multi-source "All"
-- case - explicit requirement, preferred over one long "Guild and Friends
-- and Raid..." sentence. `isLocal` is true for Self Only AND "selected
-- but zero real recipients right now" (explicit requirement: zero actual
-- remote recipients always reads as "Play for Yourself", regardless of
-- which target is technically active) - see SB:ResolveOutputTarget's own
-- fallback, Communication.lua, for the equivalent send-side rule.
-- "People" (never "N people" or a per-channel label) is used whenever
-- MORE than one channel actually contributes a real recipient under
-- "All", or when "All" is the target at all (isAllTarget) even if only
-- one channel happens to have anyone reachable at this instant - explicit
-- requirement, since the user's actual intent was "everyone", not one
-- specific group.
local function DescribeEffectiveTargetPhrase()
    local total, perBucket, isLocal, directName, isAllTarget = ComputeLiveTargetCounts()
    if directName then return directName, nil, false end
    if isLocal or total == 0 then return "locally", nil, true end

    local contributing, onlyBucket = 0, nil
    for _, bucket in ipairs({ "GUILD", "RAID", "FRIENDS" }) do
        if (perBucket[bucket] or 0) > 0 then
            contributing = contributing + 1
            onlyBucket = bucket
        end
    end

    if not isAllTarget and contributing <= 1 and onlyBucket then
        return string.format("%s (%d)", BUCKET_LABEL[onlyBucket], perBucket[onlyBucket]), nil, false
    end

    local parts = {}
    for _, bucket in ipairs({ "GUILD", "RAID", "FRIENDS" }) do
        if (perBucket[bucket] or 0) > 0 then
            parts[#parts + 1] = string.format("%s (%d)", BUCKET_LABEL[bucket], perBucket[bucket])
        end
    end
    -- No breakdown line at all when only one bucket actually contributed
    -- (the "All selected, only Guild has anyone" case) - a one-item
    -- breakdown would just repeat the primary line for no benefit.
    local secondary = (#parts > 1) and table.concat(parts, "  -  ") or nil
    return string.format("People (%d)", total), secondary, false
end

-- Section 20: a per-sound "Default Output" override on one of the
-- VISIBLE Favourites would make a header promising "Play for X:"
-- actively misleading for that one sound - it won't actually go there.
-- Switches to "Default destination: X" (describing what applies to
-- everything WITHOUT its own override) whenever at least one visible
-- Favourite has one; GetOrCreateFavMenuRow below adds a small routing
-- badge on that sound's own tile so it's clear WHICH one differs.
local function AnyVisibleFavouriteHasOverride()
    local favourites = SB.GetFavourites and SB:GetFavourites() or {}
    for slot = 1, SB.MAX_FAVOURITES do
        local soundID = favourites[slot]
        if soundID then
            local saved = SB.db.sounds and SB.db.sounds[soundID]
            if saved and saved.outputOverride and saved.outputOverride ~= "ALL" then
                return true
            end
        end
    end
    return false
end

local function GetFavMenuHeaderText()
    local phrase, secondary, isLocal = DescribeEffectiveTargetPhrase()
    local overridesPresent = AnyVisibleFavouriteHasOverride()
    local primary
    -- Explicit requirement: "Play sound locally"/"Play locally" reads as
    -- technical jargon - "Play for Yourself" says the same thing (only
    -- you hear it) in plain language, used consistently everywhere this
    -- Mini Soundbook state is presented.
    if overridesPresent then
        primary = isLocal and "Default destination: Play for Yourself" or ("Default destination: " .. phrase)
    else
        -- Regression fix: "Play for Guild/Raid/Friends (X):" / "Play for
        -- People (X):" (was "Send sound to X:") - matches the wording
        -- DescribeEffectiveTargetPhrase's own phrase fragments are built
        -- for now ("Guild (10)", "People (6)", ...).
        primary = isLocal and "Play for Yourself:" or ("Play for " .. phrase .. ":")
    end
    return primary, secondary
end

-- Up to 8 rows visible before scrolling (24px each) - "wenn zu lang dann
-- scrollbar" - taller than that and the thumb (already part of
-- Theme.CreateScrollFrame) takes over, same as every other scroll area
-- in this addon. Declared here (above every function that closes over it)
-- so those functions actually capture it as an upvalue - a local declared
-- below the function that references it would instead resolve to a global.
local FAV_MENU_ROW_H = 24

-- Column count mirrors UI.lua's own 2-vs-3 column switch, keyed off the
-- Mini Soundbook Size slider (SB.db.ui.announcer.favScale, 0.5-2.0) -
-- targeted correction round: this used to key off the Announcer Size
-- slider, which was wrong (resizing the Announcer resized favourites
-- too) - favScale is the independent scale that owns the favourite-area
-- UI exclusively. 1.15 is the same relative midpoint as before, just
-- against the new field.
-- Widened again, 2nd pass (explicit requirement: "Emotional Damage" is
-- still truncated at 100% Mini Soundbook Size - increase the base width
-- ~20%, target roughly 170px minimum usable text/name width after icon/
-- padding") - width only, not font size; row height (FAV_MENU_ROW_H),
-- the icon's own size, and the icon<->text/text<->edge gaps below are
-- all unchanged, exactly as required ("retain normal icon/text
-- spacing"). Usable text width = colW - 33 (4px icon inset + 20px icon +
-- 5px icon->text gap + 4px text->edge gap, GetOrCreateFavMenuRow below) -
-- 205 for the 2-column case lands at exactly 171px, just over the 170px
-- target; the 3-column width is scaled by the same ~1.23x this round
-- applied to the 2-column one, keeping their existing 165:130 ratio
-- rather than picking an unrelated new number for it. PopulateFavMenu's
-- own favMenu:SetWidth(columns * colW + 8) already grows the whole popup
-- to fit - no separate overflow handling needed. The whole favMenu frame
-- is additionally SetScale'd by favScale (see SB:RefreshMiniSoundbookScale
-- below) for the continuous 50%-200% range - these fixed base widths are
-- what that scale multiplies from.
local FAV_COL_W = { [2] = 205, [3] = 160 }
-- `count` (optional - the number of Favourites about to be laid out) adds
-- an adaptive safety net on top of the scale-based choice above (3.0 QA
-- round, section 4): now that the popup never scrolls and always shows
-- every entry at once, 2 columns' worth of a large list could still grow
-- into an awkwardly tall popup on a short screen. Only ever escalates
-- 2->3 (never overrides an explicit large-Mini-Soundbook-Size 3 back down
-- to 2) - column WIDTH readability is already handled by FAV_COL_W's
-- fixed, pre-tuned values, this only ever reacts to available screen
-- HEIGHT.
local function GetFavMenuColumns(count)
    local scale = (SB.db.ui.announcer and SB.db.ui.announcer.favScale) or 1
    local columns = scale >= 1.15 and 3 or 2
    if columns == 2 and count and count > 0 then
        local screenH = UIParent:GetHeight() or 768
        local rows2 = math.ceil(count / 2)
        if rows2 * FAV_MENU_ROW_H > screenH * 0.6 then
            columns = 3
        end
    end
    return columns
end

-- Icon+name row, same visual language as UI.lua's CreateEntryButton (icon
-- left, name right, flat accent hover) just compact enough to tile 2-3 per
-- line. The keybind moved to a hover tooltip instead of its own label -
-- there isn't enough per-tile width left for it once the row is narrowed
-- down to a grid column.
local function GetOrCreateFavMenuRow(index)
    if favMenu.rows[index] then return favMenu.rows[index] end
    local row = CreateFrame("Button", nil, favMenu.content)
    row:SetHeight(FAV_MENU_ROW_H)
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(Theme.ACCENT[1], Theme.ACCENT[2], Theme.ACCENT[3], 0.15)
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", 4, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon
    -- Small routing badge (section 20) - only shown on a sound with its
    -- OWN per-sound "Default Output" override, so it's clear which
    -- Favourite(s) don't follow the header's "Send sound to X:" summary.
    -- Same colour source as the Library's own override tint
    -- (SB.SoundOutputOverrideColor, Communication.lua).
    local overrideDot = row:CreateTexture(nil, "OVERLAY")
    overrideDot:SetSize(7, 7)
    overrideDot:SetPoint("TOPRIGHT", icon, "TOPRIGHT", 1, 1)
    overrideDot:SetTexture("Interface\\Buttons\\WHITE8X8")
    overrideDot:Hide()
    row.overrideDot = overrideDot
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
        local saved = self.soundID and SB.db.sounds and SB.db.sounds[self.soundID]
        local override = saved and saved.outputOverride and saved.outputOverride ~= "ALL" and saved.outputOverride
        if (self.hotkey and self.hotkey ~= "") or override then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.hotkey and self.hotkey ~= "" then GameTooltip:AddLine(self.hotkey, 1, 1, 1) end
            if override then
                local oc = SB.SoundOutputOverrideColor and SB.SoundOutputOverrideColor(self.soundID)
                local label = override:match("^PLAYER:(.+)$") or override
                if oc then GameTooltip:AddLine("Default Output: " .. label, oc.r, oc.g, oc.b) end
            end
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
    favMenu:SetScript("OnHide", function()
        catcher:Hide()
        if NoteMiniSurfaceHidden then NoteMiniSurfaceHidden() end
    end)

    favMenu.title = favMenu:CreateFontString(nil, "OVERLAY")
    favMenu.title:SetFontObject(SB.Fonts.Highlight)
    favMenu.title:SetPoint("TOPLEFT", 10, -8)
    favMenu.title:SetPoint("RIGHT", -10, 0)
    favMenu.title:SetJustifyH("LEFT")
    favMenu.title:SetWordWrap(false)
    favMenu.title:SetTextColor(unpack(SB.Theme.GOLD))

    -- Secondary per-source breakdown line ("Guild (4) - Friends (2)") -
    -- only shown for a multi-source selection (DescribeEffectiveTargetPhrase
    -- above), preferred over folding everything into one long title line.
    favMenu.subtitle = favMenu:CreateFontString(nil, "OVERLAY")
    favMenu.subtitle:SetFontObject(SB.Fonts.DisableSmall)
    favMenu.subtitle:SetPoint("TOPLEFT", favMenu.title, "BOTTOMLEFT", 0, -2)
    favMenu.subtitle:SetPoint("RIGHT", -10, 0)
    favMenu.subtitle:SetJustifyH("LEFT")
    favMenu.subtitle:SetWordWrap(false)
    favMenu.subtitle:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    favMenu.subtitle:Hide()

    favMenu.emptyText = favMenu:CreateFontString(nil, "OVERLAY")
    favMenu.emptyText:SetFontObject(SB.Fonts.DisableSmall)
    favMenu.emptyText:SetPoint("TOPLEFT", 10, -32)
    favMenu.emptyText:SetPoint("RIGHT", -10, 0)
    favMenu.emptyText:SetJustifyH("LEFT")
    favMenu.emptyText:SetWordWrap(true)
    favMenu.emptyText:SetText("No Favourites yet.")
    favMenu.emptyText:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    favMenu.emptyText:Hide()

    -- No ScrollFrame (3.0 QA round, section 4, explicit requirement): the
    -- popup shows every current Favourite at once (max SB.MAX_FAVOURITES,
    -- 20) with no scrollbar - PopulateFavMenu sizes both `content` and
    -- `favMenu` itself from the actual row count every time it runs, so
    -- fewer Favourites always means a smaller popup, never a fixed/
    -- clipped viewport.
    local content = CreateFrame("Frame", nil, favMenu)
    content:SetPoint("TOPLEFT", 4, -30)
    favMenu.content = content
    favMenu.rows = {}

    return favMenu
end

local function PopulateFavMenu()
    local primary, secondary = GetFavMenuHeaderText()
    favMenu.title:SetText(primary)
    favMenu.subtitle:SetShown(secondary ~= nil)
    if secondary then favMenu.subtitle:SetText(secondary) end

    -- Extra headroom when the secondary breakdown line is showing - same
    -- "measure the real rendered height, don't guess a fixed offset"
    -- approach the old Output flyout's own subtitle used.
    local subtitleH = secondary and ((favMenu.subtitle:GetHeight() or 0) + 2) or 0
    local topOffset = 30 + subtitleH

    local favourites = SB.GetFavourites and SB:GetFavourites() or {}
    local favCount = 0
    for slot = 1, SB.MAX_FAVOURITES do
        if favourites[slot] then favCount = favCount + 1 end
    end

    -- Grid width/columns first, everything below positions against it.
    local columns = GetFavMenuColumns(favCount)
    local colW = FAV_COL_W[columns]
    local gridW = columns * colW
    favMenu:SetWidth(gridW + 8)
    favMenu.content:ClearAllPoints()
    favMenu.content:SetPoint("TOPLEFT", 4, -topOffset)
    favMenu.content:SetWidth(gridW)

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
            local overrideColor = SB.SoundOutputOverrideColor and SB.SoundOutputOverrideColor(soundID)
            if overrideColor then
                row.overrideDot:SetVertexColor(overrideColor.r, overrideColor.g, overrideColor.b, 1)
                row.overrideDot:Show()
            else
                row.overrideDot:Hide()
            end
            row:Show()
        end
    end
    for i = shown + 1, #favMenu.rows do favMenu.rows[i]:Hide() end

    favMenu.emptyText:ClearAllPoints()
    favMenu.emptyText:SetPoint("TOPLEFT", 10, -topOffset - 2)
    favMenu.emptyText:SetShown(shown == 0)

    -- No scrollbar/viewport cap (3.0 QA round, section 4) - every row is
    -- always laid out and shown above, so `content` and the popup itself
    -- both just grow to fit ALL of them: max SB.MAX_FAVOURITES (20) is
    -- 10 rows at 2 columns or 7 at 3, either comfortably on-screen
    -- without ever needing to scroll. Fewer Favourites -> fewer rows ->
    -- a smaller popup, every time this runs.
    local totalRows = math.ceil(shown / columns)
    local contentH = totalRows * FAV_MENU_ROW_H
    favMenu.content:SetHeight(math.max(1, contentH))

    local titleH = (shown == 0) and 46 or 24
    favMenu:SetHeight(topOffset + math.max(titleH - 22, contentH == 0 and 24 or contentH) + 10)
end

------------------------------------------------------------------------
-- Proximity-based auto-close (explicit requirement, Mini Soundbook
-- layering/proximity regression fix) - a single shared, throttled
-- ticker covering BOTH transient surfaces (the expanded Mini Soundbook/
-- favMenu and Quick Options/quickMenu), rather than one competing timer
-- per element. Inactive (no ticker at all) whenever both are closed -
-- "do not run permanent Every Frame proximity checks while closed".
------------------------------------------------------------------------

-- Regression fix (explicit user report): the original 60px/0.3s pairing
-- closed the Mini Soundbook almost the instant it opened - real screen
-- distance for a given "UI px" tolerance shrinks a lot at higher UI
-- scale settings, and 300ms is barely enough time to even register that
-- something opened, let alone react. Loosened substantially - "in der
-- Nähe reicht" - plus a separate opening grace period below so the very
-- act of opening can never itself be followed by an immediate close.
local PROXIMITY_TOLERANCE = 150  -- px, around the combined active area
local PROXIMITY_CLOSE_DELAY = 0.6 -- seconds continuously outside before closing
local PROXIMITY_SAMPLE_INTERVAL = 0.1 -- ~0.1s throttled polling, not every frame
-- Explicit requirement: "the icon is definitely nearby" - a short window
-- right after opening (icon click, hover-open, or a forced size-preview
-- open) during which outside-time can never accumulate at all, regardless
-- of where the cursor happens to be at that exact instant. Guarantees a
-- minimum reaction window on every single open, not just a looser ongoing
-- tolerance.
local PROXIMITY_OPEN_GRACE = 0.6 -- seconds

local proximityTicker
local proximityOutsideElapsed = 0
local proximityGraceRemaining = 0
-- Interaction priority (explicit requirement): while true, the ticker
-- never accumulates outside-time at all - "restart the outside-distance
-- timer only after the active interaction ends" - set by icon drag
-- (BuildIcon above) and the Announcer/Mini Soundbook Size sliders
-- (SB.ShowAnnouncerQuickOptions below).
local proximityActiveInteraction = false

SetMiniActiveInteraction = function(active)
    proximityActiveInteraction = active and true or false
    if proximityActiveInteraction then proximityOutsideElapsed = 0 end
end

local function AddMiniBounds(combined, frame)
    if not frame or not frame.IsShown or not frame:IsShown() then return combined end
    local l, r, t, b = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
    if not (l and r and t and b) then return combined end
    -- Regression fix (explicit user report: the Mini Soundbook closes
    -- instantly while the cursor is hovering directly over it, but only
    -- once Mini Soundbook Size reaches the 3-column layout, ~120%+).
    -- GetLeft/Right/Top/Bottom are returned in the frame's OWN local unit
    -- space (1 unit = that frame's own effective-scale pixels) - icon and
    -- favMenu both carry their own independent SetScale (Announcer Size /
    -- Mini Soundbook Size), so comparing their raw numbers directly
    -- against the cursor position (normalized to UIParent's own scale
    -- below) silently skews by exactly the scale ratio - the same class
    -- of bug already fixed once for SB.ResolvePopoutDirection's
    -- GetCenter() call (see that function's own comment). Below ~1.2 the
    -- skew happened to stay inside the tolerance band, masking it; at 1.2+
    -- (also a wider frame in raw units, compounding the error) it
    -- regularly exceeded even a generous tolerance.
    local scaleRatio = (frame.GetEffectiveScale and frame:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
    l, r, t, b = l * scaleRatio, r * scaleRatio, t * scaleRatio, b * scaleRatio
    if not combined then
        return { left = l, right = r, top = t, bottom = b }
    end
    combined.left = math.min(combined.left, l)
    combined.right = math.max(combined.right, r)
    combined.top = math.max(combined.top, t)
    combined.bottom = math.min(combined.bottom, b)
    return combined
end

-- Explicit requirement: "use its complete visible bounds plus relevant
-- child dropdown/popup bounds... include the Mini Soundbook trigger/icon
-- as part of the valid interaction area." The icon is always included
-- (it's the shared trigger for both surfaces); favMenu/quickMenu are
-- included only while actually shown; the Popout Direction dropdown's
-- own floating list (a separate top-level frame, see
-- SB.CloseAnnouncerQuickOptions above) is included only while open.
local function GetCombinedMiniBounds()
    local combined
    combined = AddMiniBounds(combined, icon)
    combined = AddMiniBounds(combined, favMenu)
    combined = AddMiniBounds(combined, quickMenu)
    if quickMenu and quickMenu.dirDropdown and quickMenu.dirDropdown:IsListOpen() then
        combined = AddMiniBounds(combined, quickMenu.dirDropdown:GetListFrame())
    end
    return combined
end

local function IsCursorWithinMiniTolerance()
    local bounds = GetCombinedMiniBounds()
    if not bounds then return true end -- nothing to measure against - never force-close
    local scale = UIParent:GetEffectiveScale()
    if not scale or scale == 0 then scale = 1 end
    local x, y = GetCursorPosition()
    x, y = x / scale, y / scale
    return x >= bounds.left - PROXIMITY_TOLERANCE and x <= bounds.right + PROXIMITY_TOLERANCE
        and y >= bounds.bottom - PROXIMITY_TOLERANCE and y <= bounds.top + PROXIMITY_TOLERANCE
end

local function StopMiniProximityTicker()
    if proximityTicker then proximityTicker:Cancel(); proximityTicker = nil end
    proximityOutsideElapsed = 0
    proximityGraceRemaining = 0
end

local function MiniProximityTick()
    if proximityActiveInteraction then
        proximityOutsideElapsed = 0
        return
    end
    if proximityGraceRemaining > 0 then
        proximityGraceRemaining = proximityGraceRemaining - PROXIMITY_SAMPLE_INTERVAL
        proximityOutsideElapsed = 0
        return
    end
    if IsCursorWithinMiniTolerance() then
        proximityOutsideElapsed = 0
        return
    end
    proximityOutsideElapsed = proximityOutsideElapsed + PROXIMITY_SAMPLE_INTERVAL
    if proximityOutsideElapsed < PROXIMITY_CLOSE_DELAY then return end
    proximityOutsideElapsed = 0
    -- Explicit requirement: return each surface to its own normal closed
    -- lifecycle - SB.CloseFavMenu/SB.CloseAnnouncerQuickOptions already
    -- do exactly that (real Hide(), no setting/position/size/scale/lock
    -- changes, dropdown list closed too).
    if quickMenu and quickMenu:IsShown() then SB.CloseAnnouncerQuickOptions() end
    if favMenu and favMenu:IsShown() then SB.CloseFavMenu() end
    if not ((quickMenu and quickMenu:IsShown()) or (favMenu and favMenu:IsShown())) then
        StopMiniProximityTicker()
    end
end

local function StartMiniProximityTicker()
    -- The grace period restarts on every call, even if the ticker is
    -- already running (e.g. favMenu opening for a size preview while
    -- Quick Options and its ticker are already active) - every fresh
    -- open gets its own full reaction window, not just the first one.
    proximityOutsideElapsed = 0
    proximityGraceRemaining = PROXIMITY_OPEN_GRACE
    if proximityTicker then return end
    proximityTicker = C_Timer.NewTicker(PROXIMITY_SAMPLE_INTERVAL, MiniProximityTick)
end

-- Canonical "a transient surface just hid" signal - called from BOTH
-- favMenu's and quickMenu's own OnHide scripts (not just from
-- SB.CloseFavMenu/SB.CloseAnnouncerQuickOptions) so the ticker stops
-- promptly no matter WHICH code path actually hid the frame (a row's own
-- click-to-play, the outside-click catcher, Escape, proximity itself,
-- ...) - Hide() always fires OnHide reliably, making it the one
-- authoritative place to check this, rather than duplicating the same
-- "is the other one still open" check at every individual call site.
NoteMiniSurfaceHidden = function()
    if not ((quickMenu and quickMenu:IsShown()) or (favMenu and favMenu:IsShown())) then
        StopMiniProximityTicker()
    end
end

-- Mini Soundbook activation mode (explicit requirement): the icon's own
-- native OnEnter hook (BuildIcon above) - fires once per genuine
-- transition into the icon's bounds, never on a poll. Gated by both the
-- persisted setting AND Quick Options' own open state ("opening Quick
-- Options must suppress automatic hover-opening... must not immediately
-- reopen... requires a fresh valid hover entry after Quick Options
-- closes" - satisfied for free here: nothing re-checks this while the
-- cursor merely continues resting on the icon after Quick Options closes
-- elsewhere, only a genuine new OnEnter does, and that only ever fires
-- after a real OnLeave).
HandleMiniIconHoverEnter = function()
    if not (SB.db and SB.db.ui and SB.db.ui.announcer and SB.db.ui.announcer.openOnHover) then return end
    if quickMenu and quickMenu:IsShown() then return end
    if SB.ShowFavMenu then SB.ShowFavMenu(icon) end
end

-- Exposed on SB (not a plain local) - BuildIcon's OnClick handler above
-- calls this by name before this point in the file is even reached at
-- load time; only actually invoked later, on a real click, by which time
-- this assignment has long since run (same pattern SB.ShowAnnouncerQuickOptions
-- already used successfully here).
-- Regression fix: single-active-transient-surface rule. Reuses favMenu's
-- OWN existing OnHide handler (already hides its catcher) rather than
-- duplicating that lifecycle here - "return to its normal closed state
-- using the existing lifecycle" (explicit requirement). A real Hide(),
-- never a strata change, so the frame genuinely stops taking clicks.
function SB.CloseFavMenu()
    if favMenu then favMenu:Hide() end
end

-- Shared build+populate+position+show logic, factored out of ShowFavMenu so
-- the Mini Soundbook Size live-preview path (below) can reuse it WITHOUT
-- going through ShowFavMenu's own Quick-Options-closing side effect - the
-- preview is an explicit, narrow exception to the single-active-surface
-- rule, scoped only to the slider-drag interaction.
--
-- `positionAnchor` (optional) is ONLY used for the one-time SetPoint call
-- below - `favMenu.__anchor` (used by SB:RefreshPopoutPositions and every
-- other re-anchor) always stays `anchor` (the icon), never the position
-- anchor, so nothing outside this preview path ever sees a Popout
-- Direction resolved off anything but the icon.
local function DisplayFavMenu(anchor, directionOverride, positionAnchor)
    BuildFavMenu()
    SB:RefreshMiniSoundbookScale()
    PopulateFavMenu()
    favMenu.__anchor = anchor
    local posFrame = positionAnchor or anchor
    local direction = directionOverride or SB.ResolvePopoutDirection(posFrame)
    SB.PositionRelativeToIcon(favMenu, posFrame, direction)
    favMenu.catcher:Show()
    favMenu:Show()
end

function SB.ShowFavMenu(anchor)
    -- Single-active-transient-surface rule (explicit requirement): Quick
    -- Options never coexists with the expanded Mini Soundbook - closed
    -- first if it was open ("Quick Options -> Mini Soundbook: close Quick
    -- Options, then open Mini Soundbook"). The context/send menu is
    -- deliberately left alone here - it's opened FROM a favMenu row and
    -- is meant to coexist with it.
    if SB.CloseAnnouncerQuickOptions then SB.CloseAnnouncerQuickOptions() end
    DisplayFavMenu(anchor)
    StartMiniProximityTicker()
end

-- Mini Soundbook Size live preview (explicit, narrow exception to the
-- single-active-transient-surface rule, scoped ONLY to dragging this one
-- slider): while the user drags, the Mini Soundbook must be visible and
-- reflect the size continuously, coexisting with Quick Options rather than
-- closing it. If the Mini Soundbook was already legitimately open, it is
-- left exactly as-is and untouched on release. If it had to be force-opened
-- for the preview, it is closed again on release via the SAME CloseFavMenu
-- lifecycle everything else uses.
local miniSizePreviewForcedOpen = false

local function StartMiniSizePreview()
    if SetMiniActiveInteraction then SetMiniActiveInteraction(true) end
    if not (favMenu and favMenu:IsShown()) then
        miniSizePreviewForcedOpen = true
        -- Regression fix: an independently-computed "opposite side of the
        -- icon" direction looked correct on paper, but near a screen edge
        -- SetClampedToScreen pulls an off-screen placement back on-screen -
        -- straight back toward the icon (and quickMenu, which sits
        -- immediately next to it), overlapping after all. Chaining off
        -- quickMenu's own ACTUAL resolved rectangle instead, continuing in
        -- the SAME direction quickMenu already opened toward (the side
        -- ResolvePopoutDirection picked specifically because it has room),
        -- guarantees adjacency to quickMenu with never less than the
        -- normal POPOUT_GAP between them - it can only ever be pushed
        -- further into the open screen area, never back toward quickMenu.
        if quickMenu and quickMenu:IsShown() then
            local dir = SB.ResolvePopoutDirection(icon)
            DisplayFavMenu(icon, dir, quickMenu)
        else
            DisplayFavMenu(icon)
        end
        StartMiniProximityTicker()
    end
end

local function EndMiniSizePreview()
    if SetMiniActiveInteraction then SetMiniActiveInteraction(false) end
    if miniSizePreviewForcedOpen then
        miniSizePreviewForcedOpen = false
        SB.CloseFavMenu()
    end
end

-- Mini Soundbook Size - independent of Announcer Size (SB:RefreshAnnouncerScale
-- above): scales ONLY the favourite-area popup (icons, sound-name text,
-- dropdown/name-area width, spacing) via a plain frame SetScale, same
-- technique the Announcer itself uses for its own scale. Safe to call
-- before the popup has ever been built (BuildFavMenu hasn't run yet, e.g.
-- Settings -> Mini's slider before the icon is ever right-clicked) - just
-- no-ops until the frame exists, exactly like SB:RefreshAnnouncerScale's
-- own icon/banner guards.
function SB:RefreshMiniSoundbookScale()
    if favMenu then favMenu:SetScale(SB.db.ui.announcer.favScale or 1.0) end
end

-- Explicit requirement (section 19): if the right-side broadcast tabs'
-- selection changes while this popup is open, its summary must update
-- immediately, not on next open/reload. UI.lua fires this after every
-- change to SB.db.ui.outputRail (select-all, Self Only, individual
-- flyout checkboxes).
SB:On("OUTPUT_SELECTION_CHANGED", function()
    if favMenu and favMenu:IsShown() then PopulateFavMenu() end
end)

-- Regression fix (explicit requirement - live title updates): a per-sound
-- "Default Output" override changing (Edit Sound) can flip
-- AnyVisibleFavouriteHasOverride's result, which changes whether the
-- header reads the plain live phrase or the "Default destination: X"
-- variant - refresh the same way OUTPUT_SELECTION_CHANGED already does.
SB:On("SOUND_DISPLAY_CHANGED", function()
    if favMenu and favMenu:IsShown() then PopulateFavMenu() end
end)

-- Regression fix: single-active-transient-surface rule. Also closes the
-- Popout Direction dropdown's own floating list, which is a SEPARATE
-- top-level frame (Theme.CreateDropdown - parented to UIParent, not a
-- real child of quickMenu) and would otherwise survive quickMenu's own
-- Hide() untouched, left floating with its own live hitbox.
function SB.CloseAnnouncerQuickOptions()
    if quickMenu then
        if quickMenu.dirDropdown then quickMenu.dirDropdown:CloseList() end
        quickMenu:Hide()
    end
end

function SB.ShowAnnouncerQuickOptions(anchor)
    if quickMenu and quickMenu:IsShown() then
        SB.CloseAnnouncerQuickOptions()
        return
    end
    -- Single-active-transient-surface rule (explicit requirement): close
    -- the expanded Mini Soundbook and any open context/send menu first -
    -- "Mini Soundbook -> Quick Options: collapse/close Mini Soundbook
    -- transient state, then open Quick Options" / "Context menu -> Quick
    -- Options: close context menu first."
    if SB.CloseFavMenu then SB.CloseFavMenu() end
    if SB.CloseSendMenu then SB.CloseSendMenu() end
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
        catcher:SetScript("OnClick", function() SB.CloseAnnouncerQuickOptions() end)
        quickMenu.catcher = catcher
        quickMenu:SetScript("OnHide", function()
            catcher:Hide()
            if NoteMiniSurfaceHidden then NoteMiniSurfaceHidden() end
        end)

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
        -- Timed mute durations (Settings restructure, explicit requirement):
        -- these used to be three standalone buttons on the old Settings
        -- page - removed from there entirely (timed/global muting is a
        -- runtime action, not persistent configuration) and relocated here,
        -- the Mini Soundbook's own mute interaction, alongside the
        -- indefinite toggle above. Same SB:StartReceiveMute calls Settings
        -- used to make; behaviour is unchanged, only where you reach it from.
        AddRow("Mute 30 min", function() SB:StartReceiveMute(30 * 60, 30) end)
        AddRow("Mute 60 min", function() SB:StartReceiveMute(60 * 60, 60) end)
        quickMenu.lockBtn = AddRow("Lock Interface", function()
            SB:SetAnnouncerLocked(not SB.db.ui.layoutLocked)
        end)
        AddRow("Muted Players...", function()
            if SB.OpenMutePlayersMenu then SB.OpenMutePlayersMenu() end
        end)
        -- Settings restructure, explicit requirement: History belongs on
        -- the launcher icons' own context menu (this one - shared by the
        -- Announcer icon's Shift+Right-click and the Main toolbar's Quick
        -- Audio button), directly above Open Settings, not inside Settings
        -- itself (History is content/navigation, not configuration).
        AddRow("Sound History", function()
            if SB.ShowHistoryWindow then SB:ShowHistoryWindow() end
        end)
        -- Deep-linking straight to the Settings tab needs UI.lua to expose
        -- its (currently local) ToggleSettings - later 3.0 stage, once
        -- Settings becomes its own Main-shell view. For now this just opens
        -- the Main Soundbook, same as clicking the icon itself would.
        AddRow("Open Settings", function()
            SB:Fire("TOGGLE_MAIN_UI")
        end)

        -- Mini Soundbook activation mode (explicit requirement) - the
        -- exact same checkbox component and the exact same persisted
        -- field (SB.db.ui.announcer.openOnHover) Settings -> Mini's own
        -- copy uses, never a separate value. No extra refresh needed
        -- either way - the icon's own OnEnter handler reads this field
        -- live on every hover, so a change here or in Settings takes
        -- effect on the very next hover regardless of which one changed it.
        local hoverCheck = Theme.CreateCheckbox(quickMenu, "Open Mini Soundbook on Hover", function(checked)
            SB.db.ui.announcer.openOnHover = checked and true or false
        end)
        hoverCheck:SetPoint("TOP", rows[#rows], "BOTTOM", -8, -10)
        quickMenu.hoverCheck = hoverCheck

        -- Popout Direction - explicit request: one shared setting for
        -- every surface that opens off the icon (this menu, Favourites,
        -- the Announcer banner itself and its previews - see
        -- SB.ResolvePopoutDirection/SB.PositionRelativeToIcon above).
        -- "Automatic" resolves from the icon's current screen region every
        -- time it's needed; the other four pin one side regardless of
        -- where the icon sits.
        local dirLabel = quickMenu:CreateFontString(nil, "OVERLAY")
        dirLabel:SetFontObject(SB.Fonts.HighlightSmall)
        dirLabel:SetPoint("TOP", hoverCheck, "BOTTOM", 8, -12)
        dirLabel:SetText("Popout Direction")
        dirLabel:SetTextColor(unpack(Theme.TEXT_DIM))

        local dirDropdown = Theme.CreateDropdown(quickMenu, 160, 22)
        dirDropdown:SetOptions({
            { text = "Automatic", value = "AUTO" },
            { text = "Right", value = "RIGHT" },
            { text = "Left", value = "LEFT" },
            { text = "Up", value = "UP" },
            { text = "Down", value = "DOWN" },
        })
        dirDropdown:SetOnChange(function(value)
            SB.db.ui.popoutDirection = value
            -- Explicit requirement: reposition any already-open anchored
            -- surface immediately, no /reload needed.
            SB:RefreshPopoutPositions()
        end)
        dirDropdown.button:SetPoint("TOP", dirLabel, "BOTTOM", 0, -6)
        quickMenu.dirDropdown = dirDropdown

        -- Announcer size - explicit request ("irgendwie clever größer/
        -- kleiner machen können, aktuell zu klein"). SetScale on both the
        -- idle icon and the active banner scales everything about them
        -- (icon, text, the progress bar) together, proportionally, rather
        -- than this menu trying to independently resize a dozen elements.
        local sizeLabel = quickMenu:CreateFontString(nil, "OVERLAY")
        sizeLabel:SetFontObject(SB.Fonts.HighlightSmall)
        sizeLabel:SetPoint("TOP", dirDropdown.button, "BOTTOM", 0, -12)
        sizeLabel:SetText("Announcer Size")
        sizeLabel:SetTextColor(unpack(Theme.TEXT_DIM))

        -- Live preview (explicit requirement, matching Mini Soundbook
        -- Size's own live preview): the real icon/banner now rescale
        -- continuously while dragging, not only on mouse-up. No separate
        -- forced-open/positioning step is needed here, unlike Mini
        -- Soundbook Size's preview - the icon (and banner, when shown)
        -- are already on-screen and already independently anchored off
        -- the icon's own live edges (see SB.PositionRelativeToIcon), so
        -- growing/shrinking the icon in place dynamically pushes
        -- quickMenu's own tracked anchor point along with it and can
        -- never make the icon grow "into" quickMenu's rectangle.
        local sizeSlider = Theme.CreateSlider(quickMenu, 50, 200, 10, 120, function(value)
            SB.db.ui.announcer.scale = value / 100
            SB:RefreshAnnouncerScale()
        end)
        sizeSlider:SetScript("OnMouseUp", function() SB:RefreshAnnouncerScale() end)
        sizeSlider:SetPoint("TOP", sizeLabel, "BOTTOM", -14, -8)
        -- Interaction priority (explicit requirement): "dragging Announcer
        -- Size" must never be interrupted by proximity auto-close -
        -- HookScript composes with the OnMouseUp handler just above
        -- rather than replacing it.
        sizeSlider:HookScript("OnMouseDown", function() if SetMiniActiveInteraction then SetMiniActiveInteraction(true) end end)
        sizeSlider:HookScript("OnMouseUp", function() if SetMiniActiveInteraction then SetMiniActiveInteraction(false) end end)
        quickMenu.sizeSlider = sizeSlider

        -- Regression fix (explicit requirement): "Both Settings -> Mini
        -- and the Mini options popup must expose the same two persisted
        -- values" - this popup only ever had Announcer Size. Mini
        -- Soundbook Size added directly underneath it, same 50-200%/
        -- step-10% range, writing the SAME ui.announcer.favScale field
        -- Settings -> Mini's own slider uses (see Settings.lua's
        -- BuildMiniSoundbookSection) - there is only ever one persisted
        -- value per size, never a separate popup-local copy, so changing
        -- either location updates the other's next display automatically
        -- (both simply read the live field when shown/opened).
        local miniSizeLabel = quickMenu:CreateFontString(nil, "OVERLAY")
        miniSizeLabel:SetFontObject(SB.Fonts.HighlightSmall)
        miniSizeLabel:SetPoint("TOP", sizeSlider, "BOTTOM", 14, -12)
        miniSizeLabel:SetText("Mini Soundbook Size")
        miniSizeLabel:SetTextColor(unpack(Theme.TEXT_DIM))

        local miniSizeSlider = Theme.CreateSlider(quickMenu, 50, 200, 10, 120, function(value)
            SB.db.ui.announcer.favScale = value / 100
            -- Live preview (explicit requirement): apply continuously while
            -- dragging, not only on release.
            SB:RefreshMiniSoundbookScale()
        end)
        miniSizeSlider:SetScript("OnMouseUp", function() SB:RefreshMiniSoundbookScale() end)
        miniSizeSlider:SetPoint("TOP", miniSizeLabel, "BOTTOM", -14, -8)
        -- Interaction priority AND live-preview forced-open/close (explicit
        -- requirement): dragging this slider must never be interrupted by
        -- proximity auto-close, must force the Mini Soundbook visible if it
        -- isn't already, and must return it to its prior state on release -
        -- all via the existing StartMiniSizePreview/EndMiniSizePreview
        -- lifecycle above (a narrow, explicit exception to the single-
        -- active-surface rule, scoped only to this slider).
        miniSizeSlider:HookScript("OnMouseDown", function() StartMiniSizePreview() end)
        miniSizeSlider:HookScript("OnMouseUp", function() EndMiniSizePreview() end)
        quickMenu.miniSizeSlider = miniSizeSlider

        -- +24 for the new "Open Mini Soundbook on Hover" checkbox row.
        quickMenu:SetSize(184, #rows * 26 + 66 + 58 + 44 + 24)
    end

    quickMenu.sizeSlider:SetValue(math.floor((SB.db.ui.announcer.scale or 1.0) * 100 + 0.5))
    quickMenu.miniSizeSlider:SetValue(math.floor((SB.db.ui.announcer.favScale or 1.0) * 100 + 0.5))
    quickMenu.dirDropdown:SetValue(SB.db.ui.popoutDirection or "AUTO")
    quickMenu.hoverCheck:SetChecked(SB.db.ui.announcer.openOnHover)

    quickMenu.muteBtn.label:SetText(SB:IsReceiveMuted() and "Unmute Incoming" or "Mute Incoming")
    quickMenu.lockBtn.label:SetText(SB.db.ui.layoutLocked and "Unlock Interface" or "Lock Interface")

    quickMenu.__anchor = anchor
    SB.PositionRelativeToIcon(quickMenu, anchor, SB.ResolvePopoutDirection(anchor))
    quickMenu.catcher:Show()
    quickMenu:Show()
    StartMiniProximityTicker()
end

-- Explicit requirement (section 22): if Popout Direction changes while
-- Favourites/Quick Options/the Announcer banner are currently visible,
-- reposition them immediately rather than waiting for the next open/
-- reload. Each surface's own anchor is always the icon in practice, but
-- __anchor is tracked (not hardcoded to `icon`) so this stays correct if
-- that ever changes.
function SB:RefreshPopoutPositions()
    if favMenu and favMenu:IsShown() and favMenu.__anchor then
        SB.PositionRelativeToIcon(favMenu, favMenu.__anchor, SB.ResolvePopoutDirection(favMenu.__anchor))
    end
    if quickMenu and quickMenu:IsShown() and quickMenu.__anchor then
        SB.PositionRelativeToIcon(quickMenu, quickMenu.__anchor, SB.ResolvePopoutDirection(quickMenu.__anchor))
    end
    if banner and banner:IsShown() then
        LayoutBanner()
    end
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
    elseif SB.raidOverride and (SB.raidOverride.mutedSend or SB.raidOverride.mutedAll) then
        -- Explicit requirement: joining an already-running raid, or a
        -- fresh login while a restriction happens to already be applied
        -- to this client (unusual - raidOverride is session-only and
        -- reset on reload/disconnect - but reachable if the Announcer
        -- itself is toggled back on after being hidden mid-raid) shows
        -- the persistent state immediately, not just from the next
        -- RAID_OVERRIDE_CHANGED event.
        BuildBanner()
        CollapseToIdle()
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
