-- Theme.lua
-- Shared "modern flat" visual language for every Soundbook window except
-- the Mini Soundbook (which stays borderless/transparent by design):
-- flat dark panels, a 1px accent-coloured border, square (unornamented)
-- icon slots, and flat buttons - inspired by the look of addons like
-- HealerSweatMeter and FishingKit rather than classic carved-stone WoW
-- chrome. All colours/helpers live here so every window stays consistent.

local ADDON_NAME, SB = ...

local Theme = {}
SB.Theme = Theme

-- Discord's "blurple" brand colour, used as the addon's single accent
-- colour throughout (borders, favourite highlight, checkboxes, selected
-- states).
Theme.ACCENT       = { 0.35, 0.48, 1.00 }
Theme.ACCENT_DIM   = { 0.25, 0.38, 0.95, 0.42 }
Theme.GOLD         = { 0.92, 0.68, 0.28 }
Theme.GOLD_DIM     = { 0.48, 0.32, 0.12, 0.90 }
Theme.BG           = { 0.018, 0.055, 0.105, 0.97 }
Theme.BG_RAISED    = { 0.035, 0.095, 0.18, 0.98 }
Theme.BG_INPUT     = { 0.012, 0.028, 0.060, 0.96 }
Theme.BORDER       = { 0.30, 0.52, 1.00, 0.92 }
Theme.BORDER_DIM   = { 0.92, 0.68, 0.28, 0.28 }
Theme.TEXT         = { 0.91, 0.94, 1.00 }
Theme.TEXT_DIM     = { 0.55, 0.66, 0.79 }
-- Soundbook 2.0 visual pass, Mini Soundbook only: a true arcane cyan
-- (no red channel at all, unlike ACCENT's blurple which reads as violet
-- against dark navy) - explicit request to remove the violet hover wash
-- from the Mini Soundbook's slot hover and its Send-to context menu row
-- hover specifically, without touching ACCENT itself (still used
-- everywhere else - Main Soundbook, Settings, checkboxes, ...).
Theme.ARCANE_HOVER = { 0.30, 0.70, 0.92 }
Theme.METRICS      = {
    XS = 4, S = 8, M = 12, L = 16, XL = 24,
    inset = 12, padding = 10, gap = 8, border = 2,
    header = 44, sectionGap = 16, controlHeight = 22,
}

