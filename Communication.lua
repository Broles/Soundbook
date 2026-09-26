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
-- Exported: one shared lookup, so callers never duplicate this realm-aware
-- key logic with a plain-name lookup that could miss the current key shape.
SB.KnownUserInfo = KnownUserInfo

local function IsSelf(sender)
    if type(sender) ~= "string" or sender == "" then return false end

    local meFull = SB.GetUnitFullName and SB.GetUnitFullName("player") or UnitName("player")
    local meName = UnitName and UnitName("player") or meFull

    -- Primary path: realm-aware canonical identity.
    local senderKey = IdentityKey(sender)
    local meKey = IdentityKey(meFull or meName)
    if senderKey and meKey and senderKey == meKey then return true end

    -- Some supported clients/APIs hand roster/addon names back in a legacy
    -- display form that does not round-trip through PlayerKey exactly
    -- (notably realm/display separators). Character names themselves cannot
    -- contain spaces or "-", so comparing the character-name component is a
    -- safe compatibility fallback for identifying our own row/message.
    local function CharacterPart(value)
        if type(value) ~= "string" then return nil end
        value = (SB.TrimText and SB.TrimText(value)) or value:match("^%s*(.-)%s*$")
        if not value or value == "" then return nil end
        local part = value:match("^([^%-%s]+)") or value
        return part ~= "" and part or nil
    end

    local senderChar = CharacterPart(sender)
    local meChar = CharacterPart(meName or meFull)
    if senderChar and meChar and senderChar == meChar then return true end

    -- Final compatibility path for clients that expose Ambiguate.
    if Ambiguate then
        local okSender, shortSender = pcall(Ambiguate, sender, "none")
        local okMe, shortMe = pcall(Ambiguate, meFull or meName, "none")
        if okSender and okMe and shortSender and shortMe and shortSender == shortMe then
            return true
        end
    end

    return false
end

------------------------------------------------------------------------
-- Chat notifications - Settings -> Remote Playback. Three independent
-- toggles:
--   notifyOnMuted        - a remote sound played for you
--   notifyMutedAttempts  - a remote sound was BLOCKED by a PER-SOUND mute
--                          specifically - so you know someone tried. Does
--                          NOT cover a disabled "Receive Sounds from"
--                          channel - that's always fully silent, no
--                          exceptions, handled entirely in OnAddonMessage's
--                          PLAY branch below, before any of this runs.
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
-- Distinct again from both of the above - a personal Ignore-list block is
-- neither a sound-mute nor a channel opt-out, gets its own colour so the
-- three counts are never visually confused with each other.
local IGNORE_COLOR = "cffff8080" -- soft red

-- Colour-codes the channel/source portion the same way Now Playing does
-- (SB.GetChannelColor).
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

-- Shows how many recipients had the sound MUTED locally, not just who
-- actually received/played it - "(N muted)" in red, right after the
-- "(Channel received: ...)" segment, only when mutedCount > 0. `entries`
-- may be empty (everyone who got it had it muted) - the received segment
-- is omitted rather than printing an empty "()" list.
--
-- `rxOffCount` counts recipients who never got a chance to mute/play it
-- because they have that whole receive channel switched off (Settings'
-- Send/Receive table) - shown as its own "(N receive-off)" segment in
-- orange, never merged into "(N muted)" since it's a channel-level
-- opt-out, not a deliberate per-sound/per-person mute. Debug-Mode-only
-- (see HandleRxOffAck) - `rxOffCount` is always 0 on a normal client.
local function PrintFriendsReceived(soundName, entries, mutedCount, rxOffCount, ignoredCount)
    local receivedPart = #entries > 0
        and string.format(" |cff999999(%s)|r", FormatReceivedList(entries))
        or ""
    local mutedPart = (mutedCount and mutedCount > 0)
        and string.format(" |%s(%d muted)|r", MUTED_COLOR, mutedCount)
        or ""
    local rxOffPart = (rxOffCount and rxOffCount > 0)
        and string.format(" |%s(%d receive-off)|r", RXOFF_COLOR, rxOffCount)
        or ""
    -- e.g. "Guild received: 4 (1 blocked by Ignore)"
    local ignoredPart = (ignoredCount and ignoredCount > 0)
        and string.format(" |%s(%d blocked by Ignore)|r", IGNORE_COLOR, ignoredCount)
        or ""
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|%s[Soundbook]|r |cffffffff%s|r: |cffffd100%s|r%s%s%s%s",
        TAG_COLOR, UnitName("player"), soundName, receivedPart, mutedPart, rxOffPart, ignoredPart))
end

------------------------------------------------------------------------
-- Sending
------------------------------------------------------------------------

-- Raid and Party are treated as ONE target everywhere in Soundbook
-- (dropdowns, the Send broadcast toggle, per-sound Default/Macro Output
-- overrides all only ever store "RAID") - they're mutually exclusive in
-- WoW, you're never in both at once. This is the one place that resolves
-- the merged concept to whichever native channel is actually live right
-- now: "RAID" while in a raid, "PARTY" while in a non-raid group, nil if
-- in neither (nothing to send to).
function SB.ResolveGroupChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

-- Names already covered by a currently-enabled group broadcast channel this
-- send (Guild/Raid/Party), so SendToFriends can skip whispering them.
-- Without this, anyone who is both e.g. in your guild AND on your friends
-- list would get the same sound twice (once via GUILD, once via WHISPER),
-- with whichever packet arrives first deciding the displayed "received"
-- channel. Each person gets exactly one copy, via the most specific
-- channel that reaches them.
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

    -- Raid and Party share the one "RAID" toggle (see SB.ResolveGroupChannel
    -- above) - whichever of the two is actually live gets scanned here.
    if modes.RAID and IsInRaid() then
        -- Compatibility hardening: raid indices aren't guaranteed compact -
        -- scan the full valid range, not just up to the current member count.
        for i = 1, SB.MAX_RAID_MEMBERS do
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
        -- Ignore blocking: unlike a true Guild/Raid channel message, this
        -- blind broadcast CAN filter per-recipient, so it silently skips an
        -- ignored name (same "skip and continue" shape as the `covered`
        -- de-dup above) rather than aborting the whole send.
        if name and connected and not IsSelf(name) and not covered[IdentityKey(name)] and not SB:IsIgnored(name) then
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
    -- Shared outbound boundary: this is the actual wire-sending function for
    -- Guild/Raid/Party/Friends all at once, so it re-checks
    -- SB:IsSendBlockedByRaid() here too even though every current caller
    -- already checks first - a future caller that forgets its own check
    -- still can't bypass a Raid Admin mute this way.
    if SB:IsSendBlockedByRaid() then return end

    local text = SB.PROTOCOL_VERSION .. SEP .. "PLAY" .. SEP .. soundID
    recentBroadcasts[soundID] = GetTime()

    -- Raid and Party share the one "RAID" toggle - whichever is actually
    -- live gets the message (see SB.ResolveGroupChannel).
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
-- These three send functions are deliberately silent (no PlayLocally
-- re-play, no "Sent to X" chat line), unlike SendMenu.lua's
-- SB:SendSoundTo* further below - a normal click through this setting
-- should feel exactly like a normal click always has (SB:TriggerSound
-- already played it locally and fires LOCAL_SOUND_PLAYED), just aimed
-- differently, not like the more deliberate, explicitly-confirmed
-- SendMenu action.
------------------------------------------------------------------------

-- Shared outbound boundary for a whole-channel Guild/Raid/Party send:
-- every current caller (DispatchDefaultOutput, SendSoundToChannel)
-- already checks SB:IsSendBlockedByRaid() first, but re-checking at this
-- lowest level means a future/alternate send path can't bypass a Raid
-- Admin mute by calling this function directly. No friend exemption here
-- - that only ever applies to a single direct/whisper target (see
-- SendToPlayerSilent's own callers).
local function SendToSingleChannelSilent(soundID, channel)
    if channel ~= "GUILD" and channel ~= "PARTY" and channel ~= "RAID" then return end
    if SB:IsSendBlockedByRaid() then return end
    recentBroadcasts[soundID] = GetTime()
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "PLAY" .. SEP .. soundID, channel)
end

-- Same shared-boundary reasoning as SendToSingleChannelSilent above.
local function SendToAllFriendsSilent(soundID)
    if SB:IsSendBlockedByRaid() then return end
    recentBroadcasts[soundID] = GetTime()
    local text = SB.PROTOCOL_VERSION .. SEP .. "PLAY" .. SEP .. soundID
    SendToFriends(text, {})
end

local function SendToPlayerSilent(soundID, name)
    if not SB.registry[soundID] or not SB.IsValidPlayerTarget(name) or IsSelf(name) then return end
    -- Ignore blocking - silent here, matching this function's "no chat
    -- line" design. SB:SendSoundToPlayer below is the surface with an
    -- explicit chat confirmation, and checks this itself first so it can
    -- print its own dedicated message instead.
    if SB:IsIgnored(name) then return end
    recentBroadcasts[soundID] = GetTime()
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "PLAY" .. SEP .. soundID .. SEP .. "D", "WHISPER", name)
end

-- A Guild/Raid channel message can't be narrowed to specific recipients at
-- the WoW chat-channel level, so a narrowed per-player subset instead goes
-- out as individual whispers carrying a "SG"/"SR" flag (see
-- ParsePlayPayload/OnAddonMessage below) - the ONE place OnAddonMessage
-- remaps a whisper carrying either flag back onto the "GUILD"/"RAID"
-- channel for every purpose downstream (receive gating, queue priority,
-- ACK code, chat label), so a recipient's client treats it exactly like a
-- real channel-wide broadcast - explicit requirement: "preserve the
-- logical source channel... even if the underlying transport has to use
-- individual messages." Friends never needs this: a Friends
-- broadcast/subset was always individual per-friend whispers with no flag
-- at all (see SendToFriends) - narrowing it to a subset is just sending to
-- fewer names, no wire change needed.
--
-- Same outbound boundary as a genuine whole-channel send
-- (SendToSingleChannelSilent) - checked ONCE for the whole subset, no
-- per-recipient Friend exemption, since this is still logically a
-- Guild/Raid send, not a Direct one.
local SUBSET_WIRE_FLAG = { GUILD = "SG", RAID = "SR" }
local function SendSubsetSilent(soundID, names, bucket)
    local flag = SUBSET_WIRE_FLAG[bucket]
    if not flag or not SB.registry[soundID] then return end
    if SB:IsSendBlockedByRaid() then return end
    local text = SB.PROTOCOL_VERSION .. SEP .. "PLAY" .. SEP .. soundID .. SEP .. flag
    local sentAny = false
    for _, name in ipairs(names) do
        if SB.IsValidPlayerTarget(name) and not IsSelf(name) and not SB:IsIgnored(name) then
            SB.SendAddonMessage(SB.COMM_PREFIX, text, "WHISPER", name)
            sentAny = true
        end
    end
    if sentAny then recentBroadcasts[soundID] = GetTime() end
end

-- Shared option list for Settings -> Default Output Channel (UI.lua's main
-- dropdown) and EditWindow.lua's per-sound macro "Output" dropdown. Fixed
-- order All -> Friends -> Guild -> Raid -> Party -> Self, with each
-- group's online members listed as their own rows directly under that
-- group's header (indented, smaller font via SB.OutputTargetRowFont below).
--
-- Individual people are re-queried live every time the list opens, never
-- cached, and deduplicated by name with the same priority SendMenu.lua's
-- right-click list uses - Friends > Guild > Raid > Party - so someone in
-- more than one group at once shows up only under the highest-priority
-- one. Only ever someone confirmed to have Soundbook (SB.db.knownUsers).
local PLAYER_ROW_INDENT = 14

