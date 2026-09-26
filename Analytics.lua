-- Analytics.lua
--
-- Anonymous, opt-out-only, per-sound usage analytics ("who plays/favourites/
-- mutes what, how much"), synced directly between Soundbook clients you're
-- actually in contact with (guild/party/raid - no multi-hop relay in this
-- version, see the file-level comment further down on that scope decision).
--
-- PRIVACY: only ever stores/transmits a random per-installation NodeID
-- (SB.db.analytics.nodeID) - never a character name, GUID, realm, guild
-- name or BattleTag. The WHISPER/GUILD/RAID/PARTY sender name WoW hands us
-- on receipt is used ONLY to route the reply-less broadcast; it is never
-- written into an analytics record or kept associated with one. "My Stats"
-- in the UI only ever reads records whose nodeID == our own - there is no
-- way, anywhere in this file, to turn another node's ID back into a player
-- identity.
--
-- DATA MODEL (SB.db.analytics):
--   nodeID          - persistent, random, account-wide (SavedVariables here
--                      already IS account-wide - no SavedVariablesPerCharacter
--                      in the .toc - so this needs no extra plumbing).
--   schemaVersion    - bumped only if the STORED shape changes incompatibly.
--   records[soundID][nodeID] = {
--       revision, totalPlays, sessionsUsed, lastUsed (time() epoch),
--       favourite (bool), personalMute (bool),
--       plays7d, plays30d, playsPrev7d (rolling counters, recomputed from
--       OUR OWN daily buckets for our own node; carried through as-is for
--       records that arrived from other nodes),
--   }
--   dailyBuckets[soundID][YYYYMMDD] = playCount
--       LOCAL ONLY, never transmitted (see NETWORK PROTOCOL below) -
--       pruned to ~35 days. This is what "plays7d/plays30d/playsPrev7d"
--       above get recomputed from for OUR OWN node's record.
--
-- DEDUPLICATION / REVISION: every mutation to OUR OWN node's record for a
-- soundID increments that record's `revision` by 1. A remote record is only
-- ever accepted if `incoming.revision > known.revision` (or no known record
-- exists yet) - see AcceptRemoteRecord. Since the exact same message can
-- reach a client any number of times (or out of order) via more than one
-- channel/relay hop, and this check is the ONLY thing that ever writes a
-- remote record, replaying the same data any number of times, in any order,
-- can never double-count a play/session/favourite/mute - the record is
-- simply overwritten with itself or ignored, never added to.
--
-- NETWORK PROTOCOL / SYNC SCOPE (explicit decision, confirmed with the
-- user before implementing): this version only exchanges records directly
-- with whoever your OWN broadcasts already reach (guild/raid/party, same
-- channels HELLO already pings) - a client never re-transmits a record it
-- received FROM someone else on behalf of that other node. That means two
-- clients who are never simultaneously in the same guild/group will never
-- see each other's data, even indirectly - full store-and-forward relay
-- (A->B->C->A propagation across peers who never overlap) was explicitly
-- scoped OUT of this pass as a separate, larger follow-up. The dedup/
-- revision logic above is already fully relay-safe FOR WHEN that's added
-- later - it just isn't exercised yet, since nothing relays.
--
-- Sync is dirty-queue + throttled, never one packet per play: a play/
-- favourite/mute change marks that (soundID, our nodeID) pair dirty; a
-- ticker sends a handful of dirty records at a time, spaced out, plus a
-- much slower full-resync ticker that eventually re-shares everything we
-- know (so a client that joins the guild later still catches up, without
-- needing a real pull/digest handshake - a known simplification, see the
-- README-style summary at the end of this pass).

local ADDON_NAME, SB = ...

------------------------------------------------------------------------
-- NodeID
------------------------------------------------------------------------

local NODE_ID_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

local function GenerateNodeID()
    local parts = {}
    for i = 1, 10 do
        local idx = math.random(1, #NODE_ID_CHARS)
        parts[i] = NODE_ID_CHARS:sub(idx, idx)
    end
    return table.concat(parts)
end

function SB.Analytics_NodeID()
    return SB.db.analytics and SB.db.analytics.nodeID
end

------------------------------------------------------------------------
-- Storage scaffolding - safe to call any time, idempotent.
------------------------------------------------------------------------

local ANALYTICS_SCHEMA_VERSION = 1
local BUCKET_RETENTION_DAYS = 35

local function EnsureDB()
    if not SB.db then return nil end
    if not SB.db.analytics then
        SB.db.analytics = {
            nodeID = GenerateNodeID(),
            schemaVersion = ANALYTICS_SCHEMA_VERSION,
            records = {},
            dailyBuckets = {},
        }
    end
    local a = SB.db.analytics
    if not a.nodeID or a.nodeID == "" then a.nodeID = GenerateNodeID() end
    a.schemaVersion = a.schemaVersion or ANALYTICS_SCHEMA_VERSION
    a.records = a.records or {}
    a.dailyBuckets = a.dailyBuckets or {}
    return a
end

-- Enabled by default (explicit decision, confirmed with the user) - the
-- shared tag system (Trending/Popular/Legendary/...) depends on a wide
-- community data pool, so this is deliberately NOT exposed as a Settings
-- checkbox (would invite casual opt-outs that thin the pool for everyone).
-- A single settings flag still exists for a player who deliberately wants
-- OUT entirely (`/sb analytics off`), without touching SavedVariables by
-- hand. Existing collected data is left in place either way (turning it
-- back on doesn't lose history); only future collection/sync stops.
local function IsEnabled()
    return SB.db and SB.db.settings and SB.db.settings.analyticsEnabled ~= false
end
SB.Analytics_IsEnabled = IsEnabled

------------------------------------------------------------------------
-- Session tracking - runtime-only, never persisted. One random ID per
-- addon load, used purely to dedupe "sessionsUsed" (a sound played 5 times
-- in one sitting is still only ONE session for that sound), never sent
-- over the network on its own.
------------------------------------------------------------------------

local currentSessionID = GenerateNodeID()
local sessionSeenSounds = {} -- [soundID] = true, cleared only by a fresh addon load

------------------------------------------------------------------------
-- Daily buckets (local-only) + rolling window recompute
------------------------------------------------------------------------

local function TodayKey()
    return date("%Y%m%d")
end

local function DayKeyOffset(daysAgo)
    return date("%Y%m%d", time() - daysAgo * 86400)
end

local function AddToBucket(soundID, amount)
    local a = EnsureDB()
    if not a then return end
    a.dailyBuckets[soundID] = a.dailyBuckets[soundID] or {}
    local key = TodayKey()
    a.dailyBuckets[soundID][key] = (a.dailyBuckets[soundID][key] or 0) + amount
end

-- Sums a sound's own daily buckets over the last `days` days (today
-- inclusive, so days=7 covers today and the 6 days before it).
local function SumBucketRange(soundID, daysBack, daysForward)
    local a = EnsureDB()
    if not a or not a.dailyBuckets[soundID] then return 0 end
    local buckets = a.dailyBuckets[soundID]
    local total = 0
    for d = daysForward, daysBack - 1 do
        local key = DayKeyOffset(d)
        total = total + (buckets[key] or 0)
    end
    return total
end

-- Drops any daily bucket entry older than BUCKET_RETENTION_DAYS - run
-- once per login, not on a timer (cheap, and buckets only ever change once
-- a day at most).
local function PruneBuckets()
    local a = EnsureDB()
    if not a then return end
    local cutoff = tonumber(DayKeyOffset(BUCKET_RETENTION_DAYS))
    for soundID, buckets in pairs(a.dailyBuckets) do
        for key in pairs(buckets) do
            if (tonumber(key) or 0) < cutoff then
                buckets[key] = nil
            end
        end
        if not next(buckets) then
            a.dailyBuckets[soundID] = nil
        end
    end
end

------------------------------------------------------------------------
-- Dirty queue + sync scheduling (defined before the record helpers below,
-- which mark entries dirty)
------------------------------------------------------------------------

local dirtyKeys = {}    -- [soundID] = true - our own node's record needs (re)sending
local dirtyOrder = {}   -- soundID list, oldest-dirty-first, for round-robin sending

local function MarkDirty(soundID)
    if not dirtyKeys[soundID] then
        dirtyKeys[soundID] = true
        table.insert(dirtyOrder, soundID)
    end
end

------------------------------------------------------------------------
-- Own-record mutation helpers - each bumps revision and marks dirty.
------------------------------------------------------------------------

local function EnsureOwnRecord(soundID)
    local a = EnsureDB()
    if not a then return nil end
    a.records[soundID] = a.records[soundID] or {}
    local rec = a.records[soundID][a.nodeID]
    if not rec then
        rec = {
            revision = 0, totalPlays = 0, sessionsUsed = 0, lastUsed = 0,
            favourite = false, personalMute = false,
            plays7d = 0, plays30d = 0, playsPrev7d = 0,
        }
        a.records[soundID][a.nodeID] = rec
    end
    return rec
end

local function RecomputeRolling(soundID, rec)
    rec.plays7d = SumBucketRange(soundID, 7, 0)
    rec.plays30d = SumBucketRange(soundID, 30, 0)
    rec.playsPrev7d = SumBucketRange(soundID, 14, 7)
end

--- Called from Communication.lua's HandleAck/HandleMuteAck, ONLY once a
--- real ack comes back from another player's client confirming they
--- actually received the sound (played or muted it - either way, proof a
--- real other Soundbook processed it). NOT called on the mere local
--- trigger anymore (a purely local/self play, or a send nobody was around
--- to receive, never gets an ack, and so never reaches here) - explicit
--- requirement: this is a multiplayer soundbook, its statistics must only
--- ever reflect genuine sender-AND-recipient social interactions.
function SB:AnalyticsRecordPlay(soundID)
    if not IsEnabled() then return end
    local ok, err = pcall(function()
        local rec = EnsureOwnRecord(soundID)
        if not rec then return end
        rec.totalPlays = rec.totalPlays + 1
        rec.lastUsed = time()
        if not sessionSeenSounds[soundID] then
            sessionSeenSounds[soundID] = true
            rec.sessionsUsed = rec.sessionsUsed + 1
        end
        AddToBucket(soundID, 1)
        RecomputeRolling(soundID, rec)
        rec.revision = rec.revision + 1
        MarkDirty(soundID)
    end)
    if not ok then SB:Debug("Analytics: RecordPlay failed: %s", tostring(err)) end
end

--- Called from Favorites.lua's AddFavourite/RemoveFavourite.
function SB:AnalyticsSetFavourite(soundID, isFavourite)
    if not IsEnabled() then return end
    local ok, err = pcall(function()
        local rec = EnsureOwnRecord(soundID)
        if not rec then return end
        local newVal = isFavourite and true or false
        if rec.favourite == newVal then return end -- no real change, don't burn a revision
        rec.favourite = newVal
        rec.revision = rec.revision + 1
        MarkDirty(soundID)
    end)
    if not ok then SB:Debug("Analytics: SetFavourite failed: %s", tostring(err)) end
end

--- Called from EditWindow.lua when a sound's personal mute is saved.
function SB:AnalyticsSetPersonalMute(soundID, isMuted)
    if not IsEnabled() then return end
    local ok, err = pcall(function()
        local rec = EnsureOwnRecord(soundID)
        if not rec then return end
        local newVal = isMuted and true or false
        if rec.personalMute == newVal then return end
        rec.personalMute = newVal
        rec.revision = rec.revision + 1
        MarkDirty(soundID)
    end)
    if not ok then SB:Debug("Analytics: SetPersonalMute failed: %s", tostring(err)) end
end

------------------------------------------------------------------------
-- Wire encode/decode - SEP="|" throughout, matching every other message
-- type in Communication.lua. soundID is the LAST field specifically so an
-- unexpected "|" inside a (user-renamed) sound name can't desync the
-- fields ahead of it - same "tail field absorbs the rest" idea Communication.
-- lua's own PLAY/ACK payload parsing already relies on.
------------------------------------------------------------------------

local WIRE_SEP = "|"

local function EncodeRecord(soundID, nodeID, rec)
    return table.concat({
        nodeID,
        rec.revision,
        rec.totalPlays,
        rec.sessionsUsed,
        rec.favourite and "1" or "0",
        rec.personalMute and "1" or "0",
        math.floor(rec.lastUsed or 0),
        rec.plays7d or 0,
        rec.plays30d or 0,
        rec.playsPrev7d or 0,
        soundID,
    }, WIRE_SEP)
end

-- Sanity limits against a corrupt or hostile payload - generous enough for
-- any real usage pattern, small enough to reject nonsense.
local MAX_REASONABLE_COUNT = 5000000
local MAX_NODE_ID_LEN = 16
local MAX_SOUND_ID_LEN = 160

local function DecodeRecord(payload)
    if type(payload) ~= "string" or payload == "" or #payload > 240 then return nil end
    local nodeID, revision, totalPlays, sessions, fav, mute, lastUsed, p7, p30, pPrev7, soundID =
        payload:match("^([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|([^|]+)|(.+)$")
    if not nodeID then return nil end
    if #nodeID == 0 or #nodeID > MAX_NODE_ID_LEN then return nil end
    if #soundID == 0 or #soundID > MAX_SOUND_ID_LEN then return nil end
    if fav ~= "0" and fav ~= "1" then return nil end
    if mute ~= "0" and mute ~= "1" then return nil end

    revision = tonumber(revision)
    totalPlays = tonumber(totalPlays)
    sessions = tonumber(sessions)
    lastUsed = tonumber(lastUsed)
    p7 = tonumber(p7)
    p30 = tonumber(p30)
    pPrev7 = tonumber(pPrev7)
    if not (revision and totalPlays and sessions and lastUsed and p7 and p30 and pPrev7) then return nil end
    if revision < 0 or revision > MAX_REASONABLE_COUNT then return nil end
    if totalPlays < 0 or totalPlays > MAX_REASONABLE_COUNT then return nil end
    if sessions < 0 or sessions > MAX_REASONABLE_COUNT then return nil end
    if p7 < 0 or p30 < 0 or pPrev7 < 0 or p7 > MAX_REASONABLE_COUNT or p30 > MAX_REASONABLE_COUNT or pPrev7 > MAX_REASONABLE_COUNT then
        return nil
    end
    -- A little slack for clock skew between two real players' clients;
    -- still rejects obviously bogus (far future/negative) timestamps.
    if lastUsed < 0 or lastUsed > time() + 3600 then lastUsed = time() end

    return {
        nodeID = nodeID,
        soundID = soundID,
        revision = revision,
        totalPlays = totalPlays,
        sessionsUsed = sessions,
        favourite = fav == "1",
        personalMute = mute == "1",
        lastUsed = lastUsed,
        plays7d = p7,
        plays30d = p30,
        playsPrev7d = pPrev7,
    }
end

------------------------------------------------------------------------
-- Remote merge - THE dedup gate. Never called for our own node's records.
------------------------------------------------------------------------

local function AcceptRemoteRecord(decoded)
    local a = EnsureDB()
    if not a then return end
    if decoded.nodeID == a.nodeID then return end -- never let a relayed copy of OUR OWN record overwrite itself oddly

    -- Explicit fix: ignore a record for a soundID we don't even have
    -- anymore (most commonly a friend on an older Soundbook version still
    -- syncing stats for a since-renamed/removed sound, e.g. the pre-2.3.0
    -- "Default::..." ids after the Legacy/German Memes category split).
    -- Used to be stored anyway and left for the next PruneOrphanedRecords
    -- pass to clean up - but that only runs once per real login (not per
    -- /reload), so a single stray sync minutes into a session could keep
    -- resurrecting an orphaned row indefinitely, making it look like
    -- pruning never worked at all even though it briefly did.
    if not SB.registry[decoded.soundID] then return end

    a.records[decoded.soundID] = a.records[decoded.soundID] or {}
    local known = a.records[decoded.soundID][decoded.nodeID]
    if known and known.revision >= decoded.revision then
        return -- stale or duplicate - the whole point of the revision check
    end

    a.records[decoded.soundID][decoded.nodeID] = {
        revision = decoded.revision,
        totalPlays = decoded.totalPlays,
        sessionsUsed = decoded.sessionsUsed,
        favourite = decoded.favourite,
        personalMute = decoded.personalMute,
        lastUsed = decoded.lastUsed,
        plays7d = decoded.plays7d,
        plays30d = decoded.plays30d,
        playsPrev7d = decoded.playsPrev7d,
    }
    SB:Fire("ANALYTICS_UPDATED")
end

--- Called by Communication.lua's OnAddonMessage for cmd == "ANLY". Never
--- allowed to raise - a malformed/hostile payload must never affect
--- playback or any other Soundbook feature (explicit requirement).
function SB:AnalyticsHandleIncoming(payload)
    if not IsEnabled() then return end
    local ok, err = pcall(function()
        local decoded = DecodeRecord(payload)
        if decoded then AcceptRemoteRecord(decoded) end
    end)
    if not ok then SB:Debug("Analytics: HandleIncoming failed: %s", tostring(err)) end
end

------------------------------------------------------------------------
-- Outgoing sync - dirty queue (fast, small batches) + slow full resync.
------------------------------------------------------------------------

local function BroadcastPayload(payload)
    local text = SB.PROTOCOL_VERSION .. "|ANLY|" .. payload
    if IsInGuild() then SB.SendAddonMessage(SB.COMM_PREFIX, text, "GUILD") end
    if IsInRaid() then
        SB.SendAddonMessage(SB.COMM_PREFIX, text, "RAID")
    elseif IsInGroup() then
        SB.SendAddonMessage(SB.COMM_PREFIX, text, "PARTY")
    end
end

local DIRTY_BATCH_SIZE = 3
local DIRTY_SYNC_INTERVAL = 45   -- seconds
local FULL_RESYNC_INTERVAL = 600 -- seconds - eventually reaches a client that joined later
local dirtyStartTimer, fullStartTimer
local dirtySyncTicker, fullSyncTicker
local analyticsLoginReady = false

local function SendDirtyBatch()
    if not IsEnabled() then return end
    local a = EnsureDB()
    if not a then return end
    if #dirtyOrder == 0 then return end
    if not (IsInGuild() or IsInGroup()) then return end -- nobody to send to right now

    local sent = 0
    while sent < DIRTY_BATCH_SIZE and #dirtyOrder > 0 do
        local soundID = table.remove(dirtyOrder, 1)
        dirtyKeys[soundID] = nil
        local rec = a.records[soundID] and a.records[soundID][a.nodeID]
        if rec then
            local ok, payload = pcall(EncodeRecord, soundID, a.nodeID, rec)
            if ok and payload and #payload <= 240 then
                BroadcastPayload(payload)
                sent = sent + 1
            end
        end
    end
end

--- Re-marks every one of OUR OWN records dirty, a few at a time via the
--- normal dirty queue (not all at once) - how a client that's been open a
--- while makes sure a newly-joined guildmate/groupmate eventually catches
--- up on everything, not just what changes from here on.
local function ScheduleFullResync()
    local a = EnsureDB()
    if not a then return end
    for soundID, byNode in pairs(a.records) do
        if byNode[a.nodeID] then MarkDirty(soundID) end
    end
end

--- One-time-per-login reconciliation: a sound favourited/muted BEFORE this
--- feature existed (or before Analytics.lua was loaded this session) never
--- went through AnalyticsSetFavourite/AnalyticsSetPersonalMute, so it would
--- otherwise never show up in Analytics at all despite being a real,
--- currently-favourite/muted sound. Reads current state straight from
--- SB.db.sounds (the same saved.favourite/saved.muted flags Favorites.lua
--- and EditWindow.lua themselves write to) and pushes it through the normal
--- mutation functions, which already no-op (no revision bump, nothing
--- marked dirty) when the record already agrees - so this is safe and cheap
--- to just run every login, not only "the first time".
local function ReconcileExistingState()
    if not IsEnabled() then return end
    if not SB.db or not SB.db.sounds then return end
    for soundID, saved in pairs(SB.db.sounds) do
        -- Explicit fix: this was the real reason PruneOrphanedRecords'
        -- cleanup never stuck, even across a full restart. SB.db.sounds
        -- (icon/mute/favourite overrides) was never pruned for a
        -- since-renamed/removed soundID (e.g. "Default::..." after the
        -- category split) - just left as harmless-looking dead data. But
        -- this function runs right after PruneOrphanedRecords in the same
        -- PLAYER_LOGIN/DB_READY handler and blindly re-creates an
        -- analytics record for ANY soundID still marked favourite/muted
        -- here, orphaned or not - immediately undoing the prune that had
        -- just run moments earlier. Skipping anything no longer in the
        -- registry here closes the loop.
        if SB.registry[soundID] then
            if saved.favourite then
                SB:AnalyticsSetFavourite(soundID, true)
            end
            if saved.muted then
                SB:AnalyticsSetPersonalMute(soundID, true)
            end
        end
    end
end

local function CancelTimer(timer)
    if timer and timer.Cancel then timer:Cancel() end
end

local function StopSyncTimers()
    CancelTimer(dirtyStartTimer)
    CancelTimer(fullStartTimer)
    CancelTimer(dirtySyncTicker)
    CancelTimer(fullSyncTicker)
    dirtyStartTimer, fullStartTimer = nil, nil
    dirtySyncTicker, fullSyncTicker = nil, nil
    -- An opt-out must also cover low-priority analytics packets that the
    -- shared transport had already queued but not yet sent.
    if SB.ClearQueuedAnalyticsMessages then SB:ClearQueuedAnalyticsMessages() end
end

local function StartSyncTimers()
    if not analyticsLoginReady or not IsEnabled() then return end

    -- Staggered starts avoid competing with HELLO/roster work at login.
    -- Every handle is retained so opting out can cancel both the delayed
    -- startup and the repeating ticker immediately.
    if not dirtyStartTimer and not dirtySyncTicker then
        dirtyStartTimer = C_Timer.NewTimer(20, function()
            dirtyStartTimer = nil
            if IsEnabled() and not dirtySyncTicker then
                dirtySyncTicker = C_Timer.NewTicker(DIRTY_SYNC_INTERVAL, SendDirtyBatch)
            end
        end)
    end
    if not fullStartTimer and not fullSyncTicker then
        fullStartTimer = C_Timer.NewTimer(90, function()
            fullStartTimer = nil
            if IsEnabled() and not fullSyncTicker then
                ScheduleFullResync()
                fullSyncTicker = C_Timer.NewTicker(FULL_RESYNC_INTERVAL, ScheduleFullResync)
            end
        end)
    end
end

-- The single authority used by Settings and `/sb analytics`. Collected
-- history deliberately remains intact, but disabling immediately stops
-- collection, timers, and not-yet-sent analytics packets.
function SB:SetAnalyticsEnabled(enabled)
    if not (SB.db and SB.db.settings) then return false end
    enabled = enabled == true
    local changed = SB.db.settings.analyticsEnabled ~= enabled
    SB.db.settings.analyticsEnabled = enabled

    if enabled then
        EnsureDB()
        if analyticsLoginReady then
            ReconcileExistingState()
            StartSyncTimers()
        end
    else
        StopSyncTimers()
    end

    if changed then SB:Fire("ANALYTICS_ENABLED_CHANGED", enabled) end
    return true
end

function SB:GetAnalyticsSyncState()
    return {
        enabled = IsEnabled(),
        startupPending = dirtyStartTimer ~= nil or fullStartTimer ~= nil,
        running = dirtySyncTicker ~= nil or fullSyncTicker ~= nil,
    }
end

------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------

-- Removes analytics data for a soundID that no longer exists in the
-- registry (a sound was renamed, its file deleted, or a companion addon
-- that used to register it got removed/updated) - explicit requirement:
-- a "broken"/gone sound must never keep cluttering the /sb analytics
-- window forever. Runs every login, not just once, so it self-heals
-- automatically the moment a sound disappears, not only for whatever
-- happens to already be broken right now. Safe by construction - this
-- reads SB.registry, which is guaranteed fully built (every companion
-- addon included, RequiredDeps ordering) by PLAYER_LOGIN.
local function PruneOrphanedRecords()
    local a = EnsureDB()
    if not a then return end
    local changed = false
    for soundID in pairs(a.records) do
        if not SB.registry[soundID] then
            a.records[soundID] = nil
            changed = true
        end
    end
    for soundID in pairs(a.dailyBuckets) do
        if not SB.registry[soundID] then
            a.dailyBuckets[soundID] = nil
        end
    end
    if SB.db.soundDurations then
        for soundID in pairs(SB.db.soundDurations) do
            if not SB.registry[soundID] then
                SB.db.soundDurations[soundID] = nil
            end
        end
    end
    -- Also clean SB.db.sounds (per-sound icon/mute/favourite overrides) and
    -- knownSoundIDs (the New-tag tracker) - previously left alone as
    -- "harmless dead data", but SB.db.sounds specifically is NOT harmless:
    -- ReconcileExistingState (below) reads it every login and was
    -- resurrecting an analytics record for anything still marked
    -- favourite/muted here, orphaned or not - undoing this very prune
    -- moments after it ran. Actually removing the root data instead of
    -- just leaving it for ReconcileExistingState's own new registry guard
    -- to skip closes the loop for good and keeps SavedVariables tidy.
    if SB.db.sounds then
        for soundID in pairs(SB.db.sounds) do
            if not SB.registry[soundID] then
                SB.db.sounds[soundID] = nil
            end
        end
    end
    if SB.db.knownSoundIDs then
        for soundID in pairs(SB.db.knownSoundIDs) do
            if not SB.registry[soundID] then
                SB.db.knownSoundIDs[soundID] = nil
            end
        end
    end
    if changed then SB:Fire("ANALYTICS_UPDATED") end
end

-- REVERTED (see below): a DB_READY-triggered prune here used to also run
-- this on every /reload, not just a real login. Rolled back - it caused a
-- real bug (see the comment on PLAYER_LOGIN's own hook just below) and is
-- gone for good, not just delayed/reordered.
--
-- PruneOrphanedRecords is ONLY ever safe at PLAYER_LOGIN, never earlier -
-- explicit fix, found via a real bug report. DB_READY fires at Soundbook's
-- OWN ADDON_LOADED, which can (and, apparently, reliably does) run BEFORE
-- a companion addon like Soundbook_Private/Soundbook_MySounds has loaded
-- and registered ITS sounds - they only need `Soundbook` (this addon,
-- providing SB.RegisterPrivateSounds/SB.RegisterSounds) to exist first,
-- there's no dependency edge forcing the reverse. Running the prune that
-- early saw those sounds as "not in SB.registry yet" and wiped real data
-- for them: Stammtisch sounds lost their knownSoundIDs entries (so
-- BackfillAddedAt, running later at the now-correct PLAYER_LOGIN, treated
-- literally all of them as newly-added and tagged everything "New"), and
-- a MySounds/Private sound's manually-picked custom icon (SB.db.sounds)
-- got deleted outright - unlike the New-tag mislabel, that one is real
-- data loss, not just a flag to recompute (see Core.lua/EditWindow.lua -
-- there is no historical copy of a per-player icon pick anywhere).
-- PLAYER_LOGIN alone (below) IS safe for this, per this same file's
-- original comment on PruneOrphanedRecords - it fires once every addon in
-- the whole AddOns folder has finished loading, companions included.
SB:On("PLAYER_LOGIN", function()
    analyticsLoginReady = true
    EnsureDB()
    PruneBuckets()
    PruneOrphanedRecords()
    ReconcileExistingState()
    StartSyncTimers()
end)

------------------------------------------------------------------------
-- Query / metrics layer - everything AnalyticsUI.lua reads. Pure
-- computation over SB.db.analytics.records; never mutates anything here.
------------------------------------------------------------------------

--- Every soundID that has at least one record from any node (including us).
function SB.Analytics_AllSoundIDs()
    local a = EnsureDB()
    local ids = {}
    if not a then return ids end
    for soundID in pairs(a.records) do
        table.insert(ids, soundID)
    end
    return ids
end

-- `filter` is "all" / "7d" / "30d" - which per-node play count to read.
local function NodePlaysForFilter(rec, filter)
    if filter == "7d" then return rec.plays7d or 0 end
    if filter == "30d" then return rec.plays30d or 0 end
    return rec.totalPlays or 0
end

--- soundID -> true only for a Stammtisch (Soundbook_Private) sound.
--- Explicit request: Stammtisch gets its OWN separate "pool" for the
--- Trending/Popular/Loved/Legendary tags, computed and ranked entirely
--- against other Stammtisch sounds - never pooled with Legacy/German Memes
--- (see SB.Analytics_IsHealthEligible for that main pool). "Nur ganz
--- wenige Spieler haben Stammtisch" - pooling it with the much larger
--- Legacy/German Memes audience would mean a Stammtisch sound could
--- basically never win reach/plays comparisons no matter how loved it is
--- within its own small circle.
function SB.Analytics_IsPrivatePoolEligible(soundID)
    local cat = SB.ParseSoundID(soundID)
    return cat == SB.PRIVATE_CATEGORY
end

--- Distinct nodes (across every sound) with any play activity in `filter`'s
--- window - the denominator for Reach %. `pool` (optional): "private"
--- restricts this to only nodes active on a STAMMTISCH sound specifically
--- - explicit requirement, a Stammtisch sound's reach must be measured
--- against Stammtisch's own (much smaller) active audience, not the whole
--- Soundbook's - otherwise it could never reach a meaningful reach %
--- against everyone else's Legacy/German Memes activity, most of whom
--- don't even have Stammtisch installed. Omitted/nil keeps the original
--- whole-addon denominator, unchanged, for the main pool.
function SB.Analytics_ObservedActiveUsers(filter, pool)
    local a = EnsureDB()
    if not a then return 0 end
    local seen = {}
    for soundID, byNode in pairs(a.records) do
        if pool ~= "private" or SB.Analytics_IsPrivatePoolEligible(soundID) then
            for nodeID, rec in pairs(byNode) do
                if NodePlaysForFilter(rec, filter) > 0 then seen[nodeID] = true end
            end
        end
    end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    return n
end

--- Distinct nodes observed at all, regardless of activity window - used
--- for the top summary's "Observed Users".
function SB.Analytics_ObservedUsersTotal()
    local a = EnsureDB()
    if not a then return 0 end
    local seen = {}
    for _, byNode in pairs(a.records) do
        for nodeID in pairs(byNode) do seen[nodeID] = true end
    end
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    return n
end

--- Per-sound metrics for the given time filter ("all"/"7d"/"30d"). Favs/
--- Mutes are always CURRENT state (not time-filtered - they're a live flag,
--- not a historical count).
function SB.Analytics_SoundMetrics(soundID, filter)
    local a = EnsureDB()
    local m = {
        plays = 0, users = 0, favs = 0, mutes = 0, sessions = 0,
        lastUsed = 0, observedNodes = 0, playsPrev7d = 0,
    }
    if not a or not a.records[soundID] then return m end
    for _, rec in pairs(a.records[soundID]) do
        m.observedNodes = m.observedNodes + 1
        local plays = NodePlaysForFilter(rec, filter)
        m.plays = m.plays + plays
        if plays > 0 then m.users = m.users + 1 end
        if rec.favourite then m.favs = m.favs + 1 end
        if rec.personalMute then m.mutes = m.mutes + 1 end
        m.sessions = m.sessions + (rec.sessionsUsed or 0)
        m.playsPrev7d = m.playsPrev7d + (rec.playsPrev7d or 0)
        if (rec.lastUsed or 0) > m.lastUsed then m.lastUsed = rec.lastUsed end
    end
    -- Reach is measured against the right audience for this sound's own
    -- pool - Stammtisch against Stammtisch's own active users, everything
    -- else against the whole addon's, same as before (see
    -- SB.Analytics_ObservedActiveUsers's own comment).
    local pool = SB.Analytics_IsPrivatePoolEligible(soundID) and "private" or nil
    local activeUsers = SB.Analytics_ObservedActiveUsers(filter, pool)
    m.reach = activeUsers > 0 and (m.users / activeUsers) or 0
    m.favRate = m.observedNodes > 0 and (m.favs / m.observedNodes) or 0
    m.muteRate = m.observedNodes > 0 and (m.mutes / m.observedNodes) or 0
    return m
end

--- A plain +/-% growth number (current 7d plays vs. the previous 7d), or
--- nil when there's no valid trend verdict available at all - either no
--- current activity, activity too thin to mean anything (see
--- trendingMinPlays/trendingMinUsers below), or no comparable PRIOR week
--- to measure growth against.
---
--- Explicit bugfix, round 1: this used to fire "NEW" (-> Trending, see
--- SB.Analytics_Health) off a SINGLE play with zero the prior week, and a
--- 2-play week following a 1-play week already cleared the +50% growth
--- bar too - both pure noise with a userbase this small, not a real trend.
--- A minimum CURRENT-week volume (both total plays and distinct players)
--- was added to require before anything counts as trending at all.
---
--- Explicit bugfix, round 2: that alone wasn't enough - right after ANY
--- reset (the Legacy/German Memes category split, or simply a sound's
--- analytics only having started being tracked recently), literally EVERY
--- currently-used sound has zero prior-week data purely as a reset
--- artifact, not because it's actually accelerating. A "0 prior plays ->
--- automatically counts as trending" rule can never tell that apart from a
--- genuine trend, so it's gone entirely now - a verdict requires an ACTUAL
--- week-over-week comparison with real data on both sides. The first week
--- after any reset honestly has "not enough history yet" (nil) instead of
--- guessing everyone into Trending at once.
function SB.Analytics_Trend(soundID)
    local T = SB.ANALYTICS_HEALTH_THRESHOLDS
    local m7 = SB.Analytics_SoundMetrics(soundID, "7d")
    if m7.plays <= 0 then return nil end
    -- Explicit request: Stammtisch's own (lower) minimum play volume -
    -- "nur ganz wenige Spieler haben Stammtisch", so the main pool's bar
    -- would rarely if ever be reachable there. The distinct-PLAYERS
    -- minimum (trendingMinUsers) stays shared - "at least 2 different
    -- people" is an anti-single-person-spam floor, not a population-size
    -- one, so it applies just as much to a small group.
    local minPlays = SB.Analytics_IsPrivatePoolEligible(soundID) and T.trendingMinPlaysPrivate or T.trendingMinPlays
    if m7.plays < minPlays or m7.users < T.trendingMinUsers then return nil end
    if m7.playsPrev7d <= 0 then return nil end
    return (m7.plays - m7.playsPrev7d) / m7.playsPrev7d
end

------------------------------------------------------------------------
-- Top-N capping - shared machinery for EVERY positive pill (Trending,
-- Popular, Community Favourite/"Loved") - explicit request: none of them
-- should be able to flood the grid just because many sounds individually
-- clear that tag's own absolute threshold; each is additionally capped to
-- its own maxCount, so every tag stays meaningful IN RELATION TO THE
-- OTHERS, not just against a fixed number - "in relation immer zu
-- einander". All three default to the same cap (5) so none of them can
-- structurally out-crowd the others.
------------------------------------------------------------------------

--- `eligibleFn(soundID)` gates which POOL a candidate is drawn from (main
--- Legacy/German Memes pool vs. the separate Stammtisch pool - explicit
--- request, see SB.Analytics_IsPrivatePoolEligible above). `rankValueFn
--- (soundID)` returns a number to rank by (higher = more qualifying) for a
--- sound that clears THIS tag's own threshold, or nil for one that
--- doesn't - only sounds it returns a number for are ever candidates.
--- Returns exactly the top `maxCount` of those (or fewer, NEVER force-
--- padded with non-qualifying sounds just to fill the quota).
local function BuildTopSet(eligibleFn, rankValueFn, maxCount)
    local candidates = {}
    if SB.Analytics_AllSoundIDs then
        for _, soundID in ipairs(SB.Analytics_AllSoundIDs()) do
            if eligibleFn(soundID) then
                local rank = rankValueFn(soundID)
                if rank then
                    table.insert(candidates, { soundID = soundID, rank = rank })
                end
            end
        end
    end
    table.sort(candidates, function(a, b) return a.rank > b.rank end)
    local set = {}
    for i = 1, math.min(#candidates, maxCount) do
        set[candidates[i].soundID] = true
    end
    return set
end

-- Cached briefly (a few seconds) - RefreshGrid/AnalyticsUI's BuildRows both
-- call SB.Analytics_Health once per VISIBLE sound, not once total, and each
-- of those needs to know the full ranking to decide whether THIS sound
-- makes the cut - recomputing it from scratch for every single row in the
-- same refresh would be wasteful. One cache slot per tag PER POOL (main +
-- Stammtisch, kept entirely separate - explicit request).
local TOP_SET_CACHE_TTL = 5
local trendingSetCache, trendingSetCacheAt
local popularSetCache, popularSetCacheAt
local favouriteSetCache, favouriteSetCacheAt
local trendingSetCachePrivate, trendingSetCachePrivateAt
local popularSetCachePrivate, popularSetCachePrivateAt
local favouriteSetCachePrivate, favouriteSetCachePrivateAt

--- The soundIDs currently allowed to actually show "Trending" - capped to
--- ANALYTICS_HEALTH_THRESHOLDS.trendingMaxCount, whichever are growing
--- FASTEST (SB.Analytics_Trend), among the main Legacy/German Memes pool.
function SB.Analytics_TopTrendingSet()
    local now = GetTime()
    if trendingSetCache and trendingSetCacheAt and (now - trendingSetCacheAt) < TOP_SET_CACHE_TTL then
        return trendingSetCache
    end
    local T = SB.ANALYTICS_HEALTH_THRESHOLDS
    trendingSetCache = BuildTopSet(SB.Analytics_IsHealthEligible, function(soundID)
        local trend = SB.Analytics_Trend(soundID)
        if type(trend) == "number" and trend >= T.trendingGrowth then return trend end
        return nil
    end, T.trendingMaxCount)
    trendingSetCacheAt = now
    return trendingSetCache
end

--- Same as SB.Analytics_TopTrendingSet, but Stammtisch's own separate pool
--- and cap (ANALYTICS_HEALTH_THRESHOLDS.trendingMaxCountPrivate) - explicit
--- request: "+2 Trending Sounds" on top of the main pool's own up to 5.
function SB.Analytics_TopTrendingSetPrivate()
    local now = GetTime()
    if trendingSetCachePrivate and trendingSetCachePrivateAt and (now - trendingSetCachePrivateAt) < TOP_SET_CACHE_TTL then
        return trendingSetCachePrivate
    end
    local T = SB.ANALYTICS_HEALTH_THRESHOLDS
    trendingSetCachePrivate = BuildTopSet(SB.Analytics_IsPrivatePoolEligible, function(soundID)
        local trend = SB.Analytics_Trend(soundID)
        if type(trend) == "number" and trend >= T.trendingGrowth then return trend end
        return nil
    end, T.trendingMaxCountPrivate)
    trendingSetCachePrivateAt = now
    return trendingSetCachePrivate
end

--- The soundIDs currently allowed to actually show "Popular" - capped to
--- ANALYTICS_HEALTH_THRESHOLDS.popularMaxCount, whichever have the most
--- total plays (among those already clearing popularReach/popularMinPlays),
--- among the main Legacy/German Memes pool.
function SB.Analytics_TopPopularSet()
    local now = GetTime()
    if popularSetCache and popularSetCacheAt and (now - popularSetCacheAt) < TOP_SET_CACHE_TTL then
        return popularSetCache
    end
    local T = SB.ANALYTICS_HEALTH_THRESHOLDS
    popularSetCache = BuildTopSet(SB.Analytics_IsHealthEligible, function(soundID)
        local m = SB.Analytics_SoundMetrics(soundID, "all")
        if m.reach >= T.popularReach and m.plays >= T.popularMinPlays then return m.plays end
        return nil
    end, T.popularMaxCount)
    popularSetCacheAt = now
    return popularSetCache
end

--- Same as SB.Analytics_TopPopularSet, but Stammtisch's own separate pool,
--- its own (lower) popularMinPlaysPrivate volume floor, and its own cap
--- (popularMaxCountPrivate) - explicit request: "+2 Sounds".
function SB.Analytics_TopPopularSetPrivate()
    local now = GetTime()
    if popularSetCachePrivate and popularSetCachePrivateAt and (now - popularSetCachePrivateAt) < TOP_SET_CACHE_TTL then
        return popularSetCachePrivate
    end
    local T = SB.ANALYTICS_HEALTH_THRESHOLDS
    popularSetCachePrivate = BuildTopSet(SB.Analytics_IsPrivatePoolEligible, function(soundID)
        local m = SB.Analytics_SoundMetrics(soundID, "all")
        if m.reach >= T.popularReach and m.plays >= T.popularMinPlaysPrivate then return m.plays end
        return nil
    end, T.popularMaxCountPrivate)
    popularSetCachePrivateAt = now
    return popularSetCachePrivate
end

--- The soundIDs currently allowed to actually show "Community Favourite"
--- ("Loved") - capped to ANALYTICS_HEALTH_THRESHOLDS.communityFavMaxCount,
--- whichever have the highest favourite RATE (among those already
--- clearing communityFavRate), among the main Legacy/German Memes pool.
function SB.Analytics_TopFavouriteSet()
    local now = GetTime()
    if favouriteSetCache and favouriteSetCacheAt and (now - favouriteSetCacheAt) < TOP_SET_CACHE_TTL then
        return favouriteSetCache
    end
    local T = SB.ANALYTICS_HEALTH_THRESHOLDS
    favouriteSetCache = BuildTopSet(SB.Analytics_IsHealthEligible, function(soundID)
        local m = SB.Analytics_SoundMetrics(soundID, "all")
        if m.favRate >= T.communityFavRate then return m.favRate end
        return nil
    end, T.communityFavMaxCount)
    favouriteSetCacheAt = now
    return favouriteSetCache
end

--- Same as SB.Analytics_TopFavouriteSet, but Stammtisch's own separate
--- pool and cap (communityFavMaxCountPrivate) - explicit request: "+2
--- Sounds". favRate itself needs no separate floor here - it's already a
--- per-sound ratio (favourites / observers of THAT sound), not tied to
--- the size of the wider active-user population the way reach is.
function SB.Analytics_TopFavouriteSetPrivate()
    local now = GetTime()
    if favouriteSetCachePrivate and favouriteSetCachePrivateAt and (now - favouriteSetCachePrivateAt) < TOP_SET_CACHE_TTL then
        return favouriteSetCachePrivate
    end
    local T = SB.ANALYTICS_HEALTH_THRESHOLDS
    favouriteSetCachePrivate = BuildTopSet(SB.Analytics_IsPrivatePoolEligible, function(soundID)
        local m = SB.Analytics_SoundMetrics(soundID, "all")
        if m.favRate >= T.communityFavRate then return m.favRate end
        return nil
    end, T.communityFavMaxCountPrivate)
    favouriteSetCachePrivateAt = now
    return favouriteSetCachePrivate
end

--- Top summary block - Observed Users/Sessions/Total Plays/Sounds with
--- Data/Data Range/Last Sync (Last Sync itself is tracked by the caller
--- via the ANALYTICS_UPDATED event timestamp, not stored here).
function SB.Analytics_Summary(filter)
    local a = EnsureDB()
    local s = { observedUsers = 0, observedSessions = 0, totalPlays = 0, soundsWithData = 0, oldestSeen = nil, newestSeen = nil }
    if not a then return s end
    s.observedUsers = SB.Analytics_ObservedUsersTotal()
    for soundID, byNode in pairs(a.records) do
        local hasAny = false
        for _, rec in pairs(byNode) do
            local plays = NodePlaysForFilter(rec, filter)
            s.totalPlays = s.totalPlays + plays
            s.observedSessions = s.observedSessions + (rec.sessionsUsed or 0)
            if plays > 0 or filter == "all" then hasAny = true end
            if rec.lastUsed and rec.lastUsed > 0 then
                if not s.newestSeen or rec.lastUsed > s.newestSeen then s.newestSeen = rec.lastUsed end
                if not s.oldestSeen or rec.lastUsed < s.oldestSeen then s.oldestSeen = rec.lastUsed end
            end
        end
        if hasAny then s.soundsWithData = s.soundsWithData + 1 end
    end
    return s
end

--- Only ever reads OUR OWN node's records - explicit privacy requirement,
--- "My Stats" must never be able to show anyone else's data.
function SB.Analytics_MyStats()
    local a = EnsureDB()
    local list = {}
    if not a then return list end
    for soundID, byNode in pairs(a.records) do
        local rec = byNode[a.nodeID]
        if rec then
            table.insert(list, { soundID = soundID, rec = rec })
        end
    end
    return list
end

------------------------------------------------------------------------
-- Health classification - several understandable labels, never a single
-- opaque score. Thresholds centralised here so they're easy to tune later
-- without hunting through the classifier logic itself.
------------------------------------------------------------------------

-- Only Legacy and German Memes sounds are eligible for health/tag
-- classification (Trending/Popular/Loved/Removal Candidate/Least Used/
-- etc.) - explicit requirement. Category 1/2 (Soundbook_MySounds) and
-- Stammtisch (Soundbook_Private) are each player's OWN separately-curated
-- library, swapped/extended entirely at their own discretion - not the
-- shared "everyone on this addon has this" content the health system is
-- meant to judge. A tiny handful of real observers for those (a specific
-- friend group, not the whole playerbase) makes any classification
-- meaningless or actively misleading (near-permanent "Insufficient Data",
-- or a false "Removal Candidate" for a sound its owner is perfectly happy
-- with). Most players only ever have Legacy/German Memes at all, which is
-- exactly what this system should stay focused on.
--
-- Their raw usage IS still tracked and viewable exactly as before (play
-- counts, reach, etc. via "My Stats" and the general Overview) - only the
-- health JUDGMENT (and everything gated on it - the Trending/Popular/Loved
-- tag pills too, see UI.lua's GetTag) is scoped out here.
local HEALTH_ELIGIBLE_CATEGORIES = { Legacy = true, ["German Memes"] = true }

--- soundID -> true only for a Legacy/German Memes sound. Callers use this
--- to decide whether to even compute/show a health label or tag pill at
--- all - see AnalyticsUI.lua's BuildRows and UI.lua's GetTag.
function SB.Analytics_IsHealthEligible(soundID)
    local cat = SB.ParseSoundID(soundID)
    return HEALTH_ELIGIBLE_CATEGORIES[cat] == true
end

SB.ANALYTICS_HEALTH_THRESHOLDS = {
    minNodesForData     = 2,     -- fewer observed nodes than this -> Insufficient Data
    minPlaysForData      = 3,
    popularReach         = 0.5,  -- reach >= this -> candidate for Popular
    popularMinPlays      = 15,
    popularMaxCount      = 5,    -- at most this many sounds can be Popular AT ONCE, whichever have the most plays
    communityFavRate     = 0.35, -- fav rate >= this -> Community Favourite
    communityFavMaxCount = 5,    -- at most this many sounds can be Community Favourite AT ONCE, whichever have the highest fav rate
    trendingGrowth       = 0.5,  -- +50% period over period -> Trending
    trendingMinPlays     = 5,    -- fewer plays THIS week than this -> never Trending, no matter the growth% (stops 1-play noise)
    trendingMinUsers     = 2,    -- fewer distinct players THIS week than this -> never Trending (stops one person spamming a sound alone from qualifying)
    trendingMaxCount     = 5,    -- at most this many sounds can be Trending AT ONCE, whichever are growing fastest - keeps the tag relative/meaningful instead of everything qualifying together
    -- Stammtisch's own SEPARATE pool (explicit request) - "+2" on top of
    -- the main pool's own caps above, ranked only against other
    -- Stammtisch sounds, never against Legacy/German Memes (see
    -- SB.Analytics_IsPrivatePoolEligible). popularMinPlays/trendingMinPlays
    -- get their own (lower) floor here too - "nur ganz wenige Spieler
    -- haben Stammtisch", the main pool's absolute volume bars would rarely
    -- if ever be reachable there. Ratio-based thresholds (popularReach,
    -- communityFavRate, trendingGrowth) stay shared - they already self-
    -- scale correctly once measured against Stammtisch's own (smaller)
    -- active-user count instead (SB.Analytics_ObservedActiveUsers's `pool`
    -- argument), so a separate floor for those would just be guessing.
    trendingMinPlaysPrivate     = 3,
    trendingMaxCountPrivate     = 2,
    popularMinPlaysPrivate      = 8,
    popularMaxCountPrivate      = 2,
    communityFavMaxCountPrivate = 2,
    spammySessionRatio   = 6,    -- avg plays-per-session-per-user this high -> Spammy
    spammyMinSessions    = 2,    -- fewer than this many observed sessions -> never Spammy (one enthusiastic burst in a single sitting isn't a pattern)
    muteRateHigh         = 0.4,  -- Frequently Muted
    forgottenDays        = 30,   -- no plays in this many days (with prior history) -> Forgotten
    removalMinSignals    = 2,    -- this many negative signals at once -> Removal Candidate
}

--- Returns a single label string. `soundID` is needed to check the capped
--- top-trending ranking (SB.Analytics_TopTrendingSet) - `metrics` from
--- SB.Analytics_SoundMetrics (filter should be "all" for a stable
--- classification), `trend` from SB.Analytics_Trend, `daysSinceLastUsed`
--- computed by the caller.
function SB.Analytics_Health(soundID, metrics, trend, daysSinceLastUsed)
    local T = SB.ANALYTICS_HEALTH_THRESHOLDS
    if metrics.observedNodes < T.minNodesForData or metrics.plays < T.minPlaysForData then
        return "Insufficient Data"
    end

    if metrics.muteRate >= T.muteRateHigh then
        return "Frequently Muted"
    end

    -- Same small-sample-noise principle as Trending's own minimums below -
    -- a single enthusiastic burst in ONE sitting (e.g. 6 plays during one
    -- wipe) shouldn't brand a sound "Spammy" community-wide off one
    -- session; spammyMinSessions requires the pattern to show up across
    -- more than one sitting first.
    local avgSessionRatio = metrics.sessions > 0 and (metrics.plays / metrics.sessions) or 0
    if avgSessionRatio >= T.spammySessionRatio and metrics.favRate < T.communityFavRate
        and metrics.sessions >= T.spammyMinSessions then
        return "Spammy"
    end

    -- Explicit request: Stammtisch gets its OWN separate pool/cap for
    -- every one of these three (SB.Analytics_IsPrivatePoolEligible) -
    -- never pooled/ranked together with Legacy/German Memes.
    local isPrivate = SB.Analytics_IsPrivatePoolEligible(soundID)

    -- Explicit request: capped to the trendingMaxCount (or, for
    -- Stammtisch, trendingMaxCountPrivate) fastest-growing sounds at once -
    -- clearing the growth bar alone is no longer enough by itself if too
    -- many other sounds in the SAME pool are growing even faster right
    -- now, so the tag stays relative/meaningful ("was ist WIRKLICH gerade
    -- trendy") instead of everyone qualifying at the same time.
    local trendingSet = isPrivate and SB.Analytics_TopTrendingSetPrivate() or SB.Analytics_TopTrendingSet()
    if type(trend) == "number" and trend >= T.trendingGrowth and trendingSet[soundID] then
        return "Trending"
    end

    -- Same "capped to the top few, not just anyone clearing the bar"
    -- principle as Trending above - "in Relation immer zueinander", now
    -- within the sound's own pool (popularMinPlays vs. the lower
    -- popularMinPlaysPrivate).
    local popularMinPlays = isPrivate and T.popularMinPlaysPrivate or T.popularMinPlays
    local popularSet = isPrivate and SB.Analytics_TopPopularSetPrivate() or SB.Analytics_TopPopularSet()
    if metrics.reach >= T.popularReach and metrics.plays >= popularMinPlays and popularSet[soundID] then
        return "Popular"
    end

    -- Same principle again, within the sound's own pool.
    local favouriteSet = isPrivate and SB.Analytics_TopFavouriteSetPrivate() or SB.Analytics_TopFavouriteSet()
    if metrics.favRate >= T.communityFavRate and favouriteSet[soundID] then
        return "Community Favourite"
    end

    -- Removal Candidate needs SEVERAL negative signals at once, never one
    -- alone - explicit requirement, and never an automatic deletion, just
    -- a label.
    local negativeSignals = 0
    if metrics.reach < 0.15 then negativeSignals = negativeSignals + 1 end
    if metrics.plays < T.popularMinPlays then negativeSignals = negativeSignals + 1 end
    if metrics.favRate < 0.05 then negativeSignals = negativeSignals + 1 end
    if daysSinceLastUsed and daysSinceLastUsed >= T.forgottenDays then negativeSignals = negativeSignals + 1 end
    if negativeSignals >= T.removalMinSignals then
        if daysSinceLastUsed and daysSinceLastUsed >= T.forgottenDays then
            return "Removal Candidate"
        end
        return "Niche"
    end

    if daysSinceLastUsed and daysSinceLastUsed >= T.forgottenDays then
        return "Forgotten"
    end

    return "Niche"
end

------------------------------------------------------------------------
-- Grid ordering - Legacy/German Memes/Category1/Category2/Stammtisch, per explicit
-- request. Never touches the input list or SB.registryByCategory itself -
-- always returns a fresh array, so callers (UI.lua) are free to keep using
-- the underlying registry list elsewhere unmodified.
------------------------------------------------------------------------

--- `ids` is a flat array of soundIDs (one tab's worth). Returns a NEW
--- array. Regardless of sort mode, every "New" sound (SB:IsSoundNew - a
--- real library-addition date within the last 5 days (120h), see
--- SoundRegistry.lua) is always moved to the very front, ahead of even
--- the most popular sound - explicit request. The rest is then ordered
--- per SB.db.settings.sortMode:
---   "popularity" (default) - most community-wide all-time plays first
---   (SB.Analytics_SoundMetrics' own "all" filter, i.e. every observed
---   node combined, not just your own plays); ties - including sounds
---   with zero/no data at all - fall back to alphabetical among
---   themselves, so "no data yet" sounds end up grouped at the bottom in
---   a readable order rather than shuffled.
---   anything else ("alphabetical") - stays in whatever order the
---   caller/registry already had it in (Sounds.lua's own declaration
---   order for a category), unchanged.
function SB.SortSoundIDsBySetting(ids)
    if not ids then return ids end
    local mode = SB.db and SB.db.settings and SB.db.settings.sortMode

    local sorted = {}
    for i, id in ipairs(ids) do sorted[i] = id end

    if mode == "popularity" then
        local function PlaysOf(soundID)
            local ok, m = pcall(SB.Analytics_SoundMetrics, soundID, "all")
            return (ok and m and m.plays) or 0
        end
        table.sort(sorted, function(a, b)
            local pa, pb = PlaysOf(a), PlaysOf(b)
            if pa ~= pb then return pa > pb end
            return SB:GetSoundDisplayName(a):lower() < SB:GetSoundDisplayName(b):lower()
        end)
    end

    -- New-first partition - stable (preserves whatever relative order the
    -- step above already produced within each group), applied last so it
    -- always wins regardless of sortMode.
    local function IsNew(soundID)
        return SB.IsSoundNew and SB:IsSoundNew(soundID)
    end
    local newIDs, restIDs = {}, {}
    for _, id in ipairs(sorted) do
        if IsNew(id) then
            table.insert(newIDs, id)
        else
            table.insert(restIDs, id)
        end
    end
    if #newIDs == 0 then return sorted end
    local result = {}
    for _, id in ipairs(newIDs) do table.insert(result, id) end
    for _, id in ipairs(restIDs) do table.insert(result, id) end
    return result
end
