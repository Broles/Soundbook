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
-- Hoisted here (built/populated much further down, in the Favourites
-- popup section) so BuildIcon's own OnLeave hook (tooltip persistence,
-- see below) can reference the real frame directly - a `local favMenu`
-- declared only later in the file would be a DIFFERENT variable than the
-- one a closure created up here captures.
local favMenu
-- True only while favMenu is currently open BECAUSE of icon hover (never
-- for a left-click or the Mini Soundbook Size slider's forced preview) -
-- gates both the tightened ~8px proximity tolerance and the tooltip
-- persistence below, neither of which should apply to a Mini Soundbook
-- the player opened through its normal, explicit controls.
local miniOpenedViaHover = false
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
-- Same idea, set only by Start/EndAnnouncerSizePreview (the Announcer Size
-- slider's own live-preview, see below) - kept as a genuinely separate flag
-- rather than reusing dragPreviewActive, since the two interactions are
-- unrelated (no shared OnUpdate/easter-egg machinery here) even though they
-- can never physically overlap (dragging the icon and dragging a slider at
-- the same time isn't possible).
local announcerSizePreviewActive = false

local function IsPreviewActive()
    return dragPreviewActive or announcerSizePreviewActive
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
-- Hover re-arm gate (interaction-priority fix)
------------------------------------------------------------------------

-- Every transient popup this module owns (favMenu, quickMenu) shows a
-- full-screen catcher at a strata ABOVE the icon's own "MEDIUM" strata
-- while open (favMenu/quickMenu's catchers are "DIALOG"; SendMenu.lua's
-- context menu, opened from a favMenu row, goes further still -
-- "TOOLTIP" - see its own OpenSendMenu comment: "the icon should stay
-- visibly zoomed... for as long as this popup covers it and steals the
-- real mouse focus"). WoW hit-tests by strata first, so for as long as
-- any of these is open the icon simply cannot be the topmost frame under
-- the cursor, wherever the cursor actually is - meaning the icon
-- reliably fires a real OnLeave the instant such a popup appears and a
-- real OnEnter the instant it's gone, even though the cursor may never
-- have physically moved. Native OnEnter/OnLeave pairing alone therefore
-- cannot distinguish "the user is genuinely hovering again" from "some
-- popup just stopped covering the icon" - this explicit gate is that
-- distinction instead. Disarmed the moment an explicit interaction opens
-- one of these popups; a popup closing never re-arms it by itself
-- (bullet: "popup close does not re-arm it") - only a LEAVE where the
-- cursor is verified to really be outside the icon's own bounds re-arms
-- it (icon's OnLeave hook below), so the very next genuine enter is what
-- gets to open the Mini Soundbook again.
local miniHoverGateArmed = true

local function IsCursorActuallyOnIcon()
    if not (icon and icon.GetLeft) then return false end
    local l, r, t, b = icon:GetLeft(), icon:GetRight(), icon:GetTop(), icon:GetBottom()
    if not (l and r and t and b) then return false end
    local scale = icon:GetEffectiveScale()
    if not scale or scale == 0 then scale = 1 end
    local x, y = GetCursorPosition()
    x, y = x / scale, y / scale
    return x >= l and x <= r and y >= b and y <= t
end

-- Exposed so other transient-popup owners (SendMenu.lua's context menu)
-- can disarm the same gate their own popup requires - any surface with a
-- full-screen catcher steals real mouse hover from the icon the same way
-- Quick Options does (see this section's own comment above).
function SB.SuppressMiniHoverGate()
    miniHoverGateArmed = false
end

-- Single source of truth for what a click on the icon itself does (see
-- BuildIcon's OnClick below) - ALSO called from favMenu's/quickMenu's own
-- catcher OnClick further down when a click meant for the icon lands on
-- one of those full-screen catchers instead, because a catcher covers the
-- entire screen at a strata above the icon, including directly over it
-- (same strata fact the gate above is built on). Without redispatching,
-- that first right-click/shift-right-click would silently just close
-- whichever popup was open and do nothing else - Open Soundbook/Quick
-- Options only firing on a SECOND click - and with hover ON, hover could
-- reopen the popup again before that second click ever landed, making
-- the icon look permanently stuck. Only called for a button/click that
-- should actually change what's open - see each catcher's own comment
-- for when it's skipped (a plain re-click that would just toggle the
-- SAME surface back open).
local function PerformMiniIconClick(button)
    if button == "LeftButton" then
        if SB.ShowFavMenu then SB.ShowFavMenu(icon) end
    elseif IsShiftKeyDown() then
        if SB.ShowAnnouncerQuickOptions then SB.ShowAnnouncerQuickOptions(icon) end
    else
        -- Bugfix: a plain right-click opening the Main Soundbook never
        -- closed a hover-opened Mini Soundbook first, so the two could end
        -- up visibly stacked on top of each other. Right-click already
        -- ranks above hover in this addon's own interaction priority (see
        -- the "Hover re-arm gate" section above) - this just makes closing
        -- the Mini part of that same explicit action, same as opening
        -- Quick Options already does.
        if SB.CloseFavMenu then SB.CloseFavMenu() end
        SB:Fire("TOGGLE_MAIN_UI")
    end
end

-- Bugfix: the icon lost its OWN native mouse ownership (click already
-- redispatched above, but drag was never covered - a drag needs the icon
-- itself to receive OnDragStart, which redispatching a finished OnClick
-- can't provide) for as long as one of its own hover-opened popups
-- stayed open, because that popup's full-screen catcher sits at DIALOG
-- strata - above the icon's normal "MEDIUM" - everywhere on screen,
-- including directly over the icon. Most visible as "the icon can't be
-- dragged while Open on Hover is enabled", since hovering it is exactly
-- what opens the covering popup in the first place. Rather than
-- reimplementing drag manually on the catcher (which would need its own,
-- error-prone click-vs-drag distinction WoW already gives the icon for
-- free), the icon is temporarily raised to sit ABOVE its own catcher so
-- it keeps receiving every native mouse event (click, drag, OnEnter/
-- OnLeave) exactly as if nothing were covering it - restored the moment
-- that catcher hides, so every OTHER stacking relationship (icon vs.
-- Main/Settings, etc.) is completely unaffected.
local ICON_IDLE_STRATA = "MEDIUM"
local function RaiseIconAboveCatcher(catcherFrame)
    if not (icon and catcherFrame) then return end
    icon:SetFrameStrata("DIALOG")
    icon:SetFrameLevel((catcherFrame:GetFrameLevel() or 1) + 10)
end
local function RestoreIconStrata()
    if not icon then return end
    icon:SetFrameStrata(ICON_IDLE_STRATA)
end

------------------------------------------------------------------------
-- Frame construction
------------------------------------------------------------------------

local ICON_SIZE = 36

local function BuildIcon()
    if icon then return icon end

    icon = SB.CreateFrame("Button", "SoundbookAnnouncerIcon", UIParent)
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetFrameStrata(ICON_IDLE_STRATA)
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
        -- The Mini Soundbook popup tracks the icon's position while shown
        -- (proximity checks, catcher/strata management) and visibly gets in
        -- the way of the drag itself, so close it before the move starts
        -- rather than leaving it open and fighting the reposition.
        if SB.CloseFavMenu then SB.CloseFavMenu() end
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
        PerformMiniIconClick(mouseButton)
    end)

    icon:SetScript("OnEnter", function(self)
        -- Anchor toward whichever side the Mini Soundbook/Quick Options do
        -- NOT expand into, so this tooltip never overlaps a hover-opened
        -- favMenu sitting right next to the icon. Reuses the same
        -- direction the popups themselves resolve (SB.ResolvePopoutDirection)
        -- rather than a second, independent screen-edge calculation, and
        -- maps it to the opposite GameTooltip anchor.
        local oppositeAnchor = {
            LEFT = "ANCHOR_RIGHT", RIGHT = "ANCHOR_LEFT",
            UP = "ANCHOR_BOTTOM", DOWN = "ANCHOR_TOP",
        }
        local direction = SB.ResolvePopoutDirection(self)
        GameTooltip:SetOwner(self, oppositeAnchor[direction] or "ANCHOR_LEFT")
        GameTooltip:SetText("Mini Soundbook", unpack(Theme.GOLD))
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
        GameTooltip:AddLine("Right Click: Open Soundbook", 0.85, 0.9, 1)
        GameTooltip:AddLine("Shift + Right Click: Quick Options", 0.85, 0.9, 1)
        GameTooltip:Show()
    end)
    icon:SetScript("OnLeave", function()
        -- Tooltip persistence (explicit requirement): while the Mini
        -- Soundbook this icon just hover-opened is still up, a leave here
        -- is very likely the cursor transiting toward it (favMenu is
        -- anchored immediately adjacent to the icon) - keep the SAME
        -- tooltip up instead of hiding it only to need a fresh re-show.
        -- Dismissed once that hover interaction actually ends (favMenu's
        -- own OnHide below clears it), or through the normal tooltip
        -- lifecycle (another element's own OnEnter simply replacing it) -
        -- no second tooltip implementation, the existing one just isn't
        -- torn down early.
        if favMenu and favMenu:IsShown() and miniOpenedViaHover then return end
        GameTooltip:Hide()
    end)

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

    -- Re-arms the hover gate (see this file's own "Hover re-arm gate"
    -- section above) only on a LEAVE where the cursor is verified to
    -- really be off the icon - an OnLeave that fires while a popup's
    -- catcher is simply stacking above the icon (cursor never actually
    -- moved) must not count, or the very next spurious OnEnter that
    -- follows the popup closing would incorrectly reopen the Mini
    -- Soundbook underneath it.
    icon:HookScript("OnLeave", function()
        if not IsCursorActuallyOnIcon() then
            miniHoverGateArmed = true
        end
    end)

    -- Hover-open, gated by SB.db.ui.announcer.openOnHover AND the re-arm
    -- gate above - purely native OnEnter-edge-triggered (fires once per
    -- genuine transition into the icon's bounds), but a genuine-looking
    -- OnEnter is not by itself enough proof of a genuine hover: a
    -- full-screen popup catcher closing while the cursor still rests on
    -- the icon also fires one, with no real mouse movement at all (see
    -- the gate section above) - the gate is what tells those two apart.
    -- Left-click keeps working regardless of this setting; this hook
    -- only ADDS the hover trigger. HandleMiniIconHoverEnter is defined
    -- later alongside the proximity/surface system and referenced here
    -- as a forward-declared upvalue.
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

    -- Icon/text/duration/track are ALL fully positioned by
    -- RelayoutBannerHeight below (called once here via
    -- SB:RefreshAnnouncerFont, and again on every font/scale change) -
    -- the icon's own size depends on the computed content height, so no
    -- point here can be fixed independently of that layout pass. No
    -- SetPoint calls in this constructor are load-bearing.
    local slot = Theme.CreateIconSlot(banner)
    banner.slot = slot

    local nameText = banner:CreateFontString(nil, "OVERLAY")
    nameText:SetFontObject(SB.Fonts.HighlightSmall)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    banner.nameText = nameText

    local timeText = banner:CreateFontString(nil, "OVERLAY")
    timeText:SetFontObject(SB.Fonts.DisableSmall)
    timeText:SetJustifyH("RIGHT")
    timeText:SetTextColor(unpack(V3.TEXT_SECONDARY))
    banner.timeText = timeText

    local subText = banner:CreateFontString(nil, "OVERLAY")
    subText:SetFontObject(SB.Fonts.DisableSmall)
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

    -- Overlap markers (one thin vertical line per OTHER currently-playing
    -- sound, replacing the old "+N" badge) are pooled textures on `track`
    -- itself, created lazily - see RefreshOverlapMarkers below. No fixed
    -- pool here; banner.markers starts empty.

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
-- Overlap markers: a thin vertical line inside the progress bar for
-- every OTHER currently-playing sound - explicit replacement for the old
-- numeric "+N" badge. Each marker moves entirely independently, driven
-- purely by that ONE background sound's own elapsed/duration (0% at its
-- own start, 100% when IT finishes) - deliberately never relative to the
-- primary's own remaining time. An earlier version positioned a marker at
-- `remaining / primaryRemaining`: since both numerator and denominator
-- shrink by the same real-time amount every tick, that fraction actually
-- DECREASES over time whenever the background sound is shorter than the
-- primary's own remaining duration (a live report: "one indicator moved
-- backwards") - a background-only, elapsed-based fraction is monotonic by
-- construction as long as its own startedAt/duration don't change, which
-- they never do while the same tracked instance stays active. Pooled
-- textures parented to `track` itself, created lazily and reused frame to
-- frame - deliberately not a generic animation framework, just this one
-- small pool for this one feature.
------------------------------------------------------------------------

local function GetOrCreateOverlapMarker(index)
    banner.markers = banner.markers or {}
    local marker = banner.markers[index]
    if not marker then
        -- A gold core (matching the primary bar's own orange/gold fill)
        -- barely registered against that same fill - not enough hue
        -- separation to read as a distinct, secondary signal. Arcane cyan
        -- (V3.ARCANE_CYAN, the same family the Mini Soundbook's own
        -- backdrop/chrome uses) sits opposite gold/orange on the colour
        -- wheel, so it reads as clearly "different" against both the
        -- filled and unfilled portions of the bar; the dark shadow layer
        -- behind it keeps it visible over light art too. `shadow` is
        -- OVERLAY so it draws above `fill` (ARTWORK); `core` is created
        -- after it so it layers on top within the same sublevel.
        local shadow = banner.track:CreateTexture(nil, "OVERLAY")
        shadow:SetTexture("Interface\\Buttons\\WHITE8X8")
        shadow:SetWidth(4)
        shadow:SetVertexColor(0, 0, 0, 0.55)

        local core = banner.track:CreateTexture(nil, "OVERLAY")
        core:SetTexture("Interface\\Buttons\\WHITE8X8")
        core:SetWidth(2)
        core:SetVertexColor(V3.ARCANE_CYAN[1], V3.ARCANE_CYAN[2], V3.ARCANE_CYAN[3], 1)

        marker = { shadow = shadow, core = core }
        banner.markers[index] = marker
    end
    return marker
end

local function HideAllOverlapMarkers()
    if not (banner and banner.markers) then return end
    for _, marker in ipairs(banner.markers) do
        marker.shadow:Hide()
        marker.core:Hide()
    end
end

-- Recomputed on every progress tick (continuous movement as playback
-- progresses) AND immediately whenever a background sound starts or
-- ends (never waiting for the next tick to appear/disappear). Reads
-- activeDisplays directly and touches only the marker pool - never the
-- primary's own fill width or elapsed/duration text, so this can run
-- freely without risking the "reset to 0" class of bug that motivated
-- keeping this fully separate from RenderPrimary's own ticker state.
local function RefreshOverlapMarkers()
    if not banner or not banner.track then return end
    banner.markers = banner.markers or {}
    local now = GetTime()
    local trackW = math.max(1, (banner.track:GetWidth() or 1) - 2) -- same 1px-per-side inset the fill itself uses
    local shown = 0
    for i = 1, #activeDisplays - 1 do -- every entry EXCEPT the primary (last)
        local entry = activeDisplays[i]
        if ValidDuration(entry.duration) then
            -- Entirely this ONE entry's own elapsed/duration - never the
            -- primary's. Clamped 0..1 so a tick landing slightly past the
            -- real end (before its own PLAYBACK_PROGRESS_ENDED removes it
            -- from activeDisplays) sits at the right edge rather than
            -- overshooting it, and never goes negative for a just-started
            -- instance whose startedAt is (rarely) a hair in the future.
            local elapsed = now - (entry.startedAt or now)
            local fraction = math.max(0, math.min(1, elapsed / entry.duration))
            shown = shown + 1
            local marker = GetOrCreateOverlapMarker(shown)
            local x = 1 + trackW * fraction
            for _, part in ipairs({ marker.shadow, marker.core }) do
                part:ClearAllPoints()
                part:SetPoint("TOP", banner.track, "TOPLEFT", x, -1)
                part:SetPoint("BOTTOM", banner.track, "BOTTOMLEFT", x, 1)
                part:Show()
            end
        end
        -- An entry with no known duration simply can't be placed on this
        -- timeline - no marker for it, never a guessed position (explicit
        -- requirement: respect existing tracking limitations rather than
        -- inventing playback state).
    end
    for i = shown + 1, #banner.markers do
        banner.markers[i].shadow:Hide()
        banner.markers[i].core:Hide()
    end
end

------------------------------------------------------------------------
-- Persistent "RAID MUTED" banner: an active Raid Admin restriction must
-- be unmistakable even while the Announcer is otherwise idle. Reuses the
-- same banner frame/elements RenderPrimary uses for a real sound, fed
-- different content. Wired into CollapseToIdle below, the one place
-- every "nothing real left to show" path funnels through, so it needs
-- no separate call sites.
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
    -- "RAID MUTED" covers both an individual admin mute and Mute All alike;
    -- the subtitle line spells out the actual scope difference.
    banner.nameText:SetText("RAID MUTED")
    banner.nameText:SetTextColor(RAID_MUTE_COLOR[1], RAID_MUTE_COLOR[2], RAID_MUTE_COLOR[3])
    banner.subText:SetText(ov.mutedAll and "Sending & receiving disabled" or "Sending to Raid/Party + Guild disabled")
    banner.subText:SetTextColor(unpack(V3.TEXT_SECONDARY))
    HideAllOverlapMarkers()
    banner.fill:SetVertexColor(RAID_MUTE_COLOR[1], RAID_MUTE_COLOR[2], RAID_MUTE_COLOR[3], 1)

    StopRaidMuteTicker()
    if ov.expiresAt and (ov.durationCode == "30" or ov.durationCode == "60") then
        -- Live countdown; the fill also drains as a visual progress-style
        -- cue, reusing the same element a real sound's own duration bar uses.
        banner.track:Show()
        banner.fill:Show()
        TickRaidMuteBanner()
        raidMuteTicker = C_Timer.NewTicker(1, TickRaidMuteBanner)
    else
        -- F/B/R: semantic label only - never show the internal safety-net
        -- timer as if it were the real duration.
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
    -- position - a real playback event must not overwrite it. activeDisplays
    -- is still updated normally by the caller; RestoreRealAnnouncerState()
    -- repaints from it once the preview ends.
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
    -- Progress bar takes on the channel's own colour (green for Guild, etc.)
    -- instead of always gold - same SB.CHANNEL_COLOR semantics used
    -- everywhere else a channel is shown.
    banner.fill:SetVertexColor(color.r, color.g, color.b, 1)

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
        -- Never fake a percentage for an unknown duration - hide the bar
        -- entirely rather than guess. No timeline to place overlap
        -- markers against either.
        banner.track:Hide()
        banner.fill:Hide()
        HideAllOverlapMarkers()
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
            -- Continuous marker movement, driven off the SAME tick as the
            -- primary's own fill - never resets/touches the fill or time
            -- text itself.
            RefreshOverlapMarkers()
        end)
        RefreshOverlapMarkers()
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
    -- active. This is the one place every "nothing real left" path funnels
    -- through, so a genuine mute/unmute/expiry (RAID_OVERRIDE_CHANGED,
    -- below) just calls this again to pick the right one.
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
-- Event wiring (SoundPlayer.lua / Communication.lua).
------------------------------------------------------------------------

local LOCAL_TARGET_LABEL = { GUILD = "Guild", PARTY = "Party", RAID = "Raid", FRIENDS = "Friends", ALL = "All" }
local function LocalTargetToChannelLabel(target)
    if not target or target == "SELF" then return "Self" end
    if type(target) == "string" and target:match("^PLAYER:") then return "Direct" end
    return LOCAL_TARGET_LABEL[target] or "Self"
end

local function AddDisplay(soundID, sender, channelLabel)
    -- No Now Playing display at all while the HUD itself is hidden (a
    -- fresh install defaults to hidden - see Core.lua's "safer first start").
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
        -- instanceID (SoundPlayer.lua's playback-instance token, may be nil if
        -- this call wasn't paired with a PLAYBACK_PROGRESS_STARTED) is the one
        -- true correlator for PLAYBACK_PROGRESS_ENDED below - never the WoW
        -- handle (can be nil, can't distinguish handle-less instances) and
        -- never soundID alone (would confuse overlapping instances of the
        -- same sound).
        instanceID = instanceID,
    })
    if collapseTimer then collapseTimer:Cancel(); collapseTimer = nil end
    RenderPrimary()
    -- The newly-added entry is now primary; whatever was primary before
    -- (if anything) is demoted to a background sound and needs its own
    -- overlap marker placed immediately, not just on the next tick.
    RefreshOverlapMarkers()
end

-- Instance-scoped removal (unlike SB.RemoveAnnouncerDisplayForSound above,
-- which is soundID-scoped for its callers - a retrigger's own dedup, and a
-- sound going muted). Used by the ENDED handler below, including from a
-- deferred minimum-display-duration timer - safe to call on an instanceID
-- that's already gone: finds nothing, does nothing.
--
-- Bugfix (progress-stability regression): this used to call RenderPrimary()
-- unconditionally whenever ANY tracked instance ended, including a
-- background/overlapping sound that was never the displayed (last/
-- primary) entry in the first place. RenderPrimary() does a FULL repaint -
-- resets banner.fill to near-zero width and restarts the progress ticker
-- from scratch - so ending an unrelated background sound made the
-- CURRENTLY DISPLAYED sound's own progress visibly flash/reset to 0
-- before the ticker's next tick caught it back up, even though the
-- primary itself never actually changed. Only a removal that was ITSELF
-- the primary entry is a genuine primary change and warrants the full
-- repaint; a background entry ending only ever needs its own overlap
-- marker removed, never a repaint of the untouched primary.
local function RemoveDisplayByInstance(instanceID)
    local removed, removedWasPrimary = false, false
    for i = #activeDisplays, 1, -1 do
        if activeDisplays[i].instanceID == instanceID then
            removedWasPrimary = (i == #activeDisplays)
            table.remove(activeDisplays, i)
            removed = true
        end
    end
    if not removed then return end
    if #activeDisplays > 0 and not removedWasPrimary then
        -- The primary is unchanged - only recompute overlap markers
        -- (the ended sound's own marker disappears immediately), never
        -- touch the primary's own fill/ticker/text.
        RefreshOverlapMarkers()
    elseif #activeDisplays > 0 then
        RenderPrimary()
    else
        ScheduleCollapse()
    end
end

SB:On("PLAYBACK_PROGRESS_STARTED", function(state)
    if not state then return end
    pendingStart = { soundID = state.soundID, handle = state.handle, duration = state.duration, startedAt = GetTime(), instanceID = state.instanceID }
end)

-- The Announcer must never disappear before the configured Announcement
-- Duration minimum, but must also never linger past a known duration
-- just because C_Sound.IsPlaying still claims otherwise (see
-- SoundPlayer.lua's duration-ceiling handling). Matched purely by
-- instanceID, never by handle (SoundPlayer.lua allows that to be nil,
-- and it can't tell two handle-less instances apart anyway).
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
    -- The persistent header state appears/clears automatically the moment
    -- the restriction is applied/lifted/expires. CollapseToIdle already
    -- decides between the Raid Admin display and the bare idle icon, so a
    -- genuine change just re-runs it (only while nothing real is playing -
    -- a real sound's banner wins and falls through to CollapseToIdle once
    -- it naturally ends).
    if icon and #activeDisplays == 0 then
        BuildBanner()
        CollapseToIdle()
    end
end)
SB:On("RECEIVE_MUTE_CHANGED", RefreshIndicators)

------------------------------------------------------------------------
-- Quick Options - compact right-click menu on the idle icon: mute
-- incoming, lock, muted players, open Settings.
------------------------------------------------------------------------

local quickMenu

-- Shared preview content for BOTH the Announcer Size slider's resize
-- preview and the icon-drag preview - one content function, reusing the
-- real banner frame and elements rather than a second mocked-up layout.
-- Deliberately fixed/deterministic, never real user data (see the "test"
-- source handling in SB:PlaySound).
local function PopulatePreviewBanner()
    BuildBanner()
    banner.soundbookSoundID = nil
    banner.slot.texture:SetTexture(SB.APP_ICON or SB.DEFAULT_ICON)
    banner.nameText:SetText("Announcer Preview")
    banner.nameText:SetTextColor(unpack(V3.TEXT_PRIMARY))
    local color = SB.GetChannelColor("Raid")
    banner.subText:SetText(string.format("Preview |cff%s- Raid|r", color.hex))
    banner.fill:SetVertexColor(color.r, color.g, color.b, 1)
    HideAllOverlapMarkers()
    banner.track:Show()
    banner.fill:Show()
end

------------------------------------------------------------------------
-- Icon-drag preview: while dragging the Soundbook icon, show the same
-- populated Announcer preview, repositioning live as the icon crosses
-- screen regions (see SB.ResolvePopoutDirection), so the automatic
-- placement rule is understandable just by watching it happen. Also
-- carries a deliberate 10-second easter egg: while the preview's progress
-- bar completes a 10-second cycle, one random LOCAL-ONLY sound plays and
-- the cycle restarts, for as long as the drag continues.
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
    -- SB:TriggerSound, which dispatches to the "Send to:" default/Guild/
    -- Raid/Friends/a direct target. PlaySound on its own only ever plays
    -- audio on THIS client - no addon message, no ACK, no History entry,
    -- no routing. The "test" source also excludes it from the New-Sound-
    -- heard counter (SoundPlayer.lua). A UI easter egg, never multiplayer
    -- behaviour.
    SB:PlaySound(soundID, "test")
end

-- Runs every frame ONLY while the icon is actively being dragged;
-- StopIconDragPreview below unconditionally detaches it the instant the
-- drag ends - there is no idle polling, this handler exists for zero
-- frames outside an active drag. Recomputing direction/position every
-- tick (rather than diffing against the last region) is deliberately
-- simple since both are O(1).
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
    -- CollapseToIdle fades the banner to alpha 0 then Hides it once nothing
    -- real is left to show; without resetting alpha here, a bare Show() would
    -- leave that faded-out alpha in place and the preview would be invisible.
    if UIFrameFadeRemoveFrame then UIFrameFadeRemoveFrame(banner) end
    banner:SetAlpha(1)
    banner:Show()
    icon:SetAlpha(1)
    icon:SetScript("OnUpdate", DragPreviewOnUpdate)
end

-- No delayed callback (C_Timer.After) anywhere in this feature - the
-- 10-second cycle runs synchronously inside DragPreviewOnUpdate, which
-- this unconditionally detaches before returning. That makes "a sound
-- fires after the mouse was already released" structurally impossible
-- without needing a drag-session token.
function StopIconDragPreview()
    if not dragPreviewActive then return end
    dragPreviewActive = false
    icon:SetScript("OnUpdate", nil)
    dragCandidateSounds = nil
    RestoreRealAnnouncerState()
end

------------------------------------------------------------------------
-- Favourites quick-play menu: left-click the icon opens up to 20
-- Favourites as a responsive icon grid (same icon+name row style as the
-- Library's entries - see UI.lua's LayoutEntries), titled with exactly
-- where a click will actually send them. Column/card layout is fully
-- content- and size-driven (see GetFavMenuLayout below). Picking
-- a sound plays it through SB:TriggerSound with no override, identical
-- to a normal Library click.
------------------------------------------------------------------------

-- favMenu itself is declared at the top of this file (hoisted for
-- BuildIcon's own tooltip-persistence hook) - not re-declared here.

local BUCKET_LABEL = { GUILD = "Guild", RAID = "Raid", FRIENDS = "Friends" }

-- Explicit request: the recipient phrase (names or the "Guild (3)"
-- fallback alike - one coherent "who this goes to" segment, not an
-- arbitrary split) renders in that channel's own colour, the same
-- SB.CHANNEL_COLOR hex every other Guild/Raid/Friends label in the addon
-- already uses (chat lines, the Send-to dropdown's own rows) - a plain
-- embedded WoW colour code inside favMenu.title's single FontString, so
-- the surrounding "Play for "/":" wrapper stays the header's normal gold.
-- GetStringWidth() correctly ignores |cxxxxxxxx/|r escapes for layout
-- purposes, so this never skews the fit-check.
local function ColorizeForBucket(text, bucket)
    local color = SB.CHANNEL_COLOR and SB.CHANNEL_COLOR[bucket]
    if not color or not color.hex then return text end
    return "|cff" .. color.hex .. text .. "|r"
end

-- The title describes exactly what the SAME single-select Default
-- Output (SB.db.settings.defaultOutputTarget, the Main window's "Send
-- to:" control) would actually use for a normal click - never a
-- separately-computed guess. Reads live reachable-player counts
-- (SB.ComputeReachablePlayers, the same source used everywhere else).
-- @return total (int), perBucket ({GUILD=n, RAID=n, FRIENDS=n}),
--         isLocal (bool), directName (string or nil), isAllTarget (bool),
--         singleBucketNames (array of realm-qualified names, or nil - only
--         populated for the single-bucket GUILD/RAID/FRIENDS case, the
--         actual effective recipient list a send would use right now)
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
        -- A per-player recipient subset (Communication.lua) narrows this
        -- bucket's live reach below its full reachable count - read the
        -- actual effective recipient LIST (not just a count) so the
        -- title can show their real names when they fit (explicit
        -- request) - falls back to the plain reachable list when no
        -- subset is active, same fallback SB.GetChannelSubsetCount uses.
        local names = SB.ComputeChannelSubsetRecipients and SB.ComputeChannelSubsetRecipients(target)
        if not names then names = reachable[target] or {} end
        local n = #names
        -- Always recorded, including 0 - explicit requirement: a channel
        -- with zero selected recipients must read "Guild (0)", never
        -- silently fall back to "Play for Yourself" as if it were plain
        -- Self Only. isLocal is therefore unconditionally false here;
        -- only a genuine SELF target (above) or "All" with nothing
        -- reachable (below) still counts as local.
        perBucket[target] = n
        total = n
        return total, perBucket, false, nil, false, names
    end
    -- "ALL" (default/fallback) - every currently Send-enabled channel,
    -- exactly matching SB:BroadcastSound's own modes-driven fan-out.
    for _, bucket in ipairs({ "GUILD", "RAID", "FRIENDS" }) do
        if modes[bucket] then CountBucket(bucket) end
    end
    return total, perBucket, total == 0, nil, true, nil
end

-- Explicit request: when the selected channel's actual recipient names
-- would fit the Mini Soundbook's title bar, show them ("Alice and Bob")
-- instead of a bare count ("Guild (3)") - GetFavMenuHeaderText below
-- decides whether this candidate actually fits (it owns the "Play for "/
-- ":" wrapping and the real pixel measurement, never a name-count
-- ceiling here - any number of names is a valid candidate; whether it
-- actually renders within the available width is entirely the
-- measurement's call, not a guess based on how many there are).
local function JoinNamesNaturally(names)
    local n = #names
    if n == 1 then return names[1] end
    if n == 2 then return names[1] .. " and " .. names[2] end
    return table.concat(names, ", ", 1, n - 1) .. " and " .. names[n]
end
local function BuildNamesCandidate(names)
    if not names or #names == 0 then return nil end
    local displayNames = {}
    for _, name in ipairs(names) do
        table.insert(displayNames, (SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(name)) or name)
    end
    return JoinNamesNaturally(displayNames)
end

-- Describes the CURRENT Default Output target as a short phrase
-- ("Guild (10)", "People (6)", "Bob", ...) plus an optional secondary
-- breakdown line ("Guild (4)  -  Friends (2)") for the multi-source "All"
-- case, and (4th return) a names-list candidate GetFavMenuHeaderText may
-- prefer over the count phrase if it fits. `isLocal` is true ONLY for a
-- genuine Self Only target, or "All" with zero real recipients under any
-- currently Send-enabled channel - a single Guild/Raid/Friends target
-- with zero SELECTED recipients is deliberately NOT local: it must read
-- "Guild (0)" (explicit requirement - "so it is obvious that nothing
-- will be broadcast"), never be silently folded into "Play for
-- Yourself" as if the player had picked Self Only. "People" (never "N
-- people" or a per-channel label) is used whenever more than one
-- channel contributes a real recipient under "All", or whenever "All"
-- is the target at all, even if only one channel happens to have anyone
-- reachable right now - the user's actual intent was "everyone", not
-- one specific group.
local function DescribeEffectiveTargetPhrase()
    local total, perBucket, isLocal, directName, isAllTarget, singleBucketNames = ComputeLiveTargetCounts()
    if directName then return directName, nil, false end
    if isLocal then return "locally", nil, true end

    -- Existence (not "> 0") is what marks a bucket as "the/a contributing
    -- target" - a single Guild/Raid/Friends target with 0 selected still
    -- sets perBucket[target] = 0 (see ComputeLiveTargetCounts above), and
    -- must still be recognized as that one bucket here, not silently
    -- dropped into the multi-bucket "People" formatting below.
    local contributing, onlyBucket = 0, nil
    for _, bucket in ipairs({ "GUILD", "RAID", "FRIENDS" }) do
        if perBucket[bucket] ~= nil then
            contributing = contributing + 1
            onlyBucket = bucket
        end
    end

    if not isAllTarget and contributing <= 1 and onlyBucket then
        local countPhrase = ColorizeForBucket(string.format("%s (%d)", BUCKET_LABEL[onlyBucket], perBucket[onlyBucket]), onlyBucket)
        local namesCandidate = BuildNamesCandidate(singleBucketNames)
        if namesCandidate then namesCandidate = ColorizeForBucket(namesCandidate, onlyBucket) end
        return countPhrase, nil, false, namesCandidate
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

-- A per-sound "Default Output" override on one of the VISIBLE Favourites
-- would make a header promising "Play for X:" misleading for that sound
-- - it won't actually go there. Switches to "Default destination: X"
-- (describing what applies to everything WITHOUT its own override)
-- whenever at least one visible Favourite has one; GetOrCreateFavMenuRow
-- below adds a routing badge on that sound's tile so it's clear WHICH
-- one differs.
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

-- `availableWidth` (optional) is the actual pixel width the title line is
-- about to render at this pass (favMenu's own content width minus its
-- fixed insets - see PopulateFavMenu, which computes it BEFORE calling
-- this so it's never a render stale) - when given, a names candidate
-- from DescribeEffectiveTargetPhrase is measured against favMenu.title's
-- own font and used instead of the count phrase if the full wrapped
-- line ("Play for Alice and Bob:") actually fits; omitted or a no-fit
-- always falls back to the count phrase exactly as before.
local function GetFavMenuHeaderText(availableWidth)
    local phrase, secondary, isLocal, namesCandidate = DescribeEffectiveTargetPhrase()
    local overridesPresent = AnyVisibleFavouriteHasOverride()
    -- "Play for Yourself" reads as plain language (vs. technical "Play
    -- locally") and is used consistently everywhere this Mini Soundbook
    -- state is presented.
    if isLocal then
        return (overridesPresent and "Default destination: Play for Yourself" or "Play for Yourself:"), secondary
    end

    local function Wrap(who)
        return overridesPresent and ("Default destination: " .. who) or ("Play for " .. who .. ":")
    end

    if namesCandidate and availableWidth and favMenu and favMenu.title then
        local namesHeader = Wrap(namesCandidate)
        local previousText = favMenu.title:GetText()
        favMenu.title:SetText(namesHeader)
        local fits = favMenu.title:GetStringWidth() <= availableWidth
        favMenu.title:SetText(previousText)
        if fits then return namesHeader, secondary end
    end

    return Wrap(phrase), secondary
end

-- favMenu.title's own left/right anchor insets (see BuildFavMenu below,
-- "TOPLEFT 10,-8" / "RIGHT -10,0") - shared with PopulateFavMenu's own
-- title-fit-check width computation via this one constant, so the two
-- can never silently drift apart if the header's own insets ever change
-- (e.g. to make room for a future header control).
local FAV_TITLE_SIDE_INSET = 10

------------------------------------------------------------------------
-- Responsive favourite grid (explicit redesign - the old count-only
-- column table could still collapse 20 favourites into one giant
-- vertical column at large Mini Soundbook Size). Column count, card
-- width AND card height are now all derived together, in "1x" reference
-- units (the whole favMenu frame carries its own separate SetScale from
-- the Mini Soundbook Size slider - SB.db.ui.announcer.favScale - so
-- these multiply out uniformly at render time, same as before).
------------------------------------------------------------------------
local MAX_FAV_COLUMNS = 5
-- Row height adapts to how many rows are actually needed (fewer rows ->
-- taller, more readable cards; many rows -> shrinks back down), bounded
-- so a short list never gets comically tall cards and a long one never
-- shrinks past legibility.
local ROW_H_MIN, ROW_H_MAX = 22, 36
-- Soft TOTAL content-height budget (1x units) row height is solved
-- against - not a hard cap (ROW_H_MIN already floors individual rows
-- below it when there are enough of them), just what "use the extra
-- space, don't leave a huge empty row" is measured relative to.
local GRID_SOFT_H = 300
-- Card width per candidate column count (1x units), not derived from a
-- strict height*aspect formula - deriving width strictly from row height
-- leaves no usable headroom against MIN_REAL_COL_W across the full 0.5-2.0
-- Mini Soundbook Size range (ROW_H_MAX*aspect ends up BELOW the width a
-- card needs just to hold an icon + a few characters). These values are
-- hand-verified to land each column count's REAL (post-favScale) width
-- above MIN_REAL_COL_W across smoothly graduated, non-cliff favScale
-- thresholds (col=5 needs scale>=0.95, col=4>=0.864, col=3>=0.76,
-- col=2>=0.633, col=1>=0.5 - the slider's own minimum), and each one sits
-- within the requested ~2.0-3.0:1 width:height "sound card" shape against
-- ROW_H_MIN/ROW_H_MAX.
local FAV_COL_W = { [1] = 190, [2] = 150, [3] = 125, [4] = 110, [5] = 100 }
-- More than this many rows in a column reads as "one giant vertical
-- list" (the exact regression report) - escalate to more columns
-- instead, provided the real legibility floor below still allows it.
local ROWS_SOFT_MAX = 6
-- Below this REAL (post-favScale) card width, a column can no longer
-- comfortably fit its icon plus a few readable characters of name - the
-- one thing that can still reduce (never escalate into) columns, mostly
-- biting at a small Mini Soundbook Size with a high favourite count.
local MIN_REAL_COL_W = 95
-- Icon grows/shrinks with the chosen row height, within its own sensible
-- bounds - explicit requirement, never so small it's unreadable, never
-- so large a tall card looks like an oversized button.
local ICON_MIN, ICON_MAX = 16, 30

-- Content-driven preferred column count, purely from how many Favourites
-- currently exist - a short list reads better as a vertical stack than
-- stretched thin across a wide, mostly-empty row. The starting point for
-- GetFavMenuLayout below, which then adapts it for real available
-- height/width - not the final answer on its own anymore.
local function PreferredColumnsForCount(count)
    if count <= 3 then return 1
    elseif count <= 6 then return 2
    elseif count <= 12 then return 3
    elseif count <= 16 then return 4
    else return MAX_FAV_COLUMNS end
end

-- Card width/height (1x units) and resulting row count for a candidate
-- column count against the current favourite count - row height solved
-- from the soft height budget (fewer rows -> taller cards, many rows ->
-- shrinks back down), card width taken from the per-column-count table.
local function ComputeCardMetrics(columns, count)
    local rows = math.ceil(count / columns)
    local rowH = math.min(ROW_H_MAX, GRID_SOFT_H / rows)
    rowH = math.max(ROW_H_MIN, rowH)
    local colW = FAV_COL_W[columns] or FAV_COL_W[MAX_FAV_COLUMNS]
    return colW, rowH, rows
end

-- Full layout decision: columns, card width/height (1x units), and the
-- resulting row count. Starts from the content-driven preferred column
-- count, escalates toward more (narrower) columns when that would
-- otherwise produce a tall pile of rows (bounded by MAX_FAV_COLUMNS and
-- the real legibility floor), then reduces back down whenever the
-- REAL (post-favScale) result has gone unusably narrow. Escalation is
-- checked and applied one step at a time and reduction is a hard, always-
-- final constraint, so the two passes can never fight each other into an
-- oscillation - the same (count, favScale) input always resolves to the
-- same columns.
local function GetFavMenuLayout(count)
    count = count or 0
    if count <= 0 then return 1, FAV_COL_W[1], ROW_H_MIN, 0 end
    local scale = (SB.db.ui.announcer and SB.db.ui.announcer.favScale) or 1
    local columns = PreferredColumnsForCount(count)
    local colW, rowH, rows = ComputeCardMetrics(columns, count)

    while rows > ROWS_SOFT_MAX and columns < MAX_FAV_COLUMNS do
        local nextColW = ComputeCardMetrics(columns + 1, count)
        if (nextColW * scale) < MIN_REAL_COL_W then break end
        columns = columns + 1
        colW, rowH, rows = ComputeCardMetrics(columns, count)
    end

    while columns > 1 and (colW * scale) < MIN_REAL_COL_W do
        columns = columns - 1
        colW, rowH, rows = ComputeCardMetrics(columns, count)
    end

    return columns, colW, rowH, rows
end

-- Icon+name row, same visual language as UI.lua's CreateEntryButton (icon
-- left, name right, flat accent hover) just compact enough to tile 2-3 per
-- line. The keybind moved to a hover tooltip instead of its own label -
-- there isn't enough per-tile width left for it once the row is narrowed
-- down to a grid column.
-- Additive to the existing hover highlight (`hl`) and per-item progress
-- fill, never a replacement: a thin gold outline shown while the row is
-- hovered OR while its own sound is currently playing (derived, not a
-- separate flag, from `progressFill:IsShown()` - the two states already
-- drive that fill so this can never drift out of sync with it), and
-- never doubled when both are true at once since it's a single on/off
-- border, not two stacked layers.
local function UpdateRowBorder(row)
    local visible = row.isHovered or (row.progressFill and row.progressFill:IsShown())
    if visible then
        row:SetBackdropBorderColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 1)
    else
        row:SetBackdropBorderColor(0, 0, 0, 0)
    end
    -- SetBackdropBorderColor has no getter - mirror the on/off state in a
    -- plain field so it can be asserted on directly (by tests, or future
    -- code) without re-deriving it.
    row._borderShown = visible
end

local function GetOrCreateFavMenuRow(index)
    if favMenu.rows[index] then return favMenu.rows[index] end
    local row = SB.CreateFrame("Button", nil, favMenu.content)
    row:SetHeight(ROW_H_MIN) -- placeholder only, PopulateFavMenu always resizes this to the current layout's row height
    -- Row border insets deliberately at 0 (SetBackdrop with edgeFile/
    -- edgeSize alone, no bgFile - the exact same "border-only" pattern
    -- already used for UI.lua's favouriteHover) so it sits right at the
    -- row's own edge, never overlapping the icon/text content inside it.
    row:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    row:SetBackdropBorderColor(0, 0, 0, 0)
    row._borderShown = false
    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(Theme.ACCENT[1], Theme.ACCENT[2], Theme.ACCENT[3], 0.15)
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", 4, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon
    -- Small routing badge, shown only on a sound with its own per-sound
    -- "Default Output" override, so it's clear which Favourite(s) don't
    -- follow the header summary. Same colour source as the Library's own
    -- override tint (SB.SoundOutputOverrideColor, Communication.lua).
    local overrideDot = row:CreateTexture(nil, "OVERLAY")
    overrideDot:SetSize(7, 7)
    overrideDot:SetPoint("TOPRIGHT", icon, "TOPRIGHT", 1, 1)
    overrideDot:SetTexture("Interface\\Buttons\\WHITE8X8")
    overrideDot:Hide()
    row.overrideDot = overrideDot
    -- Per-row playback progress (explicit requirement: the clicked slot
    -- itself shows progress while the Mini Soundbook stays open, instead
    -- of closing on click) - a plain left-to-right fill BEHIND the icon/
    -- text (BACKGROUND draw layer, below the HIGHLIGHT hover texture and
    -- both ARTWORK/OVERLAY content), so neither stays readable is ever
    -- compromised and hovering still shows its own highlight on top as
    -- before. Driven entirely by the shared PLAYBACK_PROGRESS_UPDATE/
    -- ENDED events (see the listeners below), the exact same broadcast
    -- the Announcer banner itself already listens to - no separate
    -- polling/ticker needed here.
    local progressFill = row:CreateTexture(nil, "BACKGROUND")
    progressFill:SetPoint("TOPLEFT", 0, 0)
    progressFill:SetPoint("BOTTOMLEFT", 0, 0)
    progressFill:SetWidth(0.01)
    progressFill:SetTexture("Interface\\Buttons\\WHITE8X8")
    progressFill:SetVertexColor(Theme.ACCENT[1], Theme.ACCENT[2], Theme.ACCENT[3], 0.28)
    progressFill:Hide()
    row.progressFill = progressFill
    local text = row:CreateFontString(nil, "OVERLAY")
    text:SetFontObject(SB.Fonts.HighlightSmall)
    text:SetPoint("LEFT", icon, "RIGHT", 5, 0)
    text:SetPoint("RIGHT", -4, 0)
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    row.text = text
    -- Explicit requirement: clicking a Favourite must NOT close the Mini
    -- Soundbook - the player can keep clicking further sounds while
    -- earlier ones (with overlap enabled) are still playing and showing
    -- their own row progress. The existing proximity/auto-collapse
    -- system (StartMiniProximityTicker et al.) is untouched and still
    -- closes it once the cursor actually leaves, independent of playback.
    row:SetScript("OnClick", function(self)
        if self.soundID then SB:TriggerSound(self.soundID) end
    end)
    row:SetScript("OnEnter", function(self)
        self.isHovered = true
        UpdateRowBorder(self)
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
    row:SetScript("OnLeave", function(self)
        self.isHovered = false
        UpdateRowBorder(self)
        GameTooltip:Hide()
    end)
    favMenu.rows[index] = row
    return row
end

local function BuildFavMenu()
    if favMenu then return favMenu end
    favMenu = SB.CreateFrame("Frame", "SoundbookFavMenu", UIParent)
    -- Real width is set every PopulateFavMenu call once the layout is
    -- known; this is just a sane initial value before the first populate.
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
    catcher:SetScript("OnClick", function(self, button)
        favMenu:Hide()
        catcher:Hide()
        -- The click only landed on this catcher because it covers the
        -- whole screen above the icon's own strata - if the cursor is
        -- actually over the icon (the common case: the Mini Soundbook is
        -- hover-open and the player then right-clicks the icon itself),
        -- this was meant for the icon's own click handling (Open
        -- Soundbook / Quick Options), not just "click outside to
        -- dismiss". Redispatch it now instead of swallowing it - see
        -- PerformMiniIconClick's own comment for why this matters.
        if IsCursorActuallyOnIcon() then
            PerformMiniIconClick(button)
        end
    end)
    favMenu.catcher = catcher
    favMenu:SetScript("OnHide", function()
        catcher:Hide()
        RestoreIconStrata()
        -- Ends the hover interaction cleanly (tooltip persistence above) -
        -- a real Hide() here always means the interaction is genuinely
        -- over (proximity-close, Escape, a row's own click-to-play, ...).
        if miniOpenedViaHover then GameTooltip:Hide() end
        miniOpenedViaHover = false
        if NoteMiniSurfaceHidden then NoteMiniSurfaceHidden() end
    end)

    favMenu.title = favMenu:CreateFontString(nil, "OVERLAY")
    favMenu.title:SetFontObject(SB.Fonts.Highlight)
    favMenu.title:SetPoint("TOPLEFT", FAV_TITLE_SIDE_INSET, -8)
    favMenu.title:SetPoint("RIGHT", -FAV_TITLE_SIDE_INSET, 0)
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

    -- No ScrollFrame: the popup shows every current Favourite at once (max
    -- SB.MAX_FAVOURITES, 20) with no scrollbar - PopulateFavMenu sizes both
    -- `content` and `favMenu` from the actual row count every time it runs,
    -- so fewer Favourites always means a smaller popup, never a fixed or
    -- clipped viewport.
    local content = CreateFrame("Frame", nil, favMenu)
    content:SetPoint("TOPLEFT", 4, -30)
    favMenu.content = content
    favMenu.rows = {}

    return favMenu
end

local function PopulateFavMenu()
    local favourites = SB.GetFavourites and SB:GetFavourites() or {}
    local favCount = 0
    for slot = 1, SB.MAX_FAVOURITES do
        if favourites[slot] then favCount = favCount + 1 end
    end

    -- Grid width/columns/row-height computed FIRST, before the header
    -- text - the title bar's own fit-check (GetFavMenuHeaderText's
    -- names-vs-count decision) needs the ACTUAL width this render is
    -- about to use, not whatever favMenu:GetWidth() still holds from the
    -- previous one.
    local columns, colW, rowH = GetFavMenuLayout(favCount)
    local gridW = columns * colW
    local iconSize = math.max(ICON_MIN, math.min(ICON_MAX, rowH - 6))
    -- FAV_TITLE_SIDE_INSET matches favMenu.title's own two-point anchor
    -- insets exactly (one constant, shared with BuildFavMenu's anchors -
    -- see its declaration above), so the measurement always lines up
    -- with what will actually render, including any future header
    -- control that narrows those insets.
    local titleAvailableWidth = (gridW + 8) - (2 * FAV_TITLE_SIDE_INSET)

    local primary, secondary = GetFavMenuHeaderText(titleAvailableWidth)
    favMenu.title:SetText(primary)
    favMenu.subtitle:SetShown(secondary ~= nil)
    if secondary then favMenu.subtitle:SetText(secondary) end

    -- Extra headroom when the secondary breakdown line is showing - measure
    -- the real rendered height rather than guessing a fixed offset.
    local subtitleH = secondary and ((favMenu.subtitle:GetHeight() or 0) + 2) or 0
    local topOffset = 30 + subtitleH
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
            row:SetSize(colW, rowH)
            row:SetPoint("TOPLEFT", col * colW, -(gridRow * rowH))
            -- Icon grows/shrinks with the row height this layout chose
            -- (see GetFavMenuLayout/ICON_MIN/ICON_MAX) - text stays
            -- anchored off the icon's own RIGHT edge (GetOrCreateFavMenuRow),
            -- so it re-flows automatically without any separate update.
            row.icon:SetSize(iconSize, iconSize)
            -- A pooled row being reassigned to a DIFFERENT sound (a real
            -- favourites reorder/replace, not just a repopulate for an
            -- unrelated reason like a font/selection change while this
            -- exact sound keeps playing) must not carry over a stale
            -- progress fill that belonged to whatever sound used to sit
            -- in this slot.
            if row.soundID ~= soundID then
                row.progressFill:Hide()
                row.progressFill:SetWidth(0.01)
                row.isHovered = false
                row.playStartedAt = nil
                row.playDuration = nil
                UpdateRowBorder(row)
            end
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

    -- Every row is laid out and shown above, so `content` and the popup
    -- both grow to fit all of them - GetFavMenuLayout already keeps the
    -- resulting row count bounded (ROWS_SOFT_MAX, escalating to more
    -- columns instead) so this never needs to scroll.
    local totalRows = math.ceil(shown / columns)
    local contentH = totalRows * rowH
    favMenu.content:SetHeight(math.max(1, contentH))

    local titleH = (shown == 0) and 46 or 24
    favMenu:SetHeight(topOffset + math.max(titleH - 22, contentH == 0 and 24 or contentH) + 10)
end

-- Drives each Favourite row's own progress fill directly off the same
-- shared PLAYBACK_PROGRESS_UPDATE/ENDED broadcast SoundPlayer.lua already
-- fires for every tracked instance (primary or background alike) - the
-- exact same events the Announcer banner listens to independently, so
-- there is no coordination/hand-off logic needed between the two: each
-- just reacts to the live state while it's actually visible. Gated on
-- the Mini Soundbook actually being open - no work at all while it's
-- closed, and nothing here ever affects the Announcer banner's own
-- display. A row is matched purely by soundID (never by instanceID),
-- since that's the only thing a row itself knows - two simultaneous
-- instances of the identical sound both update the same row, an
-- accepted, pre-existing tracking limitation (see SoundPlayer.lua's own
-- "ambiguous overlap" handling) rather than inventing per-row identity
-- Soundbook doesn't actually track.
local function FindFavMenuRowForSound(soundID)
    if not (favMenu and favMenu.rows) then return nil end
    for _, row in pairs(favMenu.rows) do
        if row.soundID == soundID and row:IsShown() then return row end
    end
    return nil
end

------------------------------------------------------------------------
-- Row progress: smooth visual interpolation, decoupled from the poll.
-- SoundPlayer.lua's own PLAYBACK_PROGRESS_UPDATE is driven by its
-- deliberately-paced polling ticker (POLL_INTERVAL, ~0.08s - a real
-- C_Sound/tracking cost, not something to run faster just for smoother
-- visuals). At that cadence a short sound's row fill visibly steps
-- instead of gliding. row.playStartedAt/row.playDuration below are set
-- from the SAME state.startedAt/state.duration the poll already
-- provides (never a separate/invented timing source - still the single
-- source of truth for duration and playback tracking); a small,
-- independent ~60fps ticker then repaints purely from
-- (now - playStartedAt) / playDuration, linearly, with no easing -
-- exactly the same maths PLAYBACK_PROGRESS_UPDATE itself uses, just
-- sampled far more often. It only exists, and only iterates, while the
-- Mini Soundbook is open AND at least one row actually has an active
-- duration - never an always-on ticker, and it never calls into
-- SoundPlayer.lua/C_Sound itself, so playback-status polling frequency
-- is completely unaffected.
------------------------------------------------------------------------

local ROW_PROGRESS_TICK = 1 / 60
local rowProgressTicker

local function StopRowProgressTicker()
    if rowProgressTicker then
        rowProgressTicker:Cancel()
        rowProgressTicker = nil
    end
end

local function AnyRowProgressActive()
    if not (favMenu and favMenu.rows) then return false end
    for _, row in pairs(favMenu.rows) do
        if row:IsShown() and row.playStartedAt and row.playDuration then return true end
    end
    return false
end

local function TickRowProgress()
    if not (favMenu and favMenu:IsShown()) then
        StopRowProgressTicker()
        return
    end
    local now = GetTime()
    local anyActive = false
    for _, row in pairs(favMenu.rows) do
        if row:IsShown() and row.playStartedAt and row.playDuration then
            anyActive = true
            local pct = math.max(0, math.min(1, (now - row.playStartedAt) / row.playDuration))
            row.progressFill:SetWidth(math.max(0.01, (row:GetWidth() or 1) * pct))
        end
    end
    if not anyActive then StopRowProgressTicker() end
end

local function StartRowProgressTickerIfNeeded()
    if rowProgressTicker then return end
    if not AnyRowProgressActive() then return end
    rowProgressTicker = C_Timer.NewTicker(ROW_PROGRESS_TICK, TickRowProgress)
end

SB:On("PLAYBACK_PROGRESS_UPDATE", function(state)
    if not (favMenu and favMenu:IsShown()) then return end
    if not state or not state.soundID then return end
    local row = FindFavMenuRowForSound(state.soundID)
    if not row then return end
    if not (type(state.duration) == "number" and state.duration == state.duration and state.duration > 0) then
        -- Never fake a percentage for an unknown duration, same rule the
        -- Announcer banner itself already follows.
        row.progressFill:Hide()
        row.playStartedAt = nil
        row.playDuration = nil
        UpdateRowBorder(row)
        return
    end
    local pct = state.progress or 0
    row.progressFill:SetWidth(math.max(0.01, (row:GetWidth() or 1) * pct))
    row.progressFill:Show()
    -- Source of truth for the fast ticker's own maths, taken directly
    -- from this poll tick's state - never recomputed or guessed.
    row.playStartedAt = state.startedAt
    row.playDuration = state.duration
    UpdateRowBorder(row)
    StartRowProgressTickerIfNeeded()
end)

SB:On("PLAYBACK_PROGRESS_ENDED", function(state)
    if not state or not state.soundID then return end
    local row = FindFavMenuRowForSound(state.soundID)
    if not row then return end
    row.progressFill:Hide()
    row.progressFill:SetWidth(0.01)
    row.playStartedAt = nil
    row.playDuration = nil
    UpdateRowBorder(row)
    if not AnyRowProgressActive() then StopRowProgressTicker() end
end)

------------------------------------------------------------------------
-- Proximity-based auto-close: a single shared, throttled ticker covering
-- BOTH transient surfaces (the expanded Mini Soundbook/favMenu and Quick
-- Options/quickMenu), rather than one competing timer per element.
-- Inactive (no ticker at all) whenever both are closed - no permanent
-- every-frame proximity checks while closed.
------------------------------------------------------------------------

-- Real screen distance for a given "UI px" tolerance shrinks at higher
-- UI scale settings, so this and the close delay are loose enough that
-- opening a surface is never immediately followed by a close - plus a
-- separate opening grace period below for the very moment of opening.
local PROXIMITY_TOLERANCE = 150  -- px, around the combined active area
-- Tightened tolerance for a Mini Soundbook opened via icon hover
-- specifically (explicit requirement) - the much larger 150px above
-- exists for surfaces the player deliberately opened through an explicit
-- control (a click, a slider drag) and is preserved unchanged for those;
-- a passive hover-open getting the SAME generous buffer made it linger
-- far longer than the cursor actually leaving it would suggest. The
-- combined bounds already include the small icon<->favMenu gap as
-- "inside" (it's a plain bounding box around both), so this only
-- tightens the OUTER edge, never the transition between the two.
local HOVER_MINI_TOLERANCE = 8  -- px, roughly outside the Mini's own real bounds
local PROXIMITY_CLOSE_DELAY = 0.6 -- seconds continuously outside before closing
local PROXIMITY_SAMPLE_INTERVAL = 0.1 -- ~0.1s throttled polling, not every frame
-- A short window right after opening (icon click, hover-open, or a
-- forced size-preview open) during which outside-time can never
-- accumulate, regardless of cursor position at that instant - guarantees
-- a minimum reaction window on every open, not just a looser ongoing
-- tolerance.
local PROXIMITY_OPEN_GRACE = 0.6 -- seconds

local proximityTicker
local proximityOutsideElapsed = 0
local proximityGraceRemaining = 0
-- Interaction priority: while true, the ticker never accumulates
-- outside-time - the outside-distance timer restarts only after the
-- active interaction ends. Set by icon drag (BuildIcon above) and the
-- Announcer/Mini Soundbook Size sliders (SB.ShowAnnouncerQuickOptions
-- below).
local proximityActiveInteraction = false

SetMiniActiveInteraction = function(active)
    proximityActiveInteraction = active and true or false
    if proximityActiveInteraction then proximityOutsideElapsed = 0 end
end

local function AddMiniBounds(combined, frame)
    if not frame or not frame.IsShown or not frame:IsShown() then return combined end
    local l, r, t, b = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
    if not (l and r and t and b) then return combined end
    -- GetLeft/Right/Top/Bottom are returned in the frame's OWN local unit
    -- space (1 unit = that frame's own effective-scale pixels) - icon and
    -- favMenu both carry independent SetScale (Announcer Size / Mini
    -- Soundbook Size), so comparing their raw numbers directly against the
    -- cursor position (normalized to UIParent's scale below) would skew by
    -- the scale ratio. Same class of fix as SB.ResolvePopoutDirection's
    -- GetCenter() call above.
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

-- The icon is always included in the combined bounds (it's the shared
-- trigger for both surfaces); favMenu/quickMenu are included only while
-- actually shown; the Popout Direction dropdown's own floating list (a
-- separate top-level frame, see SB.CloseAnnouncerQuickOptions above) is
-- included only while open.
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
    -- A Mini Soundbook opened via hover gets the tightened tolerance;
    -- one opened through an explicit control (or Quick Options, which
    -- never opens via hover at all) keeps the original generous one.
    local tolerance = (miniOpenedViaHover and favMenu and favMenu:IsShown())
        and HOVER_MINI_TOLERANCE or PROXIMITY_TOLERANCE
    return x >= bounds.left - tolerance and x <= bounds.right + tolerance
        and y >= bounds.bottom - tolerance and y <= bounds.top + tolerance
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
    -- Return each surface to its own normal closed lifecycle -
    -- SB.CloseFavMenu/SB.CloseAnnouncerQuickOptions already do exactly that
    -- (real Hide(), no setting/position/size/scale/lock changes, dropdown
    -- list closed too).
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
-- promptly no matter WHICH code path hid the frame (a row's click-to-play,
-- the outside-click catcher, Escape, proximity itself, ...) - Hide()
-- always fires OnHide reliably, making it the one authoritative place to
-- check this.
NoteMiniSurfaceHidden = function()
    if not ((quickMenu and quickMenu:IsShown()) or (favMenu and favMenu:IsShown())) then
        StopMiniProximityTicker()
    end
end

-- The icon's native OnEnter hook (BuildIcon above) fires once per
-- transition into the icon's bounds - but, per this file's "Hover
-- re-arm gate" section, not every one of those is a genuine hover, so
-- the gate is checked first, ahead of the persisted setting and Quick
-- Options' own open state. Already-open favMenu is also a no-op return
-- (not just harmless) - avoids a redundant rebuild/reposition/reshow on
-- a spurious re-enter that the gate happens to still allow through.
HandleMiniIconHoverEnter = function()
    if not miniHoverGateArmed then return end
    if not (SB.db and SB.db.ui and SB.db.ui.announcer and SB.db.ui.announcer.openOnHover) then return end
    if quickMenu and quickMenu:IsShown() then return end
    if favMenu and favMenu:IsShown() then return end
    if SB.ShowFavMenu then SB.ShowFavMenu(icon, true) end
end

-- Exposed on SB (not a plain local) since BuildIcon's OnClick handler
-- above calls this by name before this point in the file is reached at
-- load time; only actually invoked later, on a real click, by which
-- time this assignment has already run.
-- Single-active-transient-surface rule: reuses favMenu's own OnHide
-- handler (already hides its catcher) rather than duplicating that
-- lifecycle here. A real Hide(), never a strata change, so the frame
-- genuinely stops taking clicks.
function SB.CloseFavMenu()
    if favMenu then favMenu:Hide() end
end

-- Shared build+populate+position+show logic, factored out of ShowFavMenu so
-- the Mini Soundbook Size live-preview path (below) can reuse it WITHOUT
-- going through ShowFavMenu's own Quick-Options-closing side effect - the
-- preview is a narrow exception to the single-active-surface rule, scoped
-- only to the slider-drag interaction.
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
    RaiseIconAboveCatcher(favMenu.catcher)
    favMenu:Show()
end

-- `viaHover` (optional) - true only when HandleMiniIconHoverEnter is the
-- caller. Every other caller (left-click, Send-to/context flows) omits
-- it, so miniOpenedViaHover correctly defaults to false for a Mini
-- Soundbook the player opened through a normal, explicit control - the
-- tightened proximity tolerance and tooltip persistence below both key
-- off this flag, and must never apply to those.
function SB.ShowFavMenu(anchor, viaHover)
    -- Single-active-transient-surface rule: Quick Options never coexists
    -- with the expanded Mini Soundbook - closed first if it was open.
    -- The context/send menu is deliberately left alone here - it's
    -- opened FROM a favMenu row and is meant to coexist with it.
    if SB.CloseAnnouncerQuickOptions then SB.CloseAnnouncerQuickOptions() end
    miniOpenedViaHover = viaHover and true or false
    DisplayFavMenu(anchor)
    StartMiniProximityTicker()
end

-- Mini Soundbook Size live preview: a narrow exception to the single-
-- active-transient-surface rule, scoped only to dragging this one slider.
-- While the user drags, the Mini Soundbook must be visible and reflect
-- the size continuously, coexisting with Quick Options rather than
-- closing it. If it was already legitimately open, it's left untouched
-- on release. If it had to be force-opened for the preview, it's closed
-- again on release via the same CloseFavMenu lifecycle everything else uses.
local miniSizePreviewForcedOpen = false

local function StartMiniSizePreview()
    if SetMiniActiveInteraction then SetMiniActiveInteraction(true) end
    if not (favMenu and favMenu:IsShown()) then
        miniSizePreviewForcedOpen = true
        -- Chains off quickMenu's own ACTUAL resolved rectangle (continuing in
        -- the SAME direction quickMenu already opened toward) rather than
        -- independently computing an "opposite side" direction - near a
        -- screen edge, SetClampedToScreen would otherwise pull an
        -- independently-placed popup back on-screen, straight into
        -- quickMenu, overlapping it. This guarantees adjacency with never
        -- less than POPOUT_GAP between them.
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

------------------------------------------------------------------------
-- Announcer Size live preview - the same pattern as Mini Soundbook Size's
-- own StartMiniSizePreview/EndMiniSizePreview just above, targeting the
-- Announcer banner itself instead of the Mini Soundbook popup. While the
-- slider is actively dragged: the banner is forced to full opacity and, if
-- nothing is really playing, shown with the same fixed, deterministic
-- content the icon-drag preview already uses (PopulatePreviewBanner) so the
-- real layout/dimensions are visible rather than a placeholder. If a real
-- sound IS already playing/displayed, that real banner is simply resized
-- live in place (SB:RefreshAnnouncerScale, already called on every slider
-- value change) - never a second, duplicate preview.
------------------------------------------------------------------------

local announcerSizePreviewForcedOpen = false

-- Frozen-position state for quickMenu (regression fix): quickMenu is
-- normally anchored LIVE to the icon's own edge (SB.PositionRelativeToIcon),
-- and Announcer Size's SetScale on the icon moves that edge continuously
-- as the icon grows/shrinks - so without this, the menu (and the slider
-- inside it) visibly slides out from under the cursor on every value
-- change. Frozen to the menu's OWN current on-screen rectangle (relative
-- to UIParent, not the icon) for the duration of the drag, so it and every
-- child inside it (the slider included) stay pixel-stable no matter how
-- much the icon itself resizes underneath. quickMenu is a direct UIParent
-- child with no SetScale of its own, so its GetLeft()/GetBottom() are
-- already in UIParent's own coordinate space - no scale-ratio conversion
-- needed (unlike SB.ResolvePopoutDirection's own icon-relative maths,
-- which DOES need one since the icon carries its own independent scale).
local quickMenuFrozen = false

local function FreezeQuickMenuPosition()
    if not (quickMenu and quickMenu:IsShown()) or quickMenuFrozen then return end
    local left, bottom = quickMenu:GetLeft(), quickMenu:GetBottom()
    if not (left and bottom) then return end
    quickMenuFrozen = true
    quickMenu:ClearAllPoints()
    quickMenu:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
end

-- Restores the normal, live icon-anchored positioning - never persisted,
-- purely an in-session frame state change, so the very next open (or the
-- next Popout Direction change) behaves exactly as it always did.
local function UnfreezeQuickMenuPosition()
    if not quickMenuFrozen then return end
    quickMenuFrozen = false
    if quickMenu and quickMenu.__anchor then
        SB.PositionRelativeToIcon(quickMenu, quickMenu.__anchor, SB.ResolvePopoutDirection(quickMenu.__anchor))
    end
end

-- Collision-aware banner placement while resizing: LayoutBanner's own
-- normal behaviour anchors the banner to the icon using the SAME resolved
-- direction quickMenu itself uses (SB.ResolvePopoutDirection(icon)), so
-- during a resize interaction it would sit directly behind/under the very
-- menu being used to change its size. Chains the banner off quickMenu's
-- OWN outer edge instead, continuing in that same direction - adjacent to
-- the menu, never underneath it - exactly the pattern StartMiniSizePreview
-- above already uses for favMenu-vs-quickMenu adjacency. SetClampedToScreen
-- (already set on the banner) keeps the whole thing on-screen even when
-- that pushes it toward a screen edge.
local function LayoutAnnouncerPreviewDuringResize()
    if quickMenu and quickMenu:IsShown() then
        SB.PositionRelativeToIcon(banner, quickMenu, SB.ResolvePopoutDirection(icon))
    else
        LayoutBanner()
    end
end

local function StartAnnouncerSizePreview()
    icon:SetAlpha(1)
    FreezeQuickMenuPosition()
    -- Explicit bug report: opening Quick Options from the Main Soundbook's
    -- own toolbar and resizing Announcer Size there showed the preview
    -- BEHIND the Main window, hiding the very thing being resized. Root
    -- cause: banner's own strata is a plain "MEDIUM" always, while Main
    -- (UI.lua) is "HIGH" - a strictly higher stacking tier, so Main always
    -- won regardless of frame level/creation order. Bumped to "DIALOG" for
    -- the duration of the preview only (matching quickMenu's own strata,
    -- so the two remain in the same tier as each other) and restored back
    -- to its normal MEDIUM once the preview ends - real, non-preview
    -- playback has no reason to ever outrank the Main window. BuildBanner
    -- (idempotent, a no-op once already built) runs first so this applies
    -- even on the very first-ever preview, before anything else has had a
    -- reason to construct the banner yet.
    BuildBanner()
    banner:SetFrameStrata("DIALOG")
    if #activeDisplays > 0 then
        -- Real content already owns the banner - just make sure it's at
        -- full opacity too (RenderPrimary already keeps it at 1; this is a
        -- harmless belt-and-braces in case that ever changes), reposition
        -- it beside the now-frozen menu so resizing never hides it behind
        -- Quick Options, and let the slider's own live SetScale calls
        -- resize it in place from there.
        if banner then
            banner:SetAlpha(1)
            LayoutAnnouncerPreviewDuringResize()
        end
        return
    end
    announcerSizePreviewActive = true
    announcerSizePreviewForcedOpen = true
    PopulatePreviewBanner()
    LayoutAnnouncerPreviewDuringResize()
    -- CollapseToIdle fades the banner to alpha 0 then Hides it once nothing
    -- real is left to show; without resetting alpha here, a bare Show()
    -- would leave that faded-out alpha in place and the preview would be
    -- invisible (same reasoning as StartIconDragPreview above).
    if UIFrameFadeRemoveFrame then UIFrameFadeRemoveFrame(banner) end
    banner:SetAlpha(1)
    banner:Show()
end

-- Never writes SB.db.ui.announcer.alphaIdle/alphaHover - only ever reads
-- them (via SB:RefreshAnnouncerAlpha, the exact same call every other idle-
-- opacity restore already uses), so "restore the exact opacity that was
-- active before resizing started" falls out naturally: nothing here ever
-- touched the persisted value in the first place. Skipped while real
-- content is genuinely active (#activeDisplays > 0) - RenderPrimary's own
-- invariant keeps the icon at full opacity for as long as a real banner is
-- showing, and forcing alphaIdle back on top of that here would fight it.
local function EndAnnouncerSizePreview()
    if banner then banner:SetFrameStrata("MEDIUM") end
    if announcerSizePreviewForcedOpen then
        announcerSizePreviewActive = false
        announcerSizePreviewForcedOpen = false
        RestoreRealAnnouncerState() -- repaints AND repositions (RenderPrimary/CollapseToIdle both call LayoutBanner or hide outright)
    elseif banner and banner:IsShown() then
        -- A real sound was already playing throughout (the early-return
        -- branch in StartAnnouncerSizePreview above) - RestoreRealAnnouncerState
        -- is never reached for this path, so the banner's own position
        -- (chained off quickMenu during the resize) must be explicitly
        -- restored back to its normal icon anchor now that quickMenu is
        -- about to unfreeze.
        LayoutBanner()
    end
    UnfreezeQuickMenuPosition()
    if #activeDisplays == 0 then
        SB:RefreshAnnouncerAlpha()
    end
end

-- Mini Soundbook Size - independent of Announcer Size (SB:RefreshAnnouncerScale
-- above): scales ONLY the favourite-area popup (icons, sound-name text,
-- dropdown/name-area width, spacing) via a plain frame SetScale, same
-- technique the Announcer itself uses. Safe to call before the popup has
-- ever been built (BuildFavMenu hasn't run yet) - just no-ops until the
-- frame exists, like SB:RefreshAnnouncerScale's own icon/banner guards.
function SB:RefreshMiniSoundbookScale()
    if favMenu then favMenu:SetScale(SB.db.ui.announcer.favScale or 1.0) end
end

------------------------------------------------------------------------
-- Proximity locator glow (Idle Opacity < 30% only): a soft Arcane blue/
-- violet aura around the idle icon's own current footprint that fades in
-- as the cursor approaches - pure discoverability for a player who has
-- made the icon deliberately hard to see, never a functional/state
-- indicator, never touching the icon's own Idle/Hover Opacity. Scoped
-- entirely to this file's existing idle/hover/interaction machinery
-- (icon/banner/favMenu/quickMenu/proximityActiveInteraction, all already
-- in scope here) - no new persisted setting, no generic animation
-- framework, just this one small helper.
------------------------------------------------------------------------

local LOCATOR_GLOW_TEX = "Interface\\AddOns\\Soundbook\\Assets\\LocatorGlow"
local LOCATOR_ALPHA_THRESHOLD = 30 -- Idle Opacity %, strictly below this
local LOCATOR_EXTENT    = 14   -- px the glow extends past the icon's own edges
local LOCATOR_MAX_DIST  = 220  -- px: at/beyond this, fully invisible
local LOCATOR_TICK      = 0.04 -- ~40ms throttle (spec range: 30-50ms)
local LOCATOR_SMOOTH    = 0.30 -- per-tick lerp toward the target - smooth hand-off, never a pop
local LOCATOR_OUTER_PEAK = 0.40 -- broad soft blue layer's alpha at full intensity
local LOCATOR_INNER_PEAK = 0.62 -- tighter blue-violet core's alpha at full intensity (spec: ~0.55-0.70)

local locatorGlow
local locatorTicker
local locatorIntensity = 0 -- currently-displayed (smoothed) 0..1 value

local function BuildLocatorGlow()
    if locatorGlow then return locatorGlow end
    -- A SEPARATE top-level frame, deliberately NOT a child of `icon`: a
    -- child's rendered alpha is the PRODUCT of its own alpha and every
    -- ancestor's, so at a very low Idle Opacity (the exact condition
    -- this feature exists for) a child glow would be crushed to the same
    -- near-zero alpha as the icon it exists to help find. Anchored
    -- purely via SetPoint to the icon's own edges instead, so it still
    -- automatically follows the icon's movement and (Announcer Size)
    -- rescaling with no per-frame repositioning code needed, while
    -- keeping a fully independent alpha.
    local f = SB.CreateFrame("Frame", "SoundbookMiniLocatorGlow", UIParent)
    -- One strata below the icon's own idle strata (ICON_IDLE_STRATA) -
    -- deterministically always renders behind/around the icon rather
    -- than over it, regardless of the icon's own temporary strata
    -- changes (RaiseIconAboveCatcher, only ever active while favMenu/
    -- quickMenu are shown, which already disqualifies the glow below).
    -- Mouse-disabled outright, so it can never intercept a click/drag or
    -- alter any hitbox/click-through/locked behaviour - it simply never
    -- participates in hit-testing at all.
    f:SetFrameStrata("LOW")
    f:EnableMouse(false)
    f:SetPoint("TOPLEFT", icon, "TOPLEFT", -LOCATOR_EXTENT, LOCATOR_EXTENT)
    f:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", LOCATOR_EXTENT, -LOCATOR_EXTENT)
    f:Hide()

    local outer = f:CreateTexture(nil, "ARTWORK")
    outer:SetAllPoints(f)
    outer:SetTexture(LOCATOR_GLOW_TEX)
    outer:SetBlendMode("ADD")
    outer:SetVertexColor(V3.ARCANE_BLUE[1], V3.ARCANE_BLUE[2], V3.ARCANE_BLUE[3])
    outer:SetAlpha(0)
    f.outer = outer

    -- Tighter inner component: the SAME soft-radial texture, drawn
    -- smaller/inset so it reads as a denser violet core rather than a
    -- second identical ring - avoids needing a second art asset for
    -- what is still one small effect.
    local inset = LOCATOR_EXTENT * 0.55
    local inner = f:CreateTexture(nil, "ARTWORK", nil, 1)
    inner:SetPoint("TOPLEFT", f, "TOPLEFT", inset, -inset)
    inner:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -inset, inset)
    inner:SetTexture(LOCATOR_GLOW_TEX)
    inner:SetBlendMode("ADD")
    inner:SetVertexColor(V3.VIOLET[1], V3.VIOLET[2], V3.VIOLET[3])
    inner:SetAlpha(0)
    f.inner = inner

    locatorGlow = f
    return f
end

-- Shortest distance from the cursor to the icon's OWN rectangle bounds -
-- 0 for anywhere inside it, never distance-to-center - so the response
-- is correct regardless of the icon's size/aspect ratio. Same cursor/
-- scale normalization this file's own IsCursorActuallyOnIcon (Hover
-- re-arm gate, above) already relies on.
local function DistanceToIconBounds()
    if not (icon and icon.GetLeft) then return math.huge end
    local l, r, t, b = icon:GetLeft(), icon:GetRight(), icon:GetTop(), icon:GetBottom()
    if not (l and r and t and b) then return math.huge end
    local scale = icon:GetEffectiveScale()
    if not scale or scale == 0 then scale = 1 end
    local x, y = GetCursorPosition()
    x, y = x / scale, y / scale
    local dx = math.max(l - x, 0, x - r)
    local dy = math.max(b - y, 0, y - t)
    return math.sqrt(dx * dx + dy * dy)
end

-- Continuous, eased proximity curve - deliberately NOT a linear ramp and
-- NOT discrete distance bands (explicit requirement): a smoothstep base
-- (continuous and differentiable, no snapping anywhere) further raised
-- to an exponent >1, which pushes even MORE of the curve's rise toward
-- the close end than plain smoothstep alone - the outer ~half of the
-- range (220 down to ~120px) stays clearly subtle, and intensity climbs
-- quickly only over the last ~120px, matching the spec's "very subtle /
-- increasingly visible / near maximum" bands as a smooth continuum
-- rather than three discrete steps. dist<=0 (cursor at/inside the icon's
-- own bounds) is folded into the same 0 result as dist>=MAX - that is
-- exactly the "mouse is already over it, hand off to hover" case, never
-- a "maximum proximity" case.
local function ProximityIntensity(dist)
    if dist <= 0 or dist >= LOCATOR_MAX_DIST then return 0 end
    local t = 1 - (dist / LOCATOR_MAX_DIST)
    local smoothstep = t * t * (3 - 2 * t)
    return smoothstep ^ 1.6
end

local function LocatorGlowTick()
    if not locatorGlow then return end
    -- Every one of these is re-checked live on every throttled tick,
    -- rather than driving the glow off event hooks scattered across each
    -- state's own open/close path - cheap, and correct by construction:
    -- there is exactly one place that decides "is this genuine idle".
    local eligible = icon and icon:IsShown()
        and (SB.db.ui.announcer.alphaIdle or 100) < LOCATOR_ALPHA_THRESHOLD
        and not (banner and banner:IsShown())       -- active playback forcing visibility
        and not (favMenu and favMenu:IsShown())      -- normal hover/expanded, or Send-to pinning it open (opened FROM a favMenu row)
        and not (quickMenu and quickMenu:IsShown())  -- Quick Options open
        and not proximityActiveInteraction           -- icon being dragged, or a size slider being dragged

    local target = eligible and ProximityIntensity(DistanceToIconBounds()) or 0

    locatorIntensity = locatorIntensity + (target - locatorIntensity) * LOCATOR_SMOOTH
    if locatorIntensity < 0.002 then locatorIntensity = 0 end

    if locatorIntensity <= 0 then
        -- Zero the actual displayed alpha along with hiding the frame -
        -- otherwise the NEXT time it's shown again would briefly flash
        -- whatever alpha it happened to fade through last, instead of
        -- starting from genuinely invisible.
        locatorGlow.outer:SetAlpha(0)
        locatorGlow.inner:SetAlpha(0)
        if locatorGlow:IsShown() then locatorGlow:Hide() end
        return
    end

    if not locatorGlow:IsShown() then locatorGlow:Show() end
    locatorGlow.outer:SetAlpha(locatorIntensity * LOCATOR_OUTER_PEAK)
    locatorGlow.inner:SetAlpha(locatorIntensity * LOCATOR_INNER_PEAK)
end

local function StopLocatorTicker()
    if locatorTicker then locatorTicker:Cancel(); locatorTicker = nil end
    locatorIntensity = 0
    if locatorGlow then
        locatorGlow.outer:SetAlpha(0)
        locatorGlow.inner:SetAlpha(0)
        locatorGlow:Hide()
    end
end

local function StartLocatorTicker()
    if locatorTicker then return end
    BuildLocatorGlow()
    locatorTicker = C_Timer.NewTicker(LOCATOR_TICK, LocatorGlowTick)
end

-- The one gate for whether periodic proximity evaluation should be
-- running AT ALL - deliberately broader than "genuinely idle right now"
-- (that finer per-tick check lives in LocatorGlowTick above) so the
-- ticker doesn't need to start/stop on every favMenu/banner open-close,
-- only on the two things that make the feature possibly-relevant in the
-- first place. A permanently >=30% Idle Opacity (the default) or a
-- hidden icon costs nothing at all - no ticker exists until this
-- decides one is actually warranted. Called on every lifecycle point
-- that can change either input: ShowAnnouncer/HideAnnouncer (icon
-- shown-state) and RefreshAnnouncerAlpha (Idle Opacity changing live
-- from Settings, no /reload needed).
local function UpdateLocatorTickerState()
    local shouldRun = icon and icon:IsShown()
        and (SB.db.ui.announcer.alphaIdle or 100) < LOCATOR_ALPHA_THRESHOLD
    if shouldRun then
        StartLocatorTicker()
    else
        StopLocatorTicker()
    end
end

-- If the popup is open while its live reach/target summary changes -
-- the "Send to:" dropdown (UI.lua) or a roster change via
-- SB.RefreshDefaultOutputDisplay - the summary must update immediately,
-- not on next open/reload.
SB:On("OUTPUT_SELECTION_CHANGED", function()
    if favMenu and favMenu:IsShown() then PopulateFavMenu() end
end)

-- A per-sound "Default Output" override changing (Edit Sound) can flip
-- AnyVisibleFavouriteHasOverride's result, which changes whether the
-- header reads the plain live phrase or the "Default destination: X"
-- variant - refresh the same way OUTPUT_SELECTION_CHANGED does.
SB:On("SOUND_DISPLAY_CHANGED", function()
    if favMenu and favMenu:IsShown() then PopulateFavMenu() end
end)

-- A font/Text Size change (Settings) actually changes rendered glyph
-- widths (Core.lua's SB:RefreshMainFont), which the title's own names-
-- vs-count fit-check measures against - refresh the same way, so an open
-- Mini Soundbook doesn't keep showing a decision made under the old size.
SB:On("MAIN_FONT_CHANGED", function()
    if favMenu and favMenu:IsShown() then PopulateFavMenu() end
end)

-- Also closes the Popout Direction dropdown's own floating list, which is
-- a SEPARATE top-level frame (Theme.CreateDropdown - parented to UIParent,
-- not a real child of quickMenu) and would otherwise survive quickMenu's
-- own Hide() untouched, left floating with its own live hitbox.
function SB.CloseAnnouncerQuickOptions()
    if quickMenu then
        if quickMenu.dirDropdown then quickMenu.dirDropdown:CloseList() end
        quickMenu:Hide()
    end
end

function SB.ShowAnnouncerQuickOptions(anchor)
    -- Interaction priority: an explicit Quick Options open/close always
    -- disarms the hover gate, whichever branch below runs - suppresses
    -- hover immediately on open, and (toggle-close branch) makes sure a
    -- right-click that closes Quick Options again still requires a real
    -- leave+re-enter before hover can fire, same as closing it any other
    -- way.
    SB.SuppressMiniHoverGate()
    if quickMenu and quickMenu:IsShown() then
        SB.CloseAnnouncerQuickOptions()
        return
    end
    -- Single-active-transient-surface rule: Quick Options, the expanded
    -- Mini Soundbook, and the context/send menu are mutually exclusive -
    -- close the other two before opening this one.
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
        catcher:SetScript("OnClick", function(self, button)
            SB.CloseAnnouncerQuickOptions()
            -- Same redispatch as favMenu's own catcher, with one
            -- exception: Shift+Right-click is Quick Options' OWN
            -- toggle-close gesture (see the icon's click binding) -
            -- closing above already IS that action, so redispatching it
            -- too would just reopen the very menu it was meant to close.
            if IsCursorActuallyOnIcon() and not (button == "RightButton" and IsShiftKeyDown()) then
                PerformMiniIconClick(button)
            end
        end)
        quickMenu.catcher = catcher
        quickMenu:SetScript("OnHide", function()
            catcher:Hide()
            RestoreIconStrata()
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
        -- Timed mute durations live here, not in Settings: timed/global
        -- muting is a runtime action, not persistent configuration.
        AddRow("Mute 30 min", function() SB:StartReceiveMute(30 * 60, 30) end)
        AddRow("Mute 60 min", function() SB:StartReceiveMute(60 * 60, 60) end)
        quickMenu.lockBtn = AddRow("Lock Interface", function()
            SB:SetAnnouncerLocked(not SB.db.ui.layoutLocked)
        end)
        AddRow("Muted Players...", function()
            if SB.OpenMutePlayersMenu then SB.OpenMutePlayersMenu() end
        end)
        -- History lives on this launcher context menu (shared by the
        -- Announcer icon's Shift+Right-click and the Main toolbar's Quick
        -- Audio button), not inside Settings - it's content/navigation,
        -- not configuration.
        AddRow("Sound History", function()
            if SB.ShowHistoryWindow then SB:ShowHistoryWindow() end
        end)
        -- Deep-links straight into the Settings view (UI.lua's
        -- SB:ShowSettingsView) - whether Soundbook is currently closed,
        -- showing the Library, or on Admin/Keybind mode, this always lands
        -- directly on Settings in one click, reusing the exact same
        -- navigation ToggleSettings' own "opening" branch already does
        -- rather than a separate, duplicated path into the panel.
        AddRow("Open Settings", function()
            if SB.ShowSettingsView then SB:ShowSettingsView() end
        end)

        -- Mini Soundbook activation mode: writes the same persisted field
        -- (SB.db.ui.announcer.openOnHover) Settings -> Mini's own checkbox
        -- uses. No extra refresh needed - the icon's OnEnter handler reads
        -- this field live on every hover. Label is the short "Open on
        -- Hover" here (this popup is only 184px wide - the full "Open
        -- Mini Soundbook on Hover" overflows it); Settings -> Mini keeps
        -- the full descriptive label, room permitting there. Same
        -- checkbox component, same setting, just a shorter caption.
        local hoverCheck = Theme.CreateCheckbox(quickMenu, "Open on Hover", function(checked)
            SB.db.ui.announcer.openOnHover = checked and true or false
        end)
        -- Left-aligned off the same 8px inset the rows above already use
        -- (168-wide buttons centred in this 184-wide popup) rather than a
        -- single centred TOP anchor - see dirLabel's own comment below for
        -- why that centring was the actual overflow bug this fixes.
        hoverCheck:SetPoint("TOPLEFT", rows[#rows], "BOTTOMLEFT", 0, -10)
        Theme.AttachTooltip(hoverCheck, "Open on Hover",
            "Open the Mini Soundbook when hovering its icon instead of requiring a left-click.")
        quickMenu.hoverCheck = hoverCheck

        -- Popout Direction: one shared setting for every surface that opens
        -- off the icon (this menu, Favourites, the Announcer banner and its
        -- previews - see SB.ResolvePopoutDirection/SB.PositionRelativeToIcon
        -- above). "Automatic" resolves from the icon's current screen
        -- region every time it's needed; the other four pin one side.
        --
        -- Bugfix (text overflow): this and the two labels below used to
        -- anchor via a single "TOP" point (natural, unconstrained text
        -- width centred around whatever x-position the previous element's
        -- own off-centre anchor happened to leave it at) - at a larger
        -- Soundbook Text Size, "Mini Soundbook Size" in particular could
        -- render wider than this 184px-wide popup and spill past both
        -- edges. Left-aligned and bounded to the popup's own content width
        -- (the same 8px inset as the rows/checkbox above) instead, so the
        -- text wraps within it rather than ever overflowing.
        local dirLabel = quickMenu:CreateFontString(nil, "OVERLAY")
        dirLabel:SetFontObject(SB.Fonts.HighlightSmall)
        dirLabel:SetPoint("TOPLEFT", hoverCheck, "BOTTOMLEFT", 0, -12)
        dirLabel:SetPoint("RIGHT", quickMenu, "RIGHT", -8, 0)
        dirLabel:SetJustifyH("LEFT")
        dirLabel:SetWordWrap(true)
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
            -- Repositions any already-open anchored surface immediately,
            -- no /reload needed.
            SB:RefreshPopoutPositions()
        end)
        dirDropdown.button:SetPoint("TOPLEFT", dirLabel, "BOTTOMLEFT", 0, -6)
        quickMenu.dirDropdown = dirDropdown

        -- Announcer size: SetScale on both the idle icon and the active
        -- banner scales everything about them (icon, text, progress bar)
        -- together, proportionally, rather than resizing each element
        -- independently.
        local sizeLabel = quickMenu:CreateFontString(nil, "OVERLAY")
        sizeLabel:SetFontObject(SB.Fonts.HighlightSmall)
        sizeLabel:SetPoint("TOPLEFT", dirDropdown.button, "BOTTOMLEFT", 0, -12)
        sizeLabel:SetPoint("RIGHT", quickMenu, "RIGHT", -8, 0)
        sizeLabel:SetJustifyH("LEFT")
        sizeLabel:SetWordWrap(true)
        sizeLabel:SetText("Announcer Size")
        sizeLabel:SetTextColor(unpack(Theme.TEXT_DIM))

        -- Live preview: the icon/banner rescale continuously while
        -- dragging, not only on mouse-up - no separate positioning step is
        -- needed the way Mini Soundbook Size's forced-open below needs one,
        -- since the icon (and banner, when shown) are already on-screen and
        -- anchored off the icon's own live edges (SB.PositionRelativeToIcon),
        -- so resizing in place naturally carries quickMenu's own anchor
        -- along with it. StartAnnouncerSizePreview/EndAnnouncerSizePreview
        -- (above) additionally force full opacity for the duration and, if
        -- nothing is really playing, show the same deterministic preview
        -- content the icon-drag preview uses so the real banner
        -- dimensions/layout are visible rather than resizing an invisible
        -- (0% opacity) or absent banner.
        local sizeSlider = Theme.CreateSlider(quickMenu, 50, 200, 10, 120, function(value)
            SB.db.ui.announcer.scale = value / 100
            SB:RefreshAnnouncerScale()
        end)
        sizeSlider:SetScript("OnMouseUp", function() SB:RefreshAnnouncerScale() end)
        sizeSlider:SetPoint("TOPLEFT", sizeLabel, "BOTTOMLEFT", 0, -8)
        -- Dragging this slider must never be interrupted by proximity
        -- auto-close - HookScript composes with the OnMouseUp handler
        -- above rather than replacing it.
        sizeSlider:HookScript("OnMouseDown", function()
            if SetMiniActiveInteraction then SetMiniActiveInteraction(true) end
            StartAnnouncerSizePreview()
        end)
        sizeSlider:HookScript("OnMouseUp", function()
            if SetMiniActiveInteraction then SetMiniActiveInteraction(false) end
            EndAnnouncerSizePreview()
        end)
        quickMenu.sizeSlider = sizeSlider

        -- Writes the same ui.announcer.favScale field Settings -> Mini's
        -- own slider uses (Settings.lua's BuildMiniSoundbookSection) - one
        -- persisted value, never a separate popup-local copy, so both
        -- locations always show the live value when opened.
        local miniSizeLabel = quickMenu:CreateFontString(nil, "OVERLAY")
        miniSizeLabel:SetFontObject(SB.Fonts.HighlightSmall)
        miniSizeLabel:SetPoint("TOPLEFT", sizeSlider, "BOTTOMLEFT", 0, -12)
        miniSizeLabel:SetPoint("RIGHT", quickMenu, "RIGHT", -8, 0)
        miniSizeLabel:SetJustifyH("LEFT")
        miniSizeLabel:SetWordWrap(true)
        miniSizeLabel:SetText("Mini Soundbook Size")
        miniSizeLabel:SetTextColor(unpack(Theme.TEXT_DIM))

        local miniSizeSlider = Theme.CreateSlider(quickMenu, 50, 200, 10, 120, function(value)
            SB.db.ui.announcer.favScale = value / 100
            -- Applied continuously while dragging, not only on release.
            SB:RefreshMiniSoundbookScale()
        end)
        miniSizeSlider:SetScript("OnMouseUp", function() SB:RefreshMiniSoundbookScale() end)
        miniSizeSlider:SetPoint("TOPLEFT", miniSizeLabel, "BOTTOMLEFT", 0, -8)
        -- Dragging this slider must never be interrupted by proximity
        -- auto-close, must force the Mini Soundbook visible if it isn't
        -- already, and must return it to its prior state on release - via
        -- StartMiniSizePreview/EndMiniSizePreview above, a narrow exception
        -- to the single-active-surface rule scoped only to this slider.
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
    RaiseIconAboveCatcher(quickMenu.catcher)
    quickMenu:Show()
    StartMiniProximityTicker()
end

-- If Popout Direction changes while Favourites/Quick Options/the
-- Announcer banner are visible, reposition them immediately rather than
-- waiting for the next open/reload. Each surface's own anchor is always
-- the icon in practice, but __anchor is tracked (not hardcoded to `icon`)
-- so this stays correct if that ever changes.
function SB:RefreshPopoutPositions()
    if favMenu and favMenu:IsShown() and favMenu.__anchor then
        SB.PositionRelativeToIcon(favMenu, favMenu.__anchor, SB.ResolvePopoutDirection(favMenu.__anchor))
    end
    -- Never re-anchored while quickMenuFrozen - an active Announcer Size
    -- drag has deliberately pinned it in place (see FreezeQuickMenuPosition
    -- above); this must not undo that mid-interaction.
    if quickMenu and quickMenu:IsShown() and quickMenu.__anchor and not quickMenuFrozen then
        SB.PositionRelativeToIcon(quickMenu, quickMenu.__anchor, SB.ResolvePopoutDirection(quickMenu.__anchor))
    end
    if banner and banner:IsShown() then
        -- Same reasoning: while the Announcer Size interaction is active,
        -- the banner is deliberately chained off quickMenu's own edge
        -- (LayoutAnnouncerPreviewDuringResize) instead of the icon
        -- directly - a plain LayoutBanner() here would silently undo that
        -- collision avoidance mid-drag.
        if quickMenuFrozen then
            LayoutAnnouncerPreviewDuringResize()
        else
            LayoutBanner()
        end
    end
end

------------------------------------------------------------------------
-- Public API - called by Core.lua's "/sb fav", the minimap button's
-- TOGGLE_FAV_UI, and Settings.lua.
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
    UpdateLocatorTickerState()
    RefreshIndicators()
    if #activeDisplays > 0 then
        BuildBanner()
        RenderPrimary()
    elseif SB.raidOverride and (SB.raidOverride.mutedSend or SB.raidOverride.mutedAll) then
        -- Covers the rare case where a restriction is already applied when
        -- the Announcer is shown (raidOverride is session-only and reset
        -- on reload/disconnect, but this is reachable if the Announcer is
        -- toggled back on after being hidden mid-raid) - shows the
        -- persistent state immediately, not just from the next
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
    -- Hide the locator glow immediately along with the icon it belongs
    -- to - it's a standalone frame (see the section above), not a child,
    -- so it would otherwise keep rendering on its own.
    UpdateLocatorTickerState()
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
    -- The locator glow only ever runs below the 30% Idle Opacity
    -- threshold - re-evaluated live so dragging the slider past that
    -- line immediately starts/stops it, no /reload needed.
    UpdateLocatorTickerState()
end

-- Settings' "Announcer Font"/"Announcer Text Size" controls
-- (SB.db.settings.miniFont/miniFontScale) set the font directly on the
-- Announcer's own FontStrings, never via SB.Fonts' shared objects - those
-- back the MAIN Soundbook window, and mutating them would also resize
-- Settings/Edit Sound/everything else that shares them.
--
-- Compact layout (explicit redesign request, second-mockup composition):
-- the icon fills nearly the full banner height, inset equally tight from
-- the top/bottom/left edges; the duration reads right-aligned on the
-- SAME row as the sender/channel line, directly above the progress bar,
-- instead of floating isolated in the top-right corner; the progress bar
-- spans the full remaining width beside the icon. PADDING doubles as
-- both the icon's own top/bottom/left inset AND the banner's own top/
-- bottom padding, so the icon exactly fills the vertical span between
-- them - no separate "icon size" constant to keep in sync by hand.
local BANNER_PADDING    = 5 -- icon inset (top/bottom/left) = banner's own top/bottom padding
local ICON_TEXT_GAP     = 6 -- icon -> text horizontal gap
local BANNER_RIGHT_PAD  = 6 -- text/duration/track inset from the banner's right edge
local NAME_ROW_GAP      = 2 -- name row -> sender/duration row gap
local BAR_GAP           = 2 -- sender/duration row -> progress bar gap ("directly above")
local SUB_TIME_GAP      = 6 -- sender text -> duration text gap (they share one row)

-- RelayoutBannerHeight recomputes the banner's total height and every
-- element's position from the same font metrics just applied, so a
-- larger font never overlaps the progress bar below it, and the icon
-- always fills exactly the resulting content height. Uses known base-
-- size/line-height math rather than querying rendered GetHeight() (which
-- needs an extra frame to settle after SetFont) - correct the instant
-- this runs.
local function RelayoutBannerHeight()
    local scale = SB.db.settings.miniFontScale or 1
    local nameH = math.ceil((SB.Fonts.HighlightSmall.baseSize or 12) * scale * 1.4)
    local subH = math.ceil((SB.Fonts.DisableSmall.baseSize or 10) * scale * 1.4)
    local contentH = nameH + NAME_ROW_GAP + subH + BAR_GAP + TRACK_H
    banner:SetHeight(BANNER_PADDING * 2 + contentH)

    -- The icon fills the full content column height exactly - same top
    -- inset as the banner's own top padding, same left inset as PADDING.
    local iconSize = contentH
    banner.slot:SetSize(iconSize, iconSize)
    banner.slot:ClearAllPoints()
    banner.slot:SetPoint("TOPLEFT", banner, "TOPLEFT", BANNER_PADDING, -BANNER_PADDING)

    local textLeft = BANNER_PADDING + iconSize + ICON_TEXT_GAP
    local subRowY = BANNER_PADDING + nameH + NAME_ROW_GAP

    banner.nameText:ClearAllPoints()
    banner.nameText:SetPoint("TOPLEFT", banner, "TOPLEFT", textLeft, -BANNER_PADDING)
    banner.nameText:SetPoint("RIGHT", banner, "RIGHT", -BANNER_RIGHT_PAD, 0)

    -- Duration shares the sender/channel line - right-aligned, directly
    -- above the progress bar (explicit requirement) - rather than
    -- floating alone in the top-right corner.
    banner.timeText:ClearAllPoints()
    banner.timeText:SetPoint("TOPRIGHT", banner, "TOPRIGHT", -BANNER_RIGHT_PAD, -subRowY)

    banner.subText:ClearAllPoints()
    banner.subText:SetPoint("TOPLEFT", banner, "TOPLEFT", textLeft, -subRowY)
    banner.subText:SetPoint("RIGHT", banner.timeText, "LEFT", -SUB_TIME_GAP, 0)

    banner.track:ClearAllPoints()
    banner.track:SetPoint("TOPLEFT", banner, "TOPLEFT", textLeft, -(subRowY + subH + BAR_GAP))
    banner.track:SetPoint("RIGHT", banner, "RIGHT", -BANNER_RIGHT_PAD, 0)
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

-- Live report: the icon was invisible right after login until manually
-- toggling Settings' "Show Mini Soundbook" off and on - the exact same
-- SB:ShowAnnouncer() call PLAYER_LOGIN above already makes, just at a
-- much later point once the client's own loading-screen fade/UI
-- transition has genuinely finished. A frame first Show()n mid-transition
-- can end up not actually painted even though it's logically shown, with
-- nothing afterward ever forcing a fresh redraw. PLAYER_ENTERING_WORLD
-- (native event relayed via SB:Fire by Core.lua's own initFrame, same as
-- PLAYER_LOGIN above) fires once the world is truly ready and is the
-- standard point to re-assert frame state for exactly this reason; it
-- also fires on every zone/instance transition, not just login, so this
-- doubles as a cheap, idempotent self-heal rather than a one-shot login
-- fixup.
SB:On("PLAYER_ENTERING_WORLD", function()
    if SB.db.ui.announcer.shown then
        SB:ShowAnnouncer()
    end
end)