-- The single canonical "who's reachable" computation: the main dropdown
-- (SB.ComputeOutputTargetOptions, used by UI.lua/EditWindow.lua) and the
-- Mini Soundbook's right-click menu (SendMenu.lua) both call this instead
-- of each re-implementing their own Friends/Guild/Raid/Party scan, so they
-- can never drift apart.
--
-- Returns { FRIENDS = {name, ...}, GUILD = {...}, RAID = {...} }, each list
-- sorted, deduplicated by a fixed Friends > Raid > Guild priority (someone
-- reachable through several groups shows up exactly once, under the
-- highest-priority one: a friend is always a friend first; a guildmate
-- also in your raid/party counts as Raid, the more specific relationship),
-- and filtered to SB.db.knownUsers (confirmed Soundbook installs only).
--
-- RAID is Raid AND Party combined (see SB.ResolveGroupChannel) - the two
-- are mutually exclusive in WoW, so this bucket collects whichever of the
-- two is actually live; there is no separate PARTY key.
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
            -- Local playback is unconditional for the sender, so the player
            -- must never appear as one of their own selectable recipients.
            -- Keeping this at the canonical reachable-player boundary removes
            -- Self consistently from Guild/Raid/Friends checkbox lists,
            -- counts, saved-subset resolution and actual subset dispatch.
            if IsSelf(rawName) then return end
            local key = IdentityKey(rawName)
            if not key or not KnownUserInfo(rawName) or claimedBy[key] then return end
            claimedBy[key] = true
            -- Keep the realm-qualified target - sends must never guess
            -- between two same-named players.
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
    -- whichever bucket claims a player first is the only one they show
    -- up in.
    CollectInto("FRIENDS", function(add)
        local n = SB.GetNumFriends()
        for i = 1, n do
            local name, connected = SB.GetFriendInfoByIndex(i)
            if name and connected then add(name) end
        end
    end)
    CollectInto("RAID", function(add)
        if IsInRaid() then
            -- Compatibility hardening: raid indices aren't guaranteed
            -- compact - scan the full valid range, not just up to the
            -- current member count.
            for i = 1, SB.MAX_RAID_MEMBERS do
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

------------------------------------------------------------------------
-- Per-player recipient subset for the ACTIVE Send-to channel (explicit
-- request: restore/extend per-player selection for Guild/Raid/Friends,
-- reusing SB.ComputeReachablePlayers/the existing transport - no parallel
-- discovery or send system). Persists across /reload and relog (explicit
-- requirement - SB.db.ui.channelSubset, sanitized by Database.lua's
-- SanitizeDatabase, see Core.lua's GetDefaultDatabase comment on it).
-- The OLD Output Rail's own `SB.db.ui.outputRail.selected` SavedVariables
-- shape (a different, now-dead always-on multi-select broadcast feature)
-- is left completely untouched; this is intentionally a fresh,
-- independent concept, just co-located in the same `ui` table.
--
-- Each bucket holds one of THREE distinct states, per explicit
-- requirement that "all reachable selected" and "an explicit subset that
-- currently happens to be empty/partial" behave differently as new people
-- become reachable:
--   nil        - never activated ("whole channel", the addon's original,
--                always-existing behaviour).
--   "ALL"      - implicit "everyone currently reachable" - dynamically
--                recomputed from SB.ComputeReachablePlayers on every read,
--                so a NEW arrival is automatically included while this
--                bucket stays active (explicit requirement: "Friends is
--                3/3 ... a fourth friend comes online -> 4/4").
--   an array   - an explicit, frozen subset (possibly empty) set by a
--                deliberate toggle - a later roster change can add new
--                NAMES to what's reachable, but never to what's selected
--                (explicit requirement: "2/3 ... a fourth friend comes
--                online -> 2/4", and "0/3 -> 0/4"), and this is never
--                mutated by a mere read/refresh, only by
--                ToggleChannelMember/ToggleAllChannelMembers below.
-- Whenever such an explicit toggle happens to leave EVERY currently
-- reachable member selected, it collapses back to "ALL" (see
-- SetExplicitSubset) - "all selected" is always representable as the
-- dynamic implicit state, regardless of which gesture produced it, so it
-- keeps tracking future arrivals from that point on too.
------------------------------------------------------------------------
local SUBSET_BUCKETS = { "GUILD", "RAID", "FRIENDS" }

local function SubsetStore()
    return SB.db and SB.db.ui and SB.db.ui.channelSubset
end

local function GetSubset(bucket)
    local store = SubsetStore()
    return store and store[bucket]
end

local function SetSubset(bucket, value)
    local store = SubsetStore()
    if not store then return end
    store[bucket] = value
end

local function ReachableList(bucket)
    return SB.ComputeReachablePlayers()[bucket] or {}
end

local function KeySet(list)
    local set = {}
    for _, name in ipairs(list) do set[IdentityKey(name)] = true end
    return set
end

--- True once `bucket` has been activated (whether currently "ALL" or an
--- explicit subset, however large or small, and whether from this session
--- or a prior one) - false means "whole channel" still applies.
function SB.IsChannelSubsetActive(bucket)
    return GetSubset(bucket) ~= nil
end

--- True only while `bucket` currently holds a concrete, explicitly-
--- narrowed list (possibly empty) - false for both `nil` (never
--- activated) and the dynamic "ALL" state. The one place the UI asks
--- "has the player actually changed who's selected", so it can show a
--- plain count for the default all-selected state and only switch to a
--- "selected/available" count once a real narrowing exists (explicit
--- requirement - never show e.g. "Guild (3/3)" for the untouched
--- default).
function SB.IsChannelSubsetExplicit(bucket)
    local current = GetSubset(bucket)
    return current ~= nil and current ~= "ALL"
end

--- Activates `bucket`'s subset if it isn't already active, as the
--- implicit "ALL" state (explicit requirement: "on first selecting a
--- channel, all listed members are selected by default", and stays live
--- from then on). A no-op once already active (including from a prior
--- session, now restored from SavedVariables), so reopening an already-
--- customized channel never resets the player's own narrowing.
function SB.ActivateChannelSubset(bucket)
    if bucket ~= "GUILD" and bucket ~= "RAID" and bucket ~= "FRIENDS" then return end
    if GetSubset(bucket) then return end
    SetSubset(bucket, "ALL")
end

--- Explicit requirement: "Switching from Guild to Friends/Raid-Party
--- immediately clears the previous channel's per-player selection...
--- Recipient selections must never combine across channels." Pass nil to
--- clear every bucket (switching to All/Self/a single player).
function SB.ResetChannelSubsetsExcept(activeBucket)
    for _, bucket in ipairs(SUBSET_BUCKETS) do
        if bucket ~= activeBucket then SetSubset(bucket, nil) end
    end
end

--- Sets `bucket` to the given explicit list, or collapses it back to the
--- dynamic "ALL" state if that list happens to cover every currently
--- reachable member (see the module comment above) - the ONE place both
--- ToggleChannelMember and ToggleAllChannelMembers below finish through,
--- so they can never disagree on when "explicit" becomes "implicit all"
--- again.
local function SetExplicitSubset(bucket, list)
    local reachable = ReachableList(bucket)
    local selected = KeySet(list)
    for _, name in ipairs(reachable) do
        if not selected[IdentityKey(name)] then
            SetSubset(bucket, list)
            return
        end
    end
    SetSubset(bucket, "ALL")
end

--- Toggles one member of `bucket` on/off, activating the bucket first if
--- this is the very first interaction with it. Toggling someone off while
--- in the dynamic "ALL" state freezes the CURRENT reachable set (minus
--- that one person) as an explicit subset - a later new arrival must NOT
--- retroactively join it (explicit requirement).
function SB.ToggleChannelMember(bucket, name)
    SB.ActivateChannelSubset(bucket)
    local current = GetSubset(bucket)
    local key = IdentityKey(name)
    local list = {}
    if current == "ALL" then
        for _, existing in ipairs(ReachableList(bucket)) do
            if IdentityKey(existing) ~= key then table.insert(list, existing) end
        end
    else
        local found = false
        for _, existing in ipairs(current) do
            if IdentityKey(existing) == key then found = true else table.insert(list, existing) end
        end
        if not found then table.insert(list, name) end
    end
    SetExplicitSubset(bucket, list)
end

--- "Clicking the active channel again toggles all members off/on" -
--- clears to nobody if everyone currently reachable is already selected
--- (whether that's the dynamic "ALL" state or an explicit subset that
--- just happens to currently cover everyone), otherwise selects everyone
--- currently reachable via the dynamic "ALL" state (so it keeps tracking
--- future arrivals from here on, not a one-time frozen snapshot).
function SB.ToggleAllChannelMembers(bucket)
    local current = GetSubset(bucket)
    if current == "ALL" then
        SetSubset(bucket, {})
        return
    end
    local reachable = ReachableList(bucket)
    local selected = KeySet(current or {})
    local allSelected = #reachable > 0
    for _, name in ipairs(reachable) do
        if not selected[IdentityKey(name)] then allSelected = false break end
    end
    SetSubset(bucket, allSelected and {} or "ALL")
end

--- The dispatch-time recipient list for `bucket`, or nil if the whole
--- channel should be used (unmodified original behaviour). The dynamic
--- "ALL" state always resolves to everyone CURRENTLY reachable; an
--- explicit subset never includes a stored name that isn't currently
--- reachable (offline, left the group/guild) even if it's still sitting
--- in the stored list - a name coming back reachable later is still
--- honoured, since it was never actually removed from the stored subset,
--- only filtered out of THIS particular call's result.
function SB.ComputeChannelSubsetRecipients(bucket)
    local current = GetSubset(bucket)
    if not current then return nil end
    if current == "ALL" then return ReachableList(bucket) end
    local reachableKeys = KeySet(ReachableList(bucket))
    local list = {}
    for _, name in ipairs(current) do
        if reachableKeys[IdentityKey(name)] then table.insert(list, name) end
    end
    return list
end

--- Every reachable name for `bucket`, each tagged with whether it's
--- currently selected - the UI's one source for rendering the expandable
--- member checkbox list. Both `nil` (whole-channel mode) and "ALL"
--- report every row as selected, matching "keep existing whole-channel
--- behaviour equivalent to all members selected".
function SB.GetChannelMemberRows(bucket)
    local reachable = ReachableList(bucket)
    local current = GetSubset(bucket)
    local rows = {}
    if not current or current == "ALL" then
        for _, name in ipairs(reachable) do table.insert(rows, { name = name, selected = true }) end
    else
        local selectedKeys = KeySet(current)
        for _, name in ipairs(reachable) do
            table.insert(rows, { name = name, selected = selectedKeys[IdentityKey(name)] == true })
        end
    end
    return rows
end

--- (selectedCount, availableCount) for `bucket`'s channel row - explicit
--- requirement: "preferably show selected/available count". Available is
--- always the live reachable count; selected is the same count for `nil`/
--- "ALL", or only counts someone both reachable right now AND in the
--- stored explicit subset.
function SB.GetChannelSubsetCount(bucket)
    local reachable = ReachableList(bucket)
    local current = GetSubset(bucket)
    if not current or current == "ALL" then return #reachable, #reachable end
    local selectedKeys = KeySet(current)
    local selected = 0
    for _, name in ipairs(reachable) do
        if selectedKeys[IdentityKey(name)] then selected = selected + 1 end
    end
    return selected, #reachable
end

------------------------------------------------------------------------
-- Explicit user request: the subset survives a /reload but resets to
-- "everyone selected" after a genuine relog/client restart - the CHANNEL
-- choice itself (SB.db.settings.defaultOutputTarget) is unaffected
-- either way, already an ordinary persisted setting with its own
-- unrelated storage. PLAYER_ENTERING_WORLD's own `isInitialLogin`
-- argument is the native, documented way to tell a fresh login/relog
-- apart from a /reload while already in world (a /reload re-executes
-- every addon file from scratch, same as this whole module reloading,
-- but is NOT a fresh login) - no custom heuristic needed. Resetting to
-- nil (rather than explicitly "ALL") is enough: every read function
-- above already treats nil exactly like "ALL" for display/dispatch
-- purposes, so this reproduces "everyone selected" with no special case.
------------------------------------------------------------------------
function SB.ResetChannelSubsetsOnFreshLogin(isInitialLogin)
    if not isInitialLogin then return end
    for _, bucket in ipairs(SUBSET_BUCKETS) do
        SetSubset(bucket, nil)
    end
end

-- Named (not anonymous) purely so the mock harness used in this
-- codebase's own pre-flight testing can reach it and simulate
-- PLAYER_ENTERING_WORLD directly - no other addon code ever needs to.
local subsetLoginFrame = CreateFrame("Frame", "SoundbookSubsetLoginFrame")
subsetLoginFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
subsetLoginFrame:SetScript("OnEvent", function(_, _, isInitialLogin)
    SB.ResetChannelSubsetsOnFreshLogin(isInitialLogin)
end)

function SB.ComputeOutputTargetOptions()
    local opts = { { text = "All (checked in Settings)", value = "ALL", isHeader = true } }
    local reachable = SB.ComputeReachablePlayers()
    local friendNames, guildNames, raidNames = reachable.FRIENDS, reachable.GUILD, reachable.RAID

    -- Green when it matches this client's own version, orange when it's
    -- older/different/unknown - same colours everywhere a version suffix
    -- shows (this dropdown and SendMenu.lua's popup).
    local VERSION_CURRENT_COLOR = { 0.4, 0.95, 0.5 }
    local VERSION_OTHER_COLOR = { 1, 0.6, 0 }

    local function AddGroup(label, value, names)
        -- Every group header always shows, regardless of whether you're
        -- currently in that group or anyone reachable is in it (this
        -- dropdown, EditWindow's two dropdowns, SendMenu.lua's menu). A
        -- pick that goes nowhere right now (e.g. selecting Raid while
        -- solo) simply sends nothing when used
        -- (SB:DispatchDefaultOutput/SendToSingleChannelSilent handle that
        -- quietly). The header carries a "(N)" count of how many
        -- Soundbook-reachable players fall under it right now.
        table.insert(opts, { text = label .. " (" .. #names .. ")", value = value, isHeader = true })
        for _, name in ipairs(names) do
            local suffix, isCurrent = SB:GetFormattedPlayerVersion(name)
            table.insert(opts, {
                text = (SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(name) or name),
                value = "PLAYER:" .. name, indent = PLAYER_ROW_INDENT,
                suffix = suffix, suffixColor = isCurrent and VERSION_CURRENT_COLOR or VERSION_OTHER_COLOR,
                -- Same group key as this row's header ("FRIENDS"/"GUILD"/
                -- "RAID") - matches SendMenu.lua's popup, where a member
                -- row's NAME is always coloured by its group header, never
                -- by the version colour (that's the suffix's job only).
                channelKey = value,
            })
        end
    end

    -- Guild/Raid/Friends order, matching SendMenu.lua's and
    -- MutePlayers.lua's own group lists. Raid and Party are one merged row
    -- (see SB.ResolveGroupChannel/ComputeReachablePlayers) - labelled
    -- "Raid" while actually in a raid, "Party" while in a non-raid group,
    -- and "Raid" as the default label while in neither (still always
    -- shown; picking it then just sends nowhere).
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
-- member size distinction SendMenu.lua's own popup uses. Passed to
-- Theme.CreateDropdown:SetRowFont by both UI.lua's dropdown and
-- EditWindow.lua's Macro Output one.
-- A player's NAME is always coloured by its group (SB.CHANNEL_COLOR,
-- opt.value for a header / opt.channelKey for a member row), never by
-- version match - the separate version suffix (SB:GetFormattedPlayerVersion,
-- Debug Mode only) is the only thing that shows green/orange (see
-- Theme.lua's dropdown row building for opt.suffixColor). "ALL" has no
-- single channel and keeps the normal text colour.
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

--- The Output target a LOCAL click on `soundID` would actually use, if
--- `explicitOverride` is nil - priority order:
---   1. `explicitOverride` (a macro's own "::Target" suffix, or an
---      explicit caller like SendMenu.lua).
---   2. The sound's OWN per-sound "Default Output" (Edit Sound window,
---      saved.outputOverride) - distinct from the "Macro Output" field,
---      which only ever affects the copied macro text, never a normal
---      click. "ALL" (or unset) counts as "no override" here.
---   3. SB.db.settings.defaultOutputTarget (the Main window's single-
---      select "Send to:" control, see UI.lua) - "ALL" means
---      SB:BroadcastSound below, fanned out to whichever channels
---      Settings -> Multiplayer's Send matrix currently has enabled.
---      SB.db.ui.outputRail is left untouched in SavedVariables for
---      compatibility (see Database.lua's SanitizeDatabase) but has no
---      routing consumer any more.
---   4. "ALL" itself as the last-resort fallback (matches
---      defaults.settings.defaultOutputTarget - see Core.lua) - never
---      "nothing selected".
function SB:ResolveOutputTarget(soundID, explicitOverride)
    if explicitOverride and SB.IsValidOutputTarget(explicitOverride) then return explicitOverride end
    local saved = soundID and SB.db and SB.db.sounds and SB.db.sounds[soundID]
    if saved and saved.outputOverride and saved.outputOverride ~= "ALL" and SB.IsValidOutputTarget(saved.outputOverride) then
        return saved.outputOverride
    end
    local default = SB.db and SB.db.settings and SB.db.settings.defaultOutputTarget
    if default and default ~= "ALL" and SB.IsValidOutputTarget(default) then
        return default
    end
    return "ALL"
end

--- The SB.CHANNEL_COLOR entry matching `soundID`'s OWN per-sound "Default
--- Output" override, or nil if it doesn't have one set (or it's "ALL") -
--- colours its icon border/wash/name text everywhere it appears (UI.lua's
--- grid, including its own favourite slots).
--- Target -> SB.CHANNEL_COLOR mapping shared by SB.SoundOutputOverrideColor
--- below (soundID-based, for an already-saved sound) and EditWindow.lua's
--- live dropdown preview (draft-value-based, before Save) - one place for
--- the "ALL"/"SELF"/"PLAYER:x" special cases so the two can't drift apart.
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
--- play. Reads Settings -> Sound Routing -> "Default Output Channel"
--- (SB.db.settings.defaultOutputTarget) to decide where, if anywhere, this
--- click also gets sent - unless `overrideTarget` is given (a macro's
--- "::<Target>" suffix, see Macros.lua), which takes precedence for this
--- one call only and never touches the saved setting. Goes through
--- SB:ResolveOutputTarget above so a per-sound "Default Output" override
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
        -- Same friend exemption as SB:SendSoundToPlayer below - a direct
        -- send to a mutual Friend still goes through even under a
        -- raid-admin mute; anything else stays blocked.
        if SB:IsSendBlockedByRaid() and not SB:IsFriend(playerName) then return end
        SendToPlayerSilent(soundID, playerName)
        return
    end

    if SB:IsSendBlockedByRaid() then return end

    -- The per-player recipient subset (SB.ComputeChannelSubsetRecipients
    -- above) only ever narrows the MAIN "Send to:" selector's own current
    -- value - never a macro's explicit "::Target" override or a per-sound
    -- "Default Output" override, both a deliberate, separate choice for
    -- that one sound/macro that must keep reaching the WHOLE channel
    -- exactly as before (explicit requirement: preserve existing per-
    -- sound/macro routing semantics outside this new filtering).
    local saved = soundID and SB.db and SB.db.sounds and SB.db.sounds[soundID]
    local hasExplicitOverride = (overrideTarget and SB.IsValidOutputTarget(overrideTarget))
        or (saved and saved.outputOverride and saved.outputOverride ~= "ALL" and SB.IsValidOutputTarget(saved.outputOverride))
    local subsetBucket = (target == "GUILD" and "GUILD") or ((target == "RAID" or target == "PARTY") and "RAID") or (target == "FRIENDS" and "FRIENDS") or nil
    local subset = (not hasExplicitOverride) and subsetBucket and SB.ComputeChannelSubsetRecipients(subsetBucket) or nil

    if target == "ALL" then
        SB:BroadcastSound(soundID)
    elseif target == "GUILD" then
        if subset then SendSubsetSilent(soundID, subset, "GUILD") else SendToSingleChannelSilent(soundID, "GUILD") end
    elseif target == "RAID" or target == "PARTY" then
        if subset then SendSubsetSilent(soundID, subset, "RAID"); return end
        -- "RAID" is the merged Raid/Party target (see
        -- SB.ResolveGroupChannel), resolved to whichever is actually live.
        -- "PARTY" as an input here is not just stale data: the UI itself
        -- never produces it (one merged Raid/Party option), but it is
        -- still live via the "/sb play id::party" macro keyword
        -- (Macros.lua's TARGET_KEYWORDS) and via per-sound overrides saved
        -- before the Raid/Party merge - both keep working, resolved the
        -- same as "RAID".
        local resolved = SB.ResolveGroupChannel()
        if resolved then SendToSingleChannelSilent(soundID, resolved) end
    elseif target == "FRIENDS" then
        -- Friends was always individual per-friend whispers with no
        -- channel flag at all (see SendToFriends) - a subset here is just
        -- SendToFriends' own logic run against fewer names, no protocol
        -- change needed (unlike Guild/Raid above).
        if subset then
            local text = SB.PROTOCOL_VERSION .. SEP .. "PLAY" .. SEP .. soundID
            local sentAny = false
            for _, name in ipairs(subset) do
                if not SB:IsIgnored(name) then
                    SB.SendAddonMessage(SB.COMM_PREFIX, text, "WHISPER", name)
                    sentAny = true
                end
            end
            if sentAny then recentBroadcasts[soundID] = GetTime() end
        else
            SendToAllFriendsSilent(soundID)
        end
    end
end

------------------------------------------------------------------------
-- Explicit one-off sends - SendMenu.lua's right-click "send to" list on a
-- Mini Soundbook slot. Unlike SB:BroadcastSound above (which fires to every
-- channel currently enabled under Settings -> Broadcast), these ignore that
-- setting entirely - picking a specific target from the menu is a
-- deliberate override of "broadcast everywhere", not another instance of it.
-- Each one plays the sound locally too and prints an immediate "sent"
-- confirmation, separate from, and ahead of, the ACK-based "who actually
-- received/played it" notification (PrintFriendsReceived above), which
-- still arrives afterwards as normal.
------------------------------------------------------------------------

local GREEN = "cff55ff88"

-- `channelKey` is one of SB.CHANNEL_COLOR's keys (GUILD/PARTY/RAID/
-- FRIENDS/DIRECT), kept separate from `targetLabel` since a direct send's
-- targetLabel is a PLAYER NAME and would never match SB.GetChannelColor
-- by text.
local function PrintSent(targetLabel, soundName, channelKey)
    local color = SB.CHANNEL_COLOR[channelKey] or SB.CHANNEL_COLOR.SELF
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
        "|%s[Soundbook]|r |%sSent|r |cffffd100%s|r |cff999999to|r |cff%s%s|r",
        TAG_COLOR, GREEN, soundName, color.hex, targetLabel))
end

-- Plays soundID locally for YOU (same combat/encounter/overlap rules as any
-- other trigger, via the shared SB:PlaySound) and fires the same
-- LOCAL_SOUND_PLAYED event a normal click does, so the Mini Soundbook's Now
-- Playing overlay picks it up identically. Does NOT gate the send on this -
-- a local mute just skips your own playback while the send below still
-- goes out. A local mute means "I don't want to hear this on MY speakers",
-- not "nobody else should get this from me"; the two are deliberately
-- decoupled.
-- `target` (optional) mirrors what SB:TriggerSound's own LOCAL_SOUND_PLAYED
-- fire passes, so the Mini Soundbook's Announcement Bar can show what a
-- SendMenu.lua-driven send actually went to instead of falling back to
-- "Self". See Announcer.lua's own LOCAL_SOUND_PLAYED handler for how this
-- becomes the displayed source label (and, for a Direct send, the
-- recipient's name).
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
    -- Raid/Party group row), resolved here to whichever is actually live
    -- (see SB.ResolveGroupChannel). "PARTY" as an input is handled the
    -- same as SB:DispatchDefaultOutput above - not just stale data, still
    -- reachable via the "/sb play id::party" macro keyword and pre-merge
    -- saved overrides.
    if channel == "RAID" or channel == "PARTY" then
        channel = SB.ResolveGroupChannel()
    end
    -- From here on "PARTY"/"RAID"/"GUILD" are real WoW channel names, not
    -- output-target values - ResolveGroupChannel above can itself resolve
    -- to the literal wire channel "PARTY" when the player is in a
    -- non-raid group, which is what this check is actually validating.
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
-- is the one deliberate send, not one of several simultaneous channels
-- that could double up with each other.
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
-- through even while a raid-admin mute is active. This is the ONLY
-- SendMenu.lua action exempted this way - SB:SendSoundToChannel/
-- SendSoundToAllFriends (a whole channel, or every friend at once) stay
-- fully blocked regardless, since those are exactly the group-context
-- spam Mute All exists to stop; a single deliberate send between two
-- confirmed friends is a different, much narrower thing.
function SB:SendSoundToPlayer(soundID, name)
    if not SB.registry[soundID] or not SB.IsValidPlayerTarget(name) then return end
    if IsSelf(name) then
        -- Self is local playback, never a network recipient. This also
        -- protects stale saved PLAYER:<self> targets from producing a second
        -- copy of the same sound through a whisper loopback.
        PlayLocally(soundID, "SELF")
        return
    end
    -- Ignore blocking - checked first, ahead of the raid-mute Friend
    -- exemption below: absolute, no exceptions. DispatchDefaultOutput's
    -- own PLAYER target shares the same underlying block via
    -- SendToPlayerSilent but stays silent there on purpose; this
    -- deliberate SendMenu.lua action gets the explicit chat message.
    if SB:IsIgnored(name) then
        SB:Print(string.format("Cannot send to %s: Soundbook communication is blocked by Ignore.", NormalizeName(name) or name))
        return
    end
    if SB:IsSendBlockedByRaid() and not SB:IsFriend(name) then
        SB:Print("Sending is currently disabled by your raid leader.")
        return
    end
    PlayLocally(soundID, "PLAYER:" .. name)
    recentBroadcasts[soundID] = GetTime()
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "PLAY" .. SEP .. soundID .. SEP .. "D", "WHISPER", name)
    PrintSent(NormalizeName(name) or name, SB:GetSoundDisplayName(soundID), "DIRECT")
end

-- SendMenu.lua's extra top row - only offered when the player's own
-- Default Output isn't already "ALL" (otherwise a plain click already does
-- exactly this). A one-off way to send via whatever Settings -> Sound
-- Routing -> Broadcast currently has enabled, without changing that
-- setting or touching any per-sound override - same "local replay + chat
-- confirmation" shape as every other SendMenu.lua action, unlike the quiet
-- SB:BroadcastSound this wraps.
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

-- SendMenu.lua's extra bottom row - always offered, regardless of Default
-- Output/per-sound overrides: play locally only, no network send. No
-- PrintSent - nothing was sent, so no "Sent to X" confirmation applies.
function SB:PlaySoundSelfOnly(soundID)
    if not SB.registry[soundID] then return end
    PlayLocally(soundID, "SELF")
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------

-- `isDirect` distinguishes a Direct-targeted send (SendMenu's "send to one
-- specific person", from a Friend, Guild member, whoever) from a plain
-- Friends-list broadcast - both travel as WHISPER, but each has its own
-- separate receive toggle (receiveDirect vs receiveFriends) rather than
-- sharing one. Callers must resolve isDirect (see ParsePlayPayload)
-- BEFORE calling this for WHISPER traffic.
local function ReceiveAllowedForChannel(channel, isDirect)
    local s = SB.db.settings
    -- Raid and Party share one Receive toggle too - receiveRaid covers
    -- both wire channels.
    if channel == "PARTY" or channel == "RAID" or channel == "RAID_LEADER" then return s.receiveRaid
    elseif channel == "GUILD" or channel == "OFFICER" then return s.receiveGuild
    elseif channel == "WHISPER" then return isDirect and s.receiveDirect or s.receiveFriends
    end
    return false
end

-- User-facing label for received-sound notifications and queue entries,
-- keyed by the same channel values CHAT_MSG_ADDON reports.
local CHANNEL_LABEL = {
    PARTY = "Party", RAID = "Raid", RAID_LEADER = "Raid",
    GUILD = "Guild", OFFICER = "Guild", WHISPER = "Friend",
}

-- Pending "who received this" receipts, waiting for a short quiet period
-- before printing the aggregated list (several friends can ack the same
-- broadcast within a second or two of each other). `mutedNames`/`rxOffNames`
-- are SETs (not lists) purely to de-duplicate a retried MUTEACK/RXOFFACK
-- the same way `entries` already de-dupes a retried ACK below - only their
-- counts are ever shown, never the names themselves.
local pendingAcks = {} -- [soundID] = { entries = { {name=, code=}, ... }, mutedNames = {[name]=true}, mutedCount = 0, rxOffNames = {[name]=true}, rxOffCount = 0, ignoredNames = {[name]=true}, ignoredCount = 0, timer = <handle> }
local ACK_DEBOUNCE = 1.5 -- seconds of quiet before printing

local function EnsurePending(soundID)
    local pending = pendingAcks[soundID]
    if not pending then
        pending = { entries = {}, mutedNames = {}, mutedCount = 0, rxOffNames = {}, rxOffCount = 0, ignoredNames = {}, ignoredCount = 0 }
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
    if #pending.entries > 0 or pending.mutedCount > 0 or pending.rxOffCount > 0 or pending.ignoredCount > 0 then
        PrintFriendsReceived(SB:GetSoundDisplayName(soundID), pending.entries, pending.mutedCount, pending.rxOffCount, pending.ignoredCount)
    end
end

-- Analytics: a real ack (played OR muted - either way, a genuine OTHER
-- player's Soundbook actually received and processed the message) is the
-- earliest honest proof of "a real sender AND a real recipient" - stats
-- must only reflect real social interactions, never a purely local/self
-- play or a send nobody was around to receive (SELF never reaches
-- recentBroadcasts - see SB:DispatchDefaultOutput - and a send with no
-- receiver simply never gets an ack). Independent of the
-- notifyFriendReceipts setting below - that only controls a CHAT
-- notification, not whether the interaction happened. Credited exactly
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
    if IsSelf(sender) then return end -- never report/credit our own client as a recipient
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
-- locally instead of playing it (see HandlePlayCommand's MUTEACK send) -
-- only contributes to the count, never the "received" name list. Still
-- counts for Analytics (CreditAnalyticsOnce above) - a real other
-- player's client genuinely received it, they just chose not to hear it.
local function HandleMuteAck(soundID, sender)
    if IsSelf(sender) then return end -- never report/credit our own client as a recipient
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

-- Same idea again, but for a recipient who never reached the mute/play
-- decision at all - they have the whole receive channel this sound
-- arrived on switched off (Settings' Send/Receive table), see the
-- RXOFFACK send in OnAddonMessage's PLAY handling. Debug-Mode-only
-- (SB:IsDebug()) - checked on OUR (the sender's) own client, since we
-- decide whether to show it: a normal user sees nothing, same as if the
-- sound was never sent. Analytics crediting happens regardless of Debug
-- Mode (same reasoning as HandleMuteAck above).
local function HandleRxOffAck(soundID, sender)
    if IsSelf(sender) then return end -- never report/credit our own client as a recipient
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

-- Ignore blocking - a recipient who rejected this broadcast because THEY
-- have US ignored (see HandlePlayCommand's own Ignore check) replies with
-- IGNOREACK instead of a normal ACK, so we never count them as a
-- successful recipient. Unlike RxOffAck (Debug-Mode-only) this always
-- shows, same visibility as HandleMuteAck. Ignore is only ever reported
-- from an explicit wire-level IGNOREACK, never inferred from a bare
-- timeout/missing ACK (that stays "unreachable"). Still credited to
-- Analytics the same way a mute is - a real other client genuinely
-- received and processed the message, they just aren't allowed to play it.
local function HandleIgnoreAck(soundID, sender)
    if IsSelf(sender) then return end -- never report/credit our own client as a recipient
    local sentAt = recentBroadcasts[soundID]
    if not sentAt or (GetTime() - sentAt) > ACK_CLAIM_WINDOW then
        return
    end
    CreditAnalyticsOnce(soundID, sentAt)
    if not SB.db.settings.notifyFriendReceipts then return end

    local name = IdentityKey(sender) or sender
    local pending = EnsurePending(soundID)
    if pending.ignoredNames[name] then return end -- already counted
    pending.ignoredNames[name] = true
    pending.ignoredCount = pending.ignoredCount + 1
    RestartFlushTimer(soundID, pending)
end

-- If an incoming PLAY references a Legacy/German Memes soundID we don't
-- have locally, the likely explanation is that OUR OWN Soundbook is older
-- than the sender's - a shared/standard sound they already have that we
-- haven't updated to (as opposed to one of their own private sounds,
-- which is normal, not a version problem). Checked by parsing the
-- category straight out of the soundID string, so it works even for an
-- id we don't recognize at all, no registry lookup needed. Hints the
-- RECEIVING player their addon may be out of date, at most once every 24h
-- (SB.db.lastOutdatedHintAt, a persisted time() epoch) so a burst of the
-- same broadcast, or several senders in a row, can't spam chat with it.
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
    -- The per-(sender,soundID) repeat-cooldown is enforced in
    -- HandleIncomingPlay, which claims the cooldown slot the moment a
    -- sound is ACCEPTED (queued or played), not only once actually
    -- played. Every path reaching this function already passed that check.
    if not SB.registry[soundID] then
        -- Largely unreachable - HandleIncomingPlay's own IsPlayableRightNow
        -- already rejects an unknown soundID before this function is ever
        -- called (see NotifyIfMuted for where "unknown" handling, including
        -- MaybeShowOutdatedHint, lives). Kept as a defensive fallback only.
        SB:Debug("Missing sound: %s\nSender: %s", soundID, sender)
        return
    end

    -- A SendMenu.lua direct send always shows as "Direct", regardless of the
    -- fact it physically travels over the same WHISPER channel a
    -- broadcast-to-all-friends send does - see SB:SendSoundToPlayer above.
    local channelLabel = isDirect and "Direct" or (CHANNEL_LABEL[channel] or channel)

    -- Ignore blocking - checked FIRST, before even the raid-admin mute's
    -- own Friend exemption: if either player has the other ignored,
    -- Soundbook communication must not succeed, no exceptions. Our OWN
    -- outbound sends already skip anyone WE have ignored before the
    -- message is sent (see SendToFriends/SendToPlayerSilent/
    -- SB:SendSoundToPlayer) - this is the other half, for a channel-wide
    -- Guild/Raid broadcast (which can't be filtered per-recipient at send
    -- time) or the case where WE have ignored THEM. Rejected before
    -- playback, never recorded to History, and an explicit IGNOREACK
    -- reply lets the sender's aggregate ("Guild received: N (1 blocked by
    -- Ignore)") reflect it, never a normal success-implying ACK. If
    -- instead THEY have ignored US, WoW's own server-level whisper
    -- suppression means this handler is never reached at all for a
    -- WHISPER-based send (Friends/Direct) - that looks like, and is left
    -- as, ordinary unreachable/no-ACK rather than guessed at. A Guild/Raid
    -- channel message is NOT suppressed by ignore at the game level, so it
    -- still reaches us and this same check catches that direction too.
    if SB:IsIgnored(sender) then
        SB:Debug("Remote sound %s from %s ignored (Ignore list).", soundID, sender)
        SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "IGNOREACK" .. SEP .. soundID, "WHISPER", sender)
        return
    end

    -- Raid-admin "mute all" (see the Raid Admin section below) blocks
    -- receiving too, not just sending - silent here (no PrintMuted): the
    -- muted player already got their own chat line the moment the mute
    -- was applied (ApplyRaidOverride), so repeating it on every blocked
    -- sound would be spammy. Mirrors SB:SendSoundToPlayer's own friend
    -- exemption: a DIRECT send from a mutual Friend still gets through,
    -- since that's a private 1:1 action, not the group-context spam Mute
    -- All targets.
    if SB:IsReceiveBlockedByRaid() and not (isDirect and SB:IsFriend(sender)) then
        SB:Debug("Remote sound %s from %s ignored (raid-admin mute all).", soundID, sender)
        return
    end

    -- Individual Mute (Mini Soundbook mute button's right-click dropdown) -
    -- blocks EVERY sound from this one specific person, no exemption (a
    -- deliberate per-PERSON block, unlike the group-context raid mute
    -- above which exempts a direct Friend send). Same MUTEACK reply as
    -- the per-sound mute below, so the sender's "(N muted)" line includes it.
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
        -- The SENDER can see how many recipients had this sound muted, not
        -- just who played it - a small "MUTEACK" reply, same idea as the
        -- regular ACK below for a successful play. Always sent regardless
        -- of THIS player's own notify settings (same as the plain ACK) -
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
        -- reply would make the sender-side feature basically never fire.
        -- The channel WE received it over rides along so the sender can
        -- show "Guild received: ..." etc.
        local ackCode = isDirect and "D" or (CHANNEL_CODE[channel] or "?")
        SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "ACK" .. SEP .. soundID .. SEP .. ackCode, "WHISPER", sender)
    end
end

------------------------------------------------------------------------
-- Forward-compatible payload parsing - a basic PLAY (and ACK) must keep
-- working across Soundbook versions even as optional fields get added
-- over time. Both take a "first segment is the important part, everything
-- after is an optional flag we may or may not recognize" approach rather
-- than an anchored end-of-string pattern, so an unrecognized trailing
-- segment from a newer client is ignored instead of breaking the parse.
------------------------------------------------------------------------

--- PLAY payload: "soundID" or "soundID|D" (or "soundID|D|<future flag>",
--- "soundID|<some other future flag>", ...). Only ever soundID is required;
--- every segment after the first is optional and any we don't recognize
--- is silently ignored rather than rejecting the message. Recognized
--- flags: "D" (direct-send, see SB:SendSoundToPlayer above), "SG"/"SR"
--- (a per-player Guild/Raid recipient-subset whisper, see
--- SendSubsetSilent above) - never both at once from a legitimate sender.
-- @return string soundID, boolean isDirect, string|nil subsetChannel ("GUILD"/"RAID")
local function ParsePlayPayload(payload)
    local soundID, rest = payload:match("^([^|]*)|?(.*)$")
    soundID = soundID or payload
    local isDirect = false
    local subsetChannel = nil
    if rest and rest ~= "" then
        for flag in (rest .. SEP):gmatch("([^|]*)" .. SEP) do
            if flag == "D" then isDirect = true
            elseif flag == "SG" then subsetChannel = "GUILD"
            elseif flag == "SR" then subsetChannel = "RAID"
            end
            -- any other flag: forward-compat no-op.
        end
    end
    return soundID, isDirect, subsetChannel
end

--- ACK payload: "soundID|code" - code is the single-letter channel (see
--- CHANNEL_CODE/CODE_NAME above). A missing/malformed code defaults to "?"
--- (an unknown-channel entry is still useful in the aggregated "received
--- via" list) rather than dropping the whole ACK.
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
--     sender combined - many raid members each individually within their
--     own per-sender limit could still flood the raid together otherwise.
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
--- `mode` ("FRIENDS"/"GUILD"/"RAID"/"DIRECT" - the only values Settings'
--- Send/Receive table ever passes; "PARTY" is not a mode here, only a wire
--- channel RAID's own MODE_CHANNELS entry matches, see above) - disabling
--- a receive channel must reliably drop whatever's already waiting from
--- that channel too, not just block new arrivals.
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
--- existing per-(sender,sound) repeat cooldown (the same lastReceivedFrom
--- table HandlePlayCommand checks/updates at actual play time) - checked
--- BEFORE queueing so an obvious repeat never wastes a queue slot.
local function IsRecentDuplicate(sender, soundID)
    local key = (IdentityKey(sender) or "?") .. "|" .. soundID
    local last = lastReceivedFrom[key]
    if not last then return false end
    local cooldown = tonumber(SB.db.settings.remoteCooldown) or 1.0
    return (GetTime() - last) < cooldown
end

-- `list` is oldest-first (entries are always appended, so index 1 is
-- always the oldest) - must prune from the FRONT and stop at the first
-- remaining entry still within the window; pruning from the back would
-- hit the newest entry first and never remove anything.
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
--- checked BEFORE it's allowed to consume a queue slot or a rate-limit
--- accept credit. Deliberately mirrors (does not replace)
--- HandlePlayCommand's OWN checks - that function still re-checks all of
--- this right before actually playing, since a queued entry can go from
--- valid to invalid while it waits (e.g. muted moments after arriving) -
--- this is purely the "don't let an unplayable one take a slot" half.
--- @return boolean playable, string|nil reason ("unknown"/"raid_blocked"/
---   "muted" when not playable - callers use this to decide whether a
---   rejection notification is warranted, see NotifyIfMuted below)
local function IsPlayableRightNow(soundID, sender, isDirect)
    if not SB.registry[soundID] then return false, "unknown" end
    -- Ignore blocking - checked before EVERYTHING else, including the
    -- raid-mute-all Friend exemption below: absolute, no exceptions. Also
    -- checked here (not just HandlePlayCommand's redundant copy) so a
    -- message from someone we've ignored never burns a queue slot or a
    -- rate-limit accept credit in the first place.
    if SB:IsIgnored(sender) then return false, "ignored" end
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
--- re-validation) call this, so the right local reaction fires from
--- wherever the rejection actually happens.
-- Covers both "muted" (per-sound) and "player_muted" (Individual Mute
-- dropdown) - either way, the SENDER gets a MUTEACK reply so their
-- aggregated "(N muted)" line (see HandleMuteAck) includes it, regardless
-- of THIS player's own notifyMutedAttempts setting (that setting only
-- controls the LOCAL "someone tried to send you a muted sound" line below).
local function NotifyIfMuted(reason, soundID, sender, channel, isDirect)
    if reason == "unknown" then
        -- This is the ACTUAL rejection point for a soundID we don't have
        -- at all - see MaybeShowOutdatedHint's own comment above for why
        -- this specifically means "our own Soundbook might be outdated"
        -- for a Legacy/German Memes id.
        MaybeShowOutdatedHint(soundID)
        return
    end
    if reason == "ignored" then
        -- Fully silent locally (like "raid_blocked" below) - the whole
        -- point of Ignore is that nothing about this person surfaces here
        -- at all, no notifyMutedAttempts-style opt-in. The SENDER still
        -- needs to know, though - their aggregate must show "(N blocked by
        -- Ignore)", never a normal success ACK - so an IGNOREACK reply is
        -- unconditional, same as MUTEACK below.
        SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "IGNOREACK" .. SEP .. soundID, "WHISPER", sender)
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
--- sender currently passes the rate limits, and plays that one - a
--- strictly FIFO-head-only check would let one heavy sender's own item
--- stuck at the front block every OTHER sender's already-eligible sound
--- behind it. FIFO order is still preserved AMONG eligible entries (the
--- earliest-queued eligible one always wins), just no longer a hard
--- blocker for entries that aren't eligible yet. If nothing is eligible,
--- reschedules itself via a ONE-SHOT C_Timer for whichever blocked entry
--- frees up soonest - never a repeating/polling timer, and nothing is
--- scheduled while the queue is empty.
local function ProcessQueue()
    queueTimer = nil
    if #pendingQueue == 0 then return end

    local now = GetTime()
    local earliestWait

    for i, entry in ipairs(pendingQueue) do
        -- Re-validate right before actually playing - something that was
        -- fine when queued (e.g. not yet muted, not yet raid-blocked) may
        -- no longer be by the time its turn comes up. A now-stale entry is
        -- dropped outright, no rate-limit slot spent, then the scan
        -- continues at the same index (nothing shifted forward yet).
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
--- limits above.
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
    -- rejected before ever touching the queue or a rate-limit slot, and
    -- the repeat-cooldown below is deliberately NOT stamped for this
    -- either - see its own comment further down.
    local playable, reason = IsPlayableRightNow(soundID, sender, isDirect)
    if not playable then
        SB:Debug("Remote sound %s from %s not playable right now, never queued.", soundID, sender)
        NotifyIfMuted(reason, soundID, sender, channel, isDirect)
        return
    end

    -- A duplicate of a sound ALREADY waiting in the queue is coalesced
    -- (collapsed) rather than adding a second copy that would just play
    -- the same thing twice in a row once the queue gets to both of them.
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
    -- below) - a sound rejected for being over the rate limit (queue off)
    -- or for the queue being full must not burn either, or a legitimate
    -- retry moments later would incorrectly look like a duplicate/still-
    -- limited even though nothing of this sound got through the first time.
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
-- to SavedVariables (SB.db) - it must never survive past the raid it was
-- set for, and must always fall back to the player's own normal settings
-- on disconnect or any other technical hiccup. Since it's never persisted,
-- a disconnect/reload already guarantees that for free (a fresh Lua state
-- has no override) - the leave-group handler further below only needs to
-- cover the "still connected, but left/got removed from the group" case,
-- which a fresh state wouldn't catch.
------------------------------------------------------------------------

-- Whether *I* currently hold a qualifying role - gates whether AdminPanel.lua
-- shows its icon at all, and exempts me from someone else's "mute all"
-- (see HandleAdminMuteAll below).
function SB:IsRaidAdmin()
    if IsInRaid() then
        -- IsRaidLeader()/IsRaidOfficer() (old, no-argument globals) are not
        -- reliably available on current client builds. UnitIsGroupLeader/
        -- UnitIsGroupAssistant (unit-based) are the stable API, already
        -- used for the party case below, and work identically for a raid unit.
        return (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) and true or false
    elseif IsInGroup() then
        return UnitIsGroupLeader("player") and true or false
    end
    return false
end

-- Whether *I* am specifically the CURRENT leader (not just an assistant) -
-- gates the client-side Mute All/Unmute All send (SB:SendAdminMuteAll/
-- SendAdminUnmuteAll below), same "leader only" rule the receiving side
-- (IsSenderCurrentLeader) enforces, so an assistant's click never goes out
-- looking like it worked only to be silently rejected by every receiver.
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
        -- Compatibility hardening: raid indices aren't guaranteed compact -
        -- scan the full valid range, not just up to the current member count.
        for i = 1, SB.MAX_RAID_MEMBERS do
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
-- qualify). Only the current leader may trigger Mute All/Unmute All, and
-- only the current leader (or the original source of a restriction, see
-- CanSenderModifyOverride below) may override or lift another admin's
-- already-active restriction. Same roster-based spoof-resistance as
-- IsSenderAuthorizedAdmin.
local function IsSenderCurrentLeader(sender)
    local senderKey = IdentityKey(sender)
    if not senderKey then return false end
    if IsInRaid() then
        -- Compatibility hardening: raid indices aren't guaranteed compact -
        -- scan the full valid range, not just up to the current member count.
        for i = 1, SB.MAX_RAID_MEMBERS do
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
--- CURRENT one right now - another already-active admin's restriction
--- must not be overridden/lifted by a lower-privilege admin, only by the
--- SAME source re-issuing/lifting their own, or by the current leader (who
--- can always override/lift anyone's). No active override -> always allowed.
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
-- distinct events:
--   F - the next PLAYER_REGEN_ENABLED (leaving combat) - ANY fight, trash
--       included; a nasty trash pull matters too, not just bosses.
--   B - the next real ENCOUNTER_END specifically - a WoW client event that
--       only fires for a TRACKED BOSS encounter, never trash.
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
        -- own comment); "R" alone stays nil (no timer). UI code showing a
        -- LIVE COUNTDOWN from this (Settings.lua, AdminPanel.lua)
        -- deliberately only does so for 30/60 - a non-nil expiresAt for
        -- F/B is only for the backstop TIMER to fire, not a countdown.
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

local function AdminBroadcastChannel()
    if IsInRaid() then return "RAID" elseif IsInGroup() then return "PARTY" end
    return nil
end

------------------------------------------------------------------------
-- Admin state sync - lets every CURRENT Raid Admin (Lead/Assist/Party
-- Lead) see the same raid moderation state without reopening their panel,
-- and without any permanent polling. The TARGET's own client
-- (SB.raidOverride) is the one source of truth - it self-reports every
-- change (ADMINSTATE) to the raid/party at large, and answers a fresh
-- snapshot request (ADMINSTATEQUERY) whenever an admin's panel needs to
-- reconstruct ground truth (opening it, gaining Lead/Assist, /reload, or
-- joining an already-running raid). An admin ALSO relays their own
-- just-issued command as a lightweight "pending" notice (ADMINPENDING) so
-- other admins can show the same pending -> confirmed transition, not
-- just the one who clicked. All of this is session-only, exactly like
-- SB.raidOverride itself - nothing here ever touches SavedVariables.
------------------------------------------------------------------------

-- Several admins opening their panels within a few seconds of each other
-- must not each independently provoke a fresh broadcast from every single
-- raid member. Only guards QUERY-triggered replies - a genuine state
-- CHANGE (see the RAID_OVERRIDE_CHANGED listener below) always announces
-- immediately regardless.
local ADMIN_STATE_REPLY_DEBOUNCE = 4
local lastStateAnnounceAt = 0

--- Broadcasts THIS client's own current SB.raidOverride (or its absence)
--- to the raid/party - the one function both a spontaneous change and a
--- query reply funnel through, so every receiver only ever needs to parse
--- one payload shape. `force` bypasses the debounce (used for a genuine
--- change - see RAID_OVERRIDE_CHANGED below); a query reply passes false.
local function AnnounceMyRaidAdminState(force)
    local channel = AdminBroadcastChannel()
    if not channel then return end
    local now = GetTime()
    if not force and (now - lastStateAnnounceAt) < ADMIN_STATE_REPLY_DEBOUNCE then return end
    lastStateAnnounceAt = now

    local ov = SB.raidOverride
    if not ov then
        SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "ADMINSTATE" .. SEP .. "CLEAR", channel)
        return
    end
    -- Relative remaining seconds, NOT the absolute GetTime()-based
    -- expiresAt - GetTime() is each client's own local uptime clock,
    -- never comparable across two different players. The receiver
    -- (AdminPanel.lua) computes its own local expiresAt from this
    -- relative value instead.
    local remaining = ov.expiresAt and math.max(0, ov.expiresAt - now) or nil
    local kind = ov.mutedAll and "all" or "send"
    local payload = table.concat({
        "SET", kind, ov.durationCode,
        remaining and string.format("%.0f", remaining) or "-",
        ov.source or "-",
    }, SEP)
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "ADMINSTATE" .. SEP .. payload, channel)
end
SB.AnnounceMyRaidAdminState = AnnounceMyRaidAdminState

