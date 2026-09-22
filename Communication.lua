-- Communication.lua
--
-- Multiplayer sound triggers. The mp3 itself is NEVER transmitted - only
-- a small, versioned addon message like "V1|PLAY|2::wir wipen" is sent.
-- The receiver plays their own local copy of that sound through the exact
-- same SB:PlaySound function everything else uses.

local ADDON_NAME, SB = ...

local SEP = "|"

local lastReceivedFrom = {} -- [realm-aware sender key .. "|" .. soundID] = last accepted PLAY time

local NormalizeName = SB.NormalizeName
local function IdentityKey(name)
    return (SB.PlayerKey and SB.PlayerKey(name)) or NormalizeName(name)
end

local function KnownUserInfo(name)
    if not (SB.db and SB.db.knownUsers) then return nil end
    local key = IdentityKey(name)
    local legacyKey = NormalizeName(name)
    return (key and SB.db.knownUsers[key]) or (legacyKey and SB.db.knownUsers[legacyKey])
end
-- Exported (explicit bugfix - AdminPanel.lua's raid roster used to index
-- SB.db.knownUsers directly by the plain roster name, which only ever
-- matches the OLD pre-realm-aware key shape; a friend who's genuinely
-- known under the current realm-qualified key still wrongly showed "no
-- Soundbook?" there even though the exact same lookup already worked
-- correctly everywhere that called this function instead) - one shared
-- lookup instead of a second, easily-outdated copy of this same key logic.
SB.KnownUserInfo = KnownUserInfo

local function IsSelf(sender)
    local me = SB.GetUnitFullName and SB.GetUnitFullName("player") or UnitName("player")
    return IdentityKey(sender) == IdentityKey(me)
end

------------------------------------------------------------------------
-- Chat notifications - Settings -> Remote Playback. Three independent
-- toggles:
--   notifyOnMuted        - a remote sound played for you
--   notifyMutedAttempts  - a remote sound was BLOCKED by a PER-SOUND mute
--                          specifically - so you know someone tried. Does
--                          NOT cover a disabled "Receive Sounds from"
--                          channel any more - that's always fully silent,
--                          no exceptions (explicit request), handled
--                          entirely in OnAddonMessage's PLAY branch below,
--                          before any of this even runs.
--   notifyFriendReceipts - who received/played YOUR sound - this player
--                          both sends a small receipt when THEY receive a
--                          sound (only if this is on) and shows the
--                          aggregated list when receipts come back for
--                          something they sent
-- All three share the same "[Soundbook]" purple tag; a blocked attempt
-- additionally gets a red "[muted]" tag right after it.
------------------------------------------------------------------------

local TAG_COLOR = "cff5865F2"   -- Soundbook purple accent (matches Theme.ACCENT)
local MUTED_COLOR = "cffff5555" -- red
-- Distinct from MUTED_COLOR (red) - a disabled receive channel is a
-- different thing from an actual mute (see RXOFFACK below), gets its own
-- colour so the two counts are never visually confused with each other.
local RXOFF_COLOR = "cffffa500" -- orange

-- Explicit request: colour-code the channel/source portion of every one
-- of these lines the same way Now Playing does (SB.CHANNEL_COLOR,
-- Core.lua) instead of the old flat grey "(Channel):".
local function PrintReceived(sender, channelLabel, soundName)
    local label = channelLabel or "Direct"
    local color = SB.GetChannelColor(label)
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|%s[Soundbook]|r |cffffffff%s|r |cff%s(%s):|r |cffffd100%s|r",
        TAG_COLOR, sender, color.hex, label, soundName))
end

local function PrintMuted(sender, channelLabel, soundName)
    local label = channelLabel or "Direct"
    local color = SB.GetChannelColor(label)
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|%s[Soundbook]|r |%s[muted]|r |cffffffff%s|r |cff%s(%s):|r |cffffd100%s|r",
        TAG_COLOR, MUTED_COLOR, sender, color.hex, label, soundName))
end

-- Single-letter channel codes carried in the ACK protocol message (see
-- HandlePlayCommand's reply below) - F/P/R/G, matching the same four
-- channels as everywhere else in Soundbook.
local CHANNEL_CODE = {
    PARTY = "P", RAID = "R", RAID_LEADER = "R",
    GUILD = "G", OFFICER = "G", WHISPER = "F",
}
-- "D" (Direct) is never derived from CHANNEL_CODE above (a direct send still
-- physically travels over WHISPER, same as a broadcast-to-all-friends one) -
-- HandlePlayCommand overrides to "D" explicitly for a SendMenu.lua-initiated
-- direct send, see SB:SendSoundToPlayer below.
local CODE_NAME = { F = "Friend", P = "Party", R = "Raid", G = "Guild", D = "Direct" }
local CODE_ORDER = { "F", "P", "R", "G", "D", "?" }

-- `entries` is { {name=, code=}, ... }. One shared channel across everyone
-- who received it -> "Guild received: A, B". Mixed channels -> grouped
-- per channel instead: "Received: [F]: A, [P]: B, [G]: C".
local function FormatReceivedList(entries)
    local distinctCodes, codeOrder = {}, {}
    for _, e in ipairs(entries) do
        if not distinctCodes[e.code] then
            distinctCodes[e.code] = true
            table.insert(codeOrder, e.code)
        end
    end

    if #codeOrder <= 1 then
        local label = CODE_NAME[codeOrder[1]] or "Friends"
        local names = {}
        for _, e in ipairs(entries) do table.insert(names, e.name) end
        return string.format("%s received: %s", label, table.concat(names, ", "))
    end

    local parts = {}
    for _, code in ipairs(CODE_ORDER) do
        local names = {}
        for _, e in ipairs(entries) do
            if e.code == code then table.insert(names, e.name) end
        end
        if #names > 0 then
            table.insert(parts, string.format("[%s]: %s", code, table.concat(names, ", ")))
        end
    end
    return "Received: " .. table.concat(parts, ", ")
end

-- Explicit request: also show how many recipients had the sound MUTED
-- locally, not just who actually received/played it - "(N muted)" in red,
-- right after the normal "(Channel received: ...)" segment, only when
-- mutedCount > 0. `entries` may be empty (everyone who got it had it
-- muted) - the received segment is simply omitted in that case rather
-- than printing an empty "()" received list.
--
-- `rxOffCount` is a separate, later addition - recipients who never even
-- got a chance to mute/play it because they have that whole receive
-- channel switched off (Settings' Send/Receive table) - explicit request:
-- shown as its own "(N receive-off)" segment in orange, never merged into
-- the red "(N muted)" one, since it's a different thing (a channel-level
-- opt-out, not a deliberate per-sound/per-person mute). Debug-Mode-only by
-- design (see HandleRxOffAck) - `rxOffCount` is simply always 0 for a
-- normal (non-debug) client, so this segment naturally never appears then.
local function PrintFriendsReceived(soundName, entries, mutedCount, rxOffCount)
    local receivedPart = #entries > 0
        and string.format(" |cff999999(%s)|r", FormatReceivedList(entries))
        or ""
    local mutedPart = (mutedCount and mutedCount > 0)
        and string.format(" |%s(%d muted)|r", MUTED_COLOR, mutedCount)
        or ""
    local rxOffPart = (rxOffCount and rxOffCount > 0)
        and string.format(" |%s(%d receive-off)|r", RXOFF_COLOR, rxOffCount)
        or ""
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|%s[Soundbook]|r |cffffffff%s|r: |cffffd100%s|r%s%s%s",
        TAG_COLOR, UnitName("player"), soundName, receivedPart, mutedPart, rxOffPart))
end

------------------------------------------------------------------------
-- Sending
------------------------------------------------------------------------

-- Explicit request: Raid and Party are treated as ONE target everywhere in
-- Soundbook from here on (dropdowns, the Send broadcast toggle, per-sound
-- Default/Macro Output overrides all only ever store "RAID") - they're
-- mutually exclusive in WoW anyway, you're never in both at once. This is
-- the ONE place that resolves the merged concept to whichever native
-- channel is actually live right now, for the moment something really
-- needs to go out over the wire - "RAID" while in a raid, "PARTY" while in
-- a non-raid group, nil if in neither (nothing to send to).
function SB.ResolveGroupChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

-- Names already covered by a currently-enabled group broadcast channel this
-- send (Guild/Raid/Party), so SendToFriends can skip whispering them. Without
-- this, anyone who is both e.g. in your guild AND on your friends list gets
-- the exact same sound twice - once via GUILD, once via a direct WHISPER -
-- and whichever packet's network delivery happens to win the race decides
-- which channel shows up in their "received" notification. That made the
-- displayed channel effectively random instead of meaningful. Sending each
-- person exactly one copy, via the most specific channel that reaches them,
-- fixes both the duplicate traffic and the non-deterministic channel label.
local function GetGroupCoveredNames(modes)
    local covered = {}

    if modes.GUILD and IsInGuild() then
        local n = GetNumGuildMembers and GetNumGuildMembers() or 0
        for i = 1, n do
            local fullName = GetGuildRosterInfo(i)
            if fullName then
                covered[IdentityKey(fullName)] = true
            end
        end
    end

    -- Raid and Party share the one "RAID" toggle now (see
    -- SB.ResolveGroupChannel above) - whichever of the two is actually
    -- live gets scanned here.
    if modes.RAID and IsInRaid() then
        for i = 1, SB.GetNumGroupMembers() do
            local name = GetRaidRosterInfo(i)
            if name then covered[IdentityKey(name)] = true end
        end
    elseif modes.RAID and IsInGroup() then
        for i = 1, SB.GetNumGroupMembers() - 1 do
            local name = SB.GetUnitFullName and SB.GetUnitFullName("party" .. i) or UnitName("party" .. i)
            if name then covered[IdentityKey(name)] = true end
        end
    end

    return covered
end

local function SendToFriends(text, covered)
    local n = SB.GetNumFriends()
    for i = 1, n do
        local name, connected = SB.GetFriendInfoByIndex(i)
        if name and connected and not covered[IdentityKey(name)] then
            SB.SendAddonMessage(SB.COMM_PREFIX, text, "WHISPER", name)
        end
    end
end

-- soundID -> GetTime() of our own most recent broadcast of it, so an
-- incoming ACK can be matched back to "yes, I actually sent this
-- recently" rather than trusting an unsolicited ACK from anywhere.
local recentBroadcasts = {}
local ACK_CLAIM_WINDOW = 15 -- seconds an ACK can still be matched to a broadcast

-- Sends the network trigger for a sound to every channel currently enabled
-- under Settings -> Broadcast (any combination of Friends/Party/Raid/Guild).
-- Called only from SB:TriggerSound, i.e. only for locally-initiated plays,
-- never for sounds received from the network. Local playback always
-- happens separately and is unaffected by these settings.
function SB:BroadcastSound(soundID)
    local modes = SB.db.settings.broadcastModes
    if not modes then return end

    local text = SB.PROTOCOL_VERSION .. SEP .. "PLAY" .. SEP .. soundID
    recentBroadcasts[soundID] = GetTime()

    -- Raid and Party share the one "RAID" toggle now - whichever is
    -- actually live gets the message (see SB.ResolveGroupChannel).
    local groupChannel = modes.RAID and SB.ResolveGroupChannel()
    if groupChannel then
        SB.SendAddonMessage(SB.COMM_PREFIX, text, groupChannel)
    end
    if modes.GUILD and IsInGuild() then
        SB.SendAddonMessage(SB.COMM_PREFIX, text, "GUILD")
    end
    if modes.FRIENDS then
        SendToFriends(text, GetGroupCoveredNames(modes))
    end
end

------------------------------------------------------------------------
-- Default Output Channel - Settings -> Sound Routing. What a PLAIN
-- click on a Mini Soundbook favourite sends to, on top of always playing
-- locally. "ALL" (default) is just SB:BroadcastSound above, unchanged.
-- Anything else bypasses the "Broadcast sounds to:" checkboxes for one
-- single channel, or one single person, INSTEAD of them - not on top of.
--
-- These three send functions are deliberately silent (no PlayLocally re-
-- play, no "Sent to X" chat line) unlike SendMenu.lua's SB:SendSoundTo*
-- further below, which share almost the same shape - a normal click
-- through this setting is meant to feel exactly like a normal click always
-- has (SB:TriggerSound already played it locally and fires
-- LOCAL_SOUND_PLAYED itself), just aimed differently, not like the more
-- deliberate, explicitly-confirmed SendMenu action.
------------------------------------------------------------------------

local function SendToSingleChannelSilent(soundID, channel)
    if channel ~= "GUILD" and channel ~= "PARTY" and channel ~= "RAID" then return end
    recentBroadcasts[soundID] = GetTime()
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "PLAY" .. SEP .. soundID, channel)
end

local function SendToAllFriendsSilent(soundID)
    recentBroadcasts[soundID] = GetTime()
    local text = SB.PROTOCOL_VERSION .. SEP .. "PLAY" .. SEP .. soundID
    SendToFriends(text, {})
end

local function SendToPlayerSilent(soundID, name)
    if not SB.registry[soundID] or not SB.IsValidPlayerTarget(name) then return end
    recentBroadcasts[soundID] = GetTime()
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "PLAY" .. SEP .. soundID .. SEP .. "D", "WHISPER", name)
end

