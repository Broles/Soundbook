-- Core.lua
-- Shared namespace, SavedVariables handling, compatibility wrappers, slash commands.
-- Target: WoW Classic - The Burning Crusade Anniversary (Interface 20506). No Retail-only APIs.

local ADDON_NAME, SB = ...
_G.Soundbook = SB -- convenience global, e.g. for /run Soundbook:PlaySound(...)

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------
SB.ADDON_NAME       = ADDON_NAME
SB.DB_VERSION       = 28
-- Read straight from the .toc's own "## Version:" line (single source of
-- truth, see Soundbook.toc) rather than a separately hand-typed constant
-- that could drift out of sync with a real release - used by "/sb doctor"
-- and the presence version broadcast. C_AddOns.GetAddOnMetadata is the
-- modern accessor; the plain global still exists on this client too, but
-- prefer the namespaced one where available since it's the one that keeps
-- working across future client updates.
SB.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))
    or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version"))
    or "?"
-- Physical category identifiers, fixed forever once shipped - "Legacy" and
-- "German Memes" are the two categories that ship pre-populated with the
-- addon's own starter sounds (Sounds\Legacy\, Sounds\German Memes\), 1/2
-- start out empty for the user to fill in themselves, exactly like the old
-- Category 3/4 did.
--
-- "Legacy"/"German Memes" replace the single old "Default" category
-- (explicit request, split into two browsable tabs) - see MigrateDB's
-- v17->v18 block below for what that split does and deliberately does NOT
-- carry over (a full reset for every sound that moved: Analytics history,
-- per-sound custom icon/mute, "New" tag status except 4 named sounds -
-- every moved sound gets a brand new soundID, same as any other category
-- change, see SoundRegistry.lua's SB.MakeSoundID).
SB.CATEGORIES       = { "Legacy", "German Memes", 1, 2 }
-- The main window's 20-entry page shows every possible favourite on one
-- comfortably spaced page, while the Mini keeps exactly 20 slots.
SB.MAX_FAVOURITES   = 20
-- Fixed forever, regardless of SB.PROTOCOL_VERSION below - the "V1" here is
-- just a name, not tied to the protocol's actual version. Addon message
-- prefixes are matched EXACTLY by RegisterAddonMessagePrefix/CHAT_MSG_ADDON;
-- changing this at all would stop every client from ever seeing another
-- client's messages at all, regardless of anything else in this file - the
-- single most destructive possible break, so this string must never change.
SB.COMM_PREFIX      = "SBOOKV1"       -- addon message prefix (<=16 chars)
-- The wire-format version THIS client SENDS with. Deliberately separate
-- from SB.GetAddonVersion() (the .toc's ## Version, purely cosmetic/display)
-- - two players on different addon versions must still be able to talk to
-- each other as long as the actual message FORMAT is compatible, so nothing
-- here is ever compared against addon version. Only bump this to a new
-- value when the wire format changes in a way older clients genuinely can't
-- parse at all - a purely additive change (new optional trailing field, new
-- command) doesn't need a bump, see PLAY/ACK's lenient parsing in
-- Communication.lua. See SB.SUPPORTED_PROTOCOL_VERSIONS just below for how a
-- future bump stays non-breaking for everyone still on the old one.
SB.PROTOCOL_VERSION = "V1"
-- Every wire-format version this client can still UNDERSTAND on receipt,
-- not just the one it sends with above - checked instead of a strict
-- `remoteVersion == SB.PROTOCOL_VERSION`, so bumping SB.PROTOCOL_VERSION in
-- a future update (once added here too) never stops this client from still
-- accepting an older sender's messages. Only V1 has ever existed so far;
-- when a genuine V2 is introduced, add `V2 = true` here (and switch
-- PROTOCOL_VERSION above once ready to actually start SENDING it) rather
-- than replacing this table's contents.
SB.SUPPORTED_PROTOCOL_VERSIONS = { V1 = true }
SB.DEFAULT_ICON     = "Interface\\Icons\\INV_Misc_QuestionMark"
-- The addon's own icon - minimap button and the Announcer's idle app icon
-- (file ID 133736, Interface/ICONS/INV_Misc_Book_04.blp).
SB.APP_ICON         = 133736
SB.SOUND_DIR        = "Sounds"        -- relative folder containing the physical category directories
SB.VALID_CHANNELS   = { Master = true, SFX = true, Music = true, Ambience = true, Dialog = true }

-- Explicit request: one consistent colour per "where did/does this sound
-- go", used EVERYWHERE a channel/source label is shown - Now Playing
-- (Announcer.lua), Settings' Send/Receive matrix row labels, the
-- Default Output Channel/Macro Output dropdowns' group headers
-- (Communication.lua's SB.ComputeOutputTargetOptions), SendMenu.lua's
-- popup group headers, and the chat notification lines (PrintReceived/
-- PrintMuted/PrintSent). RGB (0-1 floats, for SetTextColor) plus the
-- matching "rrggbb" hex (for |cffRRGGBB chat colour codes) are kept side
-- by side here so both stay in sync from a single definition rather than
-- two independently hand-picked palettes drifting apart.
-- SELF is not one of the requested colours (Direct/Friends/Guild/Raid) -
-- it's the neutral shade used for a locally-triggered ("(Self)") sound,
-- which was never part of that colour request.
SB.CHANNEL_COLOR = {
    DIRECT  = { r = 0.72, g = 0.55, b = 0.95, hex = "b88cf2" }, -- purple
    FRIENDS = { r = 0.55, g = 0.75, b = 0.98, hex = "8cbffa" }, -- pastel blue
    GUILD   = { r = 0.55, g = 0.88, b = 0.62, hex = "8ce09e" }, -- pastel green
    RAID    = { r = 0.98, g = 0.72, b = 0.48, hex = "fab87a" }, -- pastel orange
    -- Darkened (was 0.75/0.75/0.78, "bfbfc7") - explicit request: too close
    -- to Theme.TEXT (0.91/0.94/1.00, near-white) to tell apart from "ALL"
    -- (which keeps the normal text colour) at a glance in small UI text.
    SELF    = { r = 0.48, g = 0.48, b = 0.50, hex = "7a7a80" }, -- neutral grey, darker
}
-- Party is the SAME colour as Raid, always (explicit request - the two are
-- treated as one merged target everywhere, see SB.ResolveGroupChannel in
-- Communication.lua) - kept as its own key purely so a direct
-- SB.CHANNEL_COLOR.PARTY lookup (or the "Party" label below) still resolves
-- instead of silently falling through to nil/SELF grey.
SB.CHANNEL_COLOR.PARTY = SB.CHANNEL_COLOR.RAID
-- Looks a colour up by the human-readable label string used throughout
-- the addon ("Direct"/"Friend"/"Friends"/"Guild"/"Raid"/"Party"/"Self") -
-- singular "Friend" (CHANNEL_LABEL's own WHISPER mapping in
-- Communication.lua) and plural "Friends" (the dropdown/SendMenu group
-- header) both resolve to the same FRIENDS colour. Falls back to SELF's
-- neutral grey for anything unrecognized rather than erroring.
local CHANNEL_COLOR_BY_LABEL = {
    Direct = SB.CHANNEL_COLOR.DIRECT,
    Friend = SB.CHANNEL_COLOR.FRIENDS,
    Friends = SB.CHANNEL_COLOR.FRIENDS,
    Guild = SB.CHANNEL_COLOR.GUILD,
    Raid = SB.CHANNEL_COLOR.RAID,
    Party = SB.CHANNEL_COLOR.PARTY,
    Self = SB.CHANNEL_COLOR.SELF,
}
function SB.GetChannelColor(label)
    return CHANNEL_COLOR_BY_LABEL[label] or SB.CHANNEL_COLOR.SELF
end

-- Sound files may be .ogg, .mp3, or .wav - WoW's PlaySoundFile supports all
-- three natively (.ogg is in fact Blizzard's own native format). Since the
-- client can't list folder contents, Sounds.lua never specifies an
-- extension; SoundPlayer.lua tries these in order and remembers whichever
-- one actually exists for a given sound. Order matters only for the very
-- first play of a sound that has files with more than one of these
-- extensions sharing the same base name (unlikely, but first match wins).
SB.SOUND_EXTENSIONS = { "ogg", "mp3", "wav" }

SB.DEFAULT_CATEGORY_INFO = {
    -- Was the same icon "Default" always used (INV_Misc_Gift_01) - explicit
    -- request to switch to an actual book icon instead ("auf das Buch
    -- wieder ändern"). See MigrateDB's v19->v20 block for how this reaches
    -- an already-updated install too.
    ["Legacy"] = { name = "Legacy", icon = "Interface\\Icons\\INV_Misc_Book_09" },
    -- Was icon fileID 13591, then Spell_Holy_LesserHeal - both turned out
    -- blank in-game on this client. Switched to the plain "Heal" spell
    -- icon (Spell_Holy_Heal) instead, explicit request - this one is
    -- already PROVEN to render on this exact client (it's also the
    -- per-sound icon for "Thats me" in Sounds.lua, no reported issue with
    -- it there). See MigrateDB's v19->v20 block for how this reaches an
    -- already-updated install too.
    ["German Memes"] = { name = "German Memes", icon = "Interface\\Icons\\Spell_Holy_Heal" },
    [1] = { name = "Category 1", icon = "Interface\\Icons\\INV_Misc_GroupLooking" },
    -- Was INV_Misc_Note_01 - same icon the Mini Soundbook's idle "Ready"
    -- status uses (FavouritesWindow.lua's ShowIdleStatus), and used to
    -- also be "Mir Egal"'s sound icon until that collision got flagged
    -- explicitly - fixing this one too, same reasoning: a category tab
    -- icon showing up disguised as "nothing is playing right now" is
    -- exactly the kind of double-booking to avoid.
    [2] = { name = "Category 2", icon = "Interface\\Icons\\INV_Misc_Bag_08" },
}
-- Two generic "misc star" item-icon guesses turned out not to exist on
-- this client. Spell_Nature_StarFall is the icon of an actual, currently
-- shipping TBC Druid talent (Starfall) - a real spell icon actively used
-- in-game rather than a guessed item icon name, which makes it a much
-- safer bet to actually exist.
-- Was Spell_Nature_StarFall (a real icon, but reads as a blue/purple
-- meteor shower, not the "big yellow star" explicitly asked for later) -
-- Starfire's icon is a warmer gold-toned radiant star burst, a closer
-- visual match. Same "best-effort, swap if it turns out blank" caveat as
-- every icon guess in this file - not verified in a screenshot.
SB.FAVOURITES_ICON = "Interface\\Icons\\Spell_Arcane_StarFire"
SB.SETTINGS_ICON    = "Interface\\Icons\\Trade_Engineering"
-- Raid Admin tab icon (only ever shown to a current Raid Leader/Assist or
-- Party Leader, see UI.lua's BuildAdminTabButton) - a plain shield, reads as
-- "protect the raid" rather than any specific class/spell.
SB.ADMIN_ICON       = "Interface\\Icons\\INV_Shield_04"
-- The "Stammtisch" (private sounds) tab's name/icon are fixed, not
-- user-editable like the numbered categories - same tier as FAVOURITES_ICON above.
-- Best-guess beer mug icon (untested in-game, like the two earlier
-- FAVOURITES_ICON guesses that turned out wrong before Spell_Nature_
-- StarFall) - if it doesn't render, swap the path here for another.
SB.PRIVATE_TAB_NAME = "Stammtisch"
SB.PRIVATE_TAB_ICON = "Interface\\Icons\\Spell_Misc_Drink"
-- The virtual "Hide" category's own icon (explicit request) - the Rogue
-- ability Vanish, matching "things that disappear from view".
SB.HIDE_ICON        = "Interface\\Icons\\Ability_Vanish"

-- Font choices offered under Settings -> General / Favourites Window. Kept
-- to the handful of typefaces the WoW client itself always ships (every
-- locale, every currently supported version), rather than pulling in a
-- shared-media library or asking users to drop font files somewhere - so
-- every choice here is guaranteed to actually exist, with nothing to go
-- missing or need reinstalling.
SB.AVAILABLE_FONTS = {
    { name = "Friz Quadrata (Default)", path = "Fonts\\FRIZQT__.TTF" },
    { name = "Arial Narrow",            path = "Fonts\\ARIALN.TTF" },
    { name = "Skurri",                  path = "Fonts\\SKURRI.TTF" },
    { name = "Morpheus",                path = "Fonts\\MORPHEUS.TTF" },
}

-- Text size, offered as a vague "smaller <-> bigger" slider rather than a
-- literal point size (which wouldn't mean much across the very different
-- font objects/contexts this scales) - each step is a multiplier applied
-- on top of whatever size the text would normally be.
SB.FONT_SCALE_STEPS = {
    { mult = 0.80, label = "Smaller" },
    { mult = 0.90, label = "Small" },
    { mult = 1.00, label = "Normal" },
    { mult = 1.15, label = "Large" },
    { mult = 1.30, label = "Larger" },
}

function SB.FontScaleStepIndex(mult)
    mult = mult or 1
    for i, step in ipairs(SB.FONT_SCALE_STEPS) do
        if math.abs(step.mult - mult) < 0.001 then return i end
    end
    return 3 -- "Normal"
end

------------------------------------------------------------------------
-- Soundbook's own font objects (main Soundbook window, Edit window,
-- Settings panel). These are copies of Blizzard's shared GameFontXxx
-- objects - never the originals - so changing Soundbook's font (see
-- SB:RefreshMainFont below) never touches any other addon's or Blizzard's
-- own UI text, only Soundbook's. The Mini Soundbook is handled separately
-- (Announcer.lua's own SB:RefreshAnnouncerFont) since its text already
-- resizes dynamically with the window and sets its font directly rather
-- than via a shared object.
------------------------------------------------------------------------
SB.Fonts = {}

local FONT_OBJECT_TEMPLATES = {
    Normal         = "GameFontNormal",
    NormalLarge    = "GameFontNormalLarge",
    -- UI/UX polish pass: one shared "Title" tier, used by every screen's
    -- primary heading (Main's "Soundbook", the Settings/Keybindings context
    -- label that replaces it, and Edit Sound's own header) instead of each
    -- one picking its own size/colour - explicit requirement: "same title
    -- hierarchy... one primary title treatment across these screens".
    -- Based on NormalLarge (not a wholly separate template) so it inherits
    -- the same typeface, just meaningfully bigger - see the baseSize boost
    -- right below, applied once here rather than through a second CopyFontObject.
    Title          = "GameFontNormalLarge",
    Highlight      = "GameFontHighlight",
    HighlightSmall = "GameFontHighlightSmall",
    DisableSmall   = "GameFontDisableSmall",
}

-- Per-tier size boost applied once, on top of whatever the copied Blizzard
-- template's own size already is - keeps FONT_OBJECT_TEMPLATES itself a
-- plain name->template map instead of every tier needing its own bespoke
-- creation branch.
-- 1.5x GameFontNormalLarge's 16px baseline lands the shared Title tier at
-- the requested ~24px (at normal font scale/UI scale) - explicit
-- requirement, targeted correction round.
local BASE_SIZE_MULT = { Title = 1.50 }

for key, blizzardTemplate in pairs(FONT_OBJECT_TEMPLATES) do
    local obj = CreateFont("Soundbook" .. key .. "Font")
    local template = _G[blizzardTemplate]
    if template then
        obj:CopyFontObject(template)
    end
    -- Captured once, before any scaling is ever applied - SB:RefreshMainFont
    -- always computes from this original size, never from whatever size is
    -- currently live on the object, so repeated scale changes never compound.
    local _, size = obj:GetFont()
    obj.baseSize = math.floor((size or 12) * (BASE_SIZE_MULT[key] or 1) + 0.5)
    SB.Fonts[key] = obj
end

-- Optional LibSharedMedia-3.0 integration: if ANY other installed addon
-- already loads LibSharedMedia (extremely common - ElvUI, WeakAuras,
-- Details, SharedMedia itself, ...) and has fonts registered in it,
-- Soundbook lists those too, on top of the 4 client-shipped fonts in
-- SB.AVAILABLE_FONTS. Soundbook never bundles or requires the library
-- itself - it only asks LibStub for the shared instance if one already
-- exists (the `true` "silent" argument means this returns nil instead of
-- erroring when nothing has loaded it), so with no such addon installed
-- this just silently falls back to the 4 built-ins. Queried fresh on every
-- call (not cached) so a font registered later in the session still shows
-- up next time the picker is opened.
function SB.GetAvailableFonts()
    local list = {}
    local seenPaths = {}
    for _, f in ipairs(SB.AVAILABLE_FONTS) do
        table.insert(list, f)
        seenPaths[f.path] = true
    end

    local LibStub = _G.LibStub
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM and LSM.List and LSM.Fetch then
        local ok, names = pcall(LSM.List, LSM, "font")
        if ok and type(names) == "table" then
            for _, name in ipairs(names) do
                local okFetch, path = pcall(LSM.Fetch, LSM, "font", name)
                if okFetch and type(path) == "string" and path ~= "" and not seenPaths[path] then
                    seenPaths[path] = true
                    table.insert(list, { name = name, path = path })
                end
            end
        end
    end

    return list
end

-- Re-applies the chosen typeface + text size (Settings -> General) to
-- every one of Soundbook's own font objects. Size is always computed from
-- each object's original obj.baseSize * the current scale multiplier
-- (never from whatever's currently live), so calling this repeatedly as
-- the user picks different settings never compounds.
function SB:RefreshMainFont()
    local s = SB.db and SB.db.settings
    local path = (s and s.mainFont) or SB.AVAILABLE_FONTS[1].path
    local scale = (s and s.mainFontScale) or 1
    for _, obj in pairs(SB.Fonts) do
        local _, _, flags = obj:GetFont()
        -- Floor raised from 6 to 9 (explicit bug report: tag pills - the
        -- smallest text in the addon, DisableSmall - looked like a
        -- different typeface than the rest of Soundbook). Many custom/
        -- LibSharedMedia TTF fonts silently fall back to WoW's default
        -- font once rendered below roughly this size, even though
        -- SetFont was still given the right path - a known client quirk,
        -- not a bug in which font object got which path. DisableSmall's
        -- own baseSize (~10, from GameFontDisableSmall) was already
        -- borderline at normal scale and could dip under that threshold
        -- at a reduced Text Size setting; 9 keeps it readable as a small
        -- pill label while staying clear of that fallback zone for most
        -- fonts.
        local size = math.max(9, math.floor((obj.baseSize or 12) * scale + 0.5))
        obj:SetFont(path, size, flags or "")
    end
end

------------------------------------------------------------------------
-- Tiny event bus so modules don't need to care about file/load order.
-- Modules call SB:OnReady(fn) to run code once SavedVariables are ready,
-- and SB:On(event, fn) / SB:Fire(event, ...) for everything else.
------------------------------------------------------------------------
local listeners = {}
local readyCallbacks = {}
local dbIsReady = false

function SB:On(event, fn)
    listeners[event] = listeners[event] or {}
    table.insert(listeners[event], fn)
end

function SB:Fire(event, ...)
    local list = listeners[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then
            SB:Print("|cffff5555Error|r in " .. event .. " handler: " .. tostring(err))
        end
    end
end

function SB:OnReady(fn)
    if dbIsReady then
        local ok, err = pcall(fn)
        if not ok then SB:Print("|cffff5555Error|r: " .. tostring(err)) end
    else
        table.insert(readyCallbacks, fn)
    end
end

------------------------------------------------------------------------
-- Chat output
------------------------------------------------------------------------
function SB:Print(msg)
    local frame = DEFAULT_CHAT_FRAME
    if frame then
        frame:AddMessage("|cff33ff99Soundbook|r: " .. tostring(msg))
    end
end

------------------------------------------------------------------------
-- Compatibility wrappers
-- TBC Anniversary runs on the shared modern client, but we defensively
-- feature-detect everything instead of assuming Retail-only behaviour.
------------------------------------------------------------------------

-- Frames that need SetBackdrop must inherit "BackdropTemplate" on every
-- currently supported client (Classic era, TBC/Wrath/Cata Classic, Retail).
function SB.CreateFrame(frameType, name, parent, template)
    if template and template ~= "" then
        template = template .. ",BackdropTemplate"
    else
        template = "BackdropTemplate"
    end
    return CreateFrame(frameType, name, parent, template)
end

function SB.CreatePlainFrame(frameType, name, parent, template)
    return CreateFrame(frameType, name, parent, template)
end

-- Addon message sending/registration: modern API lives under C_ChatInfo,
-- but we fall back to the legacy globals in case they are ever needed.
function SB.RegisterAddonPrefix(prefix)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(prefix)
    elseif RegisterAddonMessagePrefix then
        RegisterAddonMessagePrefix(prefix)
    end
    -- If neither exists, addon messages still typically work without
    -- registration on older API levels; we simply skip silently.
end

function SB.SendAddonMessage(prefix, text, chatType, target)
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        return C_ChatInfo.SendAddonMessage(prefix, text, chatType, target)
    elseif SendAddonMessage then
        return SendAddonMessage(prefix, text, chatType, target)
    end
    return false
end

-- Friend list iteration: prefer C_FriendList (current API), fall back to
-- the old globals used by earlier Classic client builds.
function SB.GetNumFriends()
    if C_FriendList and C_FriendList.GetNumFriends then
        return C_FriendList.GetNumFriends()
    elseif GetNumFriends then
        return GetNumFriends()
    end
    return 0
end

-- Group member count, unified across party and raid: prefer the modern
-- combined GetNumGroupMembers (includes the player, works for both party
-- and raid - this is what every call site in this file was written
-- against). Older Classic-lineage clients split this into
-- GetNumRaidMembers/GetNumPartyMembers, where GetNumPartyMembers excludes
-- the player, hence the "+1" below to match GetNumGroupMembers' semantics.
function SB.GetNumGroupMembers()
    if GetNumGroupMembers then
        return GetNumGroupMembers()
    end
    if GetNumRaidMembers then
        local raidCount = GetNumRaidMembers()
        if raidCount > 0 then
            return raidCount
        end
    end
    if GetNumPartyMembers then
        local partyCount = GetNumPartyMembers()
        if partyCount > 0 then
            return partyCount + 1
        end
    end
    return 0
end

-- Whether the player currently has game audio effectively muted: either the
-- master "Disable All Sound" option, or the Master Volume slider sitting at
-- 0. Read-only - Soundbook never sets/changes either CVar (see README's
-- "Known limitation: per-sound volume"); this only checks them so it can
-- offer a chat fallback for a remote sound you otherwise wouldn't hear at
-- all (see Communication.lua's REMOTE_SOUND_PLAYED listener).
function SB.IsSoundMuted()
    if not GetCVar then return false end
    if GetCVar("Sound_EnableAllSound") == "0" then return true end
    local masterVol = tonumber(GetCVar("Sound_MasterVolume"))
    if masterVol and masterVol <= 0 then return true end
    return false
end

-- Short display/legacy form only. Security-sensitive comparisons and new
-- storage use Validation.lua's realm-aware SB.PlayerKey instead.
function SB.NormalizeName(name)
    if not name then return nil end
    return (name:match("^([^%-]+)")) or name
end

function SB.GetFriendInfoByIndex(index)
    if C_FriendList and C_FriendList.GetFriendInfoByIndex then
        local info = C_FriendList.GetFriendInfoByIndex(index)
        if info then
            return info.name, info.connected
        end
        return nil
    elseif GetFriendInfo then
        local name, _, _, _, connected = GetFriendInfo(index)
        return name, connected
    end
    return nil
end

-- Whether `name` is on the player's own WoW Friends list (online or not -
-- membership, not presence). Used by Communication.lua to let a direct,
-- single-person send (SendMenu.lua's "select one player" rows) through a
-- Raid Admin "Mute All" specifically when sender and receiver are mutual
-- friends - explicit request: friends can still privately send to each
-- other even while a raid-wide mute is active; nobody else can use that
-- same feature as a workaround to bypass a group/raid/guild mute.
function SB:IsFriend(name)
    local requestedKey = SB.PlayerKey and SB.PlayerKey(name) or SB.NormalizeName(name)
    if not requestedKey then return false end
    local n = SB.GetNumFriends()
    for i = 1, n do
        local friendName = SB.GetFriendInfoByIndex(i)
        local friendKey = SB.PlayerKey and SB.PlayerKey(friendName) or SB.NormalizeName(friendName)
        if friendKey and friendKey == requestedKey then
            return true
        end
    end
    return false
end

-- Whether `name` is on the player's own Ignore list. Same enumerate-and-
-- match approach as SB:IsFriend above, deliberately - the older
-- GetNumIgnores/GetIgnoreName globals are available across every
-- supported client (Classic through Retail), unlike a name-keyed
-- C_FriendList.IsIgnored which isn't universally present on this addon's
-- target clients (see this file's own header: Classic - TBC Anniversary).
-- Only ever tells us "have I ignored them", never the reverse (WoW has no
-- API for "who has ignored me") - Communication.lua's Ignore-blocking
-- enforcement (IsPlayableRightNow/HandlePlayCommand/SendToPlayerSilent/
-- SendToFriends) is built entirely around that asymmetry.
function SB:IsIgnored(name)
    local requestedKey = SB.PlayerKey and SB.PlayerKey(name) or SB.NormalizeName(name)
    if not requestedKey then return false end
    local n = GetNumIgnores and GetNumIgnores() or 0
    for i = 1, n do
        local ignoreName = GetIgnoreName and GetIgnoreName(i)
        local ignoreKey = ignoreName and (SB.PlayerKey and SB.PlayerKey(ignoreName) or SB.NormalizeName(ignoreName))
        if ignoreKey and ignoreKey == requestedKey then
            return true
        end
    end
    return false
end

------------------------------------------------------------------------
-- SavedVariables defaults + migration
------------------------------------------------------------------------
local function ApplyDefaults(tbl, defaults)
    for k, v in pairs(defaults) do
        if type(v) == "table" then
            if type(tbl[k]) ~= "table" then tbl[k] = {} end
            ApplyDefaults(tbl[k], v)
        elseif tbl[k] == nil then
            tbl[k] = v
        end
    end
    return tbl
end

local function GetDefaultDB()
    return {
        dbVersion = SB.DB_VERSION,
        sounds = {},      -- [soundID] = { icon, favourite, muted, volume }
        favourites = {},  -- fixed positions 1..20; gaps are intentional
        history = {},     -- newest-first last 10 successfully received sounds
        -- [normalizedName] = { lastSeen = <time() epoch seconds> } - every
        -- player ever confirmed (via a HELLO/HELLOACK presence ping, or any
        -- other addon message) to have Soundbook installed. Built by
        -- Communication.lua, consumed by SendMenu.lua's right-click "send
        -- to" list. Never expired here - the menu itself only ever shows
        -- someone who's also currently online in a reachable group, so a
        -- stale entry for someone who's since gone offline/left just never
        -- surfaces rather than needing active cleanup.
        knownUsers = {},
        categories = {
            ["Legacy"] = { name = SB.DEFAULT_CATEGORY_INFO["Legacy"].name, icon = SB.DEFAULT_CATEGORY_INFO["Legacy"].icon },
            ["German Memes"] = { name = SB.DEFAULT_CATEGORY_INFO["German Memes"].name, icon = SB.DEFAULT_CATEGORY_INFO["German Memes"].icon },
            [1] = { name = SB.DEFAULT_CATEGORY_INFO[1].name, icon = SB.DEFAULT_CATEGORY_INFO[1].icon },
            [2] = { name = SB.DEFAULT_CATEGORY_INFO[2].name, icon = SB.DEFAULT_CATEGORY_INFO[2].icon },
        },
        settings = {
            -- Which additional channels a locally-triggered sound is also
            -- broadcast to. Several can be enabled at once (e.g. Friends AND
            -- Raid). Local playback always happens regardless of these.
            -- RAID covers Party too (see SB.ResolveGroupChannel,
            -- Communication.lua) - no separate PARTY key any more.
            broadcastModes = { FRIENDS = true, RAID = true, GUILD = true },
            allowOverlap      = false,
            -- Suppress ALL playback (local and remote) while in combat /
            -- in a boss encounter specifically - two separate switches
            -- since "any fight" and "a boss pull" are different lines
            -- people want to draw. On (true) by default - nothing is
            -- suppressed unless you turn one off.
            allowInCombat     = true,
            allowInEncounter  = true,
            channel           = "Master",
            -- Settings -> Sound Routing -> "Default Output Channel" -
            -- what a plain click on a Mini Soundbook favourite sends to,
            -- besides always playing locally. "ALL" (default) is the
            -- existing behaviour - whatever's enabled under "Broadcast
            -- sounds to:" above. Otherwise one specific channel ("GUILD"/
            -- "PARTY"/"RAID"/"FRIENDS", bypassing those checkboxes for just
            -- this click) or one specific person ("PLAYER:<name>", from
            -- Friends/Guild/Raid) - see Communication.lua's
            -- SB:DispatchDefaultOutput.
            defaultOutputTarget = "ALL",
            showFavouritesWindow = true,
            receiveFriends    = true,
            -- No separate receiveParty any more - receiveRaid covers both
            -- (see SB.ResolveGroupChannel, Communication.lua).
            receiveRaid       = true,
            receiveGuild      = true,
            -- Direct-targeted sends (SendMenu's "send to one specific
            -- person" - a Friend, a Guild member, whoever) are their own
            -- receive toggle, separate from receiveFriends above even
            -- though both travel as WHISPER - explicit request.
            receiveDirect     = true,
            -- "Mute all receiving" (Settings page, below the Send/Receive
            -- table) - temporarily or indefinitely zeroes out the four
            -- receiveX flags above, remembering their prior state so
            -- Unmute/expiry restores it exactly. Persisted on purpose
            -- (survives /reload and a full client restart) - unlike the
            -- Raid Admin mute (never persisted, reset by leaving group)
            -- there's no group-leave event to naturally clear this, so a
            -- real 30/60 minute mute needs to survive a reload to mean
            -- anything - see Communication.lua's SB:StartReceiveMute.
            receiveMute = {
                active = false,
                -- expiresAt (time() epoch seconds, absent = indefinite) and
                -- durationMinutes (30/60, absent = indefinite) are only
                -- ever set at runtime, never here.
                previous = { FRIENDS = true, PARTY = true, RAID = true, GUILD = true, DIRECT = true },
            },
            -- Individual Mute (Mini Soundbook mute button, right-click) -
            -- [normalizedName] = time() epoch seconds the mute expires at.
            -- Only ever populated at runtime (SB:MutePlayerFor/UnmutePlayer,
            -- Communication.lua) - time(), not GetTime(), specifically
            -- because this must survive a /reload or client restart the
            -- same way receiveMute's own expiresAt above does.
            mutedPlayers = {},
            remoteCooldown    = 1.0,
            -- FIFO queue/spooler for incoming remote sounds (Settings ->
            -- Remote Playback -> "Sound Queue / Spooler") - see
            -- Communication.lua's Anti-Spam section for the full mechanism.
            -- ON (default): sounds beyond the rate limit wait in a small
            -- queue instead of being lost. OFF: no queue at all, anything
            -- over the limit is discarded immediately, never caught up on
            -- later.
            soundQueueEnabled = true,
            -- Three independent chat-notification toggles (Settings ->
            -- Remote Playback) - see Communication.lua for the actual
            -- printing/formatting:
            --   notifyOnMuted        - a remote sound played for you
            notifyOnMuted     = true,
            --   notifyMutedAttempts  - a remote sound was BLOCKED by a
            --                          per-sound mute specifically. Does
            --                          NOT cover a disabled "Receive Sounds
            --                          from" channel - RECEIVING a sound
            --                          through a disabled channel is still
            --                          fully silent on this side always, no
            --                          setting re-enables a local
            --                          notification for it (explicit
            --                          request) - see OnAddonMessage's PLAY
            --                          handling in Communication.lua. The
            --                          SENDER can learn about it too, but
            --                          that's not this setting either - a
            --                          separate "RXOFFACK" reply (distinct
            --                          from a MUTEACK - this isn't a mute),
            --                          only ever shown to a sender with
            --                          Debug Mode on; a normal sender sees
            --                          nothing, same as before this existed.
            notifyMutedAttempts = true,
            --   notifyFriendReceipts - who received/played sounds you sent -
            --                          off by default (adds a reply message
            --                          for every sound you receive from
            --                          someone else while this is on)
            notifyFriendReceipts = true,
            -- Anonymous usage analytics (Analytics.lua, /sb analytics) - on
            -- by default (explicit decision), but a single switch to fully
            -- stop both collecting and transmitting for anyone who wants
            -- out entirely. Never stores/sends character names, GUIDs,
            -- realms, guild names or BattleTags - see Analytics.lua's own
            -- file header for the full privacy design.
            analyticsEnabled = true,
            -- How the category and Stammtisch sound grids are
            -- ordered - "popularity" (default, explicit decision) ranks by
            -- community-wide Analytics play counts (most-played first, ties
            -- and no-data sounds alphabetically at the end); "alphabetical"
            -- keeps the plain declaration order from Sounds.lua, unchanged.
            -- Never applies to the Favourites grid - those are deliberate,
            -- manually placed/dragged positions. See Analytics.lua's
            -- SB.SortSoundIDsBySetting, used by UI.lua's GetTabSoundList.
            sortMode = "popularity",
            -- Typeface for the main Soundbook window (incl. Edit window and
            -- the Settings panel) and, separately, the Mini Soundbook - see
            -- SB.AVAILABLE_FONTS above.
            mainFont          = SB.AVAILABLE_FONTS[1].path,
            miniFont          = SB.AVAILABLE_FONTS[1].path,
            -- Text size multipliers (SB.FONT_SCALE_STEPS), same split as
            -- the fonts above: main Soundbook vs. Mini Soundbook.
            mainFontScale     = 1,
            miniFontScale     = 1,
            -- How long the Favourites mini-window's "Now Playing" display
            -- stays up, for both sent and received sounds (0 = disabled).
            announceDuration  = 3,
            -- [slotIndex] = raw WoW binding-key string ("CTRL-A" etc., same
            -- format GetBindingKey/SetOverrideBindingClick use), only ever
            -- for slots 1..SB.KEYBIND_FAV_SLOT_COUNT - see Keybindings.lua.
            -- A CUSTOM in-addon keybind system, not Blizzard's native
            -- Bindings.xml: that route was tried first and abandoned after
            -- being confirmed live, repeatedly, across several fix attempts
            -- (XML declaration, per-binding header attribute, reduced
            -- binding count) to throw "Unrecognized XML: Binding" on this
            -- specific client build regardless - never got a single
            -- <Binding> element recognized at all, so this addon owns the
            -- whole key-capture + dispatch mechanism itself instead.
            favKeybinds       = {},
            -- Settings -> "Favourite Keybinds" section - collapsed by
            -- default (10-20 buttons is a lot of vertical space most
            -- players never need open), state remembered across sessions.
            favKeybindPanelCollapsed = true,
            -- One-time first-run intro popup (Soundbook 1.9.1) - explains
            -- local playback/sending/Favourites once, then never shows
            -- itself again unless manually restarted from Settings, next
            -- to Debug. Defaults to true (already "seen"/skip) so plain
            -- ApplyDefaults naturally leaves any EXISTING install alone -
            -- a first-run flow meant for brand-new players has no business
            -- popping up for someone already using the addon. The
            -- ADDON_LOADED handler below explicitly flips this to false
            -- ONLY on SB.isFreshInstall, right after building a real
            -- GetDefaultDB() from scratch.
            introSeen         = true,
            -- "New Sounds" popup (NewSoundsWindow.lua) - off by default
            -- (i.e. the popup IS shown) until a player explicitly opts out
            -- via its own checkbox or Settings' "Latest Sound Updates".
            newSoundsPopupOptOut = false,
            debug             = false,
        },
        ui = {
            mainPos   = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 },
            -- Explicit request: the default size for a fresh install is the
            -- window's own MINIMUM resizable size (560x560, see UI.lua's
            -- SetResizeBounds/SetMinResize) now that it can be resized at
            -- all - starting small and letting a player grow it themselves
            -- rather than opening already-larger-than-necessary.
            mainWidth = 560,
            mainHeight = 560,
            -- Top-right screen corner by default, deliberately away from
            -- where the main (centered) Soundbook window opens, so the two
            -- don't start out overlapping each other.
            favPos    = { point = "TOPRIGHT", relPoint = "TOPRIGHT", x = -60, y = -80 },
            favScale  = 1.0,
            favLocked = false,
            favShown  = true,
            favWidth  = 0,  -- 0 = not yet resized, use the computed default
            favHeight = 0,
            favAlphaIdle  = 100, -- opacity (%) while not hovering the Favourite window
            favAlphaHover = 100, -- opacity (%) while hovering it
            currentTab = "favourites",
            currentPage = {}, -- [tab] = pageNumber
            -- [tagKey] = true for an active tag filter pill (New/Trending/
            -- Popular/Community Favourite) - explicit request: an OR
            -- across whichever are active, searching every category
            -- regardless of currentTab, same as a text search already
            -- does. Empty = no filter, normal per-tab browsing.
            tagFilters = {},
            minimap = { hide = false, angle = 215 },
            -- Soundbook 3.0 - the Announcer HUD (Announcer.lua) that
            -- replaces the old Mini Soundbook/Favourites window. A separate
            -- table from the legacy favPos/favShown/... fields above (never
            -- deleted - see MigrateDB's v26->v27 block, which seeds these
            -- FROM the old fields once, for anyone upgrading).
            announcer = {
                pos = { point = "TOPRIGHT", relPoint = "TOPRIGHT", x = -60, y = -80 },
                shown = true,
                alphaIdle = 100,
                alphaHover = 100,
                -- Announcer Size (targeted correction round: split into two
                -- independent scales - this one covers ONLY the Announcer's
                -- own visuals: the Preview, Now Playing/Last Sound, and the
                -- announcer text - never the favourite-area UI. See
                -- favScale below for that. Both 0.5-2.0 (50%-200%).
                scale = 1.0,
                -- Mini Soundbook Size - covers ONLY the favourite-area UI
                -- (favourite item/control dimensions, icons, sound-name
                -- text, dropdown/name-area width) - never the Announcer
                -- itself. A brand-new install gets 1.0 directly here;
                -- an upgrading install's existing `scale` is copied into
                -- this field once by MigrateDB (v27->v28) instead, so
                -- nobody's favourites silently change size on upgrade.
                favScale = 1.0,
                -- Mini Soundbook activation mode (explicit requirement):
                -- false (default, fresh installs AND existing users
                -- missing the key - ApplyDefaults' own generic backfill
                -- already handles both cases identically, no separate
                -- migration block needed) = the expanded Mini Soundbook
                -- (favMenu) only ever opens via the existing left-click
                -- interaction; true = hovering the icon opens it too, no
                -- click required. Shared verbatim between Quick Options'
                -- own checkbox and Settings -> Mini's - both read/write
                -- this exact field, never a separate copy.
                openOnHover = false,
            },
            -- Global layout lock (3.0 shell) - separate concept from the
            -- Announcer's own `locked` above (that one only ever existed as
            -- the old Mini window's lock); this one is meant to eventually
            -- also cover the 3.0 Main shell once it exists.
            layoutLocked = false,
            -- Popout Direction (explicit request) - one shared setting for
            -- every surface that opens off the permanent Soundbook icon
            -- (Favourites, Quick Options, the Announcer banner itself, and
            -- its drag/resize preview - see Announcer.lua's
            -- SB.ResolvePopoutDirection/SB.PositionRelativeToIcon), so they
            -- can never independently pick contradictory sides for the same
            -- icon position. "AUTO" resolves from the icon's current screen
            -- region every time it's needed; the other four values pin one
            -- side regardless of where the icon sits.
            popoutDirection = "AUTO", -- "AUTO" | "RIGHT" | "LEFT" | "UP" | "DOWN"
            -- [categoryKey] = true/false, keyed by the STABLE category
            -- identifier (SB.CATEGORIES entries / "favourites" / private
            -- tab name), never a display name - see 3.0 spec section 85.
            categoryCollapsed = {},
            -- BUGFIX (3.0 QA round) - this was missing from the defaults
            -- table entirely, even though Database.lua's SanitizeDatabase
            -- has always built/expected ui.outputRail (the right-side
            -- broadcast tabs' multi-select state). Every brand-new
            -- player's very first RefreshBroadcastTabs() call crashed on
            -- `SB.db.ui.outputRail` itself being nil - an upgrading
            -- player never hit this since MigrateDatabaseInPlace/
            -- SanitizeDatabase always run for them, which is why it went
            -- unnoticed until now. Deliberately left EMPTY here, same as
            -- tagFilters/categoryCollapsed above - SanitizeDatabase (see
            -- PrepareDatabase's fresh-install fast path, which now always
            -- runs it) is what actually fills in `selected`/`selfOnly`.
            -- Pre-filling `selected` here directly would make
            -- SanitizeDatabase's own "still on the old mode/recipients
            -- shape?" migration check (type(ui.outputRail.selected) ~=
            -- "table") see an already-table value and silently skip
            -- migrating an upgrading player's real saved recipients.
            outputRail = {},
        },
    }
end

local function MigrateDB(db)
    local fromVersion = db.dbVersion or 0

    if fromVersion < 2 then
        -- v1 -> v2: single-choice "playbackMode" string became a
        -- multi-select "broadcastModes" set; "LOCAL" simply meant nothing
        -- was broadcast, so it maps to everything left off.
        local oldMode = db.settings and db.settings.playbackMode
        if db.settings then
            db.settings.playbackMode = nil
        end
        if oldMode and oldMode ~= "LOCAL" then
            db.settings.broadcastModes = db.settings.broadcastModes or {}
            db.settings.broadcastModes[oldMode] = true
        end
        -- The old automatic-macro bookkeeping is no longer used (macros are
        -- now handled via a copyable string instead of CreateMacro/EditMacro).
        db.macros = nil
        db.macroCounter = nil
    end

    if fromVersion < 3 then
        -- v2 -> v3: broadcasting to Friends/Party/Raid/Guild now defaults to
        -- ON. Force it on for everyone upgrading from v2, where it still
        -- defaulted to OFF - ApplyDefaults alone wouldn't touch these since
        -- they already have explicit (false) values from the v2 default.
        if db.settings then
            db.settings.broadcastModes = db.settings.broadcastModes or {}
            db.settings.broadcastModes.FRIENDS = true
            db.settings.broadcastModes.PARTY = true
            db.settings.broadcastModes.RAID = true
            db.settings.broadcastModes.GUILD = true
        end
    end

    if fromVersion < 4 then
        -- v3 -> v4: Category 2 becomes the addon's built-in "Default"
        -- category (ships with starter sounds); the old (always-empty)
        -- Category 3/4 become Category 1/2. Private sounds
        -- (Soundbook_Private) move off category number 2 onto their own
        -- "Private" bucket at the same time (SB.PRIVATE_CATEGORY) - every
        -- "2::..." id already saved is necessarily one of those private
        -- sounds (Category 2 itself never had any real entries before
        -- this version), so they all migrate to "Private::...". The
        -- Favourites tab's own key also moves from the number 1 to
        -- "favourites", freeing 1 up for the new Category 1.
        if db.categories then
            db.categories["Default"] = db.categories[2]
            db.categories[1] = db.categories[3]
            db.categories[2] = db.categories[4]
            db.categories[3] = nil
            db.categories[4] = nil
        end

        local function RekeySoundID(id)
            local rest = type(id) == "string" and id:match("^2::(.*)$")
            return rest and ("Private::" .. rest) or id
        end

        if db.sounds then
            local migrated = {}
            for id, data in pairs(db.sounds) do
                migrated[RekeySoundID(id)] = data
            end
            db.sounds = migrated
        end

        if db.favourites then
            for i, id in ipairs(db.favourites) do
                db.favourites[i] = RekeySoundID(id)
            end
        end

        if db.ui then
            if db.ui.currentPage then
                local page = db.ui.currentPage
                page["Default"], page["1"], page["2"] = page["2"], page["3"], page["4"]
                page["3"], page["4"] = nil, nil
            end
            if db.ui.currentTab == 2 then
                db.ui.currentTab = "Default"
            elseif db.ui.currentTab == 3 then
                db.ui.currentTab = 1
            elseif db.ui.currentTab == 4 then
                db.ui.currentTab = 2
            elseif db.ui.currentTab == 1 then
                db.ui.currentTab = "favourites"
            end
        end
    end

    if fromVersion < 5 then
        -- v4 -> v5: "Also notify when a sound was blocked" and "Notify who
        -- received/played sounds you sent" now default to on. Force them
        -- on for everyone upgrading, the same way v2->v3 forced the
        -- broadcast channels on - ApplyDefaults alone wouldn't touch these
        -- since they already have an explicit (false) value from before.
        if db.settings then
            db.settings.notifyMutedAttempts = true
            db.settings.notifyFriendReceipts = true
        end
    end

    if fromVersion < 6 then
        -- v5 -> v6: GetSoundSaved used to permanently bake the Sounds.lua
        -- default icon into saved.icon the first time a sound was touched,
        -- which then froze that icon forever - later fixes to a Sounds.lua
        -- icon silently had no effect for anyone who had already touched
        -- that sound. That eager-bake is now removed, but everyone's
        -- SavedVariables already has these frozen values sitting in it from
        -- before, so they'd still show the old (possibly broken) icon
        -- forever even with the code fixed. Clear every sound's saved icon
        -- once so it re-derives live from the current Sounds.lua default
        -- from now on. This is a one-time reset: it also clears any icon a
        -- player deliberately hand-picked via the in-game Edit window, so
        -- if that applies to you, you'll need to re-pick it once after this
        -- update - unavoidable, since the old data can't tell "auto-baked"
        -- and "deliberately chosen" apart.
        if db.sounds then
            for _, saved in pairs(db.sounds) do
                saved.icon = nil
            end
        end
    end

    if fromVersion < 7 then
        -- v6 -> v7 (Soundbook 1.9.1): no data shape changed by itself - this
        -- just marks the DB version bump for the new, additive-only
        -- settings introduced in 1.9.1 (first-run intro flag, keybind panel
        -- collapse state, etc. - see GetDefaultDB above). Reaching this
        -- block at all means it's an EXISTING install being upgraded, not a
        -- fresh one (see ADDON_LOADED below, SB.isFreshInstall) - the new
        -- "safer first start" defaults (Self-only output, Mini Soundbook
        -- closed, starter Favourites) apply ONLY to a genuinely fresh
        -- GetDefaultDB() install, never retroactively forced onto someone
        -- upgrading who already made their own choices.
    end

    if fromVersion < 8 then
        -- v7 -> v8 (Soundbook 1.9.4): explicit one-time request - force the
        -- redesigned intro popup (Intro.lua: the sound-button + disco card,
        -- the new "Add your own sounds" step) open once for EVERY existing
        -- install, even though their own introSeen was already true from
        -- long before this update existed, so returning players actually
        -- get to see it. This block only ever runs ONCE per install: the
        -- moment it runs, db.dbVersion is bumped to 8 below, so
        -- `fromVersion < 8` is false on every future load from then on -
        -- no future version bump re-triggers this unless a NEW migration
        -- block explicitly sets introSeen = false again (don't do that by
        -- accident when adding a v8->v9 block later). Reaching this block
        -- at all already means an EXISTING install (see the v6->v7 comment
        -- above) - a genuinely fresh install never runs MigrateDB at all,
        -- it just gets GetDefaultDB()'s introSeen = false directly.
        db.settings = db.settings or {}
        db.settings.introSeen = false
    end

    if fromVersion < 9 then
        -- v8 -> v9: the first Arcane Codex test used the old tall window
        -- proportions. Reset only the two window sizes once so existing
        -- testers receive the corrected compact layout without losing any
        -- sounds, favourites, settings, or saved screen positions.
        db.ui = db.ui or {}
        db.ui.mainWidth = 520
        db.ui.mainHeight = 482
        db.ui.favWidth = 360
        db.ui.favHeight = 174
    end

    if fromVersion < 10 then
        -- v9 -> v10: enforce the compact 10x2 Mini profile once more for
        -- installs that already opened the first QA package before its
        -- SavedVariables migration could be observed in a live screenshot.
        db.ui = db.ui or {}
        db.ui.favWidth = 360
        db.ui.favHeight = 174
    end

    if fromVersion < 11 then
        -- Final UI-polish migration: keep every saved feature setting and
        -- screen position, but apply the lighter compact Mini proportions.
        db.ui = db.ui or {}
        db.ui.favWidth = 360
        db.ui.favHeight = 170
    end

    if fromVersion < 12 then
        -- Targeted correction pass: preserve positions and every feature
        -- setting, but give the library/settings composition enough room
        -- for the refined responsive spacing on first load of this build.
        db.ui = db.ui or {}
        db.ui.mainWidth = 600
        db.ui.mainHeight = 560
        db.ui.favWidth = 360
        db.ui.favHeight = 170
    end

    if fromVersion < 13 then
        -- Final book proportion: slightly narrower and taller. Library and
        -- Settings share these exact dimensions and never resize on tab change.
        db.ui = db.ui or {}
        db.ui.mainWidth = 560
        db.ui.mainHeight = 620
    end

    if fromVersion < 15 then
        -- v14 -> v15: explicit request - rename sound(s) whose umlaut in
        -- the name/filename kept causing real encoding corruption on disk
        -- (the "Charakter z?hlt" bug, twice now - see Sounds.lua's own
        -- history). Renaming the FILE and Sounds.lua entry alone would
        -- silently break anyone who already has the old soundID saved as a
        -- favourite, a keybind (via the favourite slot it's in), or a
        -- per-sound override (icon/mute) - same RekeySoundID pattern the
        -- v3->v4 migration above already established for exactly this kind
        -- of problem.
        local RENAMES = {
            ["Default::Charakter zählt"] = "Default::Charakter",
        }

        local function RekeySoundID(id)
            return RENAMES[id] or id
        end

        if db.sounds then
            local migrated = {}
            for id, data in pairs(db.sounds) do
                migrated[RekeySoundID(id)] = data
            end
            db.sounds = migrated
        end

        if db.favourites then
            for slot = 1, SB.MAX_FAVOURITES do
                local id = db.favourites[slot]
                if id then
                    db.favourites[slot] = RekeySoundID(id)
                end
            end
        end
    end

    if fromVersion < 16 then
        -- v15 -> v16: main Soundbook window ~50% taller (930, was 620).
        -- CORRECTED by v16->v17 below - the user actually meant the
        -- broadcast/output-target DROPDOWN, not the book window itself.
        -- Left in place (rather than deleted) since it already shipped to
        -- this live install the moment it was saved to disk - v17 below is
        -- what actually fixes it for anyone who already picked it up.
        db.ui = db.ui or {}
        db.ui.mainHeight = 930
    end

    if fromVersion < 17 then
        -- v16 -> v17: revert v16 above - "nein du hast das Soundbook lang
        -- gezogen, zurück! auf 620!" - the book window goes back to its
        -- original 620 height. Width was never touched by v16 and stays
        -- untouched here too.
        db.ui = db.ui or {}
        db.ui.mainHeight = 620
    end

    if fromVersion < 18 then
        -- v17 -> v18: the old "Default" category was split into two new
        -- categories, "Legacy" and "German Memes" - explicit request.
        -- Every sound that used to live under "Default" now has a brand
        -- new soundID ("Default::X" -> "Legacy::X" or "German Memes::X" -
        -- see SoundRegistry.lua's SB.MakeSoundID), which is a deliberate
        -- FULL RESET for every one of them, also explicitly requested:
        --   - Analytics history for the old id is purged automatically
        --     the moment it vanishes from SB.registry (Analytics.lua's
        --     PruneOrphanedRecords, runs every login) - nothing to do here.
        --   - A favourite pointing at the old id self-heals the same way
        --     (Favorites.lua's SB:PruneFavourites) - nothing to do here.
        --   - A custom icon/per-sound-mute pick under the old id is simply
        --     never looked up again (SB.db.sounds["Default::..."] just
        --     becomes harmless dead data) - nothing to do here either.
        -- The one thing that DOES need active handling: BackfillAddedAt
        -- (SoundRegistry.lua) would otherwise treat every one of these
        -- brand-new ids as a genuinely new addition the instant it's first
        -- seen and stamp ALL of them "New" at once. Pre-marking them
        -- "already known" (without an addedAt) below heads that off for
        -- everything except the 4 sounds explicitly kept "New" - those are
        -- deliberately left OUT of the pre-seed so BackfillAddedAt's
        -- normal "never seen before -> stamp time() now" path handles them
        -- and they keep showing the tag exactly like before the split.
        local LEGACY_NAMES = {
            "Anime Ahh", "Anime Wow", "Are you lost", "Awolnation Run",
            "Bad To The Bone", "Bongo", "Cant Touch This", "Celebration",
            "Cthun You Will Die", "Deja Vu", "Dexter Meme", "Donkey Hee Haw",
            "Dry Fart", "Emotional Damage", "Epic Saxx", "Fahhh",
            "Fart echo", "Fart wet", "Few Moments Later", "Follow You",
            "Gimme the loot", "GTA San", "Halt Stop", "Hawk Tuah",
            "Hehe Michael", "Huh Cat", "Imposter Reveal", "In The Beginning",
            "Indian Song", "Keyboard Meme", "Kids Saying Yay", "Leeroy Jenkins",
            "Mein Team", "Meme End", "More Dots", "Nani",
            "No", "Oh My God", "Oh Shit MF", "Okay Guy",
            "Okayyy Lets Go", "Peon Work Work", "Perfect Fart", "Pornhub",
            "Rick Vu Luvub Dub Dub", "Rizzbot Laugh", "Rock And Roll", "Sexy",
            "Super Mario Death", "Thats me", "To be continued", "Viel Gluck",
            "Vine Boom", "Wha Wha", "Yamete Kudasai", "Yippee",
            "Zehahaha", "dun dun dun",
        }
        local GERMAN_MEMES_NAMES = {
            "Auf Alkohol", "Charakter", "Du bist gut genug", "Ich hab Ganis gemakt",
            "Ich muss raus", "Mir Egal", "Nein Doch Oh", "Schoki",
            "Weiss Nicht Digga",
        }
        local KEEP_NEW = {
            ["Donkey Hee Haw"] = true, ["Zehahaha"] = true,
            ["Mir Egal"] = true, ["Schoki"] = true,
        }

        db.knownSoundIDs = db.knownSoundIDs or {}
        for _, name in ipairs(LEGACY_NAMES) do
            if not KEEP_NEW[name] then
                db.knownSoundIDs["Legacy::" .. name] = true
            end
        end
        for _, name in ipairs(GERMAN_MEMES_NAMES) do
            if not KEEP_NEW[name] then
                db.knownSoundIDs["German Memes::" .. name] = true
            end
        end

        -- The old "Default" tab no longer exists - land anyone sitting on
        -- it on "Legacy" instead of a dead tab reference.
        if db.ui and db.ui.currentTab == "Default" then
            db.ui.currentTab = "Legacy"
        end
    end

    if fromVersion < 19 then
        -- v18 -> v19: the "German Memes" category icon from the v17->v18
        -- split (fileID 13591) turned out blank in-game - explicit request
        -- to swap it for the Priest "Lesser Heal" spell icon instead
        -- (Spell_Holy_LesserHeal, see SB.DEFAULT_CATEGORY_INFO above).
        -- ApplyDefaults alone wouldn't touch this - db.categories["German
        -- Memes"] already exists with the old icon baked in from the
        -- moment v18 ran (or a fresh GetDefaultDB() install in between) -
        -- force it once. Explicit request NOT to touch "Legacy" at all
        -- ("bitte nicht mehr ändern") - only this one key is touched here.
        if db.categories and db.categories["German Memes"] then
            db.categories["German Memes"].icon = "Interface\\Icons\\Spell_Holy_LesserHeal"
        end
    end

    if fromVersion < 20 then
        -- v19 -> v20: two more icon corrections, both explicit requests -
        -- ApplyDefaults alone won't touch either since db.categories
        -- already has both keys baked in from earlier versions:
        --   - "Legacy" - was INV_Misc_Gift_01 since it existed (carried
        --     over from the old "Default" category) - now an actual book
        --     icon ("auf das Buch wieder ändern"), overriding the earlier
        --     "don't change this again" request from the same player -
        --     a later explicit instruction wins.
        --   - "German Memes" - v18->v19 above already tried swapping
        --     fileID 13591 for Spell_Holy_LesserHeal, which ALSO turned
        --     out blank - swapping again for the plain "Heal" icon
        --     (Spell_Holy_Heal), which is proven to render on this client
        --     (also used as a per-sound icon already, see Core.lua above).
        if db.categories then
            if db.categories["Legacy"] then
                db.categories["Legacy"].icon = "Interface\\Icons\\INV_Misc_Book_09"
            end
            if db.categories["German Memes"] then
                db.categories["German Memes"].icon = "Interface\\Icons\\Spell_Holy_Heal"
            end
        end
    end

    if fromVersion < 21 then
        -- v20 -> v21: explicit request - avoid an icon being double-booked
        -- across two different UI contexts (flagged for "Mir Egal" sharing
        -- the Mini Soundbook's idle "Ready" status icon, INV_Misc_Note_01 -
        -- fixed directly in Sounds.lua). Category 2's own default icon was
        -- ALSO INV_Misc_Note_01 (same collision, same reasoning) - force
        -- it to the new default here since ApplyDefaults won't touch an
        -- already-baked-in db.categories[2] value.
        if db.categories and db.categories[2] then
            db.categories[2].icon = "Interface\\Icons\\INV_Misc_Bag_08"
        end
    end

    if fromVersion < 22 then
        -- v21 -> v22: explicit request - fix two typos in Stammtisch
        -- (Soundbook_Private) sound names ("Mach dein Stuhl" ->
        -- "Mach dein Strahl", "Hauptsache Loche" -> "Hauptsache, Loch.")
        -- - the physical file and Sounds.lua entry were both renamed to
        -- match. Same RekeySoundID pattern the v14->v15 migration already
        -- established for exactly this ("Charakter zählt" -> "Charakter")
        -- - preserves this sound's own icon/favourite/mute/macro/output-
        -- override (db.sounds) and its favourite slot position
        -- (db.favourites) under the new id. Analytics history for the old
        -- id is deliberately NOT migrated here, same as that precedent -
        -- it self-heals on its own the moment the old id vanishes from
        -- SB.registry (Analytics.lua's PruneOrphanedRecords, runs every
        -- login) - "Analytics bereinigen", not migrate.
        local RENAMES = {
            ["Private::Mach dein Stuhl"] = "Private::Mach dein Strahl",
            ["Private::Hauptsache Loche"] = "Private::Hauptsache, Loch.",
        }

        local function RekeySoundID(id)
            return RENAMES[id] or id
        end

        if db.sounds then
            local migrated = {}
            for id, data in pairs(db.sounds) do
                migrated[RekeySoundID(id)] = data
            end
            db.sounds = migrated
        end

        if db.favourites then
            for slot = 1, SB.MAX_FAVOURITES do
                local id = db.favourites[slot]
                if id then
                    db.favourites[slot] = RekeySoundID(id)
                end
            end
        end
    end

    if fromVersion < 23 then
        -- v22 -> v23: explicit bugfix - the v21->v22 rename above
        -- deliberately left db.knownSoundIDs alone (same as its own
        -- v14->v15 precedent), but that meant SoundRegistry.lua's
        -- SB:BackfillAddedAt saw both brand-new-LOOKING soundIDs on the
        -- very next login and treated them as genuinely new content:
        -- stamped a fresh addedAt (48h "New" tag pill) AND triggered the
        -- "New Sounds" intro popup for them - neither should have
        -- happened, they're renamed EXISTING sounds, not new ones
        -- ("warum kam gerade die introduction der neuen Sounds auf? das
        -- sollte nicht sein"). Retroactively undoes both for anyone who
        -- already hit it (clears the wrongly-stamped addedAt so
        -- SB:IsSoundNew/the New pill stops matching immediately - the
        -- popup itself already self-resolved on its own the moment it was
        -- shown, nothing to undo there) AND pre-empts it for anyone who
        -- hasn't logged in since the rename yet (marking them known
        -- BEFORE BackfillAddedAt ever runs this login, so it never stamps
        -- them in the first place).
        local RENAMED_NOT_ACTUALLY_NEW = {
            "Private::Mach dein Strahl",
            "Private::Hauptsache, Loch.",
        }
        db.knownSoundIDs = db.knownSoundIDs or {}
        for _, id in ipairs(RENAMED_NOT_ACTUALLY_NEW) do
            db.knownSoundIDs[id] = true
            if db.sounds and db.sounds[id] then
                db.sounds[id].addedAt = nil
            end
        end
    end

    if fromVersion < 24 then
        -- v23 -> v24: the 2.5.0 database pipeline performs migration on a
        -- detached copy and validates that copy before committing it. No
        -- user-facing setting changes shape in this migration; the version
        -- marker makes the atomic upgrade idempotent.
    end

    if fromVersion < 25 then
        -- v24 -> v25: Raid and Party merged into one Send target (explicit
        -- request - see SB.ResolveGroupChannel, Communication.lua). The old
        -- "broadcastModes.PARTY" flag no longer exists; OR it into the
        -- surviving "broadcastModes.RAID" flag first so nobody who had
        -- Party-only broadcasting enabled silently loses it - RAID now
        -- covers whichever of the two they're actually in when a sound is
        -- sent. Per-sound Default/Macro Output overrides already saved as
        -- "PARTY" are left untouched - every place that reads them treats
        -- "PARTY" as an alias for "RAID" going forward, so nothing there
        -- needs rewriting.
        if db.settings and db.settings.broadcastModes then
            local modes = db.settings.broadcastModes
            modes.RAID = (modes.RAID == true) or (modes.PARTY == true)
            modes.PARTY = nil
        end
    end

    if fromVersion < 26 then
        -- v25 -> v26: Raid and Party now merged on the RECEIVE side too,
        -- not just Send (explicit request - "wir meinten doch, dass das
        -- dasselbe ist") - the Settings matrix goes from two rows (Raid,
        -- Party) down to one ("Raid/Party"). OR the old "receiveParty"
        -- flag into the surviving "receiveRaid" flag first, same reasoning
        -- as the v24->v25 Send merge above - nobody who had Party sounds
        -- enabled but Raid sounds off (or vice versa) silently stops
        -- hearing either.
        if db.settings then
            db.settings.receiveRaid = (db.settings.receiveRaid == true) or (db.settings.receiveParty == true)
            db.settings.receiveParty = nil
        end
    end

    if fromVersion < 27 then
        -- v26 -> v27: Soundbook 3.0 - the Announcer HUD replaces the old
        -- Mini Soundbook/Favourites window as the always-on HUD element.
        -- Seed the new `ui.announcer` table from the old fav* fields ONCE
        -- here, so an upgrading player's existing position/visibility/lock/
        -- opacity choices carry over instead of resetting to defaults - the
        -- 3.0 spec is explicit that this must happen exactly once, and that
        -- the new value is authoritative from then on (not re-copied on
        -- every future login). The old fav* fields themselves are left
        -- fully intact (never deleted) - Favorites.lua's actual favourite
        -- DATA (db.favourites, favKeybinds) was never touched by any of
        -- this, only the old HUD WINDOW's own position/appearance fields.
        if db.ui then
            local old = db.ui
            db.ui.announcer = db.ui.announcer or {}
            local ann = db.ui.announcer
            if type(old.favPos) == "table" then
                ann.pos = { point = old.favPos.point, relPoint = old.favPos.relPoint, x = old.favPos.x, y = old.favPos.y }
            end
            if old.favShown ~= nil then ann.shown = old.favShown end
            if old.favAlphaIdle ~= nil then ann.alphaIdle = old.favAlphaIdle end
            if old.favAlphaHover ~= nil then ann.alphaHover = old.favAlphaHover end
            -- The old Mini window's own lock now feeds the single shared
            -- ui.layoutLocked (3.0 spec section 16 - one lock covers the
            -- Main shell and the Announcer's movement together).
            if old.favLocked ~= nil then db.ui.layoutLocked = old.favLocked end
        end
    end

    if fromVersion < 28 then
        -- v27 -> v28: targeted correction round - "Announcer Size" used to
        -- also drive the Favourites popup's own column-count/width scaling
        -- (GetFavMenuColumns in Announcer.lua), which is wrong - resizing
        -- the Announcer shouldn't resize favourites and vice versa. Split
        -- into two independent fields; seed the new favScale from whatever
        -- the single prior `scale` already was, ONCE, so an upgrading
        -- player's favourites don't silently change size - a fresh install
        -- never hits this block at all and just gets GetDefaultDB()'s own
        -- favScale = 1.0 via ApplyDefaults below.
        if db.ui and db.ui.announcer and db.ui.announcer.favScale == nil then
            local prior = tonumber(db.ui.announcer.scale)
            if prior then
                db.ui.announcer.favScale = math.max(0.5, math.min(2.0, prior))
            end
        end
    end

    db.dbVersion = SB.DB_VERSION
end

-- Database.lua owns the safe copy/migrate/validate/commit pipeline. These
-- functions remain defined here because the historical migrations are best
-- kept beside the defaults they were written against, but are exported so
-- that pipeline can run them without duplicating twenty-three old upgrades.
SB.ApplyDatabaseDefaults = ApplyDefaults
SB.GetDefaultDatabase = GetDefaultDB
SB.MigrateDatabaseInPlace = MigrateDB

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("ADDON_LOADED")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
initFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
-- Boss encounter start/end (distinct from general combat - see Settings ->
-- General -> "Allow Sounds while boss encounter"). Registering an event
-- name a given client build doesn't fire is harmless (it just never
-- triggers) - safe to always register.
initFrame:RegisterEvent("ENCOUNTER_START")
initFrame:RegisterEvent("ENCOUNTER_END")

initFrame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        -- Distinguishes a genuinely brand-new install from an existing one
        -- being upgraded (see MigrateDB's v6->v7 comment) - Soundbook 1.9.1's
        -- "safer first start" defaults (Self-only output, Mini Soundbook
        -- closed, starter Favourites) key off this, applied ONLY here, never
        -- retroactively forced onto an upgrade.
        SB.isFreshInstall = type(SoundbookDB) ~= "table"
        local databaseStatus
        if SB.PrepareDatabase then
            local prepared
            prepared, databaseStatus = SB:PrepareDatabase(SoundbookDB)
            if databaseStatus.commit then
                SoundbookDB = prepared
            end
            SB.db = prepared
        elseif SB.isFreshInstall then
            SoundbookDB = GetDefaultDB()
            SB.db = SoundbookDB
        else
            MigrateDB(SoundbookDB)
            ApplyDefaults(SoundbookDB, GetDefaultDB())
            SB.db = SoundbookDB
        end
        SB.databaseStatus = databaseStatus

        if SB.isFreshInstall then
            -- introSeen's own default is true (see GetDefaultDB) so an
            -- upgrading install stays untouched - a genuinely fresh one
            -- needs it explicitly flipped back to false to actually show
            -- the first-run intro once.
            SB.db.settings.introSeen = false
            -- "Safer first start" (Soundbook 1.9.1, explicit request):
            -- nothing gets sent to Friends/Guild/Party/Raid until the
            -- player deliberately picks a target, and the Announcer HUD
            -- doesn't pop up unasked before they've even seen the addon.
            -- ONLY for a genuinely fresh install - GetDefaultDB()'s own
            -- defaults (defaultOutputTarget="ALL", announcer.shown=true) are
            -- still exactly what ApplyDefaults backfills for an upgrade,
            -- since an existing player's current setup must never be
            -- silently reset.
            -- Main Soundbook redesign: defaultOutputTarget is the actual
            -- live global default again (see Communication.lua's
            -- SB:ResolveOutputTarget) - explicit, more recent requirement
            -- (task #66, this session) supersedes the older 1.9.1 "safer
            -- first start" SELF default: a fresh install must always land
            -- on "All", never nothing/Self-only.
            SB.db.settings.defaultOutputTarget = "ALL"
            SB.db.ui.outputRail.selfOnly = false
            SB.db.ui.favShown = false
            SB.db.ui.announcer.shown = false
        end
        dbIsReady = true
        SB:RefreshMainFont()

        if databaseStatus and databaseStatus.warning then
            SB:Print(databaseStatus.warning)
        end

        -- 2 starter Favourites on a fresh install (explicit request) -
        -- SB.registry is already built by now (SoundRegistry.lua's own
        -- BuildRegistry() ran unconditionally at its own file-load time,
        -- long before this ADDON_LOADED handler runs), so this is safe.
        -- Never touches an existing install's own Favourites.
        if SB.isFreshInstall and SB.AddFavourite then
            -- Was "Default::..." - caught while investigating a separate
            -- report: both moved to "Legacy" in the category split
            -- (MigrateDB's v17->v18 block) and this never got updated, so
            -- a genuinely fresh install since then silently got ZERO
            -- starter favourites (AddFavourite just fails quietly on an
            -- unknown soundID).
            SB:AddFavourite("Legacy::Oh My God")
            SB:AddFavourite("Legacy::Celebration")
        end

        for i = 1, #readyCallbacks do
            local ok, err = pcall(readyCallbacks[i])
            if not ok then SB:Print("|cffff5555Error|r during init: " .. tostring(err)) end
        end
        readyCallbacks = {}

        SB:Fire("DB_READY")
    elseif event == "PLAYER_LOGIN" then
        -- Classifies every currently-registered sound as "New" (real
        -- timestamp) or "legacy" (never shows the New tag) - see
        -- SoundRegistry.lua's SB:BackfillAddedAt for the full explanation.
        -- Deliberately here, not in ADDON_LOADED above - a companion addon
        -- like Soundbook_MySounds only registers ITS sounds once IT loads,
        -- which happens strictly after Soundbook's own ADDON_LOADED has
        -- already fired (RequiredDeps ordering) - by PLAYER_LOGIN every
        -- addon, this one included, is guaranteed fully loaded, so nothing
        -- registered by a companion addon is missed here.
        if SB.BackfillAddedAt then SB:BackfillAddedAt() end

        -- One-time correction: an early build of the duration-learning
        -- feature (before the playingStartedAt fix - see SoundPlayer.lua)
        -- could measure a QUEUED overlapping instance's wait time as part
        -- of the duration, learning a value roughly 2x too long. Clears
        -- any value learned by that specific known-bad build so it gets a
        -- fair chance to re-learn correctly; never touches a value that
        -- was already correct (precomputed values were never affected).
        if SB.db and SB.db.soundDurations then
            local KNOWN_BAD_LEARNED_DURATIONS = { ["1::We Will See"] = true }
            for soundID in pairs(KNOWN_BAD_LEARNED_DURATIONS) do
                if SB.db.soundDurations[soundID] then
                    SB.db.soundDurations[soundID] = nil
                    local info = SB.registry[soundID]
                    if info then info.durationSeconds = nil end
                end
            end
        end

        -- One-time correction: moving BackfillAddedAt from ADDON_LOADED to
        -- PLAYER_LOGIN (above) fixed the MySounds-timing bug, but had a
        -- side effect for private/Stammtisch sounds - they were never
        -- actually SEEN by BackfillAddedAt's original (too-early) first
        -- run, so they never got marked "legacy" back then either; once
        -- fixed, its normal "never seen this soundID before -> genuinely
        -- new" rule wrongly stamped the player's WHOLE existing Stammtisch
        -- library as New. Runs only once (SB.db.privateLegacyFixApplied) -
        -- wipes addedAt for every currently-registered PRIVATE sound back
        -- to legacy; a genuinely new Stammtisch sound added AFTER this fix
        -- is unaffected and still gets tagged New normally going forward.
        if SB.db and not SB.db.privateLegacyFixApplied then
            SB.db.privateLegacyFixApplied = true
            for soundID, info in pairs(SB.registry) do
                if info.isPrivate then
                    local saved = SB.db.sounds and SB.db.sounds[soundID]
                    if saved and saved.addedAt then saved.addedAt = nil end
                end
            end
        end

        -- One-time correction, same shape as privateLegacyFixApplied above
        -- (already consumed, doesn't fire again) - a later regression
        -- (Soundbook 2.3.1's DB_READY-triggered PruneOrphanedRecords,
        -- since reverted - see Analytics.lua) ran before a companion addon
        -- (Soundbook_Private/Soundbook_MySounds) had finished registering
        -- its own sounds, wiping their knownSoundIDs entries - which then
        -- made BackfillAddedAt (just above) wrongly stamp ALL of them
        -- ("all of Stammtisch suddenly New" - explicit bug report) as
        -- brand new. Wipes addedAt for every currently-registered private
        -- OR Category 1/2 sound back to legacy, exactly like the fix
        -- above; anything genuinely added from here on is unaffected.
        if SB.db and not SB.db.companionAddedAtFixApplied then
            SB.db.companionAddedAtFixApplied = true
            for soundID, info in pairs(SB.registry) do
                if info.isPrivate or type(info.category) == "number" then
                    local saved = SB.db.sounds and SB.db.sounds[soundID]
                    if saved and saved.addedAt then saved.addedAt = nil end
                end
            end
        end

        -- One-time correction (2.5.0 release, explicit bug report): the
        -- 2.5.0 addon-folder swap made some players' stored dbVersion
        -- unreadable for one login, so the full historical migration chain
        -- replayed from scratch instead of just the v23->v24 step. That
        -- re-triggered the v17->v18 "Default" split's intentionally-kept-
        -- new set (Donkey Hee Haw/Zehahaha/Mir Egal/Schoki) AND caught a
        -- few German Memes sounds added after that historical migration's
        -- hardcoded name list was written (Feuerball Junge/Hauen Sie ab/
        -- Luge Luge/Mir Stinken/Was Zitterstn so) - all 9 wrongly showed
        -- "New" again for a returning player who already knew them ("New
        -- Sounds" popup listing already-known sounds alongside the real
        -- 2.5.0 additions). Runs only once (SB.db.knownSoundsFix250Applied)
        -- - unconditionally clears addedAt for exactly this fixed set;
        -- a harmless no-op for anyone who was never affected.
        if SB.db and not SB.db.knownSoundsFix250Applied then
            SB.db.knownSoundsFix250Applied = true
            local WRONGLY_FLAGGED_NEW = {
                "Legacy::Donkey Hee Haw", "Legacy::Zehahaha",
                "German Memes::Mir Egal", "German Memes::Schoki",
                "German Memes::Feuerball Junge", "German Memes::Hauen Sie ab",
                "German Memes::Luge Luge", "German Memes::Mir Stinken",
                "German Memes::Was Zitterstn so",
            }
            SB.db.knownSoundIDs = SB.db.knownSoundIDs or {}
            for _, id in ipairs(WRONGLY_FLAGGED_NEW) do
                local saved = SB.db.sounds and SB.db.sounds[id]
                if saved and saved.addedAt then saved.addedAt = nil end
                SB.db.knownSoundIDs[id] = true
            end
        end

        SB:Fire("PLAYER_LOGIN")
    elseif event == "PLAYER_REGEN_DISABLED" then
        SB.inCombat = true
        SB:Fire("COMBAT_START")
    elseif event == "PLAYER_REGEN_ENABLED" then
        SB.inCombat = false
        SB:Fire("COMBAT_END")
    elseif event == "ENCOUNTER_START" then
        SB.inEncounter = true
        SB:Fire("ENCOUNTER_START")
    elseif event == "ENCOUNTER_END" then
        SB.inEncounter = false
        -- Fired (not just the flag above) so a "mute until next fight ends"
        -- raid-admin override (Communication.lua) can clear itself the
        -- moment the pull it was set for actually ends.
        SB:Fire("ENCOUNTER_END")
    end
end)

local function CountTable(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------
SLASH_SOUNDBOOK1 = "/sb"
SLASH_SOUNDBOOK2 = "/soundbook"

local function HandleSlash(msg)
    msg = msg or ""
    msg = msg:gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()

    if cmd == "" then
        SB:Fire("TOGGLE_MAIN_UI")
    elseif cmd == "fav" or cmd == "favourites" or cmd == "favorites" then
        SB:Fire("TOGGLE_FAV_UI")
    elseif cmd == "history" then
        SB:Fire("TOGGLE_HISTORY_UI")
    elseif cmd == "analytics" then
        if rest == "on" then
            if SB.SetAnalyticsEnabled then
                SB:SetAnalyticsEnabled(true)
            else
                SB.db.settings.analyticsEnabled = true
            end
            SB:Print("Analytics ON - collecting and sharing your own usage data.")
        elseif rest == "off" then
            if SB.SetAnalyticsEnabled then
                SB:SetAnalyticsEnabled(false)
            else
                SB.db.settings.analyticsEnabled = false
            end
            SB:Print("Analytics OFF - not collecting or sharing anything further (existing data kept).")
        elseif SB.ShowAnalyticsWindow then
            SB:ShowAnalyticsWindow()
        end
    elseif cmd == "play" then
        if rest == "" then
            SB:Print("Usage: /sb play <category::name>[::<target>]")
        else
            -- Optional trailing "::Guild"/"::Friends"/"::Party"/"::<player>"
            -- overrides where this play also gets sent - see Macros.lua.
            local soundID, target = SB.ParsePlayArg(rest)
            SB:TriggerSound(soundID, target)
        end
    elseif cmd == "debug" then
        SB.db.settings.debug = not SB.db.settings.debug
        SB:Print("Debug mode " .. (SB.db.settings.debug and "ON" or "OFF"))
    elseif cmd == "help" then
        SB:Print("Commands:")
        SB:Print("  /sb - toggle the main Soundbook window")
        SB:Print("  /sb fav - toggle the Announcer")
        SB:Print("  /sb history - show the last 10 received sounds")
        SB:Print("  /sb analytics - open the anonymous usage analytics window")
        SB:Print("  /sb analytics on|off - enable/disable collecting and sharing your usage data")
        SB:Print("  /sb play <category::name>[::<target>] - play (and optionally send) a sound")
        SB:Print("  /sb stop - stop anything currently playing and clear the incoming queue")
        SB:Print("  /sb mute - toggle receiving remote sounds (keeps your previous channel choices)")
        SB:Print("  /sb doctor - print a short runtime diagnostic report")
        SB:Print("  /sb reset - reset window positions and Mini Soundbook size")
        SB:Print("  /sb debug - toggle debug logging")
    elseif cmd == "stop" then
        SB:StopAllSounds()
        SB:ClearPendingQueue()
        SB:Print("Stopped playback and cleared the incoming queue.")
    elseif cmd == "mute" then
        if SB:IsReceiveMuted() then
            SB:StopReceiveMute()
            SB:Print("Receiving remote sounds is back on (your previous channel choices).")
        else
            SB:StartReceiveMute(nil, nil)
            SB:Print("Receiving remote sounds is now off. /sb mute again to restore.")
        end
    elseif cmd == "doctor" then
        -- Own version wrapped in quotes - explicit diagnostic request, so
        -- any stray whitespace/hidden character that would otherwise make
        -- an identical-looking version compare as "different" (the green/
        -- orange dropdown colour, SB:GetFormattedPlayerVersion in
        -- Communication.lua) is actually visible in chat instead of
        -- invisibly eaten by normal text rendering.
        SB:Print(string.format("Soundbook \"%s\" - DB v%d%s", SB.VERSION or "?", SB.DB_VERSION, SB.isFreshInstall and " (fresh install)" or ""))
        if SB.db.knownUsers then
            local names = {}
            for name in pairs(SB.db.knownUsers) do table.insert(names, name) end
            table.sort(names)
            -- Explicit request: same green/orange scheme the output-target
            -- dropdowns already use for a player's version suffix
            -- (SB:GetFormattedPlayerVersion, Communication.lua) - "major
            -- version" here means the first TWO dot-separated numbers
            -- together (e.g. "2.5" out of "2.5.2"), same as that existing
            -- comparison already uses - explicit bugfix: an earlier version
            -- of this compared only the very first number, which wrongly
            -- coloured e.g. 2.4.5 the same green as 2.5.1 (both just "2").
            -- Colours the name and version together as one unit, not just
            -- the version suffix on its own, since there's no separate
            -- "channel colour" for a name here (doctor's list isn't grouped
            -- by Guild/Raid/Friends the way those dropdowns are).
            local DOCTOR_VERSION_MATCH = "cff66f280"   -- same RGB as VERSION_CURRENT_COLOR
            local DOCTOR_VERSION_DIFFERENT = "cffff9900" -- same RGB as VERSION_OTHER_COLOR
            local myMajorMinor = SB.VERSION and SB.VERSION:match("^(%d+%.%d+)")
            for _, name in ipairs(names) do
                local info = SB.db.knownUsers[name]
                if type(info) == "table" then
                    local theirVersion = tostring(info.version)
                    local theirMajorMinor = theirVersion:match("^(%d+%.%d+)")
                    local color = (myMajorMinor and theirMajorMinor and theirMajorMinor == myMajorMinor)
                        and DOCTOR_VERSION_MATCH or DOCTOR_VERSION_DIFFERENT
                    SB:Print(string.format("  |%s%s: version=\"%s\"|r lastSeen=%ds ago",
                        color, name, theirVersion, math.max(0, math.floor(time() - (tonumber(info.lastSeen) or time())))))
                end
            end
        end
        SB:Print(string.format("Favourites: %d/%d used | Known Soundbook users: %d",
            SB:GetFavouriteCount(), SB.MAX_FAVOURITES, SB.db.knownUsers and CountTable(SB.db.knownUsers) or 0))
        SB:Print(string.format("Queue: %s (%d waiting) | Receive muted: %s",
            SB.db.settings.soundQueueEnabled and "ON" or "OFF",
            SB.GetPendingQueueSize and SB:GetPendingQueueSize() or 0,
            SB:IsReceiveMuted() and "YES" or "no"))
        -- Diagnostic for raid-admin "Mute All"/"Mute Sending" reports
        -- (explicit request - a player suspected sounds were still getting
        -- through over Guild while a raid mute was active). Shows exactly
        -- what THIS client currently believes the override state is, so a
        -- report can be checked against the real data instead of guessing
        -- whether the mute ever actually reached this specific player.
        if SB.raidOverride then
            local remaining = SB.raidOverride.expiresAt and math.max(0, SB.raidOverride.expiresAt - GetTime())
            SB:Print(string.format(
                "Raid override: mutedAll=%s mutedSend=%s source=%s duration=%s%s",
                tostring(SB.raidOverride.mutedAll), tostring(SB.raidOverride.mutedSend),
                tostring(SB.raidOverride.source), tostring(SB.raidOverride.durationCode),
                remaining and string.format(" (%ds left)", math.floor(remaining)) or ""))
        else
            SB:Print("Raid override: none active")
        end
        if SB.GetTransportStats then
            local transport = SB:GetTransportStats()
            SB:Print(string.format("Transport: %d queued | %d sent | %d dropped",
                transport.queued, transport.sent, transport.dropped))
        end
        if SB.GetAnalyticsSyncState then
            local analytics = SB:GetAnalyticsSyncState()
            local activity = analytics.running and "syncing"
                or (analytics.startupPending and "scheduled" or "idle")
            SB:Print(string.format("Analytics: %s (%s)", analytics.enabled and "ON" or "OFF", activity))
        end
        if SB.GetMainGridLayout then
            local columns, rawWidth, renderedEntries, renderedHeaders = SB:GetMainGridLayout()
            local registryCount = 0
            for _ in pairs(SB.registry or {}) do registryCount = registryCount + 1 end
            SB:Print(string.format("Library grid: %d columns, width=%.0f | registered sounds=%d, last rendered: %d cards / %d sections",
                columns, rawWidth or 0, registryCount, renderedEntries or 0, renderedHeaders or 0))
        end
        if SB.databaseStatus and SB.databaseStatus.commit == false then
            SB:Print("Database: compatibility/recovery mode (original SavedVariables not modified)")
        else
            SB:Print("Database: validated and writable")
        end
        -- Neither Broadcast nor Receive has a separate Party entry any more
        -- - RAID covers both, on both sides (see SB.ResolveGroupChannel,
        -- Communication.lua).
        SB:Print(string.format("Broadcast: Friends=%s Guild=%s Raid/Party=%s | Receive: Friends=%s Guild=%s Raid/Party=%s Direct=%s",
            tostring(SB.db.settings.broadcastModes.FRIENDS), tostring(SB.db.settings.broadcastModes.GUILD),
            tostring(SB.db.settings.broadcastModes.RAID),
            tostring(SB.db.settings.receiveFriends), tostring(SB.db.settings.receiveGuild),
            tostring(SB.db.settings.receiveRaid),
            tostring(SB.db.settings.receiveDirect)))
    elseif cmd == "reset" then
        local defaults = GetDefaultDB()
        SB.db.ui.mainPos = defaults.ui.mainPos
        SB.db.ui.mainWidth = defaults.ui.mainWidth
        SB.db.ui.mainHeight = defaults.ui.mainHeight
        SB.db.ui.favPos = defaults.ui.favPos
        SB.db.ui.favWidth = defaults.ui.favWidth
        SB.db.ui.favHeight = defaults.ui.favHeight
        SB.db.ui.favScale = defaults.ui.favScale
        SB.db.ui.announcer.pos = defaults.ui.announcer.pos
        SB:Print("Window positions and Announcer position reset. /reload to see it take effect everywhere.")
    else
        SB:Print("Unknown command. /sb help for the full list.")
    end
end

SlashCmdList["SOUNDBOOK"] = HandleSlash
