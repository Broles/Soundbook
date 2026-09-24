-- SoundPlayer.lua
--
-- The ONE and only place that ever calls PlaySoundFile in this addon.
-- The Soundbook button, the Favourites mini-window, the slash command,
-- macros, and incoming multiplayer messages all funnel through
-- SB:TriggerSound (locally-initiated) or SB:PlaySound (actual playback),
-- so behaviour (mute, overlap, channel) is always identical everywhere.
--
-- KNOWN LIMITATION - PER-SOUND VOLUME:
-- WoW's public API has no way to set the volume of an individual sound/
-- handle; the only volume control is global (Master/SFX CVars), which this
-- addon deliberately never touches since that would affect all game audio.
-- The per-sound "Volume" slider therefore stores a value in SavedVariables
-- but it is NOT currently applied to actual audio output.

local ADDON_NAME, SB = ...

-- Handles of sounds this addon itself started, so "stop overlap" only
-- ever stops Soundbook's own sounds and never touches unrelated game audio.
local activeHandles = {}
local supportsHandles = nil -- feature-detected lazily on first play

-- Which extension (from SB.SOUND_EXTENSIONS) actually exists on disk for a
-- given sound, discovered on first successful play and cached so repeat
-- plays don't re-probe missing extensions every time.
local resolvedExtension = {}
-- Separate cache for the ALTERNATE file (SoundAlternates.lua): the original
-- and alternate are different physical files that can have different
-- extensions, so they must never share a cache slot.
local resolvedAltExtension = {}
local missingFileBases = {}
local missingNoticeShown = {}

local function NotifyMissingLocalFile(fileBase, info, source)
    -- Remote failures stay silent; only a local click gets the one-time
    -- notice, even if a remote request first populated the missing-file cache.
    if source ~= "local" or missingNoticeShown[fileBase] then return end
    missingNoticeShown[fileBase] = true
    SB:Print(string.format(
        "Could not play '%s' - no matching file (tried .%s) next to Sounds.lua. If you just added it, a full client restart is required (see README).",
        info.name, table.concat(SB.SOUND_EXTENSIONS, "/.")
    ))
end

------------------------------------------------------------------------
-- Playback progress tracking - drives the Announcer's Now Playing progress
-- fill and the "learn a sound's real duration by observing it" fallback.
--
-- Tracked by a LOCAL playback-instance token (nextInstanceID), never by the
-- WoW sound handle or by soundID alone: the handle can legitimately be nil
-- even for a successful play (see supportsHandles above) and is only used
-- to query C_Sound.IsPlaying when available, never a prerequisite for
-- tracking/display; soundID alone can't identify an instance since the
-- same sound can be retriggered/overlapped.
------------------------------------------------------------------------

-- C_Sound.IsPlaying is an OPTIONAL refinement, not a prerequisite - not
-- guaranteed on every client build, so it's feature-detected once. An
-- instance with a known duration tracks/displays progress fine without it
-- (see the duration-ceiling branch in PollTrackedInstances); only early-
-- natural-end detection and live duration-learning need it, falling back
-- to the known duration's own ceiling when it's unavailable.
local canTrackPlayback = type(C_Sound) == "table" and type(C_Sound.IsPlaying) == "function"

-- [instanceID] = { soundID, handle (may be nil - see above), startedAt
--                  (GetTimePreciseSec - when PlaySoundFile was CALLED),
--                  playingStartedAt (when it was FIRST observed playing via
--                  C_Sound.IsPlaying - may lag startedAt, nil if no handle),
--                  observedPlaying, interrupted, ambiguousOverlap,
--                  duration (may be nil - unknown) }
--
-- WHY TWO TIMESTAMPS: WoW does not truly overlap two simultaneous plays of
-- the same sound file - a second PlaySoundFile call while an identical
-- sound is already playing returns willPlay=true and a real handle
-- immediately, but audible playback is silently QUEUED until the first
-- instance finishes. Measuring duration from startedAt (call time) for
-- that queued instance would include the entire wait, producing an
-- ~2x-too-long learned duration. playingStartedAt (first confirmed-playing
-- poll) alone still isn't enough to fix this - see activeSoundCount below.
local trackedInstances = {}
local nextInstanceID = 0
-- The most recently STARTED instance still being tracked - what the
-- Announcement Bar shows progress for.
local primaryInstanceID = nil
local pollTicker = nil

