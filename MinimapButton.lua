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

    button = SB.CreateFrame("Button", "SoundbookMinimapButton", Minimap)
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

    -- Bugfix (round 3): two earlier rounds both tried to tame Blizzard's
    -- own minimap-button art (first the zoom-button highlight texture,
    -- then the MiniMap-TrackingBorder ring's icon-inset alignment) and the
    -- book icon was STILL being visually replaced by a large dark/cyan
    -- circle - live-tested confirmation that the problem was never really
    -- the alignment, it's that texture's own native rendered appearance,
    -- which this environment has no way to preview before shipping.
    -- Dropped entirely. Every visual element here is now a plain flat
    -- colour/backdrop this file fully controls itself (SB.CreateFrame
    -- above already carries BackdropTemplate) - nothing pulled from an
    -- unpredictable Blizzard sprite, so there is no art asset left that
    -- could ever render as a large dark/blue/cyan overlay again.
    button:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1.5 })
    button:SetBackdropColor(0, 0, 0, 0) -- fully transparent fill - never covers the icon
    button:SetBackdropBorderColor(0.92, 0.68, 0.28, 0.9) -- Theme.GOLD, thin ring around the button's own edge only

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", 0, 0)
    icon:SetTexture(SB.APP_ICON)
    -- Crops the dark padding WoW icon art bakes in around its edges (same
    -- technique Theme.lua's own icon slots use) so the book fills this
    -- square instead of floating in the middle of visible dead space.
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.icon = icon

    -- Subtle hover glow ONLY - a soft, low-alpha, additive-blended flat
    -- gold wash across the whole button, never a separate sprite that
    -- could visually replace the icon underneath it.
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints(button)
    highlight:SetTexture("Interface\\Buttons\\WHITE8X8")
    highlight:SetVertexColor(0.92, 0.68, 0.28, 0.35)
    highlight:SetBlendMode("ADD")
    button.highlight = highlight

    -- Explicit requirement: pressed state must never cover/replace the
    -- book artwork either - a plain alpha dim on the icon itself (not a
    -- second texture layered on top) reads as "pressed" without ever
    -- obscuring the artwork underneath it.
    button:SetScript("OnMouseDown", function(self)
        if self:IsEnabled() then icon:SetAlpha(0.7) end
    end)
    button:SetScript("OnMouseUp", function() icon:SetAlpha(1) end)

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

    -- Picks whichever tooltip anchor sits FARTHEST from the Mini Soundbook
    -- (Announcer) icon's own real on-screen position, so the two can never
    -- overlap regardless of where either one currently sits - explicit
    -- requirement, now that the minimap button's own fresh-install default
    -- (top of the minimap) can land close to the Mini Soundbook's own
    -- fresh-install default (top-centre of the screen). Falls back to the
    -- previous fixed ANCHOR_LEFT whenever the Announcer icon doesn't exist
    -- yet or isn't shown - nothing to avoid, so no change in that case.
    local function ResolveTooltipAnchor(self)
        local announcerIcon = _G.SoundbookAnnouncerIcon
        if not (announcerIcon and announcerIcon:IsShown()) then return "ANCHOR_LEFT" end
        local mx, my = self:GetCenter()
        local ax, ay = announcerIcon:GetCenter()
        if not (mx and my and ax and ay) then return "ANCHOR_LEFT" end
        -- Both frames can carry their own independent effective scale
        -- (the minimap button inherits the Minimap's; the Announcer icon
        -- has its own Announcer Size) - GetCenter() is only ever in a
        -- frame's own local unit space, so each needs converting into
        -- UIParent's shared coordinate space before comparing, same
        -- pattern SB.ResolvePopoutDirection already uses.
        local selfScale = (self:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
        local annScale = (announcerIcon:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
        mx, my = mx * selfScale, my * selfScale
        ax, ay = ax * annScale, ay * annScale
        local dx, dy = mx - ax, my - ay
        -- Whichever axis separates the two by more decides which side the
        -- tooltip opens toward - always away from the Announcer icon.
        if math.abs(dx) > math.abs(dy) then
            return (dx >= 0) and "ANCHOR_RIGHT" or "ANCHOR_LEFT"
        end
        return (dy >= 0) and "ANCHOR_TOP" or "ANCHOR_BOTTOM"
    end

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, ResolveTooltipAnchor(self))
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
