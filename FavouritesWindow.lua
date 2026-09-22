-- FavouritesWindow.lua
-- Compact two-state favourites utility. Passive shows only the title and
-- status strips; hovering either strip expands the adaptive 3x7..10x2 icon
-- grid. Uses the exact same favourites data as the main Soundbook window.

local ADDON_NAME, SB = ...

-- Default expanded shape starts wide (10 columns x 2 rows); every resize
-- can select any useful intermediate wrapping through the logic below.
local DEFAULT_COLS = 10
local DEFAULT_ROWS = 2
local SLOT_COUNT = SB.MAX_FAVOURITES -- Core.lua loads first, so this is already defined
local BASE_ICON_SIZE = 30
local GAP = 6
local MARGIN = 8
local HEADER_H = 22
local NOW_PLAYING_H = 30
local FOOTER_H = 20 -- name bar's default/initial height, before any live scaling
local FOOTER_MIN_H = 20
local FOOTER_MAX_H = 24
local MIN_ICON = 16
-- Small enough to still fit a near-square grid (the most area-efficient of
-- the 20 possible layouts) at MIN_ICON with comfortable slack, so the
-- window can't be resized down into the "too small to fit" case
-- ComputeBestGrid has to fall back for at all, in the common case of
-- dragging near-square.
local MIN_SIZE = 170
local MAX_SIZE = 600
local WHITE_TEX = "Interface\\Buttons\\WHITE8X8"

local function DefaultWidth()
    return math.max(MIN_SIZE, DEFAULT_COLS * BASE_ICON_SIZE + (DEFAULT_COLS - 1) * GAP + 2 * MARGIN)
end
local function DefaultHeight()
    return DEFAULT_ROWS * BASE_ICON_SIZE + (DEFAULT_ROWS - 1) * GAP + 2 * MARGIN + HEADER_H + NOW_PLAYING_H + FOOTER_H
end

local favFrame
local header
local headerText
local closeBtn
local lockBtn
local muteBtn
local stopBtn
local resizeGrip
local body
local footer, footerText
local slots = {}
-- One small, never-scaled "holder" per slot - RelayoutSlots below only
-- ever moves/resizes the HOLDER; the real slot Button is anchored to its
-- holder's CENTER exactly once, at creation, and never re-anchored again.
-- This is what makes Theme.ApplyHoverZoom's hover zoom rock-solid: a
-- SetScale always grows a frame symmetrically around its OWN anchor point,
-- so anchoring permanently at CENTER (instead of dynamically converting
-- whatever point a grid layout happens to use, the old approach that
-- caused visible drift/jumping) means the zoom can never be knocked off
-- centre by a resize/relayout happening mid-hover - the holder can move
-- freely without ever touching the slot's own CENTER anchor.
local holders = {}
local dragGhost, dragGhostFrame, dragGhostOrnament
local draggingFromIndex
local isResizing = false
local CollapseMini
local RefreshSlots
-- Set by PinFavAlpha (further down) while SendMenu.lua's right-click popup
-- is open - must be declared here, ABOVE LeaveHoverZone (which needs to
-- read it too), not down next to ApplyFavAlpha/PinFavAlpha themselves -
-- Lua locals aren't hoisted, so a declaration placed after LeaveHoverZone
-- would leave it silently reading a global (nil) there instead.
local favAlphaPinned = false

-- "Now Playing": a permanent reserved strip; it never replaces the grid.
local nowPlaying, npIcon, npLine1, npLine2, npChannel
local nowPlayingTimer
local currentPlayingSoundID
local lastPlayed
local displayedSourceLabel
-- Progress fill (SoundPlayer.lua's PLAYBACK_PROGRESS_* events) - see
-- SetProgressFill/SyncProgressVisibility further down. progressSoundID/
-- progressDuration mirror whatever the most recent PLAYBACK_PROGRESS_
-- STARTED said, independently of currentPlayingSoundID - that event can
-- arrive a moment BEFORE ShowNowPlaying itself runs (playback tracking
-- starts inside SB:PlaySound, before SB:TriggerSound fires
-- LOCAL_SOUND_PLAYED), so the two are reconciled in SyncProgressVisibility
-- rather than assumed to already agree. progressAnchorTime is a plain
-- GetTime() reference the smooth per-frame animation interpolates from -
-- see ProgressOnUpdate.
local npProgressFill, npProgressBeam
-- progressHandle is the actual SoundPlayer.lua handle being displayed -
-- NOT just progressSoundID (the sound's ID). Two overlapping plays of the
-- SAME sound share one soundID but have two DIFFERENT handles; gating
-- UPDATE/ENDED on soundID alone let the FIRST instance's natural end
-- wrongly snap the SECOND, still-playing instance's bar to 100% (they
-- "matched" on soundID even though they're different plays) - explicit
-- bug report. Every progress event carries its own state.handle, so
-- comparing against progressHandle instead correctly isolates whichever
-- specific instance is actually being shown.
local progressSoundID, progressDuration, progressHandle
-- A plain GetTime() reference the smooth per-frame animation interpolates
-- from - set the instant the bar is shown (SyncProgressVisibility), same
-- call-time basis SoundPlayer.lua's own BuildPlaybackState now uses for
-- `elapsed`/`progress`, so there's nothing to "confirm" or resync to a
-- different basis later - see ProgressOnUpdate.
local progressAnchorTime
-- Ticks the "Xs ago"/"Xmin ago" prefix on the permanent Last Sound record
-- (see ShowLastStatus) once a second so it counts up live instead of
-- freezing at whatever it said when the sound arrived. It exists only
-- while the Mini is visible and a Last Sound record still exists.
local lastPlayedAgoTicker
local isHoveringFavFrame = false -- tracked so HideNowPlaying knows which alpha to restore
local isExpanded = false
local expandedHeight
local expandTicker

local function ApplyLock()
    local locked = SB.db.ui.favLocked
    if lockBtn then
        lockBtn:SetLocked(locked)
    end
    if resizeGrip then
        resizeGrip:SetShown(not locked)
    end
    -- The actual click-through fix: favFrame itself (not just individual
    -- empty slots) has mouse enabled so it can detect hover over the gaps
    -- between icons (see EnterHoverZone/LeaveHoverZone below). That alone
    -- is enough to swallow every click over any part of the window, empty
    -- or not - a slot merely disabling its own mouse just hands the click
    -- down to favFrame underneath it, which still eats it. So while locked,
    -- favFrame's own mouse goes off entirely; only the header (its own
    -- always-on EnableMouse, for drag/close/lock/right-click-to-open) and
    -- filled favourite slots (their own EnableMouse(true), set in
    -- RefreshSlots) keep receiving clicks - every other pixel of the
    -- window truly passes clicks through to the game/UI underneath.
    if favFrame then
        favFrame:EnableMouse(not locked)
        -- One stable gold perimeter in both states. Lock state is already
        -- communicated by the dedicated title-bar control. 0.45 - unified
        -- with the internal header/Now Playing/footer divider lines
        -- (explicit request), not CleanPanel's own brighter 0.88 default.
        favFrame:SetBackdropBorderColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.45)
    end
end

local function SaveSize()
    SB.db.ui.favWidth = favFrame:GetWidth()
    SB.db.ui.favHeight = favFrame:GetHeight()
end

local function SavePosition()
    local point, _, relPoint, x, y = favFrame:GetPoint(1)
    SB.db.ui.favPos = { point = point, relPoint = relPoint, x = x, y = y }
end

local function RestorePosition()
    local pos = SB.db.ui.favPos or { point = "CENTER", relPoint = "CENTER", x = 200, y = 0 }
    favFrame:ClearAllPoints()
    favFrame:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
end

-- Picks whichever supported column count makes all favourite slots as large
-- as possible. The two deliberate extremes are 3x7 and 10x2; unusable
-- 1x20/20x1 strips are never produced.
local function ComputeBestGrid(availW, availH, itemCount)
    itemCount = math.max(0, math.min(SLOT_COUNT, itemCount or 0))
    if itemCount == 0 then return 1, 0, MIN_ICON end
    local bestCols, bestSize = 1, 0
    local bestAspectError = math.huge
    -- Every intermediate wrapping is valid. Three and ten are only the
    -- narrow/wide limits for a full collection, not the only two layouts.
    local minCols = math.min(3, itemCount)
    local maxCols = math.min(10, itemCount)
    local targetAspect = availW / math.max(1, availH)
    for cols = minCols, maxCols do
        local rows = math.ceil(itemCount / cols)
        local sizeFromW = (availW - (cols - 1) * GAP) / cols
        local sizeFromH = (availH - (rows - 1) * GAP) / rows
        local size = math.min(sizeFromW, sizeFromH)
        -- Match the live panel aspect first. Unlike size-only selection,
        -- this allows every intermediate column count (including 6, 8 and
        -- 9) to become the best layout for an appropriate window shape.
        local gridAspect = cols / rows
        local aspectError = math.abs(math.log(gridAspect / targetAspect))
        if aspectError < bestAspectError - 0.0001
            or (math.abs(aspectError - bestAspectError) <= 0.0001 and size > bestSize) then
            bestAspectError = aspectError
            bestSize = size
            bestCols = cols
        end
    end
    local bestRows = math.ceil(itemCount / bestCols)

    if bestSize < MIN_ICON then
        -- The window shrank below what's needed to fit all SLOT_COUNT slots at a
        -- readable size in this shape. Forcing the size up to MIN_ICON
        -- while keeping bestCols/bestRows from the (now too-generous)
        -- unclamped fit is exactly what used to push the grid outside the
        -- window's own border - the icons got bigger but the column/row
        -- count never shrank to match, so the block no longer fit. Instead,
        -- pick however many MIN_ICON-sized columns actually fit sideways
        -- and derive rows from that - the grid may still run taller than
        -- the window in extreme cases (rows clipped at the bottom), but it
        -- never spills past the window's left/right edges anymore.
        bestSize = MIN_ICON
        bestCols = math.max(minCols, math.min(maxCols, math.floor((availW + GAP) / (MIN_ICON + GAP))))
        bestRows = math.ceil(itemCount / bestCols)
    end

    return bestCols, bestRows, bestSize
end

-- The footer's own current (live-scaled) height, kept here so RelayoutSlots
-- and RelayoutNowPlaying both reserve exactly as much space for it as
-- RelayoutFooter last actually gave it.
local currentFooterH = FOOTER_H
local currentHeaderH = HEADER_H
local currentNowPlayingH = NOW_PLAYING_H
local currentStatusFontSize = 10
local MiniFontPath
local MiniScale

local function RelayoutMiniChrome()
    if not favFrame then return end
    local w, h = favFrame:GetSize()
    local layoutH = isExpanded and h or expandedHeight or h
    -- Explicit bug report: the title bar stayed nearly the same tiny size
    -- (22-28px) no matter how large the window got, and its own font
    -- ignored the Mini Soundbook Text Size slider entirely (see titleSize
    -- below) - even maxing that slider out did nothing for it, unlike
    -- every other piece of text here. Both the range and the slope are
    -- widened so a bigger window visibly grows the header, not just the
    -- body content.
    currentHeaderH = math.max(22, math.min(46, math.floor(20 + layoutH * 0.035)))
    local textScale = math.max(0.7, MiniScale())
    local statusFontSize = math.max(9, math.min(24,
        math.floor((10 + layoutH * 0.008) * textScale + 0.5)))
    -- Two independent lines plus breathing room. Deriving the strip from
    -- the actual requested type size guarantees that Last Sound and its
    -- sender can never collide at the larger Settings values.
    currentStatusFontSize = statusFontSize
    local requiredTextH = math.floor(statusFontSize * 3.4 + 8)
    currentNowPlayingH = math.max(36, math.min(96,
        math.max(math.floor(24 + layoutH * 0.04), requiredTextH)))

    if header then
        header:SetHeight(currentHeaderH)
        local controlSize = math.max(18, math.min(34, math.floor((currentHeaderH - 6) * 1.10 + 0.5)))
        for _, control in ipairs({ closeBtn, lockBtn, muteBtn, stopBtn }) do
            if control then control:SetSize(controlSize, controlSize) end
        end
        -- Explicit bugfix: now follows textScale (the Text Size slider)
        -- like every other piece of text in this window already does -
        -- see this function's own comment above. Range widened from the
        -- old fixed 9-12px so the slider and a larger window can actually
        -- produce a noticeably bigger, readable title instead of both
        -- being absorbed by a near-constant clamp.
        local titleSize = math.max(10, math.min(28, math.floor(currentHeaderH * 0.45 * textScale + 0.5)))
        headerText:SetFont(MiniFontPath(), titleSize, "OUTLINE")
    end
    if nowPlaying then
        nowPlaying:ClearAllPoints()
        nowPlaying:SetPoint("TOPLEFT", 0, -currentHeaderH)
        nowPlaying:SetPoint("TOPRIGHT", 0, -currentHeaderH)
        nowPlaying:SetHeight(currentNowPlayingH)
    end
    if body then
        body:ClearAllPoints()
        body:SetPoint("TOPLEFT", favFrame, "TOPLEFT", 0, -(currentHeaderH + currentNowPlayingH))
        body:SetPoint("BOTTOMRIGHT", favFrame, "BOTTOMRIGHT", 0, 0)
    end
end

-- Settings -> Interface -> Mini Soundbook Font. Read fresh every
-- time instead of cached, so a change takes effect the moment it's made
-- (see SB:RefreshFavFont below).
MiniFontPath = function()
    return SB.db.settings.miniFont or SB.AVAILABLE_FONTS[1].path
end

-- Settings -> Interface -> Mini Soundbook Text Size - a vague
-- "smaller <-> bigger" multiplier (SB.FONT_SCALE_STEPS) layered on top of
-- whatever size the window's own dynamic scaling already computed.
MiniScale = function()
    return SB.db.settings.miniFontScale or 1
end

