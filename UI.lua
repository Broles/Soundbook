-- UI.lua
-- Soundbook 3.0 Main shell: a compact toolbar (Settings/Lock/Search/Audio/
-- Close), a vertical Output Rail, and one continuously scrolling Sound
-- Library (Favourites first, then a collapsible section per category) -
-- replacing the old paged, right-side-tabbed book. Settings and Raid Admin
-- remain internal panels swapped into the same content area.

local ADDON_NAME, SB = ...

local ENTRY_W     = 190
local ROW_H       = 32
local ICON_SIZE   = 22
local THREE_COLUMN_WIDTH = 600
-- Explicit report: category headers (Favourites/Legacy/...) should stand
-- out more from the sound rows below them, and the collapse caret wasn't
-- obviously a collapse control. Grown from 24 for the bigger title font
-- (NormalLarge instead of Highlight) and the bigger caret glyph below.
local SECTION_HEADER_H = 30
local SECTION_GAP = 10
-- Left margin for the entry grid so column 0's icon decoration (the
-- Favourite hover preview's 130% scale-up especially) has room before the
-- ScrollFrame's own hard clip edge at scroll.content's x=0 - see its use
-- in RefreshLibraryImpl/LayoutEntries.
local GRID_LEFT_PAD = 6

-- The "private" tab only actually appears once SB:HasPrivateSounds() is
-- true (Soundbook_Private or similar installed with at least one sound
-- registered) - see BuildSectionList. Favourites uses the string key
-- "favourites" (not a number) specifically so it can never collide with a
-- real category identifier - "Legacy"/"German Memes"/1/2 (SB.CATEGORIES,
-- Core.lua). Category 1/2 (hideIfEmpty) only ever appear once something
-- has actually registered a sound into them - normally Soundbook_MySounds
-- via SB.RegisterSounds. Soundbook itself never ships content in them,
-- only in "Legacy"/"German Memes" (used to be the single "Default"
-- category - see Core.lua's MigrateDB v17->v18 block) - see
-- SB:HasCategorySounds below.
--
-- Kept named "TABS" (a naming carryover from the pre-3.0 right-side-tab
-- UI) - these are Library SECTIONS now, not clickable tabs, but every
-- other name here (TabDisplayInfo, GetTabSoundList, ...) still describes
-- exactly what it did before; renaming them added risk without changing
-- behaviour, so it was deliberately left alone.
local TABS = {
    { key = "favourites", isFavourites = true },
    { key = "private", isPrivate = true },
    { key = "Legacy" },
    { key = "German Memes" },
    { key = 1, hideIfEmpty = true },
    { key = 2, hideIfEmpty = true },
    -- Explicit request: a virtual "Hide" category, always last, holding
    -- every sound whose Edit Sound "Hide" checkbox is on - see
    -- GetHiddenSoundList/hideIfEmpty below and BuildSectionList/
    -- RefreshLibraryImpl for its own (session-only, never-persisted)
    -- collapse handling.
    { key = "hide", isHide = true, hideIfEmpty = true },
}

local main
local entryButtons = {}
local sectionHeaders = {}
local searchBox
local searchPlaceholder
local outputRailButtons = {}
local emptyHint
local emptyHintClear
local settingsPanel
local isSettingsOpen = false
local adminPanel
local isAdminOpen = false
local adminToolbarBtn
local lockToolbarBtn
local selectedSoundID
local playingSoundID
local playingStateTimer
local mainDragGhostFrame, mainDragGhostIcon, mainDragGhostOrnament
local mainDragSourceSlot, mainDragSoundID
-- The virtual "Hide" section's own collapse state - explicit request:
-- unlike every real category, this must NOT persist. Every time the
-- Soundbook window opens it starts collapsed again, regardless of
-- whether the player expanded it earlier in the same session. A plain
-- session-local (reset in SB:ShowMainWindow), never SavedVariables.
local hideSectionExpanded = false
local RefreshLibrary
local usedEntries, usedHeaders

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function TabDisplayInfo(tab)
    if tab.isFavourites then
        return "Favourites", SB.FAVOURITES_ICON
    end
    if tab.isPrivate then
        return SB.PRIVATE_TAB_NAME, SB.PRIVATE_TAB_ICON
    end
    if tab.isHide then
        return "Hide", SB.HIDE_ICON
    end
    local info = SB.db.categories[tab.key]
    return info.name, info.icon
end

-- Popularity/New ordering is computed once per section per "window open
-- session" and then held fixed - explicit request: re-sorting live while
-- the player is actually looking at the book (e.g. because clicking a
-- sound just bumped its own play count) is disorienting, icons must not
-- visibly reshuffle under the mouse. Cleared only when the window
-- transitions from closed to open (SB:ShowMainWindow) or the Sound Order
-- setting itself changes (Settings.lua) - never by an ordinary
-- RefreshLibrary call (favourite toggled, a sound played, Analytics
-- synced, ...).
local sortedListCache = {}

-- "Hide" (explicit request) - Edit Sound's own "Hide" checkbox
-- (SB.db.sounds[id].hidden). A hidden sound is pulled OUT of its normal
-- category tab (FilterHidden below) and only shows up under the virtual
-- "hide" tab (GetHiddenSoundList) instead - a pure Library-visibility
-- toggle, doesn't touch Favourites/mute/anything else.
local function IsSoundHidden(id)
    local saved = SB.db.sounds and SB.db.sounds[id]
    return saved and saved.hidden and true or false
end

local function FilterHidden(ids)
    local out = {}
    for _, id in ipairs(ids) do
        if not IsSoundHidden(id) then table.insert(out, id) end
    end
    return out
end

local function GetHiddenSoundList()
    local out = {}
    for id in pairs(SB.registry or {}) do
        if IsSoundHidden(id) then table.insert(out, id) end
    end
    table.sort(out, function(a, b)
        return SB:GetSoundDisplayName(a):lower() < SB:GetSoundDisplayName(b):lower()
    end)
    return out
end

local function HasHiddenSounds()
    for id in pairs(SB.registry or {}) do
        if IsSoundHidden(id) then return true end
    end
    return false
end

local function GetTabSoundList(tabKey)
    if tabKey == "favourites" then
        -- Never sorted - fixed positions the player deliberately dragged
        -- into place, not a ranked list.
        return SB:GetFavourites()
    end
    if tabKey == "hide" then
        return GetHiddenSoundList()
    end
    if not SB.SortSoundIDsBySetting then
        local ids = tabKey == "private" and SB:GetPrivateSounds() or SB:GetCategorySounds(tabKey)
        return FilterHidden(ids)
    end
    if not sortedListCache[tabKey] then
        local ids = (tabKey == "private") and SB:GetPrivateSounds() or SB:GetCategorySounds(tabKey)
        sortedListCache[tabKey] = SB.SortSoundIDsBySetting(FilterHidden(ids))
    end
    return sortedListCache[tabKey]
end

--- Called when the Sound Order setting changes, and whenever the window
--- goes from closed to open - see sortedListCache above.
local function InvalidateSortedListCache()
    sortedListCache = {}
end
SB.InvalidateSoundOrderCache = InvalidateSortedListCache

local function IsSearching()
    return searchBox and searchBox:GetText() ~= "" and searchBox:GetText() ~= nil
end

--- Explicit request: tag filter pills (New/Trending/Popular/Loved) act
--- like a second, independent search - see GetFilteredSoundList below,
--- defined once GetTag itself is (needs it to actually filter). Combined
--- with IsSearching() into IsFiltering(), used everywhere a flat,
--- cross-category result list should replace the current section list -
--- same treatment a text search already gets.
local function HasActiveTagFilters()
    return next(SB.db.ui.tagFilters) ~= nil
end

local function IsFiltering()
    return IsSearching() or HasActiveTagFilters()
end

-- Explicit request (reversed back from an earlier "keep filtering active
-- across a tab click" version): clicking Settings or Admin now clears
-- BOTH the search box and any active tag filter pills, exactly like
-- landing on that destination's own plain unfiltered view - not left
-- running in the background.
local function ClearFiltering()
    if searchBox then searchBox:SetText("") end
    if SB.db and SB.db.ui and SB.db.ui.tagFilters then wipe(SB.db.ui.tagFilters) end
end

------------------------------------------------------------------------
-- Sound "tag" pill - see CreateEntryButton's btn.tag. Distinct background
-- AND text colour per tag, explicit request. Keyed by the INTERNAL label
-- (SB.Analytics_Health's own strings, plus the synthetic "New" - see
-- GetTag below); `label` is the shorter, actually-DISPLAYED text - kept
-- separate because "Community Favourite" was too long as a pill and
-- crowded out most sound names, so it displays as "Loved" instead while
-- the underlying health classification keeps its real name everywhere
-- else (e.g. the Analytics window's own table).
------------------------------------------------------------------------
-- `desc` (explicit request): shown as an extra tooltip line, ONLY for a
-- sound that actually carries this tag right now - see CreateEntryButton's
-- OnEnter below - coloured the same as the pill's own text so hovering
-- immediately explains what the pill means without having to open the
-- Analytics window. Kept in sync with the real thresholds (Analytics.lua's
-- SB.ANALYTICS_HEALTH_THRESHOLDS) in spirit, not exact numbers - a tooltip
-- reciting precise percentages would just be noise.
local TAG_STYLE = {
    Legendary               = { bg = { 0.45, 0.22, 0.03 }, text = { 1.00, 0.50, 0.10 }, label = "Legendary",
        desc = "The single most-played sound in the whole Soundbook, across every category. Only one sound can ever hold this." },
    New                     = { bg = { 0.05, 0.28, 0.40 }, text = { 0.55, 0.88, 1.00 }, label = "New",
        desc = "Added to the sound library in the last couple of days." },
    Trending                = { bg = { 0.08, 0.42, 0.18 }, text = { 0.55, 1.00, 0.62 }, label = "Trending",
        desc = "Getting noticeably more plays this week, from several different players." },
    Popular                 = { bg = { 0.50, 0.32, 0.04 }, text = { 1.00, 0.80, 0.30 }, label = "Popular",
        desc = "Played by a large share of active players, with a strong overall play count." },
    ["Community Favourite"] = { bg = { 0.42, 0.14, 0.36 }, text = { 1.00, 0.58, 0.92 }, label = "Loved",
        desc = "Favourited by a large share of the players who've played it." },
    -- Two NEGATIVE/funny tags (explicit request) - both entirely their own
    -- standalone signal computed right here in this file (see IsCringe/
    -- GetDustySet below), same overall pattern as Legendary - NEITHER
    -- reuses Analytics_Health's own internal labels (Cringe originally
    -- did, via "Spammy" - explicitly changed: "Cringe" the NAME stays, but
    -- the underlying signal is now "One-Man-Show", ranked per category, so
    -- it needed its own separate check, leaving Analytics_Health's actual
    -- "Spammy" health label untouched for the Analytics window's own use).
    -- Both sickly/murky colours, deliberately unlike any of the positive
    -- pills above and unlike each other - Cringe's own original yellow-ish
    -- tone read too close to Popular's gold, swapped for a murky,
    -- embarrassed red instead (nothing else here uses red at all).
    Cringe                  = { bg = { 0.38, 0.08, 0.08 }, text = { 0.95, 0.35, 0.35 }, label = "Cringe",
        desc = "Played a bunch of times, but always by the exact same single person - nobody else has ever touched it." },
    Dusty                   = { bg = { 0.26, 0.22, 0.16 }, text = { 0.62, 0.55, 0.42 }, label = "Dusty",
        -- Explicit bugfix: hardcoded "3" - actually a fixed top-3 for the
        -- main Legacy/German Memes pool PLUS a separate top-2 for
        -- Stammtisch (see GetDustySet/GetDustySetPrivate below), so "3" is
        -- wrong/misleading for a Stammtisch sound specifically. Kept
        -- general instead of naming either exact count.
        desc = "One of the sounds nobody has touched in the longest time." },
}

-- Display order for the tag FILTER pills (explicit request) - same order
-- GetTag's own precedence checks them in for the positive ones; the two
-- negative ones (Cringe/Dusty) are deliberately last/rightmost here too -
-- explicit request.
local TAG_FILTER_ORDER = { "New", "Legendary", "Trending", "Popular", "Community Favourite", "Cringe", "Dusty" }

-- Reverse lookup (tag name -> its position in TAG_FILTER_ORDER above) - used
-- by GetFilteredSoundList to group tag-filtered results by pill, in the
-- same order the pills themselves appear, instead of a single flat
-- alphabetical list mixing every active tag together ("sehr chaotisch",
-- explicit bug report - hard to tell which sound belongs to which pill
-- when several are active at once).
local TAG_ORDER_RANK = {}
for i, tagKey in ipairs(TAG_FILTER_ORDER) do
    TAG_ORDER_RANK[tagKey] = i
end

-- Negative tags (explicit request) - sorted to the very end of the tag-
-- filtered results list (GetFilteredSoundList below), regardless of
-- alphabetical order otherwise - "immer an letzter Stelle".
local NEGATIVE_TAGS = { Cringe = true, Dusty = true }

-- "Legendary" (explicit request) - the single most-played sound, but now
-- TWO separate winners, one per pool (same "Stammtisch never competes
-- against Legacy/German Memes" split as Trending/Popular/Loved below,
-- see Analytics.lua's SB.Analytics_IsPrivatePoolEligible): one crown for
-- the main Legacy/German Memes pool, one ADDITIONAL "+1" crown for
-- Stammtisch's own separate pool - "nur ganz wenige Spieler haben
-- Stammtisch", it could never win the main pool's crown outright no
-- matter how loved it is within its own small circle. Category1/2
-- (Soundbook_MySounds) is excluded from BOTH - same reasoning as it
-- already being excluded from Trending/Popular/Loved (a personal, per-
-- player library, not shared community content). Never a tie - "es gibt
-- nur einen Sieger" - if two or more sounds in the SAME pool are exactly
-- tied for the most plays, NOBODY in that pool gets the badge (rather
-- than arbitrarily picking one) until real usage breaks the tie. A small
-- minimum play count (lower for Stammtisch's much smaller audience) keeps
-- a fresh pool from immediately crowning whatever sound happened to be
-- clicked once first.
local MOST_PLAYED_MIN_PLAYS = 10
local MOST_PLAYED_MIN_PLAYS_PRIVATE = 5
local mostPlayedCache, mostPlayedCacheAt
local mostPlayedCachePrivate, mostPlayedCachePrivateAt
local MOST_PLAYED_CACHE_TTL = 5

local function ComputeMostPlayedSoundID(eligibleFn, minPlays)
    if not SB.Analytics_AllSoundIDs or not SB.Analytics_SoundMetrics then return nil end
    local bestID, bestPlays, tied = nil, 0, false
    for _, soundID in ipairs(SB.Analytics_AllSoundIDs()) do
        if eligibleFn(soundID) then
            local ok, plays = pcall(function()
                return SB.Analytics_SoundMetrics(soundID, "all").plays
            end)
            plays = ok and plays or 0
            if plays > bestPlays then
                bestID, bestPlays, tied = soundID, plays, false
            elseif plays == bestPlays and bestID and soundID ~= bestID then
                tied = true
            end
        end
    end
    if not bestID or bestPlays < minPlays or tied then return nil end
    return bestID
end

local function GetMostPlayedSoundID()
    local now = GetTime()
    if mostPlayedCacheAt and (now - mostPlayedCacheAt) < MOST_PLAYED_CACHE_TTL then
        return mostPlayedCache
    end
    mostPlayedCache = SB.Analytics_IsHealthEligible
        and ComputeMostPlayedSoundID(SB.Analytics_IsHealthEligible, MOST_PLAYED_MIN_PLAYS) or nil
    mostPlayedCacheAt = now
    return mostPlayedCache
end

local function GetMostPlayedSoundIDPrivate()
    local now = GetTime()
    if mostPlayedCachePrivateAt and (now - mostPlayedCachePrivateAt) < MOST_PLAYED_CACHE_TTL then
        return mostPlayedCachePrivate
    end
    mostPlayedCachePrivate = SB.Analytics_IsPrivatePoolEligible
        and ComputeMostPlayedSoundID(SB.Analytics_IsPrivatePoolEligible, MOST_PLAYED_MIN_PLAYS_PRIVATE) or nil
    mostPlayedCachePrivateAt = now
    return mostPlayedCachePrivate
end

-- "Dusty" (explicit request) - the sounds that have gone the LONGEST
-- without being played. Split into the SAME two separate pools as
-- Trending/Popular/Loved (explicit request, reversed from an earlier "one
-- combined top-3" version) - the main Legacy/German Memes pool gets its
-- own top 3, and Stammtisch gets its own separate top 2, ranked only
-- against each other, never pooled together
-- (SB.Analytics_IsHealthEligible / SB.Analytics_IsPrivatePoolEligible).
-- Lowest precedence of every tag (checked only once nothing else - not
-- even Cringe - already applies, see GetTag) - a sound that's both dusty
-- AND, say, still Loved shows Loved, the friendlier read wins.
--
-- Explicit bugfix, round 1: with too few sounds having ANY play history
-- yet (post-reset, or just a young pool), a sound played only YESTERDAY
-- could still land in the "top 3 longest-untouched" purely for lack of
-- real competition - "Deja Vu hab ich gestern gespielt und ist trotzdem
-- dusty". A minimum age floor closes that: nothing under DUSTY_MIN_DAYS is
-- ever a candidate at all, however few other candidates exist - an
-- honestly EMPTY Dusty set (nobody's actually gone quiet yet) beats a
-- technically-ranked but meaningless one.
--
-- Explicit correction, round 2: a sound NEVER played by anyone at all is
-- actually the single most obviously dusty thing possible - "sind ja die
-- optimalen Dusty Kandidaten" - the opposite of what an earlier version of
-- this assumed ("no data, not dusty"). Now iterates the FULL sound
-- registry (SB:GetAllSoundIDs, everything that exists) rather than only
-- SB.Analytics_AllSoundIDs (which only lists sounds SOMEONE has already
-- interacted with in some way - played, favourited, or muted - so a truly
-- untouched sound was invisible to this ranking entirely before). Its age
-- is measured from its own real addedAt timestamp if it has one (added
-- some days ago and simply never played since); a sound with no addedAt
-- at all is one of the ORIGINAL library sounds nobody has EVER played -
-- ranked dustiest of ALL (a large sentinel "days" value, since there's no
-- real timestamp to measure it against) - still subject to the same
-- DUSTY_MIN_DAYS floor via addedAt where one exists, so a sound added
-- yesterday and simply not played YET still isn't dusty (it'd show "New"
-- anyway, see GetTag's precedence, until that 48h window passes).
local DUSTY_MIN_DAYS = 3
local DUSTY_MAX_COUNT = 3
local DUSTY_MAX_COUNT_PRIVATE = 2
local dustySetCache, dustySetCacheAt
local dustySetCachePrivate, dustySetCachePrivateAt

local function ComputeDustySet(eligibleFn, maxCount)
    if not SB.Analytics_SoundMetrics then return {} end
    local candidates = {}
    for _, soundID in ipairs(SB:GetAllSoundIDs()) do
        if eligibleFn(soundID) then
            local ok, m = pcall(SB.Analytics_SoundMetrics, soundID, "all")
            if ok then
                local daysSince
                if m.plays > 0 and m.lastUsed and m.lastUsed > 0 then
                    daysSince = math.floor((time() - m.lastUsed) / 86400)
                else
                    local saved = SB:GetSoundSaved(soundID)
                    local addedAt = saved and saved.addedAt
                    daysSince = (addedAt and addedAt > 0) and math.floor((time() - addedAt) / 86400) or math.huge
                end
                if daysSince >= DUSTY_MIN_DAYS then
                    table.insert(candidates, { soundID = soundID, days = daysSince })
                end
            end
        end
    end
    -- Explicit bugfix: a stable alphabetical tiebreaker for equal `days` -
    -- with several never-played sounds all tied at the same sentinel
    -- value, table.sort's own comparator alone leaves their relative order
    -- undefined (Lua's sort is not guaranteed stable), so WHICH of several
    -- equally-dusty sounds actually won a slot could silently change
    -- between sessions/reloads for no real reason. Deterministic now, even
    -- though "who's dustiest among several untouched sounds" is
    -- inherently arbitrary either way.
    table.sort(candidates, function(a, b)
        if a.days ~= b.days then return a.days > b.days end
        return a.soundID < b.soundID
    end)
    local set = {}
    for i = 1, math.min(#candidates, maxCount) do
        set[candidates[i].soundID] = true
    end
    return set
end

local function GetDustySet()
    local now = GetTime()
    if dustySetCacheAt and (now - dustySetCacheAt) < MOST_PLAYED_CACHE_TTL then
        return dustySetCache
    end
    dustySetCache = SB.Analytics_IsHealthEligible
        and ComputeDustySet(SB.Analytics_IsHealthEligible, DUSTY_MAX_COUNT) or {}
    dustySetCacheAt = now
    return dustySetCache
end

local function GetDustySetPrivate()
    local now = GetTime()
    if dustySetCachePrivateAt and (now - dustySetCachePrivateAt) < MOST_PLAYED_CACHE_TTL then
        return dustySetCachePrivate
    end
    dustySetCachePrivate = SB.Analytics_IsPrivatePoolEligible
        and ComputeDustySet(SB.Analytics_IsPrivatePoolEligible, DUSTY_MAX_COUNT_PRIVATE) or {}
    dustySetCachePrivateAt = now
    return dustySetCachePrivate
end

-- "Cringe" (explicit request, data signal = "One-Man-Show" - the NAME
-- "Cringe" stays, the signal is "played a bunch, but always by the same
-- single person"). Unlike Legendary/Trending/Popular/Loved/Dusty (main
-- pool vs. Stammtisch), this is ranked separately PER ACTUAL CATEGORY -
-- Legacy, German Memes, AND Stammtisch each ALWAYS get their own single
-- Cringe winner (explicit request: "je Kategorie min 1 Cringe item,
-- immer") - ranked by plays-per-unique-listener (highest ratio = most
-- dominated by one person), with no minimum floor at all, so unlike every
-- other tag here this one is guaranteed to always crown SOMEONE in each
-- category the moment that category has any play data at all, rather than
-- only showing up once a real threshold is cleared.
local CRINGE_CATEGORIES = { "Legacy", "German Memes", SB.PRIVATE_CATEGORY }
local cringeCache = {} -- [category] = { soundID = <id or nil>, at = GetTime() }

local function ComputeCringeSoundIDForCategory(category)
    if not SB.Analytics_AllSoundIDs or not SB.Analytics_SoundMetrics or not SB.ParseSoundID then return nil end
    local bestID, bestRatio = nil, -1
    for _, soundID in ipairs(SB.Analytics_AllSoundIDs()) do
        if SB.ParseSoundID(soundID) == category then
            local ok, m = pcall(SB.Analytics_SoundMetrics, soundID, "all")
            if ok and m.plays > 0 and m.users >= 1 then
                local ratio = m.plays / m.users
                if ratio > bestRatio then
                    bestID, bestRatio = soundID, ratio
                end
            end
        end
    end
    return bestID
end

local function GetCringeSoundIDForCategory(category)
    local now = GetTime()
    local entry = cringeCache[category]
    if entry and (now - entry.at) < MOST_PLAYED_CACHE_TTL then
        return entry.soundID
    end
    entry = { soundID = ComputeCringeSoundIDForCategory(category), at = now }
    cringeCache[category] = entry
    return entry.soundID
end

local function IsCringe(soundID)
    if not soundID or not SB.ParseSoundID then return false end
    local cat = SB.ParseSoundID(soundID)
    for _, c in ipairs(CRINGE_CATEGORIES) do
        if cat == c then
            return soundID == GetCringeSoundIDForCategory(c)
        end
    end
    return false
end

-- At most one tag per sound. "Legendary" (the pool's own single most-
-- played sound, see above) always wins over everything else - explicit
-- request, it's the rarest, hardest-earned badge in the addon. "New" (a
-- real Sounds.lua library-addition date, see SoundRegistry.lua's
-- SB:IsSoundNew) wins over the Analytics-derived ones below it - explicit
-- request, a brand new sound has nothing to be Trending/Popular/Loved
-- about yet anyway. "Cringe" and "Dusty" (see above, both) are the
-- lowest-precedence tags of all - only assigned once nothing else,
-- including each other, already applies. Every SB.Analytics_Health label
-- (Insufficient Data, Spammy, Frequently Muted, Niche, Forgotten, Removal
-- Candidate) is still never shown here, per explicit request ("nur die
-- positiven" - Cringe/Dusty are their own separate, explicitly-requested
-- signals, not any of Analytics_Health's own internal labels).
local function ComputeTag(soundID)
    if soundID and (soundID == GetMostPlayedSoundID() or soundID == GetMostPlayedSoundIDPrivate()) then
        return "Legendary"
    end
    if SB.IsSoundNew and SB:IsSoundNew(soundID) then return "New" end
    if SB.Analytics_SoundMetrics and SB.Analytics_Trend and SB.Analytics_Health then
        -- Trending/Popular/Loved are Analytics-derived (community-wide
        -- health), and only ever apply to Legacy/German Memes OR
        -- Stammtisch, each its OWN separate pool (Analytics.lua's
        -- SB.Analytics_IsHealthEligible / SB.Analytics_IsPrivatePoolEligible
        -- - explicit request, Stammtisch gets "+2" of each on top of the
        -- main pool's own, never pooled together). A Category 1/2
        -- (Soundbook_MySounds) sound simply never gets one of these pills,
        -- regardless of what its own tiny-audience stats happen to say - a
        -- personal, per-player library, not shared community content.
        local eligible = (SB.Analytics_IsHealthEligible and SB.Analytics_IsHealthEligible(soundID))
            or (SB.Analytics_IsPrivatePoolEligible and SB.Analytics_IsPrivatePoolEligible(soundID))
        if eligible then
            local ok, health = pcall(function()
                local m = SB.Analytics_SoundMetrics(soundID, "all")
                local trend = SB.Analytics_Trend(soundID)
                local daysSince = (m.lastUsed and m.lastUsed > 0) and math.floor((time() - m.lastUsed) / 86400) or nil
                return SB.Analytics_Health(soundID, m, trend, daysSince)
            end)
            if ok and TAG_STYLE[health] then return health end
        end
    end
    if IsCringe(soundID) then return "Cringe" end
    if soundID and (GetDustySet()[soundID] or GetDustySetPrivate()[soundID]) then return "Dusty" end
    return nil
end

-- Explicit bugfix ("script ran too long" - the sound library has grown
-- enough that a full per-sound pass here, each doing several Analytics
-- calls plus a pcall, could exceed WoW's script watchdog): memoized for a
-- few seconds per soundID, same TTL as everything else this depends on
-- (MOST_PLAYED_CACHE_TTL) - repeated GetTag(id) calls for the SAME sound
-- within that window (every grid row re-render, every pill visibility
-- check, a tag-filtered search) become a cheap table read instead of
-- redoing ComputeTag's real work, on top of GetVisibleTagSet's own
-- chunked scan below.
local tagResultCache = {} -- [soundID] = { tag = <tag or false>, at = GetTime() }
local function GetTag(soundID)
    if not soundID then return nil end
    local cached = tagResultCache[soundID]
    local now = GetTime()
    if cached and (now - cached.at) < MOST_PLAYED_CACHE_TTL then
        return cached.tag or nil
    end
    local tag = ComputeTag(soundID)
    tagResultCache[soundID] = { tag = tag or false, at = now }
    return tag
end

-- Explicit request: a filter pill only shows at all if at least one sound
-- CURRENTLY actually carries that tag - "ich brauch nicht Trending sehen
-- oben als Pille wenn es keine Sounds dafür gibt", same for New once its
-- 48h window has nothing in it. A full scan through GetTag for every
-- sound (not just checking each tag's own underlying qualifying set, e.g.
-- SB.Analytics_TopTrendingSet non-empty) - a sound in that set could still
-- actually be showing as Legendary/New instead once GetTag's own
-- precedence resolves it, so only a real per-sound GetTag pass is
-- guaranteed to match what pills actually render.
--
-- Explicit bugfix ("script ran too long"): as the sound library grew, one
-- full synchronous pass here (even with GetTag's own per-sound memoizing
-- above) could still add up to more than WoW's script watchdog allows in
-- a single frame, crashing the whole UI refresh. The scan below now runs
-- in small chunks spread across several ticks instead of blocking in one
-- call - GetVisibleTagSet itself always still returns immediately (the
-- last COMPLETED result, however slightly stale, or - only on the very
-- first call this session, before any scan has ever finished - every tag
-- marked visible as a safe default). A pill that turns out to have
-- nothing under it a moment later is simply hidden once the scan in
-- progress finishes and the pill bar re-syncs itself, rather than the
-- game ever blocking to get it exactly right immediately.
local visibleTagSetCache, visibleTagSetCacheAt
local VISIBLE_TAG_SCAN_CHUNK = 12 -- sounds processed per tick
local scanIDs, scanIndex, scanResult, scanTicker

local function FinishVisibleTagSetScan()
    if scanTicker then
        scanTicker:Cancel()
        scanTicker = nil
    end
    visibleTagSetCache = scanResult
    visibleTagSetCacheAt = GetTime()
    scanIDs, scanIndex, scanResult = nil, nil, nil
    if main and main.tagFilterUpdaters then
        for _, updateFn in ipairs(main.tagFilterUpdaters) do updateFn() end
    end
end

local function StepVisibleTagSetScan()
    for _ = 1, VISIBLE_TAG_SCAN_CHUNK do
        scanIndex = scanIndex + 1
        local id = scanIDs[scanIndex]
        if not id then
            FinishVisibleTagSetScan()
            return
        end
        local tag = GetTag(id)
        if tag then scanResult[tag] = true end
    end
end

local function StartVisibleTagSetScan()
    if scanTicker then return end -- already running
    scanIDs = SB:GetAllSoundIDs()
    scanIndex = 0
    scanResult = {}
    scanTicker = C_Timer.NewTicker(0.01, StepVisibleTagSetScan)
end

local function GetVisibleTagSet()
    local now = GetTime()
    if visibleTagSetCacheAt and (now - visibleTagSetCacheAt) < MOST_PLAYED_CACHE_TTL then
        return visibleTagSetCache
    end
    StartVisibleTagSetScan()
    if visibleTagSetCache then return visibleTagSetCache end
    local allVisible = {}
    for tagKey in pairs(TAG_STYLE) do allVisible[tagKey] = true end
    return allVisible
end

--- The cross-category flat list used whenever IsFiltering() is true -
--- text search and active tag filters both narrow this SAME list (AND'ed
--- together when both are active), completely ignoring category
--- boundaries, same as a text search alone already did. An active tag
--- filter is an OR across whichever pills are toggled on
--- (New/Trending/Popular/Loved) - explicit request.
local function GetFilteredSoundList()
    local query = searchBox and searchBox:GetText()
    local hasQuery = query and query ~= ""
    if hasQuery then query = query:lower() end
    local activeTags = SB.db.ui.tagFilters
    local hasTagFilter = next(activeTags) ~= nil

    -- `tag`/`negative` decorated up front (not recomputed per comparison
    -- inside the sort).
    local results = {}
    for _, id in ipairs(SB:GetAllSoundIDs()) do
        local tag = GetTag(id)
        local nameMatch = hasQuery and SB:GetSoundDisplayName(id):lower():find(query, 1, true)
        local tagMatch = false
        if hasQuery and not nameMatch then
            local info = SB.registry[id]
            if info and info.tags then
                for _, t in ipairs(info.tags) do
                    if t:find(query, 1, true) then
                        tagMatch = true
                        break
                    end
                end
            end
        end
        if (not hasQuery or nameMatch or tagMatch)
            and (not hasTagFilter or activeTags[tag]) then
            table.insert(results, { id = id, tag = tag, negative = NEGATIVE_TAGS[tag] and true or false })
        end
    end
    table.sort(results, function(a, b)
        if hasTagFilter then
            -- Explicit request: with one or more tag pills active, group
            -- the results by pill - in the SAME order the pills themselves
            -- are shown (TAG_FILTER_ORDER/TAG_ORDER_RANK above) - instead
            -- of one flat alphabetical list that mixes every active tag
            -- together. Cringe/Dusty still end up last on their own,
            -- simply because they're already last in that same order -
            -- alphabetical within each tag's own group.
            local ra, rb = TAG_ORDER_RANK[a.tag] or math.huge, TAG_ORDER_RANK[b.tag] or math.huge
            if ra ~= rb then return ra < rb end
            return SB:GetSoundDisplayName(a.id):lower() < SB:GetSoundDisplayName(b.id):lower()
        end
        -- Plain text search, no tag pill active - unchanged: a Cringe/Dusty
        -- sound still always sorts to the very end, "immer an letzter
        -- Stelle", everything else alphabetically among itself.
        if a.negative ~= b.negative then return not a.negative end
        return SB:GetSoundDisplayName(a.id):lower() < SB:GetSoundDisplayName(b.id):lower()
    end)
    local ids = {}
    for _, r in ipairs(results) do table.insert(ids, r.id) end
    return ids
end

local function CursorPositionUI()
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    return x / scale, y / scale
end

local function PointInside(frame, x, y)
    if not frame or not x then return false end
    local left, right, top, bottom = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
    return left and x >= left and x <= right and y >= bottom and y <= top
end

local function StartMainFavouriteDrag(btn)
    if IsFiltering() or not btn.favouriteSlot then return end
    mainDragSourceSlot = btn.favouriteSlot
    mainDragSoundID = btn.soundID
    if btn.favouriteHover then btn.favouriteHover:Hide() end
    -- Reveal the otherwise invisible empty slots as grey icon drop targets
    -- for the duration of this drag, matching the old Mini Soundbook's own
    -- behaviour.
    RefreshLibrary()

    if not mainDragGhostFrame then
        mainDragGhostFrame = SB.CreateFrame("Frame", nil, UIParent)
        mainDragGhostFrame:SetFrameStrata("TOOLTIP")
        mainDragGhostFrame:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        mainDragGhostIcon = mainDragGhostFrame:CreateTexture(nil, "ARTWORK")
        mainDragGhostIcon:SetAllPoints()
        mainDragGhostIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        mainDragGhostOrnament = mainDragGhostFrame:CreateTexture(nil, "OVERLAY")
        mainDragGhostOrnament:SetPoint("CENTER", mainDragGhostFrame, "CENTER", 0, 0)
        mainDragGhostOrnament:SetTexture("Interface\\AddOns\\Soundbook\\Assets\\IconFrame")
        mainDragGhostOrnament:SetTexCoord(0, 1, 0, 1)
    end
    local size = math.max(24, (btn.slot:GetWidth() or ICON_SIZE) * 1.30)
    mainDragGhostFrame:SetSize(size, size)
    mainDragGhostOrnament:SetSize(size * 1.50, size * 1.50)
    mainDragGhostFrame:SetBackdropBorderColor(unpack(SB.Theme.GOLD))
    mainDragGhostIcon:SetTexture(SB:GetSoundIcon(btn.soundID))
    mainDragGhostIcon:SetVertexColor(1, 1, 1)
    mainDragGhostOrnament:SetVertexColor(0.88, 0.94, 1, 1)
    mainDragGhostFrame:Show()
    mainDragGhostFrame:SetScript("OnUpdate", function()
        local x, y = CursorPositionUI()
        mainDragGhostFrame:ClearAllPoints()
        mainDragGhostFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
        if not PointInside(main, x, y) then
            mainDragGhostIcon:SetVertexColor(1, 0.3, 0.3)
            mainDragGhostOrnament:SetVertexColor(1, 0.18, 0.18, 1)
            mainDragGhostFrame:SetBackdropBorderColor(1, 0.15, 0.15, 1)
        else
            mainDragGhostIcon:SetVertexColor(1, 1, 1)
            mainDragGhostOrnament:SetVertexColor(0.88, 0.94, 1, 1)
            mainDragGhostFrame:SetBackdropBorderColor(unpack(SB.Theme.GOLD))
        end
    end)
end

local function StopMainFavouriteDrag()
    if not mainDragSourceSlot then return end
    local x, y = CursorPositionUI()
    local targetSlot
    for _, candidate in ipairs(entryButtons) do
        if candidate:IsShown() and candidate.favouriteSlot and candidate:IsMouseOver() then
            targetSlot = candidate.favouriteSlot
            break
        end
    end
    if not PointInside(main, x, y) then
        if mainDragSoundID then SB:RemoveFavourite(mainDragSoundID) end
    elseif targetSlot and targetSlot ~= mainDragSourceSlot then
        SB:MoveFavourite(mainDragSourceSlot, targetSlot)
    end
    if mainDragGhostFrame then
        mainDragGhostFrame:SetScript("OnUpdate", nil)
        mainDragGhostFrame:Hide()
    end
    mainDragSourceSlot, mainDragSoundID = nil, nil
    RefreshLibrary()
    -- Explicit report: dropping a swap onto a slot the cursor is still
    -- sitting on kept showing the PREVIOUS occupant's enlarged hover
    -- preview until the mouse actually moved - OnEnter (which sets that
    -- preview's texture) only fires on a fresh mouse-enter, not just
    -- because RefreshLibrary repopulated the button underneath the
    -- cursor. Re-sync it here for whichever button the cursor is
    -- actually over right now.
    for _, candidate in ipairs(entryButtons) do
        if candidate:IsShown() and candidate.favouriteHover and candidate.favouriteHover:IsShown()
            and candidate:IsMouseOver() and candidate.soundID then
            candidate.favouriteHoverIcon:SetTexture(SB:GetSoundIcon(candidate.soundID))
        end
    end
end

------------------------------------------------------------------------
-- Sound entry buttons - unchanged from the pre-3.0 book (same card look,
-- same tooltip/click/hover behaviour), just parented into the new
-- scrolling Library content instead of a fixed page grid. Positioning is
-- entirely the new layout code's job (see LayoutEntries below).
------------------------------------------------------------------------

local function CreateEntryButton(index)
    -- Parented to the scroll frame's own content (not `main` directly) so
    -- WoW's ScrollFrame clipping actually applies - a frame merely
    -- POSITIONED via anchors to overlap the scroll area while parented
    -- elsewhere would render outside the visible viewport instead of being
    -- clipped by it.
    local btn = CreateFrame("Button", "SoundbookEntry" .. index, main.libraryScroll.content)
    btn:SetSize(ENTRY_W, ROW_H)

    local rowBg = btn:CreateTexture(nil, "BACKGROUND")
    rowBg:SetPoint("TOPLEFT", 1, -1)
    rowBg:SetPoint("BOTTOMRIGHT", -1, 1)
    rowBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    rowBg:SetVertexColor(0.015, 0.055, 0.12, (index % 2 == 0) and 0.58 or 0.36)
    btn.rowBg = rowBg
    btn.baseRowAlpha = (index % 2 == 0) and 0.42 or 0.24
    local separator = btn:CreateTexture(nil, "BORDER")
    separator:SetPoint("BOTTOMLEFT", 4, 0)
    separator:SetPoint("BOTTOMRIGHT", -4, 0)
    separator:SetHeight(1)
    separator:SetTexture("Interface\\Buttons\\WHITE8X8")
    separator:SetVertexColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.22)
    btn.separator = separator

    -- Flat square icon slot - its border turns the accent colour when the
    -- sound is a Favourite, replacing the old separate star badge.
    local slot = SB.Theme.CreateIconSlot(btn, ICON_SIZE + 2)
    slot:SetPoint("LEFT", 4, 0)
    btn.slot = slot
    btn.icon = slot.texture

    -- Favourites-only 130% icon preview. It is a separate overlay so only
    -- the icon grows; the row and its text remain perfectly aligned. The
    -- decorative texture is cropped to its painted bounds and exists only
    -- while hovering this page.
    local favouriteHover = SB.CreateFrame("Frame", nil, btn)
    favouriteHover:SetPoint("CENTER", slot, "CENTER", 0, 0)
    favouriteHover:SetFrameLevel(btn:GetFrameLevel() + 30)
    favouriteHover:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    favouriteHover:SetBackdropBorderColor(unpack(SB.Theme.GOLD))
    favouriteHover:EnableMouse(false)
    local favouriteHoverIcon = favouriteHover:CreateTexture(nil, "ARTWORK")
    favouriteHoverIcon:SetAllPoints()
    favouriteHoverIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local favouriteHoverOrnament = favouriteHover:CreateTexture(nil, "OVERLAY")
    favouriteHoverOrnament:SetPoint("CENTER", favouriteHover, "CENTER", 0, 0)
    favouriteHoverOrnament:SetTexture("Interface\\AddOns\\Soundbook\\Assets\\IconFrame")
    favouriteHoverOrnament:SetTexCoord(0, 1, 0, 1)
    favouriteHoverOrnament:SetVertexColor(0.88, 0.94, 1, 1)
    favouriteHover:Hide()
    btn.favouriteHover = favouriteHover
    btn.favouriteHoverIcon = favouriteHoverIcon
    btn.favouriteHoverOrnament = favouriteHoverOrnament

    local name = btn:CreateFontString(nil, "OVERLAY")
    name:SetFontObject(SB.Fonts.Highlight)
    name:SetPoint("LEFT", slot, "RIGHT", 8, 0)
    name:SetPoint("RIGHT", -8, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    btn.nameText = name

    -- "Hotkey: CTRL+A" - explicit request: Favourites only, white, two font
    -- sizes smaller than the name above it, and only shown at all when THIS
    -- slot actually has a real Blizzard keybinding assigned (see
    -- PopulateEntryButton and Keybindings.lua's SB:GetFavouriteHotkeyLabel).
    local hotkeyText = btn:CreateFontString(nil, "OVERLAY")
    hotkeyText:SetFontObject(SB.Fonts.DisableSmall)
    hotkeyText:SetPoint("RIGHT", -8, 0)
    hotkeyText:SetWidth(82)
    hotkeyText:SetJustifyH("RIGHT")
    hotkeyText:SetWordWrap(false)
    hotkeyText:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    hotkeyText:Hide()
    btn.hotkeyText = hotkeyText

    -- "Tag" pill - New/Trending/Popular/Loved (see GetTag below), inline
    -- right after the name, same row. At most one tag per sound. Genuinely
    -- rounded (explicit request, "schön rund") - built from a small
    -- semicircular cap texture (Assets/TagCap.tga) on each side plus a
    -- flat middle that stretches to fit the label, rather than a plain
    -- rectangle; the same cap texture is reused mirrored for the right
    -- side, so only one small asset was needed.
    local TAG_CAP_W, TAG_H = 7, 14
    local tag = SB.CreateFrame("Frame", nil, btn)
    tag:SetHeight(TAG_H)
    tag:SetPoint("RIGHT", -8, 0)
    tag:Hide()

    local leftCap = tag:CreateTexture(nil, "ARTWORK")
    leftCap:SetSize(TAG_CAP_W, TAG_H)
    leftCap:SetPoint("LEFT", tag, "LEFT", 0, 0)
    leftCap:SetTexture("Interface\\AddOns\\Soundbook\\Assets\\TagCap")
    tag.leftCap = leftCap

    local rightCap = tag:CreateTexture(nil, "ARTWORK")
    rightCap:SetSize(TAG_CAP_W, TAG_H)
    rightCap:SetPoint("RIGHT", tag, "RIGHT", 0, 0)
    rightCap:SetTexture("Interface\\AddOns\\Soundbook\\Assets\\TagCap")
    -- Same asset, horizontally flipped - the cap bulges left by default
    -- (built to butt against a middle piece on its right), so mirroring
    -- the U coordinates makes it bulge right instead.
    rightCap:SetTexCoord(1, 0, 0, 1)
    tag.rightCap = rightCap

    local middle = tag:CreateTexture(nil, "ARTWORK")
    middle:SetPoint("TOPLEFT", leftCap, "TOPRIGHT", 0, 0)
    middle:SetPoint("BOTTOMRIGHT", rightCap, "BOTTOMLEFT", 0, 0)
    middle:SetTexture("Interface\\Buttons\\WHITE8X8")
    tag.middle = middle

    local tagText = tag:CreateFontString(nil, "OVERLAY")
    tagText:SetFontObject(SB.Fonts.DisableSmall)
    tagText:SetPoint("CENTER")
    tag.text = tagText
    btn.tag = tag
    btn.TAG_CAP_W = TAG_CAP_W

    -- Flat, full-row accent tint instead of the old glowy ADD-blend edge
    -- highlight - explicit request: same "whole background lights up" style
    -- Theme.lua's dropdown rows already use (Theme.CreateDropdown's
    -- BuildRows), for visual consistency across the addon.
    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(SB.Theme.ACCENT[1], SB.Theme.ACCENT[2], SB.Theme.ACCENT[3], 0.12)
    -- Kept around so PopulateEntryButton can recolour it per-row (blue/
    -- accent for a normal sound, gold for a favourite) - explicit request.
    btn.highlight = highlight

    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:RegisterForDrag("LeftButton")
    btn:SetScript("OnDragStart", function(self) StartMainFavouriteDrag(self) end)
    btn:SetScript("OnDragStop", StopMainFavouriteDrag)
    btn:SetScript("OnClick", function(self, button)
        if not self.soundID then return end
        selectedSoundID = self.soundID
        if button == "LeftButton" then
            if IsShiftKeyDown() then
                SB:ToggleFavourite(self.soundID)
            else
                SB:TriggerSound(self.soundID)
            end
        elseif button == "RightButton" then
            if IsShiftKeyDown() then
                -- One-off "send to a specific channel/person" popup -
                -- explicit request: plain right-click stays Edit Sound
                -- (established behaviour), so the send menu needs its own
                -- modifier to stay reachable.
                SB.OpenSendMenu(self.soundID)
            else
                SB.ToggleEditWindow(self.soundID)
            end
        end
        if SB.RefreshMainWindow then SB:RefreshMainWindow() end
    end)

    btn:SetScript("OnEnter", function(self)
        if not self.soundID then return end
        -- The flat accent-tinted background above now covers the whole
        -- row, so whatever resting colour the name text has (gold/accent/
        -- grey - see PopulateEntryButton's btn.restColor) needs to give
        -- way to something that stays readable against an accent-coloured
        -- background specifically - plain white, same choice SendMenu.lua's
        -- own hover rows already made for the identical reason.
        self.nameText:SetTextColor(0.72, 0.86, 1.0)
        -- Explicit request: every sound's icon enlarges on hover, not just
        -- Favourites - the favouriteHover overlay frame already exists on
        -- every entry (LayoutEntries sizes it uniformly regardless of
        -- section), it was just gated to isFavouriteView here.
        if self.favouriteHover then
            self.favouriteHoverIcon:SetTexture(SB:GetSoundIcon(self.soundID))
            self.favouriteHover:Show()
        end
        local info = SB.registry[self.soundID]
        if not info then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(SB:GetSoundDisplayName(self.soundID), unpack(SB.Theme.GOLD))
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left Click: Play", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("Right Click: Edit", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("Shift + Left Click: Favourite", 0.9, 0.9, 0.9)
        GameTooltip:AddLine("Shift + Right Click: Send to...", 0.9, 0.9, 0.9)
        -- Tag explanation (explicit request) - ONLY for a sound that
        -- actually carries this tag right now (self.currentTagKey, set by
        -- PopulateEntryButton alongside the pill itself), coloured the same
        -- as the pill's own text so "why does this say Loved?" is answered
        -- right here instead of sending someone to the Analytics window.
        if self.currentTagKey then
            local style = TAG_STYLE[self.currentTagKey]
            if style and style.desc then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(style.label .. ": " .. style.desc, style.text[1], style.text[2], style.text[3], true)
            end
        end
        local saved = SB:GetSoundSaved(self.soundID)
        if saved.muted then GameTooltip:AddLine("Muted", 1, 0.3, 0.3) end
        if saved.outputOverride and saved.outputOverride ~= "ALL" then
            local oc = SB.SoundOutputOverrideColor and SB.SoundOutputOverrideColor(self.soundID)
            local label = saved.outputOverride:match("^PLAYER:(.+)$") or saved.outputOverride
            if oc then
                GameTooltip:AddLine("Default Output: " .. label, oc.r, oc.g, oc.b)
            end
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if self.favouriteHover then self.favouriteHover:Hide() end
        local c = self.restColor
        if c then self.nameText:SetTextColor(c[1], c[2], c[3]) end
    end)

    return btn
end

local function GetOrCreateEntry(index)
    if not entryButtons[index] then
        entryButtons[index] = CreateEntryButton(index)
    end
    return entryButtons[index]
end

------------------------------------------------------------------------
-- Populates one already-positioned/sized entry button. `favouriteSlot` is
-- the real 1..MAX_FAVOURITES position (only meaningful inside the
-- Favourites section); `isFavouritesBlock` gates the hotkey-vs-tag column
-- and the drag-and-drop wiring the exact same way `SB.db.ui.currentTab ==
-- "favourites"` used to in the old paged book.
------------------------------------------------------------------------

local function PopulateEntryButton(btn, soundID, favouriteSlot, isFavouritesBlock)
    if soundID and SB.registry[soundID] then
        local saved = SB:GetSoundSaved(soundID)
        btn.soundID = soundID
        btn.icon:SetTexture(SB:GetSoundIcon(soundID))
        btn.icon:Show()
        -- "Alternative Sound" purple wash (Theme.lua's CreateIconSlot) -
        -- explicit request, shown "always, everywhere" for a sound with a
        -- personal alternate recording enabled.
        btn.slot:SetAlternate(saved.useAlternate)
        -- Per-sound "Default Output" override (explicit request) - same
        -- always-visible treatment as the Alternative Sound wash above,
        -- just a different colour source (SB.CHANNEL_COLOR via the
        -- sound's own saved.outputOverride, Communication.lua).
        local outputColor = SB.SoundOutputOverrideColor and SB.SoundOutputOverrideColor(soundID)
        btn.slot:SetOutputTint(outputColor)
        btn.rowBg:Show()
        btn.separator:Show()
        btn.nameText:SetText(SB:GetSoundDisplayName(soundID))
        -- Resting colour follows information hierarchy: readable off-white
        -- by default, grey when muted, warm gold while actually playing.
        -- remembered so OnLeave can restore exactly this once the hover
        -- highlight's forced white lets go - see CreateEntryButton.
        local restColor
        local isPlaying = playingSoundID == soundID
        local isSelected = selectedSoundID == soundID
        if isPlaying then
            restColor = { 1.0, 0.84, 0.48 }
            btn.rowBg:SetVertexColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.12)
        elseif saved.muted then
            restColor = SB.Theme.TEXT_DIM
            btn.rowBg:SetVertexColor(0.02, 0.04, 0.07, btn.baseRowAlpha)
        elseif outputColor then
            -- Per-sound "Default Output" override (explicit request) -
            -- same channel colour as the icon border/wash above. Wins
            -- over a plain favourite gold, same precedence as the
            -- border's own (Theme.lua's SetVisualState), but still
            -- loses to muted/playing.
            restColor = { outputColor.r, outputColor.g, outputColor.b }
            btn.rowBg:SetVertexColor(0.015, 0.055, 0.12, btn.baseRowAlpha)
        elseif saved.favourite then
            restColor = SB.Theme.GOLD
            btn.rowBg:SetVertexColor(0.015, 0.055, 0.12, btn.baseRowAlpha)
        elseif isSelected then
            restColor = SB.Theme.TEXT
            btn.rowBg:SetVertexColor(SB.Theme.ACCENT[1], SB.Theme.ACCENT[2], SB.Theme.ACCENT[3], 0.11)
        else
            restColor = SB.Theme.TEXT
            btn.rowBg:SetVertexColor(0.015, 0.055, 0.12, btn.baseRowAlpha)
        end
        btn.restColor = restColor
        if not btn:IsMouseOver() then
            btn.nameText:SetTextColor(unpack(restColor))
        end
        -- Explicit request: the hover highlight itself is gold for a
        -- favourite (matching its gold resting name colour/border above),
        -- blue/accent otherwise - so hovering makes favourite status
        -- visible at a glance, not just the name colour. Reset live every
        -- refresh (including right after Shift+Left-Click toggles a
        -- favourite), so the new colour shows immediately, no reload/
        -- re-hover needed.
        if btn.highlight then
            if saved.favourite then
                btn.highlight:SetColorTexture(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.16)
            else
                btn.highlight:SetColorTexture(SB.Theme.ACCENT[1], SB.Theme.ACCENT[2], SB.Theme.ACCENT[3], 0.12)
            end
        end
        btn.slot:SetVisualState(isPlaying and "playing" or (isSelected and "selected" or "normal"),
            saved.favourite and true or false, saved.muted and true or false, outputColor)

        -- Hotkey label - Favourites section only, never during search.
        -- Explicit request: an unbound position shows nothing at all - no
        -- "[-]" placeholder - only an actually-assigned keybind gets the
        -- "[X]" label.
        local hotkey = (not IsFiltering()) and isFavouritesBlock and favouriteSlot
            and SB.GetFavouriteHotkeyLabel and SB:GetFavouriteHotkeyLabel(favouriteSlot)
        btn.favouriteSlot = (isFavouritesBlock and not IsFiltering()) and favouriteSlot or nil
        btn.isFavouriteView = (isFavouritesBlock and not IsFiltering()) and true or false
        if btn.isFavouriteView and hotkey then
            btn.nameText:ClearAllPoints()
            btn.nameText:SetPoint("LEFT", btn.slot, "RIGHT", 8, 0)
            btn.nameText:SetPoint("RIGHT", btn.hotkeyText, "LEFT", -8, 0)
            btn.hotkeyText:SetText("[" .. hotkey .. "]")
            btn.hotkeyText:Show()
            if btn.tag then btn.tag:Hide() end
            btn.currentTagKey = nil
        else
            btn.hotkeyText:Hide()
            -- Tags never show on Favourites at all - explicit fix: that
            -- column is reserved for hotkey labels there (shown only on
            -- SOME rows, whichever slots have a real keybind), so a tag
            -- appearing on the other rows read as randomly conflicting
            -- with the hotkey column instead of looking like a deliberate
            -- second thing. A Favourite is also already a sound the
            -- player deliberately chose - a "Popular"/"Loved" hint adds
            -- little there anyway.
            local tagKey = (not btn.isFavouriteView) and btn.tag and GetTag(soundID)
            btn.currentTagKey = tagKey or nil
            if tagKey then
                local style = TAG_STYLE[tagKey]
                btn.tag.text:SetText(style.label)
                btn.tag.text:SetTextColor(unpack(style.text))
                btn.tag.leftCap:SetVertexColor(style.bg[1], style.bg[2], style.bg[3], 0.92)
                btn.tag.rightCap:SetVertexColor(style.bg[1], style.bg[2], style.bg[3], 0.92)
                btn.tag.middle:SetVertexColor(style.bg[1], style.bg[2], style.bg[3], 0.92)
                btn.tag:SetWidth(btn.TAG_CAP_W * 2 + btn.tag.text:GetStringWidth() + 8)
                btn.tag:ClearAllPoints()
                btn.tag:SetPoint("RIGHT", -8, 0)
                btn.tag:Show()
                btn.nameText:ClearAllPoints()
                btn.nameText:SetPoint("LEFT", btn.slot, "RIGHT", 8, 0)
                btn.nameText:SetPoint("RIGHT", btn.tag, "LEFT", -6, 0)
            else
                if btn.tag then btn.tag:Hide() end
                btn.nameText:ClearAllPoints()
                btn.nameText:SetPoint("LEFT", btn.slot, "RIGHT", 8, 0)
                btn.nameText:SetPoint("RIGHT", -8, 0)
            end
        end

        btn:Show()
    else
        btn.soundID = nil
        btn.slot:SetAlternate(false)
        btn.slot:SetOutputTint(nil)
        local isFavouriteDropTarget = isFavouritesBlock and mainDragSourceSlot
            and favouriteSlot and favouriteSlot <= SB.MAX_FAVOURITES
        btn.favouriteSlot = isFavouriteDropTarget and favouriteSlot or nil
        btn.isFavouriteView = false
        if btn.favouriteHover then btn.favouriteHover:Hide() end
        btn.hotkeyText:Hide()
        if btn.tag then btn.tag:Hide() end
        btn.currentTagKey = nil
        if isFavouriteDropTarget then
            btn.icon:Hide()
            btn.nameText:SetText("")
            btn.rowBg:Hide()
            btn.separator:Hide()
            btn.slot:SetBackdropColor(0, 0, 0, 0)
            btn.slot:SetBackdropBorderColor(0.48, 0.52, 0.58, 0.85)
            btn:Show()
        else
            btn:Hide()
        end
    end
end

------------------------------------------------------------------------
-- Section headers - a collapsible row for each category ("▼ Legacy   24"),
-- plus a non-collapsible one for Favourites (with a "Keybinds" shortcut
-- instead of a caret - 3.0 spec section 29/section 52).
------------------------------------------------------------------------

local function CreateSectionHeaderRow(index)
    -- Same clipping reasoning as CreateEntryButton above.
    local hdr = SB.CreateFrame("Button", "SoundbookSection" .. index, main.libraryScroll.content)
    hdr:SetHeight(SECTION_HEADER_H)

    -- Explicit report: not obviously a collapse/expand control - bigger,
    -- bolder and brighter gold than the rest of the row, not just a small
    -- dim ">"/"v" easy to miss entirely.
    local caret = hdr:CreateFontString(nil, "OVERLAY")
    caret:SetFontObject(SB.Fonts.NormalLarge)
    caret:SetPoint("LEFT", 2, 0)
    caret:SetWidth(18)
    caret:SetTextColor(1, 0.82, 0.15)
    hdr.caret = caret

    local icon = hdr:CreateTexture(nil, "ARTWORK")
    icon:SetSize(18, 18)
    icon:SetPoint("LEFT", caret, "RIGHT", 2, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    hdr.icon = icon

    -- Explicit report: should stand out more from the sound rows below it
    -- - a bigger font (NormalLarge, same one the window's own header/title
    -- text uses) instead of Highlight, which is the same size regular
    -- sound names already use.
    local title = hdr:CreateFontString(nil, "OVERLAY")
    title:SetFontObject(SB.Fonts.NormalLarge)
    title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    title:SetTextColor(unpack(SB.Theme.TEXT))
    hdr.title = title

    local count = hdr:CreateFontString(nil, "OVERLAY")
    count:SetFontObject(SB.Fonts.DisableSmall)
    count:SetPoint("RIGHT", -6, 0)
    count:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    hdr.count = count

    -- Favourites-only shortcut, replacing count in that one row.
    local keybindsBtn = SB.Theme.CreateFlatButton(hdr, "Keybinds", 90, 18)
    keybindsBtn:SetPoint("RIGHT", -4, 0)
    keybindsBtn:SetScript("OnClick", function() SB:OpenSettingsAtKeybindings() end)
    keybindsBtn:Hide()
    hdr.keybindsBtn = keybindsBtn

    local line = hdr:CreateTexture(nil, "ARTWORK")
    line:SetPoint("BOTTOMLEFT", 2, 0)
    line:SetPoint("BOTTOMRIGHT", -2, 0)
    line:SetHeight(1)
    line:SetTexture("Interface\\Buttons\\WHITE8X8")
    line:SetVertexColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.3)

    hdr:SetScript("OnClick", function(self)
        if not self.sectionKey then return end
        if self.sectionKey == "hide" then
            hideSectionExpanded = not hideSectionExpanded
            RefreshLibrary()
            return
        end
        -- "favourites" here is a reserved internal persistence key, never
        -- the visible label ("Favourites") - explicit requirement, so a
        -- future label/rename never silently resets this collapse state.
        local key = tostring(self.sectionKey)
        SB.db.ui.categoryCollapsed[key] = (not SB.db.ui.categoryCollapsed[key]) or nil
        RefreshLibrary()
    end)

    return hdr
end

local function GetOrCreateHeader(index)
    if not sectionHeaders[index] then
        sectionHeaders[index] = CreateSectionHeaderRow(index)
    end
    return sectionHeaders[index]
end

local function ConfigureHeader(hdr, sectionKey, title, icon, collapsed, count, isFavourites)
    hdr.sectionKey = sectionKey
    hdr.title:SetText(title)
    if icon then
        hdr.icon:SetTexture(icon)
        hdr.icon:Show()
    else
        hdr.icon:Hide()
    end
    -- Plain ASCII, not a Unicode triangle glyph - matches
    -- Theme.CreateDropdown's own "v" arrow precedent elsewhere in this
    -- addon; WoW's bundled fonts (FRIZQT__.TTF etc.) don't reliably cover
    -- Unicode geometric shapes.
    hdr.caret:SetText(collapsed and ">" or "v")
    if isFavourites then
        -- Keybinds is only useful (and only shown) while expanded, mirroring
        -- a category's own count - collapsed swaps it for the same kind of
        -- "how much is hidden here" count a category shows.
        if collapsed then
            hdr.count:SetText(tostring(count or 0))
            hdr.count:Show()
            hdr.keybindsBtn:Hide()
        else
            hdr.count:Hide()
            hdr.keybindsBtn:Show()
        end
    else
        hdr.count:SetText(tostring(count or 0))
        hdr.count:Show()
        hdr.keybindsBtn:Hide()
    end
    hdr:Show()
end

------------------------------------------------------------------------
-- Library layout - one continuous scroll, Favourites first (never
-- collapsible), then a collapsible section per visible category. While
-- filtering (search text and/or an active tag pill), every section
-- collapses into one flat cross-category result list instead (3.0 spec
-- section 32) - collapsed state itself is left untouched so it's restored
-- exactly once filtering ends.
------------------------------------------------------------------------

local function BuildSectionList()
    if IsFiltering() then
        return { { type = "filtered" } }
    end
    local list = { { type = "favourites" } }
    for _, tab in ipairs(TABS) do
        if not tab.isFavourites then
            local visible
            if tab.isHide then
                visible = HasHiddenSounds()
            else
                visible = (not tab.isPrivate or SB:HasPrivateSounds())
                    and (not tab.hideIfEmpty or SB:HasCategorySounds(tab.key))
            end
            if visible then
                table.insert(list, { type = "category", tab = tab })
            end
        end
    end
    return list
end

-- Lays out `ids` (a possibly-sparse array, holes allowed for empty
-- Favourite drop targets) starting at vertical offset `y`, returns the new
-- y after this block. `favouriteSlotFor(idx)` is only used for the
-- Favourites block (returns the real 1..20 slot for entry `idx`).
local function LayoutEntries(ids, n, y, columns, entryW, iconExtent, hotkeyWidth, isFavouritesBlock, favouriteSlotFor)
    if n == 0 then return y end
    local rows = math.ceil(n / columns)
    for idx = 1, n do
        local soundID = ids[idx]
        usedEntries = usedEntries + 1
        local btn = GetOrCreateEntry(usedEntries)
        local col = (idx - 1) % columns
        local row = math.floor((idx - 1) / columns)
        btn:ClearAllPoints()
        btn:SetSize(entryW, ROW_H)
        btn:SetPoint("TOPLEFT", main.libraryScroll.content, "TOPLEFT", GRID_LEFT_PAD + col * entryW, -(y + row * ROW_H))
        btn.slot:SetSize(iconExtent, iconExtent)
        btn.favouriteHover:SetSize(iconExtent * 1.30, iconExtent * 1.30)
        btn.favouriteHoverOrnament:SetSize(iconExtent * 1.30 * 1.50, iconExtent * 1.30 * 1.50)
        btn.hotkeyText:SetWidth(hotkeyWidth)
        local slot = favouriteSlotFor and favouriteSlotFor(idx) or nil
        PopulateEntryButton(btn, soundID, slot, isFavouritesBlock)
    end
    return y + rows * ROW_H
end

local favEmptyHint

local function BuildFavouritesEntries()
    local favourites = SB:GetFavourites() -- sparse, indices 1..MAX_FAVOURITES
    local dragging = mainDragSourceSlot ~= nil
    local ids, slots = {}, {}
    for slotIndex = 1, SB.MAX_FAVOURITES do
        local soundID = favourites[slotIndex]
        if soundID or dragging then
            table.insert(ids, soundID)
            table.insert(slots, slotIndex)
        end
    end
    return ids, slots
end

local function RefreshLibraryImpl()
    if isSettingsOpen or isAdminOpen then return end
    SB:Debug("RefreshLibrary: isFiltering=%s searching=%s tagFilterCount=%s scrollW=%s scrollH=%s contentH=%s vscroll=%s",
        tostring(IsFiltering()), tostring(IsSearching()),
        tostring(next(SB.db.ui.tagFilters) and "yes" or "no"),
        tostring(main.libraryScroll and main.libraryScroll.scroll:GetWidth()),
        tostring(main.libraryScroll and main.libraryScroll.scroll:GetHeight()),
        tostring(main.libraryScroll and main.libraryScroll.content:GetHeight()),
        tostring(main.libraryScroll and main.libraryScroll.scroll:GetVerticalScroll()))
    local scroll = main.libraryScroll
    -- Defensive floor: the scroll frame's width comes from a multi-hop
    -- anchor chain (main -> toolbar -> tagFilterBar -> outputRail ->
    -- libraryScroll.scroll) rather than a single hop off `main` directly
    -- like the pre-3.0 book used. That chain does resolve synchronously in
    -- practice, but GetWidth() returning 0/nil on the very first layout
    -- pass (before anything has actually been shown once) would otherwise
    -- produce zero-width, invisible cards while the section headers (whose
    -- width comes from a separate RIGHT-relative anchor, not entryW) still
    -- render fine - exactly the "headers visible, no sound cards" failure
    -- mode this guards against.
    local contentWidth = scroll.scroll:GetWidth() or 0
    if contentWidth < ENTRY_W then contentWidth = ENTRY_W * 2 end
    -- A ScrollFrame's scroll child must be sized via SetWidth, not a second
    -- (RIGHT-edge) anchor point - once SetVerticalScroll is ever called with
    -- a non-zero offset, the engine repositions the child through its own
    -- anchor internally, and a second manual anchor on the same frame turns
    -- its rect unresolvable (GetLeft/GetTop go nil, dependent widths like
    -- the section headers' collapse to 0). This is exactly what made the
    -- Library go fully blank on the very first scroll/collapse action.
    scroll.content:SetWidth(contentWidth)
    -- Explicit report: bumping Settings -> Soundbook Text Size made sound
    -- names truncate, because the column grid never knew the font had
    -- grown - ROW_H/THREE_COLUMN_WIDTH were fixed constants. Both now grow
    -- with the same scale (never shrink below their base size - text
    -- getting cut off is the only reported direction), so a bigger font
    -- gets a taller row and switches to 3 columns later (favouring fewer,
    -- wider columns instead of cramming a bigger font into the same
    -- column width).
    local fontScale = math.max(1, (SB.db.settings and SB.db.settings.mainFontScale) or 1)
    ROW_H = math.floor(32 * fontScale + 0.5)
    THREE_COLUMN_WIDTH = math.floor(600 * fontScale + 0.5)
    local columns = contentWidth >= THREE_COLUMN_WIDTH and 3 or 2
    -- Explicit report: the first (leftmost) column's icons were visibly
    -- clipped, the others weren't - column 0 sits flush at x=0 of
    -- scroll.content, exactly on the ScrollFrame's own hard clip edge, so
    -- anything that visually extends past its icon slot's nominal bounds
    -- there (the Favourite hover preview scales the icon to 130%, and the
    -- slot's own selection/ornament textures aren't perfectly inset either)
    -- gets hard-clipped. Every other column has ordinary row content as a
    -- buffer to its left instead of a clip boundary, so the same overflow
    -- there was never visible. A small left grid margin gives column 0 the
    -- same breathing room every other column already had.
    local entryW = math.floor((contentWidth - GRID_LEFT_PAD) / columns)
    local iconExtent = 24
    local hotkeyWidth = math.max(70, math.min(104, entryW * 0.28))

    usedEntries, usedHeaders = 0, 0
    local y = 0
    local sections = BuildSectionList()
    local totalShown = 0
    local anyRealSection = false

    for _, block in ipairs(sections) do
        if block.type == "filtered" then
            local ids = GetFilteredSoundList()
            totalShown = totalShown + #ids
            y = LayoutEntries(ids, #ids, y, columns, entryW, iconExtent, hotkeyWidth, false, nil)
        elseif block.type == "favourites" then
            anyRealSection = true
            usedHeaders = usedHeaders + 1
            local hdr = GetOrCreateHeader(usedHeaders)
            hdr:ClearAllPoints()
            hdr:SetPoint("TOPLEFT", scroll.content, "TOPLEFT", 0, -y)
            hdr:SetPoint("RIGHT", scroll.content, "RIGHT", 0, 0)
            -- "favourites" is a reserved internal key (see the header's own
            -- OnClick above) - never the visible "Favourites" label.
            local favCollapsed = SB.db.ui.categoryCollapsed["favourites"] and true or false
            local favCount = SB:GetFavouriteCount()
            ConfigureHeader(hdr, "favourites", "Favourites", SB.FAVOURITES_ICON, favCollapsed, favCount, true)
            y = y + SECTION_HEADER_H
            totalShown = totalShown + favCount
            if favCollapsed then
                favEmptyHint:Hide()
            else
                local ids, slots = BuildFavouritesEntries()
                if #ids == 0 then
                    -- Nothing occupied and no drag in progress
                    -- (BuildFavouritesEntries would otherwise include all 20
                    -- slots as drop targets) - a small inline hint instead of
                    -- an empty-looking gap, kept local to this section rather
                    -- than covering the whole Library (other sections are
                    -- still fully visible below it).
                    favEmptyHint:ClearAllPoints()
                    favEmptyHint:SetPoint("TOPLEFT", scroll.content, "TOPLEFT", 4, -y)
                    favEmptyHint:SetPoint("RIGHT", scroll.content, "RIGHT", -4, 0)
                    favEmptyHint:Show()
                    y = y + 20
                else
                    favEmptyHint:Hide()
                    y = LayoutEntries(ids, #ids, y, columns, entryW, iconExtent, hotkeyWidth, true, function(idx) return slots[idx] end)
                end
            end
            y = y + SECTION_GAP
        else
            anyRealSection = true
            local tab = block.tab
            local key = tab.key
            local name, icon = TabDisplayInfo(tab)
            local collapsed
            if tab.isHide then
                collapsed = not hideSectionExpanded
            else
                collapsed = SB.db.ui.categoryCollapsed[tostring(key)] and true or false
            end
            local list = GetTabSoundList(key)
            local n = #list
            totalShown = totalShown + n

            usedHeaders = usedHeaders + 1
            local hdr = GetOrCreateHeader(usedHeaders)
            hdr:ClearAllPoints()
            hdr:SetPoint("TOPLEFT", scroll.content, "TOPLEFT", 0, -y)
            hdr:SetPoint("RIGHT", scroll.content, "RIGHT", 0, 0)
            ConfigureHeader(hdr, key, name, icon, collapsed, n, false)
            y = y + SECTION_HEADER_H

            if not collapsed then
                y = LayoutEntries(list, n, y, columns, entryW, iconExtent, hotkeyWidth, false, nil)
                y = y + SECTION_GAP
            end
        end
    end

    for i = usedEntries + 1, #entryButtons do entryButtons[i]:Hide() end
    for i = usedHeaders + 1, #sectionHeaders do sectionHeaders[i]:Hide() end

    scroll.content:SetHeight(math.max(1, y))
    -- Re-clamp the current scroll offset against the freshly computed
    -- content height. WoW's ScrollFrame never does this on its own when
    -- the scrollchild shrinks (e.g. collapsing a section) - a viewport
    -- left scrolled past the new, shorter content shows nothing but blank
    -- space below the last real row, which looks identical to "the
    -- Library is empty."
    local viewportH = scroll.scroll:GetHeight() or 0
    local maxScroll = math.max(0, y - viewportH)
    local currentScroll = scroll.scroll:GetVerticalScroll() or 0
    if currentScroll > maxScroll then
        scroll.scroll:SetVerticalScroll(maxScroll)
    end
    scroll.UpdateThumb()

    -- Empty-state hint - explicit requirement: a clear (if brief) message
    -- when there is genuinely nothing to show at all, never a permanent
    -- fixture. An empty Favourites section gets its own small inline hint
    -- instead (see favEmptyHint above) since other sections are still
    -- visible below it - this one only covers "search/filter matched
    -- nothing" and the (practically unreachable) "no sections exist at
    -- all" case.
    if IsFiltering() then
        if totalShown == 0 then
            emptyHint:SetText("No sounds match your search.")
            emptyHint:Show()
            local searching, tagged = IsSearching(), HasActiveTagFilters()
            emptyHintClear.text:SetText(
                (searching and tagged) and "Clear Search & Filters"
                or tagged and "Clear Filters"
                or "Clear Search")
            emptyHintClear:Show()
        else
            emptyHint:Hide()
            emptyHintClear:Hide()
        end
    elseif not anyRealSection then
        emptyHint:SetText("No sounds available.")
        emptyHint:Show()
        emptyHintClear:Hide()
    else
        emptyHint:Hide()
        emptyHintClear:Hide()
    end

    if main.tagFilterUpdaters then
        for _, updateFn in ipairs(main.tagFilterUpdaters) do updateFn() end
    end
    SB:Debug("RefreshLibrary done: usedEntries=%d usedHeaders=%d totalShown=%d y=%d anyRealSection=%s",
        usedEntries, usedHeaders, totalShown, y, tostring(anyRealSection))
    if usedEntries > 0 then
        local b = entryButtons[1]
        -- GetLeft/GetTop can return zero Lua values (not nil) when the frame's
        -- position isn't resolvable yet; assigning to locals first normalizes
        -- that to nil so tostring() never receives zero arguments.
        local bShown, bAlpha, bLeft, bTop = b:IsShown(), b:GetAlpha(), b:GetLeft(), b:GetTop()
        local bW, bH = b:GetWidth(), b:GetHeight()
        local bName = b.nameText and b.nameText:GetText()
        local bStrata = b.GetFrameStrata and b:GetFrameStrata()
        local bLevel = b:GetFrameLevel()
        SB:Debug("btn1: shown=%s alpha=%s left=%s top=%s w=%s h=%s name=%q strata=%s level=%s",
            tostring(bShown), tostring(bAlpha), tostring(bLeft), tostring(bTop),
            tostring(bW), tostring(bH), tostring(bName),
            tostring(bStrata), tostring(bLevel))
    end
    if usedHeaders > 0 then
        local h = sectionHeaders[1]
        local hShown, hAlpha, hLeft, hTop = h:IsShown(), h:GetAlpha(), h:GetLeft(), h:GetTop()
        local hW = h:GetWidth()
        local hTitle = h.title and h.title:GetText()
        SB:Debug("hdr1: shown=%s alpha=%s left=%s top=%s w=%s title=%q",
            tostring(hShown), tostring(hAlpha), tostring(hLeft), tostring(hTop),
            tostring(hW), tostring(hTitle))
    end
    local scrShown, scrAlpha = scroll.scroll:IsShown(), scroll.scroll:GetAlpha()
    local cShown, cAlpha, cLeft, cTop = scroll.content:IsShown(), scroll.content:GetAlpha(), scroll.content:GetLeft(), scroll.content:GetTop()
    local mAlpha, mShown = main:GetAlpha(), main:IsShown()
    SB:Debug("scroll: shown=%s alpha=%s content.shown=%s content.alpha=%s content.left=%s content.top=%s main.alpha=%s main.shown=%s",
        tostring(scrShown), tostring(scrAlpha),
        tostring(cShown), tostring(cAlpha),
        tostring(cLeft), tostring(cTop),
        tostring(mAlpha), tostring(mShown))
end

-- WoW hides Lua errors from players by default (Interface Options ->
-- "Display Lua Errors" is off unless the player opts in via
-- /console scriptErrors 1), which would otherwise make a genuine runtime
-- error in the Library's own render pass look identical to "there's
-- nothing to show" - an empty book with no obvious explanation. Report it
-- to chat directly instead of relying on that setting.
RefreshLibrary = function()
    local ok, err = pcall(RefreshLibraryImpl)
    if not ok then
        SB:Print("|cffff5555Library refresh error:|r " .. tostring(err))
    end
end

------------------------------------------------------------------------
-- Output Rail - ALL / G / P-R / F / NO (3.0 spec section 20). Sets the
-- global Default Output Channel (Communication.lua's
-- SB.db.settings.defaultOutputTarget) directly. Guild/Party-Raid/Friends
-- also open a hover flyout offering the whole group or an individual
-- recipient subset (SB.db.ui.outputRail, fanned out through the existing
-- Direct/whisper transport - see Communication.lua's SB:DispatchDefaultOutput
-- SUBSET branch, never a new wire command).
------------------------------------------------------------------------

-- Explicit request: the Rail should use the same semantic channel colours
-- as everywhere else in the addon (Announcer sender line, SendMenu, ...) -
-- reusing SB.CHANNEL_COLOR (Core.lua) rather than inventing a second set.
local OUTPUT_RAIL_ENTRIES = {
    { label = "ALL", value = "ALL", tooltip = "All currently enabled broadcast channels.",
      color = { 0.92, 0.94, 1.0 } },
    { label = "G", value = "GUILD", tooltip = "Guild only.", bucket = "GUILD", groupLabel = "Guild",
      color = { SB.CHANNEL_COLOR.GUILD.r, SB.CHANNEL_COLOR.GUILD.g, SB.CHANNEL_COLOR.GUILD.b } },
    { label = "P/R", value = "RAID", tooltip = "Party or Raid, whichever you're currently in.", bucket = "RAID",
      color = { SB.CHANNEL_COLOR.RAID.r, SB.CHANNEL_COLOR.RAID.g, SB.CHANNEL_COLOR.RAID.b } },
    { label = "F", value = "FRIENDS", tooltip = "Friends only.", bucket = "FRIENDS", groupLabel = "Friends",
      color = { SB.CHANNEL_COLOR.FRIENDS.r, SB.CHANNEL_COLOR.FRIENDS.g, SB.CHANNEL_COLOR.FRIENDS.b } },
    { label = "NO", value = "SELF", tooltip = "Local playback only - nothing is sent.",
      color = { SB.CHANNEL_COLOR.SELF.r, SB.CHANNEL_COLOR.SELF.g, SB.CHANNEL_COLOR.SELF.b } },
}

local function IsRailBucketAvailable(bucket)
    if bucket == "GUILD" then return IsInGuild() and true or false end
    if bucket == "RAID" then return (IsInGroup() or IsInRaid()) and true or false end
    if bucket == "FRIENDS" then
        local reachable = SB.ComputeReachablePlayers and SB.ComputeReachablePlayers()
        return reachable and #reachable.FRIENDS > 0
    end
    return true
end

local function RailGroupLabel(entry)
    if entry.bucket == "RAID" then
        return IsInRaid() and "Raid" or (IsInGroup() and "Party" or "Raid/Party")
    end
    return entry.groupLabel
end

local function RefreshOutputRail()
    local current = SB.db.settings.defaultOutputTarget or "ALL"
    local subsetMode = current == "SUBSET" and SB.db.ui.outputRail and SB.db.ui.outputRail.mode
    local subsetCount = subsetMode and #(SB.db.ui.outputRail.recipients or {}) or 0
    for _, btn in ipairs(outputRailButtons) do
        local entry = btn.railEntry
        local selected = btn.railValue == current
            or (btn.railValue == "RAID" and current == "PARTY")
            or (subsetMode and btn.railValue == subsetMode)
        -- Explicit report: the active channel "geht voll unter" (gets
        -- totally lost) - a border-colour-only change wasn't enough.
        -- Selected now fills the tile with the channel's own colour, not
        -- just its edge, so it's obvious at a glance which one is active.
        if selected then
            local c = entry.color
            btn:SetBackdropColor(c[1] * 0.32, c[2] * 0.32, c[3] * 0.32, 0.95)
            btn:SetBackdropBorderColor(c[1], c[2], c[3], 1)
            btn.label:SetTextColor(1, 1, 1)
            btn.accent:SetVertexColor(c[1], c[2], c[3], 1)
        else
            btn:SetBackdropColor(0.015, 0.04, 0.09, 0.85)
            btn:SetBackdropBorderColor(unpack(SB.Theme.BORDER_DIM))
            btn.label:SetTextColor(unpack(SB.Theme.TEXT_DIM))
            btn.accent:SetVertexColor(entry.color[1], entry.color[2], entry.color[3], 0.85)
        end
        local baseLabel = entry.label
        if btn.railValue == "RAID" then
            baseLabel = IsInRaid() and "R" or (IsInGroup() and "P" or "P/R")
        end
        if subsetMode and btn.railValue == subsetMode and subsetCount > 0 then
            -- Plain ASCII, not a Unicode middle dot - see this file's other
            -- glyph-safety comments (WoW's bundled fonts don't reliably
            -- cover every codepoint).
            baseLabel = baseLabel .. ":" .. subsetCount
        end
        btn.label:SetText(baseLabel)

        if entry.bucket then
            local available = IsRailBucketAvailable(entry.bucket)
            btn:SetAlpha(available and 1 or 0.45)
        end
    end
end

------------------------------------------------------------------------
-- Output flyout - Guild/Party-Raid/Friends' hover popup (3.0 spec section
-- 22). One shared floating panel, repopulated per hover target, same
-- "stay open while the mouse crosses onto it" pattern Theme.CreateDropdown
-- already uses for its own list.
------------------------------------------------------------------------

local outputFlyout
local outputFlyoutOpenTimer, outputFlyoutCloseTimer

local function ScheduleFlyoutClose()
    if outputFlyoutCloseTimer then outputFlyoutCloseTimer:Cancel() end
    outputFlyoutCloseTimer = C_Timer.NewTimer(0.15, function()
        outputFlyoutCloseTimer = nil
        if outputFlyout and not outputFlyout:IsMouseOver() then outputFlyout:Hide() end
    end)
end

local function BuildOutputFlyout()
    if outputFlyout then return outputFlyout end
    local f = SB.CreateFrame("Frame", nil, UIParent)
    f:SetFrameStrata("TOOLTIP")
    f:SetWidth(190)
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    f:SetBackdropColor(unpack(SB.Theme.BG_RAISED))
    f:SetBackdropBorderColor(SB.Theme.GOLD_DIM[1], SB.Theme.GOLD_DIM[2], SB.Theme.GOLD_DIM[3], 0.8)
    f:EnableMouse(true)
    f:Hide()
    f:SetScript("OnEnter", function()
        if outputFlyoutCloseTimer then outputFlyoutCloseTimer:Cancel(); outputFlyoutCloseTimer = nil end
    end)
    f:SetScript("OnLeave", ScheduleFlyoutClose)

    f.title = f:CreateFontString(nil, "OVERLAY")
    f.title:SetFontObject(SB.Fonts.Highlight)
    f.title:SetPoint("TOPLEFT", 10, -8)
    f.title:SetTextColor(unpack(SB.Theme.GOLD))

    -- Explicit request: the Rail's own hover tooltip and this flyout used
    -- to appear one after another (tooltip first, flyout second) -
    -- "störung", a two-step reveal instead of one clean hover. Bucketed
    -- Rail entries (Guild/Party-Raid/Friends) now skip the native tooltip
    -- entirely and show its explanation here instead, so hovering produces
    -- exactly one popup.
    f.subtitle = f:CreateFontString(nil, "OVERLAY")
    f.subtitle:SetFontObject(SB.Fonts.DisableSmall)
    f.subtitle:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -2)
    f.subtitle:SetPoint("RIGHT", -10, 0)
    f.subtitle:SetJustifyH("LEFT")
    f.subtitle:SetWordWrap(true)
    f.subtitle:SetTextColor(unpack(SB.Theme.TEXT_DIM))

    f.unavailableText = f:CreateFontString(nil, "OVERLAY")
    f.unavailableText:SetFontObject(SB.Fonts.DisableSmall)
    f.unavailableText:SetJustifyH("LEFT")
    f.unavailableText:SetWordWrap(true)
    f.unavailableText:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    f.unavailableText:Hide()

    f.allRow = CreateFrame("Button", nil, f)
    f.allRow:SetHeight(20)
    local hl = f.allRow:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(SB.Theme.ACCENT[1], SB.Theme.ACCENT[2], SB.Theme.ACCENT[3], 0.15)
    f.allRow.text = f.allRow:CreateFontString(nil, "OVERLAY")
    f.allRow.text:SetFontObject(SB.Fonts.HighlightSmall)
    f.allRow.text:SetPoint("LEFT", 10, 0)
    f.allRow:Hide()

    f.rows = {}
    outputFlyout = f
    return f
end

local function GetOrCreateFlyoutRow(f, index)
    if f.rows[index] then return f.rows[index] end
    local row = CreateFrame("Button", nil, f)
    row:SetHeight(20)
    local check = SB.Theme.CreateToggleTile(row, 14)
    check:SetPoint("LEFT", 8, 0)
    row.check = check
    local text = row:CreateFontString(nil, "OVERLAY")
    text:SetFontObject(SB.Fonts.HighlightSmall)
    text:SetPoint("LEFT", check, "RIGHT", 6, 0)
    row.text = text
    f.rows[index] = row
    return row
end

-- `bucketKey` is one of SB.ComputeReachablePlayers' own keys (GUILD/RAID/
-- FRIENDS). Toggling an individual player builds a SUBSET target (3.0 spec
-- section 23) - fanned out through the existing Direct transport by
-- Communication.lua's SB:DispatchDefaultOutput, never a new wire command.
local function PopulateOutputFlyout(bucketKey, groupLabel, description)
    local f = BuildOutputFlyout()
    f.title:SetText(groupLabel)
    f.subtitle:SetText(description or "")
    f.subtitle:SetShown(description ~= nil and description ~= "")

    local reachable = SB.ComputeReachablePlayers and SB.ComputeReachablePlayers()
    local names = (reachable and reachable[bucketKey]) or {}
    -- Extra headroom when the subtitle is showing - its own height varies
    -- with wrapping, so read it back after SetText/Show rather than
    -- guessing a fixed offset.
    local y = -28 - (description and description ~= "" and ((f.subtitle:GetHeight() or 0) + 4) or 0)

    if #names == 0 then
        f.allRow:Hide()
        for _, row in ipairs(f.rows) do row:Hide() end
        local reason
        if bucketKey == "GUILD" then reason = "Not currently in a guild"
        elseif bucketKey == "RAID" then reason = "Not currently in a party or raid"
        else reason = "No online Soundbook friends detected" end
        f.unavailableText:ClearAllPoints()
        f.unavailableText:SetPoint("TOPLEFT", 10, y)
        f.unavailableText:SetPoint("RIGHT", -10, 0)
        f.unavailableText:SetText(reason)
        f.unavailableText:Show()
        y = y - 32
    else
        f.unavailableText:Hide()
        f.allRow:ClearAllPoints()
        f.allRow:SetPoint("TOPLEFT", 0, y)
        f.allRow:SetPoint("RIGHT", 0, 0)
        f.allRow.text:SetText(string.format("All %s (%d)", groupLabel, #names))
        f.allRow:SetScript("OnClick", function()
            SB.db.settings.defaultOutputTarget = bucketKey
            wipe(SB.db.ui.outputRail.recipients)
            SB.db.ui.outputRail.mode = bucketKey
            RefreshOutputRail()
            outputFlyout:Hide()
        end)
        f.allRow:Show()
        y = y - 22

        local subset = SB.db.ui.outputRail.recipients
        for i, name in ipairs(names) do
            local row = GetOrCreateFlyoutRow(f, i)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 0, y)
            row:SetPoint("RIGHT", 0, 0)
            row.text:SetText(SB.GetPlayerDisplayName and SB.GetPlayerDisplayName(name) or name)
            local key = SB.PlayerKey and SB.PlayerKey(name)
            local checked = false
            for _, n in ipairs(subset) do
                if key and SB.PlayerKey and SB.PlayerKey(n) == key then checked = true break end
            end
            row.check:SetChecked(checked)
            row.check:SetScript("OnClick", function(self)
                local list = SB.db.ui.outputRail.recipients
                for idx = #list, 1, -1 do
                    if key and SB.PlayerKey and SB.PlayerKey(list[idx]) == key then table.remove(list, idx) end
                end
                if self:GetChecked() then table.insert(list, name) end
                if #list > 0 then
                    SB.db.settings.defaultOutputTarget = "SUBSET"
                    SB.db.ui.outputRail.mode = bucketKey
                else
                    SB.db.settings.defaultOutputTarget = bucketKey
                end
                RefreshOutputRail()
            end)
            row:Show()
            y = y - 22
        end
        for i = #names + 1, #f.rows do f.rows[i]:Hide() end
    end

    f:SetHeight(math.abs(y) + 10)
end

local function BuildOutputRail(parent)
    local rail = SB.CreateFrame("Frame", nil, parent)
    rail:SetWidth(40)
    for i, entry in ipairs(OUTPUT_RAIL_ENTRIES) do
        local btn = SB.CreateFrame("Button", nil, rail)
        btn:SetSize(36, 34)
        btn:SetPoint("TOP", rail, "TOP", 0, -(i - 1) * 38)
        btn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        btn:SetBackdropColor(0.015, 0.04, 0.09, 0.85)
        btn:SetBackdropBorderColor(unpack(SB.Theme.BORDER_DIM))
        btn.railValue = entry.value
        btn.railEntry = entry

        -- Always-visible channel accent (explicit request: known colour
        -- coding - green Guild, blue Friends, orange Party/Raid, white
        -- All, grey Self) - a left-edge strip rather than tinting the
        -- whole tile, so it reads as a colour CODE, not a saturated block.
        local accent = btn:CreateTexture(nil, "ARTWORK")
        accent:SetPoint("TOPLEFT", 1, -1)
        accent:SetPoint("BOTTOMLEFT", 1, 1)
        accent:SetWidth(3)
        accent:SetTexture("Interface\\Buttons\\WHITE8X8")
        accent:SetVertexColor(entry.color[1], entry.color[2], entry.color[3], 0.85)
        btn.accent = accent

        local label = btn:CreateFontString(nil, "OVERLAY")
        label:SetFontObject(SB.Fonts.HighlightSmall)
        label:SetPoint("CENTER")
        label:SetText(entry.label)
        btn.label = label

        btn:SetScript("OnClick", function()
            SB.db.settings.defaultOutputTarget = entry.value
            if entry.bucket then
                wipe(SB.db.ui.outputRail.recipients)
                SB.db.ui.outputRail.mode = entry.bucket
            end
            RefreshOutputRail()
        end)
        btn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(0.04, 0.10, 0.20, 0.92)
            -- Explicit request: the Rail's own hover tooltip and the
            -- flyout used to appear one after another ("störung") - a
            -- bucketed entry (Guild/Party-Raid/Friends) now skips the
            -- native tooltip entirely, since its explanation lives in the
            -- flyout's own subtitle instead (PopulateOutputFlyout below).
            -- Only ALL/Self, which have no flyout, still use a plain
            -- tooltip.
            if not entry.bucket then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(entry.label, 1, 1, 1)
                GameTooltip:AddLine(entry.tooltip, 0.8, 0.85, 0.95, true)
                GameTooltip:Show()
            end

            if entry.bucket then
                if outputFlyoutCloseTimer then outputFlyoutCloseTimer:Cancel(); outputFlyoutCloseTimer = nil end
                if outputFlyoutOpenTimer then outputFlyoutOpenTimer:Cancel() end
                outputFlyoutOpenTimer = C_Timer.NewTimer(0.12, function()
                    outputFlyoutOpenTimer = nil
                    local label = entry.label == "P/R" and "Party/Raid" or entry.label
                    local description = entry.tooltip
                    if not IsRailBucketAvailable(entry.bucket) then
                        local reason
                        if entry.bucket == "GUILD" then reason = "Not currently in a guild"
                        elseif entry.bucket == "RAID" then reason = "Not currently in a party or raid"
                        else reason = "No online Soundbook friends detected" end
                        description = reason
                    end
                    PopulateOutputFlyout(entry.bucket, RailGroupLabel(entry), description)
                    outputFlyout:ClearAllPoints()
                    outputFlyout:SetPoint("TOPLEFT", self, "TOPRIGHT", 4, 0)
                    outputFlyout:Show()
                end)
            end
        end)
        btn:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
            RefreshOutputRail()
            if outputFlyoutOpenTimer then outputFlyoutOpenTimer:Cancel(); outputFlyoutOpenTimer = nil end
            if entry.bucket then ScheduleFlyoutClose() end
        end)

        outputRailButtons[i] = btn
    end
    return rail
end

------------------------------------------------------------------------
-- Tag filter pills - unchanged content/logic from the pre-3.0 book, just
-- built inside the new toolbar area.
------------------------------------------------------------------------

local function BuildTagFilterBar(parent)
    local tagFilterBar = SB.CreateFrame("Frame", nil, parent)
    tagFilterBar:SetHeight(20)
    main.tagFilterBar = tagFilterBar
    main.tagFilterUpdaters = {}

    local FILTER_PILL_H, FILTER_PILL_CAP_W, FILTER_PILL_GAP = 20, 8, 6
    local filterPills = {}
    for _, tagKey in ipairs(TAG_FILTER_ORDER) do
        local style = TAG_STYLE[tagKey]
        local pill = SB.CreateFrame("Button", nil, tagFilterBar)
        pill:SetHeight(FILTER_PILL_H)
        pill:SetPoint("LEFT", tagFilterBar, "LEFT", 0, 0)
        table.insert(filterPills, pill)

        local leftCap = pill:CreateTexture(nil, "ARTWORK")
        leftCap:SetSize(FILTER_PILL_CAP_W, FILTER_PILL_H)
        leftCap:SetPoint("LEFT", pill, "LEFT", 0, 0)
        leftCap:SetTexture("Interface\\AddOns\\Soundbook\\Assets\\TagCap")

        local rightCap = pill:CreateTexture(nil, "ARTWORK")
        rightCap:SetSize(FILTER_PILL_CAP_W, FILTER_PILL_H)
        rightCap:SetPoint("RIGHT", pill, "RIGHT", 0, 0)
        rightCap:SetTexture("Interface\\AddOns\\Soundbook\\Assets\\TagCap")
        rightCap:SetTexCoord(1, 0, 0, 1)

        local middle = pill:CreateTexture(nil, "ARTWORK")
        middle:SetPoint("TOPLEFT", leftCap, "TOPRIGHT", 0, 0)
        middle:SetPoint("BOTTOMRIGHT", rightCap, "BOTTOMLEFT", 0, 0)
        middle:SetTexture("Interface\\Buttons\\WHITE8X8")

        local text = pill:CreateFontString(nil, "OVERLAY")
        text:SetFontObject(SB.Fonts.DisableSmall)
        text:SetPoint("CENTER")
        text:SetText(style.label)

        pill:SetWidth(FILTER_PILL_CAP_W * 2 + text:GetStringWidth() + 10)

        local function UpdatePillVisual()
            pill:SetShown(GetVisibleTagSet()[tagKey] and true or false)
            local active = SB.db.ui.tagFilters[tagKey] and true or false
            local a = active and 0.92 or 0.20
            leftCap:SetVertexColor(style.bg[1], style.bg[2], style.bg[3], a)
            rightCap:SetVertexColor(style.bg[1], style.bg[2], style.bg[3], a)
            middle:SetVertexColor(style.bg[1], style.bg[2], style.bg[3], a)
            text:SetTextColor(style.text[1], style.text[2], style.text[3], active and 1 or 0.6)
        end
        UpdatePillVisual()
        table.insert(main.tagFilterUpdaters, UpdatePillVisual)

        pill:SetScript("OnClick", function()
            if SB.db.ui.tagFilters[tagKey] then
                SB.db.ui.tagFilters[tagKey] = nil
            else
                SB.db.ui.tagFilters[tagKey] = true
            end
            UpdatePillVisual()
            RefreshLibrary()
        end)

        pill:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(style.label, style.text[1], style.text[2], style.text[3])
            GameTooltip:AddLine(style.desc, style.text[1], style.text[2], style.text[3], true)
            GameTooltip:Show()
        end)
        pill:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local function RecenterFilterPills()
        local totalW, visibleCount = 0, 0
        for _, pill in ipairs(filterPills) do
            if pill:IsShown() then
                visibleCount = visibleCount + 1
                totalW = totalW + pill:GetWidth()
            end
        end
        if visibleCount > 1 then totalW = totalW + (visibleCount - 1) * FILTER_PILL_GAP end
        local barW = tagFilterBar:GetWidth() or 0
        local x = math.max(0, (barW - totalW) / 2)
        for _, pill in ipairs(filterPills) do
            if pill:IsShown() then
                pill:ClearAllPoints()
                pill:SetPoint("LEFT", tagFilterBar, "LEFT", x, 0)
                x = x + pill:GetWidth() + FILTER_PILL_GAP
            end
        end
    end
    RecenterFilterPills()
    tagFilterBar:SetScript("OnSizeChanged", RecenterFilterPills)
    table.insert(main.tagFilterUpdaters, RecenterFilterPills)

    return tagFilterBar
end

------------------------------------------------------------------------
-- Raid Admin toolbar button - only visible to the current Raid Leader/
-- Assist or Party Leader (AdminPanel.lua). Replaces the old right-side
-- Admin tab.
------------------------------------------------------------------------

local function ToggleAdmin()
    isAdminOpen = not isAdminOpen
    if isAdminOpen then
        isSettingsOpen = false
        ClearFiltering()
    end
    SB:RefreshMainWindow()
end

function SB:RefreshAdminTabVisibility()
    if not adminToolbarBtn then return end
    local adminVisible = SB:IsRaidAdmin()
    if adminVisible then
        adminToolbarBtn:Show()
    else
        adminToolbarBtn:Hide()
        if isAdminOpen then
            isAdminOpen = false
            SB:RefreshMainWindow()
        end
    end
end

------------------------------------------------------------------------
-- Frame construction
------------------------------------------------------------------------

local function SavePosition()
    local point, _, relPoint, x, y = main:GetPoint(1)
    SB.db.ui.mainPos = { point = point, relPoint = relPoint, x = x, y = y }
end

local function SaveSize()
    SB.db.ui.mainWidth = main:GetWidth()
    SB.db.ui.mainHeight = main:GetHeight()
end

local function RestorePosition()
    local pos = SB.db.ui.mainPos or { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 }
    main:ClearAllPoints()
    main:SetPoint(pos.point, UIParent, pos.relPoint, pos.x, pos.y)
end

local function RefreshLockVisual()
    if not lockToolbarBtn then return end
    lockToolbarBtn:SetLocked(SB.db.ui.layoutLocked and true or false)
end

local function BuildMainFrame()
    main = SB.CreateFrame("Frame", "SoundbookMainFrame", UIParent)
    -- Explicit request: default size (used only when nothing's saved yet)
    -- matches the window's own minimum resizable bounds - 560x560 - not a
    -- larger fixed starting size.
    local initialW = math.max(560, math.min(720, tonumber(SB.db.ui.mainWidth) or 560))
    local initialH = math.max(560, math.min(760, tonumber(SB.db.ui.mainHeight) or 560))
    main:SetSize(initialW, initialH)
    main:SetFrameStrata("HIGH")
    main:SetClampedToScreen(true)
    main:SetMovable(true)
    main:SetResizable(true)
    if main.SetResizeBounds then
        main:SetResizeBounds(560, 560, 720, 760)
    elseif main.SetMinResize then
        main:SetMinResize(560, 560)
        main:SetMaxResize(720, 760)
    end
    main:EnableMouse(true)
    main:RegisterForDrag("LeftButton")
    main:SetScript("OnDragStart", function()
        if SB.db.ui.layoutLocked then return end
        main:StartMoving()
    end)
    main:SetScript("OnDragStop", function()
        main:StopMovingOrSizing()
        SavePosition()
    end)
    SB.Theme.Panel(main)
    main:Hide()

    tinsert(UISpecialFrames, "SoundbookMainFrame")

    ------------------------------------------------------------------
    -- Toolbar: Settings / Raid Admin / Lock / Search / Close (3.0 spec
    -- section 16) - replaces the old tall crest header + right-side tab
    -- dock. A slim gold-bordered strip instead of a large ornamental
    -- banner (spec section 2's own "avoid" list).
    ------------------------------------------------------------------
    local toolbar = SB.CreateFrame("Frame", nil, main)
    toolbar:SetPoint("TOPLEFT", 8, -8)
    toolbar:SetPoint("TOPRIGHT", -8, -8)
    toolbar:SetHeight(34) -- grown from 30 to fit the enlarged 26px toolbar controls
    main.toolbar = toolbar

    local toolbarLine = toolbar:CreateTexture(nil, "ARTWORK")
    toolbarLine:SetPoint("BOTTOMLEFT", 0, -2)
    toolbarLine:SetPoint("BOTTOMRIGHT", 0, -2)
    toolbarLine:SetHeight(1)
    toolbarLine:SetTexture("Interface\\Buttons\\WHITE8X8")
    toolbarLine:SetVertexColor(unpack(SB.Theme.GOLD))

    local closeBtn = SB.Theme.CreateCloseGlyph(toolbar, 22)
    closeBtn:SetPoint("RIGHT", 0, 0)
    closeBtn:SetScript("OnClick", function() main:Hide() end)

    local function ToggleSettings()
        isSettingsOpen = not isSettingsOpen
        if isSettingsOpen then
            isAdminOpen = false
            ClearFiltering()
        end
        SB:RefreshMainWindow()
    end

    -- "Audio" quick-access - reuses the Announcer's own Quick Options menu
    -- (mute incoming / lock / muted players / open Soundbook / Announcer
    -- size), so there is exactly one such menu in the whole addon rather
    -- than two diverging copies. Explicit request: flush at the toolbar's
    -- own left edge (matching Settings' own left-edge placement below),
    -- and a bit bigger like the search field next to it.
    local audioBtn = SB.Theme.CreateMiniControlButton(toolbar, 26)
    audioBtn:SetPoint("LEFT", 0, 0)
    local audioIcon = audioBtn:CreateTexture(nil, "ARTWORK")
    audioIcon:SetPoint("TOPLEFT", 2, -2)
    audioIcon:SetPoint("BOTTOMRIGHT", -2, 2)
    audioIcon:SetTexture("Interface\\Icons\\INV_Misc_Bell_01")
    audioIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    audioBtn:SetScript("OnClick", function(self)
        if SB.ShowAnnouncerQuickOptions then SB.ShowAnnouncerQuickOptions(self) end
    end)
    SB.Theme.AttachTooltip(audioBtn, "Quick Audio", "Mute incoming, lock the interface, or manage muted players.")

    local adminBtn = SB.Theme.CreateMiniControlButton(toolbar, 26)
    adminBtn:SetPoint("LEFT", audioBtn, "RIGHT", 4, 0)
    local adminIcon = adminBtn:CreateTexture(nil, "ARTWORK")
    adminIcon:SetPoint("TOPLEFT", 2, -2)
    adminIcon:SetPoint("BOTTOMRIGHT", -2, 2)
    adminIcon:SetTexture(SB.ADMIN_ICON)
    adminIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    adminBtn:SetScript("OnClick", ToggleAdmin)
    SB.Theme.AttachTooltip(adminBtn, "Raid Admin", "Temporarily mute sending/receiving for the raid or party.")
    adminBtn:Hide()
    adminToolbarBtn = adminBtn

    -- Explicit request: Lock stays on the right, between the search field
    -- and the close button.
    lockToolbarBtn = SB.Theme.CreateLockGlyph(toolbar, 26)
    lockToolbarBtn:SetPoint("RIGHT", closeBtn, "LEFT", -4, 0)
    lockToolbarBtn:SetScript("OnClick", function()
        SB.db.ui.layoutLocked = not SB.db.ui.layoutLocked
        RefreshLockVisual()
    end)
    SB.Theme.AttachTooltip(lockToolbarBtn, "Lock Interface", "Prevent moving/resizing the Main Soundbook and the Announcer.")

    -- Explicit request: a bit bigger, matching the toolbar icons' own
    -- size bump.
    searchBox = SB.Theme.CreateInputBox(toolbar, 100, 26)
    searchBox:SetPoint("LEFT", adminBtn, "RIGHT", 8, 0)
    searchBox:SetPoint("RIGHT", lockToolbarBtn, "LEFT", -8, 0)
    searchBox:SetMaxLetters(50)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    searchBox:SetScript("OnTextChanged", function(self)
        searchPlaceholder:SetShown(self:GetText() == "")
        RefreshLibrary()
    end)
    main.searchBox = searchBox

    searchPlaceholder = searchBox:CreateFontString(nil, "OVERLAY")
    searchPlaceholder:SetFontObject(SB.Fonts.DisableSmall)
    searchPlaceholder:SetPoint("LEFT", 4, 0)
    searchPlaceholder:SetText("Find a sound...")

    ------------------------------------------------------------------
    -- Tag filter row, directly under the toolbar.
    ------------------------------------------------------------------
    local tagFilterBar = BuildTagFilterBar(main)
    tagFilterBar:SetPoint("TOPLEFT", toolbar, "BOTTOMLEFT", 0, -6)
    tagFilterBar:SetPoint("RIGHT", main, "RIGHT", -8, 0)

    ------------------------------------------------------------------
    -- Output Rail (left) + scrolling Library content (right).
    ------------------------------------------------------------------
    local outputRail = BuildOutputRail(main)
    outputRail:SetPoint("TOPLEFT", tagFilterBar, "BOTTOMLEFT", 0, -8)
    outputRail:SetPoint("BOTTOM", main, "BOTTOM", 0, 10)
    main.outputRail = outputRail

    -- Settings - explicit request: bottom-left, sized to match the Output
    -- Rail's own buttons (36x34) rather than the small 22px toolbar glyphs,
    -- and bottom-aligned with that same rail so it reads as belonging to
    -- the same column, at the very bottom of it.
    local settingsBtn = SB.Theme.CreateMiniControlButton(main, 36)
    settingsBtn:SetHeight(34)
    settingsBtn:SetPoint("BOTTOM", outputRail, "BOTTOM", 0, 0)
    local settingsIcon = settingsBtn:CreateTexture(nil, "ARTWORK")
    settingsIcon:SetPoint("TOPLEFT", 4, -4)
    settingsIcon:SetPoint("BOTTOMRIGHT", -4, 4)
    settingsIcon:SetTexture(SB.SETTINGS_ICON)
    settingsIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    settingsBtn:SetScript("OnClick", ToggleSettings)
    SB.Theme.AttachTooltip(settingsBtn, "Settings")
    main.settingsBtn = settingsBtn

    local libraryScroll = SB.Theme.CreateScrollFrame(main)
    libraryScroll.scroll:SetPoint("TOPLEFT", outputRail, "TOPRIGHT", 8, 0)
    libraryScroll.scroll:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -10, 10)
    -- Theme.CreateScrollFrame never sets its own content child's width -
    -- every other caller in this addon does that itself. A ScrollFrame's
    -- scroll child must get that width via SetWidth (done in
    -- RefreshLibrary, which recomputes it every layout pass), never via a
    -- second RIGHT-edge anchor point - see the comment above
    -- scroll.content:SetWidth in RefreshLibrary for why a second anchor
    -- breaks as soon as the frame is actually scrolled.
    libraryScroll.content:SetPoint("TOPLEFT", 0, 0)
    libraryScroll.content:SetWidth(1)
    main.libraryScroll = libraryScroll

    -- Settings/Admin panels render into the same content region as the
    -- Library, swapped in over it (unchanged from the pre-3.0 book).
    local content = SB.CreateFrame("Frame", nil, main)
    content:SetAllPoints(libraryScroll.scroll)
    main.content = content

    emptyHint = libraryScroll.scroll:CreateFontString(nil, "OVERLAY")
    emptyHint:SetFontObject(SB.Fonts.HighlightSmall)
    emptyHint:SetPoint("CENTER", libraryScroll.scroll, "CENTER", 0, 0)
    emptyHint:SetWidth(260)
    emptyHint:SetJustifyH("CENTER")
    emptyHint:SetWordWrap(true)
    emptyHint:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    emptyHint:SetSpacing(3)
    emptyHint:Hide()

    -- "Clear Search"/"Clear Filters" - explicit requirement: a zero-result
    -- search/filter state must offer a way out without having to find the
    -- search box or tag pills again by hand.
    emptyHintClear = SB.CreateFrame("Button", nil, libraryScroll.scroll)
    emptyHintClear:SetPoint("TOP", emptyHint, "BOTTOM", 0, -8)
    emptyHintClear:SetSize(140, 20)
    local clearText = emptyHintClear:CreateFontString(nil, "OVERLAY")
    clearText:SetFontObject(SB.Fonts.HighlightSmall)
    clearText:SetAllPoints()
    clearText:SetJustifyH("CENTER")
    clearText:SetTextColor(unpack(SB.Theme.V3.ARCANE_CYAN))
    emptyHintClear.text = clearText
    emptyHintClear:SetScript("OnEnter", function() clearText:SetTextColor(unpack(SB.Theme.TEXT)) end)
    emptyHintClear:SetScript("OnLeave", function() clearText:SetTextColor(unpack(SB.Theme.V3.ARCANE_CYAN)) end)
    emptyHintClear:SetScript("OnClick", function()
        ClearFiltering()
        RefreshLibrary()
    end)
    emptyHintClear:Hide()

    favEmptyHint = libraryScroll.content:CreateFontString(nil, "OVERLAY")
    favEmptyHint:SetFontObject(SB.Fonts.DisableSmall)
    favEmptyHint:SetJustifyH("LEFT")
    favEmptyHint:SetText("No Favourites yet - Shift+Left-Click any sound to add it here.")
    favEmptyHint:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    favEmptyHint:Hide()

    -- Explicit report: too small/hard to actually click on. Bigger hit
    -- box, and the grabber texture itself is enlarged and inset from that
    -- box (rather than filling it) so it also reads as more prominent,
    -- not just a bigger empty click zone around the same tiny glyph.
    local resizeGrip = SB.CreateFrame("Button", nil, main)
    resizeGrip:SetSize(34, 34)
    resizeGrip:SetPoint("BOTTOMRIGHT", -6, 6)
    resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeGrip:GetNormalTexture():SetAllPoints()
    resizeGrip:GetHighlightTexture():SetAllPoints()
    resizeGrip:GetPushedTexture():SetAllPoints()
    resizeGrip:SetScript("OnMouseDown", function()
        if SB.db.ui.layoutLocked then return end
        main:StartSizing("BOTTOMRIGHT")
    end)
    resizeGrip:SetScript("OnMouseUp", function()
        main:StopMovingOrSizing()
        SaveSize()
        if main.layoutRefreshTimer then
            main.layoutRefreshTimer:Cancel()
            main.layoutRefreshTimer = nil
        end
        RefreshLibrary()
        if settingsPanel and settingsPanel:IsShown() and SB.FitSettingsPanelHeight then SB:FitSettingsPanelHeight() end
    end)
    main.resizeGrip = resizeGrip
    main:SetScript("OnSizeChanged", function()
        if not main.content then return end
        if main.layoutRefreshTimer then main.layoutRefreshTimer:Cancel() end
        main.layoutRefreshTimer = C_Timer.NewTimer(0.05, function()
            main.layoutRefreshTimer = nil
            RefreshLibrary()
            if settingsPanel and settingsPanel:IsShown() and SB.FitSettingsPanelHeight then
                SB:FitSettingsPanelHeight()
            end
        end)
    end)

    -- Guards against a saved "collapsed" state key from an earlier session
    -- for a category that's since gone away (Soundbook_Private removed,
    -- etc.) - harmless (BuildSectionList simply never lists it), left as-is.

    settingsPanel = SB.BuildSettingsPanel(main, content)
    settingsPanel:Hide()
    adminPanel = SB.BuildAdminPanel(main, content)
    adminPanel:Hide()
    SB:RefreshAdminTabVisibility()
    RefreshLockVisual()

    RestorePosition()
    return main
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

-- The single place that decides what's visible for the current
-- isSettingsOpen/isAdminOpen state - called from every path that can
-- change either, so Library/Settings/Admin visibility can never drift out
-- of sync. Settings and Admin are mutually exclusive - each toggle already
-- closes the other one itself, at the moment it's clicked.
function SB:RefreshMainWindow()
    if not main then return end
    if isSettingsOpen or isAdminOpen then
        if isSettingsOpen then
            settingsPanel:Show()
            if SB.RefreshChannelMatrix then SB:RefreshChannelMatrix() end
        else
            settingsPanel:Hide()
        end
        if isAdminOpen then
            adminPanel:Show()
            SB:RefreshAdminPanel()
        else
            adminPanel:Hide()
        end
        emptyHint:Hide()
        main.libraryScroll.scroll:Hide()
        main.outputRail:Hide()
        main.tagFilterBar:Hide()
        for i = 1, #entryButtons do entryButtons[i]:Hide() end
        for i = 1, #sectionHeaders do sectionHeaders[i]:Hide() end
    else
        settingsPanel:Hide()
        adminPanel:Hide()
        main.libraryScroll.scroll:Show()
        main.outputRail:Show()
        main.tagFilterBar:Show()
        RefreshLibrary()
    end
    RefreshOutputRail()
end

function SB:ShowMainWindow()
    if not main then BuildMainFrame() end
    -- Explicit report: clicking the Announcer's icon reopened whichever
    -- internal view (Settings, Raid Admin) was last active instead of the
    -- Library, because isSettingsOpen/isAdminOpen are module-level flags
    -- that don't reset just because the window was hidden. Both of this
    -- function's callers (the icon click via ToggleMainWindow, and Intro's
    -- onboarding) want the Library every time - same as ShowDefaultSounds
    -- already does for its own onboarding entry point.
    isSettingsOpen = false
    isAdminOpen = false
    -- Explicit request: the virtual Hide section always starts collapsed
    -- again on a fresh open, even if it was expanded earlier this session.
    hideSectionExpanded = false
    InvalidateSortedListCache()
    main:Show()
    SB:RefreshMainWindow()
    -- Safety net: re-run one tick later too, in case the Library's multi-
    -- hop anchor chain (main -> toolbar -> tagFilterBar -> outputRail ->
    -- libraryScroll.scroll - see RefreshLibrary's own comment) hadn't
    -- fully resolved widths yet on this first synchronous pass. Cheap
    -- (one extra layout pass) and always safe to repeat.
    C_Timer.After(0, function()
        if main and main:IsShown() then SB:RefreshMainWindow() end
    end)
end

-- Onboarding destination: always open the actual starter sounds, never a
-- previously remembered Settings panel, search result, or tag filter.
function SB:ShowDefaultSounds()
    if not main then BuildMainFrame() end
    isSettingsOpen = false
    isAdminOpen = false
    if searchBox then searchBox:SetText("") end
    wipe(SB.db.ui.tagFilters)
    SB.db.ui.categoryCollapsed["Legacy"] = nil
    InvalidateSortedListCache()
    main:Show()
    SB:RefreshMainWindow()
    -- Land at the very top (Favourites, then Legacy) rather than wherever
    -- the Library happened to be scrolled to last.
    if main.libraryScroll then main.libraryScroll.scroll:SetVerticalScroll(0) end
end

function SB:HideMainWindow()
    if main then main:Hide() end
end

function SB:ToggleMainWindow()
    if main and main:IsShown() then
        SB:HideMainWindow()
    else
        SB:ShowMainWindow()
    end
end

-- Explicit compatibility entry point - Settings.lua's Favourite Keybinds
-- section lives inside the same Settings panel as before; this just opens
-- straight to it instead of leaving the player to find it manually.
function SB:OpenSettingsAtKeybindings()
    isSettingsOpen = true
    isAdminOpen = false
    ClearFiltering()
    SB:RefreshMainWindow()
    if SB.FocusFavouriteKeybindings then
        C_Timer.After(0, SB.FocusFavouriteKeybindings)
    end
end

function SB:GetMainGridLayout()
    local scrollFrame = main and main.libraryScroll and main.libraryScroll.scroll
    local contentWidth = scrollFrame and scrollFrame:GetWidth() or (ENTRY_W * 2)
    local columns = contentWidth >= THREE_COLUMN_WIDTH and 3 or 2
    -- rawWidth/rendered entries+headers surfaced for /sb doctor - lets a
    -- player tell "genuinely nothing registered" apart from "registered
    -- but the Library isn't actually rendering it" without needing
    -- /console scriptErrors 1 enabled first.
    return columns, contentWidth, usedEntries or 0, usedHeaders or 0
end

SB:On("TOGGLE_MAIN_UI", function() SB:ToggleMainWindow() end)

SB:On("FAVOURITES_CHANGED", function()
    if main and main:IsShown() and not isSettingsOpen and not isAdminOpen then RefreshLibrary() end
end)

SB:On("SOUND_DISPLAY_CHANGED", function()
    if main and main:IsShown() and not isSettingsOpen and not isAdminOpen then RefreshLibrary() end
end)

local function SetPlayingState(soundID)
    if playingStateTimer then
        playingStateTimer:Cancel()
        playingStateTimer = nil
    end
    playingSoundID = soundID
    if main and main:IsShown() and not isSettingsOpen and not isAdminOpen then RefreshLibrary() end
    local duration = tonumber(SB.db and SB.db.settings and SB.db.settings.announceDuration) or 3
    if soundID and duration > 0 then
        playingStateTimer = C_Timer.NewTimer(duration, function()
            playingStateTimer = nil
            playingSoundID = nil
            if main and main:IsShown() and not isSettingsOpen and not isAdminOpen then RefreshLibrary() end
        end)
    end
end

SB:On("LOCAL_SOUND_PLAYED", SetPlayingState)

SB:On("REMOTE_SOUND_PLAYED", SetPlayingState)

SB:On("PLAYBACK_STOPPED", function()
    SetPlayingState(nil)
end)

SB:On("CATEGORY_CHANGED", function()
    if main and main:IsShown() and not isSettingsOpen and not isAdminOpen then RefreshLibrary() end
end)

-- Keeps the Admin button's own visibility in sync with the player's
-- current role - a Raid Lead can hand off lead, an Assist can be demoted,
-- or the player can simply leave the group entirely, all mid-session.
local adminVisibilityFrame = CreateFrame("Frame")
adminVisibilityFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
adminVisibilityFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
adminVisibilityFrame:SetScript("OnEvent", function()
    SB:RefreshAdminTabVisibility()
    if main and main:IsShown() and not isSettingsOpen and not isAdminOpen then RefreshOutputRail() end
end)
