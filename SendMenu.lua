-- SendMenu.lua
-- Right-click context menu on a Mini Soundbook favourite slot: pick exactly
-- who a sound goes to - a whole channel (Guild/Raid/Party/Friends) or one
-- specific person confirmed to have Soundbook (SB.db.knownUsers, built by
-- Communication.lua's lightweight HELLO/HELLOACK presence pings, see
-- there). Editing a sound (name/icon/mute) is no longer reachable from
-- here - use the main Soundbook window's own right-click for that.

local ADDON_NAME, SB = ...

local ROW_H = 24
local INDENT = 20
local WIDTH = 260
local TITLE_H = 34
-- Explicit request: ~50% taller (was 12) so fewer people need to scroll to
-- see their whole reachable-players list - width (WIDTH above) stays
-- untouched.
local MAX_VISIBLE_ROWS = 18

local menu, catcher
local rows = {}
local menuItems = {}
local menuOffset = 0
local RenderMenu

-- One row per group: header label, member list, and what a click on the
-- header itself does. Explicit request (reversed, again, from an earlier
-- "only if reachable" version): every group ALWAYS shows here, regardless
-- of whether you're currently in it or anyone reachable is in it - "egal
-- ob die Personen/Spieler drin sind oder nicht". A whole-channel send that
-- goes nowhere right now (e.g. picking Raid while solo) simply reaches
-- nobody when actually clicked - the option itself is always offered.
-- Member lists come from SB.ComputeReachablePlayers (Communication.lua) -
-- THE single canonical reachable-players computation, shared with the main
-- Default Output Channel dropdown so both always agree on who's reachable
-- (explicit requirement) - already deduplicated by the fixed Friends >
-- Guild > Raid > Party priority and safe against same-display-name/
-- different-realm ambiguity (see its own comment). The on-screen HEADER
-- order below (Guild, Raid, Party, Friends) is unrelated to that priority
-- and unchanged.
local function BuildGroups(soundID)
    local reachable = SB.ComputeReachablePlayers()
    local guildMembers, raidMembers, friendMembers = reachable.GUILD, reachable.RAID, reachable.FRIENDS
    -- `key` matches SB.CHANNEL_COLOR's own keys (Core.lua) - explicit
    -- request: colour-code each group header the same way as everywhere
    -- else (Settings, the Default Output Channel dropdown, Now Playing).
    -- Explicit request: the label itself carries a "(N)" count of how many
    -- Soundbook-reachable players actually fall under it right now, same
    -- as SB.ComputeOutputTargetOptions (Communication.lua).
    --
    -- Raid and Party are ONE merged group row (see SB.ResolveGroupChannel/
    -- SB.ComputeReachablePlayers, Communication.lua) - labelled "Raid"
    -- while actually in a raid, "Party" while in a non-raid group, "Raid"
    -- as the default label while in neither; sendAll resolves to whichever
    -- is actually live at the moment it's clicked.
    local groupLabel = IsInRaid() and "Raid" or (IsInGroup() and "Party") or "Raid"
    return {
        {
            label = "Guild (" .. #guildMembers .. ")", key = "GUILD", available = true, members = guildMembers,
            sendAll = function() SB:SendSoundToChannel(soundID, "GUILD") end,
        },
        {
            label = groupLabel .. " (" .. #raidMembers .. ")", key = "RAID", available = true, members = raidMembers,
            sendAll = function() SB:SendSoundToChannel(soundID, "RAID") end,
        },
        {
            label = "Friends (" .. #friendMembers .. ")", key = "FRIENDS", available = true, members = friendMembers,
            sendAll = function() SB:SendSoundToAllFriends(soundID) end,
        },
    }
end

------------------------------------------------------------------------
-- Popup UI - a single flat panel (Theme.Panel), same "click anywhere else
-- to dismiss" catcher trick Theme.CreateDropdown already uses. Built once,
-- rows rebuilt fresh each open.
------------------------------------------------------------------------

-- The slot whose hover-zoom is currently pinned open (see OpenSendMenu's
-- `sourceSlot`) - tracked here so CloseMenu can always un-pin the right
-- one, however the menu ends up closing (a click elsewhere, a send,
-- Escape, or a second OpenSendMenu call reusing the same popup).
local pinnedZoomSlot