-- [soundID] = how many instances of that exact sound are CURRENTLY tracked
-- (started, not yet confirmed ended). C_Sound.IsPlaying can't tell "queued
-- behind another instance of the same sound" apart from "genuinely
-- playing" - both read true - so no timestamp is trustworthy for a SECOND
-- instance of the same sound started while the first is still active. Any
-- such "ambiguous" instance is excluded from duration LEARNING entirely -
-- see TrackNewPlayback/PollTrackedInstances.
local activeSoundCount = {}

-- An instance never observed playing (bad file, PlaySoundFile lied about
-- willPlay, or no handle AND no known duration) would otherwise sit in
-- trackedInstances forever - dropped after this many seconds.
local NEVER_STARTED_TIMEOUT = 3.0
-- Safety net for the OPPOSITE case: an instance that DID start but whose
-- C_Sound.IsPlaying never flips back to false would otherwise sit in
-- trackedInstances forever, keeping activeSoundCount for that sound
-- elevated - which would make EVERY future play of that sound look
-- "ambiguous" and never learn a duration. Force-released (never learned
-- from) past this many seconds regardless of playing state.
local MAX_TRACKED_LIFETIME = 90.0
local POLL_INTERVAL = 0.08
-- Once a KNOWN duration plus this grace margin has elapsed, an instance
-- ends regardless of what C_Sound.IsPlaying still claims - some clients/
-- files report IsPlaying=true for several seconds past the real audible end.
local NATURAL_END_GRACE = 0.3

local function Now()
    return GetTimePreciseSec and GetTimePreciseSec() or GetTime()
end

-- DISPLAY elapsed is measured from startedAt (call time), not from
-- playingStartedAt (first confirmed-playing poll tick) - a deliberate
-- split from LEARNING, which still uses playingStartedAt (see the
-- natural-end branch in PollTrackedInstances). Waiting on C_Sound.IsPlaying
-- confirmation for display caused a visible stutter and made retriggering
-- the same sound mid-playback blank the progress bar out entirely, since
-- IsPlaying can't tell the two instances apart. Call time is always
-- immediately known, so display doesn't depend on IsPlaying at all - only
-- the stricter LEARNING path does, since that needs to be trustworthy.
local function BuildPlaybackState(instanceID, now)
    local pb = trackedInstances[instanceID]
    if not pb then return nil end
    now = now or Now()
    local elapsed = math.max(0, now - pb.startedAt)
    local progress = nil
    if pb.duration and pb.duration > 0 then
        progress = math.max(0, math.min(1, elapsed / pb.duration))
    end
    return {
        soundID = pb.soundID,
        instanceID = instanceID,
        handle = pb.handle,
        startedAt = pb.startedAt,
        duration = pb.duration,
        elapsed = elapsed,
        progress = progress,
        isPrimary = (instanceID == primaryInstanceID),
    }
end

-- Learned only from a genuinely NATURAL end (never interrupted), and only
-- fills in a still-unknown duration - never overwrites an existing
-- precomputed/already-learned value with a possibly-imprecise measurement.
local function SaveLearnedDuration(soundID, measured)
    if not soundID or not measured or measured <= 0 or measured > 600 then return end
    local info = SB.registry[soundID]
    if info and info.durationSeconds then return end -- already known - never overwrite
    if not SB.db then return end
    SB.db.soundDurations = SB.db.soundDurations or {}
    if SB.db.soundDurations[soundID] then return end
    SB.db.soundDurations[soundID] = measured
    if info then info.durationSeconds = measured end
end

local function StopPollTicker()
    if pollTicker then
        pollTicker:Cancel()
        pollTicker = nil
    end
end

-- Removes an instance from tracking and decrements its sound's active-
-- instance count - the ONE place this ever happens, so activeSoundCount
-- can never drift out of sync with trackedInstances.
local function ReleaseTrackedInstance(instanceID, pb)
    trackedInstances[instanceID] = nil
    if pb.handle then activeHandles[pb.handle] = nil end
    if primaryInstanceID == instanceID then primaryInstanceID = nil end
    local n = (activeSoundCount[pb.soundID] or 1) - 1
    if n > 0 then
        activeSoundCount[pb.soundID] = n
    else
        activeSoundCount[pb.soundID] = nil
    end
end

