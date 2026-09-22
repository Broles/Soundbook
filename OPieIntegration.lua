-- OPieIntegration.lua
--
-- Optional soft integration with OPie (a separate, very popular radial
-- action-binding addon - hold a key/mouse binding, a wheel of actions pops
-- up, release over one to trigger it). Soundbook never bundles or requires
-- OPie itself - the guard at the very top of AddSoundbookRings makes this
-- entire file a silent no-op if it isn't installed, same "nice to have if
-- present" pattern as Core.lua's LibSharedMedia font integration.
--
-- This registers Soundbook's sounds as pickable candidates in OPie's OWN
-- ring editor, under two separate categories - it does NOT create a ring
-- for you automatically. The player still opens OPie's own UI and builds
-- whatever custom ring(s) they want, same as they would for spells, items,
-- or any other addon that integrates this way (mounts, toys, etc.).
--
-- Built against OPie's "ActionBook" API (its documented extension point
-- for third-party addons: http://www.go-hero.net/opie/api), following the
-- same integration shape a real, shipping OPie integration (Narcissus'
-- own Bridge/Opie.lua) already uses in practice - RegisterActionType,
-- AugmentCategory, CreateActionSlot, NotifyObservers. This has NOT been
-- verified against a live OPie install by hand (no way to do that outside
-- the game) - if something about it doesn't work quite right in practice,
-- that's the first place to look.

local ADDON_NAME, SB = ...

local function AddSoundbookRings()
    if not (OPie and OPie.ActionBook) then return end
    local AB = OPie.ActionBook:compatible(2, 36)
    if not AB then return end

    local ALL_TYPE = "opie.Soundbook.AnySound"
    local FAV_TYPE = "opie.Soundbook.Favourite"
    local nameMapAll, nameMapFav = {}, {}

    -- Selecting a sound in the wheel behaves exactly like a plain left
    -- click in the Soundbook window itself (explicit request) - plays
    -- locally, then follows Settings -> Default Output / this sound's own
    -- per-sound override, same as SB:TriggerSound always has.
    local function PlaySelected(soundID)
        if SB.registry[soundID] then SB:TriggerSound(soundID) end
    end

    -- Shared tooltip hint for both categories - `true` (show a tooltip at
    -- all), 0 (no special tooltip type), icon, label, then three padding
    -- zeros ActionBook's own hint shape expects (screen offsets it doesn't
    -- need to be told), no anchor/OnTooltipShow override.
    local function GetHint(soundID)
        local info = SB.registry[soundID]
        if not info then return end
        return true, 0, SB:GetSoundIcon(soundID), SB:GetSoundDisplayName(soundID), 0, 0, 0
    end

    -----------------------------------------------------------------
    -- Category 1: every currently registered sound, across every
    -- category (Legacy/German Memes/Stammtisch/Category1/2) - exactly
    -- like OPie's own built-in spellbook/toybox pickers, you search and
    -- filter within OPie's own ring editor when building a ring; this
    -- just offers the full list of candidates.
    -----------------------------------------------------------------
    local function GetDescriptionAll(soundID)
        local info = SB.registry[soundID]
        if not info then return end
        return "Soundbook", SB:GetSoundDisplayName(soundID), SB:GetSoundIcon(soundID), soundID
    end

    local function CreateActionAll(soundID)
        if not SB.registry[soundID] then return end
        if not nameMapAll[soundID] then
            nameMapAll[soundID] = AB:CreateActionSlot(GetHint, soundID, "func", PlaySelected, soundID)
        end
        return nameMapAll[soundID]
    end

    AB:RegisterActionType(ALL_TYPE, CreateActionAll, GetDescriptionAll, 1)
    AB:AugmentCategory("Soundbook", function(_, add)
        for soundID in pairs(SB.registry) do
            add(ALL_TYPE, soundID)
        end
    end)

    -----------------------------------------------------------------
    -- Category 2: only the player's current 20 Favourite slots -
    -- explicit request, a second, separate, much shorter list for
    -- someone who'd rather build a ring from just their curated
    -- Favourites than search the entire library.
    -----------------------------------------------------------------
    local function GetDescriptionFav(soundID)
        local info = SB.registry[soundID]
        if not info or not SB:IsFavourite(soundID) then return end
        return "Soundbook Favourites", SB:GetSoundDisplayName(soundID), SB:GetSoundIcon(soundID), soundID
    end

    local function CreateActionFav(soundID)
        if not SB.registry[soundID] or not SB:IsFavourite(soundID) then return end
        if not nameMapFav[soundID] then
            nameMapFav[soundID] = AB:CreateActionSlot(GetHint, soundID, "func", PlaySelected, soundID)
        end
        return nameMapFav[soundID]
    end

    AB:RegisterActionType(FAV_TYPE, CreateActionFav, GetDescriptionFav, 1)
    AB:AugmentCategory("Soundbook Favourites", function(_, add)
        local favs = SB:GetFavourites()
        for i = 1, SB.MAX_FAVOURITES do
            -- Never use ipairs/# on this table - fixed positions with
            -- intentional gaps, see Favorites.lua.
            local soundID = favs[i]
            if soundID then add(FAV_TYPE, soundID) end
        end
    end)

    AB:NotifyObservers(ALL_TYPE)
    AB:NotifyObservers(FAV_TYPE)
end

-- OPie itself may still be loading its own saved data at ADDON_LOADED
-- time (same reasoning as Core.lua's BackfillAddedAt waiting for
-- PLAYER_LOGIN over companion addons) - PLAYER_LOGIN guarantees every
-- addon, OPie included, has fully finished loading.
SB:On("PLAYER_LOGIN", AddSoundbookRings)