-- Grows/shrinks the name bar with the window itself, while its font also
-- follows the explicit Mini Soundbook text-size setting - so it stays
-- readable on a tiny window and doesn't look like a thin afterthought on a
-- big one.
local function RelayoutFooter()
    if not footer then return end
    local h = isExpanded and (favFrame:GetHeight() or 0) or (expandedHeight or DefaultHeight())
    currentFooterH = math.max(22, math.min(44,
        h * 0.13 * math.max(1, MiniScale())))
    footer:SetHeight(currentFooterH)
    local fontSize = math.max(9, math.min(20,
        math.floor((currentFooterH - 8) * 0.62 + 0.5)))
    footerText:SetFont(MiniFontPath(), fontSize, "OUTLINE")
end

local function RelayoutSlots()
    local w, h = favFrame:GetSize()
    local availW = w - 2 * MARGIN
    local availH = h - currentHeaderH - currentNowPlayingH - currentFooterH - 2 * MARGIN
    if availW <= 0 or availH <= 0 then return end

    -- All 20 saved positions always define the geometry, even though empty
    -- positions have no visual at rest. This preserves layouts such as
    -- sound / empty / sound / empty / sound without compacting them.
    local layoutCount = SLOT_COUNT
    local cols, rows, iconSize = ComputeBestGrid(availW, availH, layoutCount)

    if layoutCount == 0 then
        for i = 1, SLOT_COUNT do
            holders[i]:Hide()
            slots[i]:Hide()
        end
        return
    end

    local blockH = rows * iconSize + (rows - 1) * GAP
    local offsetY = MARGIN + (availH - blockH) / 2

    for i = 1, SLOT_COUNT do
        local holder = holders[i]
        local slot = slots[i]
        if i > layoutCount then
            holder:Hide()
            slot:Hide()
        else
            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            local firstInRow = row * cols + 1
            local rowCount = math.min(cols, layoutCount - firstInRow + 1)
            local rowW = rowCount * iconSize + (rowCount - 1) * GAP
            local rowX = (w - rowW) / 2
        -- Only the holder is ever re-anchored/re-sized here - the slot
        -- itself just follows (it's permanently CENTER-anchored to its
        -- holder, see the `holders` declaration above) and gets its size
        -- refreshed to match the new grid cell.
            holder:SetSize(iconSize, iconSize)
            holder:ClearAllPoints()
            holder:SetPoint("TOPLEFT", body, "TOPLEFT", rowX + col * (iconSize + GAP), -(offsetY + row * (iconSize + GAP)))
            slot:SetSize(iconSize, iconSize)
            holder:Show()
            slot:SetShown(slot.soundID ~= nil or draggingFromIndex ~= nil)
        end
    end
end

-- Re-applies the current font and explicit Mini Soundbook text multiplier
-- to both status lines. The strip follows the expanded window height; the
-- setting changes typography rather than distorting its chrome.
local ensuringTextWidth = false
local function EnsureMiniTextWidth(requiredWidth)
    if not favFrame or isResizing or ensuringTextWidth then return end
    local current = favFrame:GetWidth() or MIN_SIZE
    local target = math.max(MIN_SIZE, math.min(MAX_SIZE, math.ceil(requiredWidth or current)))
    if target > current + 1 then
        ensuringTextWidth = true
        favFrame:SetWidth(target)
        ensuringTextWidth = false
    end
end

-- Explicit request (reverting the previous pass's inline badge): channel
-- back as its own column, far right, vertically CENTERED across the whole
-- strip (not split to either text line), bigger font than the sound name,
-- full channel colour (not just a dot). Sound name stays primary (top-
-- left, largest), sender stays secondary (bottom-left, dim) - "Sound,
-- Quelle, Kanal" in that reading order.
local function RelayoutNowPlaying()
    if not nowPlaying or not npLine1 then return end
    nowPlaying:ClearAllPoints()
    nowPlaying:SetPoint("TOPLEFT", 0, -currentHeaderH)
    nowPlaying:SetPoint("TOPRIGHT", 0, -currentHeaderH)
    nowPlaying:SetHeight(currentNowPlayingH)
    local iconSize = math.max(22, math.min(currentNowPlayingH - 12, currentStatusFontSize * 2.4))
    local fontSize = currentStatusFontSize
    -- Explicit request: toned back down - 1.35x read as too dominant next
    -- to the sound name (which is meant to stay primary). Matches the
    -- sound name's own size now instead of exceeding it - still clearly
    -- set apart by colour/weight, just no longer the single biggest thing
    -- in the strip.
    local channelFontSize = fontSize
    local channelWidth = math.max(46, math.min(76, (nowPlaying:GetWidth() or 160) * 0.22))
    npLine1:SetFont(MiniFontPath(), fontSize, "OUTLINE")
    if npLine2 then npLine2:SetFont(MiniFontPath(), math.max(8, fontSize - 2), "") end
    if npChannel then npChannel:SetFont(MiniFontPath(), channelFontSize, "OUTLINE") end
    npIcon:ClearAllPoints()
    npIcon:SetSize(iconSize, iconSize)
    npIcon:SetPoint("LEFT", nowPlaying, "LEFT", 6, 0)
    npLine1:ClearAllPoints()
    npLine1:SetPoint("LEFT", npIcon, "RIGHT", 7, fontSize * 0.68)
    npLine1:SetPoint("RIGHT", nowPlaying, "RIGHT", -(channelWidth + 8), fontSize * 0.68)
    npLine2:ClearAllPoints()
    npLine2:SetPoint("LEFT", npIcon, "RIGHT", 7, -fontSize * 0.7)
    npLine2:SetPoint("RIGHT", nowPlaying, "RIGHT", -(channelWidth + 8), -fontSize * 0.7)
    npChannel:ClearAllPoints()
    npChannel:SetPoint("RIGHT", nowPlaying, "RIGHT", -8, 0)
    npChannel:SetWidth(channelWidth)
    npChannel:SetJustifyH("RIGHT")
    EnsureMiniTextWidth(math.max(npLine1:GetStringWidth() or 0, npLine2:GetStringWidth() or 0)
        + channelWidth + iconSize + 32)
end

-- Bottom "name bar" - Soundbook 2.0 visual pass: no more filled bar. Idle:
-- just the thin top divider, no text. Hovering a filled slot: the name
-- fades in flanked by two small gold dashes ("──── Name ────"), divider
-- brightens slightly - reads as an integrated caption, not a separate
-- strip. Replaces the old mouse-following GameTooltip for sound items. It
-- never intercepts the mouse itself (see BuildFrame below), so it stays
-- click-through exactly like the rest of the window; it's purely a
-- readout driven by each slot's own hover.
local function ShowSoundNameBar(text, muted)
    if not footer then return end
    footer.divider:SetVertexColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.65)
    if muted then
        footerText:SetText(text .. " (Muted)")
        footerText:SetTextColor(1, 0.55, 0.55)
    else
        footerText:SetText(text)
        -- Explicit request: coloured by the CURRENT Default Output
        -- Channel setting - Guild pastel green, Friends pastel blue,
        -- Direct (one specific person) purple, etc. - same SB.CHANNEL_COLOR
        -- used everywhere else (Communication.lua's own dropdown row
        -- colouring). "ALL" has no single channel and keeps the normal
        -- text colour, same precedent as that dropdown.
        local channelColor = SB.DefaultOutputChannelColor and SB.DefaultOutputChannelColor()
        if channelColor then
            footerText:SetTextColor(channelColor.r, channelColor.g, channelColor.b)
        else
            footerText:SetTextColor(unpack(SB.Theme.TEXT))
        end
    end
    footerText:Show()
    footer.dashLeft:Show()
    footer.dashRight:Show()
    EnsureMiniTextWidth((footerText:GetStringWidth() or 0) + 70)
end

local function HideSoundNameBar()
    if not footer then return end
    footer.divider:SetVertexColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.45)
    footerText:Hide()
    footer.dashLeft:Hide()
    footer.dashRight:Hide()
end

-- Explicit request: channel goes back to its own dedicated element
-- (npChannel, far right) instead of an inline badge folded into the
-- sender line - this just applies its colour/text; npChannel itself is
-- positioned/sized in RelayoutNowPlaying.
local function SetChannelDisplay(sourceLabel)
    if not npChannel then return end
    local color = SB.GetChannelColor(sourceLabel)
    displayedSourceLabel = sourceLabel
    local queued = SB.GetPendingQueueSize and SB:GetPendingQueueSize() or 0
    npChannel:SetText(string.upper(sourceLabel) .. (queued > 0 and (" +" .. queued) or ""))
    npChannel:SetTextColor(color.r, color.g, color.b)
end

-- A compact "+N" on the existing source label exposes pending remote
-- playback without taking a single pixel away from the Favourite grid.
SB:On("REMOTE_QUEUE_CHANGED", function()
    if displayedSourceLabel then SetChannelDisplay(displayedSourceLabel) end
end)

local PROGRESS_INSET = 1

-- Sets the fill's actual on-screen width AND the beam's position for a
-- given 0-1 progress value, against nowPlaying's CURRENT width - called
-- every frame (see ProgressOnUpdate) so a live resize/rescale is always
-- reflected immediately, same as everything else in RelayoutNowPlaying.
local function SetProgressFill(progress)
    if not npProgressFill or not nowPlaying then return end
    progress = math.max(0, math.min(1, progress or 0))
    local fullW = math.max(0, (nowPlaying:GetWidth() or 0) - 2 * PROGRESS_INSET)
    npProgressFill:SetWidth(math.max(0.01, fullW * progress))
    if npProgressBeam then
        npProgressBeam:ClearAllPoints()
        npProgressBeam:SetPoint("TOP", nowPlaying, "TOPLEFT", PROGRESS_INSET + fullW * progress, -PROGRESS_INSET)
        npProgressBeam:SetPoint("BOTTOM", nowPlaying, "BOTTOMLEFT", PROGRESS_INSET + fullW * progress, PROGRESS_INSET)
    end
end

------------------------------------------------------------------------
-- Secondary progress indicators - explicit request: an older sound that
-- was superseded by a newer one (as the "current" name/sender display)
-- but hasn't actually finished playing yet keeps its OWN thin vertical
-- beam, just like the primary indicator's own gold one, only weaker/less
-- present - "verliert nur seine Farbe/Auffälligkeit", not its progress.
-- Coloured per the CHANNEL/SOURCE it was sent over (pastel version of the
-- same colours the Now Playing channel label already uses elsewhere -
-- SB.GetChannelColor), at low alpha and plain BLEND (not the primary
-- beam's ADD glow), so it reads as clearly secondary and never competes
-- with or washes out the gold. A small pool, capped at SECONDARY_MAX so
-- an extreme overlap-testing burst can't spawn an unbounded number.
------------------------------------------------------------------------
local SECONDARY_MAX = 4
local SECONDARY_ALPHA = 0.5
local secondaryPool = {}         -- [slot] = texture
local secondarySlotByHandle = {} -- [handle] = slot
local secondaryState = {}        -- [slot] = { handle, anchorTime, duration }
-- [handle] = { sourceLabel = "Self"/"Guild"/"Raid"/"Party"/"Friends"/
-- "Direct", sender = <name> } - set by ShowNowPlaying (the only place
-- that actually knows the channel/sender; SoundPlayer.lua's tracking
-- itself is channel-agnostic) at the moment a play becomes primary, read
-- back here both to colour a demoted secondary indicator AND to restore
-- the full Now Playing text if that sound gets promoted back (see
-- TryPromoteSecondary). Cleaned up whenever that handle's indicator
-- (primary or secondary) is released, so it never grows unbounded.
local handleInfo = {}

local function EnsureSecondaryTexture(slot)
    if secondaryPool[slot] then return secondaryPool[slot] end
    local tex = nowPlaying:CreateTexture(nil, "BORDER")
    tex:SetWidth(2)
    tex:Hide()
    secondaryPool[slot] = tex
    return tex
end

local function SetSecondaryPosition(slot, progress)
    local tex = secondaryPool[slot]
    local st = secondaryState[slot]
    if not tex or not st or not nowPlaying then return end
    progress = math.max(0, math.min(1, progress or 0))
    local fullW = math.max(0, (nowPlaying:GetWidth() or 0) - 2 * PROGRESS_INSET)
    tex:ClearAllPoints()
    tex:SetPoint("TOP", nowPlaying, "TOPLEFT", PROGRESS_INSET + fullW * progress, -PROGRESS_INSET)
    tex:SetPoint("BOTTOM", nowPlaying, "BOTTOMLEFT", PROGRESS_INSET + fullW * progress, PROGRESS_INSET)
end

-- Forward-declared - RefreshOnUpdateAttachment needs to know whether any
-- secondary slot is occupied, and ReleaseSecondary/UpdateSecondary need to
-- call it after changing that.
local RefreshOnUpdateAttachment

-- `keepInfo` - when a handle is being demoted OUT of the secondary pool
-- because it's about to be PROMOTED back to primary (see
-- TryPromoteSecondary), its handleInfo entry must survive this release -
-- only a genuine end (ReleaseSecondary called with no second argument)
-- should ever clear it.
local function ReleaseSecondary(handle, keepInfo)
    local slot = secondarySlotByHandle[handle]
    if not slot then return end
    secondarySlotByHandle[handle] = nil
    secondaryState[slot] = nil
    if not keepInfo then handleInfo[handle] = nil end
    if secondaryPool[slot] then secondaryPool[slot]:Hide() end
    RefreshOnUpdateAttachment()
end