-- Same option list Settings -> Default Output Channel (now the main
-- window's own omnipresent dropdown, see UI.lua) and EditWindow.lua's
-- per-sound macro "Output" dropdown both share - one place to keep them
-- identical. Explicit request: fixed order All -> Friends -> Guild -> Raid
-- -> Party -> Self, with each group's individual online members listed as
-- their own selectable rows DIRECTLY under that group's header (indented,
-- smaller font via SB.OutputTargetRowFont below) instead of one flat block
-- of "-> Name (Source)" rows tacked on at the very end - a name no longer
-- needs its own "(Friend)"/"(Guild)" label since which header it's sitting
-- under already says that.
--
-- Individual people are re-queried live every time the list opens, never
-- cached (who's online/in-group changes constantly), and deduplicated by
-- name with the SAME priority SendMenu.lua's right-click list already
-- uses - Friends > Guild > Raid > Party - so someone in more than one group
-- at once only ever shows up once, under the highest-priority one. Only
-- ever someone confirmed to have Soundbook (SB.db.knownUsers, the same
-- presence roster SendMenu.lua filters by) - picking someone without the
-- addon would just silently go nowhere.
local PLAYER_ROW_INDENT = 14

-- THE single canonical "who's reachable" computation - explicit requirement:
-- the main dropdown (Communication.lua's SB.ComputeOutputTargetOptions,
-- used by UI.lua/EditWindow.lua) and the Mini Soundbook's right-click menu
-- (SendMenu.lua) must always show the exact same current list, not two
-- independently-maintained copies that could silently drift apart - both
-- now call this one function instead of each re-implementing their own
-- Friends/Guild/Raid/Party scan.
--
-- Returns { FRIENDS = {name, ...}, GUILD = {...}, RAID = {...} }, each list
-- already sorted, deduplicated by a fixed Friends > Raid > Guild priority
-- (explicit request - someone reachable through several groups at once
-- shows up exactly ONCE, under the highest-priority one: a friend is always
-- a friend first regardless of group membership; a guildmate who's also in
-- your raid/party counts as Raid, not Guild, since that's the more
-- specific/immediate relationship), and filtered to SB.db.knownUsers
-- (confirmed Soundbook installs only).
--
-- RAID is Raid AND Party combined (explicit request, see
-- SB.ResolveGroupChannel) - the two are mutually exclusive in WoW, so this
-- bucket simply collects whichever of the two is actually live right now;
-- there is no separate PARTY key any more.
--
-- Identity safety: deduplication uses a realm-aware canonical key and each
-- row retains the actual realm-qualified whisper target. Presentation may
-- hide the local realm, but two same-named cross-realm players stay distinct.
function SB.ComputeReachablePlayers()
    if SB.PruneStaleKnownUsers then SB:PruneStaleKnownUsers() end

    local claimedBy = {} -- [canonical name+realm] = true, across ALL buckets
    local result = { FRIENDS = {}, GUILD = {}, RAID = {} }

    local function CollectInto(bucketName, iterFn)
        local bucket = result[bucketName]
        iterFn(function(rawName)
            local key = IdentityKey(rawName)
            if not key or not KnownUserInfo(rawName) or claimedBy[key] then return end
            claimedBy[key] = true
            -- Keep the actual realm-qualified target. Presentation may hide
            -- the local realm, but sends must never guess between two Bobs.
            table.insert(bucket, rawName)
        end)
        table.sort(bucket, function(a, b)
            local da = SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(a) or a
            local db = SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(b) or b
            if da == db then return (IdentityKey(a) or a) < (IdentityKey(b) or b) end
            return da < db
        end)
    end

    -- Collection order = priority order (Friends > Raid/Party > Guild) -
    -- whichever bucket claims a player first is the only one they show up
    -- in, see this function's own comment above.
    CollectInto("FRIENDS", function(add)
        local n = SB.GetNumFriends()
        for i = 1, n do
            local name, connected = SB.GetFriendInfoByIndex(i)
            if name and connected then add(name) end
        end
    end)
    CollectInto("RAID", function(add)
        if IsInRaid() then
            for i = 1, SB.GetNumGroupMembers() do
                local name, _, _, _, _, _, _, online = GetRaidRosterInfo(i)
                if name and online then add(name) end
            end
        elseif IsInGroup() then
            for i = 1, SB.GetNumGroupMembers() - 1 do
                local unit = "party" .. i
                if UnitIsConnected(unit) then
                    add(SB.GetUnitFullName and SB.GetUnitFullName(unit) or UnitName(unit))
                end
            end
        end
    end)
    CollectInto("GUILD", function(add)
        if IsInGuild() and GetNumGuildMembers then
            for i = 1, GetNumGuildMembers() do
                local fullName, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
                if fullName and isOnline then add(fullName) end
            end
        end
    end)

    return result
end

function SB.ComputeOutputTargetOptions()
    local opts = { { text = "All (checked in Settings)", value = "ALL", isHeader = true } }
    local reachable = SB.ComputeReachablePlayers()
    local friendNames, guildNames, raidNames = reachable.FRIENDS, reachable.GUILD, reachable.RAID

    -- Explicit request: green when it matches this client's own version,
    -- orange when it's older/different/unknown - same colours everywhere
    -- a version suffix shows (this dropdown and SendMenu.lua's popup).
    local VERSION_CURRENT_COLOR = { 0.4, 0.95, 0.5 }
    local VERSION_OTHER_COLOR = { 1, 0.6, 0 }

    local function AddGroup(label, value, names)
        -- Explicit request (reversed, again, from the last two rounds of
        -- "only if I'm actually in it"/"only if there's someone reachable"
        -- versions of this): every group header ALWAYS shows, regardless
        -- of whether you're currently in that group or anyone reachable is
        -- in it - "egal ob die Personen/Spieler drin sind oder nicht". A
        -- pick that goes nowhere right now (e.g. selecting Raid while
        -- solo) simply sends nothing when it's actually used
        -- (SB:DispatchDefaultOutput/SendToSingleChannelSilent already
        -- handle that quietly) - the option itself is always there to
        -- pick, everywhere (this dropdown, EditWindow's two dropdowns,
        -- SendMenu.lua's right-click menu).
        -- Explicit request: the header itself carries a "(N)" count of how
        -- many Soundbook-reachable players actually fall under it right
        -- now - "wie viele Spieler dieser Outputgruppe logisch zugeordnet
        -- werden" - so picking a target also tells you your real reach,
        -- without having to expand/count the member rows yourself.
        table.insert(opts, { text = label .. " (" .. #names .. ")", value = value, isHeader = true })
        for _, name in ipairs(names) do
            local suffix, isCurrent = SB:GetFormattedPlayerVersion(name)
            table.insert(opts, {
                text = (SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(name) or name),
                value = "PLAYER:" .. name, indent = PLAYER_ROW_INDENT,
                suffix = suffix, suffixColor = isCurrent and VERSION_CURRENT_COLOR or VERSION_OTHER_COLOR,
                -- Same group key as this row's own header ("FRIENDS"/
                -- "GUILD"/"RAID") - explicit request: unify with
                -- SendMenu.lua's popup, where a member row's NAME is
                -- always the same colour as its group header, never the
                -- version colour (that's the suffix's job only).
                channelKey = value,
            })
        end
    end

    -- Explicit request: Guild/Raid/Friends, matching the order SendMenu.lua's
    -- and MutePlayers.lua's own group lists already use. Raid and Party are
    -- ONE merged row (see SB.ResolveGroupChannel/ComputeReachablePlayers) -
    -- labelled "Raid" while actually in a raid, "Party" while in a non-raid
    -- group, and "Raid" as the default label while in neither (still always
    -- shown, same as every other group - picking it then just sends
    -- nowhere, like any other empty group already does).
    local groupLabel = IsInRaid() and "Raid" or (IsInGroup() and "Party") or "Raid"
    AddGroup("Guild", "GUILD", guildNames)
    AddGroup(groupLabel, "RAID", raidNames)
    AddGroup("Friends", "FRIENDS", friendNames)

    table.insert(opts, { text = "Self only (no send)", value = "SELF", isHeader = true })

    return opts
end

-- Group headers (All/Friends/Guild/Raid/Party/Self) render in the larger
-- Highlight font, individual player rows in the smaller HighlightSmall one
-- (plus their own indent - see PLAYER_ROW_INDENT above) - same header-vs-
-- member size distinction SendMenu.lua's own popup already uses. Passed to
-- Theme.CreateDropdown:SetRowFont by both UI.lua's omnipresent dropdown and
-- EditWindow.lua's Macro Output one.
-- Explicit request: unified with SendMenu.lua's own popup - a player's
-- NAME is always coloured by its group (Core.lua's SB.CHANNEL_COLOR,
-- opt.value for a header / opt.channelKey - the SAME group key - for a
-- member row under it), never by version match. The separate version
-- suffix (SB:GetFormattedPlayerVersion, Debug Mode only) is the only
-- thing that ever shows green/orange - see Theme.lua's dropdown row
-- building for where opt.suffixColor gets applied to that. "ALL" has no
-- single channel and keeps the normal text colour, same as before.
function SB.OutputTargetRowFont(text, opt)
    text:SetFontObject(opt.isHeader and SB.Fonts.Highlight or SB.Fonts.HighlightSmall)
    local colorKey = opt.isHeader and opt.value or opt.channelKey
    local color = colorKey and SB.CHANNEL_COLOR[colorKey]
    if color then
        text:SetTextColor(color.r, color.g, color.b)
    else
        text:SetTextColor(unpack(SB.Theme.TEXT))
    end
end

--- The SB.CHANNEL_COLOR entry (Core.lua) matching the CURRENT Default
--- Output Channel setting, or nil for "ALL" (no single channel, same
--- precedent as OutputTargetRowFont above - stays the normal text colour
--- wherever this is used). "PLAYER:<name>" (one specific person picked as
--- the default target) is a Direct send, same as everywhere else isDirect
--- is handled - explicit request: FavouritesWindow.lua's hover name bar
--- uses this to colour the sound name by where it would actually go right
--- now if clicked.
function SB.DefaultOutputChannelColor()
    local target = (SB.db and SB.db.settings and SB.db.settings.defaultOutputTarget) or "ALL"
    if target == "ALL" then return nil end
    if type(target) == "string" and target:match("^PLAYER:") then return SB.CHANNEL_COLOR.DIRECT end
    return SB.CHANNEL_COLOR[target]
end

--- The Output target a LOCAL click on `soundID` right now would actually
--- use, if `explicitOverride` is nil - priority order:
---   1. `explicitOverride` (a macro's own "::Target" suffix, or an
---      explicit caller like SendMenu.lua) - unchanged from before.
---   2. NEW - explicit request: the sound's OWN per-sound "Default
---      Output" (Edit Sound window, saved.outputOverride) - distinct from
---      the existing "Macro Output" field, which only ever affects the
---      copied macro text, never a normal click. "ALL" (or unset) counts
---      as "no override" here, same as Settings' own global default does.
---   3. Settings -> Sound Routing -> Default Output Channel
---      (SB.db.settings.defaultOutputTarget).
---   4. "ALL" as the last-resort fallback.
function SB:ResolveOutputTarget(soundID, explicitOverride)
    if explicitOverride and SB.IsValidOutputTarget(explicitOverride) then return explicitOverride end
    local saved = soundID and SB.db and SB.db.sounds and SB.db.sounds[soundID]
    if saved and saved.outputOverride and saved.outputOverride ~= "ALL" and SB.IsValidOutputTarget(saved.outputOverride) then
        return saved.outputOverride
    end
    local fallback = (SB.db and SB.db.settings and SB.db.settings.defaultOutputTarget) or "ALL"
    return SB.IsValidOutputTarget(fallback) and fallback or "ALL"
end

--- The SB.CHANNEL_COLOR entry matching `soundID`'s OWN per-sound "Default
--- Output" override, or nil if it doesn't have one set (or it's "ALL") -
--- explicit request: colours its icon border/wash/name text everywhere it
--- appears (UI.lua's grid, FavouritesWindow.lua's favourite slots).
--- Deliberately separate from SB.DefaultOutputChannelColor above (the
--- GLOBAL setting's own colour, used for the Mini Soundbook's hover name
--- bar) - a per-sound override and the global default are two different
--- things, even though they share the same SB.CHANNEL_COLOR palette.
--- Target -> SB.CHANNEL_COLOR mapping shared by SB.SoundOutputOverrideColor
--- below (soundID-based, for rendering an already-saved sound) and
--- EditWindow.lua's live dropdown preview (draft-value-based, before the
--- user hits Save) - one place for the "ALL"/"SELF"/"PLAYER:x" special
--- cases so the two can never drift apart.
function SB.OutputOverrideColorForTarget(target)
    if not target or target == "ALL" or target == "SELF" or not SB.IsValidOutputTarget(target) then return nil end
    if target:match("^PLAYER:") then return SB.CHANNEL_COLOR.DIRECT end
    return SB.CHANNEL_COLOR[target]
end

function SB.SoundOutputOverrideColor(soundID)
    local saved = soundID and SB.db and SB.db.sounds and SB.db.sounds[soundID]
    return SB.OutputOverrideColorForTarget(saved and saved.outputOverride)
end

--- Called by SB:TriggerSound (SoundPlayer.lua) after every successful LOCAL
--- play, replacing the old unconditional SB:BroadcastSound call. Reads
--- Settings -> Sound Routing -> "Default Output Channel"
--- (SB.db.settings.defaultOutputTarget) to decide where, if anywhere, this
--- click also gets sent - unless `overrideTarget` is given (a macro's
--- "::<Target>" suffix, see Macros.lua), which takes precedence for this
--- one call only and never touches the saved setting. Now goes through
--- SB:ResolveOutputTarget above, so a per-sound "Default Output" override
--- is honoured too, at the right priority.
function SB:DispatchDefaultOutput(soundID, overrideTarget)
    if not SB.registry[soundID] then return end
    local target = SB:ResolveOutputTarget(soundID, overrideTarget)

    -- Explicit "just me" - already played locally by the caller, nothing
    -- else to do. Never blocked by a raid-admin mute (there's nothing to
    -- send in the first place).
    if target == "SELF" then return end

    local playerName = type(target) == "string" and target:match("^PLAYER:(.+)$")
    if playerName then
        -- Same friend exemption as SendMenu.lua's SB:SendSoundToPlayer - a
        -- direct send to a mutual Friend still goes through even under a
        -- raid-admin mute; anything else stays blocked.
        if SB:IsSendBlockedByRaid() and not SB:IsFriend(playerName) then return end
        SendToPlayerSilent(soundID, playerName)
        return
    end

    if SB:IsSendBlockedByRaid() then return end

    if target == "ALL" then
        SB:BroadcastSound(soundID)
    elseif target == "GUILD" then
        SendToSingleChannelSilent(soundID, "GUILD")
    elseif target == "RAID" or target == "PARTY" then
        -- "RAID" is the merged Raid/Party target (see
        -- SB.ResolveGroupChannel) - resolved to whichever is actually live
        -- right now. "PARTY" is only still checked here as a defensive
        -- fallback for any stray pre-merge saved value that somehow wasn't
        -- migrated; nothing should save it going forward.
        local resolved = SB.ResolveGroupChannel()
        if resolved then SendToSingleChannelSilent(soundID, resolved) end
    elseif target == "FRIENDS" then
        SendToAllFriendsSilent(soundID)
    end
end

------------------------------------------------------------------------
-- Explicit one-off sends - SendMenu.lua's right-click "send to" list on a
-- Mini Soundbook slot. Unlike SB:BroadcastSound above (which fires to every
-- channel currently enabled under Settings -> Broadcast), these ignore that
-- setting entirely - picking a specific target from the menu is a
-- deliberate override of "broadcast everywhere", not another instance of it.
-- Each one plays the sound locally too (same as a normal click would) and
-- prints an immediate "sent" confirmation - separate from, and ahead of,
-- the existing ACK-based "who actually received/played it" notification
-- (PrintFriendsReceived above), which still arrives afterwards as normal.
------------------------------------------------------------------------

local GREEN = "cff55ff88"

-- `channelKey` is one of SB.CHANNEL_COLOR's own keys (GUILD/PARTY/RAID/
-- FRIENDS/DIRECT) and colours just `targetLabel` - kept as a separate
-- parameter from targetLabel itself since a direct send's targetLabel is a
-- PLAYER NAME, not a channel word, and would never match SB.GetChannelColor
-- by text.
local function PrintSent(targetLabel, soundName, channelKey)
    local color = SB.CHANNEL_COLOR[channelKey] or SB.CHANNEL_COLOR.SELF
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|%s[Soundbook]|r |%sSent|r |cffffd100%s|r |cff999999to|r |cff%s%s|r",
        TAG_COLOR, GREEN, soundName, color.hex, targetLabel))
end