--- Parses an incoming ADMINSTATE payload ("CLEAR" or
--- "SET|kind|durationCode|remainingSeconds|source") into the shape
--- AdminPanel.lua wants, and fires ADMIN_STATE_SYNCED with it. This is a
--- SELF-report of the sender's own state, not a command that changes
--- anything here - no sender-authority check needed (same trust level as
--- any other self-reported presence data in this addon, e.g. HELLO).
--- Only ever acted on by a receiver that's itself a current Raid Admin;
--- everyone else has no admin UI to update.
local function HandleAdminState(payload, sender)
    if not SB:IsRaidAdmin() then return end
    local name = NormalizeName(sender) or sender
    if payload == "CLEAR" then
        SB:Fire("ADMIN_STATE_SYNCED", name, nil)
        return
    end
    local kind, code, remainingText, source = payload:match("^SET|([^|]+)|([^|]+)|([^|]+)|(.+)$")
    if not kind or (kind ~= "send" and kind ~= "all") or not VALID_ADMIN_DURATION[code] then return end
    local remaining = tonumber(remainingText)
    SB:Fire("ADMIN_STATE_SYNCED", name, {
        mutedAll = (kind == "all"),
        durationCode = code,
        expiresAt = remaining and (GetTime() + remaining) or nil,
        source = (source ~= "-") and source or nil,
    })