local function PollTrackedInstances()
    local now = Now()
    for instanceID, pb in pairs(trackedInstances) do
        local elapsed = now - pb.startedAt
        local durationCeiling = pb.duration and (pb.duration + NATURAL_END_GRACE) or nil

        if durationCeiling and elapsed >= durationCeiling then
            -- Known duration + grace margin has elapsed - end now
            -- regardless of what C_Sound.IsPlaying still claims. Also the
            -- ONLY end signal for an instance with no handle to poll.
            local state = BuildPlaybackState(instanceID, now)
            ReleaseTrackedInstance(instanceID, pb)
            SB:Fire("PLAYBACK_PROGRESS_ENDED", state)
        elseif elapsed > MAX_TRACKED_LIFETIME then
            -- Stuck - force-release without learning so activeSoundCount
            -- can recover and future plays of this sound aren't blocked.
            local state = BuildPlaybackState(instanceID, now)
            ReleaseTrackedInstance(instanceID, pb)
            SB:Fire("PLAYBACK_PROGRESS_ENDED", state)
        elseif not pb.handle or not canTrackPlayback then
            -- No handle (or this client can't query C_Sound.IsPlaying) -
            -- nothing further to observe. A known duration is already
            -- handled by the ceiling branch above. With no duration either,
            -- the play is known to have succeeded but its end can never be
            -- observed, so this still fires a real END (never a silent
            -- drop) once a reasonable window has passed.
            if not pb.duration then
                if elapsed > NEVER_STARTED_TIMEOUT then
                    local state = BuildPlaybackState(instanceID, now)
                    ReleaseTrackedInstance(instanceID, pb)
                    SB:Fire("PLAYBACK_PROGRESS_ENDED", state)
                end
            else
                SB:Fire("PLAYBACK_PROGRESS_UPDATE", BuildPlaybackState(instanceID, now))
            end
        elseif not pb.observedPlaying and elapsed > NEVER_STARTED_TIMEOUT then
            -- Never confirmed as actually started - drop silently, no
            -- learning, no PLAYBACK_PROGRESS_ENDED. This ambiguity (did
            -- PlaySoundFile lie about willPlay?) only applies when there
            -- was a handle to observe in the first place.
            ReleaseTrackedInstance(instanceID, pb)
        else
            local ok, isPlaying = pcall(C_Sound.IsPlaying, pb.handle)
            if not ok then
                -- An invalid/unrecognized handle errors rather than
                -- returning false on some clients - treat as "not
                -- playing" but never learn from it.
                ReleaseTrackedInstance(instanceID, pb)
            elseif isPlaying then
                if not pb.observedPlaying then
                    pb.observedPlaying = true
                    pb.playingStartedAt = now
                end
                -- Fired for every playing instance, not just the primary
                -- one, so older overlapping sounds still get a (demoted)
                -- progress indicator; state.isPrimary distinguishes them.
                SB:Fire("PLAYBACK_PROGRESS_UPDATE", BuildPlaybackState(instanceID, now))
            elseif pb.observedPlaying then
                -- Was playing, now isn't - a trustworthy natural end (only
                -- trusted once observed playing at least once, to avoid a
                -- startup-race false negative), unless interrupted or
                -- ambiguous (see activeSoundCount above: an overlapping
                -- instance's measured elapsed time can't be trusted, so
                -- it's excluded from learning though still displayed).
                if not pb.interrupted and not pb.ambiguousOverlap and pb.playingStartedAt then
                    SaveLearnedDuration(pb.soundID, now - pb.playingStartedAt)
                end
                local state = BuildPlaybackState(instanceID, now)
                ReleaseTrackedInstance(instanceID, pb)
                SB:Fire("PLAYBACK_PROGRESS_ENDED", state)
            end
            -- else: not yet observed playing and still within the
            -- timeout window - keep waiting, nothing to do this tick.
        end
    end
    if not next(trackedInstances) then
        StopPollTicker()
    end
end

-- Runs regardless of canTrackPlayback - a known-duration instance still
-- needs this ticker to reach its own duration-ceiling check above.
local function StartPollTicker()
    if pollTicker then return end
    pollTicker = C_Timer.NewTicker(POLL_INTERVAL, PollTrackedInstances)
end

-- Called right after a successful PlaySoundFile, from SB:PlaySound below.
-- Tracks EVERY successful call as its own instance, regardless of whether
-- a WoW handle came back. Returns the new instanceID.
local function TrackNewPlayback(soundID, handle, duration)
    -- Ambiguous: another instance of this exact sound is still active, so
    -- a measured elapsed time can't be trusted (see activeSoundCount
    -- above). Only affects LEARNING - `duration` itself is still passed
    -- through and displayed normally.
    local ambiguous = (activeSoundCount[soundID] or 0) > 0
    if ambiguous then
        -- Poison every OTHER currently-tracked instance of this sound too,
        -- not just the new one, since the first instance's "still playing"
        -- signal can be contaminated by the second just as easily. Only
        -- affects their learning eligibility, not their display duration.
        for _, pb in pairs(trackedInstances) do
            if pb.soundID == soundID and not pb.ambiguousOverlap then
                pb.ambiguousOverlap = true
            end
        end
    end
    activeSoundCount[soundID] = (activeSoundCount[soundID] or 0) + 1
    nextInstanceID = nextInstanceID + 1
    local instanceID = nextInstanceID
    trackedInstances[instanceID] = {
        soundID = soundID,
        handle = handle, -- optional - may be nil, see the section header above
        startedAt = Now(),
        playingStartedAt = nil, -- set on first confirmed-playing poll tick, only if handle is set
        observedPlaying = false,
        interrupted = false,
        ambiguousOverlap = ambiguous,
        duration = duration,
    }
    primaryInstanceID = instanceID
    StartPollTicker()
    SB:Fire("PLAYBACK_PROGRESS_STARTED", BuildPlaybackState(instanceID))
    return instanceID
