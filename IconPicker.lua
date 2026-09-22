-- IconPicker.lua
-- Icon list resolution (GetMacroIcons compatibility) plus a reusable
-- scrollable icon grid widget. SB.CreateIconGrid(...) embeds a grid
-- directly into any parent frame (used inline by EditWindow.lua, matching
-- Blizzard's own macro window where the icon grid lives in the same
-- window as the name field, not a separate popup). SB.OpenIconPicker(...)
-- wraps the same grid in its own small popup, for the one remaining place
-- that still wants a separate window: picking a Category's icon in Settings.

local ADDON_NAME, SB = ...

-- GetMacroIcons() has shipped two incompatible shapes across client builds:
--   old-style: many string return values, e.g. "INV_Misc_QuestionMark", ...
--   new-style: ONE return value that is itself a table of numeric file IDs
-- Wrapping the raw call in `{ GetMacroIcons() }` therefore sometimes yields
-- an array of strings/numbers directly, and sometimes an array containing a
-- single nested table - this flattens either shape into one flat list of
-- entries, each either a number (usable directly as a texture file ID) or a
-- string (a short icon name that needs "Interface\Icons\" prefixed to it).
local function GetFlatIconList()
    local raw = { GetMacroIcons() }
    local flat = {}
    for _, entry in ipairs(raw) do
        if type(entry) == "table" then
            for _, inner in ipairs(entry) do
                table.insert(flat, inner)
            end
        elseif type(entry) == "number" or type(entry) == "string" then
            table.insert(flat, entry)
        end
    end
    return flat
end

local function ResolveIcon(entry)
    if type(entry) == "number" then
        return entry, ("Icon #%d"):format(entry) -- numeric file ID: usable as-is
    elseif type(entry) == "string" then
        return "Interface\\Icons\\" .. entry, entry
    end
    return nil, nil
end

------------------------------------------------------------------------
-- Reusable embeddable grid
------------------------------------------------------------------------

-- opts = { columns, visibleRows, iconSize, iconPad, onSelect(iconPath) }
-- Returns the container frame (a ScrollFrame's parent wrapper); caller is
-- responsible for sizing/positioning that returned frame within its own
-- layout. The container has a fixed height of visibleRows rows; content
-- taller than that scrolls.
function SB.CreateIconGrid(parent, opts)
    local preferredColumns = opts.columns or 8
    local columns    = preferredColumns
    local visibleRows = opts.visibleRows or 4
    local iconSize   = opts.iconSize or 28
    local iconPad    = opts.iconPad or 3
    local onSelect   = opts.onSelect

    local container = SB.CreateFrame("Frame", nil, parent)
    container:SetHeight(visibleRows * (iconSize + iconPad))
    container:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    container:SetBackdropColor(0.008, 0.025, 0.055, 0.92)
    container:SetBackdropBorderColor(unpack(SB.Theme.GOLD_DIM))

    -- Same thin accent-coloured, draggable scroll thumb as the Settings
    -- panel (Theme.CreateScrollFrame) instead of Blizzard's stock grey
    -- up/down-button scrollbar - mouse wheel and thumb-drag both work and
    -- always agree, consistent with every other scroll area in this addon.
    local sf = SB.Theme.CreateScrollFrame(container)
    local scroll, content = sf.scroll, sf.content
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -10, 0) -- room reserved so the thumb never sits on the icons

    local contentW = preferredColumns * (iconSize + iconPad)
    content:SetSize(contentW, 1)

    container.contentW = contentW

    -- Flat, resolved icon list (path+name), rebuilt on every Populate() -
    -- separate from the pooled BUTTONS below, which no longer map 1:1 to
    -- this list.
    local icons = {}

    -- Virtualized button pool - explicit requirement: only as many real
    -- Button frames as the visible area (plus a small scroll buffer) need,
    -- reused/retextured/repositioned as the list scrolls, instead of one
    -- live frame per icon. GetMacroIcons() can return several hundred to
    -- over a thousand entries on a modern client - that many permanently-
    -- alive frames for something that's almost entirely off-screen at any
    -- given moment is real, avoidable overhead this addon doesn't need.
    local POOL_BUFFER_ROWS = 2
    local pool = {}

    local function EnsurePoolButtons()
        local need = (visibleRows + POOL_BUFFER_ROWS) * columns
        for i = #pool + 1, need do
            local btn = SB.CreateFrame("Button", nil, content)
            btn:SetSize(iconSize, iconSize)
            btn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
            btn:SetBackdropColor(0.01, 0.03, 0.07, 0.9)
            btn:SetBackdropBorderColor(unpack(SB.Theme.BORDER_DIM))

            local tex = btn:CreateTexture(nil, "ARTWORK")
            tex:SetAllPoints()
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- crop the icon's baked-in border padding, see Theme.lua
            btn.texture = tex

            local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
            highlight:SetAllPoints()
            highlight:SetTexture("Interface\\Buttons\\WHITE8X8")
            highlight:SetVertexColor(SB.Theme.ACCENT[1], SB.Theme.ACCENT[2], SB.Theme.ACCENT[3], 0.12)
            highlight:SetBlendMode("ADD")

            local selectedMark = btn:CreateTexture(nil, "OVERLAY")
            selectedMark:SetSize(14, 14)
            selectedMark:SetPoint("TOPRIGHT", 2, 2)
            selectedMark:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
            selectedMark:SetVertexColor(unpack(SB.Theme.GOLD))
            selectedMark:Hide()
            btn.selectedMark = selectedMark

            btn:SetScript("OnClick", function(self)
                if onSelect and self.iconPath then onSelect(self.iconPath) end
            end)
            btn:SetScript("OnEnter", function(self)
                self:SetBackdropBorderColor(unpack(SB.Theme.ACCENT))
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.iconName or "", 1, 1, 1)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function(self)
                self:SetBackdropBorderColor(unpack(container.selectedPath == self.iconPath and SB.Theme.GOLD or SB.Theme.BORDER_DIM))
                GameTooltip:Hide()
            end)

            pool[i] = btn
        end
    end
    EnsurePoolButtons()

    -- Maps the pool onto whichever rows are CURRENTLY visible (plus one
    -- row of headroom above, so a fast wheel/drag scroll never shows a
    -- blank flash before the next Populate-triggered pass catches up) -
    -- called every time the scroll position actually changes, see the
    -- hooksecurefunc below.
    local function RenderVisibleWindow()
        local rowH = iconSize + iconPad
        local scrollOffset = scroll:GetVerticalScroll() or 0
        local firstRow = math.max(0, math.floor(scrollOffset / rowH) - 1)
        for p, btn in ipairs(pool) do
            local slot = p - 1
            local row = firstRow + math.floor(slot / columns)
            local col = slot % columns
            local entry = icons[row * columns + col + 1]
            if entry then
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", col * rowH, -row * rowH)
                btn.iconPath = entry.path
                btn.iconName = entry.name
                btn.texture:SetTexture(entry.path)
                if container.selectedPath == entry.path then
                    btn:SetBackdropBorderColor(unpack(SB.Theme.GOLD))
                    btn.selectedMark:Show()
                else
                    btn:SetBackdropBorderColor(unpack(SB.Theme.BORDER_DIM))
                    btn.selectedMark:Hide()
                end
                btn:Show()
            else
                btn:Hide()
            end
        end
    end

    -- Both the mouse wheel AND the (now draggable, see
    -- Theme.CreateScrollFrame) thumb funnel through this one method, so
    -- hooking it once covers re-virtualizing on either input uniformly.
    hooksecurefunc(scroll, "SetVerticalScroll", RenderVisibleWindow)

    function container:Populate()
        local ok, raw = pcall(GetFlatIconList)
        if not ok or type(raw) ~= "table" then raw = {} end
        wipe(icons)
        for _, entry in ipairs(raw) do
            local path, label = ResolveIcon(entry)
            if path then
                table.insert(icons, { path = path, name = label })
            end
        end

        local rows = math.ceil(#icons / columns)
        content:SetHeight(math.max(1, rows * (iconSize + iconPad)))
        RenderVisibleWindow()

        if #icons == 0 then
            SB:Debug("IconGrid: GetMacroIcons() returned no usable icons.")
        end
    end

    function container:SetSelectedIcon(path)
        self.selectedPath = path
        RenderVisibleWindow()
    end

    -- Reflow to the real available width. This is event-driven (only when
    -- the widget changes size), not a permanent update loop, and keeps the
    -- last icon column from clipping into the scrollbar on narrow layouts.
    local function ReflowColumns()
        local usable = math.max(iconSize, (container:GetWidth() or contentW) - 10)
        local nextColumns = math.max(1, math.min(preferredColumns,
            math.floor((usable + iconPad) / (iconSize + iconPad))))
        if nextColumns == columns then return end
        columns = nextColumns
        EnsurePoolButtons()
        local rows = math.ceil(#icons / columns)
        content:SetWidth(math.max(1, columns * (iconSize + iconPad)))
        content:SetHeight(math.max(1, rows * (iconSize + iconPad)))
        RenderVisibleWindow()
    end
    container:SetScript("OnSizeChanged", ReflowColumns)

    container:Populate()
    ReflowColumns()
    return container
end

------------------------------------------------------------------------
-- Standalone popup (still used for picking a Category's icon in Settings)
------------------------------------------------------------------------

local popup
local activeCallback

local function BuildPopup()
    if popup then return popup end

    local columns, visibleRows, iconSize, iconPad = 8, 6, 32, 4
    local leftMargin, rightMargin = 16, 16

    popup = SB.CreateFrame("Frame", "SoundbookIconPicker", UIParent)
    popup:SetSize(leftMargin + columns * (iconSize + iconPad) + 10 + rightMargin,
        visibleRows * (iconSize + iconPad) + 86)
    popup:SetFrameStrata("DIALOG")
    -- Generously high - this picker can be opened FROM another DIALOG-
    -- strata window (Edit Sound's "Change Icon" button, 3.0 spec section
    -- 42), which itself sits above its own modal click-blocker via an
    -- explicit frame level. A picker that opens BEHIND the window that
    -- opened it would be unusable, so this always wins ties within DIALOG.
    popup:SetFrameLevel(300)
    SB.Theme.Panel(popup)
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
    popup:SetClampedToScreen(true)
    popup:Hide()

    SB.Theme.CreateHeader(popup, "Choose an Icon", 52)

    local closeBtn = SB.Theme.CreateCloseGlyph(popup, 18)
    closeBtn:SetPoint("TOPRIGHT", -8, -8)
    closeBtn:SetScript("OnClick", function() popup:Hide() end)

    local grid = SB.CreateIconGrid(popup, {
        columns = columns, visibleRows = visibleRows, iconSize = iconSize, iconPad = iconPad,
        onSelect = function(path)
            if activeCallback then activeCallback(path) end
            popup:Hide()
        end,
    })
    grid:SetPoint("TOPLEFT", leftMargin, -70)
    grid:SetWidth(grid.contentW + 10) -- only one anchor point given above, so width needs setting explicitly - +10 matches the thin scroll thumb's own reserved margin inside CreateIconGrid
    popup.grid = grid

    return popup
end

-- callback(iconPath) is invoked with the chosen icon (a full
-- "Interface\Icons\X" string, or a numeric file ID). `currentPath`
-- (optional) pre-highlights the sound/category's existing icon in the
-- grid, same as the old embedded grid used to via SetSelectedIcon.
function SB.OpenIconPicker(callback, currentPath)
    BuildPopup()
    activeCallback = callback
    popup.grid:Populate()
    popup.grid:SetSelectedIcon(currentPath)
    popup:Show()
end
