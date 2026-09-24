-- SoundRegistry.lua
-- Builds the single source of truth lookup table from Sounds.lua.
-- Every other module (UI, Macros, Favourites, Communication) resolves
-- sounds exclusively through SB.registry / SB:GetSoundInfo - there is no
-- second, independently implemented sound lookup anywhere in the addon.

local ADDON_NAME, SB = ...

SB.registry = {}          -- [soundID] = { id, category, name, fileBase }
SB.registryByCategory = {} -- [category] = { soundID, soundID, ... } (in Sounds.lua order) - PUBLIC sounds only, see SB.privateSoundIDs below
SB.privateSoundIDs = {}   -- soundID list for every sound registered via SB.RegisterPrivateSounds (e.g. Soundbook_Private) -
                          -- kept OUT of registryByCategory entirely so it never mixes into the public Category
                          -- tabs; instead it powers its own dedicated "Stammtisch" tab (UI.lua).

-- Fixed internal category id for every private sound - only one "bonus
-- content" bucket (Stammtisch), never split by companion addon. Must
-- never change once a private sound has been favourited (stored as this +
-- name), and must stay outside SB.CATEGORIES' numeric/"Default" range so
-- it can't collide with a real category.
SB.PRIVATE_CATEGORY = "Private"

-- Builds a stable id such as "2::wir wipen" or "Default::Vine Boom".
-- Category is always the physical category identifier (a number, or the
-- "Default"/SB.PRIVATE_CATEGORY string), never an array index, so ids
-- never break when sounds are reordered, renamed (category display name),
-- or resorted.
function SB.MakeSoundID(category, name)
    return tostring(category) .. "::" .. name
end

function SB.ParseSoundID(soundID)
    if not SB.IsValidSoundID(soundID) then return nil end
    local cat, name = soundID:match("^([^:]+)::(.*)$")
    if not cat then return nil end
    return tonumber(cat) or cat, name
end

-- `sourceAddon` defaults to this addon's own folder, but a companion addon
-- (via SB.RegisterPrivateSounds below) can pass its OWN folder name so its
-- sound files stay entirely inside its own folder, never needing to be
-- copied into Soundbook's own Sounds folder.
-- `flat` (private sounds only) skips the "CategoryN" subfolder - there's
-- only one bucket of private/bonus sounds, so no folder split is needed.
local function BuildFileBase(category, name, sourceAddon, flat)
    -- Path relative to the WoW installation root (without extension - see
    -- SB.SOUND_EXTENSIONS / SoundPlayer.lua for how the real file is found).
    local root = "Interface\\AddOns\\" .. (sourceAddon or ADDON_NAME) .. "\\Sounds\\"
    if flat then
        return root .. name
    end
    -- "Legacy" and "German Memes" are named folders (Sounds\Legacy\,
    -- Sounds\German Memes\), not "CategoryLegacy\"/"CategoryGerman Memes\" -
    -- only the plain numeric categories (1, 2, ...) get the "CategoryN\"
    -- treatment.
    if category == "Legacy" then
        return root .. "Legacy\\" .. name
    elseif category == "German Memes" then
        return root .. "German Memes\\" .. name
    end
    return root .. "Category" .. category .. "\\" .. name
end

-- SB.SoundDurations (SoundDurations.lua) is keyed by the physical file
-- name on disk, but a sound's registered `name` can differ in CASE from
-- the real file name. Windows doesn't care, but a plain Lua table lookup
-- is case-SENSITIVE, so we also try a lowercased fallback. Built lazily
-- (not at file-load time) since SB.SoundDurations may not be populated yet.
local soundDurationsLower
local function LookupPrecomputedDuration(fileBase)
    if not SB.SoundDurations then return nil end
    local exact = SB.SoundDurations[fileBase]
    if exact then return exact end
    if not soundDurationsLower then
        soundDurationsLower = {}
        for k, v in pairs(SB.SoundDurations) do
            soundDurationsLower[k:lower()] = v
        end
    end
    return soundDurationsLower[fileBase:lower()]
end

