-- Database.lua
-- Atomic SavedVariables preparation: copy -> migrate -> default -> sanitize
-- -> validate -> commit. The original table is never mutated on a failed or
-- future-version migration.

local ADDON_NAME, SB = ...

local MAX_COPY_DEPTH = 48
local MAX_COPY_ENTRIES = 200000

local function DeepCopy(source)
    local seen, entryCount = {}, 0
    local function Copy(value, depth)
        if type(value) ~= "table" then return value end
        if depth > MAX_COPY_DEPTH then error("database nesting is too deep") end
        if seen[value] then error("database contains a cyclic table") end
        local result = {}
        seen[value] = result
        for key, child in pairs(value) do
            entryCount = entryCount + 1
            if entryCount > MAX_COPY_ENTRIES then error("database contains too many entries") end
            local keyType = type(key)
            if keyType == "string" or keyType == "number" or keyType == "boolean" then
                local childType = type(child)
                if childType == "nil" or childType == "string" or childType == "number"
                    or childType == "boolean" or childType == "table" then
                    result[Copy(key, depth + 1)] = Copy(child, depth + 1)
                end
            end
        end
        seen[value] = nil
        return result
    end
    return Copy(source, 1)
end

local function EnsureTable(parent, key)
    if type(parent[key]) ~= "table" then parent[key] = {} end
    return parent[key]
end

local function ClampNumber(value, fallback, minimum, maximum)
    if not SB.IsFiniteNumber(value) then value = fallback end
    if value < minimum then return minimum end
    if value > maximum then return maximum end
    return value
end

local function BooleanOr(value, fallback)
    if type(value) == "boolean" then return value end
    return fallback
end

local function SanitizePosition(position, fallback)
    local validPoints = {
        TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true,
        RIGHT = true, BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
    }
    if type(position) ~= "table" then position = {} end
    position.point = validPoints[position.point] and position.point or fallback.point
    position.relPoint = validPoints[position.relPoint] and position.relPoint or fallback.relPoint
    position.x = ClampNumber(position.x, fallback.x, -10000, 10000)
    position.y = ClampNumber(position.y, fallback.y, -10000, 10000)
    return position
end

