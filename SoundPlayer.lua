-- SoundPlayer.lua
--
-- The ONE and only place that ever calls PlaySoundFile in this addon.
-- The Soundbook button, the Favourites mini-window, the slash command,
-- macros, and incoming multiplayer messages all funnel through
-- SB:TriggerSound (locally-initiated) or SB:PlaySound (actual playback),
-- so behaviour (mute, overlap, channel) is always identical everywhere.
--
-- KNOWN TBC ANNIVERSARY LIMITATION - PER-SOUND VOLUME:
-- WoW's public API has no function to set the playback volume of an
-- individual sound or sound handle (no SetSoundHandleVolume or similar
-- exists on any currently shipping client, TBC Anniversary included).
-- The only volume control WoW exposes is global (Master/SFX CVars),
-- which this addon deliberately never touches, because that would change
-- the volume of every other sound in the game, not just Soundbook's.
-- The per-sound "Volume" slider in the Edit window therefore stores a
-- value in SavedVariables (for forward-compatibility and for anyone
-- consuming SB.registry externally) but that value is NOT currently
-- applied to actual audio output. This is documented, not faked.

local ADDON_NAME, SB = ...

-- Handles of sounds this addon itself started, so "stop overlap" only
-- ever stops Soundbook's own sounds and never touches unrelated game audio.
local activeHandles = {}
local supportsHandles = nil -- feature-detected lazily on first play

-- Which extension (from SB.SOUND_EXTENSIONS) actually exists on disk for a
-- given sound, discovered on first successful play and remembered from then
-- on so repeat plays don't re-probe missing extensions every time.
local resolvedExtension = {}
-- Same idea, but for the ALTERNATE file (SoundAlternates.lua) - kept in a
-- SEPARATE table, never the same slot as resolvedExtension above: the
-- original and the alternate are two different physical files that can
-- easily have different extensions, so caching one under the other's key
-- would make the probe try the wrong extension first for whichever file
-- wasn't actually resolved yet.
local resolvedAltExtension = {}
local missingFileBases = {}
local missingNoticeShown = {}

local function NotifyMissingLocalFile(fileBase, info, source)
    -- Remote failures stay silent. A later local click still gets its one
    -- useful explanation even when another player's request was what first
    -- populated the session-level missing-file cache.
    if source ~= "local" or missingNoticeShown[fileBase] then return end
    missingNoticeShown[fileBase] = true
    SB:Print(string.format(
        "Could not play '%s' - no matching file (tried .%s) next to Sounds.lua. If you just added it, a full client restart is required (see README).",
        info.name, table.concat(SB.SOUND_EXTENSIONS, "/.")
    ))
end

------------------------------------------------------------------------
-- Playback progress tracking - drives the Mini Soundbook's Announcement
-- Bar progress fill (FavouritesWindow.lua) and the "learn a sound's real
-- duration by observing it" fallback for anything SoundDurations.lua
-- doesn't already know. Central here (not guessed at by the UI).
------------------------------------------------------------------------

-- C_Sound.IsPlaying(handle) is what this whole feature is built on - not
-- guaranteed on every client build, so it's feature-detected once and
-- every call site checks `canTrackPlayback` first. If it's ever
-- unavailable, playback itself is completely unaffected - only the
-- progress bar/duration-learning silently never activates.
local canTrackPlayback = type(C_Sound) == "table" and type(C_Sound.IsPlaying) == "function"