end

--- Re-marks an already-tracked instance as primary, without starting a new
--- play or touching activeSoundCount/ambiguousOverlap - for a caller that
--- wants to fall back to an older still-playing sound after a newer,
--- shorter one finishes first. No-op if the instance is no longer tracked.
function SB:PromoteTrackedHandle(instanceID)
    if not trackedInstances[instanceID] then return end
    primaryInstanceID = instanceID
end

--- The WoW sound handle for the instance most recently started via
--- TrackNewPlayback - may be nil even for a currently-tracked instance
--- (see the section header above), or if nothing has played yet or the
--- primary instance has already ended.
function SB:GetPrimaryPlaybackHandle()
    local pb = primaryInstanceID and trackedInstances[primaryInstanceID]
    return pb and pb.handle or nil
end

local function GetChannel()
    local ch = SB.db and SB.db.settings and SB.db.settings.channel
    if ch and SB.VALID_CHANNELS[ch] then return ch end
    return "Master"
end

local function StopAllOwnSounds()
    for handle in pairs(activeHandles) do
        pcall(StopSound, handle, 0)
    end
    wipe(activeHandles)
    -- An explicit Stop, or an overlap-disabled replacement (which calls
    -- this function first), must clear progress state IMMEDIATELY rather
    -- than wait for the next poll tick. Every tracked instance is
    -- force-ended here synchronously; never learned as a real duration.
    for instanceID, pb in pairs(trackedInstances) do
        local state = BuildPlaybackState(instanceID)
        -- Marked distinct from a natural/duration-ceiling end so a
        -- listener (the Announcer's minimum-display-duration floor) knows
        -- to bypass its minimum and clear immediately.
        if state then state.stopped = true end
        ReleaseTrackedInstance(instanceID, pb)
        SB:Fire("PLAYBACK_PROGRESS_ENDED", state)
    end
end

-- Public wrapper - the Mini Soundbook's Stop button (Announcer.lua) and
-- "/sb stop" (Core.lua) both funnel through this single place rather
-- than reaching into activeHandles themselves.
function SB:StopAllSounds()
    StopAllOwnSounds()
    if SB.ClearQueuedSoundMessages then SB:ClearQueuedSoundMessages() end
    SB:Fire("PLAYBACK_STOPPED")
end

-- Tries each supported extension (.ogg, .mp3, .wav by default) for this
-- sound's base path until one actually plays. WoW can't tell us which
-- extension exists ahead of time (addons can't list folder contents), so
-- this is the only reliable way to support more than one file type without
-- requiring the user to specify it anywhere. A failed attempt (willPlay ==
-- false) never produces audio, so probing multiple extensions in sequence
-- is safe - only the one that actually exists ever makes a sound.
local function TryPlayFile(fileBase, channel, knownExt)
    local function Try(extension)
        local ok, willPlay, handle = pcall(PlaySoundFile, fileBase .. "." .. extension, channel)
        if not ok then return false end
        return willPlay, handle
    end
    if knownExt then
        local willPlay, handle = Try(knownExt)
        if willPlay then return true, handle, knownExt end
        -- The remembered extension stopped working (file renamed/removed) -
        -- fall through and re-probe all extensions below.
    end

    for _, ext in ipairs(SB.SOUND_EXTENSIONS) do
        if ext ~= knownExt then
            local willPlay, handle = Try(ext)
            if willPlay then return true, handle, ext end
        end
    end

    return false
end

-- Core playback. `source` is "local", "remote", or "test" - used only for
-- debug logging, never changes playback behaviour.
function SB:PlaySound(soundID, source)
    source = source or "local"

    local info = SB.registry[soundID]
    if not info then
        SB:Debug("PlaySound: unknown sound id '%s' (source=%s)", tostring(soundID), source)
        return false
    end

    local saved = SB:GetSoundSaved(soundID)
    if saved and saved.muted then
        SB:Debug("PlaySound: '%s' is muted, skipping (source=%s)", soundID, source)
        return false
    end

    -- Settings -> General -> "Allow Sounds while fights"/"...boss
    -- encounter" - applies to every trigger (local, macro, remote) since
    -- this is the one central playback function. SB.inCombat/inEncounter
    -- are maintained by Core.lua's PLAYER_REGEN_*/ENCOUNTER_* handlers.
    if SB.inEncounter and SB.db.settings.allowInEncounter == false then
        SB:Debug("PlaySound: '%s' skipped - in a boss encounter and 'Allow Sounds while boss encounter' is off (source=%s)", soundID, source)
        return false
    end
    if SB.inCombat and SB.db.settings.allowInCombat == false then
        SB:Debug("PlaySound: '%s' skipped - in combat and 'Allow Sounds while fights' is off (source=%s)", soundID, source)
        return false
    end

    -- "Alternative Sound" substitution (SoundAlternates.lua) - purely a
    -- LOCAL playback swap; soundID/info/analytics still refer to the real
    -- original throughout, only which file plays (and what duration the
    -- Announcement Bar times against) changes. Applies regardless of
    -- `source`, so a local click and a received remote play both get the
    -- substitution on this player's own audio output.
    local altEntry = saved and saved.useAlternate and SB.SoundAlternates and SB.SoundAlternates[soundID]
    local fileBase = (altEntry and altEntry.fileBase) or info.fileBase
    local durationSeconds = (altEntry and altEntry.durationSeconds) or info.durationSeconds
    local extCache = altEntry and resolvedAltExtension or resolvedExtension

    if missingFileBases[fileBase] then
        SB:Debug("PlaySound: cached missing file '%s' (source=%s)", fileBase, source)
        NotifyMissingLocalFile(fileBase, info, source)
        return false
    end

    local channel = GetChannel()
    local willPlay, handle, ext = TryPlayFile(fileBase, channel, extCache[soundID])

    if willPlay and supportsHandles == nil then
        supportsHandles = (handle ~= nil)
        if not supportsHandles then
            SB:Debug("PlaySoundFile did not return a sound handle - overlap-stop will not be able to cut off in-flight sounds individually.")
        end
    end

    if not willPlay then
        missingFileBases[fileBase] = true
        SB:Debug("No playable file found for '%s' (tried: %s) - is the file missing? source=%s",
            fileBase, table.concat(SB.SOUND_EXTENSIONS, ", "), source)
        NotifyMissingLocalFile(fileBase, info, source)
        return false
    end

    -- Probe first: a typo or missing file must never cut off a valid sound
    -- that is already playing. The new handle is not tracked yet, so this
    -- stops only older Soundbook-owned handles.
    if not (SB.db and SB.db.settings and SB.db.settings.allowOverlap) then
        StopAllOwnSounds()
    end

    extCache[soundID] = ext

    if handle then
        activeHandles[handle] = true
        -- WoW's classic PlaySoundFile API has no "this handle finished
        -- naturally" callback, so this is a safety-net timeout to bound
        -- activeHandles growth instead - every sound this addon plays is
        -- short, so 60s is far more than enough headroom. Harmless if
        -- StopAllOwnSounds already removed the handle by then.
        C_Timer.After(60, function()
            activeHandles[handle] = nil
        end)
    end
    -- Tracked regardless of whether a WoW handle came back - TrackNewPlayback/
    -- PollTrackedInstances treat the handle as fully optional. Wrapped in
    -- pcall so a tracking-side problem can never take down playback, which
    -- has already succeeded by this point.
    local ok, err = pcall(TrackNewPlayback, soundID, handle, durationSeconds)
    if not ok then SB:Debug("Playback tracking failed: %s", tostring(err)) end

    -- %s, not %d - category can be "Legacy"/"German Memes" (string) or 1/2 (number).
    SB:Debug("Played %s (category=%s, source=%s, channel=%s)%s", soundID, tostring(info.category), source, channel,
        altEntry and " [ALTERNATE - local substitution, soundID/analytics unaffected]" or "")

    -- "New" tag early-expiry counter (SoundRegistry.lua's SB:IsSoundNew) -
    -- every successful local/received play ultimately lands in this one
    -- function regardless of trigger source, so counting happens here
    -- rather than at each entry point. source == "test" (UI preview, e.g.
    -- Announcer's icon-drag preview) is excluded so it can't inflate the count.
    if SB.BumpNewSoundHeardCount and source ~= "test" then
        SB:BumpNewSoundHeardCount(soundID, source == "remote" and "received" or "self")
    end

    return true
end

local LOCAL_TRIGGER_CAPACITY = 10
local LOCAL_TRIGGER_REFILL = 6
local LOCAL_REPEAT_GAP = 0.08
local localTriggerTokens = LOCAL_TRIGGER_CAPACITY
local localTriggerUpdatedAt = Now()
local lastLocalTrigger = {}

local function AllowLocalTrigger(soundID)
    local now = Now()
    local elapsed = math.max(0, now - localTriggerUpdatedAt)
    localTriggerTokens = math.min(LOCAL_TRIGGER_CAPACITY, localTriggerTokens + elapsed * LOCAL_TRIGGER_REFILL)
    localTriggerUpdatedAt = now
    if lastLocalTrigger[soundID] and now - lastLocalTrigger[soundID] < LOCAL_REPEAT_GAP then return false end
    if localTriggerTokens < 1 then return false end
    localTriggerTokens = localTriggerTokens - 1
    lastLocalTrigger[soundID] = now
    return true
end

-- User/macro/slash-initiated playback: plays locally exactly once, then
-- (depending on the configured Playback Mode) asks Communication.lua to
-- notify other Soundbook users. Never called for sounds we received from
-- the network - that goes straight to SB:PlaySound to avoid echoes.
--
-- `targetOverride` (optional, see Macros.lua's SB.ParsePlayArg -
-- "GUILD"/"PARTY"/"RAID"/"FRIENDS"/"SELF"/"PLAYER:<name>") is used INSTEAD
-- of the Default Output Channel setting for this one trigger only,
-- normally passed by a macro's "::<Target>" suffix. Other callers omit it.
function SB:TriggerSound(soundID, targetOverride)
    local info = SB.registry[soundID]
    if not info and SB.ParsePlayArg then
        -- Also accept the compact "Category::Name::Target" form directly
        -- (not just via "/sb play"), so a plain Lua call like
        -- Soundbook:TriggerSound("Default::Auf Alkohol::Self") works too.
        local parsedID, parsedTarget = SB.ParsePlayArg(soundID)
        if parsedID ~= soundID and SB.registry[parsedID] then
            soundID = parsedID
            targetOverride = targetOverride or parsedTarget
            info = SB.registry[soundID]
        end
    end
    if not info then
        SB:Debug("TriggerSound: unknown sound id '%s'", tostring(soundID))
        return false
    end

    local saved = SB:GetSoundSaved(soundID)
    if saved and saved.muted then
        SB:Debug("TriggerSound: '%s' is muted", soundID)
        return false
    end

    if not AllowLocalTrigger(soundID) then
        SB:Debug("TriggerSound: local burst protection dropped '%s'", soundID)
        return false
    end

    local played = SB:PlaySound(soundID, "local")

    if played then
        -- Same "who's playing what" display the Favourites mini-window
        -- shows for remote sounds, just your own name. The resolved target
        -- mirrors what SB:DispatchDefaultOutput below sends with, so the
        -- Mini Soundbook can show the real destination (e.g. "Guild")
        -- instead of always "Self".
        local resolvedTarget = SB.ResolveOutputTarget and SB:ResolveOutputTarget(soundID, targetOverride)
            or targetOverride or (SB.db.settings and SB.db.settings.defaultOutputTarget) or "ALL"
        SB:Fire("LOCAL_SOUND_PLAYED", soundID, resolvedTarget)
        -- Analytics is NOT recorded here: a "play" should only enter shared
        -- statistics for a genuine social interaction (real sender AND real
        -- recipient), never a purely local trigger. See Communication.lua's
        -- HandleAck/HandleMuteAck, which record it once a real receipt
        -- confirmation comes back from another player's client. Per-sound
        -- "Default Output" override and raid-admin mute handling live
        -- inside SB:DispatchDefaultOutput itself, not duplicated here.
        if SB.DispatchDefaultOutput then
            SB:DispatchDefaultOutput(soundID, targetOverride)
        end
    end

    return played
end
