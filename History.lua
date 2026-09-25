-- History.lua
-- Persistent newest-first record of the last 10 sounds successfully received
-- from another Soundbook user. Replaying is always forced to SELF so reviewing
-- history can never broadcast the sound back to a group or player.

local ADDON_NAME, SB = ...

local MAX_HISTORY = 10
local WINDOW_W, WINDOW_H = 390, 505 -- exactly the Edit Sound footprint
local ROW_H, ROW_GAP = 38, 4
local historyFrame
local rows = {}
local emptyText

local function History()
    SB.db.history = SB.db.history or {}
    return SB.db.history
end

local function EntryName(entry)
    if entry.soundID and SB.registry[entry.soundID] then
        return SB:GetSoundDisplayName(entry.soundID)
    end
    return entry.soundName or entry.soundID or "Unknown sound"
end

local function EntryIcon(entry)
    if entry.soundID and SB.registry[entry.soundID] then
        return SB:GetSoundIcon(entry.soundID)
    end
    return entry.icon or "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- Midnight (00:00:00) of whatever calendar day `ts` falls on - used to
-- compare two timestamps by actual DATE, not a rolling "24h ago" window,
-- so "Today"/"Yesterday" flip over at midnight like a human would expect,
-- not exactly 24h/48h after the entry was received.
local function StartOfDay(ts)
    local t = date("*t", ts)
    t.hour, t.min, t.sec = 0, 0, 0
    return time(t)
end

-- "Today HH:MM" / "Yesterday HH:MM" for the last two calendar days,
-- explicit request - falls back to the previous "DD.MM. HH:MM" format for
-- anything older.
local function FormatHistoryStamp(ts)
    if not ts then return "Unknown time" end
    local timePart = date("%H:%M", ts)
    local startToday = StartOfDay(time())
    if StartOfDay(ts) == startToday then
        return "Today " .. timePart
    elseif StartOfDay(ts) == startToday - 86400 then
        return "Yesterday " .. timePart
    end
    return date("%d.%m. %H:%M", ts)
end

local function RefreshHistory()
    if not historyFrame then return end
    local history = History()
    emptyText:SetShown(#history == 0)
    for i = 1, MAX_HISTORY do
        local row = rows[i]
        local entry = history[i]
        if entry then
            row.entry = entry
            row.icon:SetTexture(EntryIcon(entry))
            row.name:SetText(EntryName(entry))
            local stamp = FormatHistoryStamp(entry.timestamp)
            -- Source coloured the same way as everywhere else in the addon
            -- (SB.GetChannelColor - Guild green, Raid orange, ...) -
            -- explicit request. An inline colour code only around this one
            -- segment, not row.meta's own base SetTextColor (TEXT_DIM,
            -- set once at row-build time below) - date/sender stay dim.
            local sourceLabel = entry.source or "Unknown source"
            local sourceColor = SB.GetChannelColor(sourceLabel)
            local coloredSource = string.format("|cff%s%s|r", sourceColor.hex, sourceLabel)
            row.meta:SetText(string.format("%s  |  %s  |  %s",
                stamp, entry.sender or "Unknown player", coloredSource))
            local available = entry.soundID and SB.registry[entry.soundID]
            row.name:SetTextColor(unpack(available and SB.Theme.GOLD or SB.Theme.TEXT_DIM))
            row:EnableMouse(available and true or false)
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
    end
end