-- Called from the PLAYBACK_PROGRESS_UPDATE handler whenever
-- state.isPrimary is false. By the time a handle's updates start
-- reporting isPrimary=false, SoundPlayer.lua's own primaryHandle has
-- ALREADY moved on to a newer sound - continues smoothly from THIS
-- handle's own current elapsed time (state.elapsed) rather than
-- restarting at 0%, so the visual transition is "the same indicator, just
-- demoted", not a new one popping in from empty.
local function UpdateSecondary(state)
    if not nowPlaying or not state.duration or state.duration <= 0 then return end
    local slot = secondarySlotByHandle[state.handle]
    if not slot then
        for i = 1, SECONDARY_MAX do
            local taken = false
            for _, s in pairs(secondarySlotByHandle) do
                if s == i then taken = true break end
            end
            if not taken then slot = i break end
        end
        if not slot then return end -- pool full - rare, silently skip
        secondarySlotByHandle[state.handle] = slot
        local tex = EnsureSecondaryTexture(slot)
        -- Pastel = the same colour SB.GetChannelColor already uses for
        -- this sound's channel label, just at low alpha and plain blend
        -- (not the primary beam's ADD) - explicit request: must never
        -- read as brighter/more attention-grabbing than the gold primary
        -- indicator. Falls back to the neutral SELF grey if the source
        -- was somehow never recorded (shouldn't normally happen).
        local info = handleInfo[state.handle]
        local color = SB.GetChannelColor(info and info.sourceLabel) or SB.CHANNEL_COLOR.SELF
        tex:SetColorTexture(color.r, color.g, color.b, SECONDARY_ALPHA)
        tex:Show()
    end
    secondaryState[slot] = {
        handle = state.handle,
        soundID = state.soundID,
        anchorTime = GetTime() - state.elapsed,
        duration = state.duration,
    }
    RefreshOnUpdateAttachment()
end

-- Runs every rendered frame while EITHER the primary bar or any secondary
-- indicator is active (attached/detached via RefreshOnUpdateAttachment) -
-- explicit request: the poll-driven PLAYBACK_PROGRESS_UPDATE events alone
-- (every ~80ms) looked visibly stepped, especially on short sounds. This
-- interpolates smoothly from each indicator's own GetTime() anchor every
-- frame; each real PLAYBACK_PROGRESS_UPDATE still arrives and re-syncs
-- that anchor to SoundPlayer.lua's own authoritative elapsed value, so
-- per-frame drift never accumulates.
local function ProgressOnUpdate()
    if progressAnchorTime and progressDuration and progressDuration > 0 then
        SetProgressFill((GetTime() - progressAnchorTime) / progressDuration)
    end
    for slot, st in pairs(secondaryState) do
        SetSecondaryPosition(slot, (GetTime() - st.anchorTime) / st.duration)
    end
end

RefreshOnUpdateAttachment = function()
    if not nowPlaying then return end
    if progressAnchorTime or next(secondaryState) then
        nowPlaying:SetScript("OnUpdate", ProgressOnUpdate)
    else
        nowPlaying:SetScript("OnUpdate", nil)
    end
end

-- Reconciles the fill's visibility with whatever is CURRENTLY being shown
-- in the strip (currentPlayingSoundID) against whatever playback tracking
-- most recently started (progressSoundID/progressDuration) - the two can
-- briefly disagree for one event tick (see the top-of-file comment) and
-- this is what brings them back in sync. No known duration -> the fill
-- simply never appears for this play (explicit requirement - never guess
-- a percentage), even though the sound is still tracked for LEARNING a
-- duration for next time.
--
-- Starts the animation immediately, from GetTime() right now - no
-- "waiting for confirmation" step. Explicit fix for two related bugs from
-- an earlier version that DID wait for SoundPlayer.lua's own
-- C_Sound.IsPlaying-confirmed timing: (1) a visible "double start" stutter
-- right at the beginning of every sound, caused by animating from a
-- GUESSED anchor that then snapped once the confirmed one arrived ~80ms
-- later; (2) retriggering the SAME sound before it finished blanked the
-- bar out completely, because C_Sound.IsPlaying can't tell the two
-- overlapping instances of an identical sound apart, so a trustworthy
-- confirmation might never arrive at all. Since display now runs entirely
-- off call time (see SoundPlayer.lua's BuildPlaybackState) instead of
-- waiting on that confirmation, neither problem can occur - every new
-- sound (interrupting an old one or not, overlapping itself or not)
-- always gets an immediate, correctly-timed restart. Only affects the
-- PRIMARY bar - secondary bars manage their own lifecycle independently
-- (see UpdateSecondary/ReleaseSecondary) and are untouched here, so an
-- older still-playing sound keeps animating even once the primary slot
-- has already reverted to idle/last-status.
local function SyncProgressVisibility()
    if not npProgressFill then return end
    progressAnchorTime = nil
    if currentPlayingSoundID and progressSoundID == currentPlayingSoundID
        and progressDuration and progressDuration > 0 then
        npProgressFill:Show()
        if npProgressBeam then npProgressBeam:Show() end
        progressAnchorTime = GetTime()
        SetProgressFill(0)
    else
        npProgressFill:Hide()
        if npProgressBeam then npProgressBeam:Hide() end
    end
    RefreshOnUpdateAttachment()
end

local function HideProgressFill()
    if npProgressFill then npProgressFill:Hide() end
    if npProgressBeam then npProgressBeam:Hide() end
    progressAnchorTime = nil
    RefreshOnUpdateAttachment()
end

local function ShowIdleStatus()
    if npIcon then npIcon:SetTexture("Interface\\Icons\\INV_Misc_Note_01") end
    if npLine1 then
        npLine1:SetText("Ready")
        npLine1:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    end
    if npLine2 then
        npLine2:SetText("No sound played yet")
        npLine2:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    end
    if npChannel then npChannel:SetText("") end
    HideProgressFill()
    RelayoutNowPlaying()
end

-- "3s ago" / "2min ago" - always counts UP from when the sound was
-- received, never resets/counts down. Caps at 59min; ShowLastStatus below
-- clears the whole record once it'd tick over to 60min instead of ever
-- displaying an hour tier - explicit request, "danach wird gecleared".
local LAST_PLAYED_MAX_SECONDS = 60 * 60
local function FormatAgo(receivedAt)
    local secs = math.max(0, math.floor(time() - (receivedAt or time())))
    if secs < 60 then return secs .. "s" end
    return math.floor(secs / 60) .. "min"
end

local LAST_PLAYED_AGO_HEX = "ff8c26" -- same orange as the raid-admin-mute badge elsewhere in this file
local function StopLastPlayedTicker()
    if lastPlayedAgoTicker then
        lastPlayedAgoTicker:Cancel()
        lastPlayedAgoTicker = nil
    end
end

local function ShowLastStatus()
    if currentPlayingSoundID or not lastPlayed then return end
    if time() - (lastPlayed.receivedAt or time()) >= LAST_PLAYED_MAX_SECONDS then
        lastPlayed = nil
        StopLastPlayedTicker()
        ShowIdleStatus()
        return
    end
    npIcon:SetTexture(SB:GetSoundIcon(lastPlayed.soundID))
    -- Primary: an orange, live-counting "Xs ago:" prefix (explicit
    -- request - always visible, even long after the sound itself expired)
    -- followed by the sound name at the usual dimmed "last played" weight.
    -- The prefix is baked into the string via an inline colour escape
    -- rather than a second FontString - the "|r" resets back to whatever
    -- SetTextColor sets below, so the name itself is unaffected.
    npLine1:SetText(("|cff%s%s ago:|r %s"):format(
        LAST_PLAYED_AGO_HEX, FormatAgo(lastPlayed.receivedAt), SB:GetSoundDisplayName(lastPlayed.soundID)))
    npLine1:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    -- Secondary: sender only, neutral dim text - channel is its own
    -- element now (SetChannelDisplay), not folded into this line.
    -- Explicit request: never a realm suffix here, even for a cross-realm
    -- sender (SB.GetPlayerDisplayName, Validation.lua).
    npLine2:SetText(SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(lastPlayed.sender) or lastPlayed.sender)
    npLine2:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    SetChannelDisplay(lastPlayed.source)
    HideProgressFill()
    RelayoutNowPlaying()
end

local function StartLastPlayedTicker()
    if lastPlayedAgoTicker or not lastPlayed or not (favFrame and favFrame:IsShown()) then return end
    lastPlayedAgoTicker = C_Timer.NewTicker(1, ShowLastStatus)
end

-- Forward-declared - TryPromoteSecondary needs to call ShowNowPlaying
-- (defined further down) to actually restore an older sound's name/
-- sender/source display, and HideNowPlaying itself (its own real
-- definition, right below, is assigned to this same local rather than
-- using another `local function` - so is ShowNowPlaying's, further down -
-- both keep being the exact same upvalue everywhere else in this file
-- already refers to them by).
local ShowNowPlaying, HideNowPlaying

-- Falls back to an older sound that's STILL PLAYING in the background
-- (tracked as a secondary indicator) when the current primary one just
-- ended - explicit request: "ich wünsche mir dass der laufende Sound 1
-- dann wieder zurückspringt, mit den Informationen Titel/von wem/Quelle,
-- und der Duration-Indikator wird wieder der goldene primäre." Scans every
-- current secondary (typically there's only one) for the first one that's
-- CONFIRMED still actually playing (see the live C_Sound.IsPlaying check
-- below) and restores it exactly where it left off - no restart to 0%.
-- Returns true if a promotion happened (caller should skip the normal
-- idle/last-status fallback in that case).
local function TryPromoteSecondary()
    -- An explicit "skip the live view entirely" preference (Announcement
    -- Duration = 0) means promoting doesn't make sense either - respect it
    -- the same way a fresh ShowNowPlaying call already would.
    if (tonumber(SB.db.settings.announceDuration) or 3) <= 0 then return false end

    -- Explicit bugfix (the "two overlapping sounds ending at the same time
    -- flicker back and forth" report): a candidate's own stored duration/
    -- anchorTime math (used further below purely to correct the
    -- Announcement Duration timer once a promotion is already happening)
    -- can be off from the sound's REAL end by up to SoundPlayer.lua's own
    -- ~80ms poll interval, or by however far a precomputed/learned
    -- duration is from the real file - close enough that when two
    -- overlapping sounds finish within that same small margin of each
    -- other, a secondary can still look "not quite over yet" on paper
    -- while its actual audio has already stopped (PLAYBACK_PROGRESS_ENDED
    -- for it simply hasn't arrived yet). Promoting that one anyway used to
    -- flip the display onto an already-silent sound for a fraction of a
    -- second before immediately snapping back to idle/last-status - the
    -- reported flicker, repeating for every secondary this happened to
    -- hit. A live C_Sound.IsPlaying check right here, on the actual
    -- handle, is the one thing that can't lie about this - a candidate
    -- that fails it is released outright (it really has already finished)
    -- and the next one (if any) is tried instead, rather than ever
    -- promoting a sound that's already silent.
    for handle, slot in pairs(secondarySlotByHandle) do
        local ok, isPlaying = pcall(C_Sound.IsPlaying, handle)
        if ok and isPlaying then
            local st = secondaryState[slot]
            local info = handleInfo[handle]
            if st and info then
                local elapsedSoFar = GetTime() - st.anchorTime
                SB:Debug("TryPromoteSecondary: promoting handle=%s soundID=%s duration=%s elapsedSoFar=%.2f",
                    tostring(handle), tostring(st.soundID), tostring(st.duration), elapsedSoFar)
                ReleaseSecondary(handle, true) -- true: keep handleInfo, ShowNowPlaying below still needs it
                if SB.PromoteTrackedHandle then SB:PromoteTrackedHandle(handle) end

                -- Seeded here so ShowNowPlaying's own SyncProgressVisibility
                -- call (which requires these to already agree) shows the
                -- bar immediately, exactly like a fresh
                -- PLAYBACK_PROGRESS_STARTED would have.
                progressSoundID = st.soundID
                progressDuration = st.duration
                progressHandle = handle

                ShowNowPlaying(st.soundID, info.sender, (info.sourceLabel ~= "Self") and info.sourceLabel or nil, false)

                -- Restores real continuity - ShowNowPlaying's Sync just
                -- reset the anchor to "now" (0% elapsed); overwritten here,
                -- before anything ever renders, so there's no visible flash
                -- back to 0%.
                progressAnchorTime = st.anchorTime

                -- The Announcement Duration timer ShowNowPlaying just
                -- scheduled assumed a FRESH sound starting now - correct it
                -- to this sound's actual REMAINING time instead, so the
                -- strip doesn't linger long after it has genuinely finished.
                if nowPlayingTimer then
                    nowPlayingTimer:Cancel()
                    local remaining
                    if elapsedSoFar < st.duration then
                        remaining = math.max(0.1, st.duration - elapsedSoFar + 0.3)
                    else
                        -- Explicit bugfix ("zwei Sounds... können sich
                        -- nicht entscheiden was angezeigt wird"): this
                        -- sound is already PAST its own known/learned
                        -- duration, yet the live C_Sound.IsPlaying check
                        -- above just confirmed it's still genuinely
                        -- playing - its stored duration is simply too
                        -- short to trust for timing from here on (a
                        -- precomputed/learned-duration inaccuracy). The old
                        -- math (duration - elapsedSoFar) went negative and
                        -- floored at the same 0.1s every time, which - with
                        -- a SECOND similarly-overdue sound sitting in the
                        -- other slot - re-triggered this same promotion
                        -- path against each other roughly ten times a
                        -- second, each swap flipping the visible display:
                        -- the reported rapid back-and-forth. A fixed,
                        -- much slower re-check instead keeps the display
                        -- stable and readable while still catching the
                        -- real end promptly once it actually happens.
                        remaining = 1.0
                    end
                    SB:Debug("TryPromoteSecondary: correcting timer to remaining=%.2f (duration=%s elapsedSoFar=%.2f)",
                        remaining, tostring(st.duration), elapsedSoFar)
                    nowPlayingTimer = C_Timer.NewTimer(remaining, HideNowPlaying)
                end

                return true
            end
        else
            -- Already silent for real, despite still looking "active" on
            -- paper (SoundPlayer.lua's poll just hasn't caught up to it
            -- yet) - release it outright, no lingering entry, and keep
            -- scanning for a genuinely still-playing candidate instead of
            -- ever displaying this one.
            SB:Debug("TryPromoteSecondary: handle=%s already silent (IsPlaying=%s ok=%s) - releasing without promoting",
                tostring(handle), tostring(isPlaying), tostring(ok))
            ReleaseSecondary(handle)
        end
    end

    SB:Debug("TryPromoteSecondary: nothing left genuinely still playing to promote")
    return false
end

-- `allowPromote` (default true) - false only for an explicit Stop
-- (PLAYBACK_STOPPED already stops every tracked handle, primary and
-- secondary alike, so there's nothing left to fall back to anyway) and
-- the Announcement Duration=0 "skip straight to idle" path.
HideNowPlaying = function(allowPromote)
    if nowPlayingTimer then
        nowPlayingTimer:Cancel()
        nowPlayingTimer = nil
    end
    if nowPlaying then nowPlaying:Show() end
    currentPlayingSoundID = nil
    HideProgressFill()
    if allowPromote ~= false and TryPromoteSecondary() then
        return
    end
    if lastPlayed then ShowLastStatus() else ShowIdleStatus() end
    for _, slot in ipairs(slots) do
        if slot.soundID then
            local saved = SB:GetSoundSaved(slot.soundID)
            slot:SetVisualState("normal", true, saved.muted and true or false)
        end
    end
    HideSoundNameBar()
    -- Drop back to whichever alpha currently applies (idle or hover,
    -- depending on where the mouse actually is right now).
    SB:ApplyFavAlpha(isHoveringFavFrame)
end

-- channelLabel is nil for a locally-triggered sound with nowhere it's
-- being sent (no sender/channel to show, just your own name) and a string
-- like "Raid"/"Guild" otherwise - for a remote sound that's who sent it
-- for real; for a local one that's now sending somewhere too (see
-- LocalTargetToChannelLabel below), it's just where YOUR click is headed,
-- not something received.
--
-- `isReceived` (true only for the REMOTE_SOUND_PLAYED path below) is what
-- actually gates the permanent "Last Sound" record - NOT whether
-- channelLabel happens to be set, since a local send can carry a channel
-- label too ("Guild") without being a received sound.
--
-- Playback information updates the reserved strip without touching slots.
ShowNowPlaying = function(soundID, sender, channelLabel, isReceived)
    local info = SB.registry[soundID]
    if not info then return end
    local sourceLabel = channelLabel or "Self"
    -- Explicit request: the permanent "Last Sound" record (see
    -- ShowLastStatus) must only ever reflect a sound RECEIVED from someone
    -- else - your own plays/sends must never overwrite it, even one being
    -- actively sent to a channel right now, even though they still get the
    -- same live "who's playing what" strip while actively playing (below).
    -- "I don't need to see that I heard my own sound - only other people's."
    if isReceived then
        lastPlayed = {
            soundID = soundID,
            sender = sender or UnitName("player"),
            source = sourceLabel,
            receivedAt = time(),
        }
        StartLastPlayedTicker()
    end
    if not favFrame or not favFrame:IsShown() then return end

    -- Settings -> Interface -> Announcement Duration controls how
    -- long the live state is shown before it becomes the permanent Last
    -- Sound record. Zero skips directly to Last Sound.
    local displaySeconds = tonumber(SB.db.settings.announceDuration) or 3
    if displaySeconds <= 0 then
        HideNowPlaying()
        return
    end
    -- Explicit request: the bar must never disappear while the sound is
    -- still actually playing - the setting above is now only a MINIMUM,
    -- extended up to the sound's own real duration (plus a small grace
    -- margin so it doesn't cut off right at the last instant) whenever
    -- that's known and longer than the configured minimum.
    if info.durationSeconds and info.durationSeconds + 0.3 > displaySeconds then
        displaySeconds = info.durationSeconds + 0.3
    end

    npIcon:SetTexture(SB:GetSoundIcon(soundID))
    currentPlayingSoundID = soundID
    -- Records who sent it and over which channel THIS specific handle was
    -- sent/received - SoundPlayer.lua's own tracking is channel-agnostic,
    -- this is the only place that actually knows it. Read back later
    -- either to colour this play's demoted secondary indicator
    -- (UpdateSecondary) or to fully restore it if promoted back to
    -- primary (TryPromoteSecondary). progressHandle is already this
    -- play's handle by now (PLAYBACK_PROGRESS_STARTED set it just before
    -- this function ran).
    if progressHandle then
        handleInfo[progressHandle] = { sourceLabel = sourceLabel, sender = sender }
    end
    -- Reconciles the progress fill with whatever SoundPlayer.lua's
    -- PLAYBACK_PROGRESS_STARTED most recently reported (that event fires
    -- slightly BEFORE this function does - see the top-of-file comment on
    -- progressSoundID) - now that currentPlayingSoundID is finally set,
    -- this is the moment they're guaranteed to be comparable.
    SyncProgressVisibility()
    local soundName = SB:GetSoundDisplayName(soundID)
    -- channelLabel is nil for a locally-triggered sound - "Self" is itself
    -- the source label there (not a fallback/placeholder), matching the
    -- same "Name (Source):" shape a remote sound's "Player (Friend):" /
    -- "Player2 (Guild):" uses. Explicit request: colour-code the source
    -- the same way everywhere - see SB.CHANNEL_COLOR (Core.lua).
    -- Full brightness here (vs. ShowLastStatus's TEXT_DIM) - "während
    -- Playback höhere visuelle Intensität" - the only thing that changes
    -- between live and last-played is this weight, not the layout.
    npLine1:SetText(soundName)
    npLine1:SetTextColor(unpack(SB.Theme.TEXT))
    -- Explicit request: never a realm suffix here, even for a cross-realm
    -- sender (SB.GetPlayerDisplayName, Validation.lua).
    local displaySender = sender or UnitName("player")
    npLine2:SetText(SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(displaySender) or displaySender)
    npLine2:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    SetChannelDisplay(sourceLabel)
    RelayoutNowPlaying()
    nowPlaying:Show()
    for _, slot in ipairs(slots) do
        if slot.soundID == soundID then
            local saved = SB:GetSoundSaved(soundID)
            slot:SetVisualState("playing", true, saved.muted and true or false)
        end
    end

    -- Always fully visible while showing who's playing what, regardless
    -- of the configured idle/hover alpha - the whole point is that you
    -- notice it even if the window is normally very transparent.
    favFrame:SetAlpha(1)

    if nowPlayingTimer then nowPlayingTimer:Cancel() end
    if C_Timer and C_Timer.NewTimer then
        nowPlayingTimer = C_Timer.NewTimer(displaySeconds, HideNowPlaying)
    else
        C_Timer.After(displaySeconds, HideNowPlaying) -- no Cancel(), best effort
    end
end

-- How far outside favFrame's own edge a drop has to land to count as "I
-- don't want this favourite anymore" instead of just a missed reorder
-- target - explicit request: must be an unambiguous, deliberate drag-away,
-- never an accidental few-pixel miss right at the window's border.
local DELETE_DRAG_DISTANCE = 50
local lastDragX, lastDragY

local function IsInDeleteZone(x, y)
    if not favFrame or not x then return false end
    local left, right, top, bottom = favFrame:GetLeft(), favFrame:GetRight(), favFrame:GetTop(), favFrame:GetBottom()
    if not left then return false end
    return x < left - DELETE_DRAG_DISTANCE
        or x > right + DELETE_DRAG_DISTANCE
        or y < bottom - DELETE_DRAG_DISTANCE
        or y > top + DELETE_DRAG_DISTANCE
end

local function StartGhostDrag(slotIndex, iconPath, iconSize)
    draggingFromIndex = slotIndex
    isHoveringFavFrame = true
    SB:ApplyFavAlpha(true)
    if not dragGhost then
        -- A texture has no frame strata of its own - it renders wherever
        -- its PARENT frame sits. Parenting straight to UIParent (default
        -- "MEDIUM" strata) put the old ghost BEHIND favFrame itself
        -- ("DIALOG" strata, see BuildFrame below), and "TOOLTIP" was never
        -- a valid CreateTexture draw layer to begin with (BACKGROUND/
        -- BORDER/ARTWORK/OVERLAY/HIGHLIGHT are the only five) - together
        -- these threw "bad argument #3" the moment a drag actually reached
        -- here. A small dedicated frame at "TOOLTIP" strata fixes both:
        -- always above every other Soundbook window, valid layer for the
        -- texture on it.
        dragGhostFrame = SB.CreateFrame("Frame", nil, UIParent)
        dragGhostFrame:SetFrameStrata("TOOLTIP")
        dragGhostFrame:SetBackdrop({ edgeFile = WHITE_TEX, edgeSize = 1 })
        dragGhost = dragGhostFrame:CreateTexture(nil, "OVERLAY")
        dragGhost:SetAllPoints()
        dragGhost:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        dragGhostOrnament = dragGhostFrame:CreateTexture(nil, "OVERLAY", nil, 1)
        dragGhostOrnament:SetPoint("CENTER", dragGhostFrame, "CENTER", 0, 0)
        dragGhostOrnament:SetTexture("Interface\\AddOns\\Soundbook\\Assets\\IconFrame")
        dragGhostOrnament:SetTexCoord(0, 1, 0, 1)
    end
    local ghostSize = math.max(MIN_ICON, (iconSize or BASE_ICON_SIZE) * 1.30)
    dragGhostFrame:SetSize(ghostSize, ghostSize)
    dragGhostOrnament:SetSize(ghostSize * 1.50, ghostSize * 1.50)
    dragGhostFrame:SetBackdropBorderColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 1)
    dragGhost:SetTexture(iconPath)
    dragGhost:SetVertexColor(1, 1, 1) -- reset any red delete-zone tint left over from a previous drag
    dragGhostOrnament:SetVertexColor(0.88, 0.94, 1.0, 1)
    dragGhostFrame:Show()
    -- Only while dragging, reveal every one of the 20 valid destinations.
    -- Filled and empty targets keep their real positional indices.
    RefreshSlots()
    favFrame:SetScript("OnUpdate", function()
        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        x, y = x / scale, y / scale
        lastDragX, lastDragY = x, y
        dragGhostFrame:ClearAllPoints()
        dragGhostFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
        -- Red tint = "let go here to remove this favourite" - shown live
        -- WHILE dragging (not just discovered after releasing), same
        -- DELETE_DRAG_DISTANCE threshold StopGhostDrag itself acts on.
        if IsInDeleteZone(x, y) then
            dragGhost:SetVertexColor(1, 0.3, 0.3)
            dragGhostOrnament:SetVertexColor(1, 0.18, 0.18, 0.95)
            dragGhostFrame:SetBackdropBorderColor(1, 0.15, 0.15, 1)
        else
            dragGhost:SetVertexColor(1, 1, 1)
            dragGhostOrnament:SetVertexColor(0.88, 0.94, 1.0, 1)
            dragGhostFrame:SetBackdropBorderColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 1)
        end
    end)
end

local function StopGhostDrag(dropSlotIndex)
    favFrame:SetScript("OnUpdate", nil)
    if dragGhostFrame then dragGhostFrame:Hide() end
    if draggingFromIndex then
        if IsInDeleteZone(lastDragX, lastDragY) then
            -- Dragged clearly away from the whole window, not just a
            -- pixel or two past a slot's edge - explicit request: THIS
            -- gesture means "remove it", not "reorder it".
            local soundID = SB:GetFavourites()[draggingFromIndex]
            if soundID then
                SB:RemoveFavourite(soundID)
            end
        elseif dropSlotIndex and dropSlotIndex ~= draggingFromIndex then
            SB:MoveFavourite(draggingFromIndex, dropSlotIndex)
        end
    end
    draggingFromIndex = nil
    lastDragX, lastDragY = nil, nil
    RefreshSlots()
    local stillInside = favFrame and favFrame.IsMouseOver and favFrame:IsMouseOver()
    if stillInside then
        isHoveringFavFrame = true
        SB:ApplyFavAlpha(true)
    else
        isHoveringFavFrame = false
        if CollapseMini then CollapseMini() end
        SB:ApplyFavAlpha(false)
    end
end

-- GetMouseFocus was replaced by GetMouseFoci (returning a table) on some
-- newer clients; support both so drag & drop keeps working either way.
local function GetFocusedFrame()
    if GetMouseFoci then
        local foci = GetMouseFoci()
        return foci and foci[1]
    elseif GetMouseFocus then
        return GetMouseFocus()
    end
    return nil
end

local function FindSlotUnderCursor()
    local focus = GetFocusedFrame()
    if focus and focus.soundbookSlotIndex then
        return focus.soundbookSlotIndex
    end
    return nil
end

RefreshSlots = function()
    local favourites = SB:GetFavourites()
    local locked = SB.db.ui.favLocked

    for i = 1, SLOT_COUNT do
        local slot = slots[i]
        local soundID = favourites[i]
        if soundID and not SB.registry[soundID] then soundID = nil end
        slot.soundID = soundID
        slot.soundbookSlotIndex = soundID and i or nil
        if soundID then
            local icon = SB:GetSoundIcon(soundID)
            slot.texture:SetTexture(icon)
            slot.texture:Show()
            -- Every filled slot here is a favourite by definition, so its
            -- border is always the accent colour.
            local saved = SB:GetSoundSaved(soundID)
            -- Per-sound "Default Output" override (explicit request) -
            -- same channel-coloured border/wash treatment as the main
            -- Soundbook grid (UI.lua), so an overridden sound reads the
            -- same way here too.
            local outputColor = SB.SoundOutputOverrideColor and SB.SoundOutputOverrideColor(soundID)
            slot:SetVisualState(currentPlayingSoundID == soundID and "playing" or "normal",
                true, saved.muted and true or false, outputColor)
            slot.statusBadge:SetShown(saved.muted and true or false)
            -- "Alternative Sound" purple wash (Theme.lua's CreateIconSlot) -
            -- explicit request, shown "always, everywhere" for a sound
            -- with a personal alternate recording enabled.
            slot:SetAlternate(saved.useAlternate)
            slot:SetOutputTint(outputColor)
            slot.soundbookHoverDisabled = false
            slot:EnableMouse(true)
            if not locked then
                slot:RegisterForDrag("LeftButton")
            else
                slot:RegisterForDrag()
            end
            slot:Show()
        else
            slot:SetVisualState("normal", false, false, nil)
            slot.texture:Hide()
            slot.statusBadge:Hide()
            slot:SetAlternate(false)
            slot:SetOutputTint(nil)
            -- Empty capacity is invisible at rest. Drag mode temporarily
            -- turns it into a grey-edged target below.
            slot:SetBackdropColor(0, 0, 0, 0)
            slot:SetBackdropBorderColor(0, 0, 0, 0)
            slot:RegisterForDrag()
            if draggingFromIndex then
                -- Drag-only drop target: quiet transparent fill and a
                -- neutral grey one-pixel edge. No icon, hover ornament or
                -- zoom; it disappears immediately when the drag ends.
                slot.soundbookSlotIndex = i
                slot.soundbookHoverDisabled = true
                slot:SetBackdropColor(0, 0, 0, 0)
                slot:SetBackdropBorderColor(0.48, 0.52, 0.58, 0.85)
                slot:EnableMouse(true)
                slot:Show()
            else
                slot.soundbookHoverDisabled = true
                slot:EnableMouse(false)
                slot:Hide()
            end
        end
    end
    RelayoutSlots()
end

local function SetMiniHeightKeepingTop(height)
    local left, top = favFrame:GetLeft(), favFrame:GetTop()
    favFrame:SetHeight(height)
    if left and top then
        favFrame:ClearAllPoints()
        favFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end
end

local function SetMiniResizeBounds(minHeight)
    if favFrame.SetResizeBounds then
        favFrame:SetResizeBounds(MIN_SIZE, minHeight, MAX_SIZE, MAX_SIZE)
    elseif favFrame.SetMinResize then
        favFrame:SetMinResize(MIN_SIZE, minHeight)
        favFrame:SetMaxResize(MAX_SIZE, MAX_SIZE)
    end
end

local function LayoutBodyOffset(offset)
    if not body then return end
    body:ClearAllPoints()
    body:SetPoint("TOPLEFT", favFrame, "TOPLEFT", 0,
        -(currentHeaderH + currentNowPlayingH) + (offset or 0))
    body:SetPoint("BOTTOMRIGHT", favFrame, "BOTTOMRIGHT", 0, 0)
end

CollapseMini = function()
    if not favFrame or not body or isResizing or draggingFromIndex then return end
    if expandTicker then expandTicker:Cancel(); expandTicker = nil end
    body:Hide()
    isExpanded = false
    RelayoutMiniChrome()
    local collapsedHeight = currentHeaderH + currentNowPlayingH + 2
    -- Resize bounds also constrain programmatic SetHeight on some clients.
    -- Lower the passive minimum first or the client silently forces this
    -- back to MIN_SIZE and leaves a large empty panel under the two strips.
    SetMiniResizeBounds(collapsedHeight)
    SetMiniHeightKeepingTop(collapsedHeight)
    RelayoutMiniChrome()
    RelayoutNowPlaying()
end

local function ExpandMini()
    if not favFrame or not body or isExpanded then return end
    isExpanded = true
    SetMiniResizeBounds(MIN_SIZE)
    SetMiniHeightKeepingTop(math.max(MIN_SIZE, expandedHeight or DefaultHeight()))
    RelayoutMiniChrome()
    RelayoutFooter()
    RelayoutSlots()
    RelayoutNowPlaying()
    body:Show()
    body:SetAlpha(0)
    LayoutBodyOffset(8)

    local step = 0
    if C_Timer and C_Timer.NewTicker then
        expandTicker = C_Timer.NewTicker(0.02, function(ticker)
            step = step + 1
            local progress = math.min(1, step / 6)
            LayoutBodyOffset(8 * (1 - progress))
            body:SetAlpha(progress)
            if progress >= 1 then
                ticker:Cancel()
                expandTicker = nil
                LayoutBodyOffset(0)
                body:SetAlpha(1)
            end
        end)
    else
        LayoutBodyOffset(0)
        body:SetAlpha(1)
    end
end

local function BuildFrame()
    if favFrame then return favFrame end

    -- No fill, ever - fully transparent by design, only the title text and
    -- the sound icons are ever visible. The 1px edge is added below purely
    -- as an unlocked-state indicator (see ApplyLock): invisible (alpha 0)
    -- while locked, accent-coloured while unlocked, so you can always tell
    -- at a glance whether the window can currently be moved/resized.
    favFrame = SB.CreateFrame("Frame", "SoundbookFavouritesWindow", UIParent)
    local w = (SB.db.ui.favWidth and SB.db.ui.favWidth > 0) and SB.db.ui.favWidth or DefaultWidth()
    local h = (SB.db.ui.favHeight and SB.db.ui.favHeight > 0) and SB.db.ui.favHeight or DefaultHeight()
    w = math.max(MIN_SIZE, math.min(MAX_SIZE, w))
    h = math.max(MIN_SIZE, math.min(MAX_SIZE, h))
    expandedHeight = h
    favFrame:SetSize(w, h)
    -- Soundbook 2.0 visual pass: root surface now reuses the SAME arcane
    -- background asset the Main Soundbook is built on (Theme.Panel),
    -- instead of a flat near-black fill with no texture at all - explicit
    -- request, "das Mini Soundbook wirkt noch wie ein separates Utility-
    -- Fenster". Darkened MUCH further than Main (0.82 wash, vs. Main's own
    -- 0.32) so it reads as the same material at HUD intensity, never a
    -- second full Main window. Border alpha (0.45) already matches this
    -- window's own internal divider lines below.
    -- 0.55, not 0.82 - the earlier value combined with header/status/grid's
    -- OWN additional overlays (below) stacked into near-total invisibility
    -- ("ich sehe die Textur nicht") - alpha layers compound multiplicatively,
    -- not additively, so several "subtle" darkenings in a row add up fast.
    SB.Theme.MiniArcanePanel(favFrame, 0.55)
    favFrame:SetBackdropBorderColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.45)
    -- HIGH, one tier above the main Soundbook window's own "HIGH" isn't
    -- possible (max is HIGH short of DIALOG), so use DIALOG: the two
    -- windows default to overlapping positions, and without this the main
    -- window (also high-strata) would sit on top and swallow every click
    -- meant for this one wherever they overlap - including the title bar.
    favFrame:SetFrameStrata("DIALOG")
    favFrame:SetClampedToScreen(true)
    favFrame:SetMovable(true)   -- required for StartMoving() to have any effect
    favFrame:SetResizable(true) -- required for StartSizing() to have any effect
    SetMiniResizeBounds(MIN_SIZE)

    -- Idle vs. hover opacity (Settings -> Interface). favFrame's own
    -- OnEnter/OnLeave alone only fires for the gaps NOT covered by a
    -- child (header, slots, grip, ...) - the same "topmost frame under
    -- the cursor" issue as the header buttons below. So every hoverable
    -- child hooks these same two functions too, debounced the same way,
    -- so hovering any sound icon (or anything else in the window) keeps
    -- the hover alpha active instead of only the window's empty edges.
    favFrame:EnableMouse(true)
    local hoverZoneTimer

    local function EnterHoverZone()
        if hoverZoneTimer then
            hoverZoneTimer:Cancel()
            hoverZoneTimer = nil
        end
        isHoveringFavFrame = true
        ExpandMini()
        if not currentPlayingSoundID then SB:ApplyFavAlpha(true) end
    end

    local function LeaveHoverZone()
        if hoverZoneTimer then hoverZoneTimer:Cancel() end
        hoverZoneTimer = C_Timer.NewTimer(0.15, function()
            hoverZoneTimer = nil
            -- Explicit request: while SendMenu.lua's right-click popup has
            -- this window pinned open, a real OnLeave (the popup now
            -- covering the slot/window and stealing hover) must do
            -- NOTHING here - not collapse the body ("der untere Teil fährt
            -- hoch"), not touch alpha, not even flip isHoveringFavFrame -
            -- same reasoning as the draggingFromIndex case just below,
            -- just for a different reason to stay fully expanded.
            if favAlphaPinned then return end
            if draggingFromIndex then
                isHoveringFavFrame = true
                SB:ApplyFavAlpha(true)
                return
            end
            isHoveringFavFrame = false
            CollapseMini()
            if not currentPlayingSoundID then SB:ApplyFavAlpha(false) end
        end)
    end

    favFrame:SetScript("OnEnter", EnterHoverZone)
    favFrame:SetScript("OnLeave", LeaveHoverZone)

    -- Header: title text, draggable strip. Close/Lock only appear on
    -- hover (kept minimal per "just the title and the icons" look); a
    -- right-click anywhere on the strip opens the main Soundbook window.
    -- Mouse stays enabled on it AT ALL TIMES, even while locked, so hover
    -- detection (and therefore Unlock) never gets stuck unreachable.
    -- Soundbook 2.0 visual pass: the header used to be its own fully
    -- bordered box sitting flush against favFrame's own outer border - two
    -- gold rectangles touching read as "generic utility bar", not one
    -- integrated arcane panel. Now it's borderless fill + a single thin
    -- gold divider along the bottom edge only, so the whole Mini Soundbook
    -- reads as ONE frame with quiet internal seams, matching how the
    -- header/body boundary works on the Main Soundbook.
    header = SB.CreateFrame("Frame", nil, favFrame)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    header:SetHeight(HEADER_H)
    -- Lower alpha than before (was 0.5) - lets more of favFrame's own new
    -- arcane texture/wash show through here than in the grid below,
    -- matching "Header darf etwas stärker texturiert sein als der Body".
    header:SetBackdrop({ bgFile = WHITE_TEX })
    header:SetBackdropColor(0.02, 0.07, 0.15, 0.15)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    favFrame.header = header

    -- Soundbook 2.0 final polish: the gem used to just sit ON TOP of one
    -- continuous divider line (read as "glued under the line", per
    -- explicit feedback). Now the line itself is split into two segments
    -- that stop short of the gem on either side, so the gem reads as an
    -- inline clasp/jewel that's actually PART of the line, not a sticker
    -- on it - no overlap between line and gem at all.
    local GEM_GAP = 4 -- px of clear space either side of the gem
    local headerDividerLeft = header:CreateTexture(nil, "ARTWORK")
    headerDividerLeft:SetHeight(1)
    headerDividerLeft:SetPoint("BOTTOMLEFT", 0, 0)
    headerDividerLeft:SetPoint("RIGHT", header, "CENTER", -GEM_GAP, 0)
    headerDividerLeft:SetColorTexture(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.45)
    header.dividerLeft = headerDividerLeft

    local headerDividerRight = header:CreateTexture(nil, "ARTWORK")
    headerDividerRight:SetHeight(1)
    headerDividerRight:SetPoint("BOTTOMRIGHT", 0, 0)
    headerDividerRight:SetPoint("LEFT", header, "CENTER", GEM_GAP, 0)
    headerDividerRight:SetColorTexture(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.45)
    header.dividerRight = headerDividerRight

    -- Small gold crystal accent - the "optional, very small" diamond from
    -- the design brief. True header centre (matches the title above it -
    -- see the later ClearAllPoints/SetPoint once stopBtn/closeBtn exist),
    -- sitting exactly in the gap between the two line segments.
    local headerGem = header:CreateTexture(nil, "ARTWORK", nil, 1)
    headerGem:SetSize(6, 6)
    headerGem:SetPoint("BOTTOM", header, "BOTTOM", 0, -2)
    headerGem:SetTexture(WHITE_TEX)
    headerGem:SetVertexColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.9)
    headerGem:SetRotation(math.pi / 4)
    header.gem = headerGem

    headerText = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    -- Same typeface as the rest of the Mini Soundbook applied immediately
    -- (Font only, GameFontNormalSmall's own size/outline as a placeholder
    -- here) - the REAL size, following both the window's own height and
    -- the Mini Soundbook Text Size slider, is set by RelayoutMiniChrome's
    -- own titleSize once the first real layout pass runs.
    do
        local _, size, flags = headerText:GetFont()
        headerText:SetFont(MiniFontPath(), size or 11, flags or "")
    end
    headerText:SetText("Mini Soundbook")
    -- Explicit request: no more solid gold title (read as "aggressive
    -- yellow") - warm white primary. RefreshMuteCountdown further down
    -- still overrides this to red while muted/gold-ish while idle; its own
    -- idle colour is updated to match (SB.Theme.TEXT) right below.
    headerText:SetTextColor(unpack(SB.Theme.TEXT))
    headerText:SetShadowOffset(1, -1)
    headerText:SetShadowColor(0, 0, 0, 1)

    header:SetScript("OnDragStart", function()
        if SB.db.ui.favLocked then return end
        favFrame:StartMoving()
    end)
    header:SetScript("OnDragStop", function()
        favFrame:StopMovingOrSizing()
        SavePosition()
    end)
    header:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            SB:Fire("TOGGLE_MAIN_UI")
        end
    end)

    -- closeBtn/lockBtn are children of header and visually sit ON TOP of
    -- it, so the moment the cursor moves from the header directly onto
    -- one of them, WoW considers the mouse to have left `header` (the
    -- topmost frame under the cursor is now the child) - firing
    -- header:OnLeave, which hid them, which handed mouse focus straight
    -- back to header, re-firing OnEnter... an infinite show/hide flicker,
    -- and a target that's invisible about half the time is unclickable.
    -- Fix: debounce the hide behind a short timer that any of the three
    -- (header, closeBtn, lockBtn) can cancel by re-entering.
    local headerHideTimer

    local function ShowHeaderButtons()
        if headerHideTimer then
            headerHideTimer:Cancel()
            headerHideTimer = nil
        end
        closeBtn:Show()
        lockBtn:Show()
        muteBtn:Show()
        stopBtn:Show()
    end

    local function ScheduleHideHeaderButtons()
        -- Soundbook keeps all HUD controls visible. The function is
        -- retained because child hover handlers share this path.
        ShowHeaderButtons()
    end

    header:SetScript("OnEnter", function()
        ShowHeaderButtons()
        EnterHoverZone()
    end)
    header:SetScript("OnLeave", function()
        ScheduleHideHeaderButtons()
        LeaveHoverZone()
    end)

    -- Close plus the two left-side state controls share the same chrome.
    -- (Theme.CreateMiniControlButton: same size, fill, border, hover/
    -- pressed states - explicit request, no more isolated bare-text "x"
    -- next to a plain colour dot) - only shown while hovering the strip.
    local MINI_BTN_SIZE = 16

    closeBtn = SB.Theme.CreateCloseGlyph(header, MINI_BTN_SIZE)
    -- NEGATIVE offset here: this must stay INSIDE header's own bounds, or
    -- moving the mouse toward it crosses out of header's hit-rect first,
    -- firing OnLeave (hiding it) before the cursor ever reaches it.
    closeBtn:SetPoint("RIGHT", -4, 0)
    closeBtn:SetScript("OnClick", function() SB:HideFavWindow() end)
    closeBtn:HookScript("OnEnter", function(self)
        ShowHeaderButtons()
        EnterHoverZone()
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Close")
        GameTooltip:Show()
    end)
    closeBtn:HookScript("OnLeave", function()
        ScheduleHideHeaderButtons()
        LeaveHoverZone()
        GameTooltip:Hide()
    end)

    lockBtn = SB.Theme.CreateLockGlyph(header, MINI_BTN_SIZE)
    lockBtn:SetPoint("LEFT", 4, 0)
    lockBtn:SetScript("OnClick", function()
        SB:SetFavWindowLocked(not SB.db.ui.favLocked)
    end)
    lockBtn:HookScript("OnEnter", function(self)
        ShowHeaderButtons()
        EnterHoverZone()
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(SB.db.ui.favLocked and "Unlock (allow moving/resizing)" or "Lock (prevent moving/resizing)")
        GameTooltip:Show()
    end)
    lockBtn:HookScript("OnLeave", function()
        ScheduleHideHeaderButtons()
        LeaveHoverZone()
        GameTooltip:Hide()
    end)

    -- Remote Mute - one click, toggles the same personal receive-mute
    -- Settings' Mute/Unmute button does (SB:StartReceiveMute/StopReceiveMute)
    -- - explicit request: reachable directly from the Mini Soundbook, not
    -- just buried in Settings.
    muteBtn = SB.Theme.CreateMuteGlyph(header, MINI_BTN_SIZE)
    muteBtn:SetPoint("LEFT", lockBtn, "RIGHT", 3, 0)

    -- Explicit request: a Raid Admin block must read as visibly DIFFERENT
    -- from your own personal mute - a small orange "authority" corner dot
    -- (vs. the mute glyph's own red/gold personal-mute colouring) shown
    -- only while SB:IsReceiveBlockedByRaid() - someone ELSE muted you, not
    -- you muting yourself.
    local raidBlockBadge = muteBtn:CreateTexture(nil, "OVERLAY")
    raidBlockBadge:SetSize(6, 6)
    raidBlockBadge:SetPoint("TOPLEFT", -1, 1)
    raidBlockBadge:SetTexture(WHITE_TEX)
    raidBlockBadge:SetVertexColor(1, 0.55, 0.15, 1)
    raidBlockBadge:Hide()
    muteBtn.raidBlockBadge = raidBlockBadge

    local function RefreshMuteBtn()
        local muted = SB.IsReceiveMuted and SB:IsReceiveMuted()
        muteBtn:SetMuted(muted and true or false)
        local raidBlocked = SB.IsReceiveBlockedByRaid and SB:IsReceiveBlockedByRaid()
        raidBlockBadge:SetShown(raidBlocked and true or false)
    end
    muteBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    muteBtn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            -- Individual Mute (MutePlayers.lua) - a completely separate
            -- feature from the left-click's global receive-mute below:
            -- blocks specific PEOPLE, not everyone.
            SB.OpenMutePlayersMenu()
            return
        end
        if SB:IsReceiveMuted() then
            SB:StopReceiveMute()
        else
            -- The red-square action is an immediate hard stop as well as
            -- a receive mute: cut off every sound Soundbook started
            -- (local or remote) and discard everything still waiting in
            -- the incoming spooler before blocking further reception.
            SB:StopAllSounds()
            if SB.ClearPendingQueue then SB:ClearPendingQueue() end
            SB:StartReceiveMute(nil, nil)
        end
    end)
    muteBtn:HookScript("OnEnter", function(self)
        ShowHeaderButtons()
        EnterHoverZone()
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(SB:IsReceiveMuted()
            and "Left Click: Unmute all receiving sounds."
            or "Left Click: Mute all receiving sounds.")
        GameTooltip:AddLine("Right Click: Individual Mute - block specific people.", 0.8, 0.8, 0.8, true)
        if SB.IsReceiveBlockedByRaid and SB:IsReceiveBlockedByRaid() then
            GameTooltip:AddLine("Your Raid Leader has muted receiving right now.", 1, 0.55, 0.15, true)
        end
        GameTooltip:Show()
    end)
    muteBtn:HookScript("OnLeave", function()
        ScheduleHideHeaderButtons()
        LeaveHoverZone()
        GameTooltip:Hide()
    end)
    RefreshMuteBtn()
    SB:On("RECEIVE_MUTE_CHANGED", RefreshMuteBtn)
    SB:On("RAID_OVERRIDE_CHANGED", RefreshMuteBtn)

    stopBtn = SB.Theme.CreateStopGlyph(header, MINI_BTN_SIZE)
    stopBtn:SetPoint("LEFT", muteBtn, "RIGHT", 3, 0)
    stopBtn:SetScript("OnClick", function()
        SB:StopAllSounds()
        if SB.ClearPendingQueue then SB:ClearPendingQueue() end
        HideNowPlaying(false) -- explicit Stop - never fall back to a sound that's itself about to be stopped
    end)
    stopBtn:HookScript("OnEnter", function(self)
        ShowHeaderButtons()
        EnterHoverZone()
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Stop all Soundbook sounds")
        GameTooltip:Show()
    end)
    stopBtn:HookScript("OnLeave", function()
        ScheduleHideHeaderButtons()
        LeaveHoverZone()
        GameTooltip:Hide()
    end)

    -- Explicit request: title (and the gem below it) truly horizontally
    -- centred on the HEADER ITSELF, not on the leftover space between the
    -- two (asymmetric - 3 buttons left, 1 right) button clusters. A plain
    -- CENTER anchor, no LEFT/RIGHT stretch, does that directly - at very
    -- narrow window widths the text can now graze a button, but centring
    -- takes priority per this explicit request.
    headerText:ClearAllPoints()
    headerText:SetPoint("CENTER", header, "CENTER", 0, 0)
    headerText:SetJustifyH("CENTER")
    headerText:SetWordWrap(false)

    -- Gem sits on the header's own true centre too (same X as the title
    -- above) AND straddles the bottom divider line exactly - its own
    -- CENTER anchored right to header's BOTTOM (y=0, where the divider
    -- texture is), not offset above or below it.
    header.gem:ClearAllPoints()
    header.gem:SetPoint("CENTER", header, "BOTTOM", 0, 0)

    body = CreateFrame("Frame", nil, favFrame)
    body:SetPoint("TOPLEFT", favFrame, "TOPLEFT", 0, -(currentHeaderH + currentNowPlayingH))
    body:SetPoint("BOTTOMRIGHT", favFrame, "BOTTOMRIGHT", 0, 0)
    body:EnableMouse(true)
    body:SetScript("OnEnter", EnterHoverZone)
    body:SetScript("OnLeave", LeaveHoverZone)
    favFrame.body = body

    -- Explicit request: the grid stays the CALMEST/darkest zone of the
    -- shared arcane surface - a BACKGROUND-layer wash darkens favFrame's
    -- texture further here specifically, without touching the icon slots
    -- themselves (they're child frames of `body`, so they always render
    -- above this regardless of layer order within body).
    local bodyWash = body:CreateTexture(nil, "BACKGROUND")
    bodyWash:SetAllPoints()
    bodyWash:SetTexture(WHITE_TEX)
    bodyWash:SetVertexColor(0.008, 0.035, 0.08, 0.20)

    -- Footer "name bar": same height/style convention as the header, but
    -- anchored at the bottom. Never mouse-enabled (see comment on
    -- ShowSoundNameBar above) - it's a pure readout, driven by each slot's
    -- own OnEnter/OnLeave further down, so it never affects click-through.
    -- Soundbook 2.0 visual pass: was a fully boxed, near-opaque strip that
    -- read as a separate bar bolted under the grid. Now: no box at all,
    -- just a thin gold divider along the TOP edge (mirrors the header/Now
    -- Playing dividers) and a small flanking-dash treatment around the
    -- text itself ("──── Name ────") instead of a filled background.
    footer = SB.CreateFrame("Frame", nil, body)
    footer:SetPoint("BOTTOMLEFT", 0, 0)
    footer:SetPoint("BOTTOMRIGHT", 0, 0)
    footer:SetHeight(FOOTER_H)
    favFrame.footer = footer

    local footerDivider = footer:CreateTexture(nil, "ARTWORK")
    footerDivider:SetHeight(1)
    footerDivider:SetPoint("TOPLEFT", 0, 0)
    footerDivider:SetPoint("TOPRIGHT", 0, 0)
    footerDivider:SetColorTexture(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.45)
    footer.divider = footerDivider

    footerText = footer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    footerText:SetPoint("CENTER", 0, -1)
    footerText:SetJustifyH("CENTER")
    footerText:SetWordWrap(false)
    footerText:SetTextColor(unpack(SB.Theme.TEXT))
    footerText:SetText("")

    -- The two short flanking dashes either side of the name - purely
    -- decorative, shown/hidden together with the text itself.
    -- Explicit bugfix ("Vierecke statt Striche auf meinem Laptop") - this
    -- used to be the Unicode box-drawing character U+2500 ("─", 3x) rather
    -- than a plain hyphen. GameFontDisableSmall is Blizzard's OWN default
    -- font object, completely untouched by Soundbook's own font settings
    -- (MiniFontPath is deliberately never applied here) - whether that
    -- specific glyph renders depends entirely on the WoW client's own
    -- underlying font file, which can differ between machines/locales even
    -- for the exact same addon and settings, showing up as a tofu box
    -- wherever it's missing. A plain ASCII hyphen is guaranteed to exist
    -- in literally any font, on any machine.
    local footerDashLeft = footer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footerDashLeft:SetPoint("RIGHT", footerText, "LEFT", -6, 0)
    footerDashLeft:SetText("---")
    footerDashLeft:SetTextColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.55)
    footerDashLeft:Hide()
    footer.dashLeft = footerDashLeft

    local footerDashRight = footer:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footerDashRight:SetPoint("LEFT", footerText, "RIGHT", 6, 0)
    footerDashRight:SetText("---")
    footerDashRight:SetTextColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.55)
    footerDashRight:Hide()
    footer.dashRight = footerDashRight
    footerText:Hide()

    -- Resize grip (bottom-right). Only shown while unlocked - made
    -- deliberately hard to miss (flat accent-boxed button, not just a
    -- faint grey Blizzard icon) since it's the only way to resize the
    -- window at all.
    resizeGrip = SB.CreateFrame("Button", nil, body)
    resizeGrip:SetSize(14, 14)
    resizeGrip:SetPoint("BOTTOMRIGHT", -1, 1)
    resizeGrip:SetBackdrop({ bgFile = WHITE_TEX, edgeFile = WHITE_TEX, edgeSize = 1 })
    resizeGrip:SetBackdropColor(SB.Theme.ARCANE_HOVER[1], SB.Theme.ARCANE_HOVER[2], SB.Theme.ARCANE_HOVER[3], 0.16)
    resizeGrip:SetBackdropBorderColor(SB.Theme.ARCANE_HOVER[1], SB.Theme.ARCANE_HOVER[2], SB.Theme.ARCANE_HOVER[3], 0.42)
    local gripTex = resizeGrip:CreateTexture(nil, "OVERLAY")
    gripTex:SetPoint("TOPLEFT", 3, -3)
    gripTex:SetPoint("BOTTOMRIGHT", -3, 3)
    gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    gripTex:SetVertexColor(1, 1, 1, 1)
    resizeGrip:SetScript("OnMouseDown", function()
        if SB.db.ui.favLocked then return end
        isResizing = true
        RefreshSlots()
        favFrame:StartSizing("BOTTOMRIGHT")
    end)
    resizeGrip:SetScript("OnMouseUp", function()
        favFrame:StopMovingOrSizing()
        isResizing = false
        expandedHeight = favFrame:GetHeight()
        SaveSize()
        RelayoutFooter()
        RelayoutSlots()
        RefreshSlots()
        RelayoutNowPlaying()
        if not isHoveringFavFrame then CollapseMini() end
    end)
    resizeGrip:SetScript("OnEnter", function(self)
        EnterHoverZone()
        self:SetBackdropColor(SB.Theme.ARCANE_HOVER[1], SB.Theme.ARCANE_HOVER[2], SB.Theme.ARCANE_HOVER[3], 0.52)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText("Drag to resize")
        GameTooltip:Show()
    end)
    resizeGrip:SetScript("OnLeave", function(self)
        LeaveHoverZone()
        self:SetBackdropColor(SB.Theme.ARCANE_HOVER[1], SB.Theme.ARCANE_HOVER[2], SB.Theme.ARCANE_HOVER[3], 0.16)
        GameTooltip:Hide()
    end)

    favFrame:SetScript("OnSizeChanged", function()
        RelayoutFooter()
        RelayoutMiniChrome()
        RelayoutSlots()
        RelayoutNowPlaying()
    end)

    for i = 1, SLOT_COUNT do
        -- Unscaled positioning anchor - RelayoutSlots (above) moves/resizes
        -- THIS, never the slot itself. See the `holders` declaration for
        -- why (rock-solid hover zoom, immune to a relayout happening
        -- mid-hover).
        local holder = SB.CreateFrame("Frame", nil, body)
        holders[i] = holder

        -- Flat square slot: a plain 1px border (no carved WoW slot art).
        -- Every filled slot here IS a favourite by definition, so its
        -- border is always the accent colour; empty slots show no border
        -- at all (see RefreshSlots) - only real icons are ever visible.
        local slot = SB.Theme.CreateIconSlot(body, nil, SB.Theme.BORDER_DIM, "Button")
        -- The compact HUD deliberately uses a true one-unit resting edge.
        -- Its richer decorative frame is a separate, hover-only outer ring.
        slot:SetBackdrop({
            bgFile = WHITE_TEX,
            edgeFile = WHITE_TEX,
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        -- THE actual bug behind "icons are white-backed": SetBackdrop()
        -- resets the backdrop's fill/border colour to opaque white the
        -- moment it's called again, even though CreateIconSlot already set
        -- the correct dark colours right before this - those calls don't
        -- carry over. Re-applying them here is what was missing.
        slot:SetBackdropColor(SB.Theme.BG_INPUT[1], SB.Theme.BG_INPUT[2], SB.Theme.BG_INPUT[3], 0.82)
        slot:SetBackdropBorderColor(unpack(SB.Theme.BORDER_DIM))
        slot.soundbookSlotIndex = i
        -- Permanent CENTER anchor to its holder, set once and never
        -- touched again - required by Theme.ApplyHoverZoom below (see its
        -- own comment on why CENTER is the precondition for a stable,
        -- truly-centred zoom).
        slot:SetPoint("CENTER", holder, "CENTER", 0, 0)
        -- Explicit request: the decorative IconFrame overlay (Theme.lua's
        -- CreateIconSlot, "ornament") was left in its default always-on
        -- state here, contradicting this very block's own comment above
        -- ("a separate, hover-only outer ring") - its pale tint over every
        -- icon read as "all icons are white-tinted". Hover-only fixes it.
        slot:SetOrnamentMode("hover")

        local highlight = slot:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetTexture(WHITE_TEX)
        -- Explicit request: arcane cyan, not ACCENT's blurple/violet.
        highlight:SetVertexColor(SB.Theme.ARCANE_HOVER[1], SB.Theme.ARCANE_HOVER[2], SB.Theme.ARCANE_HOVER[3], 0.12)
        highlight:SetBlendMode("ADD")

        local statusBadge = slot:CreateTexture(nil, "OVERLAY")
        statusBadge:SetSize(8, 8)
        statusBadge:SetPoint("TOPRIGHT", -2, -2)
        statusBadge:SetTexture(WHITE_TEX)
        statusBadge:SetVertexColor(0.95, 0.22, 0.32, 1)
        statusBadge:Hide()
        slot.statusBadge = statusBadge

        slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        slot:SetScript("OnClick", function(self, button)
            if not self.soundID then return end
            if button == "LeftButton" then
                SB:TriggerSound(self.soundID)
            elseif button == "RightButton" then
                -- "Send to..." menu (SendMenu.lua) - pick a specific
                -- channel or person instead of the default broadcast-
                -- everywhere behaviour a plain left-click uses. Editing a
                -- sound is no longer reachable from the mini window at all -
                -- use the main Soundbook window's own right-click for that.
                -- pinFavWindow=true: this popup opens right on/next to the
                -- Mini Soundbook itself, so keep it fully visible while
                -- open; `self` (this slot) as sourceSlot keeps ITS icon
                -- visibly zoomed the same way, as if still hovered - see
                -- SB.OpenSendMenu's own comment on both.
                SB.OpenSendMenu(self.soundID, true, self)
            end
        end)

        slot:SetScript("OnDragStart", function(self)
            if SB.db.ui.favLocked or not self.soundID then return end
            StartGhostDrag(self.soundbookSlotIndex, SB:GetSoundIcon(self.soundID), self:GetWidth())
        end)
        slot:SetScript("OnDragStop", function(self)
            local dropIndex = FindSlotUnderCursor()
            StopGhostDrag(dropIndex)
        end)

        slot:SetScript("OnEnter", function(self)
            -- Always counts as "hovering the window" for the idle/hover
            -- alpha, even over an empty (invisible) slot - only the name
            -- bar below is conditional on actually having a sound.
            EnterHoverZone()
            if not self.soundID then return end
            local info = SB.registry[self.soundID]
            if not info then return end
            local saved = SB:GetSoundSaved(self.soundID)
            ShowSoundNameBar(SB:GetSoundDisplayName(self.soundID), saved and saved.muted)
        end)
        slot:SetScript("OnLeave", function()
            LeaveHoverZone()
            HideSoundNameBar()
        end)

        -- Soundbook 2.0 visual pass: back down to 15% (was 30%, noticeably
        -- more aggressive than the requested 1.10-1.18x range) - centred,
        -- still allowed to cover neighbours if it needs to. See
        -- Theme.ApplyHoverZoom's own comment. Applied after the functional
        -- handlers above so its HookScript never replaces them.
        SB.Theme.ApplyHoverZoom(slot, 0.15)

        -- The decorative icon filigree is intentionally absent at rest.
        -- Register this after the zoom hook: on entry the slot first moves
        -- above its neighbours, then this outer frame is placed above the
        -- newly raised slot level as well.
        SB.Theme.ApplyOuterIconHover(slot)

        slots[i] = slot
    end

    -- Permanent Now Playing strip. It owns reserved space above the grid,
    -- so playback feedback never hides or replaces favourite slots.
    -- Soundbook 2.0 visual pass: same "one panel, quiet seams" treatment
    -- as the header - borderless fill, one thin gold divider along the
    -- bottom edge instead of a fully boxed strip stacked under the
    -- header's own box.
    nowPlaying = SB.CreateFrame("Frame", nil, favFrame)
    nowPlaying:SetPoint("TOPLEFT", 0, -currentHeaderH)
    nowPlaying:SetPoint("TOPRIGHT", 0, -currentHeaderH)
    nowPlaying:SetHeight(currentNowPlayingH)
    -- Lower alpha than before (was 0.55) - "5-15% dunkler als RootSurface"
    -- (explicit request), not its own much-darker separate block.
    nowPlaying:SetBackdrop({ bgFile = WHITE_TEX })
    nowPlaying:SetBackdropColor(0.015, 0.05, 0.11, 0.15)
    nowPlaying:EnableMouse(true)
    nowPlaying:SetFrameLevel(favFrame:GetFrameLevel() + 10)

    local nowPlayingDivider = nowPlaying:CreateTexture(nil, "ARTWORK")
    nowPlayingDivider:SetHeight(1)
    nowPlayingDivider:SetPoint("BOTTOMLEFT", 0, 0)
    nowPlayingDivider:SetPoint("BOTTOMRIGHT", 0, 0)
    nowPlayingDivider:SetColorTexture(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.45)

    -- Playback progress fill (SoundPlayer.lua's PLAYBACK_PROGRESS_* events)
    -- - "BORDER" draw layer, deliberately BELOW npIcon ("ARTWORK") and
    -- every text ("OVERLAY") so it never covers them; above the plain
    -- background wash underneath (a Backdrop, which always renders below
    -- every draw-layer texture). Left-anchored, width set proportionally
    -- to progress - see SetProgressFill. Hidden by default; only ever
    -- shown while a sound with a KNOWN duration is actively playing - see
    -- SyncProgressVisibility ("keine erfundene Prozentanzeige").
    npProgressFill = nowPlaying:CreateTexture(nil, "BORDER")
    npProgressFill:SetPoint("TOPLEFT", nowPlaying, "TOPLEFT", 1, -1)
    npProgressFill:SetPoint("BOTTOMLEFT", nowPlaying, "BOTTOMLEFT", 1, 1)
    npProgressFill:SetWidth(0.01)
    -- Toned down (0.12) - the gold beam below carries the actual "where
    -- are we" indication, this is just a quiet trailing wash.
    npProgressFill:SetColorTexture(SB.Theme.ARCANE_HOVER[1], SB.Theme.ARCANE_HOVER[2], SB.Theme.ARCANE_HOVER[3], 0.12)
    npProgressFill:Hide()

    -- The actual moving indicator - a thin bright gold vertical beam that
    -- tracks the current progress position (explicit request). Same
    -- BORDER layer as the fill (below icon/text), positioned each update
    -- in SetProgressFill.
    npProgressBeam = nowPlaying:CreateTexture(nil, "BORDER", nil, 1)
    npProgressBeam:SetPoint("TOP", nowPlaying, "TOPLEFT", 1, -1)
    npProgressBeam:SetPoint("BOTTOM", nowPlaying, "BOTTOMLEFT", 1, 1)
    npProgressBeam:SetWidth(2)
    npProgressBeam:SetBlendMode("ADD")
    npProgressBeam:SetColorTexture(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.9)
    npProgressBeam:Hide()

    npIcon = nowPlaying:CreateTexture(nil, "ARTWORK")
    npIcon:SetTexCoord(0.06, 0.94, 0.06, 0.94)

    -- Font template given at creation (not just via SetFont later in
    -- RelayoutNowPlaying) - a FontString with no font ever set at all
    -- errors on the very first SetText() call. One line now (sender,
    -- channel, and sound name all combined - see ShowNowPlaying), not two.
    npLine1 = nowPlaying:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    npLine1:SetPoint("TOPLEFT", 29, -3)
    npLine1:SetPoint("TOPRIGHT", -48, -3)
    npLine1:SetTextColor(1, 1, 1)
    npLine1:SetJustifyH("LEFT")
    npLine1:SetWordWrap(false)
    npLine1:SetText("Ready")
    npLine1:SetTextColor(unpack(SB.Theme.TEXT))

    npLine2 = nowPlaying:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    npLine2:SetPoint("BOTTOMLEFT", 29, 3)
    npLine2:SetPoint("BOTTOMRIGHT", -48, 3)
    npLine2:SetJustifyH("LEFT")
    npLine2:SetWordWrap(false)
    npLine2:SetText("No sound playing")
    npLine2:SetTextColor(unpack(SB.Theme.TEXT_DIM))

    -- Explicit request: channel back as its own column, far right,
    -- vertically centred across the whole strip, bigger font, full
    -- channel colour - see RelayoutNowPlaying for sizing/position.
    npChannel = nowPlaying:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    npChannel:SetPoint("RIGHT", -8, 0)
    npChannel:SetJustifyH("RIGHT")
    npChannel:SetWordWrap(false)
    npChannel:SetText("")

    nowPlaying:Show()
    nowPlaying:SetScript("OnEnter", function()
        EnterHoverZone()
    end)
    nowPlaying:SetScript("OnLeave", function()
        LeaveHoverZone()
    end)

    RestorePosition()
    ApplyLock()
    RelayoutFooter()
    RelayoutMiniChrome()
    RelayoutSlots()
    RelayoutNowPlaying()
    SB:ApplyFavAlpha(false) -- start in the idle state (not hovering)
    CollapseMini()

    return favFrame
end

-- percent is 0-100. hovering=true applies (and remembers) the hover
-- alpha, false applies the idle one - used both by the live OnEnter/OnLeave
-- above and by Settings while the user is editing the values.
-- THE actual bug behind "the window doesn't stay open/visible while the
-- Send-to popup is open": ApplyFavAlpha used to have no idea a pin was in
-- effect, so the very next call to it - e.g. LeaveHoverZone firing the
-- instant the mouse leaves the clicked slot to hover the popup, which
-- calls ApplyFavAlpha(isHoveringFavFrame) - silently overwrote
-- PinFavAlpha's alpha=1 right back down to the idle alpha, often within
-- the very same click. `favAlphaPinned` (declared at the top of the file,
-- set by PinFavAlpha below) is now checked here too, so nothing can undo
-- the pin except PinFavAlpha(false) itself.

function SB:ApplyFavAlpha(hovering)
    if not favFrame or favAlphaPinned then return end
    local pct = hovering and SB.db.ui.favAlphaHover or SB.db.ui.favAlphaIdle
    pct = tonumber(pct) or 100
    pct = math.max(0, math.min(100, pct))
    favFrame:SetAlpha(pct / 100)
end

function SB:RefreshFavAlpha()
    if not favFrame or favAlphaPinned then return end
    if currentPlayingSoundID then
        favFrame:SetAlpha(1)
    else
        SB:ApplyFavAlpha(isHoveringFavFrame)
    end
end

-- Forces the Mini Soundbook fully visible while something else needs it to
-- stay put and readable - currently just SendMenu.lua's right-click menu.
-- Without this, the moment that menu opens (a separate, higher-strata
-- frame right on top of the slot you clicked), the cursor is no longer
-- "hovering" favFrame as far as WoW's hit-testing is concerned - it hands
-- OnEnter/OnLeave to whichever frame is topmost, which is now the menu -
-- so favFrame immediately dropped to idle alpha, which if set low made the
-- whole window appear to vanish right as the menu opened. `pinned=false`
-- restores whatever alpha actually applies right now (hover or idle).
function SB:PinFavAlpha(pinned)
    if not favFrame then return end
    favAlphaPinned = pinned and true or false
    if pinned then
        favFrame:SetAlpha(1)
    else
        -- Explicit request: re-check the REAL current mouse position
        -- instead of trusting isHoveringFavFrame, which was frozen the
        -- moment this got pinned and never updated while pinned (see
        -- LeaveHoverZone's own early-return) - so it could easily be
        -- stale by the time the popup closes. Clicking away to close the
        -- popup, or clicking a target inside it, both end with the mouse
        -- somewhere real - firing favFrame's actual OnEnter/OnLeave
        -- handler for wherever that really is settles both alpha AND the
        -- expand/collapse state (CollapseMini/ExpandMini) correctly,
        -- instead of always collapsing regardless of where the mouse
        -- actually ended up.
        local reallyHovering = favFrame.IsMouseOver and favFrame:IsMouseOver()
        local handler = favFrame:GetScript(reallyHovering and "OnEnter" or "OnLeave")
        if handler then
            handler(favFrame)
        else
            SB:ApplyFavAlpha(isHoveringFavFrame)
        end
    end
end

-- Called from Settings whenever Mini Soundbook Font or Text Size changes,
-- so an already open window picks up the change immediately instead of
-- only on next resize/Now-Playing. Text Size affects the Ready/Now Playing
-- strip and hover name bar; the title keeps its own fixed size and only its
-- typeface changes.
function SB:RefreshFavFont()
    if not favFrame then return end
    local _, size, flags = headerText:GetFont()
    headerText:SetFont(MiniFontPath(), size, flags or "")
    RelayoutMiniChrome()
    RelayoutFooter()
    RelayoutSlots()
    RelayoutNowPlaying()
    if not isExpanded then
        SetMiniHeightKeepingTop(currentHeaderH + currentNowPlayingH + 2)
    end
end

function SB:ShowFavWindow()
    BuildFrame()
    HideNowPlaying(false) -- in case it was showing then got hidden mid-timer; start clean, no promotion
    RefreshSlots()
    CollapseMini()
    favFrame:Show()
    StartLastPlayedTicker()
    SB.db.ui.favShown = true
    if SB.SyncMuteCountdownTicker then SB.SyncMuteCountdownTicker() end
end

function SB:HideFavWindow()
    if favFrame then
        CollapseMini()
        favFrame:Hide()
    end
    StopLastPlayedTicker()
    if SB.StopMuteCountdownTicker then SB.StopMuteCountdownTicker() end
    SB.db.ui.favShown = false
end

function SB:ToggleFavWindow()
    if favFrame and favFrame:IsShown() then
        SB:HideFavWindow()
    else
        SB:ShowFavWindow()
    end
end

function SB:SetFavWindowLocked(locked)
    SB.db.ui.favLocked = locked and true or false
    if favFrame then
        ApplyLock()
        RefreshSlots()
    end
end

SB:On("FAVOURITES_CHANGED", function()
    if favFrame then RefreshSlots() end
end)

SB:On("SOUND_DISPLAY_CHANGED", function()
    if favFrame then RefreshSlots() end
end)

SB:On("TOGGLE_FAV_UI", function()
    SB:ToggleFavWindow()
end)

-- Fired only when a remote sound actually played (i.e. we have it and it
-- isn't muted - see Communication.lua) - shows who played what, over which
-- channel in the permanent status strip for a few seconds.
SB:On("REMOTE_SOUND_PLAYED", function(soundID, sender, channelLabel)
    if favFrame then ShowNowPlaying(soundID, sender, channelLabel, true) end
end)

-- Explicit request: a locally-triggered sound that's also being SENT
-- somewhere shows its real destination (e.g. "Guild") in the live strip
-- while playing - not always "SELF" regardless of what it's actually
-- sent to. `target` is the same resolved output-target value
-- SB:DispatchDefaultOutput itself sends with (see SoundPlayer.lua's
-- SB:TriggerSound). "ALL" (broadcasts to every checked channel at once)
-- used to fall back to "Self" here too, same as a genuinely local-only
-- play - misleading, since a real broadcast attempt WAS made, it just
-- looked identical to nothing being sent at all. Now shown as its own
-- "All" label instead (falls back to a neutral colour - see
-- SB.GetChannelColor - since there's no single channel colour for it).
local LOCAL_TARGET_LABEL = {
    GUILD = "Guild", PARTY = "Party", RAID = "Raid", FRIENDS = "Friends", ALL = "All",
}
local function LocalTargetToChannelLabel(target)
    if not target or target == "SELF" then return nil end
    if type(target) == "string" and target:match("^PLAYER:") then return "Direct" end
    return LOCAL_TARGET_LABEL[target]
end

-- Fired for every locally-triggered sound (click, macro, slash command -
-- see SoundPlayer.lua). Same display as a received sound, just your own
-- name and (per LocalTargetToChannelLabel above) whatever it's being sent
-- to, if anything - EXCEPT a Direct send, explicit request: shows the
-- RECIPIENT's name here instead of your own (which you already know,
-- since you're the one looking at this) - "im besten Fall sehe ich den
-- Spielernamen dem ich den Sound geschickt habe". The channel badge
-- itself still just says "Direct" (keeps its own purple colour-coding,
-- SB.CHANNEL_COLOR - a specific player name wouldn't match anything
-- there and would fall back to a generic colour).
SB:On("LOCAL_SOUND_PLAYED", function(soundID, target)
    if not favFrame then return end
    local recipientName = type(target) == "string" and target:match("^PLAYER:(.+)$")
    ShowNowPlaying(soundID, recipientName or UnitName("player"), LocalTargetToChannelLabel(target))
end)

-- Every explicit stop path (Mini Soundbook action, /sb stop, or another
-- addon calling the public API) immediately restores the normal icon
-- grid. allowPromote=false: SB:StopAllSounds() stops EVERY tracked
-- handle, primary and secondary alike - the secondary ones just haven't
-- been released yet at this exact synchronous instant (that happens on
-- the next poll tick), so without this a Stop could otherwise "promote" a
-- sound that's itself a moment away from being stopped too.
SB:On("PLAYBACK_STOPPED", function()
    if favFrame then HideNowPlaying(false) end
end)

-- Progress fill wiring (SoundPlayer.lua) - see the top-of-file comment on
-- progressSoundID/progressDuration and SyncProgressVisibility for why
-- STARTED doesn't gate on currentPlayingSoundID directly.
-- Bookkeeping ONLY - deliberately does NOT touch the fill/OnUpdate here.
-- This fires from inside SB:PlaySound, strictly BEFORE
-- SB:TriggerSound/HandleIncomingPlay goes on to fire LOCAL_SOUND_PLAYED/
-- REMOTE_SOUND_PLAYED (which is what actually calls ShowNowPlaying and,
-- through it, SyncProgressVisibility) - so currentPlayingSoundID here is
-- still whatever the PREVIOUS display was, not this new sound. Acting on
-- it here caused exactly the "freezes on a second sound" bug: see
-- SyncProgressVisibility's own comment for the full explanation.
SB:On("PLAYBACK_PROGRESS_STARTED", function(state)
    if not state then return end
    progressSoundID = state.soundID
    progressDuration = state.duration
    progressHandle = state.handle
end)

SB:On("PLAYBACK_PROGRESS_UPDATE", function(state)
    if not state or not state.progress then return end
    if state.isPrimary then
        -- Gated on the specific HANDLE, not just soundID - two
        -- overlapping plays of the SAME sound would otherwise "match"
        -- each other's events, see progressHandle's own comment further up.
        if state.handle ~= progressHandle or state.soundID ~= currentPlayingSoundID then return end
        if not progressDuration or progressDuration <= 0 then return end
        -- Periodic cross-check against SoundPlayer.lua's own authoritative
        -- elapsed value - both sides use the same call-time basis now, so
        -- this is normally a no-op, not a correction (see ProgressOnUpdate).
        progressAnchorTime = GetTime() - state.elapsed
    else
        -- No longer (or never was) the primary sound - a demoted "still
        -- playing in the background" bar. SoundPlayer.lua's own
        -- primaryHandle has already moved on by the time this arrives, so
        -- there's no risk of this fighting the current primary bar.
        UpdateSecondary(state)
    end
end)

SB:On("PLAYBACK_PROGRESS_ENDED", function(state)
    if not state then return end
    SB:Debug("PLAYBACK_PROGRESS_ENDED: handle=%s soundID=%s isPrimaryMatch=%s (progressHandle=%s currentPlayingSoundID=%s)",
        tostring(state.handle), tostring(state.soundID),
        tostring(state.handle == progressHandle and state.soundID == currentPlayingSoundID),
        tostring(progressHandle), tostring(currentPlayingSoundID))
    if state.handle == progressHandle and state.soundID == currentPlayingSoundID then
        -- Explicit requirement: reliably reach 100% at the natural end
        -- before whatever happens next (the existing Announcement
        -- Duration timer, or an immediate HideNowPlaying) takes over.
        if state.duration and state.duration > 0 then
            SetProgressFill(1)
        end
        progressAnchorTime = nil
        RefreshOnUpdateAttachment()
        -- Never got demoted to a secondary indicator in its lifetime -
        -- ReleaseSecondary's own cleanup (below, for the demoted case)
        -- never ran for it, so clear this directly instead.
        handleInfo[state.handle] = nil
    else
        ReleaseSecondary(state.handle)
    end
end)

SB:On("PLAYER_LOGIN", function()
    if SB.db.ui.favShown then
        SB:ShowFavWindow()
    end
end)

------------------------------------------------------------------------
-- Raid-admin mute countdown - explicit request: "der Timer läuft dann
-- runter, 30 min.. 29 min... etc." Only the two timed durations (30/60 min,
-- see Communication.lua's ApplyRaidOverride) have a real expiresAt to count
-- down - "Next Fight"/"Until raid ends" are event-based, not time-based, so
-- there's nothing to tick for those (the one-time chat notice already
-- covers them). Reuses the existing title text itself rather than adding a
-- new element - the header is only 16px tall to begin with, no room to
-- spare for a second line, and "replace the title while it matters" reads
-- clearly enough on its own.
------------------------------------------------------------------------

local muteCountdownTicker

local function FormatCountdown(seconds)
    seconds = math.max(0, math.floor(seconds))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Only the two USER-FACING timed durations (30/60 min) get a live
-- countdown here - "Next Fight"/"Next Boss" also carry an expiresAt now
-- (Communication.lua's 90-minute safety-net backstop for when the real
-- trigger event never fires), but showing THAT as a ticking countdown
-- would wrongly suggest a fixed timer instead of "clears whenever the
-- fight/boss actually ends, usually much sooner".
local COUNTDOWN_DURATION_CODES = { ["30"] = true, ["60"] = true }

-- Explicit request: unified "Soundbook [muted: mm:ss]" title format for
-- EVERY way you can end up not receiving sounds right now - raid-admin
-- muted (SB.raidOverride, Communication.lua) or a personal receive-mute
-- from Settings (SB:IsReceiveMuted(), same file's SB:StartReceiveMute) -
-- indefinite mutes (no expiry to count down) show "[muted]" with no time.
-- Raid-admin takes visual priority if somehow both are active at once - the
-- more time-critical/less-in-your-own-control of the two.
local function RefreshMuteCountdown()
    if not headerText then return end

    local ov = SB.raidOverride
    if ov and ov.expiresAt and COUNTDOWN_DURATION_CODES[ov.durationCode] then
        local remaining = ov.expiresAt - GetTime()
        if remaining > 0 then
            headerText:SetText("Mini Soundbook [muted: " .. FormatCountdown(remaining) .. "]")
            headerText:SetTextColor(1, 0.35, 0.35)
            return
        end
    end

    if SB:IsReceiveMuted() then
        local remaining = SB:GetReceiveMuteRemaining()
        if remaining then
            headerText:SetText("Mini Soundbook [muted: " .. FormatCountdown(remaining) .. "]")
        else
            headerText:SetText("Mini Soundbook [muted]")
        end
        headerText:SetTextColor(1, 0.35, 0.35)
        return
    end

    headerText:SetText("Mini Soundbook")
    -- Soundbook 2.0 visual pass: matches the title's own new idle colour
    -- (warm white, not solid gold - see its creation in BuildFrame).
    headerText:SetTextColor(unpack(SB.Theme.TEXT))
end

-- Whether either mute source currently has a live countdown worth ticking
-- for - an indefinite mute (raid "R"/"F"/"B", or the plain personal Mute
-- button) has nothing to count down, so no ticker is needed for those; the
-- title still updates once immediately via RefreshMuteCountdown itself.
local function HasLiveCountdown()
    local ov = SB.raidOverride
    if ov and ov.expiresAt and COUNTDOWN_DURATION_CODES[ov.durationCode] and (ov.expiresAt - GetTime()) > 0 then
        return true
    end
    return SB:IsReceiveMuted() and SB:GetReceiveMuteRemaining() ~= nil
end

local function StopMuteCountdownTicker()
    if muteCountdownTicker then
        muteCountdownTicker:Cancel()
        muteCountdownTicker = nil
    end
end

-- Fired by Communication.lua on every apply/clear/expiry of either mute
-- source - (re)starts a 1-second ticker only while there's an actual
-- countdown to show, cancelled the moment there isn't, so this never runs
-- as a permanent background poll.
local function SyncMuteCountdownTicker()
    RefreshMuteCountdown()
    StopMuteCountdownTicker()
    if favFrame and favFrame:IsShown() and HasLiveCountdown() then
        muteCountdownTicker = C_Timer.NewTicker(1, RefreshMuteCountdown)
    end
end

SB:On("RAID_OVERRIDE_CHANGED", SyncMuteCountdownTicker)
SB:On("RECEIVE_MUTE_CHANGED", SyncMuteCountdownTicker)

-- Exposed on SB (not just a local) so SB:ShowFavWindow above - defined
-- EARLIER in this file, before this local function exists - can still
-- reach it via a plain table lookup at call time, same late-binding
-- pattern SoundPlayer.lua already uses for SB.DispatchDefaultOutput.
-- Needed so a mute already active/resumed from a previous session (see
-- Communication.lua's DB_READY resolve-on-load) shows correctly the moment
-- this window first appears, not just on the next state CHANGE after that.
SB.SyncMuteCountdownTicker = SyncMuteCountdownTicker
SB.StopMuteCountdownTicker = StopMuteCountdownTicker
