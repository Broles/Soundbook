-- EditWindow.lua
-- Right-click on any sound opens this ONE popup for everything about that
-- sound: an icon preview + "Change Icon" (opens IconPicker.lua's own
-- popup), display name, favourite/muted/alternate, per-sound Default
-- Output, and its macro command - a compact modal, not a big embedded
-- icon grid (3.0 spec section 42).

local ADDON_NAME, SB = ...

local WINDOW_W = 390

-- Macro Command and Macro Output side by side, same row (explicit request -
-- Ctrl+C copying never worked reliably enough to earn its own dedicated
-- Copy button, and the two rows stacked on top of each other wasted a full
-- row's height that this window doesn't need to spend). Same full-row
-- width the Default Output dropdown above uses (WINDOW_W - 56), split into
-- two equal columns with a small gap between them.
local MACRO_COL_GAP = 10
local MACRO_COL_W = math.floor((WINDOW_W - 56 - MACRO_COL_GAP) / 2)

local edit
local currentSoundID
local draft
local originalDraft
local dirty = false
local closingConfirmed = false
local confirmFrame
local modalBlocker

-- Compares the live draft against the snapshot taken when this sound was
-- opened (OpenEditWindow) - explicit vs. a blunt "any handler fired" flag,
-- so clicking into the name field and back out without typing anything
-- doesn't wrongly trigger the unsaved-changes prompt (3.0 spec section 46).
local function RecomputeDirty()
    if not originalDraft or not draft then dirty = false; return end
    dirty = draft.icon ~= originalDraft.icon
        or draft.name ~= originalDraft.name
        or draft.favourite ~= originalDraft.favourite
        or draft.muted ~= originalDraft.muted
        or draft.useAlternate ~= originalDraft.useAlternate
        or draft.outputOverride ~= originalDraft.outputOverride
        or draft.macroTarget ~= originalDraft.macroTarget
end

-- Explicit request: the Macro Output dropdown ONLY (not Default Output
-- above it, not the Soundbook/Mini Soundbook dropdowns elsewhere) shows a
-- shorter "All (check Settings)" for the top "ALL" row instead of the
-- usual "All (checked in Settings)" - it has roughly half the row width to
-- work with (two columns sharing one row, see MACRO_COL_W above) and the
-- longer text was truncating. Wraps the same shared
-- SB.ComputeOutputTargetOptions everything else uses rather than
-- duplicating its whole option-building logic.
local function MacroOutputOptions()
    local opts = SB.ComputeOutputTargetOptions()
    if opts[1] and opts[1].value == "ALL" then
        opts[1].text = "All (check Settings)"
    end
    return opts
end

-- Unsaved-changes confirmation (3.0 spec section 46) - "Discard unsaved
-- changes? [Keep Editing] [Discard]", shown instead of silently closing.
local function BuildConfirmDialog()
    if confirmFrame then return confirmFrame end
    local f = SB.CreateFrame("Frame", nil, UIParent)
    f:SetSize(280, 104)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    SB.Theme.Panel(f)
    f:Hide()

    local text = f:CreateFontString(nil, "OVERLAY")
    text:SetFontObject(SB.Fonts.Highlight)
    text:SetPoint("TOP", 0, -26)
    text:SetText("Discard unsaved changes?")
    text:SetTextColor(unpack(SB.Theme.TEXT))

    local keepBtn = SB.Theme.CreateSecondaryButton(f, "Keep Editing", 118, 26)
    keepBtn:SetPoint("BOTTOMLEFT", 14, 16)
    keepBtn:SetScript("OnClick", function() f:Hide() end)

    -- onClick is (re)assigned fresh by ShowDiscardConfirm below each time -
    -- "discard" means something different depending on why this was
    -- raised (closing the window vs. switching to editing a different
    -- sound while this one has unsaved changes).
    f.discardBtn = SB.Theme.CreatePrimaryButton(f, "Discard", 118, 26)
    f.discardBtn:SetPoint("BOTTOMRIGHT", -14, 16)

    confirmFrame = f
    return f
end

