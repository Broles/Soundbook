-- MutePlayers.lua
-- Individual Mute - reached from the Mini Soundbook's Quick Options menu
-- ("Muted Players...", Announcer.lua) to open a dropdown listing every reachable person
-- (same Friends/Guild/Raid/Party groups SendMenu.lua's own popup and the
-- Default Output Channel dropdown already use) - explicit request: same
-- look and feel as those (title icon strip, gold divider, scroll/mouse
-- wheel treatment, row styling), just built here as its own popup since
-- the interaction is different: left-click a person mutes THEM for
-- another 60 minutes (stacking on top of any time they already have
-- left), right-click unmutes them immediately, and the panel stays open
-- the whole time - only closing when you click outside it - instead of
-- SendMenu.lua's close-on-any-row-click.
--
-- Blocks nothing here itself - the actual enforcement (a muted person's
-- sounds never arriving, the sender seeing "(N muted)") lives in
-- Communication.lua's SB:IsPlayerMuted / IsPlayableRightNow / MUTEACK.

local ADDON_NAME, SB = ...

local ROW_H = 24
local INDENT = 20
local WIDTH = 260
local TITLE_H = 34
-- Same as SendMenu.lua's own popup.
local MAX_VISIBLE_ROWS = 18

local menu, catcher
local rows = {}
local menuItems = {}
local menuOffset = 0
local RenderMenu
local BuildMenuItems
local countdownTicker

local function IsSelfName(name)
    local playerName = SB.GetUnitFullName and SB.GetUnitFullName("player") or UnitName("player")
    return SB.PlayerKey(name) == SB.PlayerKey(playerName)
end

local function CloseMenu()
    if menu then menu:Hide() end
    if catcher then catcher:Hide() end
    if countdownTicker then
        countdownTicker:Cancel()
        countdownTicker = nil
    end
end

local function ClearRows()
    for _, row in ipairs(rows) do
        row:Hide()
        row:ClearAllPoints()
    end
end

local function EnsureCountdownTicker()
    if countdownTicker then return end
    countdownTicker = C_Timer.NewTicker(1, function()
        if not menu or not menu:IsShown() then
            countdownTicker:Cancel()
            countdownTicker = nil
            return
        end
        RenderMenu()
    end)
end

local function FormatRemaining(seconds)
    seconds = math.max(0, math.floor(seconds))
    local mins = math.floor(seconds / 60)
    if mins > 0 then return string.format("%dm", mins) end
    return string.format("%ds", seconds)
end

-- Explicit request: first row, always - clears every individual mute and
-- its timer at once. Coloured distinctly (the same red PrintMuted/muted-
-- countdown text already uses elsewhere) from an ordinary header/person
-- row since it's an action, not a group/name to read.
local UNMUTE_ALL_COLOR = { 1, 0.45, 0.45 }
local MUTED_SUFFIX_COLOR = { 1, 0.35, 0.35 }

