-- AdminPanel.lua
-- Raid Admin panel: only ever reachable by the current Raid Leader/Assist
-- or Party Leader (see UI.lua's BuildAdminTabButton/SB:RefreshAdminTabVisibility).
-- Lets that player temporarily mute sending (per person) or sending+receiving
-- (everyone but the leadership roles themselves) for the raid/party, for the
-- length of a pull or the whole instance - see Communication.lua's own
-- "Raid Admin" section for the protocol/enforcement side; this file is only
-- ever the UI on top of SB:SendAdminMute/SendAdminUnmute/SendAdminMuteAll/
-- SendAdminUnmuteAll.

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
-- these labels are written out.
local DURATION_TAG = {}
for _, opt in ipairs(DURATION_OPTIONS) do
    DURATION_TAG[opt.value] = "[mute: " .. opt.text .. "]"
end

-- Per-player bookkeeping of what this admin has clicked this session -
-- [name] = { duration = code, status = "pending"|"confirmed"|"failed",
-- sentAt = GetTime() }. Explicit requirement: a command is only ever shown
-- as successful once the TARGET's own client confirms it (ADMINACK, see
-- Communication.lua's SendAdminAck/SB:Fire("ADMIN_ACK_RECEIVED", ...)
-- below) - "pending" right after the click, "confirmed" once the ack
-- arrives, "failed" if none arrives within ACK_TIMEOUT_SECONDS (covers
-- both a real rejection - e.g. a stronger restriction already active - and
-- a target with no current Soundbook presence at all, who can never ack).
-- Reset whenever the panel rebuilds against a different roster (see
-- RefreshList) so a stale name from a previous raid never lingers.
local mutedByMe = {}
local ACK_TIMEOUT_SECONDS = 6
-- [name] = GetTime() this admin's OWN estimate of when that mute expires -
-- only set for the two USER-FACING timed durations (30/60 min). "Until raid
-- ends" has no expiry at all; "Next Fight"/"Next Boss" are intentionally
-- excluded here too even though Communication.lua's own SB.DurationSecondsFor
-- now returns a number for both - that's an internal 90-minute SAFETY NET in
-- case the real trigger (next combat end / next encounter end) never fires,
-- not a duration meant to be shown as a live countdown - a "89:58 remaining"
-- tag would wrongly suggest a fixed timer instead of "clears whenever the
-- fight/boss ends (usually much sooner), or in 90 min at the latest if that
-- somehow never happens". All three stay a plain static tag - see
-- RefreshList/DisplayDurationSeconds.
local mutedExpiresAt = {}

-- Deliberately NOT the same as SB.DurationSecondsFor (Communication.lua) -
-- see mutedExpiresAt's own comment above for why "F" is excluded here.
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

-- Any entry still "pending" longer than ACK_TIMEOUT_SECONDS becomes
-- "failed" - explicit requirement: a command with no confirmation within a
-- reasonable window must stop implying it might still succeed. Covers both
-- a real rejection (e.g. a stronger restriction already active elsewhere)
-- and a target with no current Soundbook presence, who can never ack at
-- all - either way, never silently shown as successful.
local function ExpirePendingAcks()
    local now = GetTime()
    for name, entry in pairs(mutedByMe) do
        if entry.status == "pending" and (now - entry.sentAt) > ACK_TIMEOUT_SECONDS then
            entry.status = "failed"
        end
    end
end