-- `onDiscard` runs if the player confirms discarding the current draft.
local function ShowDiscardConfirm(onDiscard)
    local f = BuildConfirmDialog()
    f.discardBtn:SetScript("OnClick", function()
        f:Hide()
        dirty = false
        onDiscard()
    end)
    f:Show()
end

local function BuildFrame()
    if edit then return edit end

    modalBlocker = CreateFrame("Button", nil, UIParent)
    modalBlocker:SetAllPoints(UIParent)
    modalBlocker:SetFrameStrata("DIALOG")
    modalBlocker:EnableMouse(true)
    modalBlocker:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local shade = modalBlocker:CreateTexture(nil, "BACKGROUND")
    shade:SetAllPoints()
    shade:SetColorTexture(0, 0, 0, 0)
    modalBlocker:Hide()

    edit = SB.CreateFrame("Frame", "SoundbookEditWindow", UIParent)
    -- 3.0 spec section 42: the icon grid is no longer permanently embedded
    -- here (a "Change Icon" button opens IconPicker.lua's own popup
    -- instead) - this window is correspondingly much more compact than the
    -- pre-3.0 512px version.
    edit:SetSize(WINDOW_W, 372) -- content-driven modal with a small safe inset below
                                 -- (trimmed from 565 - that value was sized
                                 -- back when Macro Output still sat on its
                                 -- own row BELOW Macro Command; once the two
                                 -- moved onto the same row side by side, a
                                 -- full row's worth of height was freed up
                                 -- below Save/Cancel but this fixed size was
                                 -- never shrunk to match, leaving unused
                                 -- empty space at the bottom - explicit
                                 -- report).
                                 -- Close button is anchored to the Macro Output dropdown
                                 -- above it, not to this height, so as long as this is TALL
                                 -- ENOUGH nothing clips - any extra just becomes a small
                                 -- margin below the button, never a gap above it.
    edit:SetPoint("CENTER")
    edit:SetFrameStrata("DIALOG")
    edit:SetFrameLevel(modalBlocker:GetFrameLevel() + 10)
    SB.Theme.Panel(edit)
    edit:SetMovable(true)
    edit:EnableMouse(true)
    edit:RegisterForDrag("LeftButton")
    edit:SetScript("OnDragStart", edit.StartMoving)
    edit:SetScript("OnDragStop", edit.StopMovingOrSizing)
    edit:SetClampedToScreen(true)
    edit:SetToplevel(true)
    edit:Hide()

    -- Clicking the transparent modal area outside Edit Sound is exactly
    -- equivalent to Cancel: close without applying the draft. The edit
    -- frame sits above this blocker, so clicks inside remain untouched.
    modalBlocker:SetScript("OnClick", function()
        if edit and edit:IsShown() then edit:Hide() end
    end)

    tinsert(UISpecialFrames, "SoundbookEditWindow") -- Escape key closes it

    SB.Theme.CreateHeader(edit, "Edit Sound", 52)

    local closeBtn = SB.Theme.CreateCloseGlyph(edit, 20)
    closeBtn:SetPoint("TOPRIGHT", -8, -8)
    closeBtn:SetScript("OnClick", function() edit:Hide() end)

    -- Icon preview + "Change Icon" (3.0 spec section 42) - opens
    -- IconPicker.lua's own virtualized popup instead of permanently
    -- dedicating a big part of this window to an embedded grid.
    local iconSlot = SB.Theme.CreateIconSlot(edit, 46)
    iconSlot:SetPoint("TOPLEFT", 24, -62)
    edit.iconPreview = iconSlot.texture
    edit.iconSlot = iconSlot

    local changeIconBtn = SB.Theme.CreateSecondaryButton(edit, "Change Icon", 92, 20)
    changeIconBtn:SetPoint("TOP", iconSlot, "BOTTOM", 0, -6)
    changeIconBtn:SetScript("OnClick", function()
        if not currentSoundID then return end
        SB.OpenIconPicker(function(path)
            draft.icon = path
            edit.iconPreview:SetTexture(path)
            RecomputeDirty()
        end, draft.icon)
    end)
    edit.changeIconBtn = changeIconBtn

    local nameLabel = edit:CreateFontString(nil, "OVERLAY")
    nameLabel:SetFontObject(SB.Fonts.HighlightSmall)
    nameLabel:SetPoint("TOPLEFT", iconSlot, "TOPRIGHT", 12, 2)
    nameLabel:SetText("Display Name")
    nameLabel:SetTextColor(0.60, 0.80, 1.0)

    local nameBox = SB.Theme.CreateInputBox(edit, WINDOW_W - 140, 22)
    nameBox:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 6, -4)
    nameBox:SetMaxLetters(50)
    nameBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    nameBox:SetScript("OnEditFocusLost", function(self)
        if not currentSoundID then return end
        draft.name = self:GetText()
        RecomputeDirty()
    end)
    edit.nameBox = nameBox

    -- Favourite / Muted checkboxes
    -- (forward-declared so the onClick closure below - defined as part of
    -- creating it - can still refer to it by the time it's actually clicked)
    local favCheck
    favCheck = SB.Theme.CreateCheckbox(edit, "Favourite", function(checked)
        if not currentSoundID then return end
        draft.favourite = checked and true or false
        RecomputeDirty()
    end)
    favCheck:SetPoint("TOPLEFT", changeIconBtn, "BOTTOMLEFT", 0, -14)
    edit.favCheck = favCheck

    local muteCheck = SB.Theme.CreateCheckbox(edit, "Muted", function(checked)
        if not currentSoundID then return end
        draft.muted = checked and true or false
        RecomputeDirty()
    end)
    muteCheck:SetPoint("LEFT", favCheck, "RIGHT", 90, 0)
    edit.muteCheck = muteCheck

    -- "Alternative Sound" (SoundAlternates.lua, explicit request) - only
    -- ever shown for a sound that actually HAS a registered alternate file
    -- (hidden otherwise in SB.OpenEditWindow below, not just disabled) -
    -- offering a checkbox that does nothing for 99% of sounds would just
    -- be confusing. Checking it substitutes that player's own local
    -- playback with a license-safe alternate version of this sound (not
    -- necessarily a self-made recording - any alternate that doesn't
    -- trip a copyright system works), on this client only - everyone
    -- else, and the network soundID itself, are unaffected.
    local altCheck = SB.Theme.CreateCheckbox(edit, "Alternative Sound", function(checked)
        if not currentSoundID then return end
        draft.useAlternate = checked and true or false
        -- Live preview - the purple wash reflects the DRAFT state
        -- immediately, before Save is even clicked, same as every other
        -- checkbox here already behaves purely on `draft` until Save.
        edit.iconSlot:SetAlternate(draft.useAlternate)
        RecomputeDirty()
    end)
    altCheck:SetPoint("LEFT", muteCheck, "RIGHT", 90, 0)
    edit.altCheck = altCheck
    SB.Theme.AttachTooltip(altCheck, "Alternative Sound",
        "Plays a license-safe alternative instead, just for you - everyone else still hears the original. Useful if the original triggers automatic copyright mutes (e.g. on Twitch).")

    -- "Default Output" (explicit request) - a PER-SOUND override of
    -- Settings' own global Default Output Channel, for a REGULAR click on
    -- this sound (Soundbook grid or Mini Soundbook) - completely separate
    -- from "Macro Output" further below, which only ever affects the
    -- copied macro text, never a normal click. "All" (default) means no
    -- override - the sound just follows Settings -> Default Output
    -- Channel like every other sound. Same options/styling as every other
    -- output-target dropdown in the addon (SB.ComputeOutputTargetOptions/
    -- SB.OutputTargetRowFont) - see SB:ResolveOutputTarget/
    -- SB.SoundOutputOverrideColor (Communication.lua) for how this is
    -- actually applied and coloured everywhere the sound's icon appears.
    local defaultOutputLabel = edit:CreateFontString(nil, "OVERLAY")
    defaultOutputLabel:SetFontObject(SB.Fonts.HighlightSmall)
    defaultOutputLabel:SetPoint("TOPLEFT", favCheck, "BOTTOMLEFT", 4, -14)
    defaultOutputLabel:SetText("Default Output (overrides Settings for this sound)")
    defaultOutputLabel:SetTextColor(0.60, 0.80, 1.0)

    local defaultOutputDD = SB.Theme.CreateDropdown(edit, WINDOW_W - 56, 22, 12)
    defaultOutputDD.button:SetPoint("TOPLEFT", defaultOutputLabel, "BOTTOMLEFT", -6, -6)
    defaultOutputDD:SetOnChange(function(value)
        if not currentSoundID then return end
        draft.outputOverride = (value ~= "ALL") and value or nil
        -- Live preview - the border/wash reflect the DRAFT state
        -- immediately, before Save is even clicked, same as every other
        -- control here.
        local color = draft.outputOverride and SB.OutputOverrideColorForTarget
            and SB.OutputOverrideColorForTarget(draft.outputOverride)
        edit.iconSlot:SetOutputTint(color)
        edit.iconSlot:SetVisualState("normal", draft.favourite, draft.muted, color)
        RecomputeDirty()
    end)
    edit.defaultOutputDD = defaultOutputDD
    SB.Theme.AttachTooltip(defaultOutputDD.button, "Default Output",
        "This sound always goes to this target on a normal click, regardless of Settings' own Default Output Channel.")

    -- Macro Command (left column) and Macro Output (right column), side by
    -- side on the same row (explicit request - Ctrl+C copying was never
    -- reliable enough to deserve its own dedicated button, and the two
    -- controls stacked on separate rows wasted a full row of height this
    -- window doesn't need to spend). Both anchored to the SAME row via
    -- defaultOutputDD.button above, just at different X offsets.
    -- Explicit bugfix: this row used to sit 10px further right than
    -- defaultOutputDD's own left edge with no matching adjustment on the
    -- right, so the whole row (Macro Command + gap + Macro Output) actually
    -- ran a few px PAST defaultOutputDD's own right edge instead of ending
    -- flush with it - visible as Macro Output's dropdown text truncating
    -- more than its raw half-width alone would explain ("All (checked in
    -- Sett...)"). -6 here (matching the label-sits-6px-left-of-its-own-
    -- control pattern already used everywhere else in this window) makes
    -- macroBox's actual left edge land exactly on defaultOutputDD.button's
    -- own left edge - see outputLabel below for the matching right-edge fix.
    local macroLabel = edit:CreateFontString(nil, "OVERLAY")
    macroLabel:SetFontObject(SB.Fonts.HighlightSmall)
    macroLabel:SetPoint("TOPLEFT", defaultOutputDD.button, "BOTTOMLEFT", -6, -14)
    macroLabel:SetText("Macro Command (read-only)")
    macroLabel:SetTextColor(0.60, 0.80, 1.0)

    local macroBox = SB.Theme.CreateInputBox(edit, MACRO_COL_W, 22)
    macroBox:SetPoint("TOPLEFT", macroLabel, "BOTTOMLEFT", 6, -6)
    macroBox:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    macroBox:SetBackdropColor(0.008, 0.020, 0.040, 0.82)
    -- WoW's EditBox leaves the cursor (and therefore its horizontal scroll)
    -- wherever it last was after SetText - for a box that's never actually
    -- focused/typed into, that's the END of the string by default, showing
    -- the tail of the macro command instead of its start (explicit report:
    -- "es::Weiss Nicht Digga" instead of the real command's beginning).
    -- SetCursorPosition(0) after every SetText fixes that.
    local function SetMacroBoxText(text)
        macroBox:SetText(text)
        macroBox:SetCursorPosition(0)
    end
    macroBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    macroBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    macroBox:SetScript("OnEditFocusLost", function(self)
        -- Read-only in spirit: whatever was typed is discarded and it
        -- snaps back to the real command on focus loss.
        if currentSoundID then
            SetMacroBoxText(SB:GetMacroString(currentSoundID, draft and draft.macroTarget))
        end
    end)
    edit.macroBox = macroBox
    edit.SetMacroBoxText = SetMacroBoxText

    -- Macro Output - who this specific sound's macro sends to, on top of
    -- always playing locally. "All" (default) leaves the macro exactly as
    -- "/sb play <id>", following Settings -> Default Output Channel like
    -- any other trigger; picking a channel or person here appends a
    -- "::<Target>" the macro carries with it from then on, overriding that
    -- setting for THIS macro only (see Macros.lua / Communication.lua's
    -- SB:DispatchDefaultOutput).
    -- See macroLabel's own comment above - this +6 (not +10) is what
    -- actually makes outputDD's right edge land exactly on
    -- defaultOutputDD.button's own right edge, matching MACRO_COL_W's own
    -- WINDOW_W-56-based math instead of overshooting it by a few px.
    local outputLabel = edit:CreateFontString(nil, "OVERLAY")
    outputLabel:SetFontObject(SB.Fonts.HighlightSmall)
    outputLabel:SetPoint("TOPLEFT", defaultOutputDD.button, "BOTTOMLEFT", 6 + MACRO_COL_W + MACRO_COL_GAP, -14)
    outputLabel:SetText("Macro Output")
    outputLabel:SetTextColor(0.60, 0.80, 1.0)

    local outputDD = SB.Theme.CreateDropdown(edit, MACRO_COL_W, 22, 12)
    outputDD.button:SetPoint("TOPLEFT", outputLabel, "BOTTOMLEFT", -6, -6)
    outputDD:SetOnChange(function(value)
        if not currentSoundID then return end
        draft.macroTarget = (value ~= "ALL") and value or nil
        edit.SetMacroBoxText(SB:GetMacroString(currentSoundID, draft.macroTarget))
        RecomputeDirty()
    end)
    edit.outputDD = outputDD

    local MACRO_HINT_TEXT = "Click to select all, then Ctrl+C to copy. Paste as the body of a macro you create yourself, using this sound's icon if you like."
    local macroHint = edit:CreateFontString(nil, "OVERLAY")
    macroHint:SetFontObject(SB.Fonts.DisableSmall)
    -- Flush with macroBox's own left edge, not further left than it
    -- (explicit report: this text's leading characters were getting cut
    -- off - it was anchored 6px to the LEFT of macroBox, which itself
    -- already sits at the leftmost edge of this window's whole form).
    macroHint:SetPoint("TOPLEFT", macroBox, "BOTTOMLEFT", 0, -4)
    macroHint:SetPoint("RIGHT", -20, 0)
    macroHint:SetJustifyH("LEFT")
    macroHint:SetWordWrap(true)
    macroHint:SetText(MACRO_HINT_TEXT)
    edit.macroHint = macroHint
    -- Captured once, right after the hint's real color is set above, so the
    -- "Selected" flash below can revert to it exactly rather than guessing
    -- at SB.Fonts.DisableSmall's own color.
    local macroHintR, macroHintG, macroHintB, macroHintA = macroHint:GetTextColor()

    -- NOTE: WoW's Lua API has no way to write to the OS clipboard directly
    -- (no C_System.SetClipboard or equivalent exists on any client,
    -- Classic/TBC/Anniversary or Retail) - Ctrl+C only works because
    -- EditBox is a real native text field once text is actually selected
    -- inside it, and that OS-level copy happens outside Lua entirely. A
    -- true one-click "already in the clipboard, no Ctrl+C needed" is
    -- therefore not something any addon can do - explicit request: the
    -- dedicated Copy button attempting to shortcut this was removed since
    -- it never actually copied anything more reliably than this click-to-
    -- select-then-Ctrl+C flow already does on its own. What this DOES do:
    -- select the whole macro string on a single click (so you don't have
    -- to drag-select it yourself first) and confirm that with a brief
    -- flash - Ctrl+C is still the one step that actually copies it.
    local macroSelectedTimer
    local function ShowMacroSelectedFeedback()
        macroHint:SetText("Selected - press Ctrl+C to copy")
        macroHint:SetTextColor(unpack(SB.Theme.ACCENT))
        if macroSelectedTimer then macroSelectedTimer:Cancel() end
        macroSelectedTimer = C_Timer.NewTimer(1.5, function()
            macroHint:SetText(MACRO_HINT_TEXT)
            macroHint:SetTextColor(macroHintR, macroHintG, macroHintB, macroHintA)
        end)
    end

    local function OnMacroBoxActivated(self)
        self:HighlightText()
        ShowMacroSelectedFeedback()
    end
    macroBox:SetScript("OnEditFocusGained", OnMacroBoxActivated)
    macroBox:SetScript("OnMouseUp", OnMacroBoxActivated)

    -- Close button - anchored right below the last real control (the Macro
    -- Command/Output hint text, now the lowest element since Macro Output
    -- moved up alongside Macro Command) with a small fixed gap, NOT to the
    -- window's own bottom edge. Keeps the gap above it constant no matter
    -- what gets added/changed above in the future, instead of silently
    -- growing every time this window's content changes but its fixed
    -- SetSize height doesn't shrink to match.
    local saveButton = SB.Theme.CreatePrimaryButton(edit, "Save", 136, 28)
    saveButton:SetPoint("TOPRIGHT", macroHint, "BOTTOM", -4, -16)
    saveButton:SetScript("OnClick", function()
        if not currentSoundID or not draft then return end
        -- 3.0 spec section 43: a full Favourite list must not block saving
        -- everything else this window controls - only the Favourite change
        -- itself is reverted (with clear inline feedback), the rest of the
        -- draft (name/icon/mute/output/macro) always saves regardless.
        local favouriteApplied = true
        if draft.favourite and not SB:IsFavourite(currentSoundID) then
            favouriteApplied = SB:AddFavourite(currentSoundID)
        elseif not draft.favourite and SB:IsFavourite(currentSoundID) then
            SB:RemoveFavourite(currentSoundID)
        end
        local saved = SB:GetSoundSaved(currentSoundID)
        saved.icon = draft.icon
        saved.muted = draft.muted
        if SB.AnalyticsSetPersonalMute then SB:AnalyticsSetPersonalMute(currentSoundID, draft.muted) end
        saved.macroTarget = draft.macroTarget
        saved.useAlternate = draft.useAlternate
        saved.outputOverride = draft.outputOverride
        SB:SetSoundDisplayName(currentSoundID, draft.name)
        SB:Fire("SOUND_DISPLAY_CHANGED", currentSoundID)
        dirty = false
        -- A Save while the "discard unsaved changes?" prompt happened to
        -- be up (e.g. it was raised by switching sounds, then the player
        -- saved instead) resolves it - nothing left to discard.
        if confirmFrame then confirmFrame:Hide() end
        if not favouriteApplied then
            SB:Print(string.format("All %d Favourite slots are currently occupied - everything else was saved.", SB.MAX_FAVOURITES))
            draft.favourite = false
            favCheck:SetChecked(false)
            return -- stay open so the player sees why Favourite reverted
        end
        edit:Hide()
    end)
    edit.saveButton = saveButton

    local cancelButton = SB.Theme.CreateSecondaryButton(edit, "Cancel", 136, 28)
    cancelButton:SetPoint("TOPLEFT", macroHint, "BOTTOM", 4, -16)
    cancelButton:SetScript("OnClick", function() edit:Hide() end)
    edit.cancelButton = cancelButton

    local formWell = edit:CreateTexture(nil, "BACKGROUND")
    formWell:SetPoint("TOPLEFT", iconSlot, "TOPLEFT", -10, 10)
    formWell:SetPoint("BOTTOMRIGHT", macroHint, "BOTTOMRIGHT", 10, -12)
    formWell:SetTexture("Interface\\Buttons\\WHITE8X8")
    formWell:SetVertexColor(0.004, 0.018, 0.045, 0.64)

    local formTop = edit:CreateTexture(nil, "BORDER")
    formTop:SetPoint("TOPLEFT", formWell, "TOPLEFT", 0, 0)
    formTop:SetPoint("TOPRIGHT", formWell, "TOPRIGHT", 0, 0)
    formTop:SetHeight(1)
    formTop:SetTexture("Interface\\Buttons\\WHITE8X8")
    formTop:SetVertexColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.42)

    edit:SetScript("OnShow", function() modalBlocker:Show() end)
    -- Catches EVERY close path uniformly (X button, Cancel, Escape - via
    -- UISpecialFrames, which calls :Hide() directly - and a click on the
    -- modal blocker below) - a single choke point instead of duplicating
    -- the dirty-check in each one. If there are unsaved changes, the
    -- window is immediately re-shown (same-frame, before anything renders
    -- hidden) and the confirmation dialog takes over from there; Discard
    -- sets closingConfirmed so this same handler lets the next Hide()
    -- through.
    edit:SetScript("OnHide", function()
        modalBlocker:Hide()
        GameTooltip:Hide()
        if dirty and not closingConfirmed then
            edit:Show()
            ShowDiscardConfirm(function()
                closingConfirmed = true
                edit:Hide()
            end)
            return
        end
        closingConfirmed = false
    end)

    return edit
end

local function PopulateEditWindow(soundID)
    currentSoundID = soundID
    local saved = SB:GetSoundSaved(soundID)

    -- Only offer the checkbox at all for a sound that actually HAS a
    -- registered alternate (SoundAlternates.lua) - see altCheck's own
    -- comment above.
    local hasAlternate = SB.SoundAlternates and SB.SoundAlternates[soundID] ~= nil

    draft = {
        icon = SB:GetSoundIcon(soundID),
        name = SB:GetSoundDisplayName(soundID),
        favourite = SB:IsFavourite(soundID),
        muted = saved.muted and true or false,
        macroTarget = saved.macroTarget,
        useAlternate = hasAlternate and saved.useAlternate and true or false,
        outputOverride = saved.outputOverride,
    }
    originalDraft = {
        icon = draft.icon, name = draft.name, favourite = draft.favourite,
        muted = draft.muted, useAlternate = draft.useAlternate,
        outputOverride = draft.outputOverride, macroTarget = draft.macroTarget,
    }
    dirty = false
    closingConfirmed = false

    edit.iconPreview:SetTexture(draft.icon)
    edit.iconSlot:SetAlternate(draft.useAlternate)
    local outputColor = SB.OutputOverrideColorForTarget and SB.OutputOverrideColorForTarget(draft.outputOverride)
    edit.iconSlot:SetOutputTint(outputColor)
    edit.iconSlot:SetVisualState("normal", draft.favourite, draft.muted, outputColor)
    edit.nameBox:SetText(draft.name)
    edit.SetMacroBoxText(SB:GetMacroString(soundID, saved.macroTarget))

    edit.favCheck:SetChecked(draft.favourite)
    edit.muteCheck:SetChecked(draft.muted)
    edit.altCheck:SetShown(hasAlternate)
    edit.altCheck:SetChecked(draft.useAlternate)

    edit.outputDD:SetOptions(MacroOutputOptions())
    edit.outputDD:SetOptionsProvider(MacroOutputOptions)
    edit.outputDD:SetRowFont(SB.OutputTargetRowFont)
    edit.outputDD:SetValue(saved.macroTarget or "ALL")

    -- Same options as every other output-target dropdown - every group
    -- always shows, regardless of current membership (see
    -- SB.ComputeOutputTargetOptions's own comment).
    edit.defaultOutputDD:SetOptions(SB.ComputeOutputTargetOptions())
    edit.defaultOutputDD:SetOptionsProvider(SB.ComputeOutputTargetOptions)
    edit.defaultOutputDD:SetRowFont(SB.OutputTargetRowFont)
    edit.defaultOutputDD:SetValue(draft.outputOverride or "ALL")

    edit:Show()
end

-- Right-clicking a DIFFERENT sound while this one still has unsaved
-- changes must not silently discard them either (3.0 spec section 46) -
-- same confirmation as closing the window, just switching to the new
-- sound on Discard instead of hiding.
function SB.OpenEditWindow(soundID)
    local info = SB.registry[soundID]
    if not info then return end
    BuildFrame()

    if edit:IsShown() and dirty and currentSoundID ~= soundID then
        ShowDiscardConfirm(function() PopulateEditWindow(soundID) end)
        return
    end
    PopulateEditWindow(soundID)
end

function SB.IsEditWindowShownFor(soundID)
    return edit and edit:IsShown() and currentSoundID == soundID
end

-- Right-clicking the sound that's already open closes the window again
-- instead of just re-populating it.
function SB.ToggleEditWindow(soundID)
    if SB.IsEditWindowShownFor(soundID) then
        edit:Hide()
    else
        SB.OpenEditWindow(soundID)
    end
end

SB:On("FAVOURITES_CHANGED", function()
    if edit and edit:IsShown() and currentSoundID then
        edit.favCheck:SetChecked(SB:IsFavourite(currentSoundID))
    end
end)
