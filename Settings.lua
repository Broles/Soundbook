-- Settings.lua
-- The Settings page lives inside the Soundbook window itself (no separate
-- foreign-looking window). UI.lua shows/hides this panel when the Settings
-- tab (grouped in the compact right-side dock below the category tabs) is
-- clicked.
--
-- Settings restructure (explicit requirement): replaced the old single
-- continuous scroll with five navigable sections - Sound & Playback,
-- Sharing & Receiving, Mini Soundbook, Library & Appearance, Advanced -
-- shown one at a time via a compact tab strip, each independently
-- scrollable, plus a persistent Help & Information footer that's visible
-- regardless of which section is active. This is a presentation/navigation
-- reorganization only - every underlying setting/SavedVariable this file
-- touches keeps its existing key and behaviour.
--
-- Three things that used to live here were relocated, not deleted:
--   - Favourite Keybindings -> the Main Soundbook's own Favourites view
--     (its "Keybinds" shortcut now enters Keybinding Mode directly - see
--     Keybindings.lua's SB.BuildKeybindModePanel and UI.lua's
--     SB:ToggleKeybindMode). Keybindings are attached to Favourite slots,
--     not general configuration.
--   - Sound History -> the launcher icons' own context/quick menu
--     (Announcer.lua's Quick Options, shared by the Announcer icon and the
--     Main toolbar's Quick Audio button), directly above Open Settings.
--     History is content/navigation, not configuration.
--   - The three timed/global receive-mute action buttons -> the same
--     Quick Options menu, alongside the indefinite Mute Incoming toggle
--     that already lived there. Timed muting is a runtime action, not
--     persistent configuration; Settings now only shows a compact
--     informational state with a Resume Receiving action while a mute is
--     actually active.
--
-- Two things were removed entirely, not relocated - explicit requirement:
-- analytics collection stays always-on and invisible to normal users, so
-- neither its enable/disable checkbox nor the Community Analytics window
-- button belong in Settings at all (the window is still reachable via
-- /sb analytics, just not surfaced here).

local ADDON_NAME, SB = ...

-- The panel's actual usable width (scroll area minus its own margins/
-- scroll thumb - see SB.BuildSettingsPanel) - controls below are sized
-- against this instead of arbitrary small pixel widths, so they actually
-- fill the column instead of leaving a big empty strip on the right.
-- UI/UX polish pass (explicit requirement, section 8: "the current content
-- column feels too narrow with too much wasted space around it") - raised
-- from 450 to use meaningfully more of the available width, while staying
-- safely inside the scroll child's own real width even at the Main
-- window's minimum resizable size (560): at that size the scroll child is
-- ~502px wide (mainWidth - 2*SAFE_INSET - 2 for the panel/scroll region,
-- minus FitSettingsPanelHeight's own -28 scrollbar/margin reservation) -
-- 480 leaves a real margin below that ceiling rather than exactly meeting
-- it. Still a fixed column (not a full-bleed responsive width) so
-- paragraph-length hint text stays readable at any window size - "keep
-- readable margins" is an explicit requirement too, not just "use more
-- width".
local CONTENT_W = 480

local panel
local categoryNameBoxes = {}
local categoryIconTextures = {}
local matrixReceiveTiles = {}
local receiveMuteInfoText, receiveMuteResumeBtn
local countdownTicker

-- One content frame per section, all built once and swapped via Show/Hide
-- (same pattern UI.lua already uses for Settings/Admin/Keybind-Mode
-- swapping over the Library) - never rebuilt on tab switch, so nothing
-- inside a section ever needs re-wiring after the first BuildSettingsPanel
-- call.
local sectionContents = {}
local sectionBottomAnchor = {}
local sectionTabButtons = {}
local currentSectionKey

-- Targeted correction round: single-word tab labels (explicit requirement -
-- the old labels were too long for a compact tab strip). `color` is each
-- category's own active-state accent (its underline colour, section-
-- specific per requirement, not a single shared active colour) - existing
-- palette tokens only: Arcane Cyan, the Guild-channel green, GOLD, a
-- Friends-style blue, and the Raid/Party orange. Underlying content/key
-- assignments are completely unchanged - this only touches the label text
-- and adds the colour used by BuildTabStrip below.
local SECTION_ORDER = {
    { key = "playback", label = "Sound",    color = SB.Theme.V3.ARCANE_CYAN },
    { key = "sharing",  label = "Sharing",  color = { SB.CHANNEL_COLOR.GUILD.r, SB.CHANNEL_COLOR.GUILD.g, SB.CHANNEL_COLOR.GUILD.b } },
    { key = "mini",     label = "Mini",     color = SB.Theme.GOLD },
    { key = "library",  label = "Library",  color = { SB.CHANNEL_COLOR.FRIENDS.r, SB.CHANNEL_COLOR.FRIENDS.g, SB.CHANNEL_COLOR.FRIENDS.b } },
    { key = "advanced", label = "Advanced", color = { SB.CHANNEL_COLOR.RAID.r, SB.CHANNEL_COLOR.RAID.g, SB.CHANNEL_COLOR.RAID.b } },
}

local CHECKBOX_HELP = {
    ["Show Minimap Button"] = "Show or hide the Soundbook shortcut at the minimap.",
    ["Allow overlapping sounds"] = "Allow a new sound to start before the previous one ends.",
    ["Allow sounds in combat"] = "Permit Soundbook playback while your character is in combat.",
    ["Allow sounds during boss encounters"] = "Permit Soundbook playback during active boss encounters.",
    ["Queue rate-limited remote sounds"] = "Keep valid incoming sounds briefly when they arrive too quickly, instead of dropping them.",
    ["Show received sound details"] = "Print sender, source and sound information for received playback.",
    ["Show blocked/muted sound attempts"] = "Report attempts to play a sound that you muted locally.",
    ["Show delivery confirmations"] = "Show delivery confirmations returned by friends.",
    ["Show Mini Soundbook"] = "Show or hide the Mini Soundbook.",
    ["Lock position and size"] = "Prevent moving and resizing the Main Soundbook and the Mini Soundbook.",
    ["Debug Mode"] = "Print additional diagnostic information to chat.",
}

local function Help(frame, title, body)
    SB.Theme.AttachTooltip(frame, title, body)
end

local function Section(parent, text, anchorTo, yOffset)
    local section = SB.Theme.CreateSectionHeader(parent, text)
    section:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOffset or -16)
    section:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
    return section
end

-- Same idea as Section above, deliberately quieter (explicit requirement,
-- "Advanced Playback" - de-emphasized compared with normal playback
-- controls): dim small text, no gold divider line, so it reads as a
-- secondary sub-group rather than a peer of Playback/During Gameplay.
local function DimSection(parent, text, anchorTo, yOffset)
    local section = CreateFrame("Frame", nil, parent)
    section:SetHeight(16)
    section:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOffset or -16)
    section:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
    local label = section:CreateFontString(nil, "OVERLAY")
    label:SetFontObject(SB.Fonts.DisableSmall)
    label:SetPoint("LEFT", 0, 0)
    label:SetText(text)
    label:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    return section
