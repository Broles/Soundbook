-- Favorites.lua
--
-- Favourites are virtual references into SB.registry, indexed by fixed grid
-- positions 1..SB.MAX_FAVOURITES. Gaps are intentional: the player may place
-- sounds at 1, 3 and 5 while 2 and 4 remain empty. Empty positions are hidden
-- outside drag mode, but their indices remain available as drop targets.

local ADDON_NAME, SB = ...

local function List()
    return SB.db.favourites
end

local function SlotCount()
    return SB.MAX_FAVOURITES
end

-- Drops stale references (e.g. a sound that was removed from Sounds.lua)
-- without touching anything else, including their slot - a pruned slot
-- just becomes empty, it doesn't pull later slots forward. Safe to call
-- anytime.
function SB:PruneFavourites()
    local list = List()
    for i = 1, SlotCount() do
        if list[i] and not SB.registry[list[i]] then
            list[i] = nil
        end
    end
end

-- Returns all fixed positions; never use #/ipairs when rendering this table.
function SB:GetFavourites()
    SB:PruneFavourites()
    return List()
end

function SB:IsFavourite(soundID)
    local list = List()
    for i = 1, SlotCount() do
        if list[i] == soundID then return true end
    end
    return false
end

-- The slot (1..SB.MAX_FAVOURITES) `soundID` currently occupies, or nil if
-- it isn't a favourite at all.
function SB:GetFavouriteSlot(soundID)
    local list = List()
    for i = 1, SlotCount() do
        if list[i] == soundID then return i end
    end
    return nil
end

function SB:GetFavouriteCount()
    local list = List()
    local n = 0
    for i = 1, SlotCount() do
        if list[i] then n = n + 1 end
    end
    return n
end

local function FirstEmptySlot()
    local list = List()
    for i = 1, SlotCount() do
        if not list[i] then return i end
    end
    return nil
end

-- Returns true on success, or false plus a short reason string. Lands in
-- the first empty slot (lowest index) - a player who wants it somewhere
-- specific drags it there afterward (Mini Soundbook, see SB:MoveFavourite).
function SB:AddFavourite(soundID)
    if not SB.registry[soundID] then
        return false, "unknown sound"
    end
    if SB:IsFavourite(soundID) then
        return true
    end
    local slot = FirstEmptySlot()
    if not slot then
        SB:Print(string.format("Favourites full (%d/%d)", SB.MAX_FAVOURITES, SB.MAX_FAVOURITES))
        return false, "full"
    end

    List()[slot] = soundID
    local saved = SB:GetSoundSaved(soundID)
    saved.favourite = true
    if SB.AnalyticsSetFavourite then SB:AnalyticsSetFavourite(soundID, true) end
    SB:Fire("FAVOURITES_CHANGED")
    return true
end

-- Removal clears only this position; other deliberate placements stay put.
function SB:RemoveFavourite(soundID)
    local list = List()
    for i = 1, SlotCount() do
        if list[i] == soundID then
            list[i] = nil
            local saved = SB:GetSoundSaved(soundID)
            saved.favourite = false
            if SB.AnalyticsSetFavourite then SB:AnalyticsSetFavourite(soundID, false) end
            SB:Fire("FAVOURITES_CHANGED")
            return true
        end
    end
    return false
end

function SB:ToggleFavourite(soundID)
    if SB:IsFavourite(soundID) then
        SB:RemoveFavourite(soundID)
        return false
    else
        local ok = SB:AddFavourite(soundID)
        return ok
    end
end

-- Swaps the sound stored in an already-occupied slot for a different one,
-- without touching the slot itself (its keybind, keyed by slot number in
-- Keybindings.lua's SB.db.settings.favKeybinds and never by soundID, is
-- untouched by construction) or any other slot. Used by the New Sounds
-- window's "Favourites are full" replacement grid - explicit requirement:
-- replacing slot 7 must leave slot 7's own keybind attached, move nothing
-- else, and the displaced sound must simply stop being a favourite (not
-- get relocated to some other slot).
function SB:ReplaceFavourite(slot, soundID)
    if slot < 1 or slot > SlotCount() then return false end
    if not SB.registry[soundID] then return false end
    local list = List()
    local oldSoundID = list[slot]
    if oldSoundID == soundID then return true end

    list[slot] = soundID
    if oldSoundID then
        local oldSaved = SB:GetSoundSaved(oldSoundID)
        oldSaved.favourite = false
        if SB.AnalyticsSetFavourite then SB:AnalyticsSetFavourite(oldSoundID, false) end
    end
    local newSaved = SB:GetSoundSaved(soundID)
    newSaved.favourite = true
    if SB.AnalyticsSetFavourite then SB:AnalyticsSetFavourite(soundID, true) end
    SB:Fire("FAVOURITES_CHANGED")
    return true
end

-- Move into any of the 20 real positions. An occupied target swaps, while an
-- empty target leaves a deliberate gap at the old location.
function SB:MoveFavourite(fromIndex, toIndex)
    if fromIndex == toIndex then return false end
    if fromIndex < 1 or fromIndex > SlotCount() or toIndex < 1 or toIndex > SlotCount() then
        return false
    end
    local list = List()
    local moving = list[fromIndex]
    if not moving then return false end
    list[fromIndex] = list[toIndex]
    list[toIndex] = moving
    SB:Fire("FAVOURITES_CHANGED")
    return true
end
