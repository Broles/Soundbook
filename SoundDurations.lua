-- SoundDurations.lua
--
-- Precomputed durations (seconds) for every sound file this addon ships
-- itself, keyed by fileBase (the SAME path SoundRegistry.lua builds for
-- each sound - category/name based, not the display name, so a rename
-- never breaks the lookup). Generated OUTSIDE the game (WoW addons cannot
-- read audio file bytes) by walking every MPEG frame header and summing
-- their sample counts - accurate for both CBR and VBR files, unlike a
-- single-bitrate estimate. Regenerate this file (do not hand-edit)
-- whenever a shipped sound file changes. A sound with no entry here just
-- has an unknown duration until it is played once in-game and learned
-- automatically - see SoundPlayer.lua.

local ADDON_NAME, SB = ...

SB.SoundDurations = {
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Anime Ahh"] = 0.888,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Anime Wow"] = 4.232,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Are you lost"] = 1.515,
    ["Interface\\AddOns\\Soundbook\\Sounds\\German Memes\\Auf Alkohol"] = 6.661,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Awolnation Run"] = 10.318,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Borat Vagine"] = 7.824,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Cant Touch This"] = 20.193,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Celebration"] = 10.214,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Charge Army"] = 7.497,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Charge Chivalry"] = 4.885,
    ["Interface\\AddOns\\Soundbook\\Sounds\\German Memes\\Charakter"] = 3.096,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Cthun You Will Die"] = 3.762,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Deja Vu"] = 6.296,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Dexter Meme"] = 10.71,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Donkey Hee Haw"] = 1.489,
    -- REGENERATED 2026-09-23 - shipped file measures 0.183s of actual
    -- MPEG audio (verified by walking every frame header), not the 0.392s
    -- this used to say. Smaller drift, likely wasn't noticed yet, flagged
    -- proactively.
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Dry Fart"] = 0.183,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Duel of the Fates"] = 15.984,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\El Chombo - Chacarron"] = 9.000,
    ["Interface\\AddOns\\Soundbook\\Sounds\\German Memes\\Einfach Geil"] = 2.873,
    ["Interface\\AddOns\\Soundbook\\Sounds\\German Memes\\Du bist gut genug"] = 7.367,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Emotional Damage"] = 3.396,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Epic Saxx"] = 7.445,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Fahhh"] = 2.351,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Fart 3D"] = 10.584,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Fart echo"] = 7.784,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Fart wet"] = 1.985,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Few Moments Later"] = 2.064,
    ["Interface\\AddOns\\Soundbook\\Sounds\\German Memes\\Feuerball Junge"] = 3.448,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Follow You"] = 8.255,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\GTA San"] = 7.706,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Gimme the loot"] = 3.072,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Goat Screaming"] = 1.907,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Haha Mexican"] = 3.370,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Haha Ostrich"] = 1.907,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Haha Peter"] = 1.332,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Halt Stop"] = 4.859,
    ["Interface\\AddOns\\Soundbook\\Sounds\\German Memes\\Hauen Sie ab"] = 5.198,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Hawk Tuah"] = 1.097,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Hehe Michael"] = 1.488,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Huh Cat"] = 0.366,
    ["Interface\\AddOns\\Soundbook\\Sounds\\German Memes\\Ich hab Ganis gemakt"] = 3.892,
    ["Interface\\AddOns\\Soundbook\\Sounds\\German Memes\\Ich muss raus"] = 2.011,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Imposter Reveal"] = 4.624,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\In The Beginning"] = 1.384,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Indian Song"] = 7.079,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Keyboard Meme"] = 4.467,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Leeroy Jenkins"] = 4.632,
    ["Interface\\AddOns\\Soundbook\\Sounds\\German Memes\\Luge Luge"] = 4.127,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Mein Team"] = 5.042,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Meme End"] = 10.248,
    ["Interface\\AddOns\\Soundbook\\Sounds\\German Memes\\Mir Egal"] = 5.329,
    ["Interface\\AddOns\\Soundbook\\Sounds\\German Memes\\Mir Stinken"] = 1.464,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Nani"] = 1.202,
    ["Interface\\AddOns\\Soundbook\\Sounds\\German Memes\\Nein Doch Oh"] = 1.776,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\No"] = 0.444,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Oh My God"] = 1.698,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Oh Shit MF"] = 2.456,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Okay Guy"] = 1.62,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Okayyy Lets Go"] = 1.855,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Parking"] = 6.113,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Parking Lot"] = 2.691,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Peon Work Work"] = 1.776,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Perfect Fart"] = 0.384,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Pornhub"] = 4.18,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Rick Vu Luvub Dub Dub"] = 1.541,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Rizzbot Laugh"] = 2.429,
    ["Interface\\AddOns\\Soundbook\\Sounds\\German Memes\\Schoki"] = 3.579,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Sexy"] = 9.117,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Shame"] = 4.336,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Thats me"] = 7.105,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\To be continued"] = 9.639,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Viel Gluck"] = 4.911,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Vine Boom"] = 1.332,
    ["Interface\\AddOns\\Soundbook\\Sounds\\German Memes\\Was Zitterstn so"] = 1.515,
    ["Interface\\AddOns\\Soundbook\\Sounds\\German Memes\\Weiss Nicht Digga"] = 2.712,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Wha Wha"] = 4.911,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Yamete Kudasai"] = 2.16,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Yippee"] = 2.717,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\Zehahaha"] = 5.016,
    ["Interface\\AddOns\\Soundbook\\Sounds\\Legacy\\dun dun dun"] = 5.172,
}
