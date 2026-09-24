-- SoundAlternates.lua
--
-- An Alternate is a LOCAL-only substitute for a sound, e.g. a license-safe
-- re-record used to dodge a stream's copyright detection. The soundID sent
-- over the network never changes, so everyone else still hears the real
-- original; only a player who enables "Alternative Sound" (Edit Sound)
-- hears their own version, regardless of who triggered playback.
--
-- WoW addons can't list folder contents, so an alternate must be
-- registered here (keyed by soundID) to be known at all; dropping a file
-- into Sounds\Alternates\ alone does nothing. fileBase mirrors the
-- category folders and has no extension - playback tries .ogg/.mp3/.wav
-- in turn (see SoundPlayer.lua):
--   Sounds\Alternates\<Category>\<Name>
--
-- durationSeconds is precomputed from the actual file (like
-- SoundDurations.lua) and kept separate from the original sound's
-- duration, since an alternate is rarely the same length; it drives the
-- Announcement Bar's progress fill while the alternate plays.

local ADDON_NAME, SB = ...

SB.SoundAlternates = {
    ["German Memes::Du bist gut genug"] = {
        fileBase = "Interface\\AddOns\\Soundbook\\Sounds\\Alternates\\German Memes\\Du bist gut genug",
        durationSeconds = 7.811,
    },
}