-- Same row shape as SendMenu.lua's own AcquireRow (label + right-aligned
-- suffix, header vs. member font/colour, blue hover wash) - `isAction`
-- (Unmute All) is the one new row kind, styled like a header but red.
local function AcquireRow(index, item)
    local row = rows[index]
    if not row then
        row = SB.CreateFrame("Button", nil, menu)
        row:SetHeight(ROW_H)

        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        -- Same arcane cyan as SendMenu.lua's own row hover, not ACCENT's
        -- blurple/violet - keeps this popup's "look and feel" consistent
        -- with it, per explicit request.
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

    row.label:SetFontObject(item.isHeader and SB.Fonts.Highlight or SB.Fonts.HighlightSmall)
    row:SetHeight(ROW_H)
    row.label:ClearAllPoints()
    row.label:SetPoint("LEFT", item.indent, 0)
    row.label:SetPoint("RIGHT", item.suffix and -58 or -8, 0)
    row.label:SetText(item.text)

    local color
    if item.isAction then
        color = UNMUTE_ALL_COLOR
    elseif item.isHeader then
        local channelColor = item.channelKey and SB.CHANNEL_COLOR[item.channelKey]
        color = channelColor and { channelColor.r, channelColor.g, channelColor.b } or SB.Theme.TEXT
    else
        color = SB.Theme.TEXT_DIM
    end
    row.label:SetTextColor(unpack(color))

    row.suffix:SetShown(item.suffix and true or false)
    if item.suffix then
        row.suffix:SetText(item.suffix)
        row.suffix:SetTextColor(unpack(MUTED_SUFFIX_COLOR))
    end

    row:SetScript("OnEnter", function() row.label:SetTextColor(1, 1, 1) end)
    row:SetScript("OnLeave", function() row.label:SetTextColor(unpack(color)) end)

    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(_, button)
        if item.isAction then
            SB:UnmuteAllPlayers()
        elseif not item.isHeader then
            if button == "LeftButton" then
                SB:MutePlayerFor(item.name)
            else
                SB:UnmutePlayer(item.name)
            end
            EnsureCountdownTicker()
        else
            return -- group headers here are plain labels, not clickable
        end
        -- Deliberately never calls CloseMenu() - explicit request: "Das
        -- Dropdown bleibt die ganze Zeit geöffnet und schließt nur, wenn
        -- man außerhalb des Dropdowns klickt." Re-render in place instead.
        BuildMenuItems()
        RenderMenu()
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
        RenderMenu()
    end)
    menu:Hide()
    SB.Theme.CleanPanel(menu, 1)

    -- Title strip - same shape as SendMenu.lua's own (icon + label +
    -- divider), just a fixed mute glyph/label instead of a per-sound icon
    -- and name, since this popup isn't about any one sound.
    menu.titleIcon = SB.Theme.CreateIconSlot(menu, 20, SB.Theme.GOLD)
    menu.titleIcon:SetPoint("TOPLEFT", 8, -7)
    menu.titleIcon.ornament:SetAlpha(0)
    menu.titleIcon:SetVisualState("normal", true, false)
    -- Same mute glyph texture/region CreateMuteGlyph itself uses (Theme.lua)
    -- - the title reads as "this popup is about the mute button" at a glance.
    menu.titleIcon.texture:SetTexture("Interface\\AddOns\\Soundbook\\Assets\\ControlIcons")
    menu.titleIcon.texture:SetTexCoord(0.25, 0.50, 0, 1)
    menu.titleIcon.texture:SetVertexColor(1.0, 0.34, 0.34, 1)

    menu.titleText = menu:CreateFontString(nil, "OVERLAY")
    menu.titleText:SetFontObject(SB.Fonts.Highlight)
    menu.titleText:SetPoint("LEFT", menu.titleIcon, "RIGHT", 8, 0)
    menu.titleText:SetPoint("RIGHT", -10, 0)
    menu.titleText:SetJustifyH("LEFT")
    menu.titleText:SetWordWrap(false)
    menu.titleText:SetText("Individual Mute")
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

-- Same font-scale-aware sizing as SendMenu.lua's own RenderMenu, so both
-- popups grow/shrink together when Settings -> Main Font Scale changes.
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
        local row = AcquireRow(i, item)
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

BuildMenuItems = function()
    wipe(menuItems)
    table.insert(menuItems, { text = "Unmute All", indent = 8, isAction = true })

    local reachable = SB.ComputeReachablePlayers()
    -- Raid and Party are ONE merged group now (see SB.ResolveGroupChannel/
    -- SB.ComputeReachablePlayers, Communication.lua) - no separate PARTY
    -- key exists on `reachable` any more; label reflects whichever is
    -- actually live right now.
    local groupLabel = IsInRaid() and "Raid" or (IsInGroup() and "Party") or "Raid"
    local groups = {
        { label = "Guild", key = "GUILD", names = reachable.GUILD },
        { label = groupLabel, key = "RAID", names = reachable.RAID },
        { label = "Friends", key = "FRIENDS", names = reachable.FRIENDS },
    }

    for _, group in ipairs(groups) do
        if #group.names > 0 then
            table.insert(menuItems, { text = group.label, indent = 8, isHeader = true, channelKey = group.key })
            for _, name in ipairs(group.names) do
                if not IsSelfName(name) then
                    local remaining = SB:GetPlayerMuteRemaining(name)
                    table.insert(menuItems, {
                        text = (SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(name) or name),
                        indent = INDENT, name = name,
                        suffix = remaining and FormatRemaining(remaining) or nil,
                    })
                end
            end
        end
    end
end

--- Opens at the current cursor position, same placement logic as
--- SendMenu.lua's own popup (flips up/left near a screen edge).
function SB.OpenMutePlayersMenu()
    EnsureMenu()
    BuildMenuItems()
    menuOffset = 0
    RenderMenu()

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

    catcher:Show()
    menu:Show()
    EnsureCountdownTicker()
end

-- Explicit request: live-refresh whoever's listed the moment a mute
-- changes anywhere else too, not just from this panel's own row clicks.
SB:On("PLAYER_MUTE_CHANGED", function()
    if menu and menu:IsShown() then
        BuildMenuItems()
        RenderMenu()
    end
end)
