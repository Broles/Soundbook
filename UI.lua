-- UI.lua
-- The main Soundbook window: a WoW-Classic-styled book with page-flip
-- navigation, a search field, and spellbook-like tabs along the right
-- edge (Favourites, and the three user-nameable categories).

local ADDON_NAME, SB = ...

-- 2.5.0 adaptive library grid. The minimum footprint remains the familiar
-- 2x10 view (and therefore always fits all 20 Favourite positions), while
-- larger windows gain rows and eventually a third column instead of merely
-- stretching the old cells into large empty bands.
local DEFAULT_PAGE_SIZE = 20
local DEFAULT_COLUMNS = 2
local MIN_ROWS = 10
local MAX_ROWS = 16
local TARGET_ROW_HEIGHT = 34
local THREE_COLUMN_WIDTH = 600
local ENTRY_W     = 190
local ENTRY_H     = 28
local ICON_SIZE   = 22

-- The "private" tab only actually appears once SB:HasPrivateSounds() is
-- true (Soundbook_Private or similar installed with at least one sound
-- registered) - see BuildTabs. Favourites uses the string key
-- "favourites" (not a number) specifically so it can never collide with a
-- real category identifier - "Legacy"/"German Memes"/1/2 (SB.CATEGORIES,
-- Core.lua). Category 1/2 (hideIfEmpty) only ever appear once something
-- has actually registered a sound into them - normally Soundbook_MySounds
-- via SB.RegisterSounds. Soundbook itself never ships content in them,
-- only in "Legacy"/"German Memes" (used to be the single "Default"
-- category - see Core.lua's MigrateDB v17->v18 block) - see
-- SB:HasCategorySounds, BuildTabs below.
local TABS = {
    { key = "favourites", isFavourites = true },
    { key = "private", isPrivate = true },
    { key = "Legacy" },
    { key = "German Memes" },
    { key = 1, hideIfEmpty = true },
    { key = 2, hideIfEmpty = true },
}

local main
local entryButtons = {}
local tabButtons = {}
local searchBox
local searchPlaceholder
local outputChannelDD
local emptyHint
local pageLabel
local keybindingsShortcutBtn
local settingsPanel
local isSettingsOpen = false
local adminPanel
local isAdminOpen = false
local adminTabBtn
local selectedSoundID
local playingSoundID
local playingStateTimer
local mainDragGhostFrame, mainDragGhostIcon, mainDragGhostOrnament
local mainDragSourceSlot, mainDragSoundID
local RefreshGrid
local gridColumns, gridRows, gridPageSize = DEFAULT_COLUMNS, MIN_ROWS, DEFAULT_PAGE_SIZE

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
    local info = SB.db.categories[tab.key]
    return info.name, info.icon
end

--- Explicit request: "besser sehen auf welcher Kategorie ich mich gerade
--- aufhalte" - the display name of whichever category tab is currently
--- selected (SB.db.ui.currentTab), or nil if that key doesn't match a
--- known tab (shouldn't normally happen). Used by RefreshMainWindow to
--- put the category name right in the window's own header title.
local function GetCurrentTabName()
    local key = SB.db.ui.currentTab
    for _, tab in ipairs(TABS) do
        if tab.key == key then
            return (TabDisplayInfo(tab))
        end
    end
    return nil
end

local function GetCurrentPage()
    local key = tostring(SB.db.ui.currentTab)
    return SB.db.ui.currentPage[key] or 1
end

local function SetCurrentPage(page)
    local key = tostring(SB.db.ui.currentTab)
    SB.db.ui.currentPage[key] = page
end

-- Popularity/New ordering is computed once per tab per "window open
-- session" and then held fixed - explicit request: re-sorting live while
-- the player is actually looking at the book (e.g. because clicking a
-- sound just bumped its own play count) is disorienting, icons must not
-- visibly reshuffle under the mouse. Cleared only when the window
-- transitions from closed to open (SB:ShowMainWindow) or the Sound Order
-- setting itself changes (Settings.lua) - never by an ordinary RefreshGrid
-- call (favourite toggled, a sound played, Analytics synced, ...).
local sortedListCache = {}

local function GetTabSoundList(tabKey)
    if tabKey == "favourites" then
        -- Never sorted - fixed positions the player deliberately dragged
        -- into place, not a ranked list.
        return SB:GetFavourites()
    end
    if not SB.SortSoundIDsBySetting then
        return tabKey == "private" and SB:GetPrivateSounds() or SB:GetCategorySounds(tabKey)
    end
    if not sortedListCache[tabKey] then
        local ids = (tabKey == "private") and SB:GetPrivateSounds() or SB:GetCategorySounds(tabKey)
        sortedListCache[tabKey] = SB.SortSoundIDsBySetting(ids)
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
--- cross-category result list should replace the current tab's own
--- normal paged view - same treatment a text search already gets.
local function HasActiveTagFilters()
    return next(SB.db.ui.tagFilters) ~= nil
end

local function IsFiltering()
    return IsSearching() or HasActiveTagFilters()
end

-- Explicit request (reversed back from an earlier "keep filtering active
-- across a tab click" version): clicking a category tab, Favourites,
-- Settings, or Admin now clears BOTH the search box and any active tag
-- filter pills, exactly like landing on that destination's own plain
-- unfiltered view - not left running in the background. Shared by every
-- one of those click handlers so they can never drift out of sync with
-- each other.
local function ClearFiltering()
    if searchBox then searchBox:SetText("") end
    if SB.db and SB.db.ui and SB.db.ui.tagFilters then wipe(SB.db.ui.tagFilters) end
end

local function ListLength(tabKey, list)
    if tabKey == "favourites" then return SB.MAX_FAVOURITES end
    return #list
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
--- together when both are active), completely ignoring SB.db.ui.currentTab,
--- same as a text search alone already did. An active tag filter is an OR
--- across whichever pills are toggled on (New/Trending/Popular/Loved) -
--- explicit request.
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
    if IsFiltering() or SB.db.ui.currentTab ~= "favourites" or not btn.favouriteSlot then return end
    mainDragSourceSlot = btn.favouriteSlot
    mainDragSoundID = btn.soundID
    if btn.favouriteHover then btn.favouriteHover:Hide() end
    -- Reveal the otherwise invisible empty rows as grey icon targets for
    -- the duration of this drag, matching Mini Soundbook behaviour.
    RefreshGrid()

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
    RefreshGrid()
end

------------------------------------------------------------------------
-- Sound entry buttons
------------------------------------------------------------------------

local function CreateEntryButton(index)
    local btn = CreateFrame("Button", "SoundbookEntry" .. index, main)
    btn:SetSize(ENTRY_W, ENTRY_H)

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

    -- "Hotkey: CTRL+A" - explicit request: Favourites tab only, white,
    -- two font sizes smaller than the name above it, and only shown at all
    -- when THIS slot actually has a real Blizzard keybinding assigned (see
    -- RefreshGrid and Keybindings.lua's SB:GetFavouriteHotkeyLabel).
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
    -- right after the name, same row, so the existing per-row layout/
    -- pagination never changes. At most one tag per sound. Genuinely
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
    -- Kept around so RefreshGrid can recolour it per-row (blue/accent for a
    -- normal sound, gold for a favourite) - see the explicit request there.
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
                -- Same "send to a specific channel/person" popup the Mini
                -- Soundbook's plain right-click already opens - explicit
                -- request: plain right-click stays Edit Sound here (that's
                -- the established, kept-as-is main-window behaviour), so
                -- the send menu needs its own modifier to stay reachable.
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
        -- grey - see RefreshGrid's btn.restColor) needs to give way to
        -- something that stays readable against an accent-coloured
        -- background specifically - plain white, same choice SendMenu.lua's
        -- own hover rows already made for the identical reason.
        self.nameText:SetTextColor(0.72, 0.86, 1.0)
        if self.isFavouriteView and self.favouriteHover then
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
        -- RefreshGrid alongside the pill itself), coloured the same as the
        -- pill's own text so "why does this say Loved?" is answered right
        -- here instead of sending someone to the Analytics window.
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

local function EnsureEntryButtons()
    local contentWidth = main.content:GetWidth() or (ENTRY_W * DEFAULT_COLUMNS)
    local contentHeight = main.content:GetHeight() or (ENTRY_H * MIN_ROWS)
    local columns = contentWidth >= THREE_COLUMN_WIDTH and 3 or 2
    local rows = math.floor(contentHeight / TARGET_ROW_HEIGHT)
    rows = math.max(MIN_ROWS, math.min(MAX_ROWS, rows))
    local pageSize = columns * rows

    if pageSize ~= gridPageSize then
        -- Keep the first currently visible result in view as capacity
        -- changes; otherwise widening the frame can appear to jump several
        -- sounds forward or backward.
        local oldPage = IsFiltering() and (main.searchPage or 1) or GetCurrentPage()
        local firstVisible = math.max(1, (oldPage - 1) * gridPageSize + 1)
        local newPage = math.floor((firstVisible - 1) / pageSize) + 1
        if IsFiltering() then main.searchPage = newPage else SetCurrentPage(newPage) end
    end
    gridColumns, gridRows, gridPageSize = columns, rows, pageSize
    main.gridColumns, main.gridRows, main.gridPageSize = columns, rows, pageSize

    local entryW = contentWidth / columns
    local entryH = contentHeight / rows
    local iconExtent = math.max(24, math.min(34, entryH - 6))
    local hotkeyWidth = math.max(70, math.min(104, entryW * 0.28))
    for i = 1, pageSize do
        if not entryButtons[i] then
            entryButtons[i] = CreateEntryButton(i)
        end
        local btn = entryButtons[i]
        local col = (i - 1) % columns
        local row = math.floor((i - 1) / columns)
        btn:ClearAllPoints()
        btn:SetSize(entryW, entryH)
        btn:SetPoint("TOPLEFT", main.content, "TOPLEFT", col * entryW, -row * entryH)
        btn.slot:SetSize(iconExtent, iconExtent)
        btn.favouriteHover:SetSize(iconExtent * 1.30, iconExtent * 1.30)
        btn.favouriteHoverOrnament:SetSize(iconExtent * 1.30 * 1.50, iconExtent * 1.30 * 1.50)
        btn.hotkeyText:SetWidth(hotkeyWidth)
    end
    for i = pageSize + 1, #entryButtons do entryButtons[i]:Hide() end
    -- Explicit bugfix: this only used to hide slots PAST the new pageSize -
    -- fine normally, since RefreshGrid (which shows/hides/populates
    -- slots 1..pageSize) always runs right after. But RefreshGrid
    -- deliberately no-ops while Settings/Admin is open ("if isSettingsOpen
    -- then return end"), so resizing the window while either is open used
    -- to leave freshly created or resized slots sitting SHOWN (a brand new
    -- button defaults to visible, and an existing one simply keeps
    -- whatever show/hide state it already had) with no icon/name ever set
    -- on them - empty bordered squares bleeding through the settings
    -- panel's own (deliberately narrow, centered) margins. Settings/Admin
    -- never show the grid at all, so every slot belongs hidden regardless
    -- of pageSize while either is open.
    if isSettingsOpen or isAdminOpen then
        for i = 1, pageSize do entryButtons[i]:Hide() end
    end
end

function SB:GetMainGridLayout()
    return gridColumns, gridRows, gridPageSize
end

------------------------------------------------------------------------
-- Refresh / paging
------------------------------------------------------------------------

RefreshGrid = function()
    if isSettingsOpen then return end
    EnsureEntryButtons()
    local pageSize = gridPageSize

    -- Explicit request: "besser sehen auf welcher Kategorie ich mich
    -- gerade aufhalte" - the window's own header now names the active tab
    -- directly (explicit request: just "Legacy", no "Soundbook -" prefix).
    -- Refreshed here (not just RefreshMainWindow) since RefreshGrid is what
    -- actually runs on every relevant change - tab switch, search text,
    -- tag filter pill, not just opening the window. Falls back to plain
    -- "Soundbook" while filtering (search text and/or an active tag pill) -
    -- the grid isn't actually scoped to that one category anymore then,
    -- it's the cross-category flat result list, so naming just the tab
    -- would be misleading.
    if main.headerBar and main.headerBar.title and not isAdminOpen then
        local catName = (not IsFiltering()) and GetCurrentTabName()
        main.headerBar.title:SetText(catName or "Soundbook")
    end

    local list, page, totalPages

    if IsFiltering() then
        list = GetFilteredSoundList()
        page = 1
        totalPages = math.max(1, math.ceil(#list / pageSize))
        if main.searchPage and main.searchPage <= totalPages then
            page = main.searchPage
        end
    else
        list = GetTabSoundList(SB.db.ui.currentTab)
        totalPages = math.max(1, math.ceil(ListLength(SB.db.ui.currentTab, list) / pageSize))
        page = math.min(GetCurrentPage(), totalPages)
        SetCurrentPage(page)
    end

    local startIdx = (page - 1) * pageSize

    for i = 1, pageSize do
        local btn = entryButtons[i]
        local soundID = list[startIdx + i]
        if soundID and SB.registry[soundID] then
            local saved = SB:GetSoundSaved(soundID)
            btn.soundID = soundID
            btn.icon:SetTexture(SB:GetSoundIcon(soundID))
            btn.icon:Show()
            -- "Alternative Sound" purple wash (Theme.lua's CreateIconSlot) -
            -- explicit request, shown "always, everywhere" for a sound
            -- with a personal alternate recording enabled.
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
            -- favourite (matching its gold resting name colour/border
            -- above), blue/accent otherwise - so hovering makes favourite
            -- status visible at a glance, not just the name colour. Reset
            -- live every refresh (including right after Shift+Left-Click
            -- toggles a favourite - RefreshMainWindow already re-runs this),
            -- so the new colour shows immediately, no reload/re-hover needed.
            if btn.highlight then
                if saved.favourite then
                    btn.highlight:SetColorTexture(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.16)
                else
                    btn.highlight:SetColorTexture(SB.Theme.ACCENT[1], SB.Theme.ACCENT[2], SB.Theme.ACCENT[3], 0.12)
                end
            end
            btn.slot:SetVisualState(isPlaying and "playing" or (isSelected and "selected" or "normal"),
                saved.favourite and true or false, saved.muted and true or false, outputColor)

            -- Hotkey label - Favourites tab only. The visible list is
            -- compact, so look up the sound's real stored slot instead of
            -- mistaking its display row for its keybind position. Never
            -- show it during search. Explicit request: an unbound position
            -- shows nothing at all - no "[-]" placeholder - only an
            -- actually-assigned keybind gets the "[X]" label.
            local favouriteSlot = (not IsFiltering()) and SB.db.ui.currentTab == "favourites"
                and SB.GetFavouriteSlot and SB:GetFavouriteSlot(soundID)
            local hotkey = (not IsFiltering()) and SB.db.ui.currentTab == "favourites"
                and favouriteSlot and SB.GetFavouriteHotkeyLabel
                and SB:GetFavouriteHotkeyLabel(favouriteSlot)
            btn.favouriteSlot = favouriteSlot
            btn.isFavouriteView = favouriteSlot and true or false
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
                -- Tags never show on the Favourites tab at all - explicit
                -- fix: that column is reserved for hotkey labels there
                -- (shown only on SOME rows, whichever slots have a real
                -- keybind), so a tag appearing on the other rows read as
                -- randomly conflicting with the hotkey column instead of
                -- looking like a deliberate second thing. A Favourite is
                -- also already a sound the player deliberately chose - a
                -- "Popular"/"Loved" hint adds little there anyway.
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
            local isFavouriteDropTarget = mainDragSourceSlot
                and (not IsFiltering()) and SB.db.ui.currentTab == "favourites"
                and (startIdx + i) <= SB.MAX_FAVOURITES
            btn.favouriteSlot = isFavouriteDropTarget and (startIdx + i) or nil
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

    -- Empty-state hint - explicit requirement: a clear (if brief) message
    -- for both an empty category AND an empty Favourites list, never a
    -- PERMANENT fixture (only shown while actually empty, outside of
    -- search - a genuinely empty category/Favourites still says "no
    -- results" via the page label while searching, which is enough there).
    -- Use the authoritative favourite count for the empty state; favourite
    -- slots are fixed positions and may intentionally contain gaps.
    local tabKey = SB.db.ui.currentTab
    if IsFiltering() then
        emptyHint:Hide()
    elseif tabKey == "favourites" then
        if SB:GetFavouriteCount() == 0 then
            emptyHint:SetText("No Favourites yet.\n\nShift+Left-Click any sound to add it here.")
            emptyHint:Show()
        else
            emptyHint:Hide()
        end
    elseif tabKey ~= "private" and #list == 0 then
        -- Only ever points at Soundbook_MySounds - never at editing
        -- Soundbook's own Sounds.lua/Sounds\CategoryN directly, since
        -- CurseForge/WowUp updates replace Soundbook's entire folder and
        -- would silently delete anything added that way.
        -- Only ever reachable for the numeric categories in practice -
        -- Legacy/German Memes always ship with content, never empty - but
        -- kept general (quoted for a string key) rather than assuming
        -- numeric, same reasoning as Settings.lua's own category-name
        -- fallback.
        local luaKey = (type(tabKey) == "string") and ("[\"" .. tabKey .. "\"]") or ("[" .. tostring(tabKey) .. "]")
        emptyHint:SetText(string.format(
            "No sounds in this category yet.\n\nAdd sounds using the Soundbook_MySounds companion addon (see README) - it's the only way that's safe across Soundbook updates:\n\n1. Copy the .mp3/.ogg/.wav into Soundbook_MySounds\\Sounds\\Category1\\ (or Category2)\n2. Add its file name to Soundbook_MySounds\\Sounds.lua, under %s\n3. Fully restart the WoW client (not /reload)",
            luaKey))
        emptyHint:Show()
    else
        emptyHint:Hide()
    end

    if IsFiltering() then
        -- Distinguishes a text search from a tag-only filter (and calls
        -- out when both are combined) rather than always saying "Search
        -- results" for something that might be a pure tag pick.
        local label = IsSearching()
            and (HasActiveTagFilters() and "Search + tag results" or "Search results")
            or "Tag filter results"
        pageLabel:SetText(string.format("%s (%d) - Page %d / %d", label, #list, page, totalPages))
        main.searchPage = page
    else
        pageLabel:SetText(string.format("Page %d / %d", page, totalPages))
    end

    -- Favourites has at most SB.MAX_FAVOURITES slots, which fits within
    -- the grid's minimum capacity. It can never have a second page, so showing a dead
    -- "Page 1 / 1" control there only adds noise. A global search/tag
    -- filter may still exceed one page even when started from this tab, so
    -- keep pagination visible while filtering.
    main.pageBar:SetShown(IsFiltering() or SB.db.ui.currentTab ~= "favourites")
    if keybindingsShortcutBtn then
        keybindingsShortcutBtn:SetShown((not IsFiltering()) and SB.db.ui.currentTab == "favourites")
    end

    -- Tag filter bar itself - explicit request (reversed from an earlier
    -- "never on Favourites" version): now shown on every tab, Favourites
    -- included, so a filter can be started from there too. Clicking a
    -- pill while on Favourites already correctly switches away from that
    -- tab's own fixed-slot/hotkey view into the normal cross-category
    -- filtered list (IsFiltering() already gates the hotkey/drag-specific
    -- rendering everywhere it applies - see favouriteSlot's own "(not
    -- IsFiltering()) and currentTab == 'favourites'" checks) - the ONLY
    -- thing that was actually missing was the bar itself being visible
    -- here to click at all. Plain (non-filtered) Favourites browsing is
    -- completely unaffected - no tag pills show on its own rows, exactly
    -- as before, since IsFiltering() is false then.
    if main.tagFilterBar then
        main.tagFilterBar:Show()
    end
    if main.tagFilterUpdaters then
        for _, updateFn in ipairs(main.tagFilterUpdaters) do updateFn() end
    end

    if page > 1 then main.prevBtn:Enable(); main.prevBtn:SetAlpha(1)
    else main.prevBtn:Disable(); main.prevBtn:SetAlpha(0.35) end
    if page < totalPages then main.nextBtn:Enable(); main.nextBtn:SetAlpha(1)
    else main.nextBtn:Disable(); main.nextBtn:SetAlpha(0.35) end
end

local function ChangePage(delta)
    if IsFiltering() then
        main.searchPage = (main.searchPage or 1) + delta
        if main.searchPage < 1 then main.searchPage = 1 end
    else
        local page = GetCurrentPage() + delta
        if page < 1 then page = 1 end
        SetCurrentPage(page)
    end
    RefreshGrid()
end

------------------------------------------------------------------------
-- Tabs
------------------------------------------------------------------------

-- Explicit request: "besser sehen auf welcher Kategorie ich mich gerade
-- aufhalte" - the active tab needed to stand out more clearly than just a
-- border/fill colour change in a vertical stack of otherwise-similar
-- icons. Adds a stronger glow (btn.innerGlow, from Theme.CreateIconSlot -
-- deliberately brighter than SetVisualState's own resting-favourite glow
-- elsewhere, since this is a persistent "you are here" marker, not a
-- transient state) and nudges the button a few px toward the book itself
-- (btn.anchorPoint/anchorRelPoint/anchorY, captured once at creation by
-- BuildTabs/BuildSettingsTabButton/BuildAdminTabButton) so the active tab
-- visually reads as "merged" with the open page, not just differently
-- coloured.
local function SetTabActive(btn, active)
    btn:SetBackdropBorderColor(unpack(active and SB.Theme.ACCENT or SB.Theme.BORDER_DIM))
    btn:SetBackdropColor(active and SB.Theme.BG_RAISED[1] or 0, active and SB.Theme.BG_RAISED[2] or 0, active and SB.Theme.BG_RAISED[3] or 0, active and 1 or 0)
    if btn.innerGlow then
        btn.innerGlow:SetVertexColor(SB.Theme.ACCENT[1], SB.Theme.ACCENT[2], SB.Theme.ACCENT[3], active and 0.40 or 0)
    end
    if btn.anchorPoint then
        btn:ClearAllPoints()
        btn:SetPoint(btn.anchorPoint, main, btn.anchorRelPoint, active and -4 or 2, btn.anchorY)
    end
end

local function RefreshTabs()
    for _, btn in ipairs(tabButtons) do
        local isActive = (not isSettingsOpen) and (not isAdminOpen) and btn.tabKey == SB.db.ui.currentTab
        SetTabActive(btn, isActive)
    end
    if main.settingsTabBtn then
        SetTabActive(main.settingsTabBtn, isSettingsOpen)
    end
    if adminTabBtn then
        SetTabActive(adminTabBtn, isAdminOpen)
    end
end

-- Shared visual construction for every tab-like button along the right
-- edge of the book (Favourites/Category tabs AND the Settings button use
-- the exact same look, so Settings reads as "one more tab", not a
-- different kind of control). Flat square slot, dim border normally,
-- accent-coloured border + a raised fill when it's the active tab.
local function CreateTabButtonFrame()
    local btn = SB.Theme.CreateIconSlot(main, 40, nil, "Button")

    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)
    btn.highlight = highlight

    btn.icon = btn.texture -- CreateIconSlot already insets (and crops) a texture

    return btn
end

local function CreateTabButton(tab)
    local btn = CreateTabButtonFrame()
    btn.tabKey = tab.key
    btn.tab = tab

    btn:SetScript("OnClick", function(self)
        isSettingsOpen = false
        isAdminOpen = false
        selectedSoundID = nil
        SB.db.ui.currentTab = self.tabKey
        ClearFiltering()
        SB:RefreshMainWindow()
    end)

    btn:SetScript("OnEnter", function(self)
        local name = TabDisplayInfo(tab)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(name, 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return btn
end

-- Skips the "private" tab entirely (not just hides it) when
-- SB:HasPrivateSounds() is false, so nobody without Soundbook_Private (or
-- an empty one) ever sees a tab for it - and every tab after it shifts up
-- to fill the gap rather than leaving a blank slot. Same treatment for any
-- hideIfEmpty tab (Category 1/2) via SB:HasCategorySounds.
local function BuildTabs()
    local index = 0
    for _, tab in ipairs(TABS) do
        local visible = (not tab.isPrivate or SB:HasPrivateSounds())
            and (not tab.hideIfEmpty or SB:HasCategorySounds(tab.key))
        if visible then
            index = index + 1
            local btn = CreateTabButton(tab)
            -- Just enough of a gap that the tab's own 1px border doesn't sit
            -- flush on top of the book's border, without floating far away.
            local y = -50 - (index - 1) * 46
            btn:SetPoint("TOPLEFT", main, "TOPRIGHT", 2, y)
            btn.anchorPoint, btn.anchorRelPoint, btn.anchorY = "TOPLEFT", "TOPRIGHT", y
            tabButtons[index] = btn
        end
    end
    main.visibleCategoryTabs = index
end

local function RefreshTabIcons()
    for _, btn in ipairs(tabButtons) do
        local _, icon = TabDisplayInfo(btn.tab)
        btn.icon:SetTexture(icon)
    end
end

------------------------------------------------------------------------
-- Settings toggle - Settings is visually its own tab (same size/border as
-- Favourites/Category tabs) and continues the same compact right-side dock.
------------------------------------------------------------------------

local function ToggleSettings()
    isSettingsOpen = not isSettingsOpen
    -- Closes Admin if it was open - the mutual-exclusion used to live in
    -- RefreshMainWindow instead (always forcing isSettingsOpen back off
    -- whenever isAdminOpen was still true), which meant clicking Settings
    -- while Admin was open had no visible effect at all - whichever one was
    -- just clicked must win, not whichever was already open.
    if isSettingsOpen then
        isAdminOpen = false
        ClearFiltering()
    end
    SB:RefreshMainWindow()
end

function SB:OpenSettingsAtKeybindings()
    isSettingsOpen = true
    isAdminOpen = false
    ClearFiltering()
    SB:RefreshMainWindow()
    if SB.FocusFavouriteKeybindings then
        C_Timer.After(0, SB.FocusFavouriteKeybindings)
    end
end

local function BuildSettingsTabButton()
    local btn = CreateTabButtonFrame()
    btn.icon:SetTexture(SB.SETTINGS_ICON)
    -- Explicit, repeated request: pinned to the actual BOTTOM edge of the
    -- book ("unten am Soundbook anheften nicht oben") - anchored straight
    -- to main's own BOTTOMRIGHT corner, NOT computed from the category-tab
    -- count from the top (that earlier attempt only "happened" to land
    -- near the bottom for a specific tab count/window height, not always).
    btn:SetPoint("BOTTOMLEFT", main, "BOTTOMRIGHT", 2, 8)
    btn.anchorPoint, btn.anchorRelPoint, btn.anchorY = "BOTTOMLEFT", "BOTTOMRIGHT", 8

    btn:SetScript("OnClick", ToggleSettings)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Settings", 1, 1, 1)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    main.settingsTabBtn = btn
    return btn
end

------------------------------------------------------------------------
-- Raid Admin toggle - same look/position family as Settings, but sits
-- directly ABOVE it (explicit request: "Oberhalb der Settings (Zahnrad)"),
-- and only exists at all for the current Raid Leader/Assist or Party
-- Leader - see AdminPanel.lua for the panel itself.
------------------------------------------------------------------------

local function ToggleAdmin()
    isAdminOpen = not isAdminOpen
    if isAdminOpen then
        isSettingsOpen = false
        ClearFiltering()
    end
    SB:RefreshMainWindow()
end

local function BuildAdminTabButton()
    local btn = CreateTabButtonFrame()
    btn.icon:SetTexture(SB.ADMIN_ICON)
    -- Directly above the Settings button (same 46px row spacing every
    -- other tab in this dock uses), anchored from main's BOTTOM the same
    -- way Settings now is - stays glued to Settings regardless of
    -- category-tab count or window height, instead of floating relative
    -- to the top.
    btn:SetPoint("BOTTOMLEFT", main, "BOTTOMRIGHT", 2, 8 + 46)
    btn.anchorPoint, btn.anchorRelPoint, btn.anchorY = "BOTTOMLEFT", "BOTTOMRIGHT", 8 + 46

    btn:SetScript("OnClick", ToggleAdmin)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Raid Admin", 1, 1, 1)
        GameTooltip:AddLine("Temporarily mute sending/receiving for the raid or party.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    adminTabBtn = btn
    return btn
end

-- Shows/hides the Admin button itself the moment the player's own role
-- changes (promoted/demoted, joins/leaves a group) - re-checked on every
-- roster update rather than only at window-build time, since a Raid Lead
-- can hand off lead mid-raid.
function SB:RefreshAdminTabVisibility()
    if not adminTabBtn then return end
    local adminVisible = SB:IsRaidAdmin()
    -- Settings no longer moves here - it's permanently pinned to main's
    -- own bottom edge (see BuildSettingsTabButton), so Admin showing/
    -- hiding never needs to shift it up or down anymore. This block used
    -- to re-anchor Settings back to the old top-down, tab-count-based
    -- position every time this ran (on init AND on every roster update) -
    -- silently undoing the bottom-pin fix the moment a roster event fired.
    if adminVisible then
        adminTabBtn:Show()
    else
        adminTabBtn:Hide()
        -- The panel itself must not stay open/reachable for someone who
        -- just lost the role that unlocked it.
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
    main:SetScript("OnDragStart", main.StartMoving)
    main:SetScript("OnDragStop", function()
        main:StopMovingOrSizing()
        SavePosition()
    end)
    SB.Theme.Panel(main)
    main:Hide()

    tinsert(UISpecialFrames, "SoundbookMainFrame")

    local headerBar = SB.Theme.CreateHeader(main, "Soundbook", 56)
    main.headerBar = headerBar

    local closeBtn = SB.Theme.CreateCloseGlyph(main, 20)
    closeBtn:SetPoint("TOPRIGHT", -8, -8)
    closeBtn:SetScript("OnClick", function() main:Hide() end)

    -- Search box - no separate "Search" label (the placeholder text inside
    -- already says that); sized and aligned to match the grid's right
    -- grid exactly (same left/right edges as the icons/names below it;
    -- columns are chosen by EnsureEntryButtons) instead of
    -- floating disconnected in the top-right corner.
    searchBox = SB.Theme.CreateInputBox(main, ENTRY_W, 22)
    searchBox:SetPoint("TOPLEFT", main, "TOP", 0, -78)
    -- -44, matching content's own BOTTOMRIGHT inset below (was -40 - a 4px
    -- mismatch that made the search box stick out past the container's
    -- right edge instead of lining up with it exactly, per this block's
    -- own comment above).
    searchBox:SetPoint("RIGHT", main, "RIGHT", -44, 0)
    searchBox:SetMaxLetters(50)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    searchBox:SetScript("OnTextChanged", function(self)
        searchPlaceholder:SetShown(self:GetText() == "")
        main.searchPage = 1
        RefreshGrid()
    end)
    main.searchBox = searchBox

    searchPlaceholder = searchBox:CreateFontString(nil, "OVERLAY")
    searchPlaceholder:SetFontObject(SB.Fonts.DisableSmall)
    searchPlaceholder:SetPoint("LEFT", 4, 0)
    searchPlaceholder:SetText("Search...")

    -- Default Output Channel - moved here from Settings (explicit request):
    -- omnipresent above the sound grid, left of the search box, on every
    -- sound-listing tab (categories/Stammtisch/Favourites) - NOT
    -- shown over Settings/Admin (see RefreshMainWindow below, same
    -- show/hide as the search box). Left column of the same row the search
    -- box occupies on the right (20 = grid's own left inset, ENTRY_W =
    -- exactly one grid column wide, so it lines up with the icons below it
    -- same as the search box already does on its side).
    -- Explicit request: dropdown list ~50% taller (12 visible rows, was 8)
    -- so the broadcast target list needs less scrolling.
    outputChannelDD = SB.Theme.CreateDropdown(main, ENTRY_W, 22, 12)
    outputChannelDD.button:SetPoint("TOPLEFT", main, "TOPLEFT", 24, -78)
    outputChannelDD.button:SetPoint("RIGHT", main, "TOP", -6, 0)
    outputChannelDD:SetOptions(SB.ComputeOutputTargetOptions())
    outputChannelDD:SetOptionsProvider(SB.ComputeOutputTargetOptions)
    outputChannelDD:SetRowFont(SB.OutputTargetRowFont)
    outputChannelDD:SetValue(SB.db.settings.defaultOutputTarget)
    outputChannelDD:SetOnChange(function(value)
        SB.db.settings.defaultOutputTarget = value
    end)
    main.outputChannelDD = outputChannelDD

    -- Explicit request: a tooltip explaining what this dropdown actually
    -- does - it's easy to mistake for a generic filter at a glance.
    outputChannelDD.button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
        GameTooltip:SetText("Default Output Channel", 1, 1, 1)
        GameTooltip:AddLine("Where a sound goes when you click it - Self plays only for you, everything else also sends to that channel/person.", 0.8, 0.8, 0.8, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("A macro's own \"::Target\" suffix overrides this for that one sound.", 0.6, 0.8, 1, true)
        GameTooltip:Show()
    end)
    outputChannelDD.button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Tag filter pills (explicit request) - New/Trending/Popular/Loved,
    -- same colours the per-sound pill already uses (TAG_STYLE). Clicking
    -- one toggles it on/off; any number can be active at once, OR'ed
    -- together (GetFilteredSoundList) - "ich kann auch mehrere Tags
    -- anklicken gleichzeitig". Active tag filters search across EVERY
    -- category, ignoring the current tab, same as a text search already
    -- does (IsFiltering()/GetFilteredSoundList above) - hidden on the
    -- Favourites tab (see RefreshGrid), same reasoning as the per-sound
    -- pill never showing there either.
    --
    -- Explicit request: centered over the actual sound-icon grid below
    -- (content's own full width, 24 to -44), not just the left-half row
    -- outputChannelDD sits in - same horizontal span as content/searchBox.
    local tagFilterBar = SB.CreateFrame("Frame", nil, main)
    tagFilterBar:SetPoint("TOPLEFT", main, "TOPLEFT", 24, -106)
    tagFilterBar:SetPoint("RIGHT", main, "RIGHT", -44, 0)
    tagFilterBar:SetHeight(20)
    main.tagFilterBar = tagFilterBar
    -- Every pill's own UpdatePillVisual, so RefreshGrid can keep them all
    -- in sync even when SB.db.ui.tagFilters changes some other way than a
    -- click on the pill itself (e.g. SB:ShowDefaultSounds wiping it).
    main.tagFilterUpdaters = {}

    -- Explicit request: pills are centered within the bar (not left-
    -- aligned) - each pill's width depends on its own label text, so the
    -- total row width is only known once every pill exists. Built first at
    -- an arbitrary LEFT anchor, then all repositioned together by
    -- RecenterFilterPills below, which also re-runs on OnSizeChanged so
    -- resizing the main window keeps them centered.
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

        -- Explicit request: the pill only shows at all while at least one
        -- sound currently carries this tag (GetVisibleTagSet) - "ich
        -- brauch nicht Trending sehen oben als Pille wenn es keine Sounds
        -- dafür gibt", same for New once nothing's within its 48h window.
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
            -- Same "start over at page 1" treatment a fresh text search
            -- already gets (both share the same global list/page counter).
            main.searchPage = 1
            RefreshGrid()
        end)

        -- Explicit request: just the tag's own description, no "click to
        -- filter..." call-to-action - and coloured like the pill itself
        -- (title + body both in style.text), not Theme.AttachTooltip's
        -- fixed gold/grey scheme.
        pill:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(style.label, style.text[1], style.text[2], style.text[3])
            GameTooltip:AddLine(style.desc, style.text[1], style.text[2], style.text[3], true)
            GameTooltip:Show()
        end)
        pill:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- Centers the whole pill row within tagFilterBar - see filterPills'
    -- own comment above. Re-anchors every VISIBLE pill (a hidden one -
    -- SetShown(false) by UpdatePillVisual above, when its tag currently
    -- has no matching sound - is skipped entirely, so it leaves no gap in
    -- the row) left-to-right starting from the computed offset.
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
    -- Keeps the row centered if the main window (and therefore this bar)
    -- gets resized - it's user-resizable (main:SetResizable, 560-720px).
    tagFilterBar:SetScript("OnSizeChanged", RecenterFilterPills)
    -- Also re-centers every time RefreshGrid runs all tagFilterUpdaters
    -- (see there) - after every pill's own UpdatePillVisual has already
    -- run and potentially shown/hidden it, this closes the gap left by
    -- any pill that just disappeared (or makes room for one that
    -- reappeared).
    table.insert(main.tagFilterUpdaters, RecenterFilterPills)

    -- Content area for sound entries
    local content = SB.CreateFrame("Frame", nil, main)
    content:SetPoint("TOPLEFT", 24, -132)
    content:SetPoint("BOTTOMRIGHT", -44, 66)
    content:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    content:SetBackdropColor(0.006, 0.022, 0.052, 0.72)
    content:SetBackdropBorderColor(SB.Theme.GOLD[1], SB.Theme.GOLD[2], SB.Theme.GOLD[3], 0.52)
    main.content = content

    -- Shown instead of the (then-empty) grid when a category has no sound
    -- files yet - see RefreshGrid.
    emptyHint = content:CreateFontString(nil, "OVERLAY")
    emptyHint:SetFontObject(SB.Fonts.HighlightSmall)
    emptyHint:SetPoint("CENTER", content, "CENTER", 0, 0)
    emptyHint:SetWidth(math.max(220, (content:GetWidth() or (ENTRY_W * DEFAULT_COLUMNS)) - 40))
    emptyHint:SetJustifyH("CENTER")
    emptyHint:SetWordWrap(true)
    emptyHint:SetTextColor(unpack(SB.Theme.TEXT_DIM))
    emptyHint:SetSpacing(3)
    emptyHint:Hide()

    -- Page bar - anchored with a deliberate gap below the sound grid so the
    -- pagination controls never crowd the last row of icons.
    local pageBar = CreateFrame("Frame", nil, main)
    pageBar:SetPoint("BOTTOM", main, "BOTTOM", 0, 24)
    pageBar:SetSize(340, 24)
    main.pageBar = pageBar

    pageLabel = pageBar:CreateFontString(nil, "OVERLAY")
    pageLabel:SetFontObject(SB.Fonts.Normal)
    pageLabel:SetPoint("LEFT", 38, 0)
    pageLabel:SetPoint("RIGHT", -38, 0)
    pageLabel:SetJustifyH("CENTER")
    pageLabel:SetWordWrap(false)

    local prevBtn = SB.Theme.CreateFlatButton(pageBar, "<", 28, 22)
    prevBtn:SetPoint("LEFT", pageBar, "LEFT", 2, 0)
    prevBtn:SetScript("OnClick", function() ChangePage(-1) end)
    main.prevBtn = prevBtn

    local nextBtn = SB.Theme.CreateFlatButton(pageBar, ">", 28, 22)
    nextBtn:SetPoint("RIGHT", pageBar, "RIGHT", -2, 0)
    nextBtn:SetScript("OnClick", function() ChangePage(1) end)
    main.nextBtn = nextBtn

    keybindingsShortcutBtn = SB.Theme.CreateFlatButton(main, "Keybindings", 150, 22, "primary")
    keybindingsShortcutBtn:SetPoint("BOTTOM", main, "BOTTOM", 0, 25)
    keybindingsShortcutBtn:SetScript("OnClick", function() SB:OpenSettingsAtKeybindings() end)
    SB.Theme.AttachTooltip(keybindingsShortcutBtn, "Favourite Keybindings",
        "Open Settings at the key assignments for favourite positions 1-20.")
    keybindingsShortcutBtn:Hide()
    main.keybindingsShortcutBtn = keybindingsShortcutBtn

    local resizeGrip = SB.CreateFrame("Button", nil, main)
    resizeGrip:SetSize(22, 22)
    resizeGrip:SetPoint("BOTTOMRIGHT", -8, 8)
    resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeGrip:SetScript("OnMouseDown", function() main:StartSizing("BOTTOMRIGHT") end)
    resizeGrip:SetScript("OnMouseUp", function()
        main:StopMovingOrSizing()
        SaveSize()
        if main.layoutRefreshTimer then
            main.layoutRefreshTimer:Cancel()
            main.layoutRefreshTimer = nil
        end
        EnsureEntryButtons()
        RefreshGrid()
        if settingsPanel and settingsPanel:IsShown() and SB.FitSettingsPanelHeight then SB:FitSettingsPanelHeight() end
    end)
    main.resizeGrip = resizeGrip
    main:SetScript("OnSizeChanged", function()
        if not main.content then return end
        EnsureEntryButtons()
        emptyHint:SetWidth(math.max(220, (main.content:GetWidth() or 260) - 40))
        if main.layoutRefreshTimer then main.layoutRefreshTimer:Cancel() end
        main.layoutRefreshTimer = C_Timer.NewTimer(0.05, function()
            main.layoutRefreshTimer = nil
            RefreshGrid()
            -- Explicit request: Settings should resize live during the
            -- drag, same as the sound grid above, not just once on mouse-
            -- up - this used to only run from the resize grip's OnMouseUp.
            if settingsPanel and settingsPanel:IsShown() and SB.FitSettingsPanelHeight then
                SB:FitSettingsPanelHeight()
            end
        end)
    end)

    -- Guards against a saved "private" tab from an earlier session where
    -- Soundbook_Private was installed but no longer is - falls back to
    -- Favourites instead of landing on a tab that no longer exists.
    if SB.db.ui.currentTab == "private" and not SB:HasPrivateSounds() then
        SB.db.ui.currentTab = "favourites"
    end
    -- Same guard for a saved Category 1/2 tab that's since gone empty again
    -- (e.g. Soundbook_MySounds was removed) - land on Favourites instead of
    -- a hidden tab.
    if (SB.db.ui.currentTab == 1 or SB.db.ui.currentTab == 2) and not SB:HasCategorySounds(SB.db.ui.currentTab) then
        SB.db.ui.currentTab = "favourites"
    end

    local sideDock = SB.CreateFrame("Frame", nil, main)
    sideDock:SetPoint("TOPLEFT", main, "TOPRIGHT", 0, -44)
    sideDock:SetSize(46, 260)
    sideDock:EnableMouse(false)
    main.sideDock = sideDock

    BuildTabs()
    BuildSettingsTabButton()
    BuildAdminTabButton()

    settingsPanel = SB.BuildSettingsPanel(main, content)
    settingsPanel:Hide()
    adminPanel = SB.BuildAdminPanel(main, content)
    adminPanel:Hide()
    SB:RefreshAdminTabVisibility()

    RestorePosition()
    return main
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

-- The single place that decides what's visible for the current
-- isSettingsOpen/isAdminOpen state - called from every path that can change
-- either (opening/closing Settings or Admin, clicking any other tab, first
-- show), so search/grid visibility can never drift out of sync again.
-- Settings and Admin are mutually exclusive - each toggle (ToggleSettings/
-- ToggleAdmin above, and every category tab's own OnClick) already closes
-- the other one itself, at the moment it's clicked - NOT decided here, on
-- purpose: doing it here instead used to always force isSettingsOpen back
-- off whenever isAdminOpen was still true (regardless of which one the
-- player had actually just clicked), which made clicking Settings while
-- Admin was open silently do nothing.
function SB:RefreshMainWindow()
    if not main then return end
    if main.headerBar and main.headerBar.title then
        if isSettingsOpen then
            main.headerBar.title:SetText("Soundbook Settings")
        elseif isAdminOpen then
            main.headerBar.title:SetText("Raid Administration")
        else
            -- Refined further, per actual tab/filter state, by RefreshGrid
            -- below (it runs on every relevant change - tab switch, search
            -- text, tag filter pill - this is just a safe starting value).
            main.headerBar.title:SetText("Soundbook")
        end
    end
    RefreshTabIcons()
    RefreshTabs()
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
        main.pageBar:Hide()
        if keybindingsShortcutBtn then keybindingsShortcutBtn:Hide() end
        emptyHint:Hide()
        -- Search filters the sound grid, which isn't shown while Settings/
        -- Admin is open - the search box wouldn't do anything here. Default
        -- Output Channel is about sending SOUNDS too, same reasoning -
        -- explicit request: only shown where sounds actually are, never
        -- over Settings or the Admin panel.
        searchBox:Hide()
        outputChannelDD.button:Hide()
        if main.tagFilterBar then main.tagFilterBar:Hide() end
        for _, btn in ipairs(entryButtons) do btn:Hide() end
    else
        settingsPanel:Hide()
        adminPanel:Hide()
        main.pageBar:Show()
        searchBox:Show()
        outputChannelDD.button:Show()
        RefreshGrid() -- also shows/hides tagFilterBar per-tab, see there
    end
end

function SB:ShowMainWindow()
    if not main then BuildMainFrame() end
    InvalidateSortedListCache()
    main:Show()
    SB:RefreshMainWindow()
end

-- Onboarding destination: always open the actual starter sounds, never a
-- previously remembered tab, Settings panel, search result, tag filter, or
-- later page.
function SB:ShowDefaultSounds()
    if not main then BuildMainFrame() end
    isSettingsOpen = false
    isAdminOpen = false
    SB.db.ui.currentTab = "Legacy"
    SB.db.ui.currentPage[tostring("Legacy")] = 1
    main.searchPage = 1
    if searchBox then searchBox:SetText("") end
    wipe(SB.db.ui.tagFilters)
    InvalidateSortedListCache()
    main:Show()
    SB:RefreshMainWindow()
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

SB:On("TOGGLE_MAIN_UI", function() SB:ToggleMainWindow() end)

SB:On("FAVOURITES_CHANGED", function()
    if main and main:IsShown() then RefreshGrid() end
end)

SB:On("SOUND_DISPLAY_CHANGED", function()
    if main and main:IsShown() then RefreshGrid() end
end)

local function SetPlayingState(soundID)
    if playingStateTimer then
        playingStateTimer:Cancel()
        playingStateTimer = nil
    end
    playingSoundID = soundID
    if main and main:IsShown() and not isSettingsOpen and not isAdminOpen then RefreshGrid() end
    local duration = tonumber(SB.db and SB.db.settings and SB.db.settings.announceDuration) or 3
    if soundID and duration > 0 then
        playingStateTimer = C_Timer.NewTimer(duration, function()
            playingStateTimer = nil
            playingSoundID = nil
            if main and main:IsShown() and not isSettingsOpen and not isAdminOpen then RefreshGrid() end
        end)
    end
end

SB:On("LOCAL_SOUND_PLAYED", SetPlayingState)

SB:On("REMOTE_SOUND_PLAYED", SetPlayingState)

SB:On("PLAYBACK_STOPPED", function()
    SetPlayingState(nil)
end)

SB:On("CATEGORY_CHANGED", function()
    if main and main:IsShown() then RefreshTabIcons() end
end)

-- Keeps the Admin tab's own visibility in sync with the player's current
-- role - a Raid Lead can hand off lead, an Assist can be demoted, or the
-- player can simply leave the group entirely, all mid-session.
local adminVisibilityFrame = CreateFrame("Frame")
adminVisibilityFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
adminVisibilityFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
adminVisibilityFrame:SetScript("OnEvent", function()
    SB:RefreshAdminTabVisibility()
end)
