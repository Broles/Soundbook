-- AnalyticsUI.lua
-- `/sb analytics` - a standalone window over the data Analytics.lua
-- collects/syncs. Pure display + sorting/filtering; never mutates
-- analytics data itself. Must work correctly with zero data (a brand new
-- install, or analytics turned off) - every view just renders an empty
-- table with the summary numbers at zero, nothing errors.

local ADDON_NAME, SB = ...

local WINDOW_W, WINDOW_H = 800, 480
local ROW_H = 22
local TABLE_TOP = 172 -- header + summary + filters + view tabs + column header

local win
local rows = {}
local columnHeaders = {}
local scrollWidget

local currentView = "Overview"
local currentTimeFilter = "all"   -- "all" / "30d" / "7d"
local currentCategory = "ALL"
local currentSearch = ""
local sortKey = "plays"
local sortDesc = true

local VIEWS = {
    "Overview", "Popular", "Favourites", "Trending", "Muted",
    "Least Used", "Removal Candidates", "My Stats",
}

local HEALTH_COLOR = {
    ["Popular"] = { 1.00, 0.82, 0.20 },
    ["Community Favourite"] = { 1.00, 0.55, 0.85 },
    ["Trending"] = { 0.35, 0.95, 0.55 },
    ["Niche"] = { 0.70, 0.78, 0.90 },
    ["Spammy"] = { 1.00, 0.55, 0.15 },
    ["Frequently Muted"] = { 0.95, 0.30, 0.30 },
    ["Forgotten"] = { 0.55, 0.55, 0.60 },
    ["Removal Candidate"] = { 0.85, 0.25, 0.25 },
    ["Insufficient Data"] = { 0.50, 0.50, 0.55 },
}

------------------------------------------------------------------------
-- Row data building - one entry per soundID that has ANY record, filtered/
-- sorted according to the current view/filters. Pure function of
-- SB.db.analytics; safe to call with zero data.
------------------------------------------------------------------------

local function DisplayName(soundID)
    local ok, name = pcall(function() return SB:GetSoundDisplayName(soundID) end)
    if ok and name and name ~= "" then return name end
    -- A record for a sound we don't have locally (someone else's private
    -- Category1/2 pick) - fall back to the raw ID rather than erroring.
    return soundID
end

local function DisplayIcon(soundID)
    local ok, icon = pcall(function() return SB:GetSoundIcon(soundID) end)
    if ok and icon then return icon end
    return SB.DEFAULT_ICON
end

local function FormatPct(x)
    return string.format("%d%%", math.floor((x or 0) * 100 + 0.5))
end

local function FormatLastUsed(ts)
    if not ts or ts <= 0 then return "-" end
    local days = math.floor((time() - ts) / 86400)
    if days <= 0 then return "today" end
    if days == 1 then return "1 day ago" end
    if days < 30 then return days .. " days ago" end
    return math.floor(days / 30) .. "mo ago"
end

local function FormatTrend(trend)
    if trend == nil then return "-" end
    if trend == "NEW" then return "NEW" end
    local pct = math.floor(trend * 100 + 0.5)
    return (pct >= 0 and "+" or "") .. pct .. "%"
end

local function CategoryOfSound(soundID)
    local cat = SB.ParseSoundID(soundID)
    return tostring(cat or "?")
end

local function MatchesFilters(soundID)
    if currentCategory ~= "ALL" and CategoryOfSound(soundID) ~= currentCategory then
        return false
    end
    if currentSearch ~= "" then
        local name = DisplayName(soundID):lower()
        if not name:find(currentSearch, 1, true) then return false end
    end
    return true
end

