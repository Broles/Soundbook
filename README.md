# Soundbook 2.7.2

Soundbook is an Arcane Codex-style soundboard for **World of Warcraft**. It combines local playback, a 20-slot Mini Soundbook, per-sound customization, multiplayer sharing, receive controls, raid administration, history, and anonymous community statistics in one lightweight addon.

Version 2.7.2 ships a single TOC file covering every currently live WoW client family, using the comma-separated multi-interface format:

```
## Interface: 11509, 16001, 20506, 50504, 120005
```

This is the same mechanism [BigWigs](https://github.com/BigWigsMods/BigWigs/blob/master/BigWigs.toc) - one of the most widely used multi-client addons - uses in its own single TOC file (verified directly against their repo, which independently confirms 16001 as WoW Forever's interface number). One physical file, no filename-suffix guessing, no risk of a client silently not recognizing a suffix it doesn't know about.

| Client | Interface | Status |
| --- | --- | --- |
| Classic Era (incl. Season of Discovery, Hardcore) | 11509 | Static-analysis verified only, not yet live-tested |
| WoW Forever (beta) | 16001 | Static-analysis verified only, not yet live-tested |
| Burning Crusade Classic (Anniversary) | 20506 | Confirmed in live use |
| Mists of Pandaria Classic (progression realms) | 50504 | Not yet audited, not yet live-tested |
| Retail | 120005 (unconfirmed — patch 12.1 may have shifted this to 120100; verify with `/run print(select(4,GetBuildInfo()))` in-game) | Added without a dedicated audit pass — see note below |

Season of Discovery and Hardcore realms run on the same client build as Classic Era, so interface 11509 covers them too. Wrath Classic and Cataclysm Classic are not listed separately: as of this writing those expansions aren't offered as standalone live realm types (the progression-realm cycle has moved past them to Mists) — add their interface numbers to the comma list if/when Blizzard reopens them.

"Static-analysis verified" means the code was audited against the target client's known API surface and the existing compatibility layer in `Core.lua`, but has not been confirmed by an actual playtest on that client. The Mists and Retail entries have not had that audit pass at all yet; they rely on `Core.lua`'s existing fallbacks (which all prefer the modern API most recent clients use natively) but haven't been checked for flavor-specific concerns such as combat-lockdown/taint edge cases. Report issues if something breaks.

## Install or upgrade

1. Close World of Warcraft completely.
2. Back up `WTF/Account/<account>/SavedVariables/Soundbook.lua` before a major upgrade.
3. Copy the included `Soundbook` folder into your client's AddOns folder, e.g.:
   - Retail: `World of Warcraft/_retail_/Interface/AddOns/`
   - Burning Crusade Classic (Anniversary): `World of Warcraft/_anniversary_/Interface/AddOns/`
   - Mists of Pandaria Classic: same `_classic_era_`-style dedicated folder Blizzard assigns to that progression client (folder name not yet confirmed against a live install)
   - Classic Era: `World of Warcraft/_classic_era_/Interface/AddOns/`
   - WoW Forever (beta): `World of Warcraft/_classic_beta_/Interface/AddOns/`
4. Confirm that the final path is `Interface/AddOns/Soundbook/Soundbook.toc`.
5. Start the game, enable Soundbook, log in, and run `/sb doctor`.

Do not delete `Soundbook.lua` from SavedVariables when upgrading. Soundbook 2.5.0 migrates supported older data in place only after a detached copy has passed migration, sanitation, and validation. See `MIGRATION.md` for details.

## Everyday controls

- `/sb` opens or closes the main Soundbook.
- Left-click a library entry to play it using its saved output target.
- Right-click a library entry to edit its name, icon, favourite/mute state, alternate sound, and macro command.
- Shift-left-click toggles a favourite.
- Search filters the active library by display name.
- The main library adapts from 2 to 3 columns and from 10 to 16 rows, using between 20 and 48 entries per page as space permits.
- `/sb fav` toggles the Mini Soundbook.

## Mini Soundbook

The Mini Soundbook is a compact HUD tool rather than a second full window:

- up to 20 fixed favourite positions, including intentional gaps;
- left-click to play, right-click to choose a destination;
- drag onto another slot to move or swap;
- drag outside the deletion zone to remove the favourite;
- adaptive 3-to-10-column layout while resizing;
- lock, Stop All, and Mute Incoming controls;
- a reserved status strip showing sound name first, then sender and source;
- semantic source colors for Direct, Friends, Guild, Raid, Party, and Self;
- progress and overlap indicators when the client provides usable sound handles;
- a compact `+N` queue indicator when remote sounds are waiting.

The grid is never replaced by a large notification panel. Timer-driven status updates run only while their information is visible or active.

## Multiplayer

Soundbook sends only compact addon messages. It never transfers audio files. Every recipient therefore needs Soundbook and the same sound ID/file locally.

Sound Routing and Multiplayer settings control:

- Friends, Guild, Party, and Raid broadcasts;
- a single direct player target;
- independent receive permissions for Friends, Guild, Party, Raid, and Direct;
- a bounded incoming queue and remote cooldown;
- per-sound mute, timed global receive mute, and timed individual-player mute;
- raid/party leader controls with recipient acknowledgements.

Soundbook 3.0 validates message size, command, channel, sound ID, player target, and admin duration before acting. Incoming and outgoing traffic use bounded rate limits; playback and control messages take priority over presence and analytics traffic. Unknown commands and unsupported protocol versions are ignored safely.

Player identity comparisons are realm-aware. Two characters with the same name on different realms no longer share a mute, cooldown, acknowledgement, or reachable-player entry.

## Anonymous community analytics

Analytics stores and shares per-sound aggregate usage through a random installation ID. Analytics records contain no character name, realm, guild name, GUID, BattleTag, or account identifier.

Analytics is enabled by default and stays that way for everyone by design - the Trending/Popular/Legendary/... tags only work with a wide, shared data pool, so this is deliberately not a Settings checkbox. A player who explicitly wants out can still use `/sb analytics off`; that immediately stops collection, cancels delayed/repeating sync work, and removes unsent analytics packets from the transport queue. Existing local history remains available and is not deleted.

Use `/sb analytics on` to enable it again and `/sb analytics` to open the statistics window.

## Custom sounds

Use a separate companion addon such as `Soundbook_MySounds` for personal audio. Keeping custom files outside the main `Soundbook` folder prevents addon managers from deleting them during an update.

Supported formats are `.ogg`, `.mp3`, and `.wav`. Register the base file name without its extension. Soundbook probes the supported extensions once, caches the successful extension, and caches missing file bases for the current session. A failed new sound is probed before existing Soundbook playback is stopped, so a typo or missing file cannot cut off a valid sound already playing.

WoW discovers new media files at client startup. After adding audio, fully restart the client; `/reload` alone may not make the file available.

Example companion registration:

```lua
Soundbook.RegisterSounds({
    [1] = {
        { name = "Ready Check", icon = "Interface\\Icons\\INV_Misc_Note_01" },
    },
}, "Soundbook_MySounds")
```

The corresponding file would be `Soundbook_MySounds/Sounds/Category1/Ready Check.ogg` (or `.mp3`/`.wav`). Unsafe folder names, path traversal, protocol delimiters, control characters, and unreasonable durations are rejected.

## Slash commands

| Command | Result |
|---|---|
| `/sb` | Toggle the main window |
| `/sb fav` | Toggle the Mini Soundbook |
| `/sb history` | Open the last 10 successful received sounds |
| `/sb analytics` | Open anonymous community statistics |
| `/sb analytics on\|off` | Enable or disable analytics |
| `/sb play <category::name>` | Play a stable sound ID |
| `/sb play <category::name>::<target>` | Play with an explicit Self/Friends/Guild/Party/Raid/player target |
| `/sb stop` | Stop Soundbook playback and clear incoming/outgoing play queues |
| `/sb mute` | Toggle receiving while remembering channel choices |
| `/sb doctor` | Print version, database, grid, queue, transport, analytics, and routing diagnostics |
| `/sb reset` | Reset window positions and Mini size |
| `/sb debug` | Toggle diagnostic logging |
| `/sb help` | Show the command list |

Stable sound IDs use `<category>::<name>`. A customized display name does not change the ID, so macros keep working.

## Compatibility and recovery

- Target interfaces: `16001` (WoW Forever), `11509` (Classic Era), `20506` (Burning Crusade Classic Anniversary), `50504` (Mists of Pandaria Classic), `120005` (Retail, unconfirmed) — see the table above for verification status.
- Retail-style APIs are used only when available and have Classic-compatible fallbacks where required.
- Optional sound-handle progress tracking degrades cleanly when `C_Sound.IsPlaying` is unavailable.
- A database written by a newer Soundbook version is opened in non-committing compatibility mode; it is never downgraded.
- A corrupt or cyclic SavedVariables table falls back to safe runtime defaults without overwriting the original table.

The complete verification boundary and live-client checklist are in `QA_REPORT.md` and `TESTING.md`.