-- UI/UX polish pass: one small shared spacing/sizing system, referenced by
-- Main, Settings, Edit Sound and Keybindings instead of each screen
-- re-deriving its own magic offsets (explicit requirement, section 2 -
-- "use a small shared spacing system consistently instead of many
-- per-screen magic offsets"). Additive to Theme.METRICS above, which
-- several pre-3.0 surfaces still read directly - this is the 3.0 polish
-- pass's own vocabulary, named for what each number actually controls
-- rather than a generic T-shirt size, so a caller can tell at a glance
-- which one it needs.
Theme.LAYOUT = {
    SAFE_INSET   = 14, -- outer clearance from a window's own decorative frame/corners
    GUTTER       = 10, -- horizontal gutter between a content column and a side rail
    GAP_S        = 6,  -- tight gap (icon <-> its own label, adjacent inline controls)
    GAP_M        = 10, -- normal gap (a control and the label/hint directly above it)
    GAP_L        = 16, -- section-to-section gap
    GAP_XL       = 24, -- major block-to-block gap
    CONTROL_H    = 24, -- standard control height (buttons, inputs, tabs)
    -- Targeted correction round: the shared major-window header height
    -- (Theme.CreateHeader's own default), used by Main/Settings/
    -- Keybindings alike - explicit target ~60px.
    HEADER_H     = 60,
    ICON_BTN     = 24, -- header utility icon size (Close/Lock/Quick Audio)
    TAB_H        = 24, -- Settings-style navigation tab height
}

-- Soundbook 3.0 design tokens - additive only, the tokens above stay exactly
-- as they are since the pre-3.0 UI (Settings, Edit Sound, etc.) still reads
-- them directly during the staged rollout (see the 3.0 Discovery Report's
-- Implementation Order: old surfaces are only retired once their 3.0
-- replacement has full parity). A restrained Arcane palette - roughly 80%
-- functional UI / 20% Arcane identity, per the 3.0 spec - so new surfaces
-- (Announcer, later the Main shell) pull from one shared place instead of
-- each hand-picking colours again.
Theme.V3 = {
    DEEP_NAVY      = { 0.027, 0.067, 0.122 },
    RAISED_NAVY    = { 0.043, 0.106, 0.176 },
    CARD_BG        = { 0.039, 0.086, 0.141 },
    HOVER_RAISED   = { 0.063, 0.169, 0.267 },
    TEXT_PRIMARY   = { 0.91, 0.94, 1.00 },
    TEXT_SECONDARY = { 0.56, 0.65, 0.75 },
    ARCANE_BLUE    = { 0.35, 0.50, 1.00 },
    ARCANE_CYAN    = { 0.30, 0.69, 0.92 },
    VIOLET         = { 0.72, 0.55, 0.95 },
    -- 4/6/8/12/16/24 spacing scale (3.0 spec section 65).
    SPACE = { 4, 6, 8, 12, 16, 24 },
}

local WHITE = "Interface\\Buttons\\WHITE8X8"
local ARCANE_BG = "Interface\\AddOns\\Soundbook\\Assets\\ArcaneBackground"
local ARCANE_HEADER = "Interface\\AddOns\\Soundbook\\Assets\\ArcaneHeader"
local FRAME_CORNER = "Interface\\AddOns\\Soundbook\\Assets\\FrameCorner"
local ICON_FRAME = "Interface\\AddOns\\Soundbook\\Assets\\IconFrame"
local CONTROL_ICONS = "Interface\\AddOns\\Soundbook\\Assets\\ControlIcons"
local SETTINGS_GEAR = "Interface\\AddOns\\Soundbook\\Assets\\SettingsGear"
local AUDIO_ICON = "Interface\\AddOns\\Soundbook\\Assets\\AudioIcon"
local CLOSE_ICON = "Interface\\AddOns\\Soundbook\\Assets\\CloseIcon"

-- Clean single-border surface for compact HUDs and context menus. These
-- elements are too small for the large book corners/inner frame used by
-- Theme.Panel; applying that ornament there creates competing lines and
-- makes content underneath show through visually.
function Theme.CleanPanel(frame, alpha)
    frame:SetBackdrop({
        bgFile = WHITE,
        edgeFile = WHITE,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    frame:SetBackdropColor(Theme.BG[1], Theme.BG[2], Theme.BG[3], alpha or 0.98)
    frame:SetBackdropBorderColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.88)
end

-- Soundbook 2.0: the Mini Soundbook's own root surface - reuses the exact
-- same ARCANE_BG asset Theme.Panel (Main Soundbook) is built on, not a
-- separate/different background language, but darkened MUCH further via
-- a heavier navy wash layered on top - explicit request: "gleiche Source
-- Texture", roughly 20-30% of Main's own visual intensity, so this reads
-- as "the same material, much quieter", never a second full Main window.
-- `washAlpha` (default 0.82) is how opaque that darkening layer is - a
-- caller wanting a specific zone (header vs. grid) slightly more or less
-- textured than the rest passes a different value; see FavouritesWindow.
-- lua's BuildFrame for how the header/status/grid/footer split it up.
function Theme.MiniArcanePanel(frame, washAlpha)
    frame:SetBackdrop({
        bgFile = ARCANE_BG,
        edgeFile = WHITE,
        edgeSize = 1,
        tile = false,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    -- Same light arcane tint Main's own Theme.Panel uses (0.68,0.78,1.00) -
    -- the wash texture below is what actually darkens it down to Mini's
    -- much quieter intensity; the raw backdrop alone would look identical
    -- to Main's own background.
    frame:SetBackdropColor(0.68, 0.78, 1.00, 0.98)
    frame:SetBackdropBorderColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.45)

    if not frame.soundbookMiniWash then
        local wash = frame:CreateTexture(nil, "ARTWORK")
        wash:SetAllPoints()
        wash:SetTexture(WHITE)
        frame.soundbookMiniWash = wash
    end
    frame.soundbookMiniWash:SetVertexColor(0.01, 0.05, 0.11, washAlpha or 0.82)

    -- Final polish pass: "Ecken dürfen etwas mehr Cyan/Blue-Struktur
    -- zeigen". Reuses FRAME_CORNER - the SAME shaped/faded ornament asset
    -- and TEXCOORD mapping Main Soundbook's own Theme.Panel already draws
    -- its gold corners with (see below) - not a flat rectangle (a plain
    -- WHITE square with ADD blend would have a hard, visible edge right
    -- where it cuts off; this asset already has a real falloff baked in).
    -- ADD blend only ever brightens, so this can never create the kind of
    -- rectangular seam that locally varying the wash's own alpha would
    -- risk, and it's small/dim enough to fade out well before reaching
    -- the icon grid in the centre - the wash itself is untouched.
    if not frame.soundbookMiniCorners then
        local corners = {}
        local points = {
            { "TOPLEFT", 1, -1, { 0, 0, 0, 1, 1, 0, 1, 1 } },
            { "TOPRIGHT", -1, -1, { 1, 0, 1, 1, 0, 0, 0, 1 } },
            { "BOTTOMLEFT", 1, 1, { 0, 1, 0, 0, 1, 1, 1, 0 } },
            { "BOTTOMRIGHT", -1, 1, { 1, 1, 1, 0, 0, 1, 0, 0 } },
        }
        for i, p in ipairs(points) do
            local corner = frame:CreateTexture(nil, "ARTWORK", nil, 1)
            corner:SetTexture(FRAME_CORNER)
            corner:SetBlendMode("ADD")
            corner:SetSize(32, 32)
            corner:SetPoint(p[1], p[2], p[3])
            corner:SetTexCoord(unpack(p[4]))
            corner:SetVertexColor(Theme.ARCANE_HOVER[1], Theme.ARCANE_HOVER[2], Theme.ARCANE_HOVER[3], 0.16)
            corners[i] = corner
        end
        frame.soundbookMiniCorners = corners
    end
end

-- Flat dark panel with a 1px accent border - the base look for every
-- window frame (main book, Edit Sound, the embedded Settings page).
function Theme.Panel(frame)
    frame:SetBackdrop({
        bgFile = ARCANE_BG,
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = false, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.68, 0.78, 1.00, 0.98)
    frame:SetBackdropBorderColor(unpack(Theme.GOLD))

    if not frame.soundbookInnerBorder then
        local inner = SB.CreateFrame("Frame", nil, frame)
        inner:SetPoint("TOPLEFT", 8, -8)
        inner:SetPoint("BOTTOMRIGHT", -8, 8)
        inner:SetBackdrop({ edgeFile = WHITE, edgeSize = 1 })
        inner:SetBackdropBorderColor(unpack(Theme.BORDER))
        inner:EnableMouse(false)
        frame.soundbookInnerBorder = inner

        local wash = frame:CreateTexture(nil, "BACKGROUND")
        wash:SetPoint("TOPLEFT", 5, -5)
        wash:SetPoint("BOTTOMRIGHT", -5, 5)
        wash:SetTexture(WHITE)
        wash:SetVertexColor(0.015, 0.10, 0.22, 0.32)
        frame.soundbookArcaneWash = wash

        if (frame:GetWidth() or 0) >= 140 and (frame:GetHeight() or 0) >= 100 then
            local corners = {}
            local points = {
                { "TOPLEFT", 1, -1, { 0, 0, 0, 1, 1, 0, 1, 1 } },
                { "TOPRIGHT", -1, -1, { 1, 0, 1, 1, 0, 0, 0, 1 } },
                { "BOTTOMLEFT", 1, 1, { 0, 1, 0, 0, 1, 1, 1, 0 } },
                { "BOTTOMRIGHT", -1, 1, { 1, 1, 1, 0, 0, 1, 0, 0 } },
            }
            local cornerSize = math.min(92, math.max(52, math.min(frame:GetWidth(), frame:GetHeight()) * 0.22))
            for i, p in ipairs(points) do
                local corner = frame:CreateTexture(nil, "OVERLAY")
                corner:SetTexture(FRAME_CORNER)
                corner:SetBlendMode("ADD")
                corner:SetVertexColor(1, 1, 1, 0.88)
                corner:SetSize(cornerSize, cornerSize)
                corner:SetPoint(p[1], p[2], p[3])
                corner:SetTexCoord(unpack(p[4]))
                corners[i] = corner
            end
            frame.soundbookCorners = corners
        end
    end
end

function Theme.CreateHeader(parent, title, height)
    local header = CreateFrame("Frame", nil, parent)
    header:SetPoint("TOPLEFT", 9, -9)
    header:SetPoint("TOPRIGHT", -9, -9)
    header:SetHeight(height or 60)

    local bg = header:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    -- A square background texture stretched across a very wide, shallow
    -- header also looks vertically crushed. Use a solid navy header field;
    -- the proportional crest below provides the intentional decoration.
    bg:SetTexture(WHITE)
    bg:SetVertexColor(0.018, 0.065, 0.145, 0.96)

    local bottom = header:CreateTexture(nil, "BORDER")
    bottom:SetPoint("BOTTOMLEFT", 8, 0)
    bottom:SetPoint("BOTTOMRIGHT", -8, 0)
    bottom:SetHeight(1)
    bottom:SetTexture(WHITE)
    bottom:SetVertexColor(unpack(Theme.GOLD))

    local crest = header:CreateTexture(nil, "ARTWORK")
    crest:SetTexture(ARCANE_HEADER)
    crest:SetPoint("TOP", header, "TOP", 0, 6)
    crest:SetAlpha(0.72)

    local label = header:CreateFontString(nil, "OVERLAY")
    label:SetFontObject(SB.Fonts.Title)
    label:SetPoint("BOTTOM", 0, 4)
    label:SetText(title or "")
    label:SetTextColor(unpack(Theme.TEXT))
    label:SetShadowColor(0.20, 0.35, 0.95, 0.9)
    label:SetShadowOffset(1, -1)
    local function LayoutCrest(self)
        local width = self:GetWidth() or 300
        local headerHeight = self:GetHeight() or (height or 58)
        -- ArcaneHeader.tga is exactly 1024x256 (4:1). Keep that native
        -- ratio at every parent width; changing width and height
        -- independently visibly crushes the central crystal and scrollwork.
        local baseW = math.max(1, math.min(300, width - 92, (headerHeight + 8) * 4))
        local crestW = math.min(330, width - 72, baseW * 1.10)
        crest:SetSize(crestW, crestW / 4)
    end
    header:SetScript("OnSizeChanged", LayoutCrest)
    LayoutCrest(header)
    header.title, header.crest = label, crest
    return header
end

-- The ONE primary title treatment (explicit requirement, section 1: "use
-- one primary title treatment across these screens, do not alternate
-- title colors/styles arbitrarily") - applies the exact same font tier,
-- colour and shadow Theme.CreateHeader's own title uses (the established
-- Edit Sound look) to a FontString a caller builds and positions itself.
-- Used for Main's own "Soundbook" title and the Settings/Keybindings
-- context label that replaces it in the same header slot, so all four
-- surfaces' primary heading share one visual definition instead of each
-- screen hand-picking its own colour/size.
function Theme.ApplyTitleStyle(fontString)
    fontString:SetFontObject(SB.Fonts.Title)
    fontString:SetTextColor(unpack(Theme.TEXT))
    fontString:SetShadowColor(0.20, 0.35, 0.95, 0.9)
    fontString:SetShadowOffset(1, -1)
end

-- Shared navigation-tab chrome (explicit requirement, section 7: "Tabs
-- should use a shared state system with the rest of the UI: idle, hover,
-- active, disabled") - used by Settings' section tab strip. A true
-- 4-state control, unlike Theme.CreateFlatButton (only idle/hover/
-- disabled - no distinct "active" look of its own), so a hovered INACTIVE
-- tab can never be visually confused with the genuinely active one.
-- `btn:SetActive(bool)` toggles the persistent state.
--
-- Targeted correction round: no filled tile any more (explicit
-- requirement - "do not use large filled selected tabs; give each
-- category its own active underline color") - `accentColor` (optional,
-- defaults to GOLD) is THIS tab's own identifying colour, used only for
-- its underline/hover tint, never a background fill, and never applied
-- to anything outside this one tab ("this color identifies the selected
-- category only - do not recolor the complete Settings content"). Active
-- = primary text + a 2px underline in accentColor, sized to the label's
-- own rendered width + 12px (recomputed on SetText, so a relabel never
-- leaves a stale-width underline). Hover (inactive only) = the same
-- accentColor at reduced intensity on the text alone. Inactive = dim
-- text, nothing else.
function Theme.CreateTabButton(parent, text, width, height, accentColor)
    accentColor = accentColor or Theme.GOLD
    local btn = SB.CreateFrame("Button", nil, parent)
    btn:SetSize(width or 90, height or Theme.LAYOUT.TAB_H)

    local label = btn:CreateFontString(nil, "OVERLAY")
    label:SetFontObject(SB.Fonts.HighlightSmall)
    label:SetPoint("CENTER")
    label:SetText(text or "")
    btn.label = label

    local mark = btn:CreateTexture(nil, "OVERLAY")
    mark:SetHeight(2)
    mark:SetTexture(WHITE)
    mark:SetVertexColor(accentColor[1], accentColor[2], accentColor[3], 1)
    mark:Hide()
    btn.selectedMark = mark

    local function LayoutMark()
        local w = math.min(btn:GetWidth() or 90, (label:GetStringWidth() or 0) + 12)
        mark:ClearAllPoints()
        mark:SetWidth(math.max(1, w))
        mark:SetPoint("BOTTOM", label, "BOTTOM", 0, -4)
    end

    local active, hovering = false, false
    local function Apply()
        if not btn:IsEnabled() then
            label:SetTextColor(0.42, 0.46, 0.53)
            mark:Hide()
            return
        end
        if active then
            label:SetTextColor(unpack(Theme.TEXT))
            LayoutMark()
            mark:Show()
        elseif hovering then
            label:SetTextColor(accentColor[1] * 0.55 + Theme.TEXT_DIM[1] * 0.45,
                accentColor[2] * 0.55 + Theme.TEXT_DIM[2] * 0.45,
                accentColor[3] * 0.55 + Theme.TEXT_DIM[3] * 0.45)
            mark:Hide()
        else
            label:SetTextColor(unpack(Theme.TEXT_DIM))
            mark:Hide()
        end
    end

    function btn:SetActive(value)
        active = value and true or false
        Apply()
    end
    function btn:IsActive()
        return active
    end

    local origSetText = label.SetText
    label.SetText = function(self, ...)
        origSetText(self, ...)
        if active then LayoutMark() end
    end

    btn:SetScript("OnEnter", function() hovering = true; Apply() end)
    btn:SetScript("OnLeave", function() hovering = false; Apply() end)
    btn:HookScript("OnEnable", Apply)
    btn:HookScript("OnDisable", Apply)
    btn:SetScript("OnSizeChanged", function() if active then LayoutMark() end end)
    Apply()

    return btn
end

function Theme.CreateSectionHeader(parent, text)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(20)
    local label = frame:CreateFontString(nil, "OVERLAY")
    label:SetFontObject(SB.Fonts.Normal)
    label:SetPoint("LEFT", 0, 0)
    label:SetText(text or "")
    label:SetTextColor(unpack(Theme.GOLD))
    local line = frame:CreateTexture(nil, "ARTWORK")
    line:SetPoint("LEFT", label, "RIGHT", 10, 0)
    line:SetPoint("RIGHT", 0, 0)
    line:SetHeight(1)
    line:SetTexture(WHITE)
    line:SetVertexColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.45)
    frame.label, frame.line = label, line
    return frame
end

function Theme.CreateSeparator(parent)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetTexture(WHITE)
    line:SetVertexColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.32)
    return line
end

-- A plain square icon "slot": a thin 1px border frame with the icon
-- texture inset by 1px - no carved WoW slot ornamentation. Returns the
-- slot frame; slot.texture is the icon texture inside it.
-- `borderColor` defaults to a neutral dim border; pass Theme.ACCENT for a
-- highlighted (e.g. favourited) slot. Pass frameType = "Button" to get a
-- clickable slot (OnClick etc.) instead of a plain decorative Frame.
function Theme.CreateIconSlot(parent, size, borderColor, frameType)
    local slot = SB.CreateFrame(frameType or "Frame", nil, parent)
    if size then slot:SetSize(size, size) end
    -- bgFile is set (even though slots are normally border-only) so callers
    -- like the tab-active-highlight in UI.lua can opt into a visible fill
    -- via SetBackdropColor; defaults to fully transparent so it never
    -- shows through a slot's icon by default.
    slot:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 2, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    slot:SetBackdropColor(Theme.BG_INPUT[1], Theme.BG_INPUT[2], Theme.BG_INPUT[3], 0.82)
    slot:SetBackdropBorderColor(unpack(borderColor or Theme.BORDER_DIM))

    local tex = slot:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", 1, -1)
    tex:SetPoint("BOTTOMRIGHT", -1, 1)
    -- WoW icon art is drawn on a square canvas with a fair amount of dark
    -- padding baked in around the edges (normally hidden by Blizzard's own
    -- round/octagonal button frame). Cropping that padding out here is
    -- what makes the icon actually fill this flat square instead of
    -- floating in the middle of it with visible dead space/corners.
    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    slot.texture = tex

    local innerGlow = slot:CreateTexture(nil, "OVERLAY")
    innerGlow:SetPoint("TOPLEFT", 2, -2)
    innerGlow:SetPoint("BOTTOMRIGHT", -2, 2)
    innerGlow:SetTexture(WHITE)
    innerGlow:SetBlendMode("ADD")
    innerGlow:SetVertexColor(Theme.ACCENT[1], Theme.ACCENT[2], Theme.ACCENT[3], 0)
    slot.innerGlow = innerGlow

    -- "Alternative Sound" wash (explicit request) - a translucent purple
    -- layer directly over the icon art, so a sound with a personal
    -- alternate recording enabled reads as visually distinct everywhere
    -- its icon appears. Normal alpha blend (not ADD like innerGlow's glow
    -- above), since this needs to genuinely TINT what's underneath, not
    -- brighten it - same purple SB.CHANNEL_COLOR.DIRECT already uses
    -- everywhere else in the addon. Hidden by default; callers toggle it
    -- with slot:SetAlternate(bool) wherever they already set the icon
    -- texture for a given soundID.
    local altTint = slot:CreateTexture(nil, "OVERLAY")
    altTint:SetPoint("TOPLEFT", 1, -1)
    altTint:SetPoint("BOTTOMRIGHT", -1, 1)
    altTint:SetTexture(WHITE)
    altTint:SetVertexColor(SB.CHANNEL_COLOR.DIRECT.r, SB.CHANNEL_COLOR.DIRECT.g, SB.CHANNEL_COLOR.DIRECT.b, 0.5)
    altTint:Hide()
    slot.altTint = altTint

    function slot:SetAlternate(active)
        self.altTint:SetShown(active and true or false)
    end

    -- Per-sound "Default Output" override wash (explicit request) - same
    -- idea/layering as altTint above (a translucent colour layer directly
    -- over the icon art), but the colour itself is whatever channel the
    -- sound's own override targets (SB.CHANNEL_COLOR - Raid=orange,
    -- Guild=green, etc, via SB.OutputOverrideColorForTarget/
    -- SB.SoundOutputOverrideColor in Communication.lua) instead of a fixed
    -- purple. Hidden by default; callers toggle it with
    -- slot:SetOutputTint(color) - pass nil/false to hide.
    local outputTint = slot:CreateTexture(nil, "OVERLAY")
    outputTint:SetPoint("TOPLEFT", 1, -1)
    outputTint:SetPoint("BOTTOMRIGHT", -1, 1)
    outputTint:SetTexture(WHITE)
    outputTint:Hide()
    slot.outputTint = outputTint

    function slot:SetOutputTint(color)
        if color then
            self.outputTint:SetVertexColor(color.r, color.g, color.b, 0.5)
            self.outputTint:Show()
        else
            self.outputTint:Hide()
        end
    end

    local ornament = slot:CreateTexture(nil, "OVERLAY")
    ornament:SetPoint("TOPLEFT", -1, 1)
    ornament:SetPoint("BOTTOMRIGHT", 1, -1)
    ornament:SetTexture(ICON_FRAME)
    ornament:SetVertexColor(0.82, 0.88, 1.0, 0.18)
    slot.ornament = ornament

    function slot:SetVisualState(state, isFavourite, isMuted, ...)
        self.soundbookState = state or "normal"
        self.soundbookFavourite = isFavourite and true or false
        self.soundbookMuted = isMuted and true or false
        -- outputColor (4th, optional): explicitly passing nil clears it;
        -- OMITTING the argument entirely keeps whatever was last set (see
        -- SetFavourited below, which calls this without knowing the
        -- current override colour and must not stomp it back to "none" on
        -- every favourite toggle) - select("#", ...) tells the two apart.
        if select("#", ...) > 0 then
            self.soundbookOutputColor = (...) or nil
        end

        local border = Theme.BORDER_DIM
        local glowR, glowG, glowB, glowA = Theme.ACCENT[1], Theme.ACCENT[2], Theme.ACCENT[3], 0
        if self.soundbookState == "playing" then
            border = Theme.GOLD
            glowA = 0.17
        elseif self.soundbookState == "selected" then
            border = Theme.ACCENT
            glowA = 0.10
        elseif self.soundbookOutputColor then
            -- Per-sound "Default Output" override (explicit request) -
            -- takes the border over a plain favourite gold, but still
            -- loses to the "playing"/"selected" transient states above.
            local c = self.soundbookOutputColor
            border = { c.r, c.g, c.b, 1 }
        elseif self.soundbookFavourite then
            border = Theme.GOLD
            glowR, glowG, glowB, glowA = Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 0.055
        end
        if self.soundbookMuted then
            border = { 0.48, 0.53, 0.60, 0.62 }
            glowA = 0
        end

        self:SetBackdropBorderColor(unpack(border))
        self.innerGlow:SetVertexColor(glowR, glowG, glowB, glowA)
        -- Decorative IconFrame art is never a resting-state treatment.
        -- It is reserved for the explicit hover overlays on Mini and the
        -- Favourites page; even a very low alpha reads as a bad stamp over
        -- the underlying icon at small WoW UI sizes.
        self.ornament:SetAlpha(0)
        if self.texture.SetDesaturated then
            self.texture:SetDesaturated(self.soundbookMuted)
        end
        self.texture:SetVertexColor(self.soundbookMuted and 0.66 or 1, self.soundbookMuted and 0.70 or 1, self.soundbookMuted and 0.76 or 1, 1)
    end

    function slot:SetFavourited(isFavourite)
        self:SetVisualState(self.soundbookState or "normal", isFavourite, self.soundbookMuted)
    end

    function slot:SetOrnamentMode(mode)
        if mode ~= "hover" then
            self.ornament:SetAlpha(1)
            return
        end
        self.ornament:SetAlpha(0)
        self:HookScript("OnEnter", function(s) s.ornament:SetAlpha(1) end)
        self:HookScript("OnLeave", function(s) s.ornament:SetAlpha(0) end)
    end

    slot:SetVisualState("normal", false, false)

    return slot
end

-- Explicit request: a hover "zoom" for the Mini Soundbook's favourite
-- slots and the Intro popup's sound button (deliberately NOT the main
-- window's own sound grid - "nicht im Spellbook") - growing the WHOLE
-- square frame (not just the icon texture inside it) by `growPercent`
-- (default 15%, a size a normal square icon clearly enough to notice
-- without feeling glitchy). Deliberately allowed to cover neighbouring
-- slots/elements while zoomed (frame level is bumped for the duration so
-- it actually renders on top of them) - explicit request, not a bug.
--
-- IMPORTANT PRECONDITION: `frame` must already be anchored via a single
-- CENTER point (either directly, or via a small never-scaled "holder"
-- frame it's permanently centred on - see FavouritesWindow.lua's grid
-- slots for that pattern). SetScale always grows a frame symmetrically
-- around whichever point it's anchored by, so CENTER is what makes this
-- read as "zoom from the middle" - anything else drifts toward whatever
-- corner/edge was used. An earlier version of this function tried to
-- convert an arbitrary anchor to CENTER dynamically, on every hover, via
-- GetPoint() math - that turned out fragile in practice (visible drift,
-- and outright "jumping" for slots whose layout gets recomputed while
-- hovered) and has been replaced by this precondition instead: get the
-- anchor right ONCE, up front, and this function no longer needs to touch
-- points at all.
--
-- Uses HookScript, not SetScript, so this never clobbers a frame's own
-- existing OnEnter/OnLeave (tooltip, hover-alpha, etc.) - call this AFTER
-- those are already assigned so the zoom hook runs on top of them, not the
-- other way around.
function Theme.ApplyHoverZoom(frame, growPercent)
    growPercent = growPercent or 0.15
    local baseLevel
    local pinned = false

    frame:HookScript("OnEnter", function(self)
        if self.soundbookHoverDisabled then return end
        baseLevel = baseLevel or self:GetFrameLevel()
        self:SetFrameLevel(baseLevel + 20)
        self:SetScale(1 + growPercent)
    end)

    frame:HookScript("OnLeave", function(self)
        if pinned then return end
        self:SetScale(1)
        if baseLevel then
            self:SetFrameLevel(baseLevel)
        end
    end)

    -- Explicit request: keep a slot visibly zoomed (as if the mouse were
    -- still over it) while something ELSE now covers it and steals the
    -- real OnLeave - e.g. SendMenu.lua's right-click popup opening right
    -- on top of the slot that spawned it. `SetHoverZoomPinned(true)`
    -- FORCES the zoomed state on right away (not just "don't un-zoom if
    -- already zoomed") - a right-click doesn't reliably fire OnEnter first
    -- on every code path, so pinning must be able to start the zoom itself,
    -- not only preserve one already in progress - and skips the OnLeave
    -- hook above for as long as it stays pinned. `SetHoverZoomPinned(false)`
    -- un-pins and, since the mouse is very likely no longer actually over
    -- the frame by then, immediately reverts the zoom itself too (same
    -- effect OnLeave would have had) rather than waiting for a real
    -- OnLeave that may never come.
    function frame:SetHoverZoomPinned(isPinned)
        pinned = isPinned and true or false
        if pinned then
            baseLevel = baseLevel or self:GetFrameLevel()
            self:SetFrameLevel(baseLevel + 20)
            self:SetScale(1 + growPercent)
        elseif not self:IsMouseOver() then
            self:SetScale(1)
            if baseLevel then
                self:SetFrameLevel(baseLevel)
            end
        end
    end
end

-- Mini favourite hover: at rest only the icon and its 1px gold edge exist.
-- On hover this overlay has EXACTLY the same square bounds as the slot. Since
-- the parent slot itself is scaled, icon, gold edge and decorative texture all
-- grow together without the ornament being inset or oversized.
function Theme.ApplyOuterIconHover(frame)
    if frame.ornament then frame.ornament:SetAlpha(0) end
    if frame.innerGlow then frame.innerGlow:SetAlpha(0) end

    local ring = SB.CreateFrame("Frame", nil, frame)
    ring:SetAllPoints(frame)
    ring:SetBackdrop({ edgeFile = WHITE, edgeSize = 1 })
    ring:SetBackdropBorderColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], 1)
    ring:SetFrameLevel(frame:GetFrameLevel() + 5)
    ring:EnableMouse(false)

    local ornament = ring:CreateTexture(nil, "OVERLAY")
    ornament:SetPoint("CENTER", ring, "CENTER", 0, 0)
    ornament:SetTexture(ICON_FRAME)
    ornament:SetTexCoord(0, 1, 0, 1)
    ornament:SetVertexColor(0.88, 0.94, 1.0, 1)
    ring.ornament = ornament

    ring:Hide()
    frame.outerHoverRing = ring

    frame:HookScript("OnEnter", function(self)
        if self.soundbookHoverDisabled or not self.texture or not self.texture:IsShown() then
            ring:Hide()
            return
        end
        -- The source art draws its filigree well inside its canvas. Make
        -- that canvas 150% of the hovered icon so the painted frame lives
        -- around the icon rather than stamping across its picture.
        ornament:SetSize(self:GetWidth() * 1.50, self:GetHeight() * 1.50)
        ring:SetFrameLevel(self:GetFrameLevel() + 5)
        ring:Show()
    end)
    frame:HookScript("OnLeave", function() ring:Hide() end)
end

-- Concise, consistent help used by the Settings page. For labelled
-- checkboxes the invisible label click-bridge owns the mouse, so mirror
-- the tooltip hooks onto it as well.
function Theme.AttachTooltip(frame, title, body)
    if not frame then return end
    local function OnEnter(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title or "Help", 1, 0.82, 0)
        if body and body ~= "" then
            GameTooltip:AddLine(body, 0.86, 0.90, 0.96, true)
        end
        GameTooltip:Show()
    end
    local function OnLeave()
        GameTooltip:Hide()
    end
    frame:HookScript("OnEnter", OnEnter)
    frame:HookScript("OnLeave", OnLeave)
    if frame.clickBridge then
        frame.clickBridge:HookScript("OnEnter", OnEnter)
        frame.clickBridge:HookScript("OnLeave", OnLeave)
    end
end

-- A flat rectangular button: solid fill, 1px border, brightens on hover -
-- used instead of UIPanelButtonTemplate's carved-stone look.
function Theme.CreateFlatButton(parent, text, width, height, variant)
    variant = variant or "secondary"
    local btn = SB.CreateFrame("Button", nil, parent)
    btn:SetSize(width or 120, height or 22)
    btn:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })

    local label = btn:CreateFontString(nil, "OVERLAY")
    label:SetFontObject(SB.Fonts.HighlightSmall)
    label:SetPoint("CENTER")
    label:SetText(text or "")
    label:SetTextColor(unpack(Theme.TEXT))
    btn.label = label

    local function ApplyState(state)
        if not btn:IsEnabled() then
            btn:SetBackdropColor(0.018, 0.035, 0.060, 0.62)
            btn:SetBackdropBorderColor(0.30, 0.34, 0.40, 0.35)
            label:SetTextColor(0.46, 0.50, 0.57)
            return
        end
        label:SetTextColor(unpack(Theme.TEXT))
        if variant == "primary" then
            btn:SetBackdropColor(state == "hover" and 0.10 or 0.055, state == "hover" and 0.24 or 0.15, state == "hover" and 0.52 or 0.38, 0.98)
        else
            btn:SetBackdropColor(state == "hover" and 0.07 or 0.028, state == "hover" and 0.18 or 0.09, state == "hover" and 0.38 or 0.24, 0.96)
        end
        btn:SetBackdropBorderColor(Theme.GOLD[1], Theme.GOLD[2], Theme.GOLD[3], state == "hover" and 1 or 0.82)
        if state == "hover" then label:SetTextColor(0.86, 0.92, 1.0) end
    end
    btn.ApplyThemeState = ApplyState
    btn:SetScript("OnEnter", function() ApplyState("hover") end)
    btn:SetScript("OnLeave", function() ApplyState("idle") end)
    btn:HookScript("OnEnable", function() ApplyState("idle") end)
    btn:HookScript("OnDisable", function() ApplyState("disabled") end)
    ApplyState("idle")

    return btn
end

function Theme.CreatePrimaryButton(parent, text, width, height)
    return Theme.CreateFlatButton(parent, text, width, height, "primary")
end

function Theme.CreateSecondaryButton(parent, text, width, height)
    return Theme.CreateFlatButton(parent, text, width, height)
end

-- Shared square "mini control" chrome (flat backdrop, border, hover/
-- pressed tint) - used for every small button in the Mini Soundbook's
-- header row (Lock/Mute/Close) so they all read as ONE consistent
-- button family - same size, fill, border, hover and pressed states -
-- instead of a mix of styles (an isolated bare-text "x" next to a plain
-- colour dot). Each specific glyph below just adds its own inner icon on
-- top of this same chrome.
function Theme.CreateMiniControlButton(parent, size)
    size = size or 16
    local btn = SB.CreateFrame("Button", nil, parent)
    btn:SetSize(size, size)
    btn:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })

    -- Soundbook 2.0 visual pass: idle has NO box/border at all now - just
    -- the bare icon glyph, so the header reads as icons floating on the
    -- panel rather than a row of buttons - explicit request. Hover reads
    -- as a soft Arcane Cyan-edged glow (targeted correction round: "gold
    -- for active/important states, Arcane Blue/Cyan for hover
    -- interaction" - hover previously used gold too, indistinguishable
    -- from a pressed/active state), and pressed keeps gold (not the
    -- blurple ACCENT, which reads as violet against this dark navy -
    -- explicit request to remove that tone).
    local function Idle()
        btn:SetBackdropColor(0, 0, 0, 0)
        btn:SetBackdropBorderColor(0, 0, 0, 0)
    end
    local function Hover()
        btn:SetBackdropColor(0.04, 0.14, 0.24, 0.80)
        btn:SetBackdropBorderColor(unpack(Theme.ARCANE_HOVER))
    end
    local function Pressed()
        btn:SetBackdropColor(Theme.GOLD[1] * 0.32, Theme.GOLD[2] * 0.32, Theme.GOLD[3] * 0.32, 0.9)
        btn:SetBackdropBorderColor(unpack(Theme.GOLD))
    end

    btn:SetScript("OnEnter", Hover)
    btn:SetScript("OnLeave", Idle)
    btn:SetScript("OnMouseDown", Pressed)
    btn:SetScript("OnMouseUp", function() if btn:IsMouseOver() then Hover() else Idle() end end)
    Idle()

    return btn