end

--- Sent by an Admin Panel that needs to (re)learn the raid's actual
--- current moderation state - see AnnounceMyRaidAdminState's own comment
--- for when. Every receiving client just re-announces its own state in
--- reply (debounced); no authority check needed on the query itself -
--- it has no side effect beyond that harmless, already-public reply.
local function HandleAdminStateQuery()
    AnnounceMyRaidAdminState(false)
end

function SB:SendAdminStateQuery()
    local channel = AdminBroadcastChannel()
    if not channel then return end
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "ADMINSTATEQUERY" .. SEP, channel)
end

--- Relays "I just sent an admin command" to the other current admins, so
--- THEIR panels can also show pending (not just the one who clicked).
--- `kind` is "mute"/"unmute"/"muteall"/"unmuteall"; `targetName` is "*"
--- for the *all variants (everyone but the admins).
function SB:SendAdminPending(targetName, kind, durationCode)
    if not SB:IsRaidAdmin() then return end
    local channel = AdminBroadcastChannel()
    if not channel then return end
    local payload = table.concat({ targetName or "*", kind, durationCode or "-" }, SEP)
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "ADMINPENDING" .. SEP .. payload, channel)
end

local function HandleAdminPending(payload, sender)
    if not SB:IsRaidAdmin() then return end
    local target, kind, code = payload:match("^([^|]*)|([^|]+)|(.+)$")
    if not kind then return end
    -- Same spoof-resistant authority check the real commands use -
    -- independently verified against MY OWN roster, never trusted from
    -- the message itself. The *all variants require the current leader,
    -- matching HandleAdminMuteAll/HandleAdminUnmuteAll's own rule.
    local isAllKind = (kind == "muteall" or kind == "unmuteall")
    local authorized = isAllKind and IsSenderCurrentLeader(sender) or IsSenderAuthorizedAdmin(sender)
    if not authorized then return end
    SB:Fire("ADMIN_PENDING_SYNCED", NormalizeName(sender) or sender, target, kind, code ~= "-" and code or nil)