--- Builds the full row list for the current view + filters, already
--- sorted. Each row: { soundID, metrics (SB.Analytics_SoundMetrics shape),
--- trend, daysSince, health }.
local function BuildRows()
    local list = {}

    if currentView == "My Stats" then
        for _, entry in ipairs(SB.Analytics_MyStats()) do
            if MatchesFilters(entry.soundID) then
                table.insert(list, {
                    soundID = entry.soundID,
                    myPlays = entry.rec.totalPlays,
                    mySessions = entry.rec.sessionsUsed,
                    myFav = entry.rec.favourite,
                    myMute = entry.rec.personalMute,
                    lastUsed = entry.rec.lastUsed,
                })
            end
        end
        table.sort(list, function(a, b) return (a.myPlays or 0) > (b.myPlays or 0) end)
        return list
    end

    for _, soundID in ipairs(SB.Analytics_AllSoundIDs()) do
        if MatchesFilters(soundID) then
            local m = SB.Analytics_SoundMetrics(soundID, currentTimeFilter)
            local trend = SB.Analytics_Trend(soundID)
            local daysSince = m.lastUsed > 0 and math.floor((time() - m.lastUsed) / 86400) or nil
            -- Health is always computed from "all" time data, regardless of
            -- the active time filter - a sound's overall standing shouldn't
            -- flicker between labels just because you're looking at a 7-day
            -- window right now.
            local mAll = SB.Analytics_SoundMetrics(soundID, "all")
            -- Health/tag judgment only ever applies to Legacy/German Memes -
            -- explicit requirement, see SB.Analytics_IsHealthEligible. A
            -- Category 1/2 (Soundbook_MySounds) or Stammtisch
            -- (Soundbook_Private) sound's raw stats still show fine in
            -- Overview/Favourites/Muted/My Stats below - it just never gets
            -- a health label (shown as "-") or counts toward Popular/
            -- Trending/Least Used/Removal Candidates.
            local eligible = SB.Analytics_IsHealthEligible(soundID)
            local health = eligible and SB.Analytics_Health(soundID, mAll, trend, daysSince) or "-"

            local include = true
            if currentView == "Popular" then
                include = eligible and (health == "Popular" or health == "Community Favourite")
            elseif currentView == "Favourites" then
                include = m.favs > 0
            elseif currentView == "Trending" then
                -- Deliberately looser than the actual "Trending" pill/
                -- label (SB.Analytics_Health, capped to the top
                -- trendingMaxCount sounds) - this is a diagnostic list, so
                -- ANY sound with positive week-over-week growth belongs
                -- here, not just the ones currently capped-in for the
                -- badge. SB.Analytics_Trend itself no longer returns "NEW"
                -- (see its own comment) - a positive number is the only
                -- thing this ever checks for now.
                include = eligible and type(trend) == "number" and trend > 0
            elseif currentView == "Muted" then
                include = m.mutes > 0
            elseif currentView == "Least Used" then
                -- A low absolute play count alone isn't enough - a sound
                -- can have very few total plays and STILL be Trending
                -- (e.g. 1 play last week -> 2 this week is +100% growth),
                -- which read as a contradiction ("least used" badge next
                -- to a "Trending" tag). "Least Used" should mean genuinely
                -- low, non-rising engagement - exclude anything currently
                -- showing positive momentum, same tags GetPositiveTag
                -- would ever put on a sound.
                include = eligible
                    and health ~= "Insufficient Data"
                    and health ~= "Trending"
                    and health ~= "Popular"
                    and health ~= "Community Favourite"
            elseif currentView == "Removal Candidates" then
                include = eligible and health == "Removal Candidate"
            end

            if include then
                table.insert(list, {
                    soundID = soundID, metrics = m, trend = trend,
                    daysSince = daysSince, health = health,
                })
            end
        end
    end

    local function Key(row)
        if sortKey == "sound" then return DisplayName(row.soundID):lower() end
        if sortKey == "users" then return row.metrics.users end
        if sortKey == "reach" then return row.metrics.reach end
        if sortKey == "favs" then return row.metrics.favs end
        if sortKey == "favRate" then return row.metrics.favRate end
        if sortKey == "mutes" then return row.metrics.mutes end
        if sortKey == "muteRate" then return row.metrics.muteRate end
        if sortKey == "sessions" then return row.metrics.sessions end
        if sortKey == "lastUsed" then return row.metrics.lastUsed end
        return row.metrics.plays
    end
    table.sort(list, function(a, b)
        local ka, kb = Key(a), Key(b)
        if ka == kb then return DisplayName(a.soundID) < DisplayName(b.soundID) end
        if sortDesc then return ka > kb else return ka < kb end
    end)

    if currentView == "Least Used" then
        -- Independent of the general sort control - always ascending by
        -- plays for this one view, matching its own name.
        table.sort(list, function(a, b) return a.metrics.plays < b.metrics.plays end)
    end

    return list
end

------------------------------------------------------------------------
-- UI construction
------------------------------------------------------------------------

