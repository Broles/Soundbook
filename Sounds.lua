-- Sounds.lua
--
-- This is the ONLY file you need to edit to add new sounds.
-- Do NOT put settings, icons, favourites, or anything else in here -
-- this file is the static "source of truth" list of available sounds
-- and is not touched by the addon at runtime.
--
-- How it works:
--   1. Drop a sound file into the matching physical folder:
--        Sounds\Legacy\<name>.ogg        (or .mp3 / .wav) - ships with starter sounds
--        Sounds\German Memes\<name>.ogg  (or .mp3 / .wav) - ships with starter sounds
--        Sounds\Category1\<name>.ogg     (or .mp3 / .wav) - yours to fill in
--        Sounds\Category2\<name>.ogg     (or .mp3 / .wav) - yours to fill in
--   2. Add the exact file name (WITHOUT the extension) as a string
--      into the matching list below.
--   3. Fully restart WoW (not just /reload - see README.md).
--
-- Example: the entry "Vine Boom" in the Legacy list below expects a file
--   Sounds\Legacy\Vine Boom.ogg   (or Vine Boom.mp3 / Vine Boom.wav)
-- and will show up in-game as a sound named "Vine Boom". Supported formats
-- are .ogg, .mp3, and .wav - you never write the extension here, Soundbook
-- detects it automatically.
--
-- "Legacy", "German Memes", 1, 2 are fixed physical categories. Their
-- in-game display names/icons can be changed later in Soundbook Settings
-- without touching this file or renaming any folder.
--
-- Optional: give a sound a DEFAULT icon in code, so everyone who gets this
-- entry (via CurseForge, Soundbook_Private, ...) sees that icon from the
-- start instead of the generic question mark - by writing a table instead
-- of a plain name string:
--   { name = "Bosskill", icon = "Interface\\Icons\\Achievement_Boss_Illidan" }
-- Anyone can still pick a different icon for it in-game as normal (Edit
-- window) - that always wins over this default, per player. Every entry
-- below has one - best-effort picks, not verified in-game one by one, so a
-- few may need swapping via the in-game icon picker if they turn up blank.
--
-- Optional: add search aliases so players can find a sound by emotion,
-- context, or origin - not just its exact name:
--   { name = "Zehahaha", icon = "...", tags = { "lachen", "laugh", "lol", "pirat" } }
-- Tags are matched case-insensitively against the search box. A sound with
-- no tags field is still fully functional - just found by name only.