end

-- The one place every state CHANGE (set, clear, expiry, combat-end,
-- encounter-end, an admin lifting it, leaving the group, the source
-- losing their role) already funnels through - ClearRaidOverride and
-- ApplyRaidOverride both fire this unconditionally, so subscribing here
-- once covers every transition for free instead of needing a matching
-- announce call at each individual call site.
SB:On("RAID_OVERRIDE_CHANGED", function() AnnounceMyRaidAdminState(true) end)

-- Sends a small confirmation reply for an admin command actually applied
-- on THIS client - the sender must only show a command as successful once
-- the target's own client confirms it, never just optimistically on send.
-- `kind` matches what AdminPanel.lua expects
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
    -- Raid Lead/Assist/Party Lead must never become restricted, through
    -- Mute All OR an individually-targeted mute (an admin could otherwise
    -- ADMINMUTE a fellow admin directly). Same notification shape as Mute
    -- All's own EXEMPT case - still a real, confirmable outcome, just not
    -- an actual restriction.
    if SB:IsRaidAdmin() then
        SB:Print(string.format(
            "|cffaaaaaaA Soundbook mute attempt from %s was ignored - you're exempt as Raid Lead/Assist/Party Lead.|r",
            NormalizeName(sender) or sender))
        SendAdminAck("EXEMPT", sender)
        return
    end
    -- A lower-privilege admin must not be able to override another
    -- admin's already-active restriction - only the original source
    -- re-issuing it, or the current leader, may.
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
    -- A targeted unmute must not weaken an already-active MUTE ALL unless
    -- it comes from that restriction's own source or the current leader -
    -- an ordinary assistant's individual unmute (aimed at what might have
    -- been an EARLIER, individual mute) must never accidentally lift
    -- someone out of a stronger raid-wide restriction.
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
    -- ONLY the current leader may trigger Mute All - an assistant does
    -- not qualify here (still fully able to send targeted, individual
    -- mutes above).
    if not IsSenderCurrentLeader(sender) then
        SB:Debug("Ignoring ADMINMUTEALL from %s - not the current raid/party leader.", sender)
        return
    end
    if SB:IsRaidAdmin() then
        -- Raid Lead/Assist/Party Lead are exempt from "mute all". An
        -- individually-targeted ADMINMUTE can still reach them
        -- (HandleAdminMute above never checks this), just never a blanket
        -- mute-all. Still gets the SAME notification everyone else does,
        -- just phrased as informational (exempt) rather than restrictive,
        -- since nothing is actually applied to them.
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
    -- Other current admins see the same pending -> confirmed transition,
    -- not just the one who clicked.
    SB:SendAdminPending(targetName, "mute", durationCode)
