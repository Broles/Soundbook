-- ReplaceFavouriteWindow.lua
-- The New Sounds window's "Add Favourite" button, clicked while all 20
-- Favourite slots are already occupied, opens this modal instead of only
-- reporting the failure to chat (NewSoundsWindow.lua checks SB:
-- GetFavouriteCount() itself before ever calling SB:AddFavourite, so that
-- chat-only failure path is never reached from here). Shows all 20 slots
-- as a fixed 4x5 grid in slot order; picking one replaces ONLY that slot's
-- sound - never moves, hides, or reorders any other slot, and never
-- touches that slot's own keybind (keyed by slot number in Keybindings.lua,
-- entirely independent of which sound occupies it).
--
-- Explicit requirement (round 2): identify each cell by icon + sound name
-- only - no slot number, no keybind, anywhere in the grid or its hover
-- tooltip. `cell.slot` still exists as internal state (SB:ReplaceFavourite
-- needs to know which slot a click targets), it's just never rendered.

local ADDON_NAME, SB = ...

local COLUMNS, ROWS = 4, 5
local ICON_SIZE = 30
local CELL_W, CELL_H = 90, 70
local CELL_GAP = 8
local CONTENT_MARGIN = 20
local GRID_W = COLUMNS * CELL_W + (COLUMNS - 1) * CELL_GAP
local WINDOW_W = GRID_W + CONTENT_MARGIN * 2

local modalBlocker
local win
local cells = {}
local pendingSoundID