SoundbookSounds = {
    -- Ships with the addon - a starter pack of common meme/social/streaming
    -- sounds, so there's something to play with immediately after install.
    ["Legacy"] = {
        { name = "aaahhhhhh!",            icon = "Interface\\Icons\\Spell_Holy_Excorcism",         tags = { "schrei", "panik", "scream", "panic", "angst", "fear" } },
        { name = "Anime Ahh",             icon = "Interface\\Icons\\Spell_Holy_Silence",            tags = { "anime", "ahh", "stöhnen", "moan", "japan", "cringe" } },
        { name = "Anime Wow",             icon = "Interface\\Icons\\Spell_Nature_Lightning",        tags = { "anime", "wow", "überraschung", "surprise", "japan", "beeindruckt" } },
        { name = "Are you lost",          icon = "Interface\\Icons\\INV_Misc_Map_01",               tags = { "verloren", "lost", "verwirrt", "confused", "wo", "where", "babygirl" } },
        { name = "Awolnation Run",        icon = "Interface\\Icons\\Ability_Rogue_Sprint",          tags = { "run", "rennen", "flucht", "flee", "musik", "music", "lied" } },
        { name = "Borat Vagine",          icon = "Interface\\Icons\\INV_Jewelry_Ring_01",           tags = { "borat", "vagine", "vagina", "gift", "geschenk", "entry", "eintritt", "dating", "romance", "awkward", "cringe", "movie", "film", "kazakhstan" } },
        { name = "Brother eeew",          icon = "Interface\\Icons\\Spell_Shadow_Charm",            tags = { "ekel", "disgust", "igitt", "gross", "eeew", "bruder", "brother", "arab" } },
        { name = "Cant Touch This",       icon = "Interface\\Icons\\INV_Gauntlets_04",              tags = { "mc hammer", "untouchable", "unantastbar", "musik", "dance", "tanzen" } },
        { name = "Celebration",           icon = "Interface\\Icons\\Spell_Holy_SurgeOfLight",      tags = { "feier", "celebrate", "sieg", "win", "party", "jubel", "hurra" } },
        { name = "Charge Army",           icon = "Interface\\Icons\\INV_BannerPVP_01",              tags = { "angriff", "attack", "charge", "armee", "army", "krieg", "war", "raid" } },
        { name = "Charge Chivalry",       icon = "Interface\\Icons\\INV_Shield_04",                tags = { "ritter", "knight", "charge", "angriff", "attack", "mittelalter" } },
        { name = "Cthun You Will Die",    icon = "Interface\\Icons\\Spell_Shadow_ShadowWordPain",  tags = { "wow", "cthun", "boss", "raid", "sterben", "die", "drohung", "threat", "aq40" } },
        { name = "Daddy Chill",           icon = "Interface\\Icons\\Spell_Frost_Stun",             tags = { "chill", "beruhig", "relax", "ruhig", "calm", "daddy", "tiktok" } },
        { name = "Deja Vu",               icon = "Interface\\Icons\\Spell_Nature_Sleep",           tags = { "deja vu", "initial d", "eurobeat", "drift", "auto", "car", "musik" } },
        { name = "Dexter Meme",           icon = "Interface\\Icons\\Ability_Rogue_Eviscerate",     tags = { "dexter", "labor", "serie", "show", "musik", "theme", "meme" } },
        { name = "Donkey Hee Haw",        icon = "Interface\\Icons\\INV_Misc_Pelt_Wolf_01",        tags = { "esel", "donkey", "tier", "animal", "hee haw", "lustig", "funny" } },
        { name = "Dry Fart",              icon = "Interface\\Icons\\INV_Misc_Dust_02",             tags = { "furz", "fart", "pups", "trocken", "dry", "peinlich", "cringe" } },
        { name = "Duel of the Fates",     icon = "Interface\\Icons\\INV_Sword_04",                 tags = { "duel of the fates", "star wars", "darth maul", "jedi", "sith", "lightsaber", "lichtschwert", "duel", "battle", "kampf", "epic", "choir", "chor", "boss", "finale", "john williams" } },
        { name = "El Chombo - Chacarron", icon = "Interface\\Icons\\INV_Misc_Drum_01",             tags = { "chacarron", "el chombo", "music", "musik", "song", "dance", "reggaeton", "latin", "nonsense", "gibberish", "mumbling", "mumble", "kauderwelsch", "meme" } },
        { name = "Emotional Damage",      icon = "Interface\\Icons\\Spell_Shadow_DeathScream",     tags = { "emotional damage", "steven he", "schmerz", "pain", "hurt", "tiktok", "meme" } },
        { name = "Epic Saxx",             icon = "Interface\\Icons\\INV_Misc_Horn_01",             tags = { "saxophon", "saxophone", "epic", "musik", "music", "sax", "80er" } },
        { name = "Excuse me bruh",        icon = "Interface\\Icons\\Ability_Warrior_Challange",    tags = { "excuse", "entschuldigung", "bruh", "konfrontation", "confront", "warte mal" } },
        { name = "Fahhh",                 icon = "Interface\\Icons\\INV_Misc_Horn_02",             tags = { "schrei", "scream", "fahh", "reaktion", "reaction", "horror" } },
        { name = "Fart 3D",               icon = "Interface\\Icons\\Ability_Creature_Poison_06",   tags = { "fart", "furz", "pups", "3d", "spatial", "surround", "stereo", "binaural", "ear to ear", "moving", "gross", "eklig", "funny", "lustig" } },
        { name = "Fart echo",             icon = "Interface\\Icons\\INV_Misc_Dust_01",             tags = { "furz", "fart", "echo", "hall", "pups", "lustig", "funny" } },
        { name = "Fart wet",              icon = "Interface\\Icons\\INV_Misc_Dust_04",             tags = { "furz", "fart", "nass", "wet", "pups", "eklig", "gross" } },
        { name = "Few Moments Later",     icon = "Interface\\Icons\\INV_Misc_PocketWatch_01",      tags = { "spongebob", "moment", "später", "later", "erzähler", "narrator", "pause" } },
        { name = "Follow You",            icon = "Interface\\Icons\\INV_Misc_Spyglass_03",         tags = { "follow", "folgen", "lied", "song", "imagine dragons", "musik" } },
        { name = "Gimme the loot",        icon = "Interface\\Icons\\INV_Misc_Coin_01",             tags = { "loot", "beute", "gib", "give", "gier", "greedy", "biggie" } },
        { name = "Goat Screaming",        icon = "Interface\\Icons\\INV_Misc_Horn_02",             tags = { "goat", "ziege", "scream", "schrei", "animal", "tier", "panic", "panik", "loud", "reaction", "meme" } },
        { name = "GTA San",               icon = "Interface\\Icons\\INV_Misc_Bag_10",              tags = { "gta", "san andreas", "gangster", "rap", "musik", "ahh" } },
        { name = "Haha Mexican",          icon = "Interface\\Icons\\INV_Misc_Bandana_01",          tags = { "lachen", "laugh", "mexiko", "mexican", "lol", "haha", "lustig", "funny" } },
        { name = "Haha Ostrich",          icon = "Interface\\Icons\\INV_Feather_01",               tags = { "lachen", "laugh", "strauß", "ostrich", "tier", "animal", "haha", "lol" } },
        { name = "Haha Peter",            icon = "Interface\\Icons\\INV_Misc_Head_Dwarf_01",       tags = { "peter", "family guy", "lachen", "laugh", "haha", "lol", "serie" } },
        { name = "Halt Stop",             icon = "Interface\\Icons\\Spell_Frost_Stun",             tags = { "halt", "stop", "stopp", "einfrieren", "freeze", "stun", "keine bewegung" } },
        { name = "Hawk Tuah",             icon = "Interface\\Icons\\Ability_Warrior_Challange",    tags = { "hawk tuah", "spit", "spucken", "tiktok", "meme", "viral" } },
        { name = "Hehe Michael",          icon = "Interface\\Icons\\INV_Misc_Head_Human_01",       tags = { "michael", "lachen", "laugh", "hehe", "lol", "schurke", "villain" } },
        { name = "Huh Cat",               icon = "Interface\\Icons\\Spell_Nature_Polymorph",       tags = { "katze", "cat", "huh", "verwirrt", "confused", "tier", "animal", "meme" } },
        { name = "Imposter Reveal",       icon = "Interface\\Icons\\Ability_Rogue_Ambush",         tags = { "among us", "imposter", "sus", "enthüllt", "reveal", "betrug", "cheat" } },
        { name = "In The Beginning",      icon = "Interface\\Icons\\Spell_Arcane_Blink",           tags = { "anfang", "beginning", "start", "gott", "god", "dramatic", "dramatisch" } },
        { name = "Indian Song",           icon = "Interface\\Icons\\INV_Misc_Bell_01",             tags = { "indien", "india", "bollywood", "musik", "music", "tanzen", "dance" } },
        { name = "Keyboard Meme",         icon = "Interface\\Icons\\INV_Misc_Wrench_01",           tags = { "tastatur", "keyboard", "tippen", "typing", "nerd", "pc", "computer" } },
        { name = "Leeroy Jenkins",        icon = "Interface\\Icons\\INV_Sword_04",                 tags = { "leeroy", "jenkins", "wow", "classic", "raid", "charge", "angriff", "meme" } },
        { name = "Mein Team",             icon = "Interface\\Icons\\INV_BannerPVP_02",             tags = { "team", "gruppe", "group", "raid", "mein", "my", "zusammen", "together" } },
        { name = "Meme End",              icon = "Interface\\Icons\\Ability_Rogue_FeignDeath",     tags = { "ende", "end", "fertig", "done", "fail", "meme", "tot", "dead" } },
        { name = "Nani",                  icon = "Interface\\Icons\\Spell_Nature_Cyclone",         tags = { "nani", "anime", "japan", "überraschung", "surprise", "was", "what" } },
        { name = "No",                    icon = "Interface\\Icons\\INV_Misc_Bomb_02",             tags = { "nein", "no", "ablehnung", "reject", "verbot", "forbidden", "stopp" } },
        { name = "Oh My God",             icon = "Interface\\Icons\\Spell_Holy_HolyBolt",          tags = { "omg", "oh my god", "schock", "shock", "überraschung", "surprise", "reaktion" } },
        { name = "Oh Shit MF",            icon = "Interface\\Icons\\Spell_Shadow_ShadowBolt",      tags = { "scheiße", "shit", "oh no", "panik", "panic", "fehler", "mistake", "fail" } },
        { name = "Okay Guy",              icon = "Interface\\Icons\\Spell_Holy_WordFortitude",     tags = { "okay", "ok", "alright", "guy", "meme", "akzeptiert", "accepted" } },
        { name = "Okayyy Lets Go",        icon = "Interface\\Icons\\Spell_Nature_Swiftness",       tags = { "lets go", "okay", "los", "start", "bereit", "ready", "motivation" } },
        { name = "Parking",               icon = "Interface\\Icons\\Spell_Nature_TimeStop",        tags = { "parken", "parking", "auto", "car", "falsch", "wrong", "halt" } },
        { name = "Parking Lot",           icon = "Interface\\Icons\\INV_Crate_01",                 tags = { "parkplatz", "parking lot", "auto", "car", "draußen", "outside" } },
        { name = "Peon Work Work",        icon = "Interface\\Icons\\Trade_Mining",                 tags = { "peon", "work", "arbeit", "warcraft", "wow", "classic", "orc" } },
        { name = "Perfect Fart",          icon = "Interface\\Icons\\INV_Misc_Dust_03",             tags = { "furz", "fart", "perfekt", "perfect", "pups", "ideal", "lustig" } },
        { name = "Pornhub",               icon = "Interface\\Icons\\INV_Misc_Spyglass_02",         tags = { "pornhub", "intro", "musik", "music", "hub", "meme", "cringe" } },
        { name = "Rick Vu Luvub Dub Dub", icon = "Interface\\Icons\\INV_Misc_Gem_02",             tags = { "rick", "rickroll", "luvub", "dub", "musik", "meme", "trolling" } },
        { name = "Rizzbot Laugh",         icon = "Interface\\Icons\\Spell_Nature_Purge",           tags = { "rizz", "rizzbot", "lachen", "laugh", "lol", "haha", "cringe" } },
        { name = "Sexy",                  icon = "Interface\\Icons\\INV_Jewelry_Ring_01",          tags = { "sexy", "heiß", "hot", "musik", "verlockend", "seductive", "flirt" } },
        { name = "Shame",                 icon = "Interface\\Icons\\Spell_Shadow_SoulLeech_2",     tags = { "schande", "shame", "scham", "glocke", "bell", "game of thrones", "got" } },
        { name = "Thats me",              icon = "Interface\\Icons\\Spell_Holy_Renew",             tags = { "das bin ich", "thats me", "ich", "me", "selbst", "self", "zeigen" } },
        { name = "To be continued",       icon = "Interface\\Icons\\Ability_Warrior_Charge",       tags = { "to be continued", "jojo", "fortsetzung", "folgt", "cliffhanger", "meme" } },
        { name = "Viel Gluck",            icon = "Interface\\Icons\\INV_Misc_Head_Human_02",       tags = { "viel glück", "good luck", "gl", "glück", "luck", "wunsch", "wish" } },
        { name = "Vine Boom",             icon = "Interface\\Icons\\Spell_Fire_FlameBolt",         tags = { "vine", "boom", "bass", "drop", "meme", "viral", "tiktok", "impact" } },
        { name = "Wha Wha",               icon = "Interface\\Icons\\Spell_Shadow_SoulLeech_3",     tags = { "wha wha", "trompete", "trumpet", "fail", "versagen", "loser", "sad" } },
        { name = "what did he sayyyyy",   icon = "Interface\\Icons\\Spell_Holy_MindVision",        tags = { "was hat er gesagt", "schock", "shock", "reaktion", "reaction", "unglaube" } },
        { name = "Yamete Kudasai",        icon = "Interface\\Icons\\Spell_Nature_Slow",            tags = { "yamete", "anime", "japan", "stop", "stopp", "bitte", "please", "cringe" } },
        { name = "Yippee",                icon = "Interface\\Icons\\Ability_Warrior_BattleShout",  tags = { "yippee", "freude", "joy", "jubel", "cheer", "sieg", "win", "tbh creature" } },
        { name = "Zehahaha",              icon = "Interface\\Icons\\Ability_Warrior_Rampage",      tags = { "lachen", "laugh", "lol", "haha", "pirat", "pirate", "one piece", "zeha", "marshall d. teach", "blackbeard", "anime" } },
        { name = "dun dun dun",           icon = "Interface\\Icons\\INV_Misc_Drum_02",             tags = { "spannung", "suspense", "dramatisch", "dramatic", "dun", "musik", "thriller" } },
    },

    ["German Memes"] = {
        { name = "Auf Alkohol",           icon = "Interface\\Icons\\INV_Drink_05",                 tags = { "alkohol", "alcohol", "saufen", "drink", "prost", "cheers", "trinken", "homer", "simpsons" } },
        { name = "Charakter",             icon = "Interface\\Icons\\Spell_Holy_InnerFire",         tags = { "charakter", "character", "persönlichkeit", "personality", "german", "deutsch" } },
        { name = "Du bist gut genug",     icon = "Interface\\Icons\\Spell_Holy_LayOnHands",        tags = { "gut genug", "good enough", "motivation", "aufmuntern", "encourage", "trost" } },
        { name = "Einfach Geil",          icon = "Interface\\Icons\\INV_Misc_Gem_01",              tags = { "geil", "awesome", "toll", "great", "begeistert", "excited", "german" } },
        { name = "Feuerball Junge",       icon = "Interface\\Icons\\Spell_Fire_Fireball02",        tags = { "feuerball", "fireball", "junge", "boy", "deutsch", "german", "schaden", "damage" } },
        { name = "Hauen Sie ab",          icon = "Interface\\Icons\\Spell_Holy_Excorcism_02",      tags = { "hauen sie ab", "get out", "raus", "weg", "leave", "geh weg", "wut", "anger" } },
        { name = "Ich hab Ganis gemakt",  icon = "Interface\\Icons\\INV_Scroll_03",                tags = { "ganis", "gemacht", "gemakt", "fertig", "done", "deutsch", "dialekt", "epic" } },
        { name = "Ich muss raus",         icon = "Interface\\Icons\\Spell_Magic_LesserInvisibilty",tags = { "raus", "leave", "weg", "out", "flucht", "escape", "ich muss", "gehen" } },
        { name = "Luge Luge",             icon = "Interface\\Icons\\Spell_Shadow_ManaBurn",        tags = { "lüge", "lie", "luge", "luegen", "lying", "betrug", "cheat", "falsch" } },
        { name = "Mir Egal",              icon = "Interface\\Icons\\INV_Misc_Note_02",             tags = { "egal", "dont care", "ignorieren", "ignore", "gleichgültig", "whatever", "mir egal" } },
        { name = "Mir Stinken",           icon = "Interface\\Icons\\Ability_Creature_Poison_06",   tags = { "stinken", "stink", "gestank", "smell", "ekel", "disgust", "pfui" } },
        { name = "Nein Doch Oh",          icon = "Interface\\Icons\\Spell_Shadow_Charm",           tags = { "nein", "doch", "no", "yes", "oh", "überraschung", "surprise", "german", "meme" } },
        { name = "Schoki",                icon = "Interface\\Icons\\INV_Misc_Food_11",             tags = { "schokolade", "chocolate", "schoki", "süß", "sweet", "lecker", "food", "simpsons", "ralph", "fettsack", "fatso" } },
        { name = "Was Zitterstn so",      icon = "Interface\\Icons\\Spell_Shadow_Possession",      tags = { "zittern", "shake", "tremble", "nervous", "angst", "fear", "beben" } },
        { name = "Weiss Nicht Digga",     icon = "Interface\\Icons\\Spell_Holy_MindVision",        tags = { "weiss nicht", "dont know", "keine ahnung", "no idea", "digga", "german", "rap" } },
    },

    [1] = {
        -- Put Category 1 sound names here once you add files to Sounds\Category1\
    },

    [2] = {
        -- Put Category 2 sound names here once you add files to Sounds\Category2\
    },
}