end

-- "x" close - same chrome as the rest of the row now, instead of an
-- isolated bare-text glyph with no border/fill of its own. Uses
-- Assets/CloseIcon.tga (purpose-supplied artwork, same gold-frame/
-- blue-glass set as SettingsGear.tga/AudioIcon.tga) rather than
-- ControlIcons.tga's own close quadrant, so all three header-icon
-- buttons this addon draws are one consistent, coordinated set.
function Theme.CreateCloseGlyph(parent, size)
    local btn = Theme.CreateMiniControlButton(parent, size or 16)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexture(CLOSE_ICON)
    btn.icon = icon
    return btn
end

-- Lock/move toggle: a small padlock while fixed, four-way movement arrows
-- while the Mini Soundbook can be moved.  Built from textures so it stays
-- legible regardless of the selected font.
function Theme.CreateLockGlyph(parent, size)
    size = size or 16
    local btn = Theme.CreateMiniControlButton(parent, size)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexture(CONTROL_ICONS)
    icon:SetTexCoord(0.00, 0.25, 0, 1)
    function btn:SetLocked(locked)
        if locked then
            icon:SetVertexColor(1, 0.82, 0.38, 1)
        else
            icon:SetVertexColor(0.42, 0.72, 1.0, 0.82)
        end
    end
    btn.icon = icon
    btn:SetLocked(false)
    return btn