local function CloseMenu()
    if menu then menu:Hide() end
    if catcher then catcher:Hide() end
    SB:PinFavAlpha(false)
    if pinnedZoomSlot and pinnedZoomSlot.SetHoverZoomPinned then
        pinnedZoomSlot:SetHoverZoomPinned(false)
    end
    pinnedZoomSlot = nil
end

-- Exposed so Announcer.lua's single-active-transient-surface rule (Mini
-- Soundbook regression fix) can close this menu when Quick Options opens
-- ("Context menu -> Quick Options: close context menu first"), and check
-- whether it's currently open without duplicating this module's own
-- `menu`/`catcher` state.
SB.CloseSendMenu = CloseMenu
function SB.IsSendMenuOpen()
    return menu ~= nil and menu:IsShown()
end

local function ClearRows()
    for _, row in ipairs(rows) do
        row:Hide()
        row:ClearAllPoints()
    end
end

-- `indent` shifts the label right (group headers stay flush left, member
-- rows sit indented under their header) - the row itself always spans the
-- full width so its hover highlight reads as one clean strip either way.
-- `versionSuffix` (member rows only) - "v1.9.1"/"v?" shown right-aligned in
-- the same row, one size down - see SB:GetFormattedPlayerVersion
-- (Communication.lua): only while Settings -> Debug Mode is on. Explicit
-- request: coloured green when `versionIsCurrent` (matches this client's
-- own version) or orange otherwise (older/different/unknown) - shown for
-- every known player now, not just ones on a different version.
local VERSION_CURRENT_COLOR = { 0.4, 0.95, 0.5 }
local VERSION_OTHER_COLOR = { 1, 0.6, 0 }