end

function SB:SendAdminUnmute(targetName)
    if not SB:IsRaidAdmin() or not targetName or targetName == "" then return end
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "ADMINUNMUTE" .. SEP, "WHISPER", targetName)
    SB:SendAdminPending(targetName, "unmute")
end

function SB:SendAdminMuteAll(durationCode)
    -- ONLY the current leader, not an assistant - matches
    -- HandleAdminMuteAll's own receiver-side check exactly, so an
    -- assistant's click never goes out looking like it might work only to
    -- be silently rejected by everyone who gets it.
    if not SB:IsCurrentGroupLeader() then return end
    local channel = AdminBroadcastChannel()
    if not channel then return end
    durationCode = durationCode or "F"
    if not VALID_ADMIN_DURATION[durationCode] then return end
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "ADMINMUTEALL" .. SEP .. durationCode, channel)
    SB:SendAdminPending("*", "muteall", durationCode)
end

function SB:SendAdminUnmuteAll()
    if not SB:IsCurrentGroupLeader() then return end
    local channel = AdminBroadcastChannel()
    if not channel then return end
    SB.SendAddonMessage(SB.COMM_PREFIX, SB.PROTOCOL_VERSION .. SEP .. "ADMINUNMUTEALL" .. SEP, channel)
    SB:SendAdminPending("*", "unmuteall")
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
-- fires this on PLAYER_REGEN_ENABLED), trash included - a rough trash pull
-- can matter just as much as a tracked boss encounter.
SB:On("COMBAT_END", function()
    if SB.raidOverride and SB.raidOverride.clearOnCombatEnd then
        ClearRaidOverride("combat_end")
    end
end)