end

-- Filled square "Stop" icon - explicit request: a real drawn/textured
-- shape, not a WoW-font-dependent Unicode glyph (a "block" character isn't
-- guaranteed to exist/render in every font this addon lets players pick
-- for the Mini Soundbook).
function Theme.CreateStopGlyph(parent, size)
    size = size or 16
    local btn = Theme.CreateMiniControlButton(parent, size)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexture(CONTROL_ICONS)
    icon:SetTexCoord(0.50, 0.75, 0, 1)
    btn.icon = icon
    return btn
end

-- Remote audio action: red square means the next click mutes receiving;
-- green Play triangle means the next click unmutes it. The glyph describes
-- the click's action rather than merely repeating the current state.
function Theme.CreateMuteGlyph(parent, size)
    size = size or 16
    local btn = Theme.CreateMiniControlButton(parent, size)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexture(CONTROL_ICONS)
    icon:SetTexCoord(0.25, 0.50, 0, 1)
    btn.icon = icon
    function btn:SetMuted(muted)
        if muted then
            icon:SetVertexColor(1.0, 0.34, 0.34, 1)
        else
            icon:SetVertexColor(1.0, 0.88, 0.48, 1)
        end
    end
    btn:SetMuted(false)
    return btn
end

-- Quick Audio (Main window header) - explicit report: this used to reuse
-- CreateMuteGlyph's own atlas quadrant, which is a speaker-WITH-SLASH
-- drawing - reads as "muted" even though Quick Audio just opens a menu,
-- not a mute toggle. Assets/AudioIcon.tga is dedicated, purpose-supplied
-- artwork (a plain speaker + sound-wave arcs, no slash) in the exact same
-- gold-frame/blue-glass style as the rest of this header's icon set -
-- already fully coloured, so never vertex-tinted. Not WoW item/spell/
-- inventory artwork, same explicit requirement as the Settings gear.
function Theme.CreateAudioGlyph(parent, size)
    size = size or 16
    local btn = Theme.CreateMiniControlButton(parent, size)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexture(AUDIO_ICON)
    btn.icon = icon
    return btn
