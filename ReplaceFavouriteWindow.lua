-- ReplaceFavouriteWindow.lua
-- The New Sounds window's "Add Favourite" button, clicked while all 20
-- Favourite slots are already occupied, opens this modal instead of only
-- reporting the failure to chat (NewSoundsWindow.lua checks SB:
-- GetFavouriteCount() itself before ever calling SB:AddFavourite, so that
-- chat-only failure path is never reached from here). Shows all 20 slots
-- as a fixed 5x4 grid in slot order; picking one replaces ONLY that slot's
-- sound - never moves, hides, or reorders any other slot, and never
-- touches that slot's own keybind (keyed by slot number in Keybindings.lua,
-- entirely independent of which sound occupies it).

local ADDON_NAME, SB = ...

local COLUMNS, ROWS = 5, 4
local CELL_W, CELL_H = 74, 64
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

    local icon = cell:CreateTexture(nil, "ARTWORK")
    icon:SetSize(28, 28)
    icon:SetPoint("TOP", 0, -6)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    cell.icon = icon

    local slotLabel = cell:CreateFontString(nil, "OVERLAY")
    slotLabel:SetFontObject(SB.Fonts.DisableSmall)
    slotLabel:SetPoint("TOP", icon, "BOTTOM", 0, -2)
    slotLabel:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    cell.slotLabel = slotLabel

    local keyLabel = cell:CreateFontString(nil, "OVERLAY")
    keyLabel:SetFontObject(SB.Fonts.DisableSmall)
    keyLabel:SetPoint("TOP", slotLabel, "BOTTOM", 0, -1)
    keyLabel:SetTextColor(unpack(SB.Theme.GOLD))
    cell.keyLabel = keyLabel

    local highlight = cell:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(SB.Theme.ACCENT[1], SB.Theme.ACCENT[2], SB.Theme.ACCENT[3], 0.16)
    highlight:SetBlendMode("ADD")

    cell:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Slot " .. self.slot, 1, 0.82, 0)
        if self.slotSoundID then
            GameTooltip:AddLine(SB:GetSoundDisplayName(self.slotSoundID), 0.86, 0.90, 0.96)
        end
        local key = SB:GetFavouriteHotkeyLabel(self.slot)
        if key then
            GameTooltip:AddLine("Keybind: " .. key, 0.86, 0.90, 0.96)
        end
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
        cell.slotLabel:SetText(tostring(slot))
        if soundID and SB.registry[soundID] then
            cell.icon:SetTexture(SB:GetSoundIcon(soundID))
            cell.icon:Show()
        else
            cell.icon:Hide()
        end
        local key = SB:GetFavouriteHotkeyLabel(slot)
        cell.keyLabel:SetText(key or "")
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