end

local function Checkbox(parent, label, anchorTo, xOff, yOff, onClick)
    local check = SB.Theme.CreateCheckbox(parent, label, onClick)
    check:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", xOff or 0, yOff or -6)
    Help(check, label, CHECKBOX_HELP[label] or "Toggle this setting.")
    return check
end

-- A real (flat, scrollable) dropdown listing every available font -
-- SB.AVAILABLE_FONTS plus, if anything on the system provides them, fonts
-- from LibSharedMedia (see SB.GetAvailableFonts in Core.lua) - each
-- previewed in its own typeface, both in the open list and on the button
-- itself once picked. Re-queried every time the list opens, so a font
-- registered later in the session still shows up. `getPath`/`setPath`
-- read/write wherever the caller's font setting actually lives.
local function BuildFontDropdown(parent, label, anchorTo, yOff, getPath, setPath)
    local lbl = parent:CreateFontString(nil, "OVERLAY")
    lbl:SetFontObject(SB.Fonts.HighlightSmall)
    lbl:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOff or -14)
    lbl:SetText(label)

    local dd = SB.Theme.CreateDropdown(parent, CONTENT_W - 20, 22, 6)
    dd.button:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -6)

    local function ComputeOptions()
        local opts = {}
        for _, f in ipairs(SB.GetAvailableFonts()) do
            table.insert(opts, { text = f.name, value = f.path })
        end
        return opts
    end

    dd:SetOptions(ComputeOptions())
    dd:SetOptionsProvider(ComputeOptions)

    dd:SetRowFont(function(fontString, opt)
        local _, size, flags = fontString:GetFont()
        fontString:SetFont(opt.value, size or 12, flags or "")
    end)

    dd:SetValue(getPath())
    dd:SetOnChange(function(path)
        setPath(path)
    end)
    Help(dd.button, label, "Choose the font used by this part of Soundbook.")

    return dd.button
end

-- A "smaller <-> bigger" text-size slider (SB.FONT_SCALE_STEPS) - a vague
-- relative scale rather than a literal point size, since this multiplies
-- very different base sizes across several font objects/contexts.
local function BuildFontScaleSlider(parent, label, anchorTo, yOff, getMult, setMult)
    local lbl = parent:CreateFontString(nil, "OVERLAY")
    lbl:SetFontObject(SB.Fonts.HighlightSmall)
    lbl:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, yOff or -14)
    lbl:SetText(label)

    local slider = SB.Theme.CreateSlider(parent, 1, #SB.FONT_SCALE_STEPS, 1, CONTENT_W - 120, function(value)
        setMult(SB.FONT_SCALE_STEPS[value].mult)
    end, function(value)
        return SB.FONT_SCALE_STEPS[value].label
    end)
    slider:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -10)
    slider:SetValue(SB.FontScaleStepIndex(getMult()))
    slider:Refresh()
    Help(slider, label, "Adjust this text size; changes are applied immediately.")

    return slider
end

------------------------------------------------------------------------
-- Sharing & Receiving - Channel Matrix
------------------------------------------------------------------------

-- Raid and Party are ONE row everywhere in this table (a single "RAID" key
-- covers both Send and Receive, labelled "Raid/Party" since it's a static
-- settings label - see SB.ResolveGroupChannel, Communication.lua, for the
-- live per-message resolution).
local MODE_LABELS = { FRIENDS = "Friends", RAID = "Raid/Party", GUILD = "Guild", DIRECT = "Direct" }
local RECEIVE_KEY = { FRIENDS = "receiveFriends", RAID = "receiveRaid", GUILD = "receiveGuild", DIRECT = "receiveDirect" }