end

-- Settings gear (Main window header, top-left) - explicit requirement:
-- a compact gear icon button replacing the old external "Settings" text
-- tab, and explicitly NOT a WoW item/spell/inventory icon (an earlier
-- attempt reused WoW's built-in Trade_Engineering texture, which reads
-- as a bug/beetle at this size rather than a gear - explicit report).
-- Assets/SettingsGear.tga is a purpose-made navy/gold/arcane gear glyph
-- (Assets/ControlIcons.tga's own atlas is a binary sprite sheet that
-- can't be extended with a new quadrant from here, hence its own file).
-- Already carries its own baked colour, so unlike the atlas-based glyphs
-- above this one is never vertex-tinted - only its alpha changes between
-- idle and active, to keep the artwork's own colour true.
function Theme.CreateSettingsGlyph(parent, size)
    size = size or 16
    local btn = Theme.CreateMiniControlButton(parent, size)
    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 2, -2)
    icon:SetPoint("BOTTOMRIGHT", -2, 2)
    icon:SetTexture(SETTINGS_GEAR)
    btn.icon = icon
    function btn:SetActive(active)
        icon:SetAlpha(active and 1 or 0.72)
    end
    btn:SetActive(false)
    return btn
end

local function CreateCheckCore(parent, size)
    local check = SB.CreateFrame("CheckButton", nil, parent)
    check:SetSize(size or 16, size or 16)
    check:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })

    check:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    local checkedTex = check:GetCheckedTexture()
    checkedTex:ClearAllPoints()
    checkedTex:SetPoint("TOPLEFT", -3, 3)
    checkedTex:SetPoint("BOTTOMRIGHT", 3, -3)

    local hovering = false
    local function ApplyLook()
        if not check:IsEnabled() then
            check:SetBackdropColor(0.02, 0.03, 0.05, 0.55)
            check:SetBackdropBorderColor(0.32, 0.35, 0.40, 0.34)
            checkedTex:SetVertexColor(0.42, 0.45, 0.50, 0.62)
        elseif check:GetChecked() then
            check:SetBackdropColor(0.03, 0.09, 0.18, 0.96)
            check:SetBackdropBorderColor(Theme.ACCENT[1], Theme.ACCENT[2], Theme.ACCENT[3], hovering and 1 or 0.82)
            checkedTex:SetVertexColor(0.72, 0.86, 1.0, 1)
        else
            check:SetBackdropColor(unpack(Theme.BG_INPUT))
            if hovering then
                check:SetBackdropBorderColor(Theme.ACCENT[1], Theme.ACCENT[2], Theme.ACCENT[3], 0.72)
            else
                check:SetBackdropBorderColor(Theme.GOLD_DIM[1], Theme.GOLD_DIM[2], Theme.GOLD_DIM[3], 0.58)
            end
            checkedTex:SetVertexColor(0.72, 0.86, 1.0, 1)
        end
    end

    local nativeSetChecked = check.SetChecked
    check.SetChecked = function(self, value)
        nativeSetChecked(self, value)
        ApplyLook()
    end
    function check:SetThemeHover(value)
        hovering = value and true or false
        ApplyLook()
    end
    check:HookScript("OnEnter", function(self) self:SetThemeHover(true) end)
    check:HookScript("OnLeave", function(self) self:SetThemeHover(false) end)
    check:HookScript("OnEnable", ApplyLook)
    check:HookScript("OnDisable", ApplyLook)
    check.ApplyThemeState = ApplyLook
    ApplyLook()
    return check