local function BuildHistoryFrame()
    if historyFrame then return historyFrame end

    historyFrame = SB.CreateFrame("Frame", "SoundbookHistoryWindow", UIParent)
    historyFrame:SetSize(WINDOW_W, WINDOW_H)
    historyFrame:SetPoint("CENTER")
    historyFrame:SetFrameStrata("DIALOG")
    historyFrame:SetMovable(true)
    historyFrame:EnableMouse(true)
    historyFrame:RegisterForDrag("LeftButton")
    historyFrame:SetScript("OnDragStart", historyFrame.StartMoving)
    historyFrame:SetScript("OnDragStop", historyFrame.StopMovingOrSizing)
    historyFrame:SetClampedToScreen(true)
    historyFrame:SetToplevel(true)
    SB.Theme.Panel(historyFrame)
    historyFrame:Hide()
    tinsert(UISpecialFrames, "SoundbookHistoryWindow")

    SB.Theme.CreateHeader(historyFrame, "Received Sound History", 52)
    local closeBtn = SB.Theme.CreateCloseGlyph(historyFrame, 20)
    closeBtn:SetPoint("TOPRIGHT", -8, -8)
    closeBtn:SetScript("OnClick", function() historyFrame:Hide() end)

    emptyText = historyFrame:CreateFontString(nil, "OVERLAY")
    emptyText:SetFontObject(SB.Fonts.Highlight)
    emptyText:SetPoint("CENTER", 0, -6)
    emptyText:SetText("No received sounds yet.")
    emptyText:SetTextColor(unpack(SB.Theme.TEXT_DIM))

    for i = 1, MAX_HISTORY do
        local row = SB.CreateFrame("Button", nil, historyFrame)
        row:SetSize(WINDOW_W - 40, ROW_H)
        row:SetPoint("TOPLEFT", 20, -60 - (i - 1) * (ROW_H + ROW_GAP))
        row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        row:SetBackdropColor(0.01, 0.035, 0.075, (i % 2 == 0) and 0.78 or 0.58)
        row:SetBackdropBorderColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.32)
        row:RegisterForClicks("LeftButtonUp")

        local iconSlot = SB.Theme.CreateIconSlot(row, 30)
        iconSlot:SetPoint("LEFT", 4, 0)
        row.icon = iconSlot.texture

        local name = row:CreateFontString(nil, "OVERLAY")
        name:SetFontObject(SB.Fonts.HighlightSmall)
        name:SetPoint("TOPLEFT", iconSlot, "TOPRIGHT", 8, -3)
        name:SetPoint("RIGHT", -6, 0)
        name:SetJustifyH("LEFT")
        name:SetWordWrap(false)
        row.name = name

        local meta = row:CreateFontString(nil, "OVERLAY")
        meta:SetFontObject(SB.Fonts.DisableSmall)
        meta:SetPoint("BOTTOMLEFT", iconSlot, "BOTTOMRIGHT", 8, 3)
        meta:SetPoint("RIGHT", -6, 0)
        meta:SetJustifyH("LEFT")
        meta:SetWordWrap(false)
        meta:SetTextColor(unpack(SB.Theme.TEXT_DIM))
        row.meta = meta

        local highlight = row:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetAllPoints()
        highlight:SetColorTexture(SB.Theme.ACCENT[1], SB.Theme.ACCENT[2], SB.Theme.ACCENT[3], 0.12)

        row:SetScript("OnClick", function(self)
            if self.entry and self.entry.soundID and SB.registry[self.entry.soundID] then
                SB:TriggerSound(self.entry.soundID, "SELF")
            end
        end)
        row:SetScript("OnEnter", function(self)
            if not self.entry then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Replay for yourself", 1, 0.82, 0)
            GameTooltip:AddLine("This never sends the sound to anyone else.", 0.86, 0.90, 0.96, true)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rows[i] = row
    end

    historyFrame:SetScript("OnShow", RefreshHistory)
    return historyFrame
end

function SB:ShowHistoryWindow()
    BuildHistoryFrame():Show()
    RefreshHistory()
end

function SB:ToggleHistoryWindow()
    local frame = BuildHistoryFrame()
    if frame:IsShown() then frame:Hide() else self:ShowHistoryWindow() end
end

SB:On("TOGGLE_HISTORY_UI", function() SB:ToggleHistoryWindow() end)

SB:On("REMOTE_SOUND_PLAYED", function(soundID, sender, channelLabel)
    if not SB.db or not SB.registry[soundID] then return end
    local history = History()
    table.insert(history, 1, {
        soundID = soundID,
        soundName = SB:GetSoundDisplayName(soundID),
        icon = SB:GetSoundIcon(soundID),
        sender = sender or "Unknown player",
        source = channelLabel or "Unknown source",
        timestamp = time(),
    })
    while #history > MAX_HISTORY do table.remove(history) end
    RefreshHistory()
end)
