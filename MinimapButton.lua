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

    -- Round 4: round 3's flat self-controlled square backdrop DID fix the
    -- dark/cyan overlay (no longer reported), but a plain square border is
    -- not what a minimap button is supposed to look like - explicit
    -- requirement: "look and behave like every other normal addon's
    -- minimap icon". That look comes specifically from the ring sprite's
    -- own opaque area visually cropping a square icon's corners into
    -- reading as round - there's no way to get that round appearance
    -- without SOME round graphic (a plain backdrop border is always a
    -- rectangle), and SetMask isn't reliably available on every client
    -- this addon targets (Classic Era included). Restored the exact,
    -- extremely well-tested LibDBIcon-standard layering (used by
    -- thousands of addons across every one of these same client
    -- versions without issue) instead of this file's own earlier,
    -- hand-rolled sizing/offsets/manual highlight texture - the previous
    -- overlay bug is far more likely to have come from THIS file's own
    -- custom highlight handling (manually resized/re-tinted/anchored off
    -- an, at the time, still-misaligned icon) than from these sprites'
    -- own native appearance.
    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetVertexColor(0, 0, 0, 0.3)

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("TOPLEFT", 7, -5)
    icon:SetTexture(SB.APP_ICON)
    -- Crops the dark padding WoW icon art bakes in around its edges (same
    -- technique Theme.lua's own icon slots use) so the book fills this
    -- square instead of floating in the middle of visible dead space.
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.icon = icon

    -- The ring - an OVERLAY-layer texture (drawn above the icon), so its
    -- own opaque ring shape visually crops the icon's square corners into
    -- the familiar round minimap-button look. Anchored at the button's own
    -- TOPLEFT (0,0), same as the icon's TOPLEFT(7,-5) offset above - both
    -- offsets are the exact values this sprite's own art was authored
    -- against.
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    button.border = border

    -- Hover feedback via Blizzard's own SetHighlightTexture (Button's
    -- built-in highlight mechanism - shown only on mouseover, sized to the
    -- button automatically) instead of a manually created/resized/tinted
    -- texture - removes any chance of this file's own math being the
    -- source of an oversized or misaligned hover glow.
    button.highlight = button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")

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

    -- Picks whichever tooltip anchor sits FARTHEST from the Mini Soundbook,
    -- so the two can never overlap regardless of where either one
    -- currently sits - explicit requirement, now that the minimap button's
    -- own fresh-install default (top of the minimap) can land close to the
    -- Mini Soundbook's own fresh-install default (top-centre of the
    -- screen). "The Mini Soundbook" means whichever of its two possible
    -- on-screen forms is actually showing right now: the EXPANDED
    -- favourites popup (SoundbookFavMenu, Announcer.lua's favMenu - often
    -- larger and positioned well away from the idle icon itself once
    -- open) takes priority when it's open, since that's the bigger, more
    -- likely thing to actually overlap; the idle icon (SoundbookAnnouncerIcon)
    -- is the fallback otherwise. Falls back to the original fixed
    -- ANCHOR_LEFT whenever neither exists/is shown - nothing to avoid, so
    -- no change in that case.
    local function ResolveTooltipAnchor(self)
        local avoid = _G.SoundbookFavMenu
        if not (avoid and avoid:IsShown()) then avoid = _G.SoundbookAnnouncerIcon end
        if not (avoid and avoid:IsShown()) then return "ANCHOR_LEFT" end
        local mx, my = self:GetCenter()
        local ax, ay = avoid:GetCenter()
        if not (mx and my and ax and ay) then return "ANCHOR_LEFT" end
        -- Both frames can carry their own independent effective scale
        -- (the minimap button inherits the Minimap's; the Announcer icon/
        -- favMenu carry Announcer Size/Mini Soundbook Size) - GetCenter()
        -- is only ever in a frame's own local unit space, so each needs
        -- converting into UIParent's shared coordinate space before
        -- comparing, same pattern SB.ResolvePopoutDirection already uses.
        local selfScale = (self:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
        local annScale = (avoid:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
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