end

-- Matrix cells and labelled settings checkboxes intentionally share this
-- exact core so checked/unchecked/hover/disabled never look like two UI kits.
function Theme.CreateToggleTile(parent, size, onToggle)
    local tile = CreateCheckCore(parent, size or 18)
    tile:SetScript("OnClick", function(self)
        self:ApplyThemeState()
        if onToggle then onToggle(self:GetChecked() and true or false) end
    end)
    return tile
end

function Theme.CreateCheckbox(parent, label, onClick)
    local check = CreateCheckCore(parent, 16)

    local text = check:CreateFontString(nil, "OVERLAY")
    text:SetFontObject(SB.Fonts.HighlightSmall)
    text:SetPoint("LEFT", check, "RIGHT", 6, 0)
    text:SetText(label or "")
    check.text = text

    check:SetScript("OnClick", function(self)
        self:ApplyThemeState()
        if onClick then onClick(self:GetChecked() and true or false) end
    end)

    -- Explicit requirement: clicking the LABEL must toggle the checkbox
    -- too, not just its own tiny 16x16 glyph. A separate, wider invisible
    -- button spanning glyph+label sits on top and simply simulates a real
    -- click on `check` (Button:Click() - fires the exact same native
    -- toggle + OnClick script above, no separate checked-state to keep in
    -- sync) - and carries its own hover highlight across the WHOLE row,
    -- since `check`'s own highlight can no longer show once this covers it.
    local clickBridge = SB.CreateFrame("Button", nil, parent)
    clickBridge:SetPoint("TOPLEFT", check, "TOPLEFT", 0, 0)
    clickBridge:SetHeight(16)
    clickBridge:SetScript("OnClick", function() check:Click() end)
    check.clickBridge = clickBridge
    check:HookScript("OnDisable", function()
        clickBridge:Disable()
        text:SetTextColor(unpack(Theme.TEXT_DIM))
    end)
    check:HookScript("OnEnable", function()
        clickBridge:Enable()
        text:SetTextColor(unpack(Theme.TEXT))
    end)

    clickBridge:HookScript("OnEnter", function()
        check:SetThemeHover(true)
        text:SetTextColor(0.78, 0.88, 1.0)
    end)
    clickBridge:HookScript("OnLeave", function()
        check:SetThemeHover(false)
        text:SetTextColor(unpack(check:IsEnabled() and Theme.TEXT or Theme.TEXT_DIM))
    end)

    -- clickBridge is parented to `parent` (this checkbox's own container),
    -- not to `check` itself - so hiding `check` alone (a caller that only
    -- wants this checkbox to conditionally exist at all, e.g. EditWindow.
    -- lua's "only for a sound that has X") would otherwise leave an
    -- invisible, still-clickable dead zone sitting there. Overriding Show/
    -- Hide/SetShown here to also propagate to clickBridge fixes this once
    -- for every caller instead of requiring each one to remember to hide
    -- both separately.
    local origShow, origHide = check.Show, check.Hide
    check.Show = function(self, ...)
        origShow(self, ...)
        clickBridge:Show()
    end
    check.Hide = function(self, ...)
        origHide(self, ...)
        clickBridge:Hide()
    end
    check.SetShown = function(self, shown, ...)
        if shown then self:Show() else self:Hide() end
    end

    -- Label width isn't known until its text is actually set, and can
    -- change later (a caller touching check.text:SetText(...) directly) -
    -- resized on both, so the bridge never falls short of (or overshoots)
    -- the label it's supposed to cover.
    local function ResizeBridge()
        clickBridge:SetWidth(16 + 6 + (text:GetStringWidth() or 0))
    end
    ResizeBridge()

    local origSetText = text.SetText
    text.SetText = function(self, ...)
        origSetText(self, ...)
        ResizeBridge()
    end

    return check
end

-- A flat EditBox: dark fill, 1px border, no carved-stone InputBoxTemplate
-- artwork.
function Theme.CreateInputBox(parent, width, height)
    local box = SB.CreateFrame("EditBox", nil, parent)
    box:SetSize(width or 150, height or Theme.METRICS.controlHeight)
    box:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    box:SetBackdropColor(unpack(Theme.BG_INPUT))
    box:SetBackdropBorderColor(unpack(Theme.GOLD_DIM))
    box:SetFontObject(SB.Fonts.HighlightSmall)
    box:SetTextInsets(6, 6, 0, 0)
    box:SetAutoFocus(false)
    -- Hooked (not SetScript) so callers can still set their own
    -- OnEditFocusGained/Lost (e.g. to save the typed value) without
    -- clobbering this border highlight - both fire.
    box:HookScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(unpack(Theme.GOLD))
    end)
    box:HookScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(unpack(Theme.GOLD_DIM))
    end)
    return box
end

