-- SoundAlternates.lua
--
-- Explicit request: lets a player substitute a license-safe alternate
-- version of a sound for the shared original - purely a LOCAL playback
-- swap. Doesn't have to be a self-made recording - any alternate that
-- doesn't trip a copyright system works. The soundID broadcast/received
-- over the network never changes, so everyone else always still hears
-- the real original; only the player who enabled it (Edit Sound ->
-- "Alternative Sound") hears their own version, on their own client, no
-- matter who triggered it (their own click, or a sound someone else sent
-- them). Built for the first real use case: a streamer avoiding an
-- automated Twitch copyright mute on a sound that samples a licensed
-- song, by playing a license-safe alternate locally instead.
--
-- WoW addons can't list folder contents, so - same as Sounds.lua itself -
-- an alternate file must be explicitly registered here before Soundbook
-- knows it exists at all; dropping a file into Sounds\Alternates\ alone
-- does nothing. Physical layout mirrors the category folders exactly:
--   Sounds\Alternates\<Category>\<Name>.ogg (or .mp3 / .wav)
-- e.g. this entry's file lives at
--   Sounds\Alternates\German Memes\Du bist gut genug.mp3
--
-- durationSeconds is precomputed the same way SoundDurations.lua's values
-- are (outside the game, from the actual file) - kept SEPARATE from the
-- original sound's own duration since an alternate file is very unlikely
-- to be exactly the same length, and this is what the Announcement Bar's
-- progress fill actually times itself against while an alternate is
-- playing (see SoundPlayer.lua).

local ADDON_NAME, SB = ...

SB.SoundAlternates = {
    ["German Memes::Du bist gut genug"] = {
        fileBase = "Interface\\AddOns\\Soundbook\\Sounds\\Alternates\\German Memes\\Du bist gut genug",
        durationSeconds = 7.811,
    },
}