local function AcquireRow(index, text, indent, isHeader, onClick, versionSuffix, channelKey, versionIsCurrent)
    local row = rows[index]
    if not row then
        row = SB.CreateFrame("Button", nil, menu)
        row:SetHeight(ROW_H)

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        -- Explicit request: arcane cyan, not ACCENT's blurple/violet - a
        -- clear hover wash confirms the current send target without
        -- adding another outline or divider to the compact popup.
        hl:SetColorTexture(SB.Theme.ARCANE_HOVER[1], SB.Theme.ARCANE_HOVER[2], SB.Theme.ARCANE_HOVER[3], 0.4)

        local label = row:CreateFontString(nil, "OVERLAY")
        label:SetPoint("RIGHT", -8, 0)
        label:SetJustifyH("LEFT")
        row.label = label

        local suffix = row:CreateFontString(nil, "OVERLAY")
        suffix:SetFontObject(SB.Fonts.DisableSmall)
        suffix:SetPoint("RIGHT", -8, 0)
        suffix:SetWidth(46)
        suffix:SetJustifyH("RIGHT")
        row.suffix = suffix

        rows[index] = row
    end

    row.label:SetFontObject(isHeader and SB.Fonts.Highlight or SB.Fonts.HighlightSmall)
    row:SetHeight(ROW_H)
    row.label:ClearAllPoints()
    row.label:SetPoint("LEFT", indent, 0)
    row.label:SetPoint("RIGHT", versionSuffix and -58 or -8, 0)
    row.label:SetText(text)
    -- Explicit request: BOTH header AND member rows colour-coded per
    -- channel (Core.lua's SB.CHANNEL_COLOR) - a member row uses the SAME
    -- channelKey as its own group header above it, so a player under
    -- "Guild" reads the same pastel green the "Guild" header itself does.
    -- The version match/mismatch colour (green/orange, Debug Mode only)
    -- stays on the small suffix label only, never the name itself - see
    -- below.
    local channelColor = channelKey and SB.CHANNEL_COLOR[channelKey]
    local color = channelColor and { channelColor.r, channelColor.g, channelColor.b }
        or (isHeader and SB.Theme.TEXT or SB.Theme.TEXT_DIM)
    row.label:SetTextColor(unpack(color))
    row.suffix:SetShown(versionSuffix and true or false)
    if versionSuffix then
        row.suffix:SetText(versionSuffix)
        row.suffix:SetTextColor(unpack(versionIsCurrent and VERSION_CURRENT_COLOR or VERSION_OTHER_COLOR))
    end

    row:SetScript("OnEnter", function() row.label:SetTextColor(1, 1, 1) end)
    row:SetScript("OnLeave", function() row.label:SetTextColor(unpack(color)) end)
    row:SetScript("OnClick", function()
        CloseMenu()
        if onClick then onClick() end
    end)

    row:Show()
    return row
end

local function EnsureMenu()
    if menu then return end

    catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("TOOLTIP")
    catcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    catcher:Hide()
    catcher:SetScript("OnClick", CloseMenu)

    menu = SB.CreateFrame("Frame", nil, UIParent)
    menu:SetFrameStrata("TOOLTIP")
    menu:SetFrameLevel(catcher:GetFrameLevel() + 1)
    menu:SetClampedToScreen(true)
    menu:EnableMouseWheel(true)
    menu:SetScript("OnMouseWheel", function(_, delta)
        local maxOffset = math.max(0, #menuItems - MAX_VISIBLE_ROWS)
        menuOffset = math.max(0, math.min(maxOffset, menuOffset - delta * 3))
        if RenderMenu then RenderMenu() end
    end)
    menu:Hide()
    SB.Theme.CleanPanel(menu, 1)

    -- Title strip: which sound this menu is about, so it's still readable
    -- once the Mini Soundbook's own name bar/tooltip is inevitably covered
    -- by this very popup - a small icon + the sound's display name, never
    -- clickable, just a readout, with a thin divider under it.
    menu.titleIcon = SB.Theme.CreateIconSlot(menu, 20, SB.Theme.GOLD)
    menu.titleIcon:SetPoint("TOPLEFT", 8, -7)
    menu.titleIcon.ornament:SetAlpha(0)
    menu.titleIcon:SetVisualState("normal", true, false)

    menu.titleText = menu:CreateFontString(nil, "OVERLAY")
    menu.titleText:SetFontObject(SB.Fonts.Highlight)
    menu.titleText:SetPoint("LEFT", menu.titleIcon, "RIGHT", 8, 0)
    menu.titleText:SetPoint("RIGHT", -10, 0)
    menu.titleText:SetJustifyH("LEFT")
    menu.titleText:SetWordWrap(false)
    menu.titleText:SetTextColor(1, 1, 1)

    menu.titleDivider = menu:CreateTexture(nil, "ARTWORK")
    menu.titleDivider:SetHeight(1)
    menu.titleDivider:SetPoint("TOPLEFT", 7, -TITLE_H)
    menu.titleDivider:SetPoint("TOPRIGHT", -7, -TITLE_H)
    menu.titleDivider:SetColorTexture(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.42)

    menu.scrollTrack = menu:CreateTexture(nil, "BORDER")
    menu.scrollTrack:SetWidth(3)
    menu.scrollTrack:SetPoint("TOPRIGHT", -3, -TITLE_H - 4)
    menu.scrollTrack:SetPoint("BOTTOMRIGHT", -3, 4)
    menu.scrollTrack:SetTexture("Interface\\Buttons\\WHITE8X8")
    menu.scrollTrack:SetVertexColor(1, 1, 1, 0.10)
    menu.scrollTrack:Hide()

    menu.scrollThumb = menu:CreateTexture(nil, "OVERLAY")
    menu.scrollThumb:SetWidth(3)
    menu.scrollThumb:SetTexture("Interface\\Buttons\\WHITE8X8")
    menu.scrollThumb:SetVertexColor(unpack(SB.Theme.GOLD))
    menu.scrollThumb:Hide()
end

-- Warm gold keeps the selected sound distinct without reintroducing the
-- purple state colour removed from the rest of the interface.
local SEND_NAME_COLOR = "|cffffcc66"

RenderMenu = function()
    local scale = math.max(0.85, math.min(1.30,
        (SB.db and SB.db.settings and SB.db.settings.mainFontScale) or 1))
    ROW_H = math.floor(24 * scale + 0.5)
    TITLE_H = math.floor(34 * scale + 0.5)

    menu.titleIcon:ClearAllPoints()
    menu.titleIcon:SetSize(math.max(20, TITLE_H - 14), math.max(20, TITLE_H - 14))
    menu.titleIcon:SetPoint("LEFT", menu, "TOPLEFT", 8, -TITLE_H / 2)
    menu.titleDivider:ClearAllPoints()
    menu.titleDivider:SetPoint("TOPLEFT", 7, -TITLE_H)
    menu.titleDivider:SetPoint("TOPRIGHT", -7, -TITLE_H)
    menu.scrollTrack:ClearAllPoints()
    menu.scrollTrack:SetPoint("TOPRIGHT", -4, -TITLE_H - 5)
    menu.scrollTrack:SetPoint("BOTTOMRIGHT", -4, 5)

    ClearRows()
    local visibleCount = math.min(MAX_VISIBLE_ROWS, #menuItems - menuOffset)
    local y = -TITLE_H - 5
    for i = 1, visibleCount do
        local item = menuItems[menuOffset + i]
        local row = AcquireRow(i, item.text, item.indent, item.isHeader,
            item.onClick, item.versionSuffix, item.channelKey, item.versionIsCurrent)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 7, y)
        row:SetPoint("RIGHT", -7, 0)
        y = y - ROW_H
    end
    for i = visibleCount + 1, #rows do rows[i]:Hide() end
    menu:SetWidth(WIDTH)
    menu:SetHeight(TITLE_H + 10 + math.max(1, visibleCount) * ROW_H)
    if #menuItems > MAX_VISIBLE_ROWS then
        local trackH = MAX_VISIBLE_ROWS * ROW_H - 8
        local thumbH = math.max(24, trackH * (MAX_VISIBLE_ROWS / #menuItems))
        local maxOffset = #menuItems - MAX_VISIBLE_ROWS
        local thumbY = (trackH - thumbH) * (menuOffset / maxOffset)
        menu.scrollTrack:Show()
        menu.scrollThumb:ClearAllPoints()
        menu.scrollThumb:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -3, -TITLE_H - 4 - thumbY)
        menu.scrollThumb:SetHeight(thumbH)
        menu.scrollThumb:Show()
    else
        menu.scrollTrack:Hide()
        menu.scrollThumb:Hide()
    end
end

local function BuildMenu(soundID)
    wipe(menuItems)
    menuOffset = 0
    menu.titleIcon.texture:SetTexture(SB:GetSoundIcon(soundID))
    menu.titleText:SetText(("Send '%s%s|r' to:"):format(SEND_NAME_COLOR, SB:GetSoundDisplayName(soundID)))
    local groups = BuildGroups(soundID)

    -- Explicit request: a quick "just use my Settings -> Sound Routing ->
    -- Broadcast channels" row at the very top, but only while that isn't
    -- already what a plain click on this sound would do anyway (Default
    -- Output already set to "All (checked in Settings)") - otherwise it'd
    -- just duplicate every group row below it for no reason.
    local defaultTarget = SB.db and SB.db.settings and SB.db.settings.defaultOutputTarget
    if defaultTarget and defaultTarget ~= "ALL" then
        table.insert(menuItems, {
            text = "All (checked in Settings)", indent = 8, isHeader = true,
            onClick = function() SB:SendSoundUsingDefaultBroadcast(soundID) end,
        })
    end

    for _, group in ipairs(groups) do
        -- Explicit bugfix: this used to also require #group.members > 0,
        -- which hid the header whenever a group happened to have no known-
        -- Soundbook members reachable right now, even though
        -- group.available already independently confirms you're genuinely
        -- IN that group. "Send to the whole Raid" works via the native
        -- RAID channel regardless of whether any individual member rows
        -- are listed under it, so group.available alone is the right gate -
        -- a group that's neither available nor has any members is still
        -- skipped entirely, header included.
        if group.available then
            table.insert(menuItems, {
                text = group.label, indent = 8, isHeader = true,
                onClick = group.sendAll, channelKey = group.key,
            })

            for _, name in ipairs(group.members) do
                -- Explicit bugfix: "X and f(name)" truncates a multi-
                -- return function down to its FIRST value only (a classic
                -- Lua gotcha) - versionIsCurrent was silently always nil
                -- here regardless of what GetFormattedPlayerVersion
                -- actually returned, which made every player's version
                -- suffix render orange no matter what. An explicit if
                -- preserves both return values correctly.
                local versionSuffix, versionIsCurrent
                if SB.GetFormattedPlayerVersion then
                    versionSuffix, versionIsCurrent = SB:GetFormattedPlayerVersion(name)
                end
                local targetName = name
                table.insert(menuItems, {
                    text = (SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(targetName) or targetName),
                    indent = INDENT, isHeader = false,
                    versionSuffix = versionSuffix, versionIsCurrent = versionIsCurrent,
                    channelKey = group.key,
                    onClick = function() SB:SendSoundToPlayer(soundID, targetName) end,
                })
            end
        end
    end

    -- Explicit request: always the last row - play for yourself only,
    -- no network send at all, regardless of Default Output or any
    -- per-sound override.
    table.insert(menuItems, {
        text = "Self only (no send)", indent = 8, isHeader = true,
        onClick = function() SB:PlaySoundSelfOnly(soundID) end,
    })

    RenderMenu()
    return #menuItems
end

-- Opens the menu at the current cursor position (standard right-click
-- context-menu placement) listing where `soundID` can be sent. No-ops
-- silently if soundID is missing/unknown, or if there is currently nothing
-- to send to at all (no group, no friends).
--
-- `pinFavWindow` (optional): forces the Mini Soundbook to full alpha while
-- this menu is open - only wanted when the menu itself was opened FROM the
-- Mini Soundbook (a slot's own right-click, see FavouritesWindow.lua),
-- since this popup then visually sits on top of/right next to it and it
-- shouldn't fade out from under the player mid-interaction. Opening this
-- same menu from the main Soundbook window (UI.lua, Shift+Right Click) has
-- nothing to do with the Mini Soundbook at all - explicit bug fix: it used
-- to always pin, popping the Mini Soundbook to full visibility out of
-- nowhere even while the mouse was nowhere near it.
--
-- `sourceSlot` (optional): the actual slot Button that was right-clicked,
-- if it has hover-zoom (Theme.ApplyHoverZoom - Mini Soundbook slots only,
-- never the main window's own grid). Explicit request: the icon should
-- stay visibly zoomed, exactly as if the mouse were still resting on it,
-- for as long as this popup covers it and steals the real mouse focus -
-- same reasoning as pinFavWindow above, just for the one slot's zoom
-- state instead of the whole window's alpha.
function SB.OpenSendMenu(soundID, pinFavWindow, sourceSlot)
    if not soundID or not SB.registry[soundID] then return end
    -- Single-active-transient-surface rule (explicit requirement): Quick
    -- Options and the context menu never coexist - opening this one
    -- closes Quick Options first if it was open, a real Hide() (via
    -- Announcer.lua's own close function), not a strata change. The
    -- expanded Mini Soundbook (favMenu) itself is deliberately left
    -- alone here - the context menu is opened FROM one of its rows and
    -- is meant to coexist with it (see pinFavWindow/PinFavAlpha above).
    if SB.CloseAnnouncerQuickOptions then SB.CloseAnnouncerQuickOptions() end
    -- Stale presence pruning happens inside SB.ComputeReachablePlayers
    -- itself now (BuildMenu -> BuildGroups below), not duplicated here.
    EnsureMenu()
    local rowCount = BuildMenu(soundID)
    if rowCount == 0 then
        CloseMenu()
        return
    end

    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    x, y = x / scale, y / scale
    local screenW = UIParent:GetWidth() or 0
    local opensRight = (screenW - x) >= menu:GetWidth()
    local opensDown = y >= menu:GetHeight()
    menu:ClearAllPoints()
    if opensRight and opensDown then
        menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    elseif opensRight then
        menu:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
    elseif opensDown then
        menu:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", x, y)
    else
        menu:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", x, y)
    end

    if pinFavWindow then
        SB:PinFavAlpha(true)
    end
    -- Un-pin whatever was pinned by a previous, still-open call before
    -- pinning the new one - guards against two OpenSendMenu calls in a
    -- row without a CloseMenu in between ever leaving a stale slot
    -- permanently zoomed.
    if pinnedZoomSlot and pinnedZoomSlot ~= sourceSlot and pinnedZoomSlot.SetHoverZoomPinned then
        pinnedZoomSlot:SetHoverZoomPinned(false)
    end
    pinnedZoomSlot = sourceSlot
    if sourceSlot and sourceSlot.SetHoverZoomPinned then
        sourceSlot:SetHoverZoomPinned(true)
    end
    catcher:Show()
    menu:Show()
end