-- A flat slider: thin track, accent-coloured fill up to the current value,
-- a small square thumb, and a live value label to the right - no
-- carved-stone OptionsSliderTemplate artwork. `onChange(value)` fires on
-- every value change (including from dragging). `formatFn(value)`
-- optionally formats the label (default "NN%"), e.g. for a non-percent
-- slider like a duration in seconds.
function Theme.CreateSlider(parent, minVal, maxVal, step, width, onChange, formatFn)
    local slider = SB.CreateFrame("Slider", nil, parent)
    slider:SetOrientation("HORIZONTAL")
    slider:SetSize(width or 150, 14)
    slider:SetMinMaxValues(minVal, maxVal)
    slider:SetValueStep(step or 1)
    if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end

    slider:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    slider:SetBackdropColor(0, 0, 0, 0.35)
    slider:SetBackdropBorderColor(unpack(Theme.BORDER_DIM))

    local fill = slider:CreateTexture(nil, "ARTWORK")
    fill:SetPoint("TOPLEFT", 1, -1)
    fill:SetPoint("BOTTOMLEFT", 1, 1)
    fill:SetWidth(1)
    fill:SetTexture(WHITE)
    fill:SetVertexColor(unpack(Theme.ACCENT))
    slider.fill = fill

    slider:SetThumbTexture(WHITE)
    local thumb = slider:GetThumbTexture()
    thumb:SetSize(8, 18)
    thumb:SetVertexColor(1, 1, 1, 1)

    local valueText = parent:CreateFontString(nil, "OVERLAY")
    valueText:SetFontObject(SB.Fonts.HighlightSmall)
    valueText:SetPoint("LEFT", slider, "RIGHT", 8, 0)
    slider.valueText = valueText

    local function Refresh()
        local lo, hi = slider:GetMinMaxValues()
        local value = slider:GetValue()
        local pct = (hi > lo) and (value - lo) / (hi - lo) or 0
        local trackW = math.max(2, slider:GetWidth() - 2)
        fill:SetWidth(math.max(0.01, trackW * pct))
        if formatFn then
            valueText:SetText(formatFn(value))
        else
            valueText:SetText(string.format("%d%%", math.floor(value + 0.5)))
        end
    end
    slider.Refresh = Refresh

    slider:SetScript("OnValueChanged", function(self, value)
        Refresh()
        if onChange then onChange(value) end
    end)
    slider:SetScript("OnSizeChanged", Refresh)

    return slider
end