-- Plays soundID locally for YOU (same combat/encounter/overlap rules as any
-- other trigger, via the one shared SB:PlaySound) and fires the same
-- LOCAL_SOUND_PLAYED event a normal click does, so the Mini Soundbook's Now
-- Playing overlay picks it up identically. Deliberately does NOT gate the
-- send itself on this - if the sound is muted locally, this just quietly
-- skips your own playback (same as it always has) while the send below
-- still goes out. A local mute is "I don't want to hear this on MY
-- speakers", not "nobody else should ever get this from me" - the two
-- shouldn't be coupled, and coupling them used to make a SendMenu.lua click
-- on a muted sound silently do nothing at all, sent or not.
-- `target` (optional) mirrors what SB:TriggerSound's own LOCAL_SOUND_PLAYED
-- fire already passes - explicit bugfix: every caller below used to omit
-- it entirely, so the Mini Soundbook's Announcement Bar had no idea what
-- a SendMenu.lua-driven send actually went to and always fell back to
-- "Self", even for a real Direct/Guild/Friends send. See FavouritesWindow.
-- lua's LOCAL_SOUND_PLAYED handler for how this gets turned into the
-- displayed source label (and, for a Direct send, the recipient's name).
local function PlayLocally(soundID, target)
    local saved = SB:GetSoundSaved(soundID)
    if saved and saved.muted then return end
    if SB:PlaySound(soundID, "local") then
        SB:Fire("LOCAL_SOUND_PLAYED", soundID, target)
    end
end

-- Whole-channel send (Guild/Party/Raid) - SendMenu.lua's group header rows.
-- A raid-admin mute (see the Raid Admin section further below) blocks this
-- entirely, including the local play - unlike a normal click (TriggerSound),
-- this is a deliberate "send to X" action with no other purpose, so there's
-- nothing useful left to do if the send itself is blocked.
function SB:SendSoundToChannel(soundID, channel)
    if not SB.registry[soundID] then return end
    -- "RAID" is the merged Raid/Party target (SendMenu.lua's single
    -- Raid/Party group row) - resolved here to whichever is actually live
    -- right now (see SB.ResolveGroupChannel). "PARTY" is only still
    -- accepted as a defensive fallback, same reasoning as
    -- SB:DispatchDefaultOutput above.
    if channel == "RAID" or channel == "PARTY" then
        channel = SB.ResolveGroupChannel()
    end
    if channel ~= "GUILD" and channel ~= "PARTY" and channel ~= "RAID" then return end
    if SB:IsSendBlockedByRaid() then
        SB:Print("Sending is currently disabled by your raid leader.")
        return
    end
    PlayLocally(soundID, channel)
    recentBroadcasts[soundID] = GetTime()
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "PLAY" .. SEP .. soundID, channel)
    local label = channel:sub(1, 1) .. channel:sub(2):lower() -- GUILD -> Guild
    PrintSent(label, SB:GetSoundDisplayName(soundID), channel)
end

-- Whole-Friends-list send - SendMenu.lua's "Friends" group header row. No
-- GetGroupCoveredNames suppression here (unlike SB:BroadcastSound) - this
-- is itself the one deliberate send, not one of several simultaneous
-- channels that could double up with each other.
function SB:SendSoundToAllFriends(soundID)
    if not SB.registry[soundID] then return end
    if SB:IsSendBlockedByRaid() then
        SB:Print("Sending is currently disabled by your raid leader.")
        return
    end
    PlayLocally(soundID, "FRIENDS")
    recentBroadcasts[soundID] = GetTime()
    local text = SB.PROTOCOL_VERSION .. SEP .. "PLAY" .. SEP .. soundID
    SendToFriends(text, {})
    PrintSent("Friends", SB:GetSoundDisplayName(soundID), "FRIENDS")
end

-- Direct, single-person send - SendMenu.lua's per-player rows (works for
-- ANY known Soundbook user reachable by whisper, not just WoW "Friends").
-- Tagged with a trailing "|D" so the receiver's notification and the
-- sender's aggregated "received via" list both show "Direct" instead of the
-- generic "Friend" a plain whisper-broadcast gets - see HandlePlayCommand/
-- OnAddonMessage below.
-- Friend exemption: a direct 1:1 send to a mutual WoW Friend still goes
-- through even while a raid-admin mute is active - explicit request
-- ("Nur Freunde können sich untereinander schicken"). This is the ONLY
-- SendMenu.lua action exempted this way - SB:SendSoundToChannel/
-- SendSoundToAllFriends (a whole channel, or every friend at once) stay
-- fully blocked regardless, since those are exactly the group-context
-- spam Mute All exists to stop; a single deliberate send between two
-- confirmed friends is a different, much narrower thing.
function SB:SendSoundToPlayer(soundID, name)
    if not SB.registry[soundID] or not SB.IsValidPlayerTarget(name) then return end
    if SB:IsSendBlockedByRaid() and not SB:IsFriend(name) then
        SB:Print("Sending is currently disabled by your raid leader.")
        return
    end
    PlayLocally(soundID, "PLAYER:" .. name)
    recentBroadcasts[soundID] = GetTime()
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "PLAY" .. SEP .. soundID .. SEP .. "D", "WHISPER", name)
    PrintSent(NormalizeName(name) or name, SB:GetSoundDisplayName(soundID), "DIRECT")
end

-- SendMenu.lua's extra top row (explicit request) - only offered when the
-- player's own Default Output isn't already "ALL" (otherwise a plain click
-- already does exactly this, no menu shortcut needed). A one-off way to
-- send via whatever Settings -> Sound Routing -> Broadcast currently has
-- enabled, without changing that setting or touching any per-sound
-- override - same deliberate "local replay + chat confirmation" shape as
-- every other SendMenu.lua action, unlike the quiet SB:BroadcastSound this
-- wraps (that one's meant to run silently after SB:TriggerSound already did
-- its own local play and confirmation).
function SB:SendSoundUsingDefaultBroadcast(soundID)
    if not SB.registry[soundID] then return end
    if SB:IsSendBlockedByRaid() then
        SB:Print("Sending is currently disabled by your raid leader.")
        return
    end
    PlayLocally(soundID, "ALL")
    SB:BroadcastSound(soundID)
    -- No single channel colour fits "possibly several at once" - falls
    -- back to PrintSent's own SELF grey.
    PrintSent("your enabled channels", SB:GetSoundDisplayName(soundID), nil)
end

-- SendMenu.lua's extra bottom row (explicit request) - always offered,
-- regardless of Default Output/per-sound overrides: play locally only, no
-- network send of any kind. No PrintSent - nothing was actually sent to
-- anyone, so no "Sent to X" confirmation makes sense here.
function SB:PlaySoundSelfOnly(soundID)
    if not SB.registry[soundID] then return end
    PlayLocally(soundID, "SELF")
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------

-- `isDirect` distinguishes a Direct-targeted send (SendMenu's "send to one
-- specific person", from a Friend, Guild member, whoever) from a plain
-- Friends-list broadcast - both travel as WHISPER, but explicit request:
-- they now have their own separate receive toggle (receiveDirect vs
-- receiveFriends) rather than sharing one. Callers must resolve isDirect
-- (see ParsePlayPayload) BEFORE calling this for WHISPER traffic.
local function ReceiveAllowedForChannel(channel, isDirect)
    local s = SB.db.settings
    -- Raid and Party share one Receive toggle now too (explicit request,
    -- reversed from an earlier "Send merged, Receive still separate"
    -- version) - receiveRaid covers both wire channels.
    if channel == "PARTY" or channel == "RAID" or channel == "RAID_LEADER" then return s.receiveRaid
    elseif channel == "GUILD" or channel == "OFFICER" then return s.receiveGuild
    elseif channel == "WHISPER" then return isDirect and s.receiveDirect or s.receiveFriends
    end
    return false
end

-- User-facing label for the "Now Playing" display in the Favourites
-- mini-window (see FavouritesWindow.lua), keyed by the same channel
-- values CHAT_MSG_ADDON reports.
local CHANNEL_LABEL = {
    PARTY = "Party", RAID = "Raid", RAID_LEADER = "Raid",
    GUILD = "Guild", OFFICER = "Guild", WHISPER = "Friend",
}

-- Pending "who received this" receipts, waiting for a short quiet period
-- before printing the aggregated list (several friends can ack the same
-- broadcast within a second or two of each other). `mutedNames`/`rxOffNames`
-- are SETs (not lists) purely to de-duplicate a retried MUTEACK/RXOFFACK
-- the same way `entries` already de-dupes a retried ACK below - only their
-- counts are ever shown, never the names themselves (explicit request:
-- "sehen ob und wieviele", not who).
local pendingAcks = {} -- [soundID] = { entries = { {name=, code=}, ... }, mutedNames = {[name]=true}, mutedCount = 0, rxOffNames = {[name]=true}, rxOffCount = 0, timer = <handle> }
local ACK_DEBOUNCE = 1.5 -- seconds of quiet before printing

local function EnsurePending(soundID)
    local pending = pendingAcks[soundID]
    if not pending then
        pending = { entries = {}, mutedNames = {}, mutedCount = 0, rxOffNames = {}, rxOffCount = 0 }
        pendingAcks[soundID] = pending
    end
    return pending
end

-- Forward-declared so RestartFlushTimer (defined first, used by both
-- HandleAck and HandleMuteAck below) can reference it before its own
-- definition further down.
local FlushAcks

local function RestartFlushTimer(soundID, pending)
    if pending.timer then pending.timer:Cancel() end
    pending.timer = C_Timer.NewTimer(ACK_DEBOUNCE, function() FlushAcks(soundID) end)
end

FlushAcks = function(soundID)
    local pending = pendingAcks[soundID]
    if not pending then return end
    pendingAcks[soundID] = nil
    if #pending.entries > 0 or pending.mutedCount > 0 or pending.rxOffCount > 0 then
        PrintFriendsReceived(SB:GetSoundDisplayName(soundID), pending.entries, pending.mutedCount, pending.rxOffCount)
    end
end

-- Analytics: a real ack (played OR muted - either way, a genuine OTHER
-- player's Soundbook actually received and processed the message) is the
-- earliest honest proof of "a real sender AND a real recipient" - explicit
-- requirement, this is a multiplayer soundbook and its statistics must
-- only ever reflect real social interactions, never a purely local/self
-- play or a send that had nobody around to receive it (SELF never even
-- reaches recentBroadcasts - see SB:DispatchDefaultOutput - and a send
-- with no one to receive it simply never gets an ack, so it's naturally
-- excluded too). Deliberately independent of the notifyFriendReceipts
-- setting just below - that only controls a CHAT notification, not
-- whether the underlying interaction genuinely happened. Credited exactly
-- once per outgoing broadcast (keyed off recentBroadcasts' own timestamp,
-- so a later replay of the same sound can be credited again) regardless
-- of how many people ack it or in which order the first ack arrives.
local analyticsCreditedAt = {} -- [soundID] = the recentBroadcasts timestamp already credited
local function CreditAnalyticsOnce(soundID, sentAt)
    if analyticsCreditedAt[soundID] == sentAt then return end
    analyticsCreditedAt[soundID] = sentAt
    if SB.AnalyticsRecordPlay then SB:AnalyticsRecordPlay(soundID) end
end

-- `code` is the single-letter channel (F/P/R/G) the acking player actually
-- received the sound over - see CHANNEL_CODE above.
local function HandleAck(soundID, code, sender)
    local sentAt = recentBroadcasts[soundID]
    if not sentAt or (GetTime() - sentAt) > ACK_CLAIM_WINDOW then
        return -- not something we broadcast recently - ignore
    end
    CreditAnalyticsOnce(soundID, sentAt)
    if not SB.db.settings.notifyFriendReceipts then return end

    local name = NormalizeName(sender) or sender
    local senderKey = IdentityKey(sender) or sender
    local pending = EnsurePending(soundID)
    for _, e in ipairs(pending.entries) do
        if e.key == senderKey then return end -- already counted (e.g. a duplicate/retried ack)
    end
    table.insert(pending.entries, { name = name, key = senderKey, code = code })
    RestartFlushTimer(soundID, pending)
end

-- Same idea as HandleAck, but for a recipient who had the sound MUTED
-- locally instead of actually playing it (see HandlePlayCommand's
-- MUTEACK send) - only ever contributes to the count, never to the
-- "received" name list itself. Still counts for Analytics (see
-- CreditAnalyticsOnce above) - a real other player's client genuinely
-- received it either way, they just chose not to hear it.
local function HandleMuteAck(soundID, sender)
    local sentAt = recentBroadcasts[soundID]
    if not sentAt or (GetTime() - sentAt) > ACK_CLAIM_WINDOW then
        return
    end
    CreditAnalyticsOnce(soundID, sentAt)
    if not SB.db.settings.notifyFriendReceipts then return end

    local name = IdentityKey(sender) or sender
    local pending = EnsurePending(soundID)
    if pending.mutedNames[name] then return end -- already counted
    pending.mutedNames[name] = true
    pending.mutedCount = pending.mutedCount + 1
    RestartFlushTimer(soundID, pending)
end

-- Same idea again, but for a recipient who never even reached the
-- mute/play decision at all - they have the whole receive channel this
-- sound arrived on switched off (Settings' Send/Receive table), see the
-- RXOFFACK send in OnAddonMessage's PLAY handling. Explicit request: this
-- is Debug-Mode-only (SB:IsDebug(), a purely local per-client toggle) -
-- checked on OUR (the sender's) own client, since we're the one deciding
-- whether to show it, not the recipient - by default a normal user must
-- see exactly the original behaviour, literally nothing, same as if the
-- sound had never been sent at all. Analytics crediting happens
-- regardless of Debug Mode though (same reasoning as HandleMuteAck above -
-- a real other client genuinely got the message, whether we display that
-- fact locally right now is a separate concern).
local function HandleRxOffAck(soundID, sender)
    local sentAt = recentBroadcasts[soundID]
    if not sentAt or (GetTime() - sentAt) > ACK_CLAIM_WINDOW then
        return
    end
    CreditAnalyticsOnce(soundID, sentAt)
    if not SB:IsDebug() then return end

    local name = IdentityKey(sender) or sender
    local pending = EnsurePending(soundID)
    if pending.rxOffNames[name] then return end -- already counted
    pending.rxOffNames[name] = true
    pending.rxOffCount = pending.rxOffCount + 1
    RestartFlushTimer(soundID, pending)
end

-- Explicit request: if an incoming PLAY references a Legacy/German Memes
-- soundID we don't have locally at all, the most likely explanation is
-- that OUR OWN Soundbook is older than the sender's - a shared/standard
-- sound they already have that we haven't updated to yet (as opposed to
-- one of their own private Category 1/2 or Stammtisch sounds, which is
-- normal and not a version problem - checked here by parsing the category
-- straight out of the soundID string, which works even for an id we don't
-- recognize at all, no registry lookup needed). Hints the RECEIVING
-- player their addon may be out of date, at most once every 24h
-- (SB.db.lastOutdatedHintAt, time() epoch - survives /reload and a full
-- restart the same way every other persisted timestamp in this addon
-- does) so a burst of the same broadcast, or several different senders in
-- a row, can't spam chat with it.
local OUTDATED_HINT_COOLDOWN = 24 * 60 * 60
local function MaybeShowOutdatedHint(soundID)
    local category = SB.ParseSoundID(soundID)
    if category ~= "Legacy" and category ~= "German Memes" then return end
    local last = SB.db.lastOutdatedHintAt or 0
    if (time() - last) < OUTDATED_HINT_COOLDOWN then return end
    SB.db.lastOutdatedHintAt = time()
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|%s[Soundbook]|r |cffff5555Your Soundbook seems to be out of date|r - someone just tried to send you a sound you don't have yet. Update the addon to get the newest sounds.",
        TAG_COLOR))
end

local function HandlePlayCommand(soundID, sender, channel, isDirect)
    -- The per-(sender,soundID) repeat-cooldown check+stamp used to live
    -- HERE, at actual play time - moved to HandleIncomingPlay, which now
    -- claims the cooldown slot the moment a sound is ACCEPTED (queued or
    -- played immediately), not only once it's actually played. Every path
    -- that reaches this function already went through that check, so
    -- nothing further to do here - see HandleIncomingPlay's own comment for
    -- the burst-duplicate bug this fixes.
    if not SB.registry[soundID] then
        -- Largely unreachable in practice - HandleIncomingPlay's own
        -- IsPlayableRightNow already rejects an unknown soundID earlier,
        -- before this function is ever called (see NotifyIfMuted for
        -- where the actual "unknown" handling - MaybeShowOutdatedHint
        -- included - now lives). Kept as a defensive fallback only.
        SB:Debug("Missing sound: %s\nSender: %s", soundID, sender)
        return
    end

    -- A SendMenu.lua direct send always shows as "Direct", regardless of the
    -- fact it physically travels over the same WHISPER channel a
    -- broadcast-to-all-friends send does - see SB:SendSoundToPlayer above.
    local channelLabel = isDirect and "Direct" or (CHANNEL_LABEL[channel] or channel)

    -- Raid-admin "mute all" (see the Raid Admin section below) blocks
    -- receiving too, not just sending - deliberately silent here (no
    -- PrintMuted), same treatment as any other blocked-and-not-shown case:
    -- the muted player already got their own explicit chat line the moment
    -- the mute was applied (ApplyRaidOverride), so repeating it on every
    -- single blocked sound the whole raid would be spammy. Mirrors
    -- SB:SendSoundToPlayer's own friend exemption: a DIRECT send from a
    -- mutual Friend still gets through, since that's a private 1:1 action,
    -- not the group-context spam Mute All targets.
    if SB:IsReceiveBlockedByRaid() and not (isDirect and SB:IsFriend(sender)) then
        SB:Debug("Remote sound %s from %s ignored (raid-admin mute all).", soundID, sender)
        return
    end

    -- Individual Mute (Mini Soundbook mute button's right-click dropdown) -
    -- blocks EVERY sound from this one specific person, no exemption (this
    -- is a deliberate per-PERSON block the player picked, unlike the
    -- group-context raid mute above which exempts a direct Friend send).
    -- Same MUTEACK reply as the per-sound mute below, so the sender's
    -- aggregated "(N muted)" chat line includes this too.
    if SB:IsPlayerMuted(sender) then
        SB:Debug("Remote sound %s from %s ignored (individually muted).", soundID, sender)
        if SB.db.settings.notifyMutedAttempts then
            PrintMuted(NormalizeName(sender) or sender, channelLabel, SB:GetSoundDisplayName(soundID))
        end
        SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "MUTEACK" .. SEP .. soundID, "WHISPER", sender)
        return
    end

    local saved = SB:GetSoundSaved(soundID)
    if saved and saved.muted then
        SB:Debug("Remote sound %s from %s ignored (muted locally).", soundID, sender)
        if SB.db.settings.notifyMutedAttempts then
            PrintMuted(NormalizeName(sender) or sender, channelLabel, SB:GetSoundDisplayName(soundID))
        end
        -- Explicit request: the SENDER should be able to see how many
        -- recipients had this sound muted, not just who actually played
        -- it - a small "MUTEACK" reply, same idea as the regular ACK just
        -- below for a successful play. Always sent regardless of THIS
        -- player's own notify settings (same reasoning as the plain ACK) -
        -- see HandleMuteAck for how the sender aggregates/displays it.
        SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "MUTEACK" .. SEP .. soundID, "WHISPER", sender)
        return
    end

    local played = SB:PlaySound(soundID, "remote")
    if played then
        SB:Fire("REMOTE_SOUND_PLAYED", soundID, NormalizeName(sender) or sender, channelLabel, IdentityKey(sender))
        -- Always send the tiny receipt back, regardless of THIS player's
        -- own notifyFriendReceipts setting - that setting only controls
        -- whether they see the aggregated list for sounds THEY sent (see
        -- HandleAck below). Requiring every recipient to opt in just to
        -- reply made the sender-side feature basically never fire; a
        -- one-line "someone got it" reply isn't sensitive enough to
        -- justify that friction. The channel WE received it over rides
        -- along so the sender can show "Guild received: ..." etc.
        local ackCode = isDirect and "D" or (CHANNEL_CODE[channel] or "?")
        SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "ACK" .. SEP .. soundID .. SEP .. ackCode, "WHISPER", sender)
    end
