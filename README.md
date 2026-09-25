# Soundbook 3.0.0

Soundbook is an Arcane Codex-style soundboard for **World of Warcraft**. It combines local playback, a 20-slot Favourites system, per-sound customization, multiplayer sharing, receive controls, raid administration, history, and anonymous community statistics in one lightweight addon.

Version 3.0.0 is a full UI/UX redesign of the Main Soundbook and the always-on HUD - see "Main Soundbook" below - built on top of the same 2.7.2 backend (multiplayer protocol, SavedVariables, Favourites, Analytics). It ships a single TOC file covering every currently live WoW client family, using the comma-separated multi-interface format:

```
## Interface: 11509, 16001, 20506, 50504, 120100
```

This is the same mechanism [BigWigs](https://github.com/BigWigsMods/BigWigs/blob/master/BigWigs.toc) - one of the most widely used multi-client addons - uses in its own single TOC file (verified directly against their repo, which independently confirms 16001 as WoW Forever's interface number and 120100 as Retail's current one). One physical file, no filename-suffix guessing, no risk of a client silently not recognizing a suffix it doesn't know about.

| Client | Interface | Status |
| --- | --- | --- |
| Classic Era (incl. Season of Discovery, Hardcore) | 11509 | Technically/static validated |
| WoW Forever (beta) | 16001 | Technically/static validated, subject to known client-specific upstream limitations — see the known upstream bug below before relying on it |
| Burning Crusade Classic (Anniversary) | 20506 | Live tested |
| Mists of Pandaria Classic (progression realms) | 50504 | Technically/static validated |
| Retail | 120100 | Technically/static validated |

Season of Discovery and Hardcore realms run on the same client build as Classic Era, so interface 11509 covers them too. Wrath Classic and Cataclysm Classic are not listed separately: as of this writing those expansions aren't offered as standalone live realm types (the progression-realm cycle has moved past them to Mists) — add their interface numbers to the comma list if/when Blizzard reopens them.

"Technically/static validated" means the code was audited against the target client's known API surface and the existing compatibility layer (`Core.lua`, `Transport.lua`) — including a dedicated compatibility-hardening pass covering Ignore-list lookups, addon-message send-result handling, and raid-roster enumeration — but has not been confirmed by an actual playtest on that client, since a live MoP/Retail/Forever/Classic Era client was not available during that pass. TBC Anniversary remains the only entry confirmed by live play; it is the baseline every other client's static audit is checked against for regressions. Report issues if something breaks.

### Known upstream bug: WoW Forever SavedVariables

The WoW Forever beta client (confirmed on builds 1.60.1.69893 and 1.60.1.69913) has an active, widely-reported bug: addon SavedVariables are written to disk correctly but are **not loaded back** on the next login, `/reload`, or character switch - every session effectively starts blank. This is a client bug, not a Soundbook bug; it's tracked in multiple threads on Blizzard's own forums, and a third-party workaround tool ([`ForeverSVFix`](https://github.com/nobewayo/ForeverSVFix)) exists. Until Blizzard fixes it, expect favourites, settings, and history to reset on Forever between sessions regardless of what this addon does. Not something we can code around from inside Soundbook.

## Main Soundbook

The Main Soundbook is one continuously scrolling Sound Library, not a paged, right-side-tabbed book:

- **My Favourites first**, then a collapsible section per category (click a section header to expand/collapse it - state is remembered).
- **Search and tag filters** (New/Trending/Popular/Loved/Legendary/Cringe/Dusty), plus a **"Send to:"** dropdown, sit in a row below the header. "Send to:" chooses where a plain left-click sends a sound: All (whichever channels are enabled under Settings -> Multiplayer), Self Only, or a specific group - Guild, Raid/Party, or Friends. Opening Guild/Raid/Friends inside that same dropdown expands a checkbox list of that channel's reachable Soundbook users right underneath it, narrowing a plain click to only the selected people instead of the whole channel - see "Recipients" below. A one-off send to one specific person (regardless of the current "Send to:" setting) is still available from a Mini Soundbook slot's own right-click "send to..." menu.
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
- active: expands into a compact banner for as long as a Soundbook sound is playing, local or received - a large icon fills nearly the full banner height on the left, the sound name and sender/channel line sit beside it, and the duration reads right-aligned directly above the real progress bar spanning the remaining width;
- right-click the active banner to mute just that one sound;
- right-click the idle icon for Quick Options (mute incoming, lock, muted players, open Soundbook);
- handles overlapping sounds (each additional currently-playing sound shows as a thin gold vertical marker - with a dark edge behind it for contrast against any fill colour - inside the progress bar, positioned by its own remaining time relative to the displayed sound's, disappearing the instant that sound ends - promotes the next one when the primary ends) and a compact queue indicator when remote sounds are waiting;
- expands away from whichever screen edge it's closest to, so it always stays fully on-screen; its own tooltip does the same, always anchoring to whichever side the Mini Soundbook/Quick Options popup would NOT expand into so it never overlaps it.

Left-click the idle icon (or hover it, if "Open on hover" is enabled) to expand a compact "Mini Soundbook" grid of your favourites for quick access without opening the Main window. Managing favourites - adding, removing, renaming - still happens in the Main Soundbook's own Library (see "Main Soundbook" above); the Announcer's popup is a read/play-only shortcut to the same 20 slots. Clicking a favourite plays it without closing the grid - the clicked slot shows its own progress fill for as long as it plays, further favourites stay clickable (with overlap enabled, several can show progress at once), and the grid still collapses normally once you actually move away from it. Each slot also shows a thin gold border while hovered or while its own sound is playing (either alone is enough, and the two never stack into a heavier border).

Its title bar shows exactly who a click would reach right now, in that channel's own colour. For a single channel (Guild/Raid-Party/Friends) it shows their actual names ("Play for Alice and Bob:") instead of a bare count whenever they genuinely fit - a real pixel-width measurement against the title bar's actual width, not a fixed cap, so any number of short names is shown as names as long as they fit, and it only falls back to a count ("Play for Guild (3):") once they wouldn't. Zero selected recipients reads "Guild (0):" rather than silently falling back to "Play for Yourself". The title also recalculates immediately on a font/Text Size change, in addition to resizing, recipient selection, and roster changes. "All" and Self Only are unaffected.

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

### Recipients

Guild, Raid/Party, and Friends each support an optional per-player recipient subset, entirely inside the "Send to:" dropdown itself - no separate control. A narrowed subset survives `/reload` intact; the active channel itself (Guild/Raid/Friends/All/Self) is an ordinary persisted setting and survives a full client restart too, but a narrowed subset resets to "everyone selected" the next time you log in fresh, rather than carrying over a possibly stale list of names from a previous session. Clicking one of those three channel rows makes it the active channel and expands its reachable Soundbook users as checkboxes directly beneath it, in the same open list; every reachable member is selected by default. Clicking the already-active channel's row again toggles everyone off or back on, without closing the list - individual members can also be checked/unchecked freely, any number of times, without reopening the menu.

The channel's own label reflects this without noise: the untouched default (everyone currently reachable) shows a bare count ("Guild (3)"), an actual manual narrowing shows "selected/available" ("Guild (2/3)", including an explicit "Guild (0/3)"), and nobody reachable at all just shows the bare channel name with no count and no placeholder/offline text ("Guild") - never "(0/0)". If everyone reachable in an active channel goes offline, that channel stays selected (never falls back to Self or another channel) and its label simply drops to the bare name; it picks back up the moment anyone becomes reachable again.

While every reachable member is selected, a newly available Soundbook user in that channel joins automatically - "Friends 3/3" becomes "4/4" the moment a fourth friend comes online, with no action needed. The moment a member is deliberately deselected (or everyone is toggled off), that stops: the selection becomes an explicit list, a new arrival shows up in the member list but stays unchecked, and the count's denominator grows without its numerator ("2/3" becomes "2/4") - including when every member has been deselected ("0/3" becomes "0/4"). Manually re-checking everyone by hand returns to the automatic behaviour. Switching to a different channel immediately collapses the previous one's member list and discards its subset entirely; reactivating a channel later always starts fresh with everyone currently reachable selected. Only one channel's subset is ever active at a time, and a large roster scrolls inside the dropdown rather than growing it indefinitely.

A narrowed Guild/Raid send still travels as individual whispers on the wire (Guild/Raid channel messages can't be addressed to specific people), but is received, gated, and acknowledged exactly like a whole-channel broadcast - never mistaken for a Direct send or a plain Friends whisper. Per-sound Default Output overrides and macro `::Target` sends always reach the whole channel, unaffected by this.

Player identity comparisons are realm-aware. Two characters with the same name on different realms no longer share a mute, cooldown, acknowledgement, or reachable-player entry.

## Anonymous community analytics

Analytics stores and shares per-sound aggregate usage through a random installation ID. Analytics records contain no character name, realm, guild name, GUID, BattleTag, or account identifier.

Analytics is enabled by default and always-on - the Trending/Popular/Legendary/... tags only work with a wide, shared data pool, so there is no toggle for it in Settings. A player who wants out uses `/sb analytics off`, which immediately stops collection, cancels delayed/repeating sync work, and removes unsent analytics packets from the transport queue. Existing local history remains available and is not deleted.

Use `/sb analytics on` to enable it again and `/sb analytics` to open the statistics window.

## Custom sounds

Use a separate companion addon such as `Soundbook_MySounds` for personal audio. Keeping custom files outside the main `Soundbook` folder prevents addon managers from deleting them during an update.

Supported formats are `.ogg`, `.mp3`, and `.wav`. Register the base file name without its extension. Soundbook probes the supported extensions once and caches the successful one. A file is only cached as genuinely missing after two independent failed probes (a real missing file fails the same way every time, so it's still caught almost immediately) and that cached state expires after a short cooldown - a single one-off playback hiccup can no longer silence a valid sound for the rest of the session. A failed new sound is probed before existing Soundbook playback is stopped, so a typo or missing file cannot cut off a valid sound already playing.

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
- Retail-style APIs are used only when available and have Classic-compatible fallbacks where required: `C_FriendList` (friends and Ignore-list lookups) over the legacy globals, `C_ChatInfo.SendAddonMessage`/`RegisterAddonMessagePrefix` over the legacy globals, `C_AddOns.GetAddOnMetadata` over the legacy global, `GetNormalizedRealmName` over `GetRealmName`, and `BackdropTemplate` mixed in only where a frame actually needs it.
- Outbound addon-message transport (`Transport.lua`) checks the actual send result rather than assuming success just because the API call didn't error - a throttled/rejected send is retried a bounded number of times, never silently dropped or infinitely retried, and the rate limiter is tuned conservatively against Blizzard's own per-prefix throttle rather than against maximum theoretical throughput.
- Raid-roster scans (`Communication.lua`, `AdminPanel.lua`) iterate the full valid `GetRaidRosterInfo` index range rather than assuming it's a compact run up to the current member count, so a member sitting at a non-contiguous index is never missed.
- Optional sound-handle progress tracking degrades cleanly when `C_Sound.IsPlaying` is unavailable.
- A database written by a newer Soundbook version is opened in non-committing compatibility mode; it is never downgraded.
- A corrupt or cyclic SavedVariables table falls back to safe runtime defaults without overwriting the original table.

The complete verification boundary and live-client checklist are in `QA_REPORT.md` and `TESTING.md`.