-- [handle] = { soundID, startedAt (GetTimePreciseSec - when PlaySoundFile
--              was CALLED), playingStartedAt (when it was FIRST actually
--              observed playing - may lag startedAt: see below),
--              observedPlaying, interrupted, ambiguousOverlap,
--              duration (may be nil - unknown) }
--
-- WHY TWO TIMESTAMPS: WoW does not truly overlap two simultaneous plays of
-- the exact same sound file - calling PlaySoundFile a second time while an
-- identical sound is already playing still returns willPlay=true and a
-- real handle immediately, but the actual audible playback is silently
-- QUEUED until the first instance finishes. Measuring duration from
-- startedAt (call time) for that second, queued instance would include
-- the ENTIRE wait behind the first one - observed in testing as an
-- exactly-~2x-too-long learned duration. playingStartedAt (stamped the
-- first time C_Sound.IsPlaying actually reports true) is meant to be the
-- "this is when it actually started being audible" anchor - but even
-- that alone did not fully fix it in testing (see activeSoundCount just
-- below for the actual fix).
local trackedHandles = {}
-- The most recently STARTED handle still being tracked - what the
-- Announcement Bar shows progress for ("zeigt den zuletzt gestarteten,
-- noch relevanten Sound", explicit requirement for overlapping playback).
local primaryHandle = nil
local pollTicker = nil

-- [soundID] = how many instances of that exact sound are CURRENTLY
-- tracked (started, not yet confirmed ended). Even the playingStartedAt
-- anchor above did not fully solve the queued-overlap problem in testing
-- (still measured ~2x too long) - most likely because C_Sound.IsPlaying
-- can't actually tell "queued behind another instance of the same sound,
-- not yet audible" apart from "genuinely playing"; both read as true, so
-- no timestamp this addon can observe is trustworthy for a SECOND
-- instance of the same sound started while the first is still active.
-- Rather than risk another bad measurement (or a desynced-looking
-- progress bar), any such "ambiguous" instance is excluded from BOTH
-- learning and live display entirely - see
-- TrackNewPlayback/BuildPlaybackState/ReleaseTrackedHandle.
local activeSoundCount = {}

-- A handle that's never even been observed playing once (e.g. a bad file,
-- or PlaySoundFile lied about willPlay) would otherwise sit in
-- trackedHandles forever, since there's nothing to transition it out -
-- dropped, unlearned, after this many seconds.
local NEVER_STARTED_TIMEOUT = 3.0
-- Safety net for the OPPOSITE case: a handle that DID start playing but
-- whose C_Sound.IsPlaying somehow never flips back to false (a client
-- quirk on some file, a missed transition, anything) would otherwise sit
-- in trackedHandles - and keep activeSoundCount for that sound elevated -
-- forever. That wouldn't just leave one stale entry: since activeSoundCount
-- never drops back to 0, EVERY future play of that same sound would look
-- "ambiguous" and permanently never learn a duration, even in complete
-- isolation. Force-released (never learned from - we can't trust an
-- instance that ran this long anyway) past this many seconds regardless
-- of its playing state.
local MAX_TRACKED_LIFETIME = 90.0
local POLL_INTERVAL = 0.08

local function Now()
    return GetTimePreciseSec and GetTimePreciseSec() or GetTime()
end