end

------------------------------------------------------------------------
-- Forward-compatible payload parsing - a basic PLAY (and ACK) must keep
-- working across Soundbook versions even as optional fields get added over
-- time. Both take a "first segment is the important part, everything after
-- is an optional flag we may or may not recognize" approach rather than an
-- anchored end-of-string pattern: an unrecognized trailing segment from a
-- newer client is simply ignored instead of breaking the whole parse (which
-- an end-anchored pattern like the ACK one used to do here - a single
-- unexpected extra field would have silently dropped the entire message).
------------------------------------------------------------------------

--- PLAY payload: "soundID" or "soundID|D" (or "soundID|D|<future flag>",
--- "soundID|<some other future flag>", ...). Only ever soundID is required;
--- every segment after the first is optional and any we don't recognize
--- (currently just "D", direct-send - see SB:SendSoundToPlayer above) is
--- silently ignored rather than rejecting the message.
-- @return string soundID, boolean isDirect
local function ParsePlayPayload(payload)
    local soundID, rest = payload:match("^([^|]*)|?(.*)$")
    soundID = soundID or payload
    local isDirect = false
    if rest and rest ~= "" then
        for flag in (rest .. SEP):gmatch("([^|]*)" .. SEP) do
            if flag == "D" then isDirect = true end
            -- any other flag: forward-compat no-op.
        end
    end
    return soundID, isDirect
end