local function BuildCell(index)
    local cell = SB.CreateFrame("Button", nil, win.gridFrame)
    cell:SetSize(CELL_W, CELL_H)
    cell:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    cell:SetBackdropColor(0.01, 0.03, 0.07, 0.9)
    cell:SetBackdropBorderColor(unpack(SB.Theme.GOLD_DIM))

    -- Icon visually dominant, sitting above the name - explicit requirement,
    -- identify the sound by icon + name, never by slot number.
    local icon = cell:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("TOP", 0, -7)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    cell.icon = icon

    -- Centered, up to 2 lines, constrained to the cell's own width so a
    -- long name can never overlap a neighbouring cell - SetMaxLines(2)
    -- (a real FontString API on every client this addon targets) both
    -- caps the wrap at 2 lines AND appends the "..." ellipsis itself when
    -- a name still doesn't fit, so no separate manual truncation is
    -- needed. The mock harness stubs SetMaxLines as a no-op (nothing to
    -- assert on wrap/ellipsis rendering itself), same treatment as its
    -- existing SetWordWrap/SetJustifyH stubs.
    local nameText = cell:CreateFontString(nil, "OVERLAY")
    nameText:SetFontObject(SB.Fonts.HighlightSmall)
    nameText:SetPoint("TOP", icon, "BOTTOM", 0, -4)
    nameText:SetWidth(CELL_W - 8)
    nameText:SetJustifyH("CENTER")
    nameText:SetWordWrap(true)
    if nameText.SetMaxLines then nameText:SetMaxLines(2) end
    nameText:SetTextColor(unpack(SB.Theme.TEXT))
    cell.nameText = nameText

    local highlight = cell:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(SB.Theme.ACCENT[1], SB.Theme.ACCENT[2], SB.Theme.ACCENT[3], 0.16)
    highlight:SetBlendMode("ADD")

    -- Full, untruncated name only - explicit requirement, no slot number
    -- or keybind anywhere in the grid OR its hover state. Still useful
    -- when the 2-line cap above has ellipsized a long name.
    cell:SetScript("OnEnter", function(self)
        if not self.slotSoundID then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(SB:GetSoundDisplayName(self.slotSoundID), 1, 0.82, 0)
        GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Selecting the slot IS the confirmation (explicit requirement - "do
    -- not add another confirmation after the user selects a replacement
    -- slot"). SB:ReplaceFavourite is the one function that performs the
    -- swap (Favorites.lua) - no favourite data is touched here directly.
    cell:SetScript("OnClick", function(self)
        if not pendingSoundID then return end
        SB:ReplaceFavourite(self.slot, pendingSoundID)
        win:Hide()
    end)

    cells[index] = cell
    return cell
end

local function LayoutGrid()
    for slot = 1, SB.MAX_FAVOURITES do
        local cell = cells[slot] or BuildCell(slot)
        local col = (slot - 1) % COLUMNS
        local row = math.floor((slot - 1) / COLUMNS)
        cell:ClearAllPoints()
        cell:SetPoint("TOPLEFT", col * (CELL_W + CELL_GAP), -row * (CELL_H + CELL_GAP))
    end
end

local function PopulateGrid()
    local favourites = SB:GetFavourites()
    for slot = 1, SB.MAX_FAVOURITES do
        local cell = cells[slot]
        local soundID = favourites[slot]
        cell.slot = slot
        cell.slotSoundID = soundID
        if soundID and SB.registry[soundID] then
            cell.icon:SetTexture(SB:GetSoundIcon(soundID))
            cell.icon:Show()
            cell.nameText:SetText(SB:GetSoundDisplayName(soundID))
        else
            cell.icon:Hide()
            cell.nameText:SetText("")
        end
    end
end

local function BuildWindow()
    if win then return win end

    modalBlocker = CreateFrame("Button", nil, UIParent)
    modalBlocker:SetAllPoints(UIParent)
    modalBlocker:EnableMouse(true)
    modalBlocker:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local shade = modalBlocker:CreateTexture(nil, "BACKGROUND")
    shade:SetAllPoints()
    shade:SetColorTexture(0, 0, 0, 0)
    modalBlocker:Hide()

    -- Clicking the transparent area outside this window is Cancel -
    -- explicit requirement: "clicking outside the modal must not
    -- accidentally replace anything." The window itself sits above this
    -- blocker, so clicks inside it are unaffected.
    modalBlocker:SetScript("OnClick", function()
        if win and win:IsShown() then win:Hide() end
    end)

    win = SB.CreateFrame("Frame", "SoundbookReplaceFavouriteWindow", UIParent)
    win:SetSize(WINDOW_W, 60 + 22 + 30 + (ROWS * CELL_H + (ROWS - 1) * CELL_GAP) + 66)
    win:SetFrameStrata("DIALOG")
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:SetClampedToScreen(true)
    win:SetToplevel(true)
    SB.Theme.Panel(win)
    win:Hide()
    tinsert(UISpecialFrames, "SoundbookReplaceFavouriteWindow") -- Escape key closes it

    SB.Theme.CreateHeader(win, "Favourites are full", 52)

    local closeBtn = SB.Theme.CreateCloseGlyph(win, 18)
    closeBtn:SetPoint("TOPRIGHT", -8, -8)
    closeBtn:SetScript("OnClick", function() win:Hide() end)

    local subtitle = win:CreateFontString(nil, "OVERLAY")
    subtitle:SetFontObject(SB.Fonts.HighlightSmall)
    subtitle:SetPoint("TOP", 0, -62)
    subtitle:SetText("Choose a Favourite to replace with:")
    subtitle:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    win.subtitle = subtitle

    -- Selected sound line - "<icon> <new sound display name>".
    local selectedRow = SB.CreateFrame("Frame", nil, win)
    selectedRow:SetPoint("TOP", subtitle, "BOTTOM", 0, -8)
    selectedRow:SetSize(GRID_W, 22)
    local selIconSlot = SB.Theme.CreateIconSlot(selectedRow, 20)
    selIconSlot:SetPoint("LEFT", (GRID_W - 160) / 2, 0)
    win.selectedIcon = selIconSlot.texture
    local selName = selectedRow:CreateFontString(nil, "OVERLAY")
    selName:SetFontObject(SB.Fonts.Highlight)
    selName:SetPoint("LEFT", selIconSlot, "RIGHT", 8, 0)
    selName:SetTextColor(unpack(SB.Theme.TEXT))
    win.selectedName = selName

    local gridFrame = SB.CreateFrame("Frame", nil, win)
    gridFrame:SetPoint("TOP", selectedRow, "BOTTOM", 0, -10)
    gridFrame:SetSize(GRID_W, ROWS * CELL_H + (ROWS - 1) * CELL_GAP)
    win.gridFrame = gridFrame
    LayoutGrid()

    local cancelBtn = SB.Theme.CreateSecondaryButton(win, "Cancel", 120, 24)
    cancelBtn:SetPoint("BOTTOM", 0, 16)
    cancelBtn:SetScript("OnClick", function() win:Hide() end)

    win:SetScript("OnShow", function() modalBlocker:Show() end)
    win:SetScript("OnHide", function()
        modalBlocker:Hide()
        pendingSoundID = nil
    end)

    return win
end

-- Opens above the New Sounds window (explicit requirement) - same strata,
-- a frame level computed from its CURRENT level rather than a fixed guess
-- (same pattern IconPicker.lua already uses to open above Edit Sound),
-- centred on it. Falls back to centring on UIParent if New Sounds isn't
-- open for some other reason.
function SB:ShowReplaceFavouriteWindow(soundID)
    if not (soundID and SB.registry[soundID]) then return end
    BuildWindow()
    pendingSoundID = soundID
    win.selectedIcon:SetTexture(SB:GetSoundIcon(soundID))
    win.selectedName:SetText(SB:GetSoundDisplayName(soundID))
    PopulateGrid()

    local newSoundsWin = _G.SoundbookNewSoundsWindow
    win:ClearAllPoints()
    modalBlocker:ClearAllPoints()
    modalBlocker:SetAllPoints(UIParent)
    if newSoundsWin and newSoundsWin:IsShown() then
        win:SetFrameStrata(newSoundsWin:GetFrameStrata())
        modalBlocker:SetFrameStrata(newSoundsWin:GetFrameStrata())
        modalBlocker:SetFrameLevel((newSoundsWin:GetFrameLevel() or 1) + 5)
        win:SetFrameLevel((newSoundsWin:GetFrameLevel() or 1) + 10)
        win:SetPoint("CENTER", newSoundsWin, "CENTER")
    else
        win:SetFrameStrata("DIALOG")
        modalBlocker:SetFrameStrata("DIALOG")
        modalBlocker:SetFrameLevel(1)
        win:SetFrameLevel(10)
        win:SetPoint("CENTER", UIParent, "CENTER")
    end

    win:Show()
end
