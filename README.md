# Soundbook 3.0.0

Soundbook is an Arcane Codex-style soundboard for **World of Warcraft**. It combines local playback, a 20-slot Favourites system, per-sound customization, multiplayer sharing, receive controls, raid administration, history, and anonymous community statistics in one lightweight addon.

Version 3.0.0 is a full UI/UX redesign of the Main Soundbook and the always-on HUD - see "Main Soundbook" below - built on top of the same 2.7.2 backend (multiplayer protocol, SavedVariables, Favourites, Analytics). It ships a single TOC file covering every currently live WoW client family, using the comma-separated multi-interface format:

```
## Interface: 11509, 16001, 20506, 50504, 120100
```

This is the same mechanism [BigWigs](https://github.com/BigWigsMods/BigWigs/blob/master/BigWigs.toc) - one of the most widely used multi-client addons - uses in its own single TOC file (verified directly against their repo, which independently confirms 16001 as WoW Forever's interface number and 120100 as Retail's current one). One physical file, no filename-suffix guessing, no risk of a client silently not recognizing a suffix it doesn't know about.

| Client | Interface | Status |
| --- | --- | --- |
| Classic Era (incl. Season of Discovery, Hardcore) | 11509 | Static-analysis verified only, not yet live-tested |
| WoW Forever (beta) | 16001 | Static-analysis verified only, not yet live-tested — see the known upstream bug below before relying on it |
| Burning Crusade Classic (Anniversary) | 20506 | Confirmed in live use |
| Mists of Pandaria Classic (progression realms) | 50504 | Not yet audited, not yet live-tested |
| Retail | 120100 | Added without a dedicated audit pass — see note below |

Season of Discovery and Hardcore realms run on the same client build as Classic Era, so interface 11509 covers them too. Wrath Classic and Cataclysm Classic are not listed separately: as of this writing those expansions aren't offered as standalone live realm types (the progression-realm cycle has moved past them to Mists) — add their interface numbers to the comma list if/when Blizzard reopens them.

"Static-analysis verified" means the code was audited against the target client's known API surface and the existing compatibility layer in `Core.lua`, but has not been confirmed by an actual playtest on that client. The Mists and Retail entries have not had that audit pass at all yet; they rely on `Core.lua`'s existing fallbacks (which all prefer the modern API most recent clients use natively) but haven't been checked for flavor-specific concerns such as combat-lockdown/taint edge cases. Report issues if something breaks.

### Known upstream bug: WoW Forever SavedVariables

The WoW Forever beta client (confirmed on builds 1.60.1.69893 and 1.60.1.69913) has an active, widely-reported bug: addon SavedVariables are written to disk correctly but are **not loaded back** on the next login, `/reload`, or character switch - every session effectively starts blank. This is a client bug, not a Soundbook bug; it's tracked in multiple threads on Blizzard's own forums, and a third-party workaround tool ([`ForeverSVFix`](https://github.com/nobewayo/ForeverSVFix)) exists. Until Blizzard fixes it, expect favourites, settings, and history to reset on Forever between sessions regardless of what this addon does. Not something we can code around from inside Soundbook.

## Main Soundbook

The Main Soundbook is one continuously scrolling Sound Library, not a paged, right-side-tabbed book:

- **My Favourites first**, then a collapsible section per category (click a section header to expand/collapse it - state is remembered).
- **Search and tag filters** (New/Trending/Popular/Loved/Legendary/Cringe/Dusty), plus a **"Send to:"** dropdown, sit in a row below the header. "Send to:" is a single-select control choosing where a plain left-click sends a sound: All (whichever channels are enabled under Settings -> Multiplayer), a specific group (Guild/Raid-Party/Friends), a specific player, or Self Only.
- A gear icon at the header's top-left opens **Settings** inside the same window (two-pane layout: General, Playback, Multiplayer, Appearance, Categories, Advanced). Quick Audio, Lock, and Close sit at the header's top-right; Raid Admin appears as its own tab when you have the authority to use it.
- **Announcer** replaces the old Mini Soundbook window as the always-on HUD - see "Announcer" below.
- **Edit Sound** is compact - "Change Icon" opens a picker popup instead of permanently embedding the icon grid - and warns before discarding unsaved changes.

Existing data (favourites, keybinds, sound customizations, history, analytics, settings) carries over automatically on first login after upgrading - nothing needs to be redone.

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

Do not delete `Soundbook.lua` from SavedVariables when upgrading. Soundbook migrates supported older data in place only after a detached copy has passed migration, sanitation, and validation. See `MIGRATION.md` for details.

## Everyday controls

- `/sb` opens or closes the main Soundbook.
- Left-click a sound card to play it using its effective output target (per-sound override, else the "Send to:" default, else All).
- Right-click a sound card to edit its name, icon, favourite/mute state, alternate sound, and macro command.
- Shift-left-click toggles a favourite; Shift-right-click opens a one-off "send to..." menu without changing the "Send to:" default.
- Search and the tag pills filter across every category at once; category sections auto-expand to show matches and restore their collapsed state afterward.
- The Library adapts its column count to the window's width as you resize.
- `/sb fav` toggles the Announcer.

## Announcer

The Announcer is the always-on HUD that replaces the old Mini Soundbook window - a small icon rather than a second full window:

- idle: just the app icon, movable, with small indicators for an active incoming-mute or raid-admin restriction;
- active: expands into a compact banner (sound name, sender, channel, real playback progress) for as long as a Soundbook sound is playing, local or received;
- right-click the active banner to mute just that one sound;
- right-click the idle icon for Quick Options (mute incoming, lock, muted players, open Soundbook);
- handles overlapping sounds (shows a `+N` badge, promotes the next one when the primary ends) and a compact queue indicator when remote sounds are waiting;
- expands away from whichever screen edge it's closest to, so it always stays fully on-screen.

Left-click the idle icon (or hover it, if "Open on hover" is enabled) to expand a compact "Mini Soundbook" grid of your favourites for quick access without opening the Main window. Managing favourites - adding, removing, renaming - still happens in the Main Soundbook's own Library (see "Main Soundbook" above); the Announcer's popup is a read/play-only shortcut to the same 20 slots.

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

Analytics is enabled by default and always-on - the Trending/Popular/Legendary/... tags only work with a wide, shared data pool, so there is no toggle for it in Settings. A player who wants out uses `/sb analytics off`, which immediately stops collection, cancels delayed/repeating sync work, and removes unsent analytics packets from the transport queue. Existing local history remains available and is not deleted.

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
| `/sb fav` | Toggle the Announcer |
| `/sb history` | Open the last 10 successful received sounds |
| `/sb analytics` | Open anonymous community statistics |
| `/sb analytics on\|off` | Enable or disable analytics |
| `/sb play <category::name>` | Play a stable sound ID |
| `/sb play <category::name>::<target>` | Play with an explicit Self/Friends/Guild/Party/Raid/player target |
| `/sb stop` | Stop Soundbook playback and clear incoming/outgoing play queues |
| `/sb mute` | Toggle receiving while remembering channel choices |
| `/sb doctor` | Print version, database, queue, transport, analytics, and routing diagnostics |
| `/sb reset` | Reset window positions and the Announcer's position |
| `/sb debug` | Toggle diagnostic logging |
| `/sb help` | Show the command list |

Stable sound IDs use `<category>::<name>`. A customized display name does not change the ID, so macros keep working.

## Compatibility and recovery

- Target interfaces: `16001` (WoW Forever), `11509` (Classic Era), `20506` (Burning Crusade Classic Anniversary), `50504` (Mists of Pandaria Classic), `120100` (Retail) — see the table above for verification status.
- Retail-style APIs are used only when available and have Classic-compatible fallbacks where required.
- Optional sound-handle progress tracking degrades cleanly when `C_Sound.IsPlaying` is unavailable.
- A database written by a newer Soundbook version is opened in non-committing compatibility mode; it is never downgraded.
- A corrupt or cyclic SavedVariables table falls back to safe runtime defaults without overwriting the original table.

The complete verification boundary and live-client checklist are in `QA_REPORT.md` and `TESTING.md`.
