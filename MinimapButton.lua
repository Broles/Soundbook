-- MinimapButton.lua
-- A small draggable minimap button that toggles the main Soundbook window.
-- No LibDBIcon or other external library - just a plain frame positioned
-- around the minimap's edge from a saved angle, same technique those
-- libraries use internally.

local ADDON_NAME, SB = ...

local RADIUS = 80
local button

local function UpdatePosition()
    if not button then return end
    local angle = math.rad(SB.db.ui.minimap.angle or 215)
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * RADIUS, math.sin(angle) * RADIUS)
end

local function BuildButton()
    if button then return button end

    button = CreateFrame("Button", "SoundbookMinimapButton", Minimap)
    button:SetSize(31, 31)
    -- Back to "MEDIUM" (Soundbook 1.9.1, explicit requirement) - the same
    -- normal strata the Minimap itself and virtually every other addon's
    -- minimap button (LibDBIcon etc.) uses. An earlier version bumped this
    -- to "HIGH" specifically to win a hover/click tie against another
    -- addon's icon sitting at the same spot on the ring - but that also
    -- meant OUR button always won against every OTHER addon's icon too,
    -- unnecessarily blocking them. A high FRAME LEVEL (still 8, well above
    -- typical sibling buttons at the SAME strata) keeps winning ordinary
    -- overlap ties within "MEDIUM" itself, without reaching for an entire
    -- strata tier above everyone else.
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER", 0, 1)
    icon:SetTexture(SB.APP_ICON)
    button.icon = icon

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    button.border = border

    -- Bugfix: Blizzard's stock zoom-button highlight art is a bright blue
    -- glow sized to nearly the whole 31px button - at that size it visually
    -- swallowed the much smaller 18px book icon on hover, reading as the
    -- icon being replaced by a big blue ring. Sized just a touch past the
    -- icon itself (not the button) and tinted Soundbook's own gold accent
    -- (see Theme.GOLD), it now reads as a subtle glow behind the icon
    -- instead of a second, icon-sized graphic on top of it.
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetSize(22, 22)
    highlight:SetPoint("CENTER", icon, "CENTER", 0, 0)
    highlight:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    highlight:SetVertexColor(0.92, 0.68, 0.28, 0.8)
    button.highlight = highlight

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "LeftButton" then
            SB:Fire("TOGGLE_MAIN_UI")
        elseif mouseButton == "RightButton" then
            SB:Fire("TOGGLE_FAV_UI")
        end
    end)

    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            mx, my = mx / scale, my / scale
            local cx, cy = Minimap:GetCenter()
            local angle = math.deg(math.atan2(my - cy, mx - cx))
            SB.db.ui.minimap.angle = angle
            UpdatePosition()
        end)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Soundbook", 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left Click: Open/close Soundbook", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("Right Click: Open/close Announcer", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("Drag: Move this button", 0.9, 0.9, 0.9)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    UpdatePosition()
    return button
end

function SB:RefreshMinimapButton()
    if SB.db.ui.minimap.hide then
        if button then button:Hide() end
    else
        BuildButton()
        button:Show()
        UpdatePosition()
    end
end

SB:On("PLAYER_LOGIN", function()
    SB:RefreshMinimapButton()
end)