local function AcquireRow(index)
    local row = rows[index]
    if row then return row end

    -- A Button, not a plain Frame - clicking a row plays that sound, same
    -- as clicking it anywhere else in Soundbook. Always forced to "SELF" -
    -- explicit requirement: this is a local preview/replay from inside the
    -- Analytics window, never a broadcast/send to anyone else, regardless
    -- of whatever the player's own Default Output Channel setting is.
    row = SB.CreateFrame("Button", nil, scrollWidget.content)
    row:SetHeight(ROW_H)
    -- Explicit vertical position per index - without this every row anchors
    -- to the same spot (LEFT/RIGHT alone say nothing about Y) and all of
    -- them render stacked exactly on top of one another.
    row:SetPoint("TOPLEFT", 4, -(index - 1) * ROW_H)
    row:SetPoint("RIGHT", -4, 0)
    row:RegisterForClicks("LeftButtonUp")
    row:SetScript("OnClick", function()
        if row.soundID then SB:TriggerSound(row.soundID, "SELF") end
    end)

    if index % 2 == 0 then
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(1, 1, 1, 0.03)
    end

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(SB.Theme.ARCANE_HOVER[1], SB.Theme.ARCANE_HOVER[2], SB.Theme.ARCANE_HOVER[3], 0.14)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 2, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Fixed-width columns, left to right. `name` gets the remaining space.
    local cols = {}
    local function AddCol(width, justify)
        local fs = row:CreateFontString(nil, "OVERLAY")
        fs:SetFontObject(SB.Fonts.HighlightSmall)
        fs:SetWidth(width)
        fs:SetJustifyH(justify or "RIGHT")
        fs:SetWordWrap(false)
        table.insert(cols, fs)
        return fs
    end

    row.name = row:CreateFontString(nil, "OVERLAY")
    row.name:SetFontObject(SB.Fonts.HighlightSmall)
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.name:SetTextColor(unpack(SB.Theme.TEXT))

    row.col1 = AddCol(42) -- plays
    row.col2 = AddCol(38) -- users
    row.col3 = AddCol(42) -- reach%
    row.col4 = AddCol(32) -- favs
    row.col5 = AddCol(42) -- fav%
    row.col6 = AddCol(34) -- mutes
    row.col7 = AddCol(42) -- mute%
    row.col8 = AddCol(42) -- sessions
    row.col9 = AddCol(70, "RIGHT") -- last used
    row.col10 = AddCol(86, "RIGHT") -- health

    -- Right-anchor the whole cluster of fixed columns; name fills the gap.
    row.col10:SetPoint("RIGHT", -4, 0)
    row.col9:SetPoint("RIGHT", row.col10, "LEFT", -4, 0)
    row.col8:SetPoint("RIGHT", row.col9, "LEFT", -4, 0)
    row.col7:SetPoint("RIGHT", row.col8, "LEFT", -4, 0)
    row.col6:SetPoint("RIGHT", row.col7, "LEFT", -4, 0)
    row.col5:SetPoint("RIGHT", row.col6, "LEFT", -4, 0)
    row.col4:SetPoint("RIGHT", row.col5, "LEFT", -4, 0)
    row.col3:SetPoint("RIGHT", row.col4, "LEFT", -4, 0)
    row.col2:SetPoint("RIGHT", row.col3, "LEFT", -4, 0)
    row.col1:SetPoint("RIGHT", row.col2, "LEFT", -4, 0)
    row.name:SetPoint("RIGHT", row.col1, "LEFT", -8, 0)

    rows[index] = row
    return row
end

local function RenderRow(index, data)
    local row = AcquireRow(index)
    row.soundID = data.soundID
    row.icon:SetTexture(DisplayIcon(data.soundID))
    row.name:SetText(DisplayName(data.soundID))

    if currentView == "My Stats" then
        row.col1:SetText(tostring(data.myPlays or 0))
        row.col2:SetText(tostring(data.mySessions or 0))
        row.col3:SetText("")
        row.col4:SetText(data.myFav and "Yes" or "-")
        row.col5:SetText("")
        row.col6:SetText(data.myMute and "Yes" or "-")
        row.col7:SetText("")
        row.col8:SetText("")
        row.col9:SetText(FormatLastUsed(data.lastUsed))
        row.col10:SetText("")
        row.col10:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    else
        local m = data.metrics
        row.col1:SetText(tostring(m.plays))
        row.col2:SetText(tostring(m.users))
        row.col3:SetText(FormatPct(m.reach))
        row.col4:SetText(tostring(m.favs))
        row.col5:SetText(FormatPct(m.favRate))
        row.col6:SetText(tostring(m.mutes))
        row.col7:SetText(FormatPct(m.muteRate))
        row.col8:SetText(tostring(m.sessions))
        row.col9:SetText(FormatLastUsed(m.lastUsed))
        row.col10:SetText(data.health)
        local c = HEALTH_COLOR[data.health] or SB.Theme.TEXT_DIM
        row.col10:SetTextColor(c[1], c[2], c[3])
    end

    row:Show()