-- `entry` is normally a plain name string, but can also be
-- { name = "...", icon = ... } to ship a DEFAULT icon with the sound in
-- code. `icon` can be a string path ("Interface\\Icons\\...") or a numeric
-- file ID (SetTexture accepts both). Still just a starting point: picking
-- a different icon in-game overrides it as normal (see SB:GetSoundSaved's
-- icon backfill).
local function InsertSoundEntry(category, entry, sourceAddon, isPrivate)
    local name, defaultIcon, explicitDuration, entryTags
    if type(entry) == "string" then
        name = entry
    elseif type(entry) == "table" then
        name = entry.name
        defaultIcon = entry.icon
        explicitDuration = entry.duration
        -- Optional search alias tags: { "laugh", "lol", "pirat", ... }
        -- Validated and normalised to lowercase strings here so the search
        -- path (UI.lua) never has to sanitise them at query time.
        if type(entry.tags) == "table" then
            entryTags = {}
            for _, t in ipairs(entry.tags) do
                if type(t) == "string" and #t > 0 and #t <= 64 then
                    table.insert(entryTags, t:lower())
                end
            end
            if #entryTags == 0 then entryTags = nil end
        end
    end
    name = SB.TrimText(name)
    if not SB.IsValidSoundName(name) then
        SB:Debug("Rejected invalid sound entry from %s: %s", tostring(sourceAddon or ADDON_NAME), tostring(name))
        return
    end
    if not SB.IsValidAddonFolder(sourceAddon) then
        SB:Debug("Rejected sound entry with invalid addon folder: %s", tostring(sourceAddon))
        return
    end

    local id = SB.MakeSoundID(category, name)
    if SB.registry[id] then
        SB:Debug("Duplicate sound entry ignored: %s", id)
        return
    end
    local iconType = type(defaultIcon)
    if not (iconType == "string" or iconType == "number") or defaultIcon == ""
        or (iconType == "string" and (#defaultIcon > 240 or defaultIcon:find("[%z\1-\31\127]"))) then
        defaultIcon = nil
    end
    local fileBase = BuildFileBase(category, name, sourceAddon, isPrivate)
    -- Duration priority: explicit per-entry `duration` > precomputed table
    -- (SoundDurations.lua) > a value already learned in a past session
    -- (SB.db isn't ready yet for this addon's own built-in Sounds.lua,
    -- which registers before ADDON_LOADED - harmless, the precomputed
    -- table covers that case). Never guessed - nil here means "unknown for
    -- now", not "0".
    local durationType = type(explicitDuration)
    if durationType ~= "number" or not SB.IsFiniteNumber(explicitDuration)
        or explicitDuration <= 0 or explicitDuration > 600 then explicitDuration = nil end
    local duration = explicitDuration
        or LookupPrecomputedDuration(fileBase)
        or (SB.db and SB.db.soundDurations and SB.db.soundDurations[id])
    SB.registry[id] = {
        id = id,
        category = category,
        name = name,
        fileBase = fileBase,
        defaultIcon = defaultIcon,
        isPrivate = isPrivate or nil,
        durationSeconds = duration,
        tags = entryTags,
    }
    if isPrivate then
        table.insert(SB.privateSoundIDs, id)
    else
        table.insert(SB.registryByCategory[category], id)
    end
end

local function BuildRegistry()
    wipe(SB.registry)
    wipe(SB.registryByCategory)
    wipe(SB.privateSoundIDs)
    for _, category in ipairs(SB.CATEGORIES) do
        SB.registryByCategory[category] = {}
    end

    local source = _G.SoundbookSounds
    if type(source) ~= "table" then
        SB:Print("|cffff5555Sounds.lua is missing or invalid.|r No sounds loaded.")
        return
    end

    for _, category in ipairs(SB.CATEGORIES) do
        local list = source[category]
        if type(list) == "table" then
            for _, name in ipairs(list) do
                InsertSoundEntry(category, name)
            end
        end
    end
end

-- Lets a SEPARATELY DISTRIBUTED companion addon add more sounds at runtime
-- without ever touching this addon's own (publicly shared) Sounds.lua -
-- the way to keep personal/private sounds out of a public CurseForge
-- upload while still sharing everything else.
--
-- `list` is a FLAT array - no category split, unlike Sounds.lua's
-- SoundbookSounds table - since private sounds are all just one "bonus
-- content" bucket (the one "Stammtisch" tab - SB:GetPrivateSounds/
-- SB:HasPrivateSounds below, UI.lua):
--   { "name", { name = "...", icon = ... }, ... }
-- (each entry a plain name string, or a table for a code-shipped default
-- icon - see InsertSoundEntry above.)
--
-- `sourceAddonFolder` (optional) is the AddOns folder name the actual
-- .mp3/.ogg/.wav files live in - pass the CALLING addon's own folder name
-- (e.g. "Soundbook_Private") so its sound files stay entirely inside that
-- addon's own (single, flat) Sounds\ folder. Defaults to Soundbook's own
-- folder if omitted.
--
-- Safe to call more than once/from more than one addon - entries are added
-- incrementally (never wipes what's already registered), and a name that
-- collides with an existing one is skipped rather than overwritten. See
-- README.md "Splitting public and private sounds".
function SB.RegisterPrivateSounds(list, sourceAddonFolder)
    if type(list) ~= "table" or not SB.IsValidAddonFolder(sourceAddonFolder) then return end
    for _, entry in ipairs(list) do
        InsertSoundEntry(SB.PRIVATE_CATEGORY, entry, sourceAddonFolder, true)
    end
    SB:Fire("SOUND_DISPLAY_CHANGED")
end

-- The UPDATE-SAFE way for anyone to add sounds to the regular category
-- tabs (same shape as this addon's own Sounds.lua) from a SEPARATE
-- companion addon folder instead of editing Soundbook's own Sounds.lua
-- directly. CurseForge/WowUp replace Soundbook's entire folder wholesale
-- on every update, so anything typed straight into Soundbook\Sounds.lua
-- (or its Sounds\ subfolders) is at risk of being wiped out. A companion
-- addon (see the Soundbook_MySounds template) is never part of Soundbook's
-- own package, so it survives every future update.
--   source: { [Category] = { "name", { name=, icon= }, ... }, [1] = {...}, [2] = {...} }
-- `sourceAddonFolder` (optional) is the AddOns folder name the actual
-- .mp3/.ogg/.wav files live in - pass your own companion addon's folder
-- name so its files stay entirely inside that folder. Defaults to
-- Soundbook's own folder if omitted. Safe to call more than once/from more
-- than one addon; a name colliding with an existing entry is skipped
-- rather than overwritten. See README.md "Adding sounds that survive
-- updates".
function SB.RegisterSounds(source, sourceAddonFolder)
    if type(source) ~= "table" or not SB.IsValidAddonFolder(sourceAddonFolder) then return end
    for _, category in ipairs(SB.CATEGORIES) do
        local list = source[category]
        if type(list) == "table" then
            for _, entry in ipairs(list) do
                InsertSoundEntry(category, entry, sourceAddonFolder, false)
            end
        end
    end
    SB:Fire("SOUND_DISPLAY_CHANGED")
end

-- Public accessors -------------------------------------------------------

function SB:GetSoundInfo(soundID)
    return SB.registry[soundID]
end

function SB:SoundExists(soundID)
    return SB.registry[soundID] ~= nil
end

function SB:GetCategorySounds(category)
    return SB.registryByCategory[category] or {}
end

-- Every sound registered via SB.RegisterPrivateSounds (e.g. by
-- Soundbook_Private) - they all show up together in the one "Stammtisch"
-- tab. Order matches registration order (the private addon's own
-- Sounds.lua).
function SB:GetPrivateSounds()
    return SB.privateSoundIDs
end

-- Whether the "Stammtisch" tab should exist at all this session - false
-- when no companion addon (or none with any sounds in it) is installed.
function SB:HasPrivateSounds()
    return #SB.privateSoundIDs > 0
end

-- Same idea for the plain numbered categories (1, 2, ...): Soundbook itself
-- only ever ships "Legacy"/"German Memes" with content. Category 1/2 are
-- empty slots that stay entirely hidden in the main window until something - normally
-- Soundbook_MySounds via SB.RegisterSounds - actually puts a sound in them,
-- so nobody without MySounds ever sees an empty tab.
function SB:HasCategorySounds(category)
    local list = SB.registryByCategory[category]
    return list ~= nil and #list > 0
end

function SB:GetAllSoundIDs()
    local list = {}
    for _, category in ipairs(SB.CATEGORIES) do
        for _, id in ipairs(SB:GetCategorySounds(category)) do
            table.insert(list, id)
        end
    end
    for _, id in ipairs(SB.privateSoundIDs) do
        table.insert(list, id)
    end
    return list
end

-- Per-sound saved data (icon/favourite/muted/volume) lives in SavedVariables
-- and is created lazily with sane defaults the first time it's touched.
-- Existing entries from before a given field existed get it backfilled
-- here too (checked individually, not just on first creation).
--
-- IMPORTANT: `saved.icon` is intentionally left nil here and NEVER written
-- by this function. The only place that ever sets it is EditWindow.lua's
-- icon grid, when a player deliberately picks one - that's what makes its
-- mere presence an unambiguous "this player chose this on purpose" signal.
-- GetSoundIcon re-reads the current defaultIcon live whenever there's no
-- explicit per-player pick, so icon fixes in Sounds.lua actually show up.
function SB:GetSoundSaved(soundID)
    if not SB.db or not SB.registry[soundID] then return nil end
    if type(SB.db.sounds) ~= "table" then SB.db.sounds = {} end
    local saved = SB.db.sounds[soundID]
    if not saved then
        saved = {}
        SB.db.sounds[soundID] = saved
    end
    if saved.favourite == nil then saved.favourite = false end
    if saved.muted == nil then saved.muted = false end
    if saved.volume == nil then saved.volume = 100 end
    return saved
end

------------------------------------------------------------------------
-- "New" tag - SB.db.sounds[soundID].addedAt (time() epoch), used by
-- UI.lua's "New" pill. Never touched by GetSoundSaved itself (that's
-- called for EVERY sound the grid ever renders, including ones a player
-- just never happened to touch yet - stamping addedAt there would wrongly
-- mark long-existing, simply-never-clicked sounds as "New"). Only ever
-- set explicitly by BackfillAddedAt below, once per soundID, ever.
------------------------------------------------------------------------

local NEW_TAG_DAYS = 2 -- 48h

-- One-time list for the release this "New" tag feature itself shipped in
-- - these sounds already existed in Sounds.lua before SB.db.knownSoundIDs
-- had any history, so they wouldn't otherwise show "New" on first run.
-- Any sound added in a LATER Sounds.lua update is auto-detected by
-- BackfillAddedAt's normal path instead (a soundID not yet in
-- SB.db.knownSoundIDs).
--
-- Permanently dead as of the "Default" category split (Core.lua's
-- MigrateDB v17->v18) - these exact ids can never exist again, so this
-- table can never match anything. Left in place; harmless.
local MIGRATION_NEW_SOUND_IDS = {
    ["Default::Zehahaha"] = true,
    ["Default::Schoki"] = true,
    ["Default::Donkey Hee Haw"] = true,
    ["Default::Mir Egal"] = true,
}

-- Walks every CURRENTLY REGISTERED soundID once (idempotent - a soundID
-- already in SB.db.knownSoundIDs is never touched again) and decides,
-- once and permanently, whether it's "New" (real addedAt timestamp) or
-- "legacy" (no addedAt at all, never shows the New tag):
--   - The very first time this ever runs for this player (no
--     knownSoundIDs table yet), every sound already in the registry is
--     legacy EXCEPT MIGRATION_NEW_SOUND_IDS above - we have no real
--     history for an existing library, so marking it all "New" on upgrade
--     would be wrong.
--   - On every run after that, any soundID never seen before is genuinely
--     new - stamped with time() right away.
-- Must run before the grid ever renders (see Core.lua's PLAYER_LOGIN/
-- ADDON_LOADED wiring) - GetSoundSaved's own lazy-create would otherwise
-- create an addedAt-less entry for an unrelated reason before this ever
-- gets a chance to classify it correctly.
function SB:BackfillAddedAt()
    if not SB.db then return end
    local isFirstRun = not SB.db.knownSoundIDs
    SB.db.knownSoundIDs = SB.db.knownSoundIDs or {}
    for soundID in pairs(SB.registry) do
        if not SB.db.knownSoundIDs[soundID] then
            SB.db.knownSoundIDs[soundID] = true
            if MIGRATION_NEW_SOUND_IDS[soundID] or not isFirstRun then
                local saved = SB:GetSoundSaved(soundID)
                saved.addedAt = time()
            end
        end
    end
end

-- Purely LOCAL, per-player "have I personally heard this enough" counters
-- - [soundID] = { self = N, received = N }. `self` is how many times THIS
-- player has personally triggered/sent this sound locally
-- (SB:TriggerSound - a click, or a SendMenu.lua "send to..."); `received`
-- is how many times THIS player has heard it after someone ELSE sent it
-- (HandlePlayCommand, Communication.lua). Deliberately independent of the
-- shared multiplayer Analytics system (Analytics.lua's totalPlays, which
-- requires a real reciprocal ACK and excludes self-only plays) - this is
-- only ever local listening history, never synced to anyone else.
local function NewSoundHeardCounts()
    SB.db.newSoundHeardCounts = SB.db.newSoundHeardCounts or {}
    return SB.db.newSoundHeardCounts
end

--- Bumps this player's own local self/received counter for `soundID` -
--- `kind` is "self" or "received". No-ops once the sound's own addedAt-
--- based time window has already expired (or it never had one) - the
--- counter only matters while the sound could still legitimately be
--- tagged New at all, nothing left to track once time alone already
--- settled it.
function SB:BumpNewSoundHeardCount(soundID, kind)
    local saved = soundID and SB.db and SB.db.sounds and SB.db.sounds[soundID]
    if not saved or not saved.addedAt or saved.addedAt <= 0 then return end
    if (time() - saved.addedAt) >= (NEW_TAG_DAYS * 86400) then return end
    local counts = NewSoundHeardCounts()
    local entry = counts[soundID] or { self = 0, received = 0 }
    entry[kind] = (entry[kind] or 0) + 1
    counts[soundID] = entry
end

--- True only while a real addedAt exists and is within NEW_TAG_DAYS -
--- legacy sounds (no addedAt at all) never qualify, and it stops on its
--- own once the window passes (no separate "clear" step needed). Also
--- stops early, before the window is up, once THIS player has personally
--- heard the sound enough - at least 3 self-triggered plays/sends AND at
--- least 3 received plays (SB:BumpNewSoundHeardCount above).
function SB:IsSoundNew(soundID)
    local saved = SB.db and SB.db.sounds[soundID]
    if not saved or not saved.addedAt or saved.addedAt <= 0 then return false end
    if (time() - saved.addedAt) >= (NEW_TAG_DAYS * 86400) then return false end
    local counts = SB.db.newSoundHeardCounts and SB.db.newSoundHeardCounts[soundID]
    if counts and (counts.self or 0) >= 3 and (counts.received or 0) >= 3 then
        return false
    end
    return true
end

function SB:GetSoundIcon(soundID)
    local saved = SB.db and SB.db.sounds[soundID]
    if saved and saved.icon then return saved.icon end
    local info = SB.registry[soundID]
    return (info and info.defaultIcon) or SB.DEFAULT_ICON
end

-- The name shown in-game defaults to the exact Sounds.lua entry, but can be
-- overridden per-sound from the Edit window without touching Sounds.lua.
function SB:GetSoundDisplayName(soundID)
    local saved = SB.db and SB.db.sounds[soundID]
    if saved and saved.displayName and saved.displayName ~= "" then
        return saved.displayName
    end
    local info = SB.registry[soundID]
    return info and info.name or soundID
end

function SB:SetSoundDisplayName(soundID, name)
    local saved = SB:GetSoundSaved(soundID)
    if not saved then return end
    local info = SB.registry[soundID]
    name = SB.TrimText(name)
    if not name or name == "" or (info and name == info.name) then
        saved.displayName = nil -- back to the Sounds.lua default
    elseif #name > 80 or name:find("[%z\1-\31\127]") then
        return false
    else
        saved.displayName = name
    end
    return true
end

BuildRegistry() -- Sounds.lua has already loaded (earlier in the .toc) by this point.
