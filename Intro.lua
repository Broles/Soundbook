-- Intro.lua
-- One-time first-run popup (Soundbook 1.9.1, "safer first start") -
-- explains local playback, sending, and Favourites in a few short lines,
-- then marks itself seen and never shows again unless manually restarted
-- from Settings -> Help & Information -> "Replay Introduction". Deliberately
-- small and temporary - not a permanent fixture, never overloads the main window.
-- Only ever auto-shown for a genuinely fresh install (SB.isFreshInstall,
-- Core.lua) - an existing install's own introSeen defaults to true, so
-- ApplyDefaults never turns this on retroactively for someone already
-- using the addon.

local ADDON_NAME, SB = ...

-- WINDOW_H grown by one card's worth (66 + 9 gap) to fit the new 4th
-- ("ADD YOUR OWN SOUNDS") step below the original 3, with roughly the same
-- breathing room above the "Let's make some noise" button the original
-- 350/3-card layout had.
local WINDOW_W, WINDOW_H = 440, 430
local WHITE_TEX = "Interface\\Buttons\\WHITE8X8"
local popup

local function BuildPopup()
    if popup then return popup end

    popup = SB.CreateFrame("Frame", "SoundbookIntroWindow", UIParent)
    popup:SetSize(WINDOW_W, WINDOW_H)
    popup:SetPoint("CENTER")
    popup:SetFrameStrata("DIALOG")
    SB.Theme.Panel(popup)
    popup:SetMovable(true)
    popup:EnableMouse(true)
    popup:RegisterForDrag("LeftButton")
    popup:SetScript("OnDragStart", popup.StartMoving)
    popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
    popup:SetClampedToScreen(true)
    popup:SetToplevel(true)
    popup:Hide()

    tinsert(UISpecialFrames, "SoundbookIntroWindow") -- Escape key closes it

    local fontPath = (SB.db and SB.db.settings and SB.db.settings.mainFont)
        or SB.AVAILABLE_FONTS[1].path

    local title = popup:CreateFontString(nil, "OVERLAY")
    title:SetFont(fontPath, 22, "OUTLINE")
    title:SetPoint("TOP", 0, -18)
    title:SetText("Welcome to Soundbook")
    title:SetTextColor(1, 0.82, 0)

    local subtitle = popup:CreateFontString(nil, "OVERLAY")
    subtitle:SetFont(fontPath, 12, "")
    subtitle:SetPoint("TOP", title, "BOTTOM", 0, -5)
    subtitle:SetText("Your sounds. One click away.")
    subtitle:SetTextColor(unpack(SB.Theme.TEXT_DIM))

    local closeBtn = SB.Theme.CreateCloseGlyph(popup, 18)
    closeBtn:SetPoint("TOPRIGHT", -8, -8)
    closeBtn:SetScript("OnClick", function() popup:Hide() end)

    -- `extraRightPad` (only step 1 uses it) reserves room on the right edge
    -- for the clickable sound button sitting on top of that card, so the
    -- heading/description text never runs underneath it.
    local function CreateStep(anchor, signalColor, number, heading, description, extraRightPad)
        local rightPad = 12 + (extraRightPad or 0)
        local card = SB.CreateFrame("Frame", nil, popup)
        card:SetSize(WINDOW_W - 40, 66)
        card:SetPoint("TOP", anchor, "BOTTOM", 0, -9)
        card:SetBackdrop({ bgFile = WHITE_TEX, edgeFile = WHITE_TEX, edgeSize = 1 })
        card:SetBackdropColor(SB.Theme.BG_RAISED[1], SB.Theme.BG_RAISED[2], SB.Theme.BG_RAISED[3], 0.92)
        card:SetBackdropBorderColor(signalColor[1], signalColor[2], signalColor[3], 0.75)

        local signal = card:CreateTexture(nil, "ARTWORK")
        signal:SetTexture(WHITE_TEX)
        signal:SetPoint("TOPLEFT", 0, 0)
        signal:SetPoint("BOTTOMLEFT", 0, 0)
        signal:SetWidth(4)
        signal:SetVertexColor(signalColor[1], signalColor[2], signalColor[3], 1)

        local badge = card:CreateFontString(nil, "OVERLAY")
        badge:SetFont(fontPath, 18, "OUTLINE")
        badge:SetPoint("LEFT", 17, 0)
        badge:SetText(number)
        badge:SetTextColor(signalColor[1], signalColor[2], signalColor[3])

        local head = card:CreateFontString(nil, "OVERLAY")
        head:SetFont(fontPath, 13, "OUTLINE")
        head:SetPoint("TOPLEFT", 52, -11)
        head:SetPoint("RIGHT", -rightPad, 0)
        head:SetJustifyH("LEFT")
        head:SetText(heading)
        head:SetTextColor(signalColor[1], signalColor[2], signalColor[3])

        local copy = card:CreateFontString(nil, "OVERLAY")
        copy:SetFont(fontPath, 11, "")
        copy:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -5)
        copy:SetPoint("RIGHT", -rightPad, 0)
        copy:SetJustifyH("LEFT")
        copy:SetWordWrap(true)
        copy:SetText(description)
        copy:SetTextColor(unpack(SB.Theme.TEXT))
        return card
    end

    -- extraRightPad=44: the 34px sound button below plus its own 14px right
    -- margin and a small buffer, so the description text never runs under it.
    local playCard = CreateStep(subtitle, { 0.30, 0.95, 0.48 }, "1", "PLAY",
        "Click any sound. It plays instantly for you.", 44)

    -- Explicit request: a real, clickable sound button on step 1 itself -
    -- right-aligned with some margin from the card's right edge, vertically
    -- centred, no text - so "click any sound" is something you can actually
    -- try right there instead of just reading about it. SB:TriggerSound is
    -- the exact same call a normal Favourites-slot/main-window click makes,
    -- so this plays the sound AND produces the same Announcer banner a
    -- real click would - not a special-cased demo.
    local celebrationID = SB.MakeSoundID("Legacy", "Celebration")
    local PLAY_BTN_SIZE = 34
    local PLAY_BTN_MARGIN = 14
    local playBtn = SB.Theme.CreateIconSlot(playCard, PLAY_BTN_SIZE, { 0.30, 0.95, 0.48 }, "Button")
    -- Anchored via CENTER, not RIGHT - Theme.ApplyHoverZoom's SetScale
    -- always grows a frame symmetrically around whichever point it's
    -- anchored by, so CENTER is required for the zoom to read as
    -- "growing from the middle" rather than drifting sideways. The
    -- 14px-from-the-card's-right-edge position is computed once here
    -- (playCard's size never changes after creation, so there's no need
    -- to keep this dynamic).
    playBtn:SetPoint("CENTER", playCard, "RIGHT", -(PLAY_BTN_MARGIN + PLAY_BTN_SIZE / 2), 0)
    playBtn.texture:SetTexture(SB:GetSoundIcon(celebrationID))
    -- Explicit request: same hover-zoom feedback as the Mini Soundbook's
    -- favourite slots (see Theme.ApplyHoverZoom) - 15%, centred, allowed
    -- to cover neighbouring text/cards while zoomed.
    SB.Theme.ApplyHoverZoom(playBtn, 0.15)

    ----------------------------------------------------------------------
    -- Explicit request: clicking the sound button turns the whole step 1
    -- card into an 8-second "disco" - many thin Orange/Yellow/Red/White
    -- bars sweeping left-to-right and flickering, starting 0.75s after the
    -- click. Same kind of fast, flashy, continuously-sweeping colour-bar
    -- effect as the BrewEven addon's buy/sell success flash
    -- (MarketRows.lua's row.feedback), just different colours and a much
    -- longer (8s vs ~1.1s) one-shot run, driven by a manual OnUpdate the
    -- same way that one is (not WoW's AnimationGroup API). The "flicker"
    -- part BrewEven's own sweep doesn't have: each bar's alpha is
    -- re-rolled at a fixed short interval (not every frame - a smooth
    -- per-frame random would just blur into a shimmer, not read as an
    -- actual flicker) for a stroboscopic feel.
    ----------------------------------------------------------------------
    -- Explicit request: "mehr Gelb, mehr Orange" - orange and yellow each
    -- appear twice (red and white stay at one) so the sweep reads as
    -- mostly warm colours with red/white as accents, not four equal bars.
    local PLAY_DISCO_COLORS = {
        { 1.00, 0.55, 0.10 }, -- orange
        { 1.00, 0.85, 0.15 }, -- yellow
        { 0.95, 0.15, 0.15 }, -- red
        { 1.00, 1.00, 1.00 }, -- white
        { 1.00, 0.55, 0.10 }, -- orange
        { 1.00, 0.85, 0.15 }, -- yellow
    }
    local PLAY_DISCO_DELAY = 0.75
    local PLAY_DISCO_DURATION = 8
    local PLAY_DISCO_SPEED = 2.2         -- sweep cycles per second across the card's width
    local PLAY_DISCO_FLICKER_STEP = 0.06 -- re-roll each bar's brightness every 60ms
    local PLAY_DISCO_BAR_WIDTH = 28      -- explicit request: "deutlich breiter" (was 8)

    -- Explicit request: bars must stay fully inside the green-bordered
    -- card, never past its edges - SetClipsChildren (where this client
    -- supports it) is a belt-and-suspenders visual safety net; the actual
    -- guarantee is the sweep math below, which keeps every bar's full
    -- width between x=0 and x=width regardless of clipping support.
    local disco = SB.CreateFrame("Frame", nil, playCard)
    disco:SetAllPoints(playCard)
    disco:SetFrameLevel(playCard:GetFrameLevel() + 5)
    if disco.SetClipsChildren then disco:SetClipsChildren(true) end
    disco:Hide()

    local discoBars = {}
    for _, color in ipairs(PLAY_DISCO_COLORS) do
        local bar = disco:CreateTexture(nil, "ARTWORK")
        bar:SetColorTexture(color[1], color[2], color[3], 0.85)
        bar:SetWidth(PLAY_DISCO_BAR_WIDTH)
        table.insert(discoBars, bar)
    end

    -- Named (not an inline closure) so a second click can re-attach it -
    -- the handler detaches itself once the 8s run finishes, same pattern
    -- BrewEven's own row-feedback color-bar sweep uses.
    disco.onUpdateHandler = function(self, delta)
        self.elapsed = self.elapsed + delta
        if self.elapsed >= PLAY_DISCO_DURATION then
            self:Hide()
            self:SetScript("OnUpdate", nil)
            return
        end

        self.flickerElapsed = self.flickerElapsed + delta
        if self.flickerElapsed >= PLAY_DISCO_FLICKER_STEP then
            self.flickerElapsed = 0
            for i = 1, #discoBars do
                self.flicker[i] = 0.35 + math.random() * 0.65
            end
        end

        local width = self:GetWidth() or 300
        local numBars = #discoBars
        -- x ranges over [0, width - PLAY_DISCO_BAR_WIDTH] only - unlike the
        -- old [-10, width+10] range, a bar's full width is always inside
        -- the card, never overshooting either edge.
        local travel = math.max(0, width - PLAY_DISCO_BAR_WIDTH)
        for i, bar in ipairs(discoBars) do
            local phase = (self.elapsed * PLAY_DISCO_SPEED + (i - 1) / numBars) % 1
            local x = phase * travel
            bar:ClearAllPoints()
            bar:SetPoint("TOP", self, "TOPLEFT", x, 0)
            bar:SetPoint("BOTTOM", self, "BOTTOMLEFT", x, 0)
            bar:SetAlpha(self.flicker[i] or 1)
        end
    end

    local function PlayDisco()
        disco.elapsed = 0
        disco.flickerElapsed = 0
        disco.flicker = {}
        disco:Show()
        disco:SetScript("OnUpdate", disco.onUpdateHandler)
    end

    -- Defined only now that PLAY_DISCO_DELAY/PlayDisco above actually
    -- exist as locals (Lua doesn't hoist locals - assigning OnClick any
    -- earlier in this function would've captured a nil global instead).
    playBtn:RegisterForClicks("LeftButtonUp")
    playBtn:SetScript("OnClick", function()
        SB:TriggerSound(celebrationID)
        C_Timer.After(PLAY_DISCO_DELAY, PlayDisco)
    end)

    local shareCard = CreateStep(playCard, SB.Theme.ACCENT, "2", "CHOOSE WHO HEARS IT",
        "Start in Self mode, then choose Direct, Friends, Guild, Raid or Party when you want to share. Everyone who sends or receives Soundbook sounds needs the addon installed.")
    local customCard = CreateStep(shareCard, { 1, 0.72, 0.18 }, "3", "MAKE IT YOURS",
        "Shift + Left-click to favourite - up to 20 slots, always shown first in your Library. Drag to reorder them, and assign hotkeys to any slot in Settings.")

    -- Explicit request: a 4th, dimmer/grey entry pointing at the optional
    -- Soundbook_MySounds companion addon (see UI.lua's empty-category hint
    -- and SoundRegistry.lua for the same concept) - deliberately styled less
    -- prominent than steps 1-3 (grey, not one of the bright signal colours)
    -- since this is optional extra info, not a required onboarding step.
    CreateStep(customCard, SB.Theme.TEXT_DIM, "4", "ADD YOUR OWN SOUNDS",
        "Optional: the Soundbook_MySounds companion addon (CurseForge) lets you add your own extra .mp3/.ogg/.wav files safely, without losing them on a Soundbook update.")

    local gotItBtn = SB.Theme.CreatePrimaryButton(popup, "Let's make some noise", 190, 26)
    gotItBtn:SetPoint("BOTTOM", 0, 14)
    gotItBtn:SetScript("OnClick", function()
        popup:Hide()
        -- This is the positive end of onboarding: always land on page 1 of
        -- the bundled Default sounds, with no remembered search/settings
        -- state obscuring them.
        if SB.ShowDefaultSounds then
            SB:ShowDefaultSounds()
        elseif SB.ShowMainWindow then
            SB:ShowMainWindow()
        end
    end)

    -- Marks itself seen the moment it closes, however that happens (Got
    -- it, the "x", or Escape) - not just on the button click specifically.
    popup:SetScript("OnHide", function()
        if SB.db and SB.db.settings then
            SB.db.settings.introSeen = true
        end
    end)

    return popup
end

--- Shows the intro popup right now - used both for the real first-run
--- trigger below and Settings -> Help & Information -> "Replay Introduction".
function SB:ShowIntro()
    BuildPopup()
    popup:Show()
end

-- Real first-run trigger - a short delay after login so it doesn't fight
-- other addons'/the game's own loading-screen-adjacent popups for
-- attention, and re-checks introSeen right before actually showing (in
-- case the player already dismissed it, or restarted it manually, in that
-- brief window).
SB:On("PLAYER_LOGIN", function()
    if SB.db and SB.db.settings and not SB.db.settings.introSeen then
        C_Timer.After(2, function()
            if SB.db and SB.db.settings and not SB.db.settings.introSeen then
                SB:ShowIntro()
            end
        end)
    end
end)

-- Self-heal, same pattern/root cause as Announcer.lua's own PLAYER_LOGIN /
-- PLAYER_ENTERING_WORLD pair (see its comment: "the icon was invisible
-- right after login... A frame first Show()n mid-transition can end up not
-- actually painted even though it's logically shown"). The intro popup's
-- own PLAYER_LOGIN trigger above is a one-shot C_Timer - if it fires while
-- the client's loading-screen fade/UI transition hasn't genuinely finished
-- yet (slower machines, heavier addon lists), it can end up in that same
-- logically-shown-but-not-painted state with nothing left to force a
-- redraw. PLAYER_ENTERING_WORLD fires once the world is truly ready and
-- re-asserts here too - guarded so it only ever acts while the intro is
-- still genuinely unseen and not already visibly open, so it never
-- reshows/resets a popup the player is mid-reading or has closed.
SB:On("PLAYER_ENTERING_WORLD", function()
    if SB.db and SB.db.settings and not SB.db.settings.introSeen then
        if not (popup and popup:IsShown()) then
            SB:ShowIntro()
        end
    end
end)