end

local emptyLabel

local function Refresh()
    if not win or not win:IsShown() then return end
    local list = BuildRows()

    for i, data in ipairs(list) do
        RenderRow(i, data)
    end
    for i = #list + 1, #rows do
        rows[i]:Hide()
    end
    scrollWidget.content:SetHeight(math.max(1, #list) * ROW_H)
    scrollWidget.UpdateThumb()
    emptyLabel:SetShown(#list == 0)

    -- Summary bar
    local s = SB.Analytics_Summary(currentTimeFilter)
    win.summaryUsers:SetText("Observed Users: " .. s.observedUsers)
    win.summarySessions:SetText("Sessions: " .. s.observedSessions)
    win.summaryPlays:SetText("Total Plays: " .. s.totalPlays)
    win.summarySounds:SetText("Sounds with Data: " .. s.soundsWithData)
    local range = "-"
    if s.oldestSeen and s.newestSeen then
        range = FormatLastUsed(s.oldestSeen) .. " - " .. FormatLastUsed(s.newestSeen)
    end
    win.summaryRange:SetText("Data Range: " .. range)
    win.summarySync:SetText("Last Sync: " .. (win.lastSyncText or "never"))
end

local function SortByColumn(key)
    if sortKey == key then
        sortDesc = not sortDesc
    else
        sortKey = key
        sortDesc = true
    end
    Refresh()
end

local function BuildColumnHeader()
    local bar = SB.CreateFrame("Frame", nil, win)
    bar:SetPoint("TOPLEFT", 12, -(TABLE_TOP - 18))
    bar:SetPoint("TOPRIGHT", -28, -(TABLE_TOP - 18))
    bar:SetHeight(18)

    local function AddHeader(text, key, width, justify)
        local btn = SB.CreateFrame("Button", nil, bar)
        if width then btn:SetSize(width, 18) else btn:SetHeight(18) end
        local fs = btn:CreateFontString(nil, "OVERLAY")
        fs:SetFontObject(SB.Fonts.DisableSmall)
        fs:SetAllPoints()
        fs:SetJustifyH(justify or "RIGHT")
        fs:SetWordWrap(false)
        fs:SetText(text)
        btn.label = fs
        btn:SetScript("OnClick", function() SortByColumn(key) end)
        btn:SetScript("OnEnter", function() fs:SetTextColor(1, 1, 1) end)
        btn:SetScript("OnLeave", function() fs:SetTextColor(unpack(SB.Theme.TEXT_DIM)) end)
        fs:SetTextColor(unpack(SB.Theme.TEXT_DIM))
        return btn
    end

    -- Mirrors AcquireRow's own column widths/order/gaps exactly.
    local h10 = AddHeader("Health", "health", 86, "RIGHT")
    h10:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    local h9 = AddHeader("Last Used", "lastUsed", 70, "RIGHT")
    h9:SetPoint("RIGHT", h10, "LEFT", -4, 0)
    local h8 = AddHeader("Sessions", "sessions", 42, "RIGHT")
    h8:SetPoint("RIGHT", h9, "LEFT", -4, 0)
    local h7 = AddHeader("Mute %", "muteRate", 42, "RIGHT")
    h7:SetPoint("RIGHT", h8, "LEFT", -4, 0)
    local h6 = AddHeader("Mutes", "mutes", 34, "RIGHT")
    h6:SetPoint("RIGHT", h7, "LEFT", -4, 0)
    local h5 = AddHeader("Fav %", "favRate", 42, "RIGHT")
    h5:SetPoint("RIGHT", h6, "LEFT", -4, 0)
    local h4 = AddHeader("Favs", "favs", 32, "RIGHT")
    h4:SetPoint("RIGHT", h5, "LEFT", -4, 0)
    local h3 = AddHeader("Reach %", "reach", 42, "RIGHT")
    h3:SetPoint("RIGHT", h4, "LEFT", -4, 0)
    local h2 = AddHeader("Users", "users", 38, "RIGHT")
    h2:SetPoint("RIGHT", h3, "LEFT", -4, 0)
    local h1 = AddHeader("Plays", "plays", 42, "RIGHT")
    h1:SetPoint("RIGHT", h2, "LEFT", -4, 0)
    -- Sound header is flexible (LEFT+RIGHT anchors, no fixed width) so it
    -- exactly matches whatever space AcquireRow's own row.name leaves
    -- between the icon and the fixed stat-column cluster - a fixed width
    -- here (the old bug) could overlap the stat cluster whenever the
    -- window wasn't wide enough for both to claim their own space.
    local h0 = AddHeader("Sound", "sound", nil, "LEFT")
    h0:SetPoint("LEFT", bar, "LEFT", 24, 0)
    h0:SetPoint("RIGHT", h1, "LEFT", -8, 0)

    win.columnDivider = win:CreateTexture(nil, "ARTWORK")
    win.columnDivider:SetHeight(1)
    win.columnDivider:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, -2)
    win.columnDivider:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -2)
    win.columnDivider:SetColorTexture(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.4)
end

local function BuildWindow()
    win = SB.CreateFrame("Frame", "SoundbookAnalyticsWindow", UIParent)
    win:SetSize(WINDOW_W, WINDOW_H)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    SB.Theme.CleanPanel(win, 0.98)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:SetClampedToScreen(true)
    win:SetToplevel(true)
    win:Hide()
    tinsert(UISpecialFrames, "SoundbookAnalyticsWindow")

    local title = win:CreateFontString(nil, "OVERLAY")
    title:SetFontObject(SB.Fonts.Highlight)
    title:SetPoint("TOP", 0, -10)
    title:SetText("Soundbook Analytics")
    title:SetTextColor(unpack(SB.Theme.TEXT))

    local closeBtn = SB.Theme.CreateCloseGlyph(win, 18)
    closeBtn:SetPoint("TOPRIGHT", -8, -8)
    closeBtn:SetScript("OnClick", function() win:Hide() end)

    -- Summary bar - six short readouts, two rows of three, always present
    -- even at zero.
    local summary = SB.CreateFrame("Frame", nil, win)
    summary:SetPoint("TOPLEFT", 12, -32)
    summary:SetPoint("TOPRIGHT", -12, -32)
    summary:SetHeight(34)

    local function SummaryLabel(col, row)
        local fs = summary:CreateFontString(nil, "OVERLAY")
        fs:SetFontObject(SB.Fonts.HighlightSmall)
        fs:SetPoint("TOPLEFT", (col - 1) * 205, -(row - 1) * 16)
        fs:SetJustifyH("LEFT")
        fs:SetTextColor(unpack(SB.Theme.TEXT_DIM))
        return fs
    end
    win.summaryUsers = SummaryLabel(1, 1)
    win.summarySessions = SummaryLabel(2, 1)
    win.summaryPlays = SummaryLabel(3, 1)
    win.summarySounds = SummaryLabel(1, 2)
    win.summaryRange = SummaryLabel(2, 2)
    win.summarySync = SummaryLabel(3, 2)

    -- Filters row: Time / Category / Search.
    local timeDD = SB.Theme.CreateDropdown(win, 100, 22, 6)
    timeDD.button:SetPoint("TOPLEFT", 12, -76)
    timeDD:SetOptions({
        { text = "All Time", value = "all" },
        { text = "30 Days", value = "30d" },
        { text = "7 Days", value = "7d" },
    })
    timeDD:SetValue("all")
    timeDD:SetOnChange(function(v) currentTimeFilter = v; Refresh() end)

    local catDD = SB.Theme.CreateDropdown(win, 110, 22, 6)
    catDD.button:SetPoint("LEFT", timeDD.button, "RIGHT", 8, 0)
    local catOptions = { { text = "All Categories", value = "ALL" } }
    for _, cat in ipairs(SB.CATEGORIES or {}) do
        table.insert(catOptions, { text = tostring(cat), value = tostring(cat) })
    end
    -- "Stammtisch" (private sounds - Soundbook_Private etc.) isn't part of
    -- SB.CATEGORIES at all (it's its own bucket, see SoundRegistry.lua's
    -- SB.PRIVATE_CATEGORY), so it was previously never selectable as a
    -- filter here even though its sounds already showed up fine under
    -- "All Categories" - explicit fix, only offered once at least one
    -- private sound is actually registered.
    if SB.HasPrivateSounds and SB:HasPrivateSounds() then
        table.insert(catOptions, { text = SB.PRIVATE_TAB_NAME or "Stammtisch", value = tostring(SB.PRIVATE_CATEGORY) })
    end
    catDD:SetOptions(catOptions)
    catDD:SetValue("ALL")
    catDD:SetOnChange(function(v) currentCategory = v; Refresh() end)

    local searchBox = SB.Theme.CreateInputBox(win, 160, 22)
    searchBox:SetPoint("LEFT", catDD.button, "RIGHT", 8, 0)
    searchBox:SetScript("OnTextChanged", function(self)
        currentSearch = (self:GetText() or ""):lower()
        Refresh()
    end)
    local searchHint = searchBox:CreateFontString(nil, "OVERLAY")
    searchHint:SetFontObject(SB.Fonts.DisableSmall)
    searchHint:SetPoint("LEFT", 4, 0)
    searchHint:SetText("Search sound...")
    searchBox:HookScript("OnTextChanged", function(self)
        searchHint:SetShown(self:GetText() == "")
    end)

    -- View tabs.
    local tabRow = SB.CreateFrame("Frame", nil, win)
    tabRow:SetPoint("TOPLEFT", 12, -104)
    tabRow:SetPoint("TOPRIGHT", -12, -104)
    tabRow:SetHeight(22)

    local tabButtons = {}
    local prevTab

    local function ApplyTabSelection()
        for name, b in pairs(tabButtons) do
            if name == currentView then
                b.ApplyThemeState("hover")
                b.selectedMark:Show()
            else
                b.ApplyThemeState("idle")
                b.selectedMark:Hide()
            end
        end
    end

    for _, viewName in ipairs(VIEWS) do
        -- Width is sized to the label itself (measured text + padding),
        -- not a fixed guess - a longer label like "Removal Candidates"
        -- would otherwise overflow a fixed-width button and visually
        -- overlap its neighbours.
        local btn = SB.Theme.CreateFlatButton(tabRow, viewName, 60, 20)
        local neededWidth = math.max(60, math.ceil(btn.label:GetStringWidth()) + 18)
        btn:SetWidth(neededWidth)
        if prevTab then
            btn:SetPoint("LEFT", prevTab, "RIGHT", 3, 0)
        else
            btn:SetPoint("LEFT", 0, 0)
        end
        local mark = btn:CreateTexture(nil, "OVERLAY")
        mark:SetPoint("BOTTOMLEFT", 2, 1)
        mark:SetPoint("BOTTOMRIGHT", -2, 1)
        mark:SetHeight(2)
        mark:SetColorTexture(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 1)
        mark:Hide()
        btn.selectedMark = mark
        btn:SetScript("OnClick", function()
            currentView = viewName
            ApplyTabSelection()
            Refresh()
        end)
        tabButtons[viewName] = btn
        prevTab = btn
    end
    ApplyTabSelection()

    BuildColumnHeader()

    scrollWidget = SB.Theme.CreateScrollFrame(win)
    scrollWidget.scroll:SetPoint("TOPLEFT", 12, -TABLE_TOP)
    scrollWidget.scroll:SetPoint("BOTTOMRIGHT", -28, 12)
    scrollWidget.content:SetPoint("TOPLEFT")
    scrollWidget.content:SetWidth(WINDOW_W - 44)

    emptyLabel = win:CreateFontString(nil, "OVERLAY")
    emptyLabel:SetFontObject(SB.Fonts.HighlightSmall)
    emptyLabel:SetPoint("TOP", scrollWidget.scroll, "TOP", 0, -20)
    emptyLabel:SetText("No data yet - this fills in as sounds get played.")
    emptyLabel:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    emptyLabel:Hide()

    SB:On("ANALYTICS_UPDATED", function()
        win.lastSyncText = date("%H:%M:%S")
        Refresh()
    end)
end

function SB:ShowAnalyticsWindow()
    if not win then BuildWindow() end
    win:Show()
    Refresh()
end
