-- Settings.lua
-- The Settings page lives inside the Soundbook window itself (no separate
-- foreign-looking window). UI.lua shows/hides this panel when the Settings
-- tab (grouped in the compact right-side dock below the category tabs) is clicked.

local ADDON_NAME, SB = ...

-- The panel's actual usable width (scroll area minus its own margins/
-- scroll thumb - see BuildSettingsPanel) - controls below are sized
-- against this instead of arbitrary small pixel widths, so they actually
-- fill the column instead of leaving a big empty strip on the right.
-- Wide enough to use the expanded Settings view without turning every
-- control into a long edge-to-edge bar. The scroll content itself still
-- follows the live panel width, so this is a comfortable control measure,
-- not a second fixed window width.
local CONTENT_W = 450

local panel
local categoryNameBoxes = {}
local categoryIconTextures = {}
local matrixReceiveTiles = {}
local muteBtn, mute30Btn, mute60Btn
local countdownTicker

local CHECKBOX_HELP = {
    ["Show Minimap Button"] = "Show or hide the Soundbook shortcut at the minimap.",
    ["Allow overlapping sounds"] = "Allow a new sound to start before the previous one ends.",
    ["Allow Sounds while fights"] = "Permit Soundbook playback while your character is in combat.",
    ["Allow Sounds while boss encounter"] = "Permit Soundbook playback during active boss encounters.",
    ["Queue rate-limited remote sounds"] = "Keep valid incoming sounds briefly when they arrive too quickly.",
    ["Chat: received sound details"] = "Print sender, source and sound information for received playback.",
    ["Chat: blocked muted sounds"] = "Report attempts to play a sound that you muted locally.",
    ["Chat: delivery confirmations"] = "Show delivery confirmations returned by friends.",
    ["Show Favourites Window"] = "Show or hide the Mini Soundbook.",
    ["Lock Favourite Window"] = "Prevent moving and resizing the Mini Soundbook.",
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

-- Raid and Party are ONE row everywhere in this table now (explicit
-- request, reversed from an earlier "Send merged, Receive still separate"
-- version - "wir meinten doch, dass das dasselbe ist") - a single "RAID"
-- key covers both Send and Receive, labelled "Raid/Party" since it's a
-- static settings label (not a live indicator like the dropdowns/menus
-- elsewhere, which show whichever of the two you're actually in right
-- now - see SB.ResolveGroupChannel, Communication.lua). No separate PARTY
-- row/key exists anywhere in this file any more.
local MODE_LABELS = { FRIENDS = "Friends", RAID = "Raid/Party", GUILD = "Guild", DIRECT = "Direct" }
local RECEIVE_KEY = { FRIENDS = "receiveFriends", RAID = "receiveRaid", GUILD = "receiveGuild", DIRECT = "receiveDirect" }

-- Display order for the Send/Receive matrix below - explicit request:
-- Friends, Guild, Raid/Party, then Direct directly under it. Direct is
-- special: it has no Send column at all (see NO_SEND_ROW below) - there's
-- no "broadcast as Direct" concept, Direct-ness comes from HOW a sound is
-- sent (SendMenu's "to one specific person"), not a channel you opt into
-- broadcasting on. It only ever needs its own RECEIVE toggle, to separate
-- "a Direct-targeted send from anyone" from a plain Friends broadcast -
-- both travel as a WHISPER on the wire (see Communication.lua's
-- ReceiveAllowedForChannel).
local MATRIX_ROWS = { "FRIENDS", "GUILD", "RAID", "DIRECT" }

-- Rows with no Send checkbox at all - just a blank cell in that column.
local NO_SEND_ROW = { DIRECT = true }
local MATRIX_ROW_LABEL_W = 90
local MATRIX_HEADER_H, MATRIX_ROW_H, MATRIX_TILE_SIZE = 20, 26, 18

-- Replaces the old two separate "Broadcast sounds to:"/"Receive Sounds
-- from:" checkbox rows (same 4 names repeated twice, easy to lose track of
-- which row was which) with one table: rows = Friends/Guild/Raid/Party,
-- columns = Send/Receive, each cell its own independently clickable
-- Theme.CreateToggleTile - explicit request, click directly in the grid to
-- opt a group in/out of sending or receiving. Direct is a later addition,
-- a 5th row with a Receive column only (see NO_SEND_ROW above).
local function BuildChannelMatrix(parent, anchorTo)
    local header = parent:CreateFontString(nil, "OVERLAY")
    header:SetFontObject(SB.Fonts.HighlightSmall)
    header:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -18)
    header:SetText("Sounds - who to send to / receive from")

    local tableW = CONTENT_W - 20
    local cellW = (tableW - MATRIX_ROW_LABEL_W) / 2

    local grid = CreateFrame("Frame", nil, parent)
    grid:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -10)
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

        -- Alternating faint row background - purely cosmetic, makes a
        -- 4-row/2-column grid actually read as a table at a glance instead
        -- of a loose cluster of squares.
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
        -- Explicit request: row labels colour-coded per channel the same
        -- way as everywhere else (Core.lua's SB.CHANNEL_COLOR) - `mode`
        -- (FRIENDS/GUILD/RAID/PARTY/DIRECT) already matches its keys directly.
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
                "Include this channel when Soundbook sends to all enabled groups.")
        else
            -- No Send concept for this row (see NO_SEND_ROW above) - a
            -- faint dash instead of leaving the cell looking accidentally
            -- empty/broken next to the filled column above and below it.
            local dash = grid:CreateFontString(nil, "OVERLAY")
            dash:SetFontObject(SB.Fonts.HighlightSmall)
            dash:SetPoint("CENTER", grid, "TOPLEFT", MATRIX_ROW_LABEL_W + cellW / 2, rowCenterY)
            dash:SetText("-")
            dash:SetTextColor(SB.Theme.BORDER_DIM[1], SB.Theme.BORDER_DIM[2], SB.Theme.BORDER_DIM[3])
        end

        local receiveTile = SB.Theme.CreateToggleTile(grid, MATRIX_TILE_SIZE, function(checked)
            SB.db.settings[RECEIVE_KEY[mode]] = checked
            -- Explicit requirement: turning a receive channel off must
            -- also drop whatever's already waiting in the queue from it,
            -- not just block new arrivals going forward.
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
        -- Kept around so SB:RefreshChannelMatrix (below) can re-sync these
        -- 4 tiles when Mute/Unmute/Mute 30/60 changes the underlying
        -- receiveX flags out from under them.
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
-- it isn't, same pattern as AdminPanel.lua's own EnsureCountdownTicker.
-- Only needed at all while a TIMED mute (30/60) is actually counting down;
-- harmless and cheap to just let it run continuously whenever the panel's
-- open rather than tracking that more precisely.
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

-- Re-syncs the 4 Receive tiles and the 3 mute buttons' own labels with
-- whatever SB.db.settings.receiveMute/receiveX currently say - called on
-- RECEIVE_MUTE_CHANGED (a click, a timer firing, or the resolve-on-load
-- check, see Communication.lua) and every time the Settings tab is shown
-- (UI.lua's RefreshMainWindow), since this panel is otherwise only ever
-- built/populated once and never re-synced on its own.
function SB:RefreshChannelMatrix()
    if not panel then return end

    for mode, tile in pairs(matrixReceiveTiles) do
        tile:SetChecked(SB.db.settings[RECEIVE_KEY[mode]] and true or false)
    end

    muteBtn.label:SetText(SB:IsReceiveMuted() and "Unmute" or "Mute")

    local activeDuration = SB:GetReceiveMuteDurationMinutes()
    if activeDuration == 30 then
        mute30Btn.label:SetText(FormatCountdown(SB:GetReceiveMuteRemaining()) .. " left")
    else
        mute30Btn.label:SetText("Mute 30 min")
    end
    if activeDuration == 60 then
        mute60Btn.label:SetText(FormatCountdown(SB:GetReceiveMuteRemaining()) .. " left")
    else
        mute60Btn.label:SetText("Mute 60 min")
    end

    if activeDuration then
        EnsureCountdownTicker()
    end
end

-- 3 buttons directly under the Send/Receive table, side by side - explicit
-- request. Mute/Unmute toggles an INDEFINITE mute of all receiving
-- (clicking it while ANY mute - indefinite or timed - is active cancels
-- that mute early, restoring whatever was checked before, regardless of
-- which button started it); Mute 30/60 min each (re)start a TIMED mute of
-- that exact length, showing their own live countdown in place of their
-- normal label while it's the one currently running (SB:RefreshChannelMatrix
-- above) - clicking a duration button while a different mute is already
-- active simply replaces it with this one, per SB:StartReceiveMute's own
-- "only snapshot on the unmuted->muted transition" rule, so the ORIGINAL
-- pre-mute state is never lost by switching between them.
local function BuildMuteButtons(parent, anchorTo)
    local btnW = (CONTENT_W - 20 - 2 * 8) / 3
    local btnH = 22

    muteBtn = SB.Theme.CreateFlatButton(parent, "Mute", btnW, btnH)
    muteBtn:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -12)
    muteBtn:SetScript("OnClick", function()
        if SB:IsReceiveMuted() then
            SB:StopReceiveMute()
        else
            SB:StartReceiveMute(nil, nil)
        end
    end)
    Help(muteBtn, "Mute receiving", "Temporarily block or restore all incoming Soundbook sounds.")

    mute30Btn = SB.Theme.CreateFlatButton(parent, "Mute 30 min", btnW, btnH)
    mute30Btn:SetPoint("LEFT", muteBtn, "RIGHT", 8, 0)
    mute30Btn:SetScript("OnClick", function()
        SB:StartReceiveMute(30 * 60, 30)
    end)
    Help(mute30Btn, "Mute for 30 minutes", "Block all incoming Soundbook sounds for 30 minutes.")

    mute60Btn = SB.Theme.CreateFlatButton(parent, "Mute 60 min", btnW, btnH)
    mute60Btn:SetPoint("LEFT", mute30Btn, "RIGHT", 8, 0)
    mute60Btn:SetScript("OnClick", function()
        SB:StartReceiveMute(60 * 60, 60)
    end)
    Help(mute60Btn, "Mute for 60 minutes", "Block all incoming Soundbook sounds for 60 minutes.")

    SB:RefreshChannelMatrix()
    return muteBtn