-- A flat, scrollable dropdown - a bordered button that opens a floating
-- list of options below it, instead of Blizzard's carved-stone
-- UIDropDownMenu. The list is its own top-level frame (parented to
-- UIParent, not wherever the button lives), so it's never clipped by a
-- surrounding ScrollFrame (e.g. the Settings panel) and always draws on
-- top. Mouse wheel scrolls the list once it has more rows than fit in
-- `maxVisibleRows`; a thin flat scroll thumb on the right edge shows
-- there's more to see.
--
-- Returns a table: dd.button (the anchor frame, for positioning) plus
-- dd:SetOptions({ {text=, value=}, ... }), dd:SetValue(value) (updates the
-- label without firing the callback), dd:SetOnChange(fn), and an optional
-- dd:SetRowFont(fn) where fn(fontString, option) can further style a row
-- (and the button's own label) - e.g. to preview each choice in its own
-- typeface.
function Theme.CreateDropdown(parent, width, height, maxVisibleRows)
    width = width or 200
    height = height or 22
    maxVisibleRows = maxVisibleRows or 8
    local ROW_H = 20

    local dd = {}
    local options = {}
    local selectedValue
    local onChange
    local optionsProvider
    local rowFontFn

    local button = SB.CreateFrame("Button", nil, parent)
    button:SetSize(width, height)
    button:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    button:SetBackdropColor(unpack(Theme.BG_INPUT))
    button:SetBackdropBorderColor(unpack(Theme.GOLD_DIM))
    dd.button = button

    local label = button:CreateFontString(nil, "OVERLAY")
    label:SetFontObject(SB.Fonts.HighlightSmall)
    label:SetPoint("LEFT", 8, 0)
    label:SetPoint("RIGHT", -20, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    dd.label = label

    local arrow = button:CreateFontString(nil, "OVERLAY")
    arrow:SetFontObject(SB.Fonts.HighlightSmall)
    arrow:SetPoint("RIGHT", -6, 0)
    arrow:SetText("v")
    arrow:SetTextColor(unpack(Theme.GOLD))

    button:HookScript("OnEnter", function() button:SetBackdropBorderColor(unpack(Theme.GOLD)) end)
    button:HookScript("OnLeave", function() button:SetBackdropBorderColor(unpack(Theme.GOLD_DIM)) end)

    -- Full-screen invisible catcher: shown only while the list is open, so
    -- a click anywhere outside the list closes it - the standard way to
    -- fake a dropdown's "click away to dismiss" without a real menu system.
    local catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("TOOLTIP")
    catcher:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    catcher:Hide()

    local list = SB.CreateFrame("Frame", nil, UIParent)
    list:SetFrameStrata("TOOLTIP")
    list:SetFrameLevel(catcher:GetFrameLevel() + 1)
    list:Hide()
    -- Explicit requirement: stays fully on-screen (left/right edges too,
    -- on top of OpenList's own up/down flip below) instead of being able
    -- to run off the side for a dropdown sitting near a screen edge.
    list:SetClampedToScreen(true)
    list:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    list:SetBackdropColor(unpack(Theme.BG_RAISED))
    list:SetBackdropBorderColor(Theme.GOLD_DIM[1], Theme.GOLD_DIM[2], Theme.GOLD_DIM[3], 0.72)
    -- Actually clip rows to the list's own bounds - without this, once
    -- there are more options than maxVisibleRows, the extra rows would
    -- just render past the bottom edge instead of being scrolled away.
    if list.SetClipsChildren then list:SetClipsChildren(true) end

    local scrollChild = CreateFrame("Frame", nil, list)
    scrollChild:SetPoint("TOPLEFT", 1, -1)
    scrollChild:SetPoint("RIGHT", -1, 0)
    scrollChild.offset = 0

    local thumb = list:CreateTexture(nil, "OVERLAY")
    thumb:SetTexture(WHITE)
    thumb:SetVertexColor(Theme.ACCENT[1], Theme.ACCENT[2], Theme.ACCENT[3], 0.58)
    thumb:SetWidth(2)
    thumb:Hide()

    local rows = {}

    local function CloseList()
        list:Hide()
        catcher:Hide()
    end
    catcher:SetScript("OnClick", CloseList)

    local function ApplyScroll()
        local visibleRows = math.min(#options, maxVisibleRows)
        local totalH = #options * ROW_H
        local viewH = visibleRows * ROW_H
        local maxOffset = math.max(0, totalH - viewH)
        scrollChild.offset = math.max(0, math.min(scrollChild.offset, maxOffset))
        scrollChild:ClearAllPoints()
        scrollChild:SetPoint("TOPLEFT", 1, -1 + scrollChild.offset)
        scrollChild:SetPoint("RIGHT", -1, 0)

        if maxOffset > 0 then
            thumb:Show()
            local trackH = viewH - 2
            local thumbH = math.max(12, trackH * (viewH / totalH))
            local thumbY = (trackH - thumbH) * (scrollChild.offset / maxOffset)
            thumb:ClearAllPoints()
            thumb:SetPoint("TOPRIGHT", list, "TOPRIGHT", -2, -1 - thumbY)
            thumb:SetHeight(thumbH)
        else
            thumb:Hide()
        end
    end

    list:SetScript("OnMouseWheel", function(_, delta)
        scrollChild.offset = scrollChild.offset - delta * ROW_H
        ApplyScroll()
    end)

    local function BuildRows()
        for i, opt in ipairs(options) do
            local row = rows[i]
            if not row then
                row = SB.CreateFrame("Button", nil, scrollChild)
                row:SetHeight(ROW_H)
                local hl = row:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(Theme.ACCENT[1], Theme.ACCENT[2], Theme.ACCENT[3], 0.12)
                local text = row:CreateFontString(nil, "OVERLAY")
                text:SetFontObject(SB.Fonts.HighlightSmall)
                text:SetJustifyH("LEFT")
                row.text = text
                -- Optional right-aligned suffix (e.g. a player's Soundbook
                -- version, one size down - see SB.ComputeOutputTargetOptions'
                -- own opt.suffix/opt.suffixColor) - a separate fontstring so
                -- it can never overlap-truncate the main label's own text.
                local suffix = row:CreateFontString(nil, "OVERLAY")
                suffix:SetFontObject(SB.Fonts.DisableSmall)
                suffix:SetPoint("RIGHT", -6, 0)
                suffix:SetWidth(46)
                suffix:SetJustifyH("RIGHT")
                row.suffix = suffix
                rows[i] = row
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
            row:SetPoint("RIGHT", 0, 0)
            row.text:SetText(opt.text)
            row.text:SetTextColor(unpack(Theme.TEXT))
            -- Optional per-option indent (e.g. a player's name sitting
            -- under its own group header) - re-applied every render since
            -- pooled row objects get reused across different option sets,
            -- not just set once at creation.
            row.text:ClearAllPoints()
            row.text:SetPoint("LEFT", 6 + (opt.indent or 0), 0)
            row.text:SetPoint("RIGHT", opt.suffix and -58 or -6, 0)
            if opt.suffix then
                row.suffix:SetText(opt.suffix)
                row.suffix:SetTextColor(unpack(opt.suffixColor or Theme.TEXT_DIM))
                row.suffix:Show()
            else
                row.suffix:Hide()
            end
            if rowFontFn then rowFontFn(row.text, opt) end
            -- Optional disabled option (explicit requirement: unavailable
            -- choices must be CLEARLY disabled, not just silently
            -- unselectable) - dimmed text, no highlight, clicking it does
            -- nothing at all (not even closes the list, so a player can
            -- still see it's there and pick something else).
            if opt.disabled then
                row.text:SetTextColor(unpack(Theme.TEXT_DIM))
                row:EnableMouse(false)
            else
                row:EnableMouse(true)
            end
            row.value = opt.value
            row:SetScript("OnClick", function()
                if opt.disabled then return end
                selectedValue = opt.value
                label:SetText(opt.text)
                if rowFontFn then rowFontFn(label, opt) end
                if onChange then onChange(opt.value) end
                CloseList()
            end)
            row:Show()
        end
        for i = #options + 1, #rows do
            rows[i]:Hide()
        end
        scrollChild:SetHeight(math.max(1, #options * ROW_H))
    end

    local function OpenList()
        if optionsProvider then options = optionsProvider() end
        BuildRows()
        scrollChild.offset = 0
        local visibleRows = math.min(#options, maxVisibleRows)
        local listHeight = math.max(ROW_H, visibleRows * ROW_H) + 2
        list:SetSize(width, listHeight)

        -- Explicit requirement: open UPWARD instead when there isn't
        -- enough room below the button (e.g. this dropdown sits near the
        -- bottom of the screen) - GetBottom() is already "how much space
        -- is there between this button's bottom edge and the screen's own
        -- bottom edge", in the same coordinate space listHeight is in, so
        -- no separate scale conversion is needed to compare them.
        list:ClearAllPoints()
        local roomBelow = button:GetBottom() or 0
        if roomBelow < listHeight then
            list:SetPoint("BOTTOMLEFT", button, "TOPLEFT", 0, 2)
        else
            list:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -2)
        end

        ApplyScroll()
        catcher:Show()
        list:Show()
    end

    button:SetScript("OnClick", function()
        if list:IsShown() then
            CloseList()
        else
            OpenList()
        end
    end)

    function dd:SetOptions(newOptions)
        options = newOptions
    end

    function dd:SetValue(value)
        selectedValue = value
        for _, opt in ipairs(options) do
            if opt.value == value then
                label:SetText(opt.text)
                if rowFontFn then rowFontFn(label, opt) end
                return
            end
        end
        -- Not (or no longer) in the option list - e.g. an LSM font whose
        -- providing addon got disabled - fall back to showing the raw
        -- value rather than leaving the label blank.
        label:SetText(value or "")
    end

    function dd:SetOnChange(fn)
        onChange = fn
    end

    -- Optional: fn() returning a fresh { {text=,value=}, ... } list, called
    -- right before the list opens each time - for options that can change
    -- during the session (e.g. fonts registered by other addons via LSM).
    function dd:SetOptionsProvider(fn)
        optionsProvider = fn
    end

    function dd:SetRowFont(fn)
        rowFontFn = fn
    end

    function dd:GetValue()
        return selectedValue
    end

    -- Exposed for callers that need to manage this dropdown's list as part
    -- of a larger popup's own lifecycle (e.g. Announcer.lua's Quick
    -- Options closing its Popout Direction dropdown too, and including
    -- the open list's bounds in a proximity-dismiss check) - `list` and
    -- `catcher` are separate top-level frames parented to UIParent, not
    -- real children of `button`, so hiding the dropdown's owner does NOT
    -- cascade to hide these on its own.
    function dd:CloseList()
        CloseList()
    end

    function dd:IsListOpen()
        return list:IsShown()
    end

    function dd:GetListFrame()
        return list
    end

    return dd
end

-- A flat scrollable area: plain ScrollFrame + mouse-wheel scrolling + a
-- thin accent-coloured thumb (shown only once there's actually more to
-- scroll) - instead of Blizzard's carved-stone UIPanelScrollFrameTemplate
-- arrows/thumb. Returns { scroll = <ScrollFrame>, content = <child Frame -
-- put things in this>, UpdateThumb = <call after changing content's
-- height> }.
function Theme.CreateScrollFrame(parent)
    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:EnableMouseWheel(true)

    local content = CreateFrame("Frame", nil, scroll)
    scroll:SetScrollChild(content)

    -- A real draggable Button now, not just a passive texture - explicit
    -- requirement: dragging the thumb must scroll exactly like the mouse
    -- wheel does, not just visually reflect wheel-driven position after
    -- the fact (which is all the old texture-only thumb could ever do).
    local thumb = CreateFrame("Button", nil, scroll)
    thumb:SetWidth(3)
    thumb:EnableMouse(true)
    thumb:RegisterForDrag("LeftButton")
    thumb:Hide()

    local thumbTex = thumb:CreateTexture(nil, "OVERLAY")
    thumbTex:SetAllPoints()
    thumbTex:SetTexture(WHITE)
    thumbTex:SetVertexColor(Theme.ACCENT[1], Theme.ACCENT[2], Theme.ACCENT[3], 0.34)

    local function UpdateThumb()
        local scrollH = scroll:GetHeight() or 0
        local contentH = content:GetHeight() or 0
        local maxScroll = math.max(0, contentH - scrollH)
        if maxScroll <= 1 or scrollH <= 0 then
            thumb:Hide()
            return
        end
        thumb:Show()
        local current = scroll:GetVerticalScroll()
        local thumbH = math.max(20, scrollH * (scrollH / contentH))
        local thumbY = (scrollH - thumbH) * (current / maxScroll)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 0, -thumbY)
        thumb:SetHeight(thumbH)
    end

    scroll:SetScript("OnMouseWheel", function(self, delta)
        local scrollH = self:GetHeight() or 0
        local contentH = content:GetHeight() or 0
        local maxScroll = math.max(0, contentH - scrollH)
        local current = self:GetVerticalScroll()
        local new = math.max(0, math.min(maxScroll, current - delta * 40))
        self:SetVerticalScroll(new)
        UpdateThumb()
    end)

    -- Drag-to-scroll - same SetVerticalScroll the wheel handler above uses,
    -- so both always agree on direction/position (dragging the thumb down
    -- moves the cursor DOWN the screen, i.e. GetCursorPosition()'s own Y
    -- decreases - that must scroll content further down, i.e. increase
    -- VerticalScroll, which is exactly what a positive
    -- startCursorY-currentCursorY delta below drives).
    local dragging = false
    local dragStartCursorY, dragStartScroll, dragTrackH, dragThumbH
    local function DragUpdate()
        local _, cursorY = GetCursorPosition()
        local scale = scroll:GetEffectiveScale()
        local screenDelta = (dragStartCursorY - cursorY) / scale
        local contentH = content:GetHeight() or 0
        local maxScroll = math.max(0, contentH - dragTrackH)
        local trackRange = math.max(1, dragTrackH - dragThumbH)
        local new = math.max(0, math.min(maxScroll, dragStartScroll + screenDelta * (maxScroll / trackRange)))
        scroll:SetVerticalScroll(new)
        UpdateThumb()
    end

    thumb:SetScript("OnDragStart", function()
        dragging = true
        thumb:SetScript("OnUpdate", DragUpdate)
        thumbTex:SetVertexColor(Theme.ACCENT[1], Theme.ACCENT[2], Theme.ACCENT[3], 0.95)
        local _, cursorY = GetCursorPosition()
        dragStartCursorY = cursorY
        dragStartScroll = scroll:GetVerticalScroll()
        dragTrackH = scroll:GetHeight() or 0
        dragThumbH = thumb:GetHeight() or 0
    end)
    thumb:SetScript("OnDragStop", function()
        dragging = false
        thumb:SetScript("OnUpdate", nil)
        thumbTex:SetVertexColor(Theme.ACCENT[1], Theme.ACCENT[2], Theme.ACCENT[3], 0.50)
    end)
    thumb:SetScript("OnEnter", function()
        thumbTex:SetVertexColor(Theme.ACCENT[1], Theme.ACCENT[2], Theme.ACCENT[3], 0.82)
    end)
    thumb:SetScript("OnLeave", function()
        if not dragging then
            thumbTex:SetVertexColor(Theme.ACCENT[1], Theme.ACCENT[2], Theme.ACCENT[3], 0.34)
        end
    end)
    scroll:SetScript("OnSizeChanged", UpdateThumb)
    content:SetScript("OnSizeChanged", UpdateThumb)

    return { scroll = scroll, content = content, UpdateThumb = UpdateThumb }
end