local function SanitizeDatabase(db, defaults)
    local settings = EnsureTable(db, "settings")
    local ui = EnsureTable(db, "ui")
    EnsureTable(db, "sounds")
    EnsureTable(db, "categories")
    EnsureTable(db, "knownUsers")
    EnsureTable(db, "knownSoundIDs")
    EnsureTable(db, "soundDurations")
    EnsureTable(db, "newSoundHeardCounts")
    -- Online Greetings' local per-player received-sound tallies (see
    -- Core.lua's GetDefaultDB comment) - same lightweight
    -- EnsureTable-only treatment as newSoundHeardCounts above; malformed
    -- per-player/per-sound entries are skipped defensively at READ time
    -- instead (SB:GetGreetingSoundFor/BumpGreetingStat), not sanitized
    -- eagerly here.
    EnsureTable(db, "greetingStats")
    -- The persisted fallback Greeting Sound assignment for a player with no
    -- received history yet (see Core.lua's GetDefaultDB comment) - same
    -- lightweight treatment; a malformed or now-invalid entry is simply
    -- replaced the next time it's read (SB:GetGreetingFallbackSoundFor),
    -- never sanitized eagerly here.
    EnsureTable(db, "greetingFallbackSounds")

    -- The persisted "latest update batch" (SoundRegistry.lua's
    -- BackfillAddedAt/GetLatestSoundUpdateSoundIDs) - deliberately separate
    -- from the temporary New tag's own addedAt timestamps, so Settings'
    -- "Latest Sound Updates" keeps working long after those expire.
    local latestUpdate = EnsureTable(db, "latestSoundUpdate")
    local rawUpdateIDs = type(latestUpdate.soundIDs) == "table" and latestUpdate.soundIDs or {}
    local cleanUpdateIDs, seenUpdateIDs = {}, {}
    for _, soundID in ipairs(rawUpdateIDs) do
        if SB.IsValidSoundID(soundID) and not seenUpdateIDs[soundID] then
            table.insert(cleanUpdateIDs, soundID)
            seenUpdateIDs[soundID] = true
        end
    end
    latestUpdate.soundIDs = cleanUpdateIDs
    latestUpdate.autoShown = BooleanOr(latestUpdate.autoShown, false)

    for soundID, saved in pairs(db.sounds) do
        if type(soundID) == "string" and SB.registry and SB.registry[soundID] then
            if type(saved) ~= "table" then saved = {}; db.sounds[soundID] = saved end
            saved.favourite = BooleanOr(saved.favourite, false)
            saved.muted = BooleanOr(saved.muted, false)
            saved.useAlternate = BooleanOr(saved.useAlternate, false)
            saved.volume = ClampNumber(saved.volume, 100, 0, 100)
            if saved.displayName ~= nil then
                local displayName = SB.TrimText(saved.displayName)
                if not displayName or displayName == "" or #displayName > 80
                    or displayName:find("[%z\1-\31\127]") then saved.displayName = nil
                else saved.displayName = displayName end
            end
            if saved.outputOverride ~= nil and not SB.IsValidOutputTarget(saved.outputOverride) then
                saved.outputOverride = nil
            end
            if saved.addedAt ~= nil and (not SB.IsFiniteNumber(saved.addedAt) or saved.addedAt <= 0) then
                saved.addedAt = nil
            end
        end
    end

    for soundID, duration in pairs(db.soundDurations) do
        if not SB.IsValidSoundID(soundID) or not SB.IsFiniteNumber(duration) or duration <= 0 or duration > 600 then
            db.soundDurations[soundID] = nil
        end
    end

    for key, info in pairs(db.knownUsers) do
        if type(key) ~= "string" or #key > 140 or type(info) ~= "table" then
            db.knownUsers[key] = nil
        else
            info.lastSeen = ClampNumber(info.lastSeen, 0, 0, 5000000000)
            if type(info.version) ~= "string" or #info.version > 80 or info.version:find("[%z\1-\31\127]") then
                info.version = nil
            end
            if info.playerName ~= nil and not SB.IsValidPlayerTarget(info.playerName) then info.playerName = nil end
        end
    end

    local booleanSettings = {
        "allowOverlap", "allowInCombat", "allowInEncounter", "showFavouritesWindow",
        "receiveFriends", "receiveRaid", "receiveGuild", "receiveDirect",
        "soundQueueEnabled", "notifyOnMuted", "notifyMutedAttempts", "notifyFriendReceipts",
        "analyticsEnabled", "favKeybindPanelCollapsed", "introSeen", "newSoundsPopupOptOut", "debug",
    }
    for _, key in ipairs(booleanSettings) do
        settings[key] = BooleanOr(settings[key], defaults.settings[key])
    end
    -- No separate receiveParty any more - receiveRaid covers both (see
    -- SB.ResolveGroupChannel, Communication.lua). The v25->v26 migration
    -- (Core.lua) already folded any old value into receiveRaid once.
    settings.receiveParty = nil

    local modes = EnsureTable(settings, "broadcastModes")
    -- RAID covers Party too (see SB.ResolveGroupChannel, Communication.lua)
    -- - no separate PARTY key exists any more; the v24->v25 migration
    -- (Core.lua) already folded any old PARTY flag into RAID once.
    for _, mode in ipairs({ "FRIENDS", "RAID", "GUILD" }) do
        modes[mode] = BooleanOr(modes[mode], defaults.settings.broadcastModes[mode])
    end
    modes.PARTY = nil
    settings.channel = SB.VALID_CHANNELS[settings.channel] and settings.channel or defaults.settings.channel
    settings.defaultOutputTarget = SB.IsValidOutputTarget(settings.defaultOutputTarget)
        and settings.defaultOutputTarget or defaults.settings.defaultOutputTarget
    settings.remoteCooldown = ClampNumber(settings.remoteCooldown, defaults.settings.remoteCooldown, 0.25, 10)
    settings.announceDuration = ClampNumber(settings.announceDuration, defaults.settings.announceDuration, 0, 15)
    settings.mainFontScale = ClampNumber(settings.mainFontScale, defaults.settings.mainFontScale, 0.8, 1.3)
    settings.miniFontScale = ClampNumber(settings.miniFontScale, defaults.settings.miniFontScale, 0.8, 1.3)
    settings.sortMode = (settings.sortMode == "alphabetical" or settings.sortMode == "popularity")
        and settings.sortMode or defaults.settings.sortMode

    -- Explicit bugfix: this used to whitelist against SB.AVAILABLE_FONTS,
    -- the 4 client-shipped fonts ONLY - a font picked from LibSharedMedia
    -- (ElvUI/WeakAuras/SharedMedia/...), a real supported choice (see
    -- SB.GetAvailableFonts, Core.lua), was never in that list, so it got
    -- silently reset back to the default here on every single login even
    -- though the saved path itself was perfectly valid ("Schrift springt
    -- nach jedem Reload auf Default zurück" - explicit bug report). Using
    -- the FULL list (SB.GetAvailableFonts) instead of the narrow one would
    -- only trade one ordering problem for another - LibSharedMedia itself,
    -- or whichever addon registers the font with it, may simply not have
    -- loaded yet at this exact point in Soundbook's own ADDON_LOADED. A
    -- basic format check (real non-empty path, no control characters) is
    -- the right level of sanitation here - corruption is what this guards
    -- against, not "not currently in a list that may not be complete yet".
    if not SB.IsSafeWireText(settings.mainFont, 260) then
        settings.mainFont = defaults.settings.mainFont
    end
    if not SB.IsSafeWireText(settings.miniFont, 260) then
        settings.miniFont = defaults.settings.miniFont
    end

    local receiveMute = EnsureTable(settings, "receiveMute")
    receiveMute.active = BooleanOr(receiveMute.active, false)
    receiveMute.previous = type(receiveMute.previous) == "table" and receiveMute.previous or {}
    for _, mode in ipairs({ "FRIENDS", "PARTY", "RAID", "GUILD", "DIRECT" }) do
        receiveMute.previous[mode] = BooleanOr(receiveMute.previous[mode], true)
    end
    if not SB.IsFiniteNumber(receiveMute.expiresAt) or receiveMute.expiresAt <= 0 then receiveMute.expiresAt = nil end
    if receiveMute.durationMinutes ~= 30 and receiveMute.durationMinutes ~= 60 then receiveMute.durationMinutes = nil end

    local mutedPlayers = EnsureTable(settings, "mutedPlayers")
    for key, expiresAt in pairs(mutedPlayers) do
        if type(key) ~= "string" or #key > 140 or not SB.IsFiniteNumber(expiresAt) or expiresAt <= 0 then
            mutedPlayers[key] = nil
        end
    end

    local cleanFavourites, seen = {}, {}
    local favourites = type(db.favourites) == "table" and db.favourites or {}
    for slot = 1, SB.MAX_FAVOURITES do
        local soundID = favourites[slot]
        if SB.IsValidSoundID(soundID) and not seen[soundID] then
            cleanFavourites[slot] = soundID
            seen[soundID] = true
        end
    end
    db.favourites = cleanFavourites

    local keybinds = type(settings.favKeybinds) == "table" and settings.favKeybinds or {}
    local cleanKeybinds = {}
    for slot = 1, SB.MAX_FAVOURITES do
        local binding = keybinds[slot]
        if type(binding) == "string" and #binding <= 80 and not binding:find("[%z\1-\31\127]") then
            cleanKeybinds[slot] = binding
        end
    end
    settings.favKeybinds = cleanKeybinds

    for category, fallback in pairs(defaults.categories) do
        local saved = db.categories[category]
        if type(saved) ~= "table" then saved = {}; db.categories[category] = saved end
        local name = SB.TrimText(saved.name)
        saved.name = (name and name ~= "" and #name <= 40 and not name:find("[%z\1-\31\127]")) and name or fallback.name
        local iconType = type(saved.icon)
        if (iconType ~= "string" and iconType ~= "number") or saved.icon == "" then saved.icon = fallback.icon end
    end

    local history = type(db.history) == "table" and db.history or {}
    local cleanHistory = {}
    for i = 1, math.min(#history, 10) do
        local entry = history[i]
        if type(entry) == "table" and (SB.IsValidSoundID(entry.soundID) or type(entry.soundName) == "string") then
            if type(entry.soundName) == "string" and (#entry.soundName > 120 or entry.soundName:find("[%z\1-\31\127]")) then
                entry.soundName = nil
            end
            if type(entry.sender) == "string" and not SB.IsValidPlayerTarget(entry.sender) then entry.sender = nil end
            if type(entry.source) ~= "string" or #entry.source > 30 then entry.source = nil end
            if not SB.IsFiniteNumber(entry.timestamp) or entry.timestamp <= 0 then entry.timestamp = nil end
            cleanHistory[#cleanHistory + 1] = entry
        end
    end
    db.history = cleanHistory

    ui.mainPos = SanitizePosition(ui.mainPos, defaults.ui.mainPos)
    ui.favPos = SanitizePosition(ui.favPos, defaults.ui.favPos)
    ui.mainWidth = ClampNumber(ui.mainWidth, defaults.ui.mainWidth, 560, 720)
    ui.mainHeight = ClampNumber(ui.mainHeight, defaults.ui.mainHeight, 560, 760)
    ui.favWidth = ClampNumber(ui.favWidth, defaults.ui.favWidth, 0, 1200)
    ui.favHeight = ClampNumber(ui.favHeight, defaults.ui.favHeight, 0, 900)
    ui.favAlphaIdle = ClampNumber(ui.favAlphaIdle, defaults.ui.favAlphaIdle, 10, 100)
    ui.favAlphaHover = ClampNumber(ui.favAlphaHover, defaults.ui.favAlphaHover, 10, 100)
    ui.favLocked = BooleanOr(ui.favLocked, defaults.ui.favLocked)
    ui.favShown = BooleanOr(ui.favShown, defaults.ui.favShown)
    ui.currentPage = type(ui.currentPage) == "table" and ui.currentPage or {}
    for key, page in pairs(ui.currentPage) do
        if type(key) ~= "string" or not SB.IsFiniteNumber(page) or page < 1 then
            ui.currentPage[key] = nil
        else
            ui.currentPage[key] = math.floor(page)
        end
    end
    local allowedTags = {
        New = true, Legendary = true, Trending = true, Popular = true,
        ["Community Favourite"] = true, Cringe = true, Dusty = true,
    }
    ui.tagFilters = type(ui.tagFilters) == "table" and ui.tagFilters or {}
    for key, value in pairs(ui.tagFilters) do
        if not allowedTags[key] or value ~= true then ui.tagFilters[key] = nil end
    end
    ui.minimap = type(ui.minimap) == "table" and ui.minimap or {}
    ui.minimap.hide = BooleanOr(ui.minimap.hide, defaults.ui.minimap.hide)
    ui.minimap.angle = ClampNumber(ui.minimap.angle, defaults.ui.minimap.angle, 0, 360)

    ui.announcer = type(ui.announcer) == "table" and ui.announcer or {}
    ui.announcer.pos = SanitizePosition(ui.announcer.pos, defaults.ui.announcer.pos)
    ui.announcer.shown = BooleanOr(ui.announcer.shown, defaults.ui.announcer.shown)
    -- ui.announcer.locked was folded into the single shared ui.layoutLocked
    -- below (3.0 spec section 16 - one lock covers Main shell + Announcer
    -- movement) - no longer read anywhere, left unsanitized/inert rather
    -- than deleted outright.
    ui.announcer.alphaIdle = ClampNumber(ui.announcer.alphaIdle, defaults.ui.announcer.alphaIdle, 10, 100)
    ui.announcer.alphaHover = ClampNumber(ui.announcer.alphaHover, defaults.ui.announcer.alphaHover, 10, 100)
    ui.layoutLocked = BooleanOr(ui.layoutLocked, defaults.ui.layoutLocked)

    local validPopoutDirections = { AUTO = true, RIGHT = true, LEFT = true, UP = true, DOWN = true }
    ui.popoutDirection = validPopoutDirections[ui.popoutDirection] and ui.popoutDirection or defaults.ui.popoutDirection

    ui.categoryCollapsed = type(ui.categoryCollapsed) == "table" and ui.categoryCollapsed or {}
    for key, value in pairs(ui.categoryCollapsed) do
        if (type(key) ~= "string" and type(key) ~= "number") or value ~= true then
            ui.categoryCollapsed[key] = nil
        end
    end

    -- LEGACY/compatibility data only (Phase-1 cleanup note): this used to
    -- back the right-side broadcast tabs' per-bucket MULTI-select
    -- recipient set (Guild/Raid/Friends, any combination simultaneously
    -- active, plus a `selfOnly` flag). That UI and its routing consumer
    -- (SB.ComputeEffectiveRecipients/DispatchDefaultOutput's old "SUBSET"
    -- target) have both been removed entirely - nothing reads this data
    -- for routing any more. The shape-repair/sanitization below is left
    -- fully intact regardless, purely so an existing player's old saved
    -- selections stay in a valid shape rather than causing a nil-index
    -- error on load - not because anything still consumes them.
    ui.outputRail = type(ui.outputRail) == "table" and ui.outputRail or {}
    if type(ui.outputRail.selected) ~= "table" then
        -- One-time migration from the OLD single-bucket shape (Soundbook
        -- 3.0's first Output Rail: one `mode` + one flat `recipients`
        -- list, single-select only) into the new per-bucket shape. Once
        -- `selected` exists, this branch never runs again for this player.
        local migrated = { GUILD = {}, RAID = {}, FRIENDS = {} }
        local oldMode = ui.outputRail.mode
        local oldRecipients = type(ui.outputRail.recipients) == "table" and ui.outputRail.recipients or {}
        if migrated[oldMode] then
            for _, name in ipairs(oldRecipients) do
                if SB.IsValidPlayerTarget(name) then table.insert(migrated[oldMode], name) end
            end
        end
        ui.outputRail.selected = migrated
        -- The OLD global defaultOutputTarget=="SELF" (safer-first-start,
        -- or the player's own deliberate choice) maps directly onto the
        -- new selfOnly flag. Every other old value ("ALL"/"GUILD"/"RAID"/
        -- "FRIENDS"/"PLAYER:x") deliberately does NOT try to reconstruct
        -- "everyone reachable" here - guild/friends/group rosters are
        -- frequently still empty this early in login, so guessing "who
        -- was reachable" at migration time would be unreliable. Existing
        -- players with one of those old values simply start with nothing
        -- selected (safe/local-only) and pick their broadcast targets
        -- once on the new tabs - the same "never silently resets an
        -- existing setup to something wrong" principle already applied
        -- elsewhere, just resolved toward the safer option here.
        ui.outputRail.selfOnly = (settings.defaultOutputTarget == "SELF")
        -- Explicit requirement: a genuinely fresh install (no old
        -- single-bucket data to migrate at all) defaults the Output Rail
        -- to "All", and there must always be SOME selection - never
        -- nothing. Deferred to a one-time flag rather than populated with
        -- real recipient names here - guild/group/friends rosters are
        -- frequently still empty this early at login (same reasoning as
        -- the migration comment above), so guessing membership at
        -- Sanitize time would be unreliable. UI.lua's roster-ready event
        -- handler consumes this flag exactly once, calling the SAME
        -- SB.SelectAllBroadcastTargets() a real "All" click uses, once
        -- live roster/Send-enabled data actually exists - never a
        -- separate ad-hoc selection path. An upgrading player migrating
        -- real old data (oldMode ~= nil) deliberately does NOT get this -
        -- their existing choice (including a deliberate SELF/local-only
        -- start) is preserved untouched, same principle as the comment
        -- above.
        if not oldMode then
            ui.outputRail.needsDefaultAll = true
        end
    end
    ui.outputRail.mode = nil
    ui.outputRail.recipients = nil
    local selected = ui.outputRail.selected
    for _, bucket in ipairs({ "GUILD", "RAID", "FRIENDS" }) do
        local clean, seen = {}, {}
        local raw = type(selected[bucket]) == "table" and selected[bucket] or {}
        for _, name in ipairs(raw) do
            local key = SB.PlayerKey and SB.PlayerKey(name)
            if SB.IsValidPlayerTarget(name) and key and not seen[key] then
                seen[key] = true
                table.insert(clean, name)
            end
        end
        selected[bucket] = clean
    end
    ui.outputRail.selfOnly = BooleanOr(ui.outputRail.selfOnly, false)

    -- Per-player recipient subset for the Send-to dropdown's Guild/Raid/
    -- Friends channels (Communication.lua's SB.ActivateChannelSubset/
    -- ToggleChannelMember/etc. - see Core.lua's GetDefaultDatabase comment
    -- on ui.channelSubset). Persists across reload/relog (explicit
    -- requirement), unlike outputRail.selected above. Each bucket is nil
    -- (untouched), the literal string "ALL" (implicit - kept as-is), or a
    -- deduplicated list of valid player targets - same validation shape as
    -- outputRail.selected, just with the extra "ALL" sentinel allowed.
    ui.channelSubset = type(ui.channelSubset) == "table" and ui.channelSubset or {}
    for _, bucket in ipairs({ "GUILD", "RAID", "FRIENDS" }) do
        local value = ui.channelSubset[bucket]
        if value == "ALL" then
            -- valid as-is
        elseif type(value) == "table" then
            local clean, seen = {}, {}
            for _, name in ipairs(value) do
                local key = SB.PlayerKey and SB.PlayerKey(name)
                if SB.IsValidPlayerTarget(name) and key and not seen[key] then
                    seen[key] = true
                    table.insert(clean, name)
                end
            end
            ui.channelSubset[bucket] = clean
        else
            ui.channelSubset[bucket] = nil
        end
    end
end

local function ValidateDatabase(db)
    if type(db) ~= "table" or type(db.settings) ~= "table" or type(db.ui) ~= "table"
        or type(db.sounds) ~= "table" or type(db.favourites) ~= "table" then
        error("database validation failed")
    end
end

function SB:PrepareDatabase(rawDatabase)
    local defaults = SB.GetDefaultDatabase()
    if type(rawDatabase) ~= "table" then
        -- BUGFIX (3.0 QA round): this used to return the raw defaults
        -- table completely unsanitized. GetDefaultDatabase() is meant to
        -- hold plain, minimal defaults (empty tables like ui.outputRail/
        -- ui.tagFilters, not their fully-built-out shape) - SanitizeDatabase
        -- below is what actually finishes those into what the rest of the
        -- addon expects (ui.outputRail.selected/selfOnly, for one - see
        -- Core.lua's GetDefaultDB comment on ui.outputRail). Every
        -- upgrading player already went through Sanitize normally; only a
        -- genuinely fresh install took this shortcut and skipped it,
        -- which is exactly why the gap went unnoticed until now. Running
        -- it here keeps both paths structurally consistent instead of
        -- requiring the defaults table to be hand-kept in sync with
        -- whatever shape Sanitize expects.
        SanitizeDatabase(defaults, defaults)
        return defaults, { commit = true, fresh = true }
    end

    local originalVersion = tonumber(rawDatabase.dbVersion) or 0
    local ok, workingOrError = pcall(DeepCopy, rawDatabase)
    if not ok then
        return defaults, {
            commit = false,
            warning = "|cffff5555Saved settings could not be copied safely.|r The original data was left untouched; this session uses safe defaults.",
            error = workingOrError,
        }
    end
    local working = workingOrError
    working.dbVersion = originalVersion

    if originalVersion > SB.DB_VERSION then
        SB.ApplyDatabaseDefaults(working, defaults)
        SanitizeDatabase(working, defaults)
        working.dbVersion = originalVersion
        return working, {
            commit = false,
            warning = "|cffffaa55These settings were created by a newer Soundbook version.|r They were left untouched; changes made in this session will not be saved.",
        }
    end

    -- Historical migrations expect these top-level containers to exist,
    -- but not current defaults (which could change their old branching).
    EnsureTable(working, "settings")
    EnsureTable(working, "ui")
    EnsureTable(working, "sounds")
    EnsureTable(working, "favourites")
    EnsureTable(working, "categories")
    EnsureTable(working.settings, "broadcastModes")
    EnsureTable(working.settings, "receiveMute")
    EnsureTable(working.settings, "mutedPlayers")
    EnsureTable(working.ui, "currentPage")
    EnsureTable(working.ui, "tagFilters")
    EnsureTable(working.ui, "minimap")

    ok, workingOrError = pcall(function()
        SB.MigrateDatabaseInPlace(working)
        SB.ApplyDatabaseDefaults(working, defaults)
        SanitizeDatabase(working, defaults)
        ValidateDatabase(working)
        return working
    end)
    if not ok then
        return defaults, {
            commit = false,
            warning = "|cffff5555Saved settings could not be upgraded safely.|r The original data was left untouched; this session uses safe defaults. Enable Debug Mode for details.",
            error = workingOrError,
        }
    end

    return workingOrError, { commit = true, migratedFrom = originalVersion }
end