-- DISPLAY elapsed is measured from startedAt (when PlaySoundFile was
-- CALLED), not from playingStartedAt (first confirmed-playing poll tick).
-- This is a deliberate split from LEARNING (which still uses
-- playingStartedAt - see the natural-end branch in PollTrackedHandles):
-- for a sound whose duration is already KNOWN, the Announcement Bar just
-- needs a reasonable-looking, ALWAYS-AVAILABLE animation, and waiting on
-- C_Sound.IsPlaying confirmation caused two real problems in testing - a
-- ~80ms confirmation delay produced a visible stutter, and retriggering
-- the SAME sound while it was still playing made C_Sound.IsPlaying
-- unable to tell the two instances apart, which used to blank the bar out
-- completely (explicit bug report - "das sollte eigentlich dann
-- neustarten... egal ob Overlapping an oder aus"). Call time is always
-- immediately known and needs no such confirmation, so display simply
-- doesn't depend on it - only the stricter LEARNING path still does,
-- since THAT actually needs to be numerically trustworthy.
local function BuildPlaybackState(handle, now)
    local pb = trackedHandles[handle]
    if not pb then return nil end
    now = now or Now()
    local elapsed = math.max(0, now - pb.startedAt)
    local progress = nil
    if pb.duration and pb.duration > 0 then
        progress = math.max(0, math.min(1, elapsed / pb.duration))
    end
    return {
        soundID = pb.soundID,
        handle = handle,
        startedAt = pb.startedAt,
        duration = pb.duration,
        elapsed = elapsed,
        progress = progress,
        isPrimary = (handle == primaryHandle),
    }
end

-- Learned only from a genuinely NATURAL end (never observed as
-- interrupted) - and only ever fills in a still-unknown duration, never
-- overwrites an existing precomputed/already-learned one. Explicit
-- requirement: an interrupted/failed playback must never pollute a real
-- duration value, and a good value already on file must never be
-- clobbered by a later, possibly-imprecise measurement.
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

-- Removes a handle from tracking and decrements its sound's active-
-- instance count - the ONE place this ever happens, so activeSoundCount
-- can never drift out of sync with trackedHandles.
local function ReleaseTrackedHandle(handle, pb)
    trackedHandles[handle] = nil
    activeHandles[handle] = nil
    if primaryHandle == handle then primaryHandle = nil end
    local n = (activeSoundCount[pb.soundID] or 1) - 1
    if n > 0 then
        activeSoundCount[pb.soundID] = n
    else
        activeSoundCount[pb.soundID] = nil
    end
end

local function PollTrackedHandles()
    local now = Now()
    for handle, pb in pairs(trackedHandles) do
        if not pb.observedPlaying and (now - pb.startedAt) > NEVER_STARTED_TIMEOUT then
            -- Never confirmed as actually started - drop silently, no
            -- learning, no PLAYBACK_PROGRESS_ENDED (nothing to end).
            ReleaseTrackedHandle(handle, pb)
        elseif (now - pb.startedAt) > MAX_TRACKED_LIFETIME then
            -- Stuck (see MAX_TRACKED_LIFETIME's own comment) - force-
            -- release without learning, so activeSoundCount can recover
            -- and future plays of this sound aren't blocked forever.
            local state = BuildPlaybackState(handle, now)
            ReleaseTrackedHandle(handle, pb)
            SB:Fire("PLAYBACK_PROGRESS_ENDED", state)
        else
            local ok, isPlaying = pcall(C_Sound.IsPlaying, handle)
            if not ok then
                -- An invalid/unrecognized handle errors rather than
                -- returning false on some clients - treat identically to
                -- "not playing", but never learn from it (we can't trust
                -- the elapsed time against a call that just errored).
                ReleaseTrackedHandle(handle, pb)
            elseif isPlaying then
                if not pb.observedPlaying then
                    pb.observedPlaying = true
                    pb.playingStartedAt = now
                end
                -- Fired for EVERY playing handle now, not just the primary
                -- one - explicit request: older sounds that haven't
                -- finished yet, even after a newer one took over the
                -- display, should still get a (demoted) progress
                -- indicator. state.isPrimary (BuildPlaybackState) is what
                -- lets listeners tell which is which.
                SB:Fire("PLAYBACK_PROGRESS_UPDATE", BuildPlaybackState(handle, now))
            elseif pb.observedPlaying then
                -- Was playing, now isn't - a genuine natural end, UNLESS
                -- this handle was explicitly stopped by us (interrupted)
                -- or ambiguous (see activeSoundCount above - an instance
                -- that started while another instance of the SAME sound
                -- was still active never has a trustworthy MEASURED
                -- elapsed time, so it's excluded from LEARNING here even
                -- though its display duration was still shown normally).
                if not pb.interrupted and not pb.ambiguousOverlap and pb.playingStartedAt then
                    SaveLearnedDuration(pb.soundID, now - pb.playingStartedAt)
                end
                local state = BuildPlaybackState(handle, now)
                ReleaseTrackedHandle(handle, pb)
                SB:Fire("PLAYBACK_PROGRESS_ENDED", state)
            end
            -- else: not yet observed playing and still within the
            -- timeout window - keep waiting, nothing to do this tick.
        end
    end
    if not next(trackedHandles) then
        StopPollTicker()
    end
end

local function StartPollTicker()
    if pollTicker or not canTrackPlayback then return end
    pollTicker = C_Timer.NewTicker(POLL_INTERVAL, PollTrackedHandles)
end

-- Called right after a successful PlaySoundFile, from SB:PlaySound below.
local function TrackNewPlayback(soundID, handle, duration)
    if not canTrackPlayback or not handle then return end
    -- Ambiguous: another instance of this EXACT sound is still active -
    -- C_Sound.IsPlaying doesn't seem to track each PlaySoundFile call of
    -- an identical file independently, so a MEASURED elapsed time can't
    -- be trusted here (confirmed in testing: a ~2x-too-long learned
    -- duration). This ONLY affects LEARNING (SaveLearnedDuration, gated
    -- on ambiguousOverlap in PollTrackedHandles) - `duration` itself (once
    -- known - precomputed or already learned) is always still passed
    -- through and displayed. Display doesn't need C_Sound.IsPlaying at
    -- all (see BuildPlaybackState) - it's just a call-time countdown, so
    -- retriggering the same sound mid-playback correctly restarts the bar
    -- instead of going blank, exactly as expected, regardless of overlap.
    local ambiguous = (activeSoundCount[soundID] or 0) > 0
    if ambiguous then
        -- Poison every OTHER currently-tracked instance of this exact
        -- sound too, the moment a second one starts - not just the new
        -- one - since the first instance's own "still playing" signal can
        -- be contaminated by the second, later one just as easily. Only
        -- affects THEIR learning eligibility now, not their own already-
        -- assigned display duration.
        for h, pb in pairs(trackedHandles) do
            if pb.soundID == soundID and not pb.ambiguousOverlap then
                pb.ambiguousOverlap = true
            end
        end
    end
    activeSoundCount[soundID] = (activeSoundCount[soundID] or 0) + 1
    trackedHandles[handle] = {
        soundID = soundID,
        startedAt = Now(),
        playingStartedAt = nil, -- set on the first confirmed-playing poll tick
        observedPlaying = false,
        interrupted = false,
        ambiguousOverlap = ambiguous,
        duration = duration,
    }
    primaryHandle = handle
    StartPollTicker()
    SB:Fire("PLAYBACK_PROGRESS_STARTED", BuildPlaybackState(handle))
end

--- Re-marks an ALREADY-tracked handle as the primary one, without
--- starting a new play or touching activeSoundCount/ambiguousOverlap -
--- used when the Mini Soundbook "falls back" to an older still-playing
--- sound after a newer, shorter one finishes first (see
--- FavouritesWindow.lua's HideNowPlaying/TryPromoteSecondary). Future
--- PLAYBACK_PROGRESS_UPDATE/ENDED events for this handle report
--- isPrimary=true again from the very next poll tick. No-op if the handle
--- isn't tracked anymore (already ended by the time this is called).
function SB:PromoteTrackedHandle(handle)
    if not trackedHandles[handle] then return end
    primaryHandle = handle
end

local function GetChannel()
    local ch = SB.db and SB.db.settings and SB.db.settings.channel
    if ch and SB.VALID_CHANNELS[ch] then return ch end
    return "Master"
end

local function StopAllOwnSounds()
    for handle in pairs(activeHandles) do
        -- Mark BEFORE the actual StopSound call - the very next poll tick
        -- must already see this as "we did this on purpose", not a
        -- natural end, so it's never learned as a real duration. Covers
        -- every stop path that funnels through here: the Stop button,
        -- "/sb stop", and a new sound cutting off the previous one when
        -- overlap is disabled.
        if trackedHandles[handle] then trackedHandles[handle].interrupted = true end
        pcall(StopSound, handle, 0)
    end
    wipe(activeHandles)
end

-- Public wrapper - the Mini Soundbook's Stop button and "/sb stop" (see
-- FavouritesWindow.lua / Core.lua) both funnel through this single place
-- rather than reaching into activeHandles themselves.
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

    -- "Alternative Sound" substitution (SoundAlternates.lua, explicit
    -- request) - purely a LOCAL playback swap. soundID/info/analytics/
    -- everything else above and below this block still refers to the real
    -- original the whole time; only WHICH FILE actually plays, and what
    -- duration the Announcement Bar times itself against, changes. Applies
    -- identically regardless of `source` - a self-triggered click and a
    -- received remote play both funnel through this one function, which is
    -- exactly what makes this work for the streaming use case it was built
    -- for (this player's own local audio output is what a stream captures,
    -- whether they clicked it themselves or someone else sent it to them).
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
        -- Explicit requirement: activeHandles must not grow unbounded over
        -- a long session. WoW's classic PlaySoundFile API has no "this
        -- handle finished naturally" callback to clean up on precisely, so
        -- this is a generous safety-net timeout instead - every meme/effect
        -- sound this addon plays is short (a few seconds at most), so 60s
        -- is far more than enough headroom while still bounding growth.
        -- Harmless if the handle was already removed by StopAllOwnSounds in
        -- the meantime (activeHandles[handle] is simply already nil/gone).
        C_Timer.After(60, function()
            activeHandles[handle] = nil
        end)
        -- Progress-bar/duration-learning tracking - see the block near the
        -- top of this file. Wrapped in pcall: a tracking-side problem must
        -- never be able to take down actual playback, which has already
        -- fully succeeded by this point regardless of what happens next.
        local ok, err = pcall(TrackNewPlayback, soundID, handle, durationSeconds)
        if not ok then SB:Debug("Playback tracking failed: %s", tostring(err)) end
    end

    -- %s, not %d - category can be "Legacy"/"German Memes" (string) or 1/2 (number).
    SB:Debug("Played %s (category=%s, source=%s, channel=%s)%s", soundID, tostring(info.category), source, channel,
        altEntry and " [ALTERNATE - local substitution, soundID/analytics unaffected]" or "")

    -- "New" tag early-expiry counter (explicit request, SoundRegistry.lua's
    -- SB:IsSoundNew) - this ONE function is where every successful local
    -- play OR received play (source "local"/"remote") ultimately lands,
    -- regardless of how it got triggered (click, macro, slash command,
    -- SendMenu.lua's explicit "send to..." via PlayLocally, or a genuine
    -- received play from HandlePlayCommand) - the single right place to
    -- count both sides of "3 mal selber abgespielt/versendet UND 3 mal
    -- received" without hooking every individual entry point separately.
    -- source == "test" (e.g. the Announcer icon-drag preview's 10-second
    -- easter-egg sound - Announcer.lua) is a UI-only exercise of this
    -- function, never a genuine play - explicitly excluded here so it
    -- can't inflate a sound's "New" early-expiry counter.
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
-- `targetOverride` (optional) is an output-target value (see Macros.lua's
-- SB.ParsePlayArg / Communication.lua's SB.ComputeOutputTargetOptions -
-- "GUILD"/"PARTY"/"RAID"/"FRIENDS"/"SELF"/"PLAYER:<name>") that, if given,
-- is used INSTEAD of Settings -> Default Output Channel for this one
-- trigger only - normally passed by a macro's "::<Target>" suffix. Every
-- other caller (button/slot clicks, plain "/sb play <id>") omits it and
-- keeps deferring to the Default Output Channel setting exactly as before.
function SB:TriggerSound(soundID, targetOverride)
    local info = SB.registry[soundID]
    if not info and SB.ParsePlayArg then
        -- soundID wasn't a registered id as-is - also accept the compact
        -- "Category::Name::Target" form directly (not just via the "/sb
        -- play" slash command), so a plain Lua call like
        -- Soundbook:TriggerSound("Default::Auf Alkohol::Self") - e.g. from
        -- a WeakAura's "Run Custom Code" - works without needing the
        -- two-argument form.
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
        -- shows for remote sounds, just your own name - one central place
        -- (here) covers every local trigger (click, macro, slash command)
        -- instead of each UI entry point announcing it. The resolved
        -- target (mirrors exactly what SB:DispatchDefaultOutput below is
        -- about to send with, per-sound "Default Output" override
        -- included - see SB:ResolveOutputTarget, Communication.lua) rides
        -- along too, so the Mini Soundbook can show the real destination
        -- (e.g. "Guild") instead of always "Self" - see FavouritesWindow.
        -- lua's LOCAL_SOUND_PLAYED handler.
        local resolvedTarget = SB.ResolveOutputTarget and SB:ResolveOutputTarget(soundID, targetOverride)
            or targetOverride or (SB.db.settings and SB.db.settings.defaultOutputTarget) or "ALL"
        SB:Fire("LOCAL_SOUND_PLAYED", soundID, resolvedTarget)
        -- Analytics is NOT recorded here anymore - explicit requirement:
        -- this is a multiplayer soundbook, and a "play" should only ever
        -- enter the shared statistics when it was a genuine social
        -- interaction (a real sender AND a real recipient), never a purely
        -- local/self trigger, and never a send that had nobody around to
        -- actually receive it. See Communication.lua's HandleAck/
        -- HandleMuteAck, which now record the play only once a REAL
        -- receipt confirmation comes back from another player's client -
        -- that's the earliest point this can honestly be known.
        -- Where (if anywhere) this also gets sent - Settings -> Favourites
        -- Window -> "Default Output Channel" (SB.db.settings.
        -- defaultOutputTarget); "ALL" (default) is the existing
        -- broadcast-everything-enabled behaviour, unchanged. A raid-admin
        -- mute (Communication.lua) and per-sound considerations are all
        -- handled inside SB:DispatchDefaultOutput itself now, including the
        -- friend exemption for a single-person target - never duplicated
        -- here.
        if SB.DispatchDefaultOutput then
            SB:DispatchDefaultOutput(soundID, targetOverride)
        end
    end

    return played
end