-- Guarantees the override never outlives the raid/party it was set for -
-- the disconnect/reload case is already covered for free (see this
-- section's own opening comment); this specifically catches "still
-- connected, but left or got removed from the group".
local wasInGroup = false
local groupCheckFrame = CreateFrame("Frame")
groupCheckFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
groupCheckFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
groupCheckFrame:SetScript("OnEvent", function()
    local inGroup = IsInGroup() and true or false
    if wasInGroup and not inGroup then
        ClearRaidOverride("leave_group")
    end

    -- A restriction's SOURCE losing their required role (demoted,
    -- leadership passed to someone else) must clear it too, not just the
    -- source physically leaving the group entirely. Checked
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
    IGNOREACK = { WHISPER = true },
    HELLO = { PARTY = true, RAID = true, RAID_LEADER = true, GUILD = true, OFFICER = true, WHISPER = true },
    HELLOACK = { WHISPER = true },
    ANLY = { PARTY = true, RAID = true, RAID_LEADER = true, GUILD = true, OFFICER = true },
    ADMINMUTE = { WHISPER = true }, ADMINUNMUTE = { WHISPER = true }, ADMINACK = { WHISPER = true },
    ADMINMUTEALL = { PARTY = true, RAID = true, RAID_LEADER = true },
    ADMINUNMUTEALL = { PARTY = true, RAID = true, RAID_LEADER = true },
    ADMINSTATE = { PARTY = true, RAID = true, RAID_LEADER = true },
    ADMINSTATEQUERY = { PARTY = true, RAID = true, RAID_LEADER = true },
    ADMINPENDING = { PARTY = true, RAID = true, RAID_LEADER = true },
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

        -- Parsed BEFORE the channel filter - the filter needs to know
        -- isDirect to tell a Direct send apart from a plain Friends-list
        -- broadcast (both travel as WHISPER, see ReceiveAllowedForChannel
        -- above).
        local plainID, isDirect, subsetChannel = ParsePlayPayload(payload)
        if not SB.IsValidSoundID(plainID) then return end
        -- A direct flag is meaningful only on a real whisper. Never let an
        -- arbitrary raid/guild packet claim the friend/direct exemptions.
        isDirect = isDirect and channel == "WHISPER"
        -- Same hardening for a Guild/Raid recipient-SUBSET flag (see
        -- SendSubsetSilent) - only ever honoured on a real whisper, and
        -- never alongside a Direct flag. Once accepted, `channel` is
        -- remapped to the LOGICAL "GUILD"/"RAID" it's standing in for, so
        -- every downstream consumer below (receive gating, queue
        -- priority, ACK code, chat label) treats it exactly like a real
        -- channel-wide broadcast, with zero further special-casing -
        -- explicit requirement: preserve the logical source channel.
        if subsetChannel and channel == "WHISPER" and not isDirect then
            channel = subsetChannel
        end

        -- Channel filter - a disabled "Receive Sounds from" channel
        -- (Direct included) must produce literally nothing on THIS (the
        -- recipient's) side: no playback, no queue entry, no notification,
        -- no chat line, no UI reaction. Only Debug Mode may ever surface
        -- that something was dropped here. Deliberately different from a
        -- per-sound mute (HandlePlayCommand's own notifyMutedAttempts
        -- branch further down), which still may notify locally - turning
        -- off a whole channel is a much stronger "I don't want to know
        -- about this at all" than muting one sound.
        --
        -- The SENDER's side gets a reply too, but deliberately NOT the
        -- same MUTEACK the mute paths use - this is a channel-level
        -- opt-out, not a mute, so it gets its own "RXOFFACK" reply, its
        -- own aggregated count, its own colour, and its own visibility
        -- rule (see HandleRxOffAck - shown to the sender only in Debug
        -- Mode; a normal sender sees nothing here at all).
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
    elseif cmd == "IGNOREACK" then
        -- Same wire shape again ("soundID" only) - a rejection because the
        -- recipient has US ignored (see HandleIgnoreAck). Additive/
        -- backward-compatible the same way: an older client that never
        -- sends this simply never gets counted as ignore-blocked, which is
        -- the correct fallback (it just looks like an ordinary unreachable
        -- recipient instead, never a false Ignore claim).
        if SB.IsValidSoundID(payload) then
            HandleIgnoreAck(payload, sender)
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
        -- the target's client (see SendAdminAck above) - AdminPanel.lua
        -- only shows a command as successful once this arrives, never just
        -- optimistically on send. `payload` is one of
        -- MUTE/UNMUTE/MUTEALL/UNMUTEALL/EXEMPT.
        if VALID_ADMIN_ACK[payload] then
            SB:Fire("ADMIN_ACK_RECEIVED", NormalizeName(sender) or sender, payload)
        end
    elseif cmd == "ADMINSTATE" then
        -- The sender's own current raidOverride (or its absence) - see
        -- the Admin state sync section above.
        HandleAdminState(payload, sender)
    elseif cmd == "ADMINSTATEQUERY" then
        HandleAdminStateQuery()
    elseif cmd == "ADMINPENDING" then
        HandleAdminPending(payload, sender)
    else
        -- Unknown/future command: ignore silently, never execute arbitrary content.
        SB:Debug("Ignoring unknown addon command '%s' from %s", tostring(cmd), tostring(sender))
    end
end

-- Named (not anonymous) purely so the mock harness used in this
-- codebase's own pre-flight testing can reach it (no other addon code
-- ever needs to) - see the scratchpad mock's global frame auto-registration.
local commFrame = CreateFrame("Frame", "SoundbookCommFrame")
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
    -- Fired ONLY on a brand-new discovery, never on the routine lastSeen
    -- refresh an already-known user gets on every recognized message
    -- (that would fire many times a second during normal raid traffic).
    -- This is the one moment a previously-ineligible player can newly
    -- become an eligible Soundbook recipient, which the Mini Soundbook
    -- title needs to reflect live.
    if not existing then
        SB:Fire("KNOWN_USER_CHANGED")
    end
end

-- How long a presence entry is trusted without a fresh HELLO/HELLOACK (or
-- any other recognized message) before it's pruned outright - someone who
-- went offline or hasn't been seen in a long time must not keep appearing
-- as reachable forever. Comfortably longer than the periodic HELLO ping
-- interval (180s, see HELLO_INTERVAL further below - 3x that) so a couple
-- of missed periodic pings in a row (e.g. a brief disconnect) doesn't drop
-- someone who's still actually around.
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
-- "-final7" suffix): the patch number alone was never meant to count as
-- "incompatible", only a genuinely different major.minor line is. nil for
-- anything that doesn't even start with digits (a malformed/unknown version).
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

------------------------------------------------------------------------
-- Online Greetings (Settings -> Multiplayer -> Notifications) - a known
-- Soundbook Friend/Guild member's own offline -> online transition, shown
-- via Announcer.lua's SB:ShowOnlineGreeting. "Does this person even run
-- Soundbook" reuses the existing HELLO-driven knownUsers table above
-- unchanged; what's genuinely new here is the offline/online EDGE
-- detection itself - knownUsers only ever accumulates a lastSeen
-- timestamp, it has no notion of "offline" at all. Built on Blizzard's own
-- real Friends/Guild roster online state instead (the same GetFriendInfo/
-- GetGuildRosterInfo calls SB.ComputeReachablePlayers above already uses),
-- driven purely by the GUILD_ROSTER_UPDATE/FRIENDLIST_UPDATE events WoW
-- already fires on its own - no new outgoing traffic, no polling ticker.
------------------------------------------------------------------------

-- [IdentityKey] = true for every Friend/Guild member CURRENTLY seen
-- online, replaced wholesale on every scan (see ScanPresence below) -
-- anyone previously online but missing from a later scan is implicitly
-- "went offline", so their eventual reappearance reads as a genuine new
-- transition. Deliberately in-memory only, never persisted - a fresh
-- session (login/reload) starting from an empty table, combined with
-- pastInitialSettle below, is exactly what makes the very first scan
-- read as "establishing the baseline", never a wave of announcements.
local onlineState = {}
-- Only true once the post-login settle window has elapsed (see
-- PLAYER_LOGIN below) - guards every transition check so partial roster
-- data still trickling in right after login/reload can never itself look
-- like a burst of "just came online" transitions.
local pastInitialSettle = false

-- Comfortably longer than SendHello's own 5s post-login delay - by the
-- time a genuine transition gets here, this player's own client has had
-- a real chance to send its HELLO and have it land in knownUsers, so a
-- true Soundbook user is never missed purely from event-ordering timing.
local GREETING_VERIFY_DELAY = 7

-- Re-verified here, not trusted from the scan that scheduled it: the
-- player must still be online (a roster blip didn't just flicker true/
-- false/true within a moment) and must now be a CONFIRMED Soundbook user
-- (KnownUserInfo, populated by the HELLO exchange above) before a real
-- greeting fires.
local function VerifyAndFireGreeting(key, name, isFriend, isGuild)
    if not (onlineState[key] and KnownUserInfo(name)) then return end
    local greetingsOn = SB.db and SB.db.settings and SB.db.settings.onlineGreetings
    local playSoundOn = SB.db and SB.db.settings and SB.db.settings.playGreetingSound
    if not greetingsOn and not playSoundOn then return end

    local displayName = (SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(name)) or name
    local soundID = playSoundOn and SB:ResolveGreetingSound(name) or nil

    if greetingsOn then
        local relationship = (isFriend and isGuild) and "Friend + Guild" or (isFriend and "Friend") or "Guild"
        if SB.ShowOnlineGreeting then
            SB:ShowOnlineGreeting(displayName, relationship, soundID)
        end
    elseif soundID then
        -- Online Greetings itself is off, but Play Greeting Sound is on
        -- and there IS a sound to play - explicit requirement: still show
        -- the Announcer as required playback feedback, but never the
        -- standalone "PLAYERX IS ONLINE" framing. Plays through the exact
        -- same SELF-only path any other local trigger uses, so it reads
        -- as an entirely ordinary sound play, nothing greeting-specific.
        SB:TriggerSound(soundID, "SELF")
    end
end

-- One full pass over currently-ONLINE Friends + Guild members, diffed
-- against the previous pass's own onlineState to find genuine offline ->
-- online transitions - never scans or tracks anyone offline; their
-- absence from this pass IS what "offline" means here.
local function ScanPresence()
    if not SB.db then return end
    local seen = {} -- [IdentityKey] = { name, isFriend, isGuild }

    local n = SB.GetNumFriends()
    for i = 1, n do
        local name, connected = SB.GetFriendInfoByIndex(i)
        if name and connected and not IsSelf(name) then
            local key = IdentityKey(name)
            if key then
                seen[key] = seen[key] or { name = name }
                seen[key].isFriend = true
            end
        end
    end

    if IsInGuild() and GetNumGuildMembers then
        for i = 1, GetNumGuildMembers() do
            local fullName, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
            if fullName and isOnline and not IsSelf(fullName) then
                local key = IdentityKey(fullName)
                if key then
                    seen[key] = seen[key] or { name = fullName }
                    seen[key].isGuild = true
                end
            end
        end
    end

    if pastInitialSettle then
        for key, info in pairs(seen) do
            if not onlineState[key] then
                -- Own local bindings per iteration (Lua's for-in gives
                -- each pass a fresh `key`/`info`), so the deferred closure
                -- below always captures the right player, never the last
                -- one iterated.
                local capturedName, capturedFriend, capturedGuild = info.name, info.isFriend, info.isGuild
                C_Timer.After(GREETING_VERIFY_DELAY, function()
                    VerifyAndFireGreeting(key, capturedName, capturedFriend, capturedGuild)
                end)
            end
        end
    end

    local nextState = {}
    for key in pairs(seen) do nextState[key] = true end
    onlineState = nextState
end

local presenceEventFrame = CreateFrame("Frame", "SoundbookPresenceFrame")
presenceEventFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
presenceEventFrame:RegisterEvent("FRIENDLIST_UPDATE")
presenceEventFrame:SetScript("OnEvent", function()
    local ok, err = pcall(ScanPresence)
    if not ok then SB:Debug("Presence scan error: %s", tostring(err)) end
end)

SB:On("PLAYER_LOGIN", function()
    -- Every scan before this fires still updates onlineState (so the
    -- picture is accurate once settled), it just can never trigger a
    -- transition check yet - explicit requirement: never announce the
    -- initial roster after login/reload/first sync.
    C_Timer.After(8, function()
        pastInitialSettle = true
        ScanPresence()
    end)
end)

------------------------------------------------------------------------
-- Greeting Sound selection - the sound a given player has sent YOU most
-- often, tie-broken by most recently received. Purely local, never the
-- anonymous community Analytics system. BumpGreetingStat hooks the
-- EXISTING REMOTE_SOUND_PLAYED event (fired only once SB:PlaySound has
-- already succeeded - past the Ignore-list, per-sound mute, and Raid
-- Admin checks) so a muted/rejected/invalid incoming sound can never
-- build statistics; nothing here duplicates that gating.
------------------------------------------------------------------------

local function BumpGreetingStat(senderKey, soundID)
    if not (senderKey and soundID and SB.db) then return end
    SB.db.greetingStats = SB.db.greetingStats or {}
    local perSound = SB.db.greetingStats[senderKey]
    if not perSound then
        perSound = {}
        SB.db.greetingStats[senderKey] = perSound
    end
    local entry = perSound[soundID]
    if not entry then
        entry = { count = 0, lastReceived = 0 }
        perSound[soundID] = entry
    end
    entry.count = (entry.count or 0) + 1
    entry.lastReceived = time()