function RefreshList()
    ExpirePendingAcks()
    local roster = GetRosterWithRoles()

    -- Drop any locally-tracked mute for someone no longer on the roster
    -- (left the group, or this is a fresh raid) - avoids a stale "muted"
    -- tag surviving into an unrelated future group.
    local present = {}
    for _, m in ipairs(roster) do present[m.name] = true end
    for name in pairs(mutedByMe) do
        if not present[name] then
            mutedByMe[name] = nil
            mutedExpiresAt[name] = nil
        end
    end

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

        local entry = mutedByMe[member.name]
        -- Your OWN row is always "known" trivially - you obviously have
        -- Soundbook, you're looking at this panel right now. The normal
        -- knownUsers check would otherwise always say "no Soundbook?" for
        -- yourself specifically: OnAddonMessage's IsSelf guard means you
        -- never process (and therefore never NoteKnownUser) your own
        -- broadcasts, so you can never actually appear in your own
        -- knownUsers list through the normal HELLO/presence mechanism.
        -- Explicit bugfix: this used to index SB.db.knownUsers directly by
        -- the plain roster name, which only matches the OLD pre-realm-
        -- aware key shape - a genuinely known player showed "no
        -- Soundbook?" here anyway once their entry was keyed the new,
        -- realm-qualified way (the exact same player still muted just
        -- fine, since that path already went through the correct lookup).
        -- SB.KnownUserInfo (Communication.lua) is that same correct lookup.
        local known = member.isSelf or (SB.KnownUserInfo and SB.KnownUserInfo(member.name))
        if entry and entry.status == "pending" then
            row.statusText:SetText("|cffaaaaaa[mute: sending...]|r")
        elseif entry and entry.status == "failed" then
            row.statusText:SetText("|cffff9933[mute: not confirmed]|r")
        elseif entry and entry.status == "confirmed" then
            local expiresAt = mutedExpiresAt[member.name]
            local tag
            if expiresAt then
                -- 30/60 min - live countdown, ticked by EnsureCountdownTicker
                -- below while the panel's open (explicit request: "der
                -- Timer läuft dann runter, 30 min.. 29 min..." - originally
                -- only built for the muted PLAYER's own Mini Soundbook
                -- title, this mirrors the same idea here in the admin's own
                -- panel).
                local remaining = expiresAt - GetTime()
                tag = "[mute: " .. (remaining > 0 and FormatCountdown(remaining) or "0:00") .. "]"
            else
                -- "Next Fight"/"Until raid ends" - no numeric expiry to
                -- count down, stays a plain static tag.
                tag = DURATION_TAG[entry.duration] or "[mute]"
            end
            row.statusText:SetText("|cffff5555" .. tag .. "|r")
        elseif not known then
            row.statusText:SetText("no Soundbook?")
        else
            row.statusText:SetText("")
        end

        if member.isSelf then
            -- Muting yourself is meaningless (and a self-sent whisper is
            -- ignored on receipt anyway, see OnAddonMessage's IsSelf guard)
            -- - shown for visibility only, not clickable.
            row:SetScript("OnClick", nil)
        else
            row:SetScript("OnClick", function()
                if entry and entry.status ~= "failed" then
                    -- Confirmed or still-pending mute - request the unmute;
                    -- shown as gone from the list right away (explicit
                    -- requirement doesn't extend to unmute confirmation
                    -- display - the underlying override still only clears
                    -- once the target's client processes ADMINUNMUTE).
                    SB:SendAdminUnmute(member.name)
                    mutedByMe[member.name] = nil
                    mutedExpiresAt[member.name] = nil
                else
                    local duration = CurrentDuration()
                    SB:SendAdminMute(member.name, duration)
                    mutedByMe[member.name] = { duration = duration, status = "pending", sentAt = GetTime() }
                    local seconds = DisplayDurationSeconds(duration)
                    mutedExpiresAt[member.name] = seconds and (GetTime() + seconds) or nil
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

-- Marks the matching pending entry (or entries, for MUTEALL/UNMUTEALL)
-- confirmed/cleared the moment the target's own client acks it - explicit
-- requirement, see Communication.lua's SendAdminAck/ADMIN_ACK_RECEIVED.
SB:On("ADMIN_ACK_RECEIVED", function(fromName, kind)
    if kind == "MUTE" or kind == "EXEMPT" then
        local entry = mutedByMe[fromName]
        if entry and entry.status == "pending" then
            entry.status = "confirmed"
        end
    elseif kind == "UNMUTE" then
        mutedByMe[fromName] = nil
        mutedExpiresAt[fromName] = nil
    elseif kind == "MUTEALL" or kind == "UNMUTEALL" then
        local entry = mutedByMe[fromName]
        if entry and entry.status == "pending" then
            entry.status = "confirmed"
        end
    end
    if panel and panel:IsShown() then RefreshList() end
end)

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
    subtitle:SetText("Only you can see this. Overrides everyone's own Soundbook settings for the length of the raid - resets automatically the moment they leave the group.")

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
        -- (explicit requirement - see ADMIN_ACK_RECEIVED below). Leadership
        -- roles are exempt from Mute All (each receiving client verifies
        -- this itself, see Communication.lua's HandleAdminMuteAll, and
        -- still sends an EXEMPT ack) - skipped here too, they must be
        -- muted individually via a click.
        local seconds = DisplayDurationSeconds(duration)
        local expiresAt = seconds and (GetTime() + seconds) or nil
        local now = GetTime()
        for _, member in ipairs(GetRosterWithRoles()) do
            if member.role ~= "leader" and member.role ~= "assist" and not member.isSelf then
                mutedByMe[member.name] = { duration = duration, status = "pending", sentAt = now }
                mutedExpiresAt[member.name] = expiresAt
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
        wipe(mutedExpiresAt)
        RefreshList()
    end)

    -- Exemption note, directly under the Mute All controls - explicit
    -- request: leadership roles are always exempt from Mute All (an
    -- individually-targeted mute below can still reach them).
    local exemptNote = panel:CreateFontString(nil, "OVERLAY")
    exemptNote:SetFontObject(SB.Fonts.DisableSmall)
    exemptNote:SetPoint("TOPLEFT", durationDD.button, "BOTTOMLEFT", 0, -6)
    exemptNote:SetText("Raid Lead / Assist / Party Lead are always exempt from Mute All.")

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
-- status can all change while the panel is closed).
function SB:RefreshAdminPanel()
    if not panel or not listWrap then return end
    -- Explicit requirement: only the current leader may trigger Mute
    -- All/Unmute All - hidden (not just disabled) for an assistant admin,
    -- who can still fully mute/unmute individually via the list below.
    local isLeader = SB.IsCurrentGroupLeader and SB:IsCurrentGroupLeader()
    if muteAllBtn then muteAllBtn:SetShown(isLeader) end
    if unmuteAllBtn then unmuteAllBtn:SetShown(isLeader) end
    RefreshList()
    -- Restarts the countdown ticker on reopen too, not just on the click
    -- that originally created a timed mute - it self-cancels on hide (see
    -- EnsureCountdownTicker), so closing and reopening the panel while a
    -- 30/60 min mute is still counting down would otherwise leave it
    -- static until the next click.
    for _, expiresAt in pairs(mutedExpiresAt) do
        if expiresAt then
            EnsureCountdownTicker()
            break
        end
    end
end