-- Display order for the Send/Receive matrix below. Direct is special: it
-- has no Send column at all - there's no "broadcast as Direct" concept,
-- Direct-ness comes from HOW a sound is sent (SendMenu's "to one specific
-- person"), not a channel you opt into broadcasting on. It only ever needs
-- its own RECEIVE toggle, to separate "a Direct-targeted send from anyone"
-- from a plain Friends broadcast - both travel as a WHISPER on the wire
-- (see Communication.lua's ReceiveAllowedForChannel).
local MATRIX_ROWS = { "FRIENDS", "GUILD", "RAID", "DIRECT" }
local NO_SEND_ROW = { DIRECT = true }
local MATRIX_ROW_LABEL_W = 90
local MATRIX_HEADER_H, MATRIX_ROW_H, MATRIX_TILE_SIZE = 20, 26, 18

-- rows = Friends/Guild/Raid/Party/Direct, columns = Send/Receive, each
-- cell its own independently clickable Theme.CreateToggleTile - click
-- directly in the grid to opt a group in/out of sending or receiving.
-- Explicit requirement (Settings restructure): the Send column is what
-- Default Output = "All" actually includes - it does NOT replace the
-- Main-window Default Output selector, which stays a separate, frequently
-- -changed runtime choice living outside Settings entirely.
local function BuildChannelMatrix(parent, anchorTo)
    -- Targeted correction round (explicit requirement): "Channels" now
    -- uses the SAME section-heading component/hierarchy as "Notifications"
    -- below it (Theme.CreateSectionHeader - Normal font, gold text, gold
    -- divider line) instead of a plain small HighlightSmall label that
    -- read as weak/secondary next to it.
    local header = SB.Theme.CreateSectionHeader(parent, "Channels")
    header:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -16)
    header:SetPoint("RIGHT", parent, "RIGHT", -20, 0)

    local subHint = parent:CreateFontString(nil, "OVERLAY")
    subHint:SetFontObject(SB.Fonts.DisableSmall)
    subHint:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
    subHint:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
    subHint:SetJustifyH("LEFT")
    subHint:SetWordWrap(true)
    subHint:SetText("Send defines which channels are included when the Main window's Default Output is set to All. Receive controls which incoming channels you accept.")
    subHint:SetTextColor(unpack(SB.Theme.TEXT_DIM))

    local tableW = CONTENT_W - 20
    local cellW = (tableW - MATRIX_ROW_LABEL_W) / 2

    local grid = CreateFrame("Frame", nil, parent)
    grid:SetPoint("TOPLEFT", subHint, "BOTTOMLEFT", 0, -10)
    grid:SetSize(tableW, MATRIX_HEADER_H + MATRIX_ROW_H * #MATRIX_ROWS)

    local sendHeader = grid:CreateFontString(nil, "OVERLAY")
    sendHeader:SetFontObject(SB.Fonts.HighlightSmall)
    sendHeader:SetPoint("TOP", grid, "TOPLEFT", MATRIX_ROW_LABEL_W + cellW / 2, 0)
    sendHeader:SetText("Send")
    sendHeader:SetTextColor(unpack(SB.Theme.ACCENT))

    local receiveHeader = grid:CreateFontString(nil, "OVERLAY")
    receiveHeader:SetFontObject(SB.Fonts.HighlightSmall)
    receiveHeader:SetPoint("TOP", grid, "TOPLEFT", MATRIX_ROW_LABEL_W + cellW + cellW / 2, 0)
    receiveHeader:SetText("Receive")
    receiveHeader:SetTextColor(unpack(SB.Theme.ACCENT))

    for i, mode in ipairs(MATRIX_ROWS) do
        local rowY = -(MATRIX_HEADER_H + (i - 1) * MATRIX_ROW_H)
        local rowCenterY = rowY - MATRIX_ROW_H / 2

        if i % 2 == 0 then
            local rowBg = grid:CreateTexture(nil, "BACKGROUND")
            rowBg:SetPoint("TOPLEFT", grid, "TOPLEFT", 0, rowY)
            rowBg:SetSize(tableW, MATRIX_ROW_H)
            rowBg:SetColorTexture(1, 1, 1, 0.03)
        end

        local rowLabel = grid:CreateFontString(nil, "OVERLAY")
        rowLabel:SetFontObject(SB.Fonts.HighlightSmall)
        rowLabel:SetPoint("LEFT", grid, "TOPLEFT", 0, rowCenterY)
        rowLabel:SetText(MODE_LABELS[mode])
        local rowColor = SB.CHANNEL_COLOR[mode]
        if rowColor then
            rowLabel:SetTextColor(rowColor.r, rowColor.g, rowColor.b)
        end

        if not NO_SEND_ROW[mode] then
            local sendTile = SB.Theme.CreateToggleTile(grid, MATRIX_TILE_SIZE, function(checked)
                SB.db.settings.broadcastModes[mode] = checked
            end)
            sendTile:SetPoint("CENTER", grid, "TOPLEFT", MATRIX_ROW_LABEL_W + cellW / 2, rowCenterY)
            sendTile:SetChecked(SB.db.settings.broadcastModes[mode] and true or false)
            Help(sendTile, "Send to " .. MODE_LABELS[mode],
                "Include this channel when Soundbook's Default Output is set to All.")
        else
            local dash = grid:CreateFontString(nil, "OVERLAY")
            dash:SetFontObject(SB.Fonts.HighlightSmall)
            dash:SetPoint("CENTER", grid, "TOPLEFT", MATRIX_ROW_LABEL_W + cellW / 2, rowCenterY)
            dash:SetText("-")
            dash:SetTextColor(SB.Theme.BORDER_DIM[1], SB.Theme.BORDER_DIM[2], SB.Theme.BORDER_DIM[3])
        end

        local receiveTile = SB.Theme.CreateToggleTile(grid, MATRIX_TILE_SIZE, function(checked)
            SB.db.settings[RECEIVE_KEY[mode]] = checked
            if not checked and SB.ClearPendingQueueForMode then
                SB:ClearPendingQueueForMode(mode)
            end
        end)
        receiveTile:SetPoint("CENTER", grid, "TOPLEFT", MATRIX_ROW_LABEL_W + cellW + cellW / 2, rowCenterY)
        receiveTile:SetChecked(SB.db.settings[RECEIVE_KEY[mode]] and true or false)
        if mode == "DIRECT" then
            Help(receiveTile, "Receive Direct sounds",
                "Allow sounds sent straight to just you specifically (SendMenu's " ..
                "\"send to one person\") - from a Friend, a Guild member, anyone with " ..
                "Soundbook. Separate from the Friends row above, which only covers a " ..
                "broadcast to everyone on your Friends list at once.")
        else
            Help(receiveTile, "Receive from " .. MODE_LABELS[mode],
                "Allow Soundbook sounds arriving through this channel.")
        end
        matrixReceiveTiles[mode] = receiveTile
    end

    local divider = grid:CreateTexture(nil, "ARTWORK")
    divider:SetHeight(1)
    divider:SetPoint("BOTTOMLEFT", 0, 0)
    divider:SetPoint("BOTTOMRIGHT", 0, 0)
    divider:SetColorTexture(SB.Theme.BORDER_DIM[1], SB.Theme.BORDER_DIM[2], SB.Theme.BORDER_DIM[3], 0.5)

    return grid
end

local function FormatCountdown(seconds)
    seconds = math.max(0, math.floor((seconds or 0) + 0.5))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Runs only while the panel is actually visible - self-cancels the moment
-- it isn't. Only needed at all while a TIMED mute (30/60) is actually
-- counting down; harmless and cheap to just let it run continuously
-- whenever the panel's open rather than tracking that more precisely.
local function EnsureCountdownTicker()
    if countdownTicker then return end
    countdownTicker = C_Timer.NewTicker(1, function()
        if not panel or not panel:IsShown() then
            countdownTicker:Cancel()
            countdownTicker = nil
            return
        end
        SB:RefreshChannelMatrix()
    end)
end

-- Global Receive Mute - explicit requirement: no permanent/30/60-minute
-- action buttons in Settings any more (that's a runtime action now
-- reached from the Mini Soundbook's own Quick Options menu, alongside its
-- existing indefinite Mute Incoming toggle - see Announcer.lua). This is
-- a READ-ONLY compact status - shown only while a mute is actually
-- active, with a single Resume Receiving action to end it early.
--
-- UI/UX polish pass (explicit requirement: "do not reserve blank space
-- for content that does not exist") - height is no longer a fixed 54px
-- reserved regardless of whether a mute is active; RefreshChannelMatrix
-- below now collapses it to ~0 when nothing is shown, and Notifications
-- (anchored to this container's BOTTOM) reflows immediately below it via
-- WoW's own live anchor resolution the instant the height changes -
-- nothing here needs its own reflow logic beyond setting the height.
local receiveMuteContainer

local function BuildReceiveMuteInfo(parent, anchorTo)
    local container = CreateFrame("Frame", nil, parent)
    container:SetHeight(1)
    container:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, 0)
    container:SetPoint("RIGHT", parent, "RIGHT", -20, 0)

    local info = container:CreateFontString(nil, "OVERLAY")
    info:SetFontObject(SB.Fonts.HighlightSmall)
    info:SetPoint("TOPLEFT", 0, -8)
    info:SetPoint("RIGHT", 0, 0)
    info:SetJustifyH("LEFT")
    info:SetTextColor(1, 0.55, 0.35)
    info:Hide()

    local resumeBtn = SB.Theme.CreateSecondaryButton(container, "Resume Receiving", 160, 22)
    resumeBtn:SetPoint("TOPLEFT", info, "BOTTOMLEFT", 0, -6)
    resumeBtn:SetScript("OnClick", function() SB:StopReceiveMute() end)
    resumeBtn:Hide()

    receiveMuteInfoText, receiveMuteResumeBtn = info, resumeBtn
    receiveMuteContainer = container
    return container
end

-- Re-syncs the 4 Receive tiles and the compact mute info with whatever
-- SB.db.settings.receiveMute/receiveX currently say - called on
-- RECEIVE_MUTE_CHANGED (a click from Quick Options, a timer firing, or the
-- resolve-on-load check, see Communication.lua) and every time the
-- Settings tab is shown (UI.lua's RefreshMainWindow), since this panel is
-- otherwise only ever built/populated once and never re-synced on its own.
function SB:RefreshChannelMatrix()
    if not panel then return end

    for mode, tile in pairs(matrixReceiveTiles) do
        tile:SetChecked(SB.db.settings[RECEIVE_KEY[mode]] and true or false)
    end

    if not receiveMuteInfoText then return end
    local muted = SB:IsReceiveMuted()
    receiveMuteInfoText:SetShown(muted)
    receiveMuteResumeBtn:SetShown(muted)
    -- Collapses to ~0 when nothing is shown (see BuildReceiveMuteInfo's
    -- own comment) instead of always reserving room for it; Notifications
    -- reflows immediately below via the live anchor chain, and
    -- FitSettingsPanelHeight is re-run so the Sharing tab's own
    -- scrollable height (and scrollbar) catch up to the new content
    -- height right away, not just on the next tab switch.
    if receiveMuteContainer then
        receiveMuteContainer:SetHeight(muted and 54 or 1)
    end
    if muted then
        local remaining = SB:GetReceiveMuteRemaining()
        if remaining then
            receiveMuteInfoText:SetText(string.format("Incoming sounds muted - %s remaining", FormatCountdown(remaining)))
            EnsureCountdownTicker()
        else
            receiveMuteInfoText:SetText("Incoming sounds muted indefinitely")
        end
    end
    if SB.FitSettingsPanelHeight and panel:IsShown() then SB:FitSettingsPanelHeight() end
end

SB:On("RECEIVE_MUTE_CHANGED", function()
    SB:RefreshChannelMatrix()
end)

------------------------------------------------------------------------
-- Library & Appearance - Categories
------------------------------------------------------------------------

local function CategoryLabel(category, suffix)
    return "Category " .. category .. " " .. suffix
end

local ICON_SLOT_SIZE = 28
local ICON_GAP = 8

-- One coherent row/group per category (explicit requirement) - icon and
-- name field side by side under a single label, not disconnected controls.
local function BuildCategoryRow(parent, anchorTo, category)
    local label = parent:CreateFontString(nil, "OVERLAY")
    label:SetFontObject(SB.Fonts.Normal)
    label:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -14)
    label:SetText(CategoryLabel(category, "Name"))

    local iconBtn = SB.Theme.CreateIconSlot(parent, ICON_SLOT_SIZE, nil, "Button")
    iconBtn:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)
    local tex = iconBtn.texture
    tex:SetTexture(SB.db.categories[category].icon)
    categoryIconTextures[category] = tex
    iconBtn:SetScript("OnClick", function()
        SB.OpenIconPicker(function(path)
            SB.db.categories[category].icon = path
            tex:SetTexture(path)
            SB:Fire("CATEGORY_CHANGED", category)
        end, SB.db.categories[category].icon)
    end)
    Help(iconBtn, CategoryLabel(category, "Icon"), "Choose the icon shown on this category tab.")

    local editBox = SB.Theme.CreateInputBox(parent, CONTENT_W - 20 - ICON_SLOT_SIZE - ICON_GAP, 22)
    editBox:SetPoint("LEFT", iconBtn, "RIGHT", ICON_GAP, 0)
    editBox:SetMaxLetters(30)
    editBox:SetText(SB.db.categories[category].name)
    editBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    editBox:SetScript("OnEditFocusLost", function(self)
        local text = self:GetText()
        if text == "" then
            text = (type(category) == "string") and category or ("Category " .. category)
        end
        SB.db.categories[category].name = text
        SB:Fire("CATEGORY_CHANGED", category)
    end)
    categoryNameBoxes[category] = editBox

    return iconBtn
end

------------------------------------------------------------------------
-- Section 1: Sound & Playback
------------------------------------------------------------------------

local function BuildSoundPlaybackSection(content, topAnchor)
    local playbackHeader = Section(content, "Playback", topAnchor, -4)

    local channelLabel = content:CreateFontString(nil, "OVERLAY")
    channelLabel:SetFontObject(SB.Fonts.HighlightSmall)
    channelLabel:SetPoint("TOPLEFT", playbackHeader, "BOTTOMLEFT", 0, -8)
    channelLabel:SetText("Sound Output Channel")

    local CHANNEL_ORDER = { "Master", "SFX", "Music", "Ambience", "Dialog" }
    local channelDD = SB.Theme.CreateDropdown(content, CONTENT_W - 20, 22, 6)
    channelDD.button:SetPoint("TOPLEFT", channelLabel, "BOTTOMLEFT", 0, -6)
    local channelOptions = {}
    for _, ch in ipairs(CHANNEL_ORDER) do
        table.insert(channelOptions, { text = ch, value = ch })
    end
    channelDD:SetOptions(channelOptions)
    channelDD:SetValue(SB.db.settings.channel or "Master")
    channelDD:SetOnChange(function(value)
        SB.db.settings.channel = value
    end)
    Help(channelDD.button, "Sound Output Channel",
        "Choose which World of Warcraft volume channel Soundbook uses.")

    local overlapCheck = Checkbox(content, "Allow overlapping sounds", channelDD.button, 0, -14, function(checked)
        SB.db.settings.allowOverlap = checked
    end)
    overlapCheck:SetChecked(SB.db.settings.allowOverlap)

    local gameplayHeader = Section(content, "During Gameplay", overlapCheck, -16)
    local combatCheck = Checkbox(content, "Allow sounds in combat", gameplayHeader, 0, -8, function(checked)
        SB.db.settings.allowInCombat = checked
    end)
    combatCheck:SetChecked(SB.db.settings.allowInCombat)

    local encounterCheck = Checkbox(content, "Allow sounds during boss encounters", combatCheck, 0, -2, function(checked)
        SB.db.settings.allowInEncounter = checked
    end)
    encounterCheck:SetChecked(SB.db.settings.allowInEncounter)

    -- De-emphasized versus the playback controls above (explicit
    -- requirement) - dimmer header, no gold divider.
    local advHeader = DimSection(content, "Advanced Playback", encounterCheck, -18)

    local cooldownLabel = content:CreateFontString(nil, "OVERLAY")
    cooldownLabel:SetFontObject(SB.Fonts.HighlightSmall)
    cooldownLabel:SetPoint("TOPLEFT", advHeader, "BOTTOMLEFT", 0, -8)
    cooldownLabel:SetText("Remote repeat cooldown (seconds)")
    cooldownLabel:SetTextColor(unpack(SB.Theme.TEXT_DIM))

    local cooldownBox = SB.Theme.CreateInputBox(content, 60, 22)
    cooldownBox:SetPoint("TOPLEFT", cooldownLabel, "BOTTOMLEFT", 0, -6)
    cooldownBox:SetNumeric(false)
    cooldownBox:SetMaxLetters(6)
    cooldownBox:SetText(tostring(SB.db.settings.remoteCooldown))
    cooldownBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    cooldownBox:SetScript("OnEditFocusLost", function(self)
        local val = tonumber(self:GetText())
        if not val or val < 0 then val = 1.0 end
        SB.db.settings.remoteCooldown = val
        self:SetText(tostring(val))
    end)
    Help(cooldownBox, "Remote repeat cooldown",
        "Minimum time before the same sound can be received again from the same player.")

    local queueCheck = Checkbox(content, "Queue rate-limited remote sounds", cooldownBox, 0, -14, function(checked)
        SB.db.settings.soundQueueEnabled = checked
        if not checked and SB.ClearPendingQueue then
            SB:ClearPendingQueue()
        end
    end)
    queueCheck:SetChecked(SB.db.settings.soundQueueEnabled)

    return queueCheck
end

------------------------------------------------------------------------
-- Section 2: Sharing & Receiving
------------------------------------------------------------------------

local function BuildSharingSection(content, topAnchor)
    local channelMatrix = BuildChannelMatrix(content, topAnchor)
    local muteInfo = BuildReceiveMuteInfo(content, channelMatrix)

    -- Targeted correction round (explicit requirement): renamed from
    -- "Chat Notifications" to "Notifications", same section-heading
    -- hierarchy as "Channels" above. The -24 gap here (was -8, chained
    -- after a mute-info container that used to always reserve 54px
    -- whether or not a mute was active) is now the ONLY gap between them -
    -- muteInfo's own height collapses to ~0 when nothing is displayed in
    -- it (BuildReceiveMuteInfo/RefreshChannelMatrix below), so this reads
    -- as "immediately after Channels" instead of leaving a large empty
    -- region, while still measuring out to the requested ~24px target
    -- once a mute IS active and muteInfo has real content again.
    local notifyHeader = Section(content, "Notifications", muteInfo, -24)
    local notifyMutedCheck = Checkbox(content, "Show received sound details", notifyHeader, 0, -8, function(checked)
        SB.db.settings.notifyOnMuted = checked
    end)
    notifyMutedCheck:SetChecked(SB.db.settings.notifyOnMuted)

    local notifyBlockedCheck = Checkbox(content, "Show blocked/muted sound attempts", notifyMutedCheck, 0, -2, function(checked)
        SB.db.settings.notifyMutedAttempts = checked
    end)
    notifyBlockedCheck:SetChecked(SB.db.settings.notifyMutedAttempts)

    local notifyReceiptsCheck = Checkbox(content, "Show delivery confirmations", notifyBlockedCheck, 0, -2, function(checked)
        SB.db.settings.notifyFriendReceipts = checked
    end)
    notifyReceiptsCheck:SetChecked(SB.db.settings.notifyFriendReceipts)

    SB:RefreshChannelMatrix()
    return notifyReceiptsCheck
end

------------------------------------------------------------------------
-- Section 3: Mini Soundbook
------------------------------------------------------------------------

local function BuildMiniSoundbookSection(content, topAnchor)
    local windowHeader = Section(content, "Window", topAnchor, -4)
    local showCheck = Checkbox(content, "Show Mini Soundbook", windowHeader, 0, -8, function(checked)
        if checked then SB:ShowAnnouncer() else SB:HideAnnouncer() end
    end)
    showCheck:SetChecked(SB.db.ui.announcer.shown)

    local lockCheck = Checkbox(content, "Lock position and size", showCheck, 0, -2, function(checked)
        SB:SetAnnouncerLocked(checked)
    end)
    lockCheck:SetChecked(SB.db.ui.layoutLocked)

    local opacityHeader = Section(content, "Opacity", lockCheck, -16)
    local alphaIdleLabel = content:CreateFontString(nil, "OVERLAY")
    alphaIdleLabel:SetFontObject(SB.Fonts.HighlightSmall)
    alphaIdleLabel:SetPoint("TOPLEFT", opacityHeader, "BOTTOMLEFT", 0, -8)
    alphaIdleLabel:SetText("Idle Opacity")

    local alphaIdleSlider = SB.Theme.CreateSlider(content, 0, 100, 1, CONTENT_W - 120, function(value)
        SB.db.ui.announcer.alphaIdle = math.floor(value + 0.5)
        SB:RefreshAnnouncerAlpha()
    end)
    alphaIdleSlider:SetPoint("TOPLEFT", alphaIdleLabel, "BOTTOMLEFT", 0, -10)
    alphaIdleSlider:SetValue(SB.db.ui.announcer.alphaIdle)
    alphaIdleSlider:Refresh()
    Help(alphaIdleSlider, "Idle Opacity", "Set the Mini Soundbook's opacity while the mouse is away and no sound is playing.")

    local alphaHoverLabel = content:CreateFontString(nil, "OVERLAY")
    alphaHoverLabel:SetFontObject(SB.Fonts.HighlightSmall)
    alphaHoverLabel:SetPoint("TOPLEFT", alphaIdleSlider, "BOTTOMLEFT", 0, -14)
    alphaHoverLabel:SetText("Hover Opacity")

    local alphaHoverSlider = SB.Theme.CreateSlider(content, 0, 100, 1, CONTENT_W - 120, function(value)
        SB.db.ui.announcer.alphaHover = math.floor(value + 0.5)
        SB:RefreshAnnouncerAlpha()
    end)
    alphaHoverSlider:SetPoint("TOPLEFT", alphaHoverLabel, "BOTTOMLEFT", 0, -10)
    alphaHoverSlider:SetValue(SB.db.ui.announcer.alphaHover)
    alphaHoverSlider:Refresh()
    Help(alphaHoverSlider, "Hover Opacity", "Set the Mini Soundbook's opacity while the mouse is over it.")

    -- Now Playing / Announcement Duration - re-exposed (it was previously
    -- kept in SavedVariables but hidden entirely once the Mini Soundbook's
    -- own real-duration progress bar replaced the old fixed-timer HUD).
    -- Honest description of what it ACTUALLY drives today: the Library
    -- grid's own "just played" gold highlight duration (UI.lua's
    -- SetPlayingState) - not a literal Now Playing -> Last Sound
    -- transition inside the Mini Soundbook banner itself, which no longer
    -- exists as a separate state in the current 3.0 Announcer. The
    -- "0 = ..." floor behaviour from the underlying setting is preserved
    -- exactly (SB.db.settings.announceDuration, clamped 0-15 in Database.lua).
    local nowPlayingHeader = Section(content, "Now Playing", alphaHoverSlider, -16)
    local durationLabel = content:CreateFontString(nil, "OVERLAY")
    durationLabel:SetFontObject(SB.Fonts.HighlightSmall)
    durationLabel:SetPoint("TOPLEFT", nowPlayingHeader, "BOTTOMLEFT", 0, -8)
    durationLabel:SetText("Now Playing Highlight Duration")

    local durationSlider = SB.Theme.CreateSlider(content, 0, 15, 1, CONTENT_W - 140, function(value)
        SB.db.settings.announceDuration = math.floor(value + 0.5)
    end, function(value)
        return value == 0 and "0 (off)" or (value .. "s")
    end)
    durationSlider:SetPoint("TOPLEFT", durationLabel, "BOTTOMLEFT", 0, -10)
    durationSlider:SetValue(tonumber(SB.db.settings.announceDuration) or 3)
    durationSlider:Refresh()
    Help(durationSlider, "Now Playing Highlight Duration",
        "How long the Library keeps highlighting a sound after it plays, before the highlight clears. 0 turns the highlight off.")

    local textHeader = Section(content, "Text", durationSlider, -16)
    local miniFontBtn = BuildFontDropdown(content, "Mini Soundbook Font", textHeader, -8,
        function() return SB.db.settings.miniFont end,
        function(path)
            SB.db.settings.miniFont = path
            SB:RefreshAnnouncerFont()
        end)

    local miniFontScaleSlider = BuildFontScaleSlider(content, "Mini Soundbook Text Size", miniFontBtn, -14,
        function() return SB.db.settings.miniFontScale end,
        function(mult)
            SB.db.settings.miniFontScale = mult
            SB:RefreshAnnouncerFont()
        end)

    return miniFontScaleSlider
end

------------------------------------------------------------------------
-- Section 4: Library & Appearance
------------------------------------------------------------------------

local function BuildLibrarySection(content, topAnchor)
    local appearanceHeader = Section(content, "Main Soundbook Appearance", topAnchor, -4)
    local mainFontBtn = BuildFontDropdown(content, "Soundbook Font", appearanceHeader, -8,
        function() return SB.db.settings.mainFont end,
        function(path)
            SB.db.settings.mainFont = path
            SB:RefreshMainFont()
        end)

    local mainFontScaleSlider = BuildFontScaleSlider(content, "Soundbook Text Size", mainFontBtn, -14,
        function() return SB.db.settings.mainFontScale end,
        function(mult)
            SB.db.settings.mainFontScale = mult
            SB:RefreshMainFont()
        end)

    local minimapCheck = Checkbox(content, "Show Minimap Button", mainFontScaleSlider, 0, -16, function(checked)
        SB.db.ui.minimap.hide = not checked
        if SB.RefreshMinimapButton then SB:RefreshMinimapButton() end
    end)
    minimapCheck:SetChecked(not SB.db.ui.minimap.hide)

    -- Library - how category and Stammtisch sounds are ordered. Default
    -- is Popularity (community-wide Analytics play counts, most-played
    -- first); Alphabetical keeps Sounds.lua's own declaration order.
    -- Never touches the Favourites grid - those positions are always manual.
    local libraryHeader = Section(content, "Library", minimapCheck, -16)
    local sortOrderLabel = content:CreateFontString(nil, "OVERLAY")
    sortOrderLabel:SetFontObject(SB.Fonts.HighlightSmall)
    sortOrderLabel:SetPoint("TOPLEFT", libraryHeader, "BOTTOMLEFT", 0, -8)
    sortOrderLabel:SetText("Sound Order")

    local sortOrderDD = SB.Theme.CreateDropdown(content, CONTENT_W - 20, 22, 4)
    sortOrderDD.button:SetPoint("TOPLEFT", sortOrderLabel, "BOTTOMLEFT", 0, -6)
    sortOrderDD:SetOptions({
        { text = "Most Popular (community play counts)", value = "popularity" },
        { text = "Alphabetical", value = "alphabetical" },
    })
    sortOrderDD:SetValue(SB.db.settings.sortMode or "popularity")
    sortOrderDD:SetOnChange(function(value)
        SB.db.settings.sortMode = value
        if SB.InvalidateSoundOrderCache then SB.InvalidateSoundOrderCache() end
        if SB.RefreshMainWindow then SB:RefreshMainWindow() end
    end)
    Help(sortOrderDD.button, "Sound Order",
        "How category and Stammtisch sounds are ordered. Favourites are always manual regardless of this setting.")

    local categoriesHeader = Section(content, "Categories", sortOrderDD.button, -16)
    local lastAnchor = categoriesHeader
    for _, category in ipairs(SB.CATEGORIES) do
        lastAnchor = BuildCategoryRow(content, lastAnchor, category)
    end

    -- Window Layout - explicit requirement: reword to make its effect
    -- explicit (it only resets window positions/sizes) and communicate
    -- clearly that it never touches Favourites, sounds, keybindings,
    -- categories, or any other user content.
    local layoutHeader = Section(content, "Window Layout", lastAnchor, -16)
    local resetLayoutBtn = SB.Theme.CreateFlatButton(content, "Restore Window Layout", CONTENT_W - 20, 22)
    resetLayoutBtn:SetPoint("TOPLEFT", layoutHeader, "BOTTOMLEFT", 0, -8)
    resetLayoutBtn:SetScript("OnClick", function()
        SlashCmdList["SOUNDBOOK"]("reset")
    end)
    Help(resetLayoutBtn, "Restore Window Layout",
        "Resets the saved window positions and sizes only - Favourites, sounds, keybindings, categories, and every other setting are untouched.")

    local layoutHint = content:CreateFontString(nil, "OVERLAY")
    layoutHint:SetFontObject(SB.Fonts.DisableSmall)
    layoutHint:SetPoint("TOPLEFT", resetLayoutBtn, "BOTTOMLEFT", 0, -4)
    layoutHint:SetPoint("RIGHT", -20, 0)
    layoutHint:SetJustifyH("LEFT")
    layoutHint:SetWordWrap(true)
    layoutHint:SetText("Only resets window positions and sizes. Does not delete Favourites, sounds, keybindings, categories, or any other data.")
    layoutHint:SetTextColor(unpack(SB.Theme.TEXT_DIM))

    return layoutHint
end

------------------------------------------------------------------------
-- Section 5: Advanced
------------------------------------------------------------------------

-- Targeted correction round (explicit requirement): "Replay Introduction"
-- and "Latest Sound Updates" moved here from the old persistent footer,
-- joining the existing "Run Diagnostics" button as one primary action
-- area - three buttons, one per row, 8px vertical gap, each the full
-- available Advanced content width (CONTENT_W - 20, the same column
-- every other full-width Settings control already uses - never the old
-- footer's cramped half-width pairing) rather than a fixed narrow width.
-- Each button's own action is carried over completely unchanged.
local ACTION_BTN_GAP = 8

local function BuildAdvancedSection(content, topAnchor)
    local diagHeader = Section(content, "Diagnostics", topAnchor, -4)
    local debugCheck = Checkbox(content, "Debug Mode", diagHeader, 0, -8, function(checked)
        SB.db.settings.debug = checked
    end)
    debugCheck:SetChecked(SB.db.settings.debug)

    local actionsHeader = Section(content, "Actions", debugCheck, -16)

    local diagnosticsBtn = SB.Theme.CreateFlatButton(content, "Run Diagnostics", CONTENT_W - 20, 22)
    diagnosticsBtn:SetPoint("TOPLEFT", actionsHeader, "BOTTOMLEFT", 0, -8)
    diagnosticsBtn:SetScript("OnClick", function()
        SlashCmdList["SOUNDBOOK"]("doctor")
    end)
    Help(diagnosticsBtn, "Run Diagnostics", "Check Soundbook and print a short health report in chat.")

    local introBtn = SB.Theme.CreateSecondaryButton(content, "Replay Introduction", CONTENT_W - 20, 22)
    introBtn:SetPoint("TOPLEFT", diagnosticsBtn, "BOTTOMLEFT", 0, -ACTION_BTN_GAP)
    introBtn:SetScript("OnClick", function()
        SB.db.settings.introSeen = false
        if SB.ShowIntro then SB:ShowIntro() end
    end)
    Help(introBtn, "Replay Introduction", "Show the first-run Soundbook introduction again.")

    local updatesBtn = SB.Theme.CreateSecondaryButton(content, "Latest Sound Updates", CONTENT_W - 20, 22)
    updatesBtn:SetPoint("TOPLEFT", introBtn, "BOTTOMLEFT", 0, -ACTION_BTN_GAP)
    updatesBtn:SetScript("OnClick", function()
        if SB.ShowNewSoundsWindow then SB:ShowNewSoundsWindow() end
    end)
    Help(updatesBtn, "Latest Sound Updates", "See which sounds were added recently and try them out.")

    local versionText = content:CreateFontString(nil, "OVERLAY")
    versionText:SetFontObject(SB.Fonts.DisableSmall)
    versionText:SetPoint("TOPLEFT", updatesBtn, "BOTTOMLEFT", 0, -10)
    versionText:SetText("Soundbook v" .. tostring(SB.VERSION or "?"))
    versionText:SetTextColor(unpack(SB.Theme.TEXT_DIM))

    return versionText
end

------------------------------------------------------------------------
-- Tab strip
------------------------------------------------------------------------

-- UI/UX polish pass (explicit requirement, section 7: "Tabs should use a
-- shared state system with the rest of the UI: idle, hover, active,
-- disabled... equalize heights/padding and reduce the cramped feel") -
-- rebuilt on Theme.CreateTabButton, a genuine 4-state control, instead of
-- CreateFlatButton (only idle/hover/disabled) with a manually-toggled
-- underline bolted on: the previous "active" look WAS the same hover fill
-- CreateFlatButton already used for a transient mouse-over, so hovering a
-- DIFFERENT, inactive tab rendered identically to the real active one.
-- Targeted correction round: "all five tabs share the available inner
-- width evenly... 8px target gap between tab regions... consistent
-- height, target ~28px... no clipping at minimum Main-window width."
-- Each region's width is recomputed from the row's own live width (single
-- explicit-width-per-region layout, no fixed pixel guesses that could
-- clip at 560px), so five single-word labels always fit with equal
-- spacing regardless of window size.
local TAB_STRIP_H = 28
local TAB_STRIP_GAP = 8

local function BuildTabStrip(parent)
    local tabRow = CreateFrame("Frame", nil, parent)
    tabRow:SetHeight(TAB_STRIP_H)

    local function ApplySelection()
        for key, btn in pairs(sectionTabButtons) do
            btn:SetActive(key == currentSectionKey)
        end
    end

    local buttons = {}
    for _, entry in ipairs(SECTION_ORDER) do
        local btn = SB.Theme.CreateTabButton(tabRow, entry.label, 90, TAB_STRIP_H, entry.color)
        btn:SetScript("OnClick", function()
            SB:ShowSettingsSection(entry.key)
        end)
        sectionTabButtons[entry.key] = btn
        table.insert(buttons, btn)
    end

    local function LayoutTabs()
        local n = #buttons
        local totalW = tabRow:GetWidth() or (90 * n + TAB_STRIP_GAP * (n - 1))
        local regionW = math.max(1, (totalW - TAB_STRIP_GAP * (n - 1)) / n)
        for i, btn in ipairs(buttons) do
            btn:SetWidth(regionW)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", tabRow, "TOPLEFT", (i - 1) * (regionW + TAB_STRIP_GAP), 0)
        end
    end
    tabRow:SetScript("OnSizeChanged", LayoutTabs)
    LayoutTabs()

    tabRow.ApplySelection = ApplySelection
    return tabRow
end

------------------------------------------------------------------------
-- Orchestration
------------------------------------------------------------------------

local scroll, scrollChild

-- Shows exactly one section's content, hides the rest, resets that
-- section's own scroll position to the top (explicit requirement: each
-- section scrolls independently - switching tabs never leaves you
-- scrolled halfway down a DIFFERENT section), and re-fits the panel's
-- scrollable height to whichever section is now active.
function SB:ShowSettingsSection(key)
    if not sectionContents[key] then return end
    currentSectionKey = key
    for k, frame in pairs(sectionContents) do
        frame:SetShown(k == key)
    end
    local tabRow = panel and panel.tabRow
    if tabRow then tabRow.ApplySelection() end
    if scroll then scroll:SetVerticalScroll(0) end
    if SB.FitSettingsPanelHeight then SB:FitSettingsPanelHeight() end
end

-- Settings uses the exact same inner book page as the sound library. The
-- existing contentFrame owns that visible gold boundary and background;
-- Settings adds no second tinted overlay or competing frame of its own.
function SB.BuildSettingsPanel(mainFrame, contentFrame)
    if panel then return panel end

    panel = CreateFrame("Frame", "SoundbookSettingsPanel", mainFrame)
    panel:SetAllPoints(contentFrame)
    panel:SetFrameLevel(contentFrame:GetFrameLevel() + 20)
    if panel.SetClipsChildren then panel:SetClipsChildren(true) end
    panel:Hide()

    -- Same shared spacing system the rest of the polish pass uses (was a
    -- one-off 8/6/10 here) - "fits cleanly within the available width
    -- without clipping or colliding with frame elements" (explicit
    -- requirement, section 7).
    local L = SB.Theme.LAYOUT
    local tabRow = BuildTabStrip(panel)
    -- Targeted correction round (explicit requirement): the category
    -- strip's Y position must match exactly where the first Library row
    -- begins, not just "close to it" - anchored directly off `mainFrame`
    -- using the SAME already-computed pixel offset the Library's own
    -- content region uses (SB.LIBRARY_CONTENT_TOP_OFFSET, UI.lua),
    -- instead of trusting the panel's own multi-hop SetAllPoints chain
    -- (which runs through the header/Search/filter row - some of them
    -- Hidden, not just repositioned, while Settings is the active view).
    -- LEFT/RIGHT still come from `panel` itself (untouched, unaffected -
    -- panel's horizontal bounds were never in question).
    local topOffset = (SB.LIBRARY_CONTENT_TOP_OFFSET or 0) + L.GAP_S
    tabRow:SetPoint("LEFT", panel, "LEFT", L.GAP_S, 0)
    tabRow:SetPoint("TOP", mainFrame, "TOP", 0, -topOffset)
    tabRow:SetPoint("RIGHT", panel, "RIGHT", -L.GAP_S, 0)
    panel.tabRow = tabRow

    -- Targeted correction round (explicit requirement): the old
    -- persistent "Help & Information" footer is gone - Replay
    -- Introduction/Latest Sound Updates moved into Advanced (see
    -- BuildAdvancedSection above) - so the scrollable area now runs all
    -- the way to the panel's own bottom edge instead of stopping above a
    -- separate footer container. No empty footer/divider left behind.
    local sf = SB.Theme.CreateScrollFrame(panel)
    -- Same reasoning as the pre-restructure panel: `scrollChild` is the
    -- REAL scroll child WoW's ScrollFrame API owns - stays anchored at its
    -- default TOPLEFT and spans the full viewport width, or
    -- SetVerticalScroll's math breaks the moment it's actually scrolled
    -- (see UI.lua's RefreshLibraryImpl for the fuller writeup of this
    -- exact bug). Each section's own `content` frame (built below) is a
    -- separate plain child, fixed at CONTENT_W and horizontally centered
    -- WITHIN scrollChild, not the scroll child itself.
    scroll, scrollChild = sf.scroll, sf.content
    scroll:SetFrameLevel(panel:GetFrameLevel() + 5)
    scrollChild:SetFrameLevel(scroll:GetFrameLevel() + 1)
    scroll:SetPoint("TOPLEFT", tabRow, "BOTTOMLEFT", 0, -L.GAP_M)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -2, L.GAP_S)
    -- Provisional, corrected below by FitSettingsPanelHeight once real
    -- geometry is resolvable - same defensive pattern the pre-restructure
    -- single-page panel used (content:SetHeight(2000) "provisional,
    -- corrected below"), which this rewrite had dropped. ROOT CAUSE of a
    -- reported blank/empty Settings content area: SB:ShowSettingsSection
    -- runs once at the end of this very function, while `main` (and this
    -- panel, anchored to its content region) has never actually been
    -- shown/laid out yet - GetTop()/GetBottom() can legitimately return
    -- nil at that point, which made FitSettingsPanelHeight's own
    -- `if top and bottom then` guard silently skip ever calling SetHeight
    -- at all, leaving both scrollChild and every section's `content`
    -- frame at a brand-new frame's default height (effectively 0) -
    -- Shown was correctly true and every control inside was positioned
    -- correctly, but a zero-height frame inside a ScrollFrame renders as
    -- a blank page regardless. A generous provisional height here means
    -- the panel is never degenerate even if that first correction attempt
    -- can't resolve real geometry yet; the OnShow handler re-runs the fit
    -- (twice) once the panel is actually visible, when geometry reliably
    -- resolves, correcting it to the real content height.
    scrollChild:SetSize(1, 2000)

    for _, entry in ipairs(SECTION_ORDER) do
        local content = CreateFrame("Frame", nil, scrollChild)
        content:SetWidth(CONTENT_W)
        content:SetHeight(2000) -- provisional, see scrollChild's own comment above
        -- Same "+5" bias-cancel as the pre-restructure panel - scrollChild
        -- is deliberately 10px narrower than `scroll` (reserved for the
        -- thumb), which alone would leave content sitting ~5px left of
        -- scroll/panel's true centre; nudging right by that half-gap
        -- cancels it out.
        content:SetPoint("TOP", scrollChild, "TOP", 5, 0)
        content:SetFrameLevel(scrollChild:GetFrameLevel() + 1)
        content:Hide()

        local topAnchor = CreateFrame("Frame", nil, content)
        topAnchor:SetSize(1, 1)
        topAnchor:SetPoint("TOPLEFT", 4, -4)

        local bottom
        if entry.key == "playback" then
            bottom = BuildSoundPlaybackSection(content, topAnchor)
        elseif entry.key == "sharing" then
            bottom = BuildSharingSection(content, topAnchor)
        elseif entry.key == "mini" then
            bottom = BuildMiniSoundbookSection(content, topAnchor)
        elseif entry.key == "library" then
            bottom = BuildLibrarySection(content, topAnchor)
        elseif entry.key == "advanced" then
            bottom = BuildAdvancedSection(content, topAnchor)
        end

        sectionContents[entry.key] = content
        sectionBottomAnchor[entry.key] = bottom or topAnchor
    end

    currentSectionKey = currentSectionKey or SECTION_ORDER[1].key
    SB:ShowSettingsSection(currentSectionKey)

    -- Recomputes scrollChild's live width (needed for WoW's own
    -- SetVerticalScroll/thumb math to stay correct as the Main window
    -- resizes) and the CURRENTLY ACTIVE section's scrollable height from
    -- its own bottom-most control. panel:GetWidth() reflects
    -- SetAllPoints(contentFrame) immediately; scroll:GetWidth() is only a
    -- fallback for the rare case that's still 0/stale (before WoW's
    -- finished a layout pass on a freshly-shown ScrollFrame).
    function SB:FitSettingsPanelHeight()
        local panelW = panel:GetWidth()
        local scrollW = (panelW and panelW > 0) and (panelW - 18) or scroll:GetWidth()
        if scrollW and scrollW > 0 then
            scrollChild:SetWidth(math.max(1, scrollW - 10))
        end
        local content = sectionContents[currentSectionKey]
        local bottomEl = sectionBottomAnchor[currentSectionKey]
        if not (content and bottomEl) then return end
        local top = content:GetTop()
        local bottom = bottomEl:GetBottom()
        if top and bottom then
            -- Floored, not just computed directly - a transient bad
            -- reading (e.g. mid-layout-pass) producing a tiny/negative
            -- value must never shrink the panel to near-nothing; worst
            -- case is it stays too tall until the next correction, never
            -- too short to show its own content.
            local h = math.max(60, (top - bottom) + 24)
            content:SetHeight(h)
            scrollChild:SetHeight(h)
        end
    end

    panel:SetScript("OnShow", function()
        SB:FitSettingsPanelHeight()
        C_Timer.After(0.05, function()
            if panel:IsShown() then SB:FitSettingsPanelHeight() end
        end)
    end)

    return panel
end