--- ACK payload: "soundID|code" - code is the single-letter channel (see
--- CHANNEL_CODE/CODE_NAME above). A missing/malformed code defaults to "?"
--- (an unknown-channel entry is still useful in the aggregated "received
--- via" list) rather than the whole ACK being dropped - "fehlende optionale
--- Felder mit Defaults behandeln".
-- @return string|nil soundID (nil if the payload is empty/unparseable), string code
local function ParseAckPayload(payload)
    local soundID, code = payload:match("^([^|]*)|?([^|]*)")
    if not soundID or soundID == "" then return nil end
    if not CODE_NAME[code] then code = "?" end
    return soundID, code
end

------------------------------------------------------------------------
-- Anti-Spam: FIFO queue/spooler for incoming remote PLAY commands, plus a
-- hard discard-only mode when the queue is switched off (Settings -> Remote
-- Playback -> "Sound Queue / Spooler", SB.db.settings.soundQueueEnabled,
-- default true). Every limit below is a single named constant, not a
-- scattered magic number, and everything here is event/timer-driven
-- (C_Timer) - there is no permanent OnUpdate poll; the queue only ever
-- "runs" while something is actually pending in it.
--
-- Two SEPARATE rate limits apply regardless of the queue setting:
--   - per-SENDER: a minimum gap between accepted sounds from the same
--     person, plus a max-per-time-window on top of that (stops one chatty
--     sender from flooding).
--   - GLOBAL: the same two kinds of limit again, but counted across EVERY
--     sender combined - explicit request: many raid members each
--     individually within their own per-sender limit could still flood the
--     raid together without this.
-- QUEUE ON: a sound that doesn't currently fit within these limits waits in
--   a small FIFO queue (capped size, oldest first) instead of being lost -
--   an over-capacity queue discards the newest arrival, never grows
--   unbounded.
-- QUEUE OFF: no queue exists at all - anything over either rate limit is
--   discarded immediately and permanently, never played late.
------------------------------------------------------------------------

local QUEUE_MIN_SENDER_GAP = 1.0       -- seconds between two accepted sounds from the SAME sender
local QUEUE_SENDER_WINDOW = 5.0        -- seconds, sliding window for the per-sender cap below
local QUEUE_SENDER_MAX_IN_WINDOW = 3   -- max accepted sounds per sender within QUEUE_SENDER_WINDOW
local QUEUE_MAX_SIZE = 5               -- max sounds waiting in the FIFO queue at once
local GLOBAL_MIN_GAP = 0.2             -- seconds between ANY two accepted sounds, any sender
local GLOBAL_WINDOW = 5.0              -- seconds, sliding window for the global cap below
local GLOBAL_MAX_IN_WINDOW = 8         -- max accepted sounds (any sender combined) within GLOBAL_WINDOW

local pendingQueue = {}       -- FIFO array of { soundID, sender, channel, isDirect }
local queueTimer
local SOURCE_PRIORITY = { PARTY = 1, RAID = 2, RAID_LEADER = 2, GUILD = 3, OFFICER = 3, WHISPER = 4 }
local recentSource = {}       -- [normalizedSender|soundID] = { priority, label }

local function SourcePriority(channel, isDirect)
    return isDirect and 5 or (SOURCE_PRIORITY[channel] or 0)
end
local senderAcceptLog = {}    -- [normalizedSender] = { lastAcceptedAt = GetTime(), times = { GetTime(), ... } }
local globalAcceptTimes = {}  -- array of GetTime() for every accepted sound, any sender
local globalLastAcceptedAt
local lastReceiveCachePruneAt = 0

local function PruneReceiveCaches(now)
    if now - lastReceiveCachePruneAt < 60 then return end
    local cutoff = now - math.max(60, (tonumber(SB.db.settings.remoteCooldown) or 1) * 4)
    for key, acceptedAt in pairs(lastReceivedFrom) do
        if acceptedAt < cutoff then lastReceivedFrom[key] = nil end
    end
    for key, source in pairs(recentSource) do
        if not source.at or source.at < cutoff then recentSource[key] = nil end
    end
    for key, log in pairs(senderAcceptLog) do
        if not log.lastAcceptedAt or log.lastAcceptedAt < (now - 60) then senderAcceptLog[key] = nil end
    end
    lastReceiveCachePruneAt = now
end

--- Empties the incoming-sound FIFO right now. "/sb stop" calls this
--- alongside SB:StopAllSounds(), so it also forgets what was queued next.
function SB:ClearPendingQueue()
    local hadEntries = #pendingQueue > 0
    wipe(pendingQueue)
    if queueTimer then
        queueTimer:Cancel()
        queueTimer = nil
    end
    if hadEntries then SB:Fire("REMOTE_QUEUE_CHANGED", 0) end
end

--- Read-only, for "/sb doctor" (Core.lua) - how many remote sounds are
--- currently waiting to play.
function SB:GetPendingQueueSize()
    return #pendingQueue
end

-- Same FRIENDS/GUILD/RAID/PARTY <-> raw CHAT_MSG_ADDON channel mapping
-- ReceiveAllowedForChannel below uses, reused here so both agree on what
-- "this queued entry belongs to that setting" means. DIRECT isn't in here -
-- like ReceiveAllowedForChannel, it shares the WHISPER channel with
-- FRIENDS and is told apart by the queued entry's own isDirect flag
-- instead (see ClearPendingQueueForMode below).
-- RAID now covers the PARTY wire channel too (Raid/Party share one
-- Receive toggle, see ReceiveAllowedForChannel above) - no separate PARTY
-- mode is ever passed in any more, but the wire channel itself is still
-- literally "PARTY" on incoming traffic, so it still needs matching here.
local MODE_CHANNELS = {
    FRIENDS = { WHISPER = true },
    GUILD = { GUILD = true, OFFICER = true },
    RAID = { RAID = true, RAID_LEADER = true, PARTY = true },
}

--- Purges any pending-queue entries that arrived over a channel matching
--- `mode` ("FRIENDS"/"GUILD"/"RAID"/"PARTY"/"DIRECT") - explicit
--- requirement: disabling a receive channel (Settings' Send/Receive table)
--- must reliably drop whatever's already waiting from that channel too,
--- not just block new arrivals from it going forward.
function SB:ClearPendingQueueForMode(mode)
    local before = #pendingQueue
    if mode == "DIRECT" then
        for i = #pendingQueue, 1, -1 do
            if pendingQueue[i].channel == "WHISPER" and pendingQueue[i].isDirect then
                table.remove(pendingQueue, i)
            end
        end
        if #pendingQueue ~= before then SB:Fire("REMOTE_QUEUE_CHANGED", #pendingQueue) end
        return
    end

    local matchSet = MODE_CHANNELS[mode]
    if not matchSet then return end
    for i = #pendingQueue, 1, -1 do
        local entry = pendingQueue[i]
        -- FRIENDS must now exclude Direct-targeted entries - those belong
        -- to the DIRECT mode above instead (both share WHISPER on the wire).
        if matchSet[entry.channel] and not (mode == "FRIENDS" and entry.isDirect) then
            table.remove(pendingQueue, i)
        end
    end
    if #pendingQueue ~= before then SB:Fire("REMOTE_QUEUE_CHANGED", #pendingQueue) end
end

--- Read-only peek at whether `soundID` from `sender` is still within the
--- existing per-(sender,sound) repeat cooldown (the SAME lastReceivedFrom
--- table HandlePlayCommand itself checks/updates at actual play time) -
--- checked BEFORE queueing so an obvious repeat never wastes a queue slot,
--- rather than only being caught later when it's finally dequeued.
local function IsRecentDuplicate(sender, soundID)
    local key = (IdentityKey(sender) or "?") .. "|" .. soundID
    local last = lastReceivedFrom[key]
    if not last then return false end
    local cooldown = tonumber(SB.db.settings.remoteCooldown) or 1.0
    return (GetTime() - last) < cooldown
end

-- `list` is oldest-first (entries are always appended, so index 1 is
-- always the oldest) - prune from the FRONT and stop the moment the oldest
-- remaining entry is within the window, since everything after it is even
-- newer. (An earlier version of this walked from the back and broke on the
-- first non-expired entry it saw - which, walking backward, is always the
-- newest one, so it never actually removed anything.)
local function PruneOld(list, now, window)
    while list[1] and now - list[1] > window do
        table.remove(list, 1)
    end
end

--- Whether a sound from `sender` may be accepted RIGHT NOW under both the
--- per-sender and global rate limits.
-- @return boolean ok, number|nil waitSeconds (only set when ok is false -
--   how long until this specific limit might allow it, used to schedule
--   the queue's next processing attempt)
local function CanAcceptNow(sender, now)
    local senderLog = senderAcceptLog[sender]
    if senderLog then
        if senderLog.lastAcceptedAt and (now - senderLog.lastAcceptedAt) < QUEUE_MIN_SENDER_GAP then
            return false, QUEUE_MIN_SENDER_GAP - (now - senderLog.lastAcceptedAt)
        end
        PruneOld(senderLog.times, now, QUEUE_SENDER_WINDOW)
        if #senderLog.times >= QUEUE_SENDER_MAX_IN_WINDOW then
            return false, math.max(0.05, QUEUE_SENDER_WINDOW - (now - senderLog.times[1]))
        end
    end

    PruneOld(globalAcceptTimes, now, GLOBAL_WINDOW)
    if globalLastAcceptedAt and (now - globalLastAcceptedAt) < GLOBAL_MIN_GAP then
        return false, GLOBAL_MIN_GAP - (now - globalLastAcceptedAt)
    end
    if #globalAcceptTimes >= GLOBAL_MAX_IN_WINDOW then
        return false, math.max(0.05, GLOBAL_WINDOW - (now - globalAcceptTimes[1]))
    end

    return true
end

local function RecordAccepted(sender, now)
    local senderLog = senderAcceptLog[sender]
    if not senderLog then
        senderLog = { times = {} }
        senderAcceptLog[sender] = senderLog
    end
    senderLog.lastAcceptedAt = now
    table.insert(senderLog.times, now)

    globalLastAcceptedAt = now
    table.insert(globalAcceptTimes, now)
end

--- Whether `soundID` would actually be playable right now if accepted -
--- explicit requirement: checked BEFORE it's ever allowed to consume a
--- queue slot or a rate-limit accept credit, not just discovered after the
--- fact once it's finally dequeued. Deliberately mirrors (does not
--- replace) HandlePlayCommand's OWN checks - that function still re-checks
--- all of this again right before actually playing as a redundant safety
--- net, since a queued entry can go from valid to invalid while it waits
--- (e.g. muted moments after arriving) - this is purely the "don't even
--- let an unplayable one take a slot in the first place" half.
--- @return boolean playable, string|nil reason ("unknown"/"raid_blocked"/
---   "muted" when not playable - callers use this to decide whether a
---   rejection notification is warranted, see NotifyIfMuted below)
local function IsPlayableRightNow(soundID, sender, isDirect)
    if not SB.registry[soundID] then return false, "unknown" end
    if SB:IsReceiveBlockedByRaid() and not (isDirect and SB:IsFriend(sender)) then return false, "raid_blocked" end
    -- Individual Mute (Mini Soundbook mute button's right-click dropdown) -
    -- no exemption, unlike the raid-mute-all check above - this is a
    -- deliberate per-PERSON block the player picked themselves.
    if SB:IsPlayerMuted(sender) then return false, "player_muted" end
    local saved = SB:GetSoundSaved(soundID)
    if saved and saved.muted then return false, "muted" end
    return true
end

--- Both call sites that reject via IsPlayableRightNow before ever reaching
--- HandlePlayCommand (HandleIncomingPlay and ProcessQueue's own
--- re-validation) call this, so whatever local reaction a rejection
--- reason deserves fires from wherever the rejection actually happens now
--- - the name predates the "unknown" branch below, kept since renaming it
--- everywhere isn't worth the diff.
-- Explicit request: also covers "player_muted" now (the Individual Mute
-- dropdown), not just the original per-sound "muted" - either way, the
-- SENDER gets a MUTEACK reply so their own aggregated "(N muted)" chat
-- line (see HandleMuteAck) includes it, regardless of THIS player's own
-- notifyMutedAttempts setting (that setting only controls the LOCAL
-- "someone tried to send you a muted sound" line below).
local function NotifyIfMuted(reason, soundID, sender, channel, isDirect)
    if reason == "unknown" then
        -- This is the ACTUAL rejection point for a soundID we don't have
        -- at all - see MaybeShowOutdatedHint's own comment above for why
        -- this specifically means "our own Soundbook might be outdated"
        -- for a Legacy/German Memes id.
        MaybeShowOutdatedHint(soundID)
        return
    end
    if reason ~= "muted" and reason ~= "player_muted" then return end
    if SB.db.settings.notifyMutedAttempts then
        local channelLabel = isDirect and "Direct" or (CHANNEL_LABEL[channel] or channel)
        PrintMuted(NormalizeName(sender) or sender, channelLabel, SB:GetSoundDisplayName(soundID))
    end
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "MUTEACK" .. SEP .. soundID, "WHISPER", sender)
end

--- Scans the WHOLE queue (not just its head) for the first entry whose
--- sender currently passes the rate limits, and plays that one - explicit
--- fairness requirement: a strictly FIFO-head-only check meant one heavy
--- sender's own item stuck at the front could block every OTHER sender's
--- already-eligible sound behind it indefinitely. FIFO order is still
--- preserved AMONG eligible entries (the earliest-queued eligible one
--- always wins), just no longer a hard blocker for entries that aren't
--- eligible yet. If nothing in the queue is eligible right now, reschedules
--- itself via a ONE-SHOT C_Timer for whichever blocked entry frees up
--- soonest - never a repeating/polling timer, and nothing is scheduled at
--- all while the queue is empty.
local function ProcessQueue()
    queueTimer = nil
    if #pendingQueue == 0 then return end

    local now = GetTime()
    local earliestWait

    for i, entry in ipairs(pendingQueue) do
        -- Re-validate right before actually playing (explicit requirement)
        -- - something that was fine when queued (e.g. not yet muted, not
        -- yet raid-blocked) may no longer be by the time its turn comes up.
        -- A now-stale entry is dropped outright, no rate-limit slot spent
        -- on it at all, then the scan continues at the same index (nothing
        -- shifted forward yet).
        local playable, reason = IsPlayableRightNow(entry.soundID, entry.sender, entry.isDirect)
        if not playable then
            table.remove(pendingQueue, i)
            SB:Fire("REMOTE_QUEUE_CHANGED", #pendingQueue)
            NotifyIfMuted(reason, entry.soundID, entry.sender, entry.channel, entry.isDirect)
            return ProcessQueue()
        end

        local ok, waitSeconds = CanAcceptNow(entry.rateLimitKey, now)
        if ok then
            table.remove(pendingQueue, i)
            SB:Fire("REMOTE_QUEUE_CHANGED", #pendingQueue)
            RecordAccepted(entry.rateLimitKey, now)
            local key = (IdentityKey(entry.sender) or "?") .. "|" .. entry.soundID
            lastReceivedFrom[key] = now
            recentSource[key] = {
                priority = SourcePriority(entry.channel, entry.isDirect),
                label = entry.isDirect and "Direct" or (CHANNEL_LABEL[entry.channel] or entry.channel),
                at = now,
            }
            HandlePlayCommand(entry.soundID, entry.sender, entry.channel, entry.isDirect)
            -- Try again in case something else in the queue is ALSO
            -- eligible right now (e.g. a different sender) - reschedules
            -- itself via timer if not, so this never spins.
            if #pendingQueue > 0 then ProcessQueue() end
            return
        elseif not earliestWait or waitSeconds < earliestWait then
            earliestWait = waitSeconds
        end
    end

    if earliestWait then
        queueTimer = C_Timer.NewTimer(earliestWait, ProcessQueue)
    end
end

--- Single entry point for an incoming PLAY once the channel filter has
--- already passed (see OnAddonMessage) - decides queue vs. immediate-play
--- vs. discard based on Settings -> "Sound Queue / Spooler" and the rate
--- limits above. Replaces the old direct HandlePlayCommand call.
-- Rate-limit bookkeeping (senderAcceptLog) is keyed by NORMALIZED name,
-- consistent with lastReceivedFrom/every other identity comparison in this
-- file - kept separate from the RAW `sender` string still passed through to
-- HandlePlayCommand/SendAddonMessage's WHISPER target, which needs the
-- real, possibly realm-qualified name to actually address a reply.
local function HandleIncomingPlay(soundID, sender, channel, isDirect)
    PruneReceiveCaches(GetTime())
    local duplicateKey = (IdentityKey(sender) or "?") .. "|" .. soundID
    if IsRecentDuplicate(sender, soundID) then
        -- A broadcast may reach us through several groups. Do not replay it,
        -- but upgrade the visible source according to Direct > Friends >
        -- Guild > Raid > Party when the better copy arrives later.
        local priority = SourcePriority(channel, isDirect)
        local previous = recentSource[duplicateKey]
        if not previous or priority > previous.priority then
            local label = isDirect and "Direct" or (CHANNEL_LABEL[channel] or channel)
            recentSource[duplicateKey] = { priority = priority, label = label, at = GetTime() }
            SB:Fire("REMOTE_SOUND_PLAYED", soundID, NormalizeName(sender) or sender, label, IdentityKey(sender))
        end
        SB:Debug("Duplicate remote sound %s from %s within cooldown, ignored.", soundID, sender)
        return
    end

    -- Unplayable outright (unknown sound / raid-blocked / muted locally) -
    -- explicit requirement: rejected before ever touching the queue or a
    -- rate-limit slot, and the repeat-cooldown below is deliberately NOT
    -- stamped for this either - see its own comment further down.
    local playable, reason = IsPlayableRightNow(soundID, sender, isDirect)
    if not playable then
        SB:Debug("Remote sound %s from %s not playable right now, never queued.", soundID, sender)
        NotifyIfMuted(reason, soundID, sender, channel, isDirect)
        return
    end

    -- Explicit requirement: a duplicate of a sound ALREADY waiting in the
    -- queue is coalesced (collapsed) rather than adding a second copy that
    -- would just play the same thing twice in a row once the queue gets to
    -- both of them.
    for _, queued in ipairs(pendingQueue) do
        local sameSender = IdentityKey(queued.sender) == IdentityKey(sender)
        if queued.soundID == soundID and sameSender then
            if SourcePriority(channel, isDirect) > SourcePriority(queued.channel, queued.isDirect) then
                queued.channel = channel
                queued.isDirect = isDirect
                SB:Debug("Queued remote sound %s upgraded to higher-priority source from %s.", soundID, sender)
                return
            end
            SB:Debug("Remote sound %s already queued, coalescing duplicate from %s.", soundID, sender)
            return
        end
    end

    local rateLimitKey = IdentityKey(sender) or sender

    -- The repeat-cooldown (lastReceivedFrom) and the rate-limit accept
    -- credit (RecordAccepted) are BOTH only ever claimed at the moment of
    -- genuine acceptance (immediate play, or a successful queue insertion
    -- below) - explicit requirement: a sound rejected for being over the
    -- rate limit (queue off) or for the queue being full must not burn
    -- either, or a legitimate retry moments later would incorrectly look
    -- like a duplicate/still-limited even though nothing of this sound
    -- ever actually got through the first time.
    local function MarkAccepted(now)
        lastReceivedFrom[duplicateKey] = now
        recentSource[duplicateKey] = {
            priority = SourcePriority(channel, isDirect),
            label = isDirect and "Direct" or (CHANNEL_LABEL[channel] or channel),
            at = now,
        }
        RecordAccepted(rateLimitKey, now)
    end

    if not SB.db.settings.soundQueueEnabled then
        -- Spooler OFF: rate-limited, but never delayed - anything over
        -- either limit is discarded outright and not retried later.
        local now = GetTime()
        local ok = CanAcceptNow(rateLimitKey, now)
        if not ok then
            SB:Debug("Remote sound %s from %s discarded (rate limit, queue off).", soundID, sender)
            return
        end
        MarkAccepted(now)
        HandlePlayCommand(soundID, sender, channel, isDirect)
        return
    end

    -- Spooler ON: FIFO-enqueue, unless already at capacity - a full queue
    -- discards the NEW arrival (oldest-first is already waiting its turn),
    -- never grows past QUEUE_MAX_SIZE. Deliberately does NOT stamp the
    -- cooldown/rate-limit here - queueing isn't "accepted" yet in the sense
    -- that matters (nothing has actually been claimed against the limits),
    -- only ProcessQueue's own successful dequeue does that, at the moment
    -- this entry's turn genuinely comes up.
    if #pendingQueue >= QUEUE_MAX_SIZE then
        SB:Debug("Remote sound queue full (%d), discarding %s from %s.", QUEUE_MAX_SIZE, soundID, sender)
        return
    end
    table.insert(pendingQueue, {
        soundID = soundID, sender = sender, channel = channel, isDirect = isDirect, rateLimitKey = rateLimitKey,
    })
    SB:Fire("REMOTE_QUEUE_CHANGED", #pendingQueue)
    if not queueTimer then
        ProcessQueue()
    end
end

------------------------------------------------------------------------
-- Raid Admin - lets the current Raid Leader/Assist or Party Leader
-- temporarily force sound-sending (and, for "mute all", receiving too) off
-- for the whole raid/party, for the length of a pull/instance, so a fight
-- isn't put at risk by someone spamming or getting distracted by sounds.
-- AdminPanel.lua is the UI (member list, mute-all + duration picker); this
-- section is the protocol, the authorization check, and the actual
-- session-only override state everything else (SoundPlayer.lua's
-- SB:TriggerSound, HandlePlayCommand above, SendMenu.lua's SB:SendSoundTo*)
-- checks before acting.
--
-- SB.raidOverride is DELIBERATELY plain in-memory Lua state, never written
-- to SavedVariables (SB.db) - explicit request: this must never survive
-- past the raid it was set for, and must always fall back to the player's
-- own normal settings on disconnect or any other technical hiccup. Since
-- it's never persisted, a disconnect/reload already guarantees that for
-- free (a fresh Lua state has no override at all) - the leave-group handler
-- further below only needs to cover the "still connected, but left/got
-- removed from the group" case, which a fresh state wouldn't catch.
------------------------------------------------------------------------

-- Whether *I* currently hold a qualifying role - gates whether AdminPanel.lua
-- shows its icon at all, and exempts me from someone else's "mute all"
-- (see HandleAdminMuteAll below).
function SB:IsRaidAdmin()
    if IsInRaid() then
        -- IsRaidLeader()/IsRaidOfficer() (old, no-argument globals) crashed
        -- here with "attempt to call a nil value" - confirmed live: one of
        -- them no longer exists on this client build. UnitIsGroupLeader/
        -- UnitIsGroupAssistant (unit-based) are the same stable API already
        -- used for the party case right below, and work identically for a
        -- raid unit.
        return (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) and true or false
    elseif IsInGroup() then
        return UnitIsGroupLeader("player") and true or false
    end
    return false
end

-- Whether *I* am specifically the CURRENT leader (not just an assistant) -
-- gates the client-side Mute All/Unmute All send (SB:SendAdminMuteAll/
-- SendAdminUnmuteAll below), same explicit "leader only" requirement the
-- receiving side (IsSenderCurrentLeader) already enforces - so an
-- assistant's click never even goes out looking like it might have
-- worked, only to be silently rejected by every receiver.
function SB:IsCurrentGroupLeader()
    if IsInRaid() then
        return UnitIsGroupLeader("player") and true or false
    elseif IsInGroup() then
        return UnitIsGroupLeader("player") and true or false
    end
    return false
end

-- Verifies `sender` currently holds a qualifying role in MY OWN raid/party
-- roster - never trusts a claim embedded in the message itself. Roster rank
-- data (GetRaidRosterInfo's rank, UnitIsGroupLeader) comes from the server
-- to every member alike, not from the sender, so an ordinary raid member
-- can't forge one of these commands by just claiming authority in the
-- payload - the receiver always checks its own independently-known roster.
local function IsSenderAuthorizedAdmin(sender)
    local senderKey = IdentityKey(sender)
    if not senderKey then return false end
    if IsInRaid() then
        for i = 1, SB.GetNumGroupMembers() do
            local rname, rank = GetRaidRosterInfo(i)
            if rname and IdentityKey(rname) == senderKey then
                return (rank or 0) >= 1 -- 1 = assistant, 2 = leader
            end
        end
        return false
    elseif IsInGroup() then
        for i = 1, SB.GetNumGroupMembers() - 1 do
            local unit = "party" .. i
            local unitName = SB.GetUnitFullName and SB.GetUnitFullName(unit) or UnitName(unit)
            if IdentityKey(unitName) == senderKey then
                return UnitIsGroupLeader(unit) and true or false
            end
        end
        return false
    end
    return false
end

-- Stricter than IsSenderAuthorizedAdmin above - the CURRENT leader
-- specifically (raid rank 2, or the party leader; an assistant does NOT
-- qualify) - explicit requirement: only the current leader may trigger
-- Mute All/Unmute All, and only the current leader (or the original source
-- of a restriction, see CanSenderModifyOverride below) may override or
-- lift another admin's already-active restriction. Same roster-based
-- spoof-resistance as IsSenderAuthorizedAdmin.
local function IsSenderCurrentLeader(sender)
    local senderKey = IdentityKey(sender)
    if not senderKey then return false end
    if IsInRaid() then
        for i = 1, SB.GetNumGroupMembers() do
            local rname, rank = GetRaidRosterInfo(i)
            if rname and IdentityKey(rname) == senderKey then
                return rank == 2
            end
        end
        return false
    elseif IsInGroup() then
        for i = 1, SB.GetNumGroupMembers() - 1 do
            local unit = "party" .. i
            local unitName = SB.GetUnitFullName and SB.GetUnitFullName(unit) or UnitName(unit)
            if IdentityKey(unitName) == senderKey then
                return UnitIsGroupLeader(unit) and true or false
            end
        end
        return false
    end
    return false
end

--- Whether `sender` is allowed to apply a NEW restriction or lift the
--- CURRENT one right now - explicit requirement: another already-active
--- admin's restriction must not be overridden/lifted by a lower-privilege
--- admin, only by the SAME source re-issuing/lifting their own, or by the
--- current leader (who can always override/lift anyone's). No active
--- override at all -> always allowed, nothing to conflict with.
local function CanSenderModifyOverride(sender)
    if not SB.raidOverride then return true end
    local senderKey = IdentityKey(sender)
    if senderKey and SB.raidOverride.sourceKey == senderKey then return true end
    return IsSenderCurrentLeader(sender)
end

function SB:IsSendBlockedByRaid()
    return SB.raidOverride ~= nil and (SB.raidOverride.mutedSend or SB.raidOverride.mutedAll)
end

function SB:IsReceiveBlockedByRaid()
    return SB.raidOverride ~= nil and SB.raidOverride.mutedAll
end

-- "R" (raid end, cleared only by leaving the group) has no timer at all.
-- "F" (Next Fight) and "B" (Next Boss) are event-cleared, not timed - two
-- DIFFERENT events, explicit request/distinction:
--   F - the next PLAYER_REGEN_ENABLED (leaving combat) - ANY fight, trash
--       included. "Kann ein wichtiger Kampf sein auch wenn es kein
--       Encounter ist" - a nasty trash pull matters too, not just bosses.
--   B - the next real ENCOUNTER_END specifically - a WoW client event that
--       only fires for a TRACKED BOSS encounter, never trash. This is what
--       "Next Fight" used to mean before this split.
-- Both are per-player-client local (each player waits for THEIR OWN next
-- combat-end/encounter-end, not a raid-wide synchronized signal), and both
-- also get this safety-net duration as a backstop: a player who never
-- actually enters combat/an encounter again (stays in town, is just
-- chatting, or the event simply doesn't fire for some reason) would
-- otherwise stay muted indefinitely, until they happen to leave the group.
-- Generous enough to cover any realistic single pull without ever
-- mattering in the normal case - a real fight (trash or boss) almost
-- always ends well before 90 minutes, so this only ever kicks in if the
-- real event genuinely never comes.
local NEXT_FIGHT_SAFETY_NET_SECONDS = 90 * 60

local function DurationSecondsFor(code)
    if code == "30" then return 30 * 60
    elseif code == "60" then return 60 * 60
    elseif code == "F" or code == "B" then return NEXT_FIGHT_SAFETY_NET_SECONDS
    end
    return nil
end
-- Exposed so AdminPanel.lua can compute the SAME expiry estimate for its own
-- live countdown tags, without a second hand-maintained copy of "30"/"60"
-- drifting out of sync with this one.
SB.DurationSecondsFor = DurationSecondsFor

local ADMIN_DURATION_LABEL = {
    F = "until this fight ends", B = "until the current boss encounter ends",
    ["30"] = "for 30 minutes", ["60"] = "for 60 minutes", R = "until the raid ends",
}
local VALID_ADMIN_DURATION = { F = true, B = true, ["30"] = true, ["60"] = true, R = true }

local raidOverrideTimer

--- Clears whatever raid-admin override is currently active, if any - a
--- no-op if there isn't one. `reason` only controls whether a chat line
--- announces it: "leave_group" stays silent (leaving the raid is already
--- obvious context on its own; the player doesn't need a second message
--- about it) - anything else (expiry, the admin lifting it early, an
--- encounter ending) prints a short "back to your own settings" line so a
--- muted player knows the moment it's over.
local function ClearRaidOverride(reason)
    if raidOverrideTimer then
        raidOverrideTimer:Cancel()
        raidOverrideTimer = nil
    end
    if not SB.raidOverride then return end
    SB.raidOverride = nil
    if reason ~= "leave_group" then
        SB:Print("|cff55ff88Your raid leader's Soundbook restriction has been lifted - back to your own settings.|r")
    end
    SB:Fire("RAID_OVERRIDE_CHANGED")
end

--- Applies a raid-admin override to THIS client - only ever called after
--- IsSenderAuthorizedAdmin already confirmed the sender qualifies.
--- `kind` is "send" (this player's own ADMINMUTE target) or "all"
--- (ADMINMUTEALL, everyone but the admins themselves). This only ever adds
--- restriction on top of the player's own settings, never loosens
--- anything - a personally-muted sound stays muted regardless.
local function ApplyRaidOverride(kind, durationCode, source)
    if not VALID_ADMIN_DURATION[durationCode] then return false end
    if raidOverrideTimer then
        raidOverrideTimer:Cancel()
        raidOverrideTimer = nil
    end

    local seconds = DurationSecondsFor(durationCode)
    SB.raidOverride = {
        mutedSend = true, -- both kinds block sending
        mutedAll = (kind == "all"),
        clearOnCombatEnd = (durationCode == "F"),     -- next PLAYER_REGEN_ENABLED - any fight, trash included
        clearOnEncounterEnd = (durationCode == "B"),  -- next real ENCOUNTER_END - tracked boss encounters only
        source = source,
        sourceKey = IdentityKey(source),
        durationCode = durationCode,
        -- Absolute GetTime() this expires at - set for 30/60 min AND, as a
        -- safety-net backstop only, for F/B too (see DurationSecondsFor's
        -- own comment) - "R" alone stays nil (no timer at all). UI code
        -- showing a LIVE COUNTDOWN from this (FavouritesWindow.lua,
        -- AdminPanel.lua) deliberately still only does so for 30/60 - F/B
        -- having a non-nil expiresAt here is for the backstop TIMER to
        -- fire, not meant to imply a countdown-worthy fixed duration.
        expiresAt = seconds and (GetTime() + seconds) or nil,
    }

    if seconds then
        raidOverrideTimer = C_Timer.NewTimer(seconds, function() ClearRaidOverride("expired") end)
    end

    local what = (kind == "all") and "Sending and receiving Soundbook sounds" or "Sending Soundbook sounds"
    local durationText = ADMIN_DURATION_LABEL[durationCode] or "for now"
    SB:Print(string.format("|cffff5555%s has been disabled by your raid leader (%s), %s.|r",
        what, SB.raidOverride.source, durationText))

    SB:Fire("RAID_OVERRIDE_CHANGED")
    return true
end

-- Sends a small confirmation reply for an admin command actually applied
-- on THIS client - explicit requirement: the sender must only ever show a
-- command as successful once the target's own client confirms it, never
-- just optimistically on send. `kind` matches what AdminPanel.lua expects
-- back (MUTE/UNMUTE/MUTEALL/UNMUTEALL/EXEMPT - EXEMPT covers the "you're a
-- leader, Mute All doesn't apply to you" case, still a real, confirmable
-- outcome, just not a restriction).
local function SendAdminAck(kind, toName)
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "ADMINACK" .. SEP .. kind, "WHISPER", toName)
end

local function HandleAdminMute(payload, sender)
    if not VALID_ADMIN_DURATION[payload] then return end
    if not IsSenderAuthorizedAdmin(sender) then
        SB:Debug("Ignoring ADMINMUTE from %s - not a raid/party leader or assist.", sender)
        return
    end
    -- Explicit requirement: a lower-privilege admin must not be able to
    -- override another admin's already-active restriction - only the
    -- original source re-issuing it, or the current leader, may.
    if not CanSenderModifyOverride(sender) then
        SB:Debug("Ignoring ADMINMUTE from %s - a stronger restriction from %s is already active.",
            sender, SB.raidOverride and SB.raidOverride.source or "?")
        return
    end
    ApplyRaidOverride("send", payload, sender)
    SendAdminAck("MUTE", sender)
end

local function HandleAdminUnmute(sender)
    if not IsSenderAuthorizedAdmin(sender) then return end
    -- Explicit requirement: a targeted unmute must not weaken an already-
    -- active MUTE ALL unless it comes from that restriction's own source or
    -- the current leader - an ordinary assistant's individual unmute (aimed
    -- at what might have been an EARLIER, individual mute) must never
    -- accidentally lift someone out of a stronger raid-wide restriction.
    if not CanSenderModifyOverride(sender) then
        SB:Debug("Ignoring ADMINUNMUTE from %s - can't lift %s's active restriction.",
            sender, SB.raidOverride and SB.raidOverride.source or "?")
        return
    end
    ClearRaidOverride("admin")
    SendAdminAck("UNMUTE", sender)
end

local function HandleAdminMuteAll(payload, sender)
    if not VALID_ADMIN_DURATION[payload] then return end
    -- Explicit requirement: ONLY the current leader may trigger Mute All -
    -- an assistant no longer qualifies here (still fully able to send
    -- targeted, individual mutes above).
    if not IsSenderCurrentLeader(sender) then
        SB:Debug("Ignoring ADMINMUTEALL from %s - not the current raid/party leader.", sender)
        return
    end
    if SB:IsRaidAdmin() then
        -- Raid Lead/Assist/Party Lead are exempt from "mute all" - explicit
        -- request. An individually-targeted ADMINMUTE can still reach them
        -- (HandleAdminMute above never checks this), just never a blanket
        -- mute-all. Still gets the SAME notification everyone else does
        -- (explicit request: "der Admin ... kriegt auch dieselbe
        -- Nachrichten") - just phrased as informational (exempt) rather
        -- than restrictive, since nothing is actually applied to them.
        SB:Print(string.format(
            "|cffaaaaaaMute All is now active raid-wide (%s), started by %s - you're exempt as Raid Lead/Assist/Party Lead.|r",
            ADMIN_DURATION_LABEL[payload] or "for now", NormalizeName(sender) or sender))
        SendAdminAck("EXEMPT", sender)
        return
    end
    ApplyRaidOverride("all", payload, sender)
    SendAdminAck("MUTEALL", sender)
end

local function HandleAdminUnmuteAll(sender)
    if not IsSenderCurrentLeader(sender) then return end
    ClearRaidOverride("admin")
    SendAdminAck("UNMUTEALL", sender)
end

local function AdminBroadcastChannel()
    if IsInRaid() then return "RAID" elseif IsInGroup() then return "PARTY" end
    return nil
end

-- Sending side - called from AdminPanel.lua. Each also checks
-- SB:IsRaidAdmin() itself (belt-and-suspenders; AdminPanel.lua's own icon
-- is already hidden for non-admins) - the REAL enforcement is always the
-- receiver's own roster-based IsSenderAuthorizedAdmin check above, never
-- this side.
function SB:SendAdminMute(targetName, durationCode)
    if not SB:IsRaidAdmin() or not targetName or targetName == "" then return end
    durationCode = durationCode or "F"
    if not VALID_ADMIN_DURATION[durationCode] then return end
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "ADMINMUTE" .. SEP .. durationCode, "WHISPER", targetName)
end

function SB:SendAdminUnmute(targetName)
    if not SB:IsRaidAdmin() or not targetName or targetName == "" then return end
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "ADMINUNMUTE" .. SEP, "WHISPER", targetName)
end

function SB:SendAdminMuteAll(durationCode)
    -- Explicit requirement: ONLY the current leader, not an assistant -
    -- matches HandleAdminMuteAll's own receiver-side check exactly, so an
    -- assistant's click never goes out looking like it might work only to
    -- be silently rejected by everyone who gets it.
    if not SB:IsCurrentGroupLeader() then return end
    local channel = AdminBroadcastChannel()
    if not channel then return end
    durationCode = durationCode or "F"
    if not VALID_ADMIN_DURATION[durationCode] then return end
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "ADMINMUTEALL" .. SEP .. durationCode, channel)
end

function SB:SendAdminUnmuteAll()
    if not SB:IsCurrentGroupLeader() then return end
    local channel = AdminBroadcastChannel()
    if not channel then return end
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "ADMINUNMUTEALL" .. SEP, channel)
end

-- "Next Boss" duration - clears itself the moment the tracked boss
-- encounter it was set for actually ends (Core.lua fires this on
-- ENCOUNTER_END). Trash combat never fires this - see "Next Fight" below
-- for that.
SB:On("ENCOUNTER_END", function()
    if SB.raidOverride and SB.raidOverride.clearOnEncounterEnd then
        ClearRaidOverride("encounter_end")
    end
end)

-- "Next Fight" duration - clears itself the moment ANY combat ends (Core.lua
-- fires this on PLAYER_REGEN_ENABLED), trash included - explicit request:
-- a rough trash pull can matter just as much as a tracked boss encounter.
SB:On("COMBAT_END", function()
    if SB.raidOverride and SB.raidOverride.clearOnCombatEnd then
        ClearRaidOverride("combat_end")
    end
end)

-- Guarantees the override never outlives the raid/party it was set for, per
-- the explicit "reset to default when leaving the raid" requirement - the
-- disconnect/reload case is already covered for free (see this section's
-- own opening comment); this specifically catches "still connected, but
-- left or got removed from the group".
local wasInGroup = false
local groupCheckFrame = CreateFrame("Frame")
groupCheckFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
groupCheckFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
groupCheckFrame:SetScript("OnEvent", function()
    local inGroup = IsInGroup() and true or false
    if wasInGroup and not inGroup then
        ClearRaidOverride("leave_group")
    end

    -- Explicit requirement: a restriction's SOURCE losing their required
    -- role (demoted, leadership passed to someone else) must clear it too,
    -- not just the source physically leaving the group entirely. Checked
    -- against MY OWN current roster, same spoof-resistant source of truth
    -- as every other admin check here. mutedAll requires the source to
    -- still be the current LEADER specifically (only the leader can hold
    -- one, per the same rule SendAdminMuteAll/HandleAdminMuteAll enforce);
    -- a plain mutedSend-only override only needs the source to still be
    -- assistant-or-leader.
    if inGroup and SB.raidOverride then
        -- Plain if/else, deliberately NOT the "cond and a or b" idiom - that
        -- breaks the moment `a` (IsSenderCurrentLeader's result) can itself
        -- be false, which is exactly the case that matters here.
        local stillQualifies
        if SB.raidOverride.mutedAll then
            stillQualifies = IsSenderCurrentLeader(SB.raidOverride.source)
        else
            stillQualifies = IsSenderAuthorizedAdmin(SB.raidOverride.source)
        end
        if not stillQualifies then
            ClearRaidOverride("source_lost_role")
        end
    end
    wasInGroup = inGroup
end)

local COMMAND_CHANNELS = {
    PLAY = { PARTY = true, RAID = true, RAID_LEADER = true, GUILD = true, OFFICER = true, WHISPER = true },
    ACK = { WHISPER = true }, MUTEACK = { WHISPER = true }, RXOFFACK = { WHISPER = true },
    HELLO = { PARTY = true, RAID = true, RAID_LEADER = true, GUILD = true, OFFICER = true, WHISPER = true },
    HELLOACK = { WHISPER = true },
    ANLY = { PARTY = true, RAID = true, RAID_LEADER = true, GUILD = true, OFFICER = true },
    ADMINMUTE = { WHISPER = true }, ADMINUNMUTE = { WHISPER = true }, ADMINACK = { WHISPER = true },
    ADMINMUTEALL = { PARTY = true, RAID = true, RAID_LEADER = true },
    ADMINUNMUTEALL = { PARTY = true, RAID = true, RAID_LEADER = true },
}
local VALID_ADMIN_ACK = { MUTE = true, UNMUTE = true, MUTEALL = true, UNMUTEALL = true, EXEMPT = true }

-- Cheap first-line packet limiter for every command, including presence,
-- receipts, analytics, unknown future commands, and invalid protocol
-- versions. PLAY has a second, stricter semantic limiter below.
local INBOUND_PACKET_CAPACITY = 24
local INBOUND_PACKET_REFILL = 12
local INBOUND_BUCKET_TTL = 120
local inboundBuckets = {}
local inboundLastPrune = 0

local function AcceptInboundPacket(sender)
    local senderKey = IdentityKey(sender)
    if not senderKey then return false end
    local now = GetTime()
    if now - inboundLastPrune > 30 then
        for key, bucket in pairs(inboundBuckets) do
            if now - bucket.lastSeen > INBOUND_BUCKET_TTL then inboundBuckets[key] = nil end
        end
        inboundLastPrune = now
    end
    local bucket = inboundBuckets[senderKey]
    if not bucket then
        bucket = { tokens = INBOUND_PACKET_CAPACITY, updatedAt = now, lastSeen = now }
        inboundBuckets[senderKey] = bucket
    end
    bucket.tokens = math.min(INBOUND_PACKET_CAPACITY,
        bucket.tokens + math.max(0, now - bucket.updatedAt) * INBOUND_PACKET_REFILL)
    bucket.updatedAt, bucket.lastSeen = now, now
    if bucket.tokens < 1 then return false end
    bucket.tokens = bucket.tokens - 1
    return true
end

local function OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= SB.COMM_PREFIX then return end
    if IsSelf(sender) then return end -- never echo our own broadcast

    if not SB.IsValidPlayerTarget(sender) or type(message) ~= "string" or #message == 0 or #message > 255 then return end
    if message:find("[%z\1-\31\127]") or not AcceptInboundPacket(sender) then return end

    local version, cmd, payload = message:match("^([^|]+)|([^|]+)|(.*)$")
    if not version or not cmd then return end
    -- Checked against every version this client still UNDERSTANDS, not a
    -- strict match to the one it currently SENDS with - see
    -- SB.SUPPORTED_PROTOCOL_VERSIONS' own comment in Core.lua. A sender on
    -- an older (but still-listed) Soundbook version is accepted completely
    -- normally; only a version this client has never been taught at all is
    -- rejected here.
    if not SB.SUPPORTED_PROTOCOL_VERSIONS[version] then
        SB:Debug("Ignoring addon message with unrecognized protocol version: %s", tostring(version))
        return
    end

    local allowedChannels = COMMAND_CHANNELS[cmd]
    if allowedChannels and not allowedChannels[channel] then
        SB:Debug("Ignoring %s on invalid channel %s.", tostring(cmd), tostring(channel))
        return
    end

    -- Any recognized message at all proves the sender has Soundbook - record
    -- it before dispatching, so every command below (including a PLAY we end
    -- up not playing, e.g. a disabled "Receive Sounds from" channel) counts
    -- toward SendMenu.lua's "who has this addon" list the same way.
    SB:NoteKnownUser(sender)

    if cmd == "PLAY" then
        if type(payload) ~= "string" or payload == "" or #payload > 200 then return end

        -- Parsed BEFORE the channel filter now (used to be after) - the
        -- filter needs to know isDirect to tell a Direct send apart from a
        -- plain Friends-list broadcast (both travel as WHISPER, see
        -- ReceiveAllowedForChannel above).
        local plainID, isDirect = ParsePlayPayload(payload)
        if not SB.IsValidSoundID(plainID) then return end
        -- A direct flag is meaningful only on a real whisper. Never let an
        -- arbitrary raid/guild packet claim the friend/direct exemptions.
        isDirect = isDirect and channel == "WHISPER"

        -- Channel filter - explicit request: a disabled "Receive Sounds
        -- from" channel (Direct included) must still produce literally
        -- nothing on THIS (the recipient's) side - no playback, no queue
        -- entry, no notification, no chat line, no UI reaction at all. Only
        -- Debug Mode may ever surface that something was dropped here. This
        -- is deliberately different from a per-sound mute (HandlePlayCommand's
        -- own notifyMutedAttempts branch further down), which still may
        -- notify locally - turning off a whole channel is a much stronger
        -- "I don't want to know about this at all" than muting one sound.
        --
        -- The SENDER's side gets a reply too now (explicit request), but
        -- deliberately NOT the same MUTEACK the mute paths use - this isn't
        -- a mute, it's a channel-level opt-out, a different thing, so it
        -- gets its own "RXOFFACK" reply, its own aggregated count, its own
        -- colour, and its own visibility rule (see HandleRxOffAck - shown
        -- to the sender only in Debug Mode; a normal sender sees nothing
        -- here at all, same as before this feature existed).
        if not ReceiveAllowedForChannel(channel, isDirect) then
            SB:Debug("Remote PLAY from %s on disabled channel %s ignored.", sender, tostring(channel))
            SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "RXOFFACK" .. SEP .. plainID, "WHISPER", sender)
            return
        end

        HandleIncomingPlay(plainID, sender, channel, isDirect)
    elseif cmd == "ACK" then
        if type(payload) == "string" and payload ~= "" then
            local ackSoundID, ackCode = ParseAckPayload(payload)
            if ackSoundID and SB.IsValidSoundID(ackSoundID) then
                HandleAck(ackSoundID, ackCode, sender)
            end
        end
    elseif cmd == "ANLY" then
        -- Anonymous analytics record - see Analytics.lua for the full
        -- decode/validate/dedup logic. Wrapped in a plain existence check
        -- (not pcall - AnalyticsHandleIncoming already pcalls its own
        -- body) so an older client without Analytics.lua loaded, or
        -- analytics disabled, just silently ignores this like any other
        -- unrecognized-to-it command would.
        if SB.AnalyticsHandleIncoming and type(payload) == "string" then
            SB:AnalyticsHandleIncoming(payload)
        end
    elseif cmd == "MUTEACK" then
        -- Just "soundID" - no channel code needed, only a count is ever
        -- shown (see HandleMuteAck). Additive/backward-compatible: an
        -- older client that never sends this simply never gets counted,
        -- and this client's own OnAddonMessage safely ignores unknown
        -- commands from an older sender either way.
        if SB.IsValidSoundID(payload) then
            HandleMuteAck(payload, sender)
        end
    elseif cmd == "RXOFFACK" then
        -- Same wire shape as MUTEACK ("soundID" only), but a distinct
        -- command - a disabled receive channel, not an actual mute (see
        -- HandleRxOffAck). Additive/backward-compatible the same way.
        if SB.IsValidSoundID(payload) then
            HandleRxOffAck(payload, sender)
        end
    elseif cmd == "HELLO" then
        -- Lightweight presence ping (see SendHello below) - reply right
        -- away so a fresh login (ours or theirs) is discovered immediately
        -- instead of waiting for the next periodic ping. SB:NoteKnownUser
        -- was already called above (no version yet); this second call adds
        -- the sender's version from the payload, additive/backward-
        -- compatible - an older client's empty/absent payload here just
        -- means `version` comes through as "" or nil, harmless.
        if payload and payload ~= "" and #payload <= 80 and not payload:find("|", 1, true) then
            SB:NoteKnownUser(sender, payload)
        end
        SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "HELLOACK" .. SEP .. (SB.VERSION or "?"), "WHISPER", sender)
    elseif cmd == "HELLOACK" then
        if payload and payload ~= "" and #payload <= 80 and not payload:find("|", 1, true) then
            SB:NoteKnownUser(sender, payload)
        end
    elseif cmd == "ADMINMUTE" then
        -- Targeted "mute my sending" from a raid/party leader or assist -
        -- see the Raid Admin section below for the full mechanism.
        HandleAdminMute(payload, sender)
    elseif cmd == "ADMINUNMUTE" then
        HandleAdminUnmute(sender)
    elseif cmd == "ADMINMUTEALL" then
        HandleAdminMuteAll(payload, sender)
    elseif cmd == "ADMINUNMUTEALL" then
        HandleAdminUnmuteAll(sender)
    elseif cmd == "ADMINACK" then
        -- Confirmation that an admin command sent BY ME actually applied on
        -- the target's client (see SendAdminAck above) - explicit
        -- requirement: AdminPanel.lua only shows a command as successful
        -- once this arrives, never just optimistically on send. `payload`
        -- is one of MUTE/UNMUTE/MUTEALL/UNMUTEALL/EXEMPT.
        if VALID_ADMIN_ACK[payload] then
            SB:Fire("ADMIN_ACK_RECEIVED", NormalizeName(sender) or sender, payload)
        end
    else
        -- Unknown/future command: ignore silently, never execute arbitrary content.
        SB:Debug("Ignoring unknown addon command '%s' from %s", tostring(cmd), tostring(sender))
    end
end

local commFrame = CreateFrame("Frame")
commFrame:RegisterEvent("CHAT_MSG_ADDON")
commFrame:SetScript("OnEvent", function(_, event, prefix, message, channel, sender)
    if event == "CHAT_MSG_ADDON" then
        local ok, err = pcall(OnAddonMessage, prefix, message, channel, sender)
        if not ok then
            SB:Debug("Communication error: %s", tostring(err))
        end
    end
end)

SB:On("PLAYER_LOGIN", function()
    SB.RegisterAddonPrefix(SB.COMM_PREFIX)
end)

------------------------------------------------------------------------
-- Presence ("who has Soundbook") - powers SendMenu.lua's right-click "send
-- to" list, which needs actual names, not just raw channels. A plain addon
-- message, same as PLAY/ACK - invisible to chat, nothing ever announced
-- anywhere visible. Deliberately independent of both the "Broadcast sounds
-- to" and "Receive Sounds from" settings: those are about sound-spam
-- preference, not about whether you can see who's around to send directly
-- to - muting Guild sound broadcasts, say, shouldn't also hide guildmates
-- from the send menu.
------------------------------------------------------------------------

-- Records/refreshes that `sender` has Soundbook - called for every
-- recognized inbound addon message (see OnAddonMessage above), since
-- receiving any of them already proves it. `version` (optional - only
-- HELLO/HELLOACK actually carry one, see SendHello/OnAddonMessage below)
-- updates the remembered addon version for this player; omitted, it just
-- refreshes lastSeen and leaves whatever version was already on file
-- alone, rather than clobbering it with nil.
function SB:NoteKnownUser(sender, version)
    local key = IdentityKey(sender)
    if not key or not SB.db then return end
    local existing = SB.db.knownUsers[key] or SB.db.knownUsers[NormalizeName(sender)]
    SB.db.knownUsers[key] = {
        lastSeen = time(),
        version = version or (existing and existing.version) or nil,
        playerName = sender,
    }
end

-- How long a presence entry is trusted without a fresh HELLO/HELLOACK (or
-- any other recognized message) before it's pruned outright - explicit
-- requirement: someone who went offline or hasn't been seen in a long time
-- must not keep appearing as reachable forever. Comfortably longer than the
-- periodic HELLO ping interval (180s, see HELLO_INTERVAL further below - 3x
-- that) so a couple of missed periodic pings in a row (e.g. a brief
-- disconnect) doesn't drop someone who's still actually around.
local KNOWN_USER_TTL_SECONDS = 540

--- Drops any SB.db.knownUsers entry not refreshed within
--- KNOWN_USER_TTL_SECONDS - called before every consumer (SendMenu.lua's
--- right-click list, the Default Output Channel / Macro Output dropdowns)
--- builds its own reachable-players list, so a stale entry never shows up
--- as an available send target.
function SB:PruneStaleKnownUsers()
    if not (SB.db and SB.db.knownUsers) then return end
    local cutoff = time() - KNOWN_USER_TTL_SECONDS
    for name, info in pairs(SB.db.knownUsers) do
        if type(info) ~= "table" or not info.lastSeen or info.lastSeen < cutoff then
            SB.db.knownUsers[name] = nil
        end
    end
end

--- "v1.9.1"/"v?" to show next to `name` in a reachable-players list
--- (SendMenu.lua's popup, the Default Output Channel / Macro Output
--- dropdowns), or nil to show nothing at all - only while Settings ->
--- Debug Mode is on. Shown for EVERY known player, not just ones on a
--- different version - a SECOND return value, `isCurrent`, tells the
--- caller whether to colour the version suffix green (same major.minor
--- as this client's own version - the patch number doesn't count, see
--- MajorMinor below) or orange (different major.minor, or unknown). A
--- caller that only reads the first return value (text) still works
--- unchanged.
-- "2.4.2"/"2.4.1"/"2.0.0-final7" -> "2.4"/"2.4"/"2.0" - only major.minor,
-- ignoring the patch number entirely (and anything after it, like a
-- "-final7" suffix) - explicit request: the patch number alone was never
-- meant to count as "incompatible", only a genuinely different
-- major.minor line is. nil for anything that doesn't even start with
-- digits (a malformed/unknown version).
local function MajorMinor(version)
    if type(version) ~= "string" then return nil end
    local major, minor = version:match("^(%d+)%.(%d+)")
    if not major then return nil end
    return major .. "." .. minor
end

function SB:GetFormattedPlayerVersion(name)
    if not (SB.db and SB.db.settings and SB.db.settings.debug) then return nil end
    local info = KnownUserInfo(name)
    local theirVersion = info and info.version
    local theirMajorMinor = MajorMinor(theirVersion)
    local myMajorMinor = MajorMinor(SB.VERSION)
    local isCurrent = theirMajorMinor ~= nil and theirMajorMinor == myMajorMinor
    return "v" .. (theirVersion or "?"), isCurrent
end

local function SendHello()
    if not SB.db then return end
    -- Own version appended to the payload - purely additive (an old 1.9.0
    -- client's HELLO handler never looked at the payload at all, so this
    -- changes nothing for it) - lets everyone else's Settings -> Debug Mode
    -- show it (see SendMenu.lua/Communication.lua's
    -- SB.ComputeOutputTargetOptions) without needing a whole new command.
    local text = SB.PROTOCOL_VERSION .. SEP .. "HELLO" .. SEP .. (SB.VERSION or "?")
    if IsInGuild() then
        SB.SendAddonMessage(SB.COMM_PREFIX, text, "GUILD")
    end
    if IsInRaid() then
        SB.SendAddonMessage(SB.COMM_PREFIX, text, "RAID")
    elseif IsInGroup() then
        SB.SendAddonMessage(SB.COMM_PREFIX, text, "PARTY")
    end
    SendToFriends(text, {})
end

local HELLO_INTERVAL = 180 -- seconds between background presence pings

SB:On("PLAYER_LOGIN", function()
    -- Short delay - guild/group roster info isn't always populated the
    -- instant PLAYER_LOGIN fires.
    C_Timer.After(5, SendHello)
    C_Timer.NewTicker(HELLO_INTERVAL, SendHello)
end)

-- A remote sound actually played for you - the base "did I miss
-- something" notification.
--
-- Explicit bugfix: a single broadcast reaching us over SEVERAL enabled
-- channels at once (e.g. the sender has both Raid AND Guild broadcast
-- checked, and we're in both groups with them) used to print one
-- "[Soundbook] Sender (Channel): Sound" chat line PER channel it arrived
-- on. HandleIncomingPlay above already recognizes these as the same
-- broadcast (see its duplicate/priority-upgrade handling, SourcePriority -
-- Direct > Friends > Guild > Raid > Party) and re-fires REMOTE_SOUND_PLAYED
-- with the better label whenever a higher-priority copy arrives - that
-- upgrade is meant for the OTHER listeners on this same event (History,
-- the Announcement Bar, the playing-state highlight further up in this
-- file/UI.lua), which all still want the best/final label as soon as it's
-- known. The chat line itself, though, should only ever print once per
-- broadcast - "eine Nachricht reicht gemäß der bekannten Priorität".
--
-- Debounced by exactly SB.db.settings.remoteCooldown - the SAME window
-- IsRecentDuplicate (above) uses to decide what counts as "the same
-- broadcast" in the first place - so by the time this actually prints, it
-- is guaranteed to already reflect the best channel any copy could still
-- arrive on, never printing a lower-priority label only to have to correct
-- it a moment later. Only ever delays the CHAT LINE, not the sound itself
-- (already played instantly, unaffected) or any of this event's other
-- listeners.
local pendingPrintTimers = {} -- [normalizedSender|soundID] = timer handle
SB:On("REMOTE_SOUND_PLAYED", function(soundID, sender, channelLabel, senderKey)
    if not SB.db.settings.notifyOnMuted then return end
    local key = (senderKey or IdentityKey(sender) or sender or "?") .. "|" .. soundID
    if pendingPrintTimers[key] then return end -- already scheduled - will pick up the best label once it fires
    local cooldown = tonumber(SB.db.settings.remoteCooldown) or 1.0
    pendingPrintTimers[key] = C_Timer.NewTimer(cooldown, function()
        pendingPrintTimers[key] = nil
        local best = recentSource[key]
        PrintReceived(sender, (best and best.label) or channelLabel, SB:GetSoundDisplayName(soundID))
    end)
end)

------------------------------------------------------------------------
-- Receive Mute All - Settings page, the 3 buttons under the Send/Receive
-- table. Zeroes out all four receiveX flags (temporarily or indefinitely),
-- remembering their prior state in SB.db.settings.receiveMute.previous so
-- Unmute/expiry restores it exactly rather than just blindly re-checking
-- all four. Deliberately PERSISTED (SavedVariables) and uses time(), not
-- GetTime() - see SB:NoteKnownUser's own lastSeen above for the same
-- reasoning: GetTime() resets on a full client restart (though not a
-- /reload), so a value computed from it stops meaning anything comparable
-- after one, while time() (real epoch seconds) still means exactly the
-- same duration either way. Unlike the completely separate Raid Admin mute
-- (SB.raidOverride above - never persisted, reset by leaving group) there
-- is no natural "leave" event to clear this one, so persisting it is the
-- only way a real 30/60 minute mute survives a reload/restart partway
-- through instead of silently being undone by it.
------------------------------------------------------------------------

local receiveMuteTimer

local function StopReceiveMuteTimer()
    if receiveMuteTimer then
        receiveMuteTimer:Cancel()
        receiveMuteTimer = nil
    end
end

-- Actually flips the four receive flags to muted/restores `previous`, then
-- tells Settings.lua's UI to resync (matrix tiles + the 3 buttons' own
-- labels) - fired regardless of what triggered the change (a click, a
-- timer firing, or the DB_READY resolve-on-load check below).
local function ApplyReceiveMuteState()
    local m = SB.db.settings.receiveMute
    if m.active then
        SB.db.settings.receiveFriends = false
        SB.db.settings.receiveRaid = false
        SB.db.settings.receiveGuild = false
        SB.db.settings.receiveDirect = false
        -- Explicit requirement: engaging a receive-mute must reliably drop
        -- whatever's still waiting in the incoming queue too, not just stop
        -- NEW sounds from being accepted - a queued sound that arrived
        -- moments before the mute would otherwise still play once its turn
        -- came up, defeating the point of muting right now.
        if SB.ClearPendingQueue then SB:ClearPendingQueue() end
    else
        local prev = m.previous or {}
        SB.db.settings.receiveFriends = prev.FRIENDS ~= false
        SB.db.settings.receiveRaid = prev.RAID ~= false
        SB.db.settings.receiveGuild = prev.GUILD ~= false
        SB.db.settings.receiveDirect = prev.DIRECT ~= false
    end
    SB:Fire("RECEIVE_MUTE_CHANGED")
end

--- Starts (or changes the duration of) a receive-mute. `durationSeconds`
--- nil = indefinite (the plain Mute button); a number schedules a one-shot
--- auto-unmute after that long, with `durationMinutes` recorded purely so
--- Settings.lua's UI knows WHICH of the two duration buttons to show a live
--- countdown on. Only snapshots the current receiveX flags into `previous`
--- when transitioning from unmuted -> muted - re-clicking a duration button
--- (or the other one) while already muted must never overwrite `previous`
--- with the CURRENTLY-muted "all off" state, or the real original state
--- would be lost for good.
function SB:StartReceiveMute(durationSeconds, durationMinutes)
    local m = SB.db.settings.receiveMute
    if not m.active then
        m.previous = {
            FRIENDS = SB.db.settings.receiveFriends,
            RAID = SB.db.settings.receiveRaid,
            GUILD = SB.db.settings.receiveGuild,
            DIRECT = SB.db.settings.receiveDirect,
        }
    end
    m.active = true
    m.expiresAt = durationSeconds and (time() + durationSeconds) or nil
    m.durationMinutes = durationMinutes
    ApplyReceiveMuteState()

    StopReceiveMuteTimer()
    if durationSeconds then
        receiveMuteTimer = C_Timer.NewTimer(durationSeconds, function()
            receiveMuteTimer = nil
            SB:StopReceiveMute()
        end)
    end
end

--- Ends a receive-mute right now, whether that's an early manual Unmute
--- click or a timer's own natural expiry - restores `previous` exactly.
function SB:StopReceiveMute()
    StopReceiveMuteTimer()
    local m = SB.db.settings.receiveMute
    m.active = false
    m.expiresAt = nil
    m.durationMinutes = nil
    ApplyReceiveMuteState()
end

function SB:IsReceiveMuted()
    return SB.db.settings.receiveMute and SB.db.settings.receiveMute.active or false
end

--- Seconds remaining on a TIMED mute, or nil (indefinite mute, or not
--- muted at all) - Settings.lua's own display-only ticker polls this while
--- its panel is visible to render "MM:SS left" on the active duration
--- button; the actual unmute is always driven by the real timer above; this
--- never controls it.
function SB:GetReceiveMuteRemaining()
    local m = SB.db.settings.receiveMute
    if not (m and m.active and m.expiresAt) then return nil end
    return math.max(0, m.expiresAt - time())
end

--- Which duration button (30/60), if any, is the one currently counting
--- down - nil for an indefinite mute or no mute at all.
function SB:GetReceiveMuteDurationMinutes()
    local m = SB.db.settings.receiveMute
    return m and m.active and m.durationMinutes or nil
end

------------------------------------------------------------------------
-- Individual Mute - Mini Soundbook mute button's right-click dropdown
-- (see FavouritesWindow.lua's MutePlayers panel). Separate from the
-- global receive-mute above (blocks EVERYONE) and from a per-sound mute
-- (blocks one SOUND from everyone) - this blocks one specific PERSON's
-- sounds, all of them, only from them.
------------------------------------------------------------------------

local PLAYER_MUTE_SECONDS = 60 * 60 -- one left-click's worth (explicit request: 60 minutes)
local PLAYER_MUTE_MAX_SECONDS = 600 * 60 -- explicit request: hard cap, 600 minutes (10h) total

--- True (and cleans up the entry) if `name` is currently muted and that
--- mute hasn't expired yet. `time()`, not GetTime(), matching
--- receiveMute's own expiresAt above - must survive a /reload.
function SB:IsPlayerMuted(name)
    local key = IdentityKey(name)
    if not key then return false end
    local muted = SB.db.settings.mutedPlayers
    local legacyKey = type(name) == "string" and not name:find("-", 1, true) and NormalizeName(name) or nil
    local expiresAt = muted and (muted[key] or (legacyKey and muted[legacyKey]))
    if not expiresAt then return false end
    if expiresAt <= time() then
        muted[key] = nil
        if legacyKey then muted[legacyKey] = nil end
        return false
    end
    return true
end

--- Seconds remaining, or nil if not currently muted - used by the mute
--- panel's own per-row countdown display.
function SB:GetPlayerMuteRemaining(name)
    if not SB:IsPlayerMuted(name) then return nil end
    local key = IdentityKey(name)
    local legacyKey = type(name) == "string" and not name:find("-", 1, true) and NormalizeName(name) or nil
    local expiresAt = SB.db.settings.mutedPlayers[key] or (legacyKey and SB.db.settings.mutedPlayers[legacyKey])
    return expiresAt and math.max(0, expiresAt - time()) or nil
end

--- One left-click's worth - explicit request: STACKS on top of whatever
--- time is already left (not reset to a flat 60 minutes), so repeated
--- clicks add up rather than each one just re-setting the same duration.
function SB:MutePlayerFor(name, seconds)
    local key = IdentityKey(name)
    if not key then return end
    seconds = seconds or PLAYER_MUTE_SECONDS
    local muted = SB.db.settings.mutedPlayers
    local now = time()
    local legacyKey = type(name) == "string" and not name:find("-", 1, true) and NormalizeName(name) or nil
    local existing = muted[key] or (legacyKey and muted[legacyKey])
    local base = (existing and existing > now) and existing or now
    -- Explicit request: hard cap at 600 minutes total, even if the player
    -- already had most of that stacked up from earlier clicks - clamps
    -- the RESULT, not each individual click, so one click that would push
    -- past the cap just tops out there instead of being silently ignored.
    muted[key] = math.min(base + seconds, now + PLAYER_MUTE_MAX_SECONDS)
    if legacyKey and legacyKey ~= key then muted[legacyKey] = nil end
    SB:Fire("PLAYER_MUTE_CHANGED", key)
end

--- Right-click on a person in the mute panel - clears their timer/mute
--- entirely, immediately (not just letting it run out).
function SB:UnmutePlayer(name)
    local key = IdentityKey(name)
    if not key then return end
    local legacyKey = type(name) == "string" and not name:find("-", 1, true) and NormalizeName(name) or nil
    if SB.db.settings.mutedPlayers[key] or (legacyKey and SB.db.settings.mutedPlayers[legacyKey]) then
        SB.db.settings.mutedPlayers[key] = nil
        if legacyKey then SB.db.settings.mutedPlayers[legacyKey] = nil end
        SB:Fire("PLAYER_MUTE_CHANGED", key)
    end
end

--- The mute panel's own "Unmute All" row - clears every individual mute
--- and its timer at once.
function SB:UnmuteAllPlayers()
    SB.db.settings.mutedPlayers = {}
    SB:Fire("PLAYER_MUTE_CHANGED", nil)
end

-- Resolve-on-load: a timed mute's real unmute is driven by a plain Lua
-- timer (receiveMuteTimer above), which does NOT survive a /reload or
-- client restart - without this, reloading mid-mute would leave the four
-- receiveX flags stuck at "all off" forever, quietly outliving whatever
-- duration was actually picked. If the stored expiry already passed while
-- offline, restore immediately; if there's still time left, resume a fresh
-- one-shot timer for exactly the remainder. An indefinite mute (expiresAt
-- nil) just carries over untouched either way - surviving a reload/restart
-- is the entire point of persisting it.
SB:On("DB_READY", function()
    local m = SB.db.settings.receiveMute
    if not (m and m.active) then return end
    if not m.expiresAt then return end
    local remaining = m.expiresAt - time()
    if remaining <= 0 then
        SB:StopReceiveMute()
    else
        receiveMuteTimer = C_Timer.NewTimer(remaining, function()
            receiveMuteTimer = nil
            SB:StopReceiveMute()
        end)
        -- Still active, just resuming - StartReceiveMute isn't called here
        -- (that would re-snapshot `previous` from the current, already-
        -- muted state), so fire this explicitly: anything already listening
        -- (Settings.lua, FavouritesWindow.lua's title) needs to know the
        -- mute carried over from before this reload/restart.
        SB:Fire("RECEIVE_MUTE_CHANGED")
    end
end)
