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
    ui.favScale = ClampNumber(ui.favScale, defaults.ui.favScale, 0.5, 2)
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

    ui.categoryCollapsed = type(ui.categoryCollapsed) == "table" and ui.categoryCollapsed or {}
    for key, value in pairs(ui.categoryCollapsed) do
        if (type(key) ~= "string" and type(key) ~= "number") or value ~= true then
            ui.categoryCollapsed[key] = nil
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