end

SB:On("REMOTE_SOUND_PLAYED", function(soundID, sender, channelLabel, senderKey)
    BumpGreetingStat(senderKey, soundID)
end)

--- The sound `name` has sent this player most often (ties broken by most
--- recently received), or nil if there's no history for them at all - "no
--- history = no Greeting Sound", explicit requirement, never a fallback.
function SB:GetGreetingSoundFor(name)
    local key = IdentityKey(name)
    local perSound = key and SB.db and SB.db.greetingStats and SB.db.greetingStats[key]
    if type(perSound) ~= "table" then return nil end
    local bestID, bestCount, bestLast = nil, 0, 0
    for soundID, entry in pairs(perSound) do
        if SB.registry[soundID] and type(entry) == "table" then
            local count, last = entry.count or 0, entry.lastReceived or 0
            if count > bestCount or (count == bestCount and last > bestLast) then
                bestID, bestCount, bestLast = soundID, count, last
            end
        end
    end
    return bestID
end

------------------------------------------------------------------------
-- Fallback Greeting Sound - a Soundbook Friend/Guild member with NO
-- received-sound history yet still gets a Greeting Sound, randomly picked
-- once from our own shortest favourites and then persisted so every later
-- login reuses the same one, rather than randomizing every time. A real
-- received-history entry (SB:GetGreetingSoundFor above) always takes
-- priority the moment it exists - see SB:ResolveGreetingSound below.
------------------------------------------------------------------------

local FALLBACK_POOL_SIZE = 10

-- Favourited sounds with a KNOWN duration (SB.registry[id].durationSeconds -
-- explicit per-entry, precomputed, or already learned this session/a past
-- one; Reuse existing duration data and duration-learning infrastructure,
-- explicit requirement - never guessed here), not currently muted, sorted
-- shortest-first, capped at the 10 shortest. Only ever computed when a
-- fallback actually needs to be (re-)assigned - no periodic scan.
local function ShortestFavouritesPool()
    local pool = {}
    local seen = {}
    for _, soundID in pairs(SB:GetFavourites()) do
        if not seen[soundID] then
            seen[soundID] = true
            local info = SB.registry[soundID]
            local saved = SB:GetSoundSaved(soundID)
            if info and info.durationSeconds and not (saved and saved.muted) then
                table.insert(pool, soundID)
            end
        end
    end
    table.sort(pool, function(a, b)
        return SB.registry[a].durationSeconds < SB.registry[b].durationSeconds
    end)
    while #pool > FALLBACK_POOL_SIZE do
        table.remove(pool)
    end
    return pool
end

-- A persisted fallback is only ever trusted after re-checking it still
-- exists and is playable right now - a sound removed from the registry
-- (can't happen mid-session, but a SavedVariables edit/downgrade could
-- leave a stale id) or since muted is invalid and must be replaced, never
-- just silently skipped. Removing the sound from FAVOURITES alone does NOT
-- invalidate an already-assigned fallback - explicit requirement, the
-- favourite list is only ever consulted when (re-)assigning.
local function ValidFallback(soundID)
    if not soundID then return false end
    local info = SB.registry[soundID]
    if not info then return false end
    local saved = SB:GetSoundSaved(soundID)
    if saved and saved.muted then return false end
    return true
end

--- The persisted fallback Greeting Sound for `name` - their existing
--- assignment if it's still valid, otherwise a fresh one randomly chosen
--- from our current shortest-favourites pool (persisted immediately so the
--- SAME sound is reused on every later login). nil only when no eligible
--- favourite exists at all right now.
function SB:GetGreetingFallbackSoundFor(name)
    local key = IdentityKey(name)
    if not (key and SB.db) then return nil end
    SB.db.greetingFallbackSounds = SB.db.greetingFallbackSounds or {}

    local existing = SB.db.greetingFallbackSounds[key]
    if ValidFallback(existing) then
        return existing
    end

    local pool = ShortestFavouritesPool()
    if #pool == 0 then
        SB.db.greetingFallbackSounds[key] = nil
        return nil
    end

    local chosen = pool[math.random(#pool)]
    SB.db.greetingFallbackSounds[key] = chosen
    return chosen
end

--- Full Greeting Sound resolution for `name`, in priority order: (1) the
--- sound they've actually sent US most often (real received history always
--- wins the moment it exists), (2) their persisted random fallback from our
--- shortest favourites. nil only when neither is available.
function SB:ResolveGreetingSound(name)
    return SB:GetGreetingSoundFor(name) or SB:GetGreetingFallbackSoundFor(name)
end

-- Manual test hook (/sb testgreeting <name>, Core.lua) - previews the
-- Online Greeting banner for a name of your choosing without needing a
-- second real Soundbook client to actually go offline/online. Reuses the
-- exact same settings truth table and rendering path a real detected
-- transition uses (SB:ShowOnlineGreeting/SB:GetGreetingSoundFor) - only
-- the presence edge-detection and the "confirmed Soundbook user" check are
-- skipped, since a test name has neither. Relationship is read from your
-- REAL current Friends/Guild roster whenever the name matches someone on
-- it, so a real name previews its real "Friend"/"Guild"/"Friend + Guild"
-- label and (if Play Greeting Sound is on) its real Greeting Sound
-- history; an unmatched name just defaults to "Friend" for preview
-- purposes.
function SB:SimulateOnlineGreeting(name)
    name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        SB:Print("Usage: /sb testgreeting <name>")
        return
    end

    local key = IdentityKey(name)
    local isFriend, isGuild = false, false

    local n = SB.GetNumFriends()
    for i = 1, n do
        local friendName, connected = SB.GetFriendInfoByIndex(i)
        if friendName and connected and IdentityKey(friendName) == key then
            isFriend = true
        end
    end
    if IsInGuild() and GetNumGuildMembers then
        for i = 1, GetNumGuildMembers() do
            local fullName, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
            if fullName and isOnline and IdentityKey(fullName) == key then
                isGuild = true
            end
        end
    end
    local relationship = (isFriend and isGuild) and "Friend + Guild" or (isGuild and "Guild") or "Friend"

    local greetingsOn = SB.db and SB.db.settings and SB.db.settings.onlineGreetings
    local playSoundOn = SB.db and SB.db.settings and SB.db.settings.playGreetingSound
    local displayName = (SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(name)) or name
    local soundID = playSoundOn and SB:ResolveGreetingSound(name) or nil
    local soundName = soundID and SB.GetSoundDisplayName and SB:GetSoundDisplayName(soundID)

    -- Explicit about WHY there's no sound in every case - not knowing the
    -- typed name is never the reason (the fallback pool works for ANY
    -- name, real or made up); "Play Greeting Sound" being off, or genuinely
    -- no history/eligible favourite, are the only two possibilities, and
    -- a tester should never have to guess which.
    local soundNote
    if soundName then
        soundNote = " - Greeting Sound: " .. soundName
    elseif not playSoundOn then
        soundNote = " - Play Greeting Sound is OFF in Settings, so no sound will play regardless of history/fallback"
    else
        soundNote = " - no Greeting Sound available (no history, no eligible favourite)"
    end
    SB:Print(string.format("Simulating Online Greeting for %s (%s)%s", displayName, relationship, soundNote))

    if not greetingsOn and not playSoundOn then
        SB:Print("Online Greetings and Play Greeting Sound are both off - nothing would show for a real transition either.")
        return
    end

    if greetingsOn then
        if SB.ShowOnlineGreeting then
            SB:ShowOnlineGreeting(displayName, relationship, soundID)
        end
    elseif soundID then
        SB:TriggerSound(soundID, "SELF")
    end
end

-- A remote sound actually played for you - the base "did I miss
-- something" notification.
--
-- A single broadcast can reach us over SEVERAL enabled channels at once
-- (e.g. the sender has both Raid AND Guild broadcast checked, and we're
-- in both groups with them). HandleIncomingPlay above already recognizes
-- these as the same broadcast (see its duplicate/priority-upgrade
-- handling, SourcePriority - Direct > Friends > Guild > Raid > Party) and
-- re-fires REMOTE_SOUND_PLAYED with the better label whenever a
-- higher-priority copy arrives - that upgrade is meant for the OTHER
-- listeners on this same event (History, the Announcement Bar, the
-- playing-state highlight further up in this file/UI.lua), which all
-- still want the best/final label as soon as it's known. The chat line
-- itself, though, should only ever print once per broadcast.
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
        -- Engaging a receive-mute must reliably drop whatever's still
        -- waiting in the incoming queue too, not just stop NEW sounds from
        -- being accepted - a queued sound that arrived moments before the
        -- mute would otherwise still play once its turn came up.
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
-- Individual Mute - reached from the Mini Soundbook's Quick Options menu
-- (MutePlayers.lua's own panel, see Announcer.lua's OpenMutePlayersMenu
-- call). Separate from the
-- global receive-mute above (blocks EVERYONE) and from a per-sound mute
-- (blocks one SOUND from everyone) - this blocks one specific PERSON's
-- sounds, all of them, only from them.
------------------------------------------------------------------------

local PLAYER_MUTE_SECONDS = 60 * 60 -- one left-click's worth (60 minutes)
local PLAYER_MUTE_MAX_SECONDS = 600 * 60 -- hard cap, 600 minutes (10h) total

--- The old, pre-realm-aware mutedPlayers key for `name` (plain NormalizeName,
--- no realm), or nil if `name` already carries an explicit realm (so it was
--- never storable under the old shape to begin with). One shared definition
--- of "what counts as a legacy mutedPlayers key" for every reader/writer
--- below, so the compatibility rule can't drift between them.
local function GetLegacyMuteKey(name)
    return type(name) == "string" and not name:find("-", 1, true) and NormalizeName(name) or nil
end

--- True (and cleans up the entry) if `name` is currently muted and that
--- mute hasn't expired yet. `time()`, not GetTime(), matching
--- receiveMute's own expiresAt above - must survive a /reload.
function SB:IsPlayerMuted(name)
    local key = IdentityKey(name)
    if not key then return false end
    local muted = SB.db.settings.mutedPlayers
    local legacyKey = GetLegacyMuteKey(name)
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
    local legacyKey = GetLegacyMuteKey(name)
    local expiresAt = SB.db.settings.mutedPlayers[key] or (legacyKey and SB.db.settings.mutedPlayers[legacyKey])
    return expiresAt and math.max(0, expiresAt - time()) or nil
end

--- One left-click's worth - STACKS on top of whatever time is already
--- left (not reset to a flat 60 minutes), so repeated clicks add up
--- rather than each one just re-setting the same duration.
function SB:MutePlayerFor(name, seconds)
    local key = IdentityKey(name)
    if not key then return end
    seconds = seconds or PLAYER_MUTE_SECONDS
    local muted = SB.db.settings.mutedPlayers
    local now = time()
    local legacyKey = GetLegacyMuteKey(name)
    local existing = muted[key] or (legacyKey and muted[legacyKey])
    local base = (existing and existing > now) and existing or now
    -- Hard cap at 600 minutes total, even if the player already had most
    -- of that stacked up from earlier clicks - clamps the RESULT, not
    -- each individual click, so one click that would push past the cap
    -- just tops out there instead of being silently ignored.
    muted[key] = math.min(base + seconds, now + PLAYER_MUTE_MAX_SECONDS)
    if legacyKey and legacyKey ~= key then muted[legacyKey] = nil end
    SB:Fire("PLAYER_MUTE_CHANGED", key)
end

--- Right-click on a person in the mute panel - clears their timer/mute
--- entirely, immediately (not just letting it run out).
function SB:UnmutePlayer(name)
    local key = IdentityKey(name)
    if not key then return end
    local legacyKey = GetLegacyMuteKey(name)
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
        -- (Settings.lua, Announcer.lua's own indicators) needs to know the
        -- mute carried over from before this reload/restart.
        SB:Fire("RECEIVE_MUTE_CHANGED")
    end
end)