end

SB:On("RECEIVE_MUTE_CHANGED", function()
    SB:RefreshChannelMatrix()
end)

-- Used to special-case "Default" ("Category Default Name" read oddly) -
-- gone since the category split (Core.lua's MigrateDB v17->v18): "Category
-- Legacy Name"/"Category German Memes Name" both read fine plainly.
local function CategoryLabel(category, suffix)
    return "Category " .. category .. " " .. suffix
end

local ICON_SLOT_SIZE = 28
local ICON_GAP = 8

local function BuildCategoryRow(parent, anchorTo, category)
    local label = parent:CreateFontString(nil, "OVERLAY")
    label:SetFontObject(SB.Fonts.Normal)
    label:SetPoint("TOPLEFT", anchorTo, "BOTTOMLEFT", 0, -14)
    label:SetText(CategoryLabel(category, "Name"))

    -- Icon sits to the LEFT of the name field, both on the same row below
    -- the label - not to the right of the label itself.
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
        end)
    end)
    Help(iconBtn, CategoryLabel(category, "Icon"), "Choose the icon shown on this category tab.")

    local editBox = SB.Theme.CreateInputBox(parent, CONTENT_W - 20 - ICON_SLOT_SIZE - ICON_GAP, 22)
    -- LEFT-to-RIGHT anchor (not TOPLEFT) so it vertically centers against
    -- the icon slot despite the different heights (28 vs 20).
    editBox:SetPoint("LEFT", iconBtn, "RIGHT", ICON_GAP, 0)
    editBox:SetMaxLetters(30)
    editBox:SetText(SB.db.categories[category].name)
    editBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    editBox:SetScript("OnEditFocusLost", function(self)
        local text = self:GetText()
        -- A named category (Legacy/German Memes - both already read fine
        -- as-is) falls back to its own name; a numeric one (1/2 - a bare
        -- "1" wouldn't read as a category name) falls back to "Category N".
        if text == "" then
            text = (type(category) == "string") and category or ("Category " .. category)
        end
        SB.db.categories[category].name = text
        SB:Fire("CATEGORY_CHANGED", category)
    end)
    categoryNameBoxes[category] = editBox

    -- Returned as the next row's anchor - the icon slot (not editBox),
    -- since it's at x=0 and taller than the editBox, so the next label
    -- both stays left-aligned (no drift) and never overlaps this row.
    return iconBtn
end

-- Settings uses the exact same inner book page as the sound library. The
-- existing contentFrame owns that visible gold boundary and background;
-- Settings adds no second tinted overlay or competing frame of its own.
function SB.BuildSettingsPanel(mainFrame, contentFrame)
    if panel then return panel end

    panel = CreateFrame("Frame", "SoundbookSettingsPanel", mainFrame)
    panel:SetAllPoints(contentFrame)
    -- The shared page texture remains behind Settings; its scroll child and
    -- controls render decisively above that artwork instead of being dimmed
    -- or partially covered by frames at the same level.
    panel:SetFrameLevel(contentFrame:GetFrameLevel() + 20)
    if panel.SetClipsChildren then panel:SetClipsChildren(true) end
    panel:Hide()

    local sf = SB.Theme.CreateScrollFrame(panel)
    -- `scrollChild` is the REAL scroll child WoW's ScrollFrame API owns -
    -- it must stay anchored at its default TOPLEFT and span the full
    -- viewport width, exactly as Theme.CreateScrollFrame set it up, or
    -- SetVerticalScroll's math (mouse wheel AND the drag thumb) breaks -
    -- explicit bugfix: an earlier version tried centering THIS frame
    -- directly (re-anchoring it to a horizontally-centered point every
    -- resize), which looked right until the first scroll - WoW's
    -- ScrollFrame silently re-snaps its scroll child back to a plain
    -- TOPLEFT anchor the moment SetVerticalScroll actually runs, undoing
    -- any custom horizontal anchor and leaving content flush-left instead.
    --
    -- `content` (below) is a NEW plain child frame, fixed at CONTENT_W and
    -- horizontally centered WITHIN scrollChild - not the scroll child
    -- itself, so none of that applies to it. Every control built for the
    -- rest of this function still uses the name `content` (shadowed here
    -- on purpose) and gets this centered frame for free, without every
    -- individual anchor needing to change.
    local scroll, scrollChild = sf.scroll, sf.content
    scroll:SetFrameLevel(panel:GetFrameLevel() + 5)
    scrollChild:SetFrameLevel(scroll:GetFrameLevel() + 1)
    -- The viewport and its draggable thumb end before the existing page
    -- frame on every side. Scrolled regions cannot enter the header or the
    -- decorative frame, even at maximum scroll.
    scroll:SetPoint("TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -10, 8)
    scrollChild:SetSize(1, 1) -- corrected below once scroll's real width is known

    local content = CreateFrame("Frame", nil, scrollChild)
    content:SetWidth(CONTENT_W)
    -- +5 explicit bugfix: scrollChild is deliberately 10px NARROWER than
    -- `scroll` (reserved for the thumb, see FitSettingsPanelHeight below)
    -- but that gap only ever comes off scrollChild's RIGHT edge - its own
    -- midpoint therefore already sits 5px left of scroll/panel's TRUE
    -- centre. Centering content on scrollChild's midpoint alone reproduced
    -- that same 5px leftward bias one level up ("leicht linksbündiger vom
    -- Zentrum"); nudging the anchor right by exactly that half-gap cancels
    -- it out. Anchoring to scrollChild (not scroll) directly is still
    -- required - only content on scrollChild's own anchor chain scrolls
    -- with it at all.
    content:SetPoint("TOP", scrollChild, "TOP", 5, 0)
    content:SetFrameLevel(scrollChild:GetFrameLevel() + 1)

    -- Very first thing in Settings, explicit request - reopens
    -- NewSoundsWindow.lua's "what's new" popup on demand (also lets you
    -- flip its own opt-out checkbox back on if you'd previously turned it
    -- off - there's no other way back into it once that's checked).
    local newSoundsBtn = SB.Theme.CreateFlatButton(content, "Latest Sound Updates", CONTENT_W - 20, 24)
    newSoundsBtn:SetPoint("TOPLEFT", 4, -4)
    newSoundsBtn:SetScript("OnClick", function()
        if SB.ShowNewSoundsWindow then SB:ShowNewSoundsWindow() end
    end)
    Help(newSoundsBtn, "Latest Sound Updates", "See which sounds were added recently and try them out.")

    local top = content:CreateFontString(nil, "OVERLAY")
    top:SetFontObject(SB.Fonts.Normal)
    top:SetPoint("TOPLEFT", newSoundsBtn, "BOTTOMLEFT", 0, -14)
    top:SetText("Sound Routing Matrix")
    top:SetTextColor(unpack(SB.Theme.GOLD))

    -- Right up front, no section header - the one thing most people
    -- immediately want to configure: what leaves your client and what
    -- you're willing to receive from others, per group, in one table -
    -- plus, directly under it, one-click ways to temporarily silence
    -- incoming sounds entirely without having to touch the table itself.
    local channelMatrix = BuildChannelMatrix(content, top)
    local muteButtonsRow = BuildMuteButtons(content, channelMatrix)

    -- GENERAL
    local generalHeader = Section(content, "General", muteButtonsRow, -16)

    local minimapCheck = Checkbox(content, "Show Minimap Button", generalHeader, 0, -8, function(checked)
        SB.db.ui.minimap.hide = not checked
        if SB.RefreshMinimapButton then SB:RefreshMinimapButton() end
    end)
    minimapCheck:SetChecked(not SB.db.ui.minimap.hide)

    local overlapCheck = Checkbox(content, "Allow overlapping sounds", minimapCheck, 0, -2, function(checked)
        SB.db.settings.allowOverlap = checked
    end)
    overlapCheck:SetChecked(SB.db.settings.allowOverlap)

    local combatCheck = Checkbox(content, "Allow Sounds while fights", overlapCheck, 0, -2, function(checked)
        SB.db.settings.allowInCombat = checked
    end)
    combatCheck:SetChecked(SB.db.settings.allowInCombat)

    local encounterCheck = Checkbox(content, "Allow Sounds while boss encounter", combatCheck, 0, -2, function(checked)
        SB.db.settings.allowInEncounter = checked
    end)
    encounterCheck:SetChecked(SB.db.settings.allowInEncounter)

    -- FAVOURITE KEYBINDS - custom in-addon key capture (Keybindings.lua),
    -- NOT Blizzard's native Key Bindings panel - that route (Bindings.xml)
    -- was tried first and abandoned after this specific client build
    -- confirmed, repeatedly, that it never recognizes a single <Binding>
    -- element at all. Click a slot, press a key combo (Escape clears it).
    -- All SB.MAX_FAVOURITES (20) slots are bindable now - collapsed by
    -- default (that many buttons is a lot of vertical space most players
    -- never need open), state remembered in SB.db.settings.
    -- favKeybindPanelCollapsed.
    local keybindHeader = Section(content, "Keybindings", encounterCheck, -16)
    local keybindToggle = SB.Theme.CreateFlatButton(content, "", CONTENT_W - 20, 22)
    keybindToggle:SetPoint("TOPLEFT", keybindHeader, "BOTTOMLEFT", 0, -8)
    Help(keybindToggle, "Favourite Keybindings",
        "Show or hide the key assignments for favourite positions 1-20.")

    local keybindHint = content:CreateFontString(nil, "OVERLAY")
    keybindHint:SetFontObject(SB.Fonts.DisableSmall)
    keybindHint:SetPoint("TOPLEFT", keybindToggle, "BOTTOMLEFT", 0, -6)
    keybindHint:SetPoint("RIGHT", -20, 0)
    keybindHint:SetJustifyH("LEFT")
    keybindHint:SetWordWrap(true)
    keybindHint:SetText("Click a slot, then press the key combo to bind it - Escape clears it.")

    local KB_COLS = 4
    local KB_ROWS = math.ceil(SB.KEYBIND_FAV_SLOT_COUNT / KB_COLS)
    local KB_GAP = 6
    local kbBtnW = (CONTENT_W - 20 - (KB_COLS - 1) * KB_GAP) / KB_COLS
    local kbBtnH = 22

    local keybindButtons = {}
    local rowAnchors = {}

    local function KeybindLabelText(slot)
        local key = SB:GetFavouriteHotkeyLabel(slot)
        return slot .. ": " .. (key or "-")
    end

    local function RefreshKeybindButtons()
        for slot, btn in pairs(keybindButtons) do
            if not btn.capturing then
                btn.label:SetText(KeybindLabelText(slot))
            end
        end
    end

    for slot = 1, SB.KEYBIND_FAV_SLOT_COUNT do
        local col = (slot - 1) % KB_COLS
        local row = math.floor((slot - 1) / KB_COLS)
        local btn = SB.Theme.CreateFlatButton(content, KeybindLabelText(slot), kbBtnW, kbBtnH)
        if col == 0 then
            if row == 0 then
                btn:SetPoint("TOPLEFT", keybindHint, "BOTTOMLEFT", 0, -10)
            else
                btn:SetPoint("TOPLEFT", rowAnchors[row - 1], "BOTTOMLEFT", 0, -6)
            end
            rowAnchors[row] = btn
        else
            btn:SetPoint("LEFT", keybindButtons[slot - 1], "RIGHT", KB_GAP, 0)
        end
        keybindButtons[slot] = btn
        Help(btn, "Favourite position " .. slot,
            "Click, then press a key combination. Press Escape to clear it.")

        local function StopCapture()
            btn.capturing = false
            btn:EnableKeyboard(false)
            btn:SetScript("OnKeyDown", nil)
            RefreshKeybindButtons()
        end
        btn.stopCapture = StopCapture

        btn:SetScript("OnClick", function()
            if btn.capturing then
                StopCapture()
                return
            end
            -- Only one slot captures at a time - cancel any other slot's
            -- in-progress capture first.
            for otherSlot, other in pairs(keybindButtons) do
                if otherSlot ~= slot and other.capturing then other.stopCapture() end
            end
            btn.capturing = true
            btn.label:SetText("Press a key...")
            btn:EnableKeyboard(true)
            btn:SetScript("OnKeyDown", function(_, key)
                -- Wait for a real key - a modifier pressed alone isn't a
                -- usable standalone binding.
                if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL"
                    or key == "LALT" or key == "RALT" or key == "UNKNOWN" then
                    return
                end
                StopCapture()
                if key == "ESCAPE" then
                    SB:SetFavouriteKeybind(slot, nil)
                    return
                end
                local parts = {}
                if IsControlKeyDown() then table.insert(parts, "CTRL") end
                if IsAltKeyDown() then table.insert(parts, "ALT") end
                if IsShiftKeyDown() then table.insert(parts, "SHIFT") end
                table.insert(parts, key)
                SB:SetFavouriteKeybind(slot, table.concat(parts, "-"))
            end)
        end)
    end

    SB:On("FAV_KEYBIND_CHANGED", RefreshKeybindButtons)

    -- Collapse/expand - the toggle button itself always stays visible and
    -- in the same spot; only the hint + 20 slot buttons show/hide. Anything
    -- BELOW this section (channelLabel etc.) re-anchors to whichever is
    -- currently the true bottom (the toggle when collapsed, the last row
    -- of buttons when expanded), so the rest of the page shifts up/down
    -- correctly instead of leaving a dead gap.
    local keybindBottomAnchor -- assigned below, read by channelLabel further down

    local function SetKeybindCollapsed(collapsed)
        SB.db.settings.favKeybindPanelCollapsed = collapsed and true or false
        keybindToggle.label:SetText(string.format("Favourite Keybinds (Slots 1-%d) %s",
            SB.KEYBIND_FAV_SLOT_COUNT, collapsed and "[+]" or "[-]"))
        keybindHint:SetShown(not collapsed)
        for _, btn in pairs(keybindButtons) do
            if collapsed and btn.capturing and btn.stopCapture then
                btn.stopCapture()
            end
            btn:SetShown(not collapsed)
        end
        keybindBottomAnchor = collapsed and keybindToggle or rowAnchors[KB_ROWS - 1]
        if SB.RelayoutSettingsAfterKeybinds then SB:RelayoutSettingsAfterKeybinds() end
    end
    keybindToggle:SetScript("OnClick", function()
        SetKeybindCollapsed(not SB.db.settings.favKeybindPanelCollapsed)
    end)
    SetKeybindCollapsed(SB.db.settings.favKeybindPanelCollapsed)

    -- Used by the centred Keybindings shortcut on the Favourites page:
    -- open this section, fit the scroll content, then bring its heading to
    -- the top of the visible Settings viewport.
    function SB:FocusFavouriteKeybindings()
        if not panel or not panel:IsShown() then return end
        SetKeybindCollapsed(false)
        C_Timer.After(0, function()
            if SB.FitSettingsPanelHeight then SB:FitSettingsPanelHeight() end
            local contentTop = content:GetTop()
            local headerTop = keybindHeader:GetTop()
            if contentTop and headerTop then
                local maxScroll = math.max(0, (content:GetHeight() or 0) - (scroll:GetHeight() or 0))
                scroll:SetVerticalScroll(math.max(0, math.min(maxScroll, contentTop - headerTop - 6)))
                if sf.UpdateThumb then sf.UpdateThumb() end
            end
        end)
    end

    -- Which of WoW's own sound channels playback routes through - controls
    -- which of the game's own volume sliders/mute toggles (Options ->
    -- Sound) affects Soundbook. WoW has no API to pick a Windows-level
    -- output DEVICE (speakers vs. headset, etc.) - only this in-game
    -- channel choice is possible.
    local playbackHeader = Section(content, "Playback", keybindBottomAnchor, -16)
    local channelLabel = content:CreateFontString(nil, "OVERLAY")
    channelLabel:SetFontObject(SB.Fonts.HighlightSmall)
    channelLabel:SetPoint("TOPLEFT", playbackHeader, "BOTTOMLEFT", 0, -8)
    channelLabel:SetText("Sound Output Channel")

    -- Re-anchors channelLabel (and, by the normal chain of relative
    -- anchors, everything below it) to whichever element is currently the
    -- true bottom of the Favourite Keybinds section - the toggle button
    -- itself while collapsed, or its last row of slot buttons while
    -- expanded - so collapsing/expanding shifts the rest of the page
    -- instead of leaving a dead gap or overlapping it.
    function SB:RelayoutSettingsAfterKeybinds()
        playbackHeader:ClearAllPoints()
        playbackHeader:SetPoint("TOPLEFT", keybindBottomAnchor, "BOTTOMLEFT", 0, -16)
        playbackHeader:SetPoint("RIGHT", content, "RIGHT", -20, 0)
        if SB.FitSettingsPanelHeight then SB:FitSettingsPanelHeight() end
    end

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

    -- Soundbook window, Edit window, and this Settings panel - the Mini
    -- Soundbook has its own separate font choice, in the Favourites
    -- Window section below.
    local mainFontBtn = BuildFontDropdown(content, "Soundbook Font", channelDD.button, -14,
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

    -- REMOTE PLAYBACK - who/what to broadcast/receive lives at the very
    -- top of the panel now (Broadcast sounds to / Receive Sounds from);
    -- this section just holds what's left over.
    local remoteHeader = Section(content, "Multiplayer & Notifications", mainFontScaleSlider, -16)

    local cooldownLabel = content:CreateFontString(nil, "OVERLAY")
    cooldownLabel:SetFontObject(SB.Fonts.HighlightSmall)
    cooldownLabel:SetPoint("TOPLEFT", remoteHeader, "BOTTOMLEFT", 0, -8)
    cooldownLabel:SetText("Remote Cooldown (seconds)")

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

    -- FIFO queue for incoming remote sounds beyond the rate limit, instead
    -- of discarding them outright - see Communication.lua's Anti-Spam
    -- section for the full mechanism/limits. Independent of Remote Cooldown
    -- above (that's the per-sound repeat cooldown; this is the newer
    -- per-sender/global flood control).
    local queueCheck = Checkbox(content, "Queue rate-limited remote sounds", cooldownBox, 0, -14, function(checked)
        SB.db.settings.soundQueueEnabled = checked
        -- Explicit requirement: turning the queue off must reliably drop
        -- whatever's still waiting in it, not leave those entries stranded
        -- (they'd never get processed again with queueing off anyway).
        if not checked and SB.ClearPendingQueue then
            SB:ClearPendingQueue()
        end
    end)
    queueCheck:SetChecked(SB.db.settings.soundQueueEnabled)

    local notifyMutedCheck = Checkbox(content, "Chat: received sound details", queueCheck, 0, -2, function(checked)
        SB.db.settings.notifyOnMuted = checked
    end)
    notifyMutedCheck:SetChecked(SB.db.settings.notifyOnMuted)

    -- Covers a per-sound mute only - a disabled "Receive Sounds from"
    -- channel is always fully silent (no playback, no queue, no
    -- notification at all), not affected by this setting.
    local notifyBlockedCheck = Checkbox(content, "Chat: blocked muted sounds", notifyMutedCheck, 0, -2, function(checked)
        SB.db.settings.notifyMutedAttempts = checked
    end)
    notifyBlockedCheck:SetChecked(SB.db.settings.notifyMutedAttempts)

    local notifyReceiptsCheck = Checkbox(content, "Chat: delivery confirmations", notifyBlockedCheck, 0, -2, function(checked)
        SB.db.settings.notifyFriendReceipts = checked
    end)
    notifyReceiptsCheck:SetChecked(SB.db.settings.notifyFriendReceipts)

    -- ANNOUNCER - every setting for the Announcer HUD (Announcer.lua,
    -- Soundbook 3.0's replacement for the old Mini Soundbook/Favourites
    -- window) lives together here, instead of being split between a
    -- "General" checkbox and an "Interface" section further down.
    local favHeader = Section(content, "Interface", notifyReceiptsCheck, -16)

    local showFavCheck = Checkbox(content, "Show Announcer", favHeader, 0, -8, function(checked)
        if checked then SB:ShowAnnouncer() else SB:HideAnnouncer() end
    end)
    showFavCheck:SetChecked(SB.db.ui.announcer.shown)

    local lockCheck = Checkbox(content, "Lock Interface", showFavCheck, 0, -2, function(checked)
        SB:SetAnnouncerLocked(checked)
    end)
    lockCheck:SetChecked(SB.db.ui.announcer.locked)

    -- Opacity, idle vs. hovering (both 0-100%).
    local alphaIdleLabel = content:CreateFontString(nil, "OVERLAY")
    alphaIdleLabel:SetFontObject(SB.Fonts.HighlightSmall)
    alphaIdleLabel:SetPoint("TOPLEFT", lockCheck, "BOTTOMLEFT", 0, -10)
    alphaIdleLabel:SetText("Alpha - Idle")

    local alphaIdleSlider = SB.Theme.CreateSlider(content, 0, 100, 1, CONTENT_W - 120, function(value)
        SB.db.ui.announcer.alphaIdle = math.floor(value + 0.5)
        SB:RefreshAnnouncerAlpha()
    end)
    alphaIdleSlider:SetPoint("TOPLEFT", alphaIdleLabel, "BOTTOMLEFT", 0, -10)
    alphaIdleSlider:SetValue(SB.db.ui.announcer.alphaIdle)
    alphaIdleSlider:Refresh()
    Help(alphaIdleSlider, "Alpha - Idle", "Set the Announcer's opacity while the mouse is away and no sound is playing.")

    local alphaHoverLabel = content:CreateFontString(nil, "OVERLAY")
    alphaHoverLabel:SetFontObject(SB.Fonts.HighlightSmall)
    alphaHoverLabel:SetPoint("TOPLEFT", alphaIdleSlider, "BOTTOMLEFT", 0, -14)
    alphaHoverLabel:SetText("Alpha - Hover")

    local alphaHoverSlider = SB.Theme.CreateSlider(content, 0, 100, 1, CONTENT_W - 120, function(value)
        SB.db.ui.announcer.alphaHover = math.floor(value + 0.5)
        SB:RefreshAnnouncerAlpha()
    end)
    alphaHoverSlider:SetPoint("TOPLEFT", alphaHoverLabel, "BOTTOMLEFT", 0, -10)
    alphaHoverSlider:SetValue(SB.db.ui.announcer.alphaHover)
    alphaHoverSlider:Refresh()
    Help(alphaHoverSlider, "Alpha - Hover", "Set the Announcer's opacity while the mouse is over it.")

    -- Announcement Duration no longer drives the Announcer (which now
    -- follows the sound's real playback duration/progress instead - see
    -- Announcer.lua) - the setting itself is kept in SavedVariables
    -- untouched (3.0 spec section 50), just no longer exposed here.

    local miniFontBtn = BuildFontDropdown(content, "Announcer Font", alphaHoverSlider, -14,
        function() return SB.db.settings.miniFont end,
        function(path)
            SB.db.settings.miniFont = path
            SB:RefreshAnnouncerFont()
        end)

    local miniFontScaleSlider = BuildFontScaleSlider(content, "Announcer Text Size", miniFontBtn, -14,
        function() return SB.db.settings.miniFontScale end,
        function(mult)
            SB.db.settings.miniFontScale = mult
            SB:RefreshAnnouncerFont()
        end)

    -- Default Output Channel used to live here - moved out to the main
    -- Soundbook window itself (top-left, next to the search box), always
    -- visible on every sound tab instead of buried in Settings - see
    -- UI.lua's BuildMainFrame/RefreshMainWindow. SB.ComputeOutputTargetOptions
    -- (Communication.lua) is what both that dropdown and EditWindow.lua's
    -- per-sound macro "Output" dropdown share.

    -- Sound Order - how category and Stammtisch
    -- are ordered. Default is Popularity (community-wide Analytics play
    -- counts, most-played first); Alphabetical keeps Sounds.lua's own
    -- declaration order. Never touches the Favourites grid (see
    -- UI.lua's GetTabSoundList) - those positions are always manual.
    local sortOrderLabel = content:CreateFontString(nil, "OVERLAY")
    sortOrderLabel:SetFontObject(SB.Fonts.HighlightSmall)
    sortOrderLabel:SetPoint("TOPLEFT", miniFontScaleSlider, "BOTTOMLEFT", 0, -14)
    sortOrderLabel:SetText("Sound Order")

    local sortOrderDD = SB.Theme.CreateDropdown(content, CONTENT_W - 20, 22, 4)
    sortOrderDD.button:SetPoint("TOPLEFT", sortOrderLabel, "BOTTOMLEFT", 0, -6)
    sortOrderDD:SetOptions({
        { text = "Popularity (most-played first)", value = "popularity" },
        { text = "Alphabetical", value = "alphabetical" },
    })
    sortOrderDD:SetValue(SB.db.settings.sortMode or "popularity")
    sortOrderDD:SetOnChange(function(value)
        SB.db.settings.sortMode = value
        -- A deliberate setting change should apply right away (unlike the
        -- "stay stable while just looking at the book" rule that otherwise
        -- holds the sorted order fixed - see UI.lua's sortedListCache).
        if SB.InvalidateSoundOrderCache then SB.InvalidateSoundOrderCache() end
        if SB.RefreshMainWindow then SB:RefreshMainWindow() end
    end)
    Help(sortOrderDD.button, "Sound Order",
        "How category and Stammtisch sounds are ordered. Popularity uses community-wide Analytics play counts; Favourites are always manual regardless of this setting.")

    -- CATEGORIES
    local categoriesHeader = Section(content, "Categories", sortOrderDD.button, -16)
    local lastAnchor = categoriesHeader
    for _, category in ipairs(SB.CATEGORIES) do
        lastAnchor = BuildCategoryRow(content, lastAnchor, category)
    end

    -- ADVANCED / DEBUG
    -- No visible Analytics opt-out here by design (explicit request): the
    -- community-wide tag system (Trending/Popular/Legendary/...) depends on
    -- a shared data pool, and a prominent toggle invites players to switch
    -- it off individually, thinning that pool for everyone. The underlying
    -- SB:SetAnalyticsEnabled/`/sb analytics on|off` escape hatch still
    -- exists for a player who deliberately wants out (see Analytics.lua).
    local debugHeader = Section(content, "Advanced / Debug", lastAnchor, -16)
    local debugCheck = Checkbox(content, "Debug Mode", debugHeader, 0, -8, function(checked)
        SB.db.settings.debug = checked
    end)
    debugCheck:SetChecked(SB.db.settings.debug)

    -- Four utility actions in a clean 2x2 grid. History shares the same
    -- window opened by /sb history.
    local utilityGap = 8
    local utilityBtnW = (CONTENT_W - 20 - utilityGap) / 2
    local restartIntroBtn = SB.Theme.CreateFlatButton(content, "Restart Intro", utilityBtnW, 22)
    restartIntroBtn:SetPoint("TOPLEFT", debugCheck, "BOTTOMLEFT", 0, -10)
    restartIntroBtn:SetScript("OnClick", function()
        SB.db.settings.introSeen = false
        if SB.ShowIntro then SB:ShowIntro() end
    end)
    Help(restartIntroBtn, "Restart Intro", "Show the first-run Soundbook introduction again.")

    local diagnosticsBtn = SB.Theme.CreateFlatButton(content, "Run Diagnostics", utilityBtnW, 22)
    diagnosticsBtn:SetPoint("LEFT", restartIntroBtn, "RIGHT", utilityGap, 0)
    diagnosticsBtn:SetScript("OnClick", function()
        SlashCmdList["SOUNDBOOK"]("doctor")
    end)
    Help(diagnosticsBtn, "Run Diagnostics", "Check Soundbook and print a short health report in chat.")

    local historyBtn = SB.Theme.CreateFlatButton(content, "Sound History", utilityBtnW, 22)
    historyBtn:SetPoint("TOPLEFT", restartIntroBtn, "BOTTOMLEFT", 0, -utilityGap)
    historyBtn:SetScript("OnClick", function()
        if SB.ShowHistoryWindow then SB:ShowHistoryWindow() end
    end)
    Help(historyBtn, "Sound History", "Show the last 10 successfully received sounds.")

    local resetLayoutBtn = SB.Theme.CreateFlatButton(content, "Reset Window Layout", utilityBtnW, 22)
    resetLayoutBtn:SetPoint("LEFT", historyBtn, "RIGHT", utilityGap, 0)
    resetLayoutBtn:SetScript("OnClick", function()
        SlashCmdList["SOUNDBOOK"]("reset")
    end)
    Help(resetLayoutBtn, "Reset Window Layout", "Restore the saved Soundbook window positions and sizes.")

    content:SetHeight(2000) -- provisional, corrected below

    -- Named (not just inline in OnShow) so SB:RelayoutSettingsAfterKeybinds
    -- - defined EARLIER in this function, before diagnosticsBtn exists yet -
    -- can also call it via the same late-binding guarded-call pattern used
    -- throughout this addon (a plain SB.-table lookup at call time, not a
    -- lexical closure, so definition order doesn't matter). Needed so
    -- toggling the Favourite Keybinds section while Settings is already
    -- open immediately re-fits the scrollable height too, not just shifts
    -- what's visually below it - otherwise expanding it while already open
    -- could leave the newly-revealed buttons clipped outside the old
    -- (smaller, collapsed-era) scroll height.
    function SB:FitSettingsPanelHeight()
        -- scrollChild (the REAL scroll child) always matches the current
        -- viewport width - required for WoW's own SetVerticalScroll/thumb
        -- math (Theme.lua) to stay correct as the main window resizes; see
        -- scrollChild's own comment above for why this can't just be
        -- centered directly. `content` (the actual settings controls) stays
        -- a fixed CONTENT_W and simply rides along, centered, since it's
        -- anchored to scrollChild's own TOP (which recomputes on its own
        -- as scrollChild's width changes) rather than to scroll directly.
        --
        -- Explicit bugfix: scroll:GetWidth() can still read 0/stale right
        -- when the panel first shows (before WoW has finished a layout
        -- pass on the freshly-shown ScrollFrame), which used to leave
        -- everything centred on whatever width happened to be live at
        -- OnShow - correct only after some LATER resize finally saw a real
        -- width. panel:GetWidth() is not itself a ScrollFrame and reflects
        -- SetAllPoints(contentFrame) immediately, so it's used first;
        -- scroll:GetWidth() only as a fallback if that's somehow unset too.
        local panelW = panel:GetWidth()
        local scrollW = (panelW and panelW > 0) and (panelW - 18) or scroll:GetWidth()
        if scrollW and scrollW > 0 then
            scrollChild:SetWidth(math.max(1, scrollW - 10))
        end
        local top = content:GetTop()
        local bottom = resetLayoutBtn:GetBottom()
        if top and bottom then
            local h = (top - bottom) + 32
            content:SetHeight(h)
            scrollChild:SetHeight(h)
        end
    end

    -- Same width-not-ready-yet timing gap as above, belt-and-suspenders:
    -- one deferred re-fit shortly after the panel first shows, in case
    -- even panel:GetWidth() wasn't final at that exact instant.
    panel:SetScript("OnShow", function()
        SB:FitSettingsPanelHeight()
        C_Timer.After(0.05, function()
            if panel:IsShown() then SB:FitSettingsPanelHeight() end
        end)
    end)

    return panel
end
