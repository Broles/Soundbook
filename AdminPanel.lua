-- AdminPanel.lua
-- Raid Admin panel: only ever reachable by the current Raid Leader/Assist
-- or Party Leader (see UI.lua's BuildAdminTabButton/SB:RefreshAdminTabVisibility).
-- Lets that player temporarily mute sending (per person) or sending+receiving
-- (everyone but the leadership roles themselves) for the raid/party, for the
-- length of a pull or the whole instance - see Communication.lua's own
-- "Raid Admin" section for the protocol/enforcement side; this file is only
-- ever the UI on top of SB:SendAdminMute/SendAdminUnmute/SendAdminMuteAll/
-- SendAdminUnmuteAll.
--
-- Explicit requirement (this iteration): every current Raid Admin sees the
-- SAME moderation state, not just their own clicks - see the "Synced raid-
-- wide state" section below and Communication.lua's ADMINSTATE/
-- ADMINSTATEQUERY/ADMINPENDING protocol. Raid Lead/Assist/Party Lead are
-- also now always exempt from an individual mute too, not just Mute All
-- (Communication.lua's HandleAdminMute) - their rows here reflect that
-- instead of presenting them as normal mutable members.

local ADDON_NAME, SB = ...

local ROW_H = 22
local panel
local listWrap -- Theme.CreateScrollFrame's { scroll, content, UpdateThumb }
local rows = {}
local durationDD
local muteAllBtn, unmuteAllBtn

-- Duration codes match Communication.lua's DurationSecondsFor/
-- ADMIN_DURATION_LABEL exactly. "F" (Next Fight) clears on the next combat
-- end - ANY fight, trash included. "B" (Next Boss) clears on the next
-- tracked boss encounter end specifically (what "Next Fight" used to mean
-- before this split - explicit request: trash can matter too, not just
-- bosses). "R" (raid end) has no timer. All three are event-cleared, not
-- time-based - only 30/60 actually count down.
local DURATION_OPTIONS = {
    { text = "Next Fight", value = "F" },
    { text = "Next Boss", value = "B" },
    { text = "30 minutes", value = "30" },
    { text = "60 minutes", value = "60" },
    { text = "Until raid ends", value = "R" },
}
-- Short tag text shown next to a muted name in the list (e.g. "[mute: 30
-- min]") - built from DURATION_OPTIONS' own text so there's only one place
-- these labels are written out. Semantic (not the safety-net countdown) for
-- F/B/R - explicit requirement.
local DURATION_TAG = {
    F = "Until fight ends", B = "Until boss ends", R = "Until raid ends",
}
for _, opt in ipairs(DURATION_OPTIONS) do
    if not DURATION_TAG[opt.value] then DURATION_TAG[opt.value] = opt.text end
end

------------------------------------------------------------------------
-- State layers - rendered with this precedence, per roster member:
--   1. raidAdminState  - CONFIRMED fact, from anyone (this admin's own
--      ACK, another admin's action, or a plain resync) - always the
--      target's own self-reported SB.raidOverride, never trusted from a
--      relaying admin alone (Communication.lua's ADMINSTATE).
--   2. mutedByMe        - THIS admin's own just-clicked, not yet
--      confirmed/failed action.
--   3. pendingFromOthers - another admin's just-clicked, not yet
--      confirmed action, relayed via ADMINPENDING so it shows here too.
--   4. otherwise not muted.
-- All three are session-only, exactly like SB.raidOverride itself -
-- nothing here is ever written to SavedVariables, and everything is
-- dropped/rebuilt whenever the roster changes (see RefreshList).
------------------------------------------------------------------------

-- [name] = { mutedAll, durationCode, expiresAt (GetTime()-based, LOCAL to
-- THIS client - see Communication.lua's ADMINSTATE payload for why it's
-- sent as a relative remaining-seconds value, never the sender's own
-- absolute GetTime()), source } - or nil (confirmed NOT muted, once a
-- CLEAR has actually been seen; simply absent means "unknown yet").
local raidAdminState = {}

-- [name] = { duration = code, status = "pending"|"failed", sentAt =
-- GetTime() } - THIS admin's own in-flight click, cleared the moment
-- raidAdminState (above) reflects the outcome, or marked "failed" after
-- ACK_TIMEOUT_SECONDS with nothing.
local mutedByMe = {}
local ACK_TIMEOUT_SECONDS = 6

-- [name] = { kind, duration, byAdmin, sentAt } - ANOTHER admin's
-- in-flight click (Communication.lua's ADMINPENDING) - same timeout
-- rule as mutedByMe, just silently dropped rather than shown "failed"
-- (only the admin who actually clicked needs that detail).
local pendingFromOthers = {}

-- Deliberately NOT the same as SB.DurationSecondsFor (Communication.lua) -
-- "F"/"B"/"R" show a semantic label (DURATION_TAG above), never a live
-- countdown from the internal 90-minute safety-net timer that would
-- wrongly imply a fixed duration - see Communication.lua's own
-- DurationSecondsFor/ApplyRaidOverride comments for the full reasoning.
local function DisplayDurationSeconds(code)
    if code == "30" then return 30 * 60
    elseif code == "60" then return 60 * 60
    end
    return nil
end

-- Default duration for a plain click on a name - explicit request
-- ("Default klick auf den Namen löst aus 'until raid ends'"). Also seeds
-- the dropdown itself (durationDD:SetValue below), so Mute All shares the
-- same default unless the admin picks something else.
local DEFAULT_DURATION = "R"

local function CurrentDuration()
    return (durationDD and durationDD:GetValue()) or DEFAULT_DURATION
end

------------------------------------------------------------------------
-- Roster - EVERY member of the raid/party, including the admin viewing this
-- panel themselves (explicit request: "der Admin ... wird auch im Admin
-- Panel gelistet" - useful with more than one Lead/Assist, so each can see
-- the others' roles too). Reused structure (not SendMenu.lua's
-- GuildMembers/etc - this is the WHOLE roster, not filtered to known
-- Soundbook users, since an admin needs to see and mute everyone present
-- regardless of whether Soundbook has confirmed they have the addon yet).
------------------------------------------------------------------------

local function GetRosterWithRoles()
    local list = {}
    local me = SB.NormalizeName(UnitName("player"))

    if IsInRaid() then
        for i = 1, SB.GetNumGroupMembers() do
            local name, rank, _, _, _, _, _, online = GetRaidRosterInfo(i)
            if name then
                name = SB.NormalizeName(name)
                if name then
                    local role = (rank == 2 and "leader") or (rank == 1 and "assist") or "member"
                    table.insert(list, { name = name, role = role, online = online and true or false, isSelf = (name == me) })
                end
            end
        end
    elseif IsInGroup() then
        -- party1..N excludes the player themselves - added back separately
        -- below so the admin still sees their own row.
        for i = 1, SB.GetNumGroupMembers() - 1 do
            local unit = "party" .. i
            local name = UnitName(unit)
            if name then
                name = SB.NormalizeName(name)
                if name then
                    local role = UnitIsGroupLeader(unit) and "leader" or "member"
                    table.insert(list, { name = name, role = role, online = UnitIsConnected(unit) and true or false, isSelf = false })
                end
            end
        end
        if me then
            table.insert(list, { name = me, role = UnitIsGroupLeader("player") and "leader" or "member", online = true, isSelf = true })
        end
    end

    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local ROLE_COLOR = {
    leader = { 1, 0.82, 0 },      -- gold
    assist = { 0.4, 0.75, 1 },    -- light blue
    member = SB.Theme.TEXT,
}
local ROLE_LABEL = { leader = " (Lead)", assist = " (Assist)", member = "" }
local function IsAdminRole(role) return role == "leader" or role == "assist" end

------------------------------------------------------------------------
-- Member rows - same hover-highlight language as SendMenu.lua's context
-- menu ("ähnlich wie das Rechtsklick-Menü im Mini-Soundbook").
------------------------------------------------------------------------

local function AcquireRow(index)
    local row = rows[index]
    if row then return row end

    row = SB.CreateFrame("Button", nil, listWrap.content)
    row:SetHeight(ROW_H)
    row:SetPoint("LEFT", 0, 0)
    row:SetPoint("RIGHT", 0, 0)

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(SB.Theme.ACCENT[1], SB.Theme.ACCENT[2], SB.Theme.ACCENT[3], 0.35)

    local nameText = row:CreateFontString(nil, "OVERLAY")
    nameText:SetFontObject(SB.Fonts.HighlightSmall)
    nameText:SetPoint("LEFT", 6, 0)
    nameText:SetJustifyH("LEFT")
    row.nameText = nameText

    local statusText = row:CreateFontString(nil, "OVERLAY")
    statusText:SetFontObject(SB.Fonts.DisableSmall)
    statusText:SetPoint("RIGHT", -8, 0)
    statusText:SetJustifyH("RIGHT")
    row.statusText = statusText

    rows[index] = row
    return row
end

local function FormatCountdown(seconds)
    seconds = math.max(0, math.floor(seconds))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local countdownTicker
-- Forward-declared so EnsureCountdownTicker's ticker closure (created
-- below, before RefreshList's own definition further down) can call the
-- real RefreshList once it's assigned - a plain `local function RefreshList`
-- at that later point would instead create a SECOND, separate local,
-- leaving this forward declaration (and therefore the ticker) permanently
-- pointing at nil.
local RefreshList

-- Runs only while the panel is actually visible - self-cancels the moment
-- it isn't, so this is never a permanent background poll. Only needed at
-- all when at least one currently-listed mute has a real countdown to show
-- (30/60 min); harmless (and cheap) to just let it run continuously
-- whenever the panel's open rather than tracking that more precisely.
local function EnsureCountdownTicker()
    if countdownTicker then return end
    countdownTicker = C_Timer.NewTicker(1, function()
        if not panel or not panel:IsShown() then
            countdownTicker:Cancel()
            countdownTicker = nil
            return
        end
        RefreshList()
    end)
end

-- Any locally-tracked pending entry (mine or another admin's) still
-- pending longer than ACK_TIMEOUT_SECONDS is dropped - explicit
-- requirement: a command with no confirmation within a reasonable window
-- must stop implying it might still succeed. Mine becomes "failed" (shown
-- as such); another admin's just quietly disappears back to "not muted"
-- (only the admin who actually clicked needs the failure detail).
local function ExpirePendingAcks()
    local now = GetTime()
    for name, entry in pairs(mutedByMe) do
        if entry.status == "pending" and (now - entry.sentAt) > ACK_TIMEOUT_SECONDS then
            entry.status = "failed"
        end
    end
    for name, entry in pairs(pendingFromOthers) do
        if (now - entry.sentAt) > ACK_TIMEOUT_SECONDS then
            pendingFromOthers[name] = nil
        end
    end
end

-- The tag shown for a CONFIRMED raidAdminState entry - live countdown for
-- 30/60 min, a semantic (not safety-net) label for F/B/R.
local function ConfirmedTag(state)
    local prefix = state.mutedAll and "RAID MUTE ALL" or "mute"
    if state.expiresAt and (state.durationCode == "30" or state.durationCode == "60") then
        local remaining = state.expiresAt - GetTime()
        return string.format("[%s: %s]", prefix, remaining > 0 and FormatCountdown(remaining) or "0:00")
    end
    return string.format("[%s: %s]", prefix, DURATION_TAG[state.durationCode] or "active")
end

function RefreshList()
    ExpirePendingAcks()
    local roster = GetRosterWithRoles()

    -- Drop any locally-tracked state for someone no longer on the roster
    -- (left the group, or this is a fresh raid) - avoids a stale tag
    -- surviving into an unrelated future group.
    local present = {}
    for _, m in ipairs(roster) do present[m.name] = true end
    for name in pairs(mutedByMe) do if not present[name] then mutedByMe[name] = nil end end
    for name in pairs(pendingFromOthers) do if not present[name] then pendingFromOthers[name] = nil end end
    for name in pairs(raidAdminState) do if not present[name] then raidAdminState[name] = nil end end

    for i, member in ipairs(roster) do
        local row = AcquireRow(i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        row:SetPoint("RIGHT", 0, 0)

        local color = ROLE_COLOR[member.role] or SB.Theme.TEXT
        row.nameText:SetText(member.name .. (ROLE_LABEL[member.role] or "") .. (member.isSelf and " (You)" or ""))
        row.nameText:SetTextColor(color[1], color[2], color[3])
        if not member.online then
            row.nameText:SetTextColor(SB.Theme.TEXT_DIM[1], SB.Theme.TEXT_DIM[2], SB.Theme.TEXT_DIM[3])
        end

        if IsAdminRole(member.role) then
            -- Explicit requirement: Lead/Assist/Party Lead are always
            -- exempt (Mute All AND an individual mute - Communication.lua's
            -- HandleAdminMute/HandleAdminMuteAll) - communicated here as a
            -- distinct Admin/exempt state, never presented as a normal
            -- mutable member.
            row.statusText:SetText("|cff8ec8ffAdmin - exempt|r")
            row:SetScript("OnClick", nil)
        elseif member.isSelf then
            -- Muting yourself is meaningless (and a self-sent whisper is
            -- ignored on receipt anyway, see OnAddonMessage's IsSelf guard)
            -- - shown for visibility only, not clickable.
            row.statusText:SetText("")
            row:SetScript("OnClick", nil)
        else
            local known = SB.KnownUserInfo and SB.KnownUserInfo(member.name)
            local confirmed = raidAdminState[member.name]
            local mine = mutedByMe[member.name]
            local others = pendingFromOthers[member.name]

            if confirmed then
                row.statusText:SetText("|cffff5555" .. ConfirmedTag(confirmed) .. "|r")
            elseif mine and mine.status == "pending" then
                row.statusText:SetText("|cffaaaaaa[mute: sending...]|r")
            elseif mine and mine.status == "failed" then
                row.statusText:SetText("|cffff9933[mute: not confirmed]|r")
            elseif others then
                row.statusText:SetText(string.format("|cffaaaaaa[mute: pending by %s...]|r",
                    SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(others.byAdmin) or others.byAdmin))
            elseif not known then
                row.statusText:SetText("no Soundbook?")
            else
                row.statusText:SetText("")
            end

            row:SetScript("OnClick", function()
                if confirmed or (mine and mine.status ~= "failed") then
                    -- Confirmed or still-pending mute - request the unmute;
                    -- shown as gone from the list right away, same
                    -- established precedent as before (the underlying
                    -- override still only actually clears once the
                    -- target's client processes ADMINUNMUTE and
                    -- self-reports it via ADMINSTATE).
                    SB:SendAdminUnmute(member.name)
                    mutedByMe[member.name] = nil
                    raidAdminState[member.name] = nil
                    pendingFromOthers[member.name] = nil
                else
                    local duration = CurrentDuration()
                    SB:SendAdminMute(member.name, duration)
                    mutedByMe[member.name] = { duration = duration, status = "pending", sentAt = GetTime() }
                end
                EnsureCountdownTicker()
                RefreshList()
            end)
        end

        row:Show()
    end

    for i = #roster + 1, #rows do
        rows[i]:Hide()
    end

    listWrap.content:SetHeight(math.max(1, #roster * ROW_H))
    listWrap.UpdateThumb()
end

------------------------------------------------------------------------
-- Synced raid-wide state - see Communication.lua's own "Admin state sync"
-- section for the wire protocol. This is what actually makes the panel
-- raid-wide instead of "only what I clicked" - explicit requirement.
------------------------------------------------------------------------

-- MY OWN command's outcome - explicit requirement: only ever shown as
-- successful once the TARGET's own client confirms it (ADMINACK), never
-- just optimistically on send. Only resolves mutedByMe's pending/failed
-- state here - the actual CONFIRMED tag (raidAdminState) always comes
-- from ADMIN_STATE_SYNCED below (the target's own self-report), which
-- arrives at essentially the same moment (both triggered by the same
-- ApplyRaidOverride/ClearRaidOverride call on the target's client) - so
-- there is deliberately only ONE source of truth for the actual tag
-- rendered, never two that could drift apart.
SB:On("ADMIN_ACK_RECEIVED", function(fromName, kind)
    if kind == "MUTE" or kind == "EXEMPT" then
        local entry = mutedByMe[fromName]
        if entry and entry.status == "pending" then entry.status = "confirmed" end
    elseif kind == "UNMUTE" then
        mutedByMe[fromName] = nil
    end
    -- MUTEALL/UNMUTEALL/EXEMPT-from-mute-all intentionally left alone
    -- here - Mute All's own per-member mutedByMe entries (seeded in the
    -- Mute All click handler below) resolve the same way once each
    -- affected member's OWN raidOverride actually applies and they
    -- self-report it (ADMIN_STATE_SYNCED), same reasoning as above.
    if panel and panel:IsShown() then RefreshList() end
end)

-- The one real source of truth for what's actually applied anywhere in
-- the raid right now - the TARGET's own client reporting its own
-- SB.raidOverride (or the lack of one), whether that's a spontaneous
-- change or a reply to SB:SendAdminStateQuery(). `state` is nil for "not
-- muted" (a real CLEAR, not just "unknown").
SB:On("ADMIN_STATE_SYNCED", function(name, state)
    if not name then return end
    raidAdminState[name] = state
    mutedByMe[name] = nil
    pendingFromOthers[name] = nil
    if state and state.expiresAt then EnsureCountdownTicker() end
    if panel and panel:IsShown() then RefreshList() end
end)

-- Another admin's just-issued command, relayed so this panel shows the
-- same pending -> confirmed transition too, not just the admin who
-- clicked - explicit requirement.
SB:On("ADMIN_PENDING_SYNCED", function(byAdmin, target, kind, durationCode)
    if kind == "mute" or kind == "unmute" then
        if target and target ~= "" then
            pendingFromOthers[target] = { kind = kind, duration = durationCode, byAdmin = byAdmin, sentAt = GetTime() }
        end
    elseif kind == "muteall" or kind == "unmuteall" then
        for _, member in ipairs(GetRosterWithRoles()) do
            if not IsAdminRole(member.role) and not member.isSelf then
                pendingFromOthers[member.name] = { kind = kind, duration = durationCode, byAdmin = byAdmin, sentAt = GetTime() }
            end
        end
    end
    if panel and panel:IsShown() then RefreshList() end
end)

-- Debounced the same way the REPLYING side already is
-- (Communication.lua's AnnounceMyRaidAdminState) - several triggers in a
-- short window (panel toggled a few times, a resize-driven refresh)
-- must not each independently re-provoke a fresh reply from every raid
-- member.
local ADMIN_QUERY_DEBOUNCE = 3
local lastQuerySentAt = 0
local function RequestStateResync()
    local now = GetTime()
    if (now - lastQuerySentAt) < ADMIN_QUERY_DEBOUNCE then return end
    lastQuerySentAt = now
    if SB.SendAdminStateQuery then SB:SendAdminStateQuery() end
end

------------------------------------------------------------------------
-- Panel shell
------------------------------------------------------------------------

function SB.BuildAdminPanel(mainFrame, contentFrame)
    if panel then return panel end

    panel = CreateFrame("Frame", "SoundbookAdminPanel", mainFrame)
    panel:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 0, 0)
    panel:SetPoint("TOPRIGHT", contentFrame, "TOPRIGHT", 0, 0)
    panel:SetPoint("BOTTOM", mainFrame, "BOTTOM", 0, 16)
    panel:Hide()

    local title = panel:CreateFontString(nil, "OVERLAY")
    title:SetFontObject(SB.Fonts.NormalLarge)
    title:SetPoint("TOPLEFT", 4, -4)
    title:SetText("Raid Admin")
    title:SetTextColor(1, 0.82, 0)

    local subtitle = panel:CreateFontString(nil, "OVERLAY")
    subtitle:SetFontObject(SB.Fonts.DisableSmall)
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
    subtitle:SetPoint("RIGHT", -4, 0)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetWordWrap(true)
    subtitle:SetText("Overrides everyone's own Soundbook settings for the length of the raid - resets automatically the moment they leave the group. Every current Raid Lead/Assist sees the same state here.")

    -- Mute All row: duration dropdown + Mute All + Unmute All.
    local muteAllLabel = panel:CreateFontString(nil, "OVERLAY")
    muteAllLabel:SetFontObject(SB.Fonts.HighlightSmall)
    muteAllLabel:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -14)
    muteAllLabel:SetText("Mute everyone (send + receive):")

    durationDD = SB.Theme.CreateDropdown(panel, 130, 22, 4)
    durationDD.button:SetPoint("TOPLEFT", muteAllLabel, "BOTTOMLEFT", 0, -6)
    durationDD:SetOptions(DURATION_OPTIONS)
    durationDD:SetValue(DEFAULT_DURATION)

    -- Explicit requirement: ONLY the current leader may trigger Mute
    -- All/Unmute All - an assistant no longer qualifies (still fully able
    -- to mute/unmute individually below). Hidden rather than just
    -- disabled for a non-leader admin so it's unambiguous, not a
    -- greyed-out control that invites clicking anyway.
    muteAllBtn = SB.Theme.CreateFlatButton(panel, "Mute All", 90, 22)
    muteAllBtn:SetPoint("LEFT", durationDD.button, "RIGHT", 8, 0)
    muteAllBtn:SetScript("OnClick", function()
        local duration = CurrentDuration()
        SB:SendAdminMuteAll(duration)
        -- Pending, not confirmed, until each target's own client acks it
        -- AND self-reports it (explicit requirement - see ADMIN_ACK_RECEIVED/
        -- ADMIN_STATE_SYNCED above). Leadership roles are exempt from Mute
        -- All (each receiving client verifies this itself, see
        -- Communication.lua's HandleAdminMuteAll, and still sends an
        -- EXEMPT ack) - skipped here too, they must be muted individually
        -- via a click (and even then are now always exempt - HandleAdminMute).
        local now = GetTime()
        for _, member in ipairs(GetRosterWithRoles()) do
            if not IsAdminRole(member.role) and not member.isSelf then
                mutedByMe[member.name] = { duration = duration, status = "pending", sentAt = now }
                raidAdminState[member.name] = nil
            end
        end
        EnsureCountdownTicker()
        RefreshList()
    end)

    unmuteAllBtn = SB.Theme.CreateFlatButton(panel, "Unmute All", 90, 22)
    unmuteAllBtn:SetPoint("LEFT", muteAllBtn, "RIGHT", 8, 0)
    unmuteAllBtn:SetScript("OnClick", function()
        SB:SendAdminUnmuteAll()
        wipe(mutedByMe)
        wipe(raidAdminState)
        wipe(pendingFromOthers)
        RefreshList()
    end)

    -- Exemption note, directly under the Mute All controls - explicit
    -- request: leadership roles are always exempt from Mute All (and now
    -- from an individual mute too - see HandleAdminMute).
    local exemptNote = panel:CreateFontString(nil, "OVERLAY")
    exemptNote:SetFontObject(SB.Fonts.DisableSmall)
    exemptNote:SetPoint("TOPLEFT", durationDD.button, "BOTTOMLEFT", 0, -6)
    exemptNote:SetText("Raid Lead / Assist / Party Lead are always exempt - Mute All and individual mutes alike.")

    local listLabel = panel:CreateFontString(nil, "OVERLAY")
    listLabel:SetFontObject(SB.Fonts.HighlightSmall)
    listLabel:SetPoint("TOPLEFT", exemptNote, "BOTTOMLEFT", 0, -14)
    listLabel:SetText("Click a name to mute/unmute just their sending:")

    listWrap = SB.Theme.CreateScrollFrame(panel)
    listWrap.scroll:SetPoint("TOPLEFT", listLabel, "BOTTOMLEFT", 0, -6)
    listWrap.scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 4)
    listWrap.content:SetPoint("TOPLEFT", 0, 0)
    listWrap.content:SetPoint("RIGHT", 0, 0)

    return panel
end

-- Rebuilds the member list - called by UI.lua's RefreshMainWindow every
-- time the Admin panel is shown, so it's never stale (roster/roles/mute
-- status can all change while the panel is closed). Also requests a fresh
-- state resync every time (debounced) - explicit requirement: opening the
-- panel, gaining Lead/Assist, /reload, or joining an already-running raid
-- must all reconstruct the ACTUAL current state from the target clients
-- themselves, never trust whatever this panel happened to have cached
-- from before.
function SB:RefreshAdminPanel()
    if not panel or not listWrap then return end
    -- Explicit requirement: only the current leader may trigger Mute
    -- All/Unmute All - hidden (not just disabled) for an assistant admin,
    -- who can still fully mute/unmute individually via the list below.
    local isLeader = SB.IsCurrentGroupLeader and SB:IsCurrentGroupLeader()
    if muteAllBtn then muteAllBtn:SetShown(isLeader) end
    if unmuteAllBtn then unmuteAllBtn:SetShown(isLeader) end
    RequestStateResync()
    RefreshList()
    -- Restarts the countdown ticker on reopen too, not just on the click
    -- that originally created a timed mute - it self-cancels on hide (see
    -- EnsureCountdownTicker), so closing and reopening the panel while a
    -- 30/60 min mute is still counting down would otherwise leave it
    -- static until the next click.
    for _, state in pairs(raidAdminState) do
        if state.expiresAt then
            EnsureCountdownTicker()
            break
        end
    end
end
