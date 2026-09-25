# Soundbook verification checklist

## Automated verification

Every development round runs a WoW-compatible Lua mock harness (load order, database migration, and every major UI builder execute outside the real client) before shipping - see `QA_REPORT.md` for the dated, round-by-round record of what each pass actually covered and found. Facts stable enough to check directly against the current repository:

- all 29 Lua files listed in `Soundbook.toc` parse as Lua 5.1 and execute in declared order in the mock runtime;
- 85 declared bundled sound records (`Sounds.lua`: 70 Legacy + 15 German Memes) match 85 packaged primary audio files, plus 1 registered alternate (`SoundAlternates.lua`) matching 1 packaged alternate file;
- database migration is detached and atomic for success, forced failure, cyclic input, and future-version input;
- corrupt settings, positions, favourites, sounds, channels, and targets are repaired safely;
- registry, companion registration, durations, favourites, macros, playback, missing files, transport priority, queue purges, identity, mutes, admin commands, and channel validation execute as expected;
- Main, Announcer, Settings, Admin Panel, Keybind Mode, Edit Sound, History, Analytics, Intro, New Sounds, Send Menu, and Mute Players windows/panels construct without a Lua error;
- empty library, long label, zero/one/20 favourites, and favourite overflow paths execute safely;
- analytics opt-out cancels startup/repeating synchronization state while preserving history.

The specific mock-harness scripts are a development-time tool, not a file shipped in this repository or the release package. This is static and logical verification, not a claim of in-game testing.

## Required live-client verification

Install with the client closed, enable Lua errors, log in, and run `/sb doctor` first.

### Upgrade and persistence

1. Upgrade a copy of a real older SavedVariables file and confirm DB v28, favourites/gaps, custom names/icons, categories, keybindings, mutes, routing, and positions.
2. `/reload`, then fully log out/in and confirm the same state remains.
3. Keep the backup until this pass is complete.

### Main library and dialogs

4. Resize the main window through minimum, default, and maximum sizes. Confirm the grid changes between 2–3 columns and 10–16 rows, pages remain stable, labels do not overlap, and the first visible item is retained during reflow.
5. Test an empty numbered category, a one-result search, a long name, many results, page navigation, no-result state, and clearing search.
6. Test left-click, right-click, Shift-left-click, playing/muted/favourite states, and hotkey badges.
7. Open Edit Sound; verify proportional icon grid, name preview, internal ID, favourite, mute, alternate, macro/output controls, Save, Cancel, and outside-click cancellation.
8. Open Settings via the header gear icon. Verify the left-hand nav's six sections (General, Playback, Multiplayer, Appearance, Categories, Advanced) each switch cleanly with no blank/collapsed content, and scroll each section's content pane top to bottom at multiple window heights checking clipping, tooltips, sliders, dropdowns, checkboxes, and category rows. Analytics has no toggle here by design (see "Anonymous community analytics" in `README.md`) - do not expect one.

### Announcer and Mini Soundbook

The Announcer (`Announcer.lua`) is the always-on HUD; its expandable favourites grid is informally called the "Mini Soundbook" but is a popup off the Announcer icon, not a separate window - it has no drag/swap/move-into-gap slot management of its own (that only happens in the Main Soundbook's own Library).

9. Test 0, 1, and 20 favourites in the popup, including gaps.
10. Test both activation modes (Settings -> Appearance, or the Quick Options checkbox): with "Open on hover" off, only a left-click on the idle icon opens the popup; with it on, hovering the icon opens it too, and it does not reopen underneath an already-open Quick Options menu.
11. Test the Mini Soundbook Size slider (Settings -> Appearance, 50%-200%) both from Settings and via Quick Options' live-preview drag; confirm the popup's icon size/column layout updates and the Announcer's own size is unaffected.
12. Test the single-active-transient-surface rule: opening Quick Options closes an open Mini Soundbook popup and vice versa; right-clicking a favourite to open the Send/context menu closes Quick Options first but is allowed to coexist with the Mini Soundbook popup it was opened from; moving the cursor away for several seconds closes the popup, except while actively dragging or otherwise interacting with it.
13. Verify left-click plays; right-click opens a clamped Send menu near all four screen edges.
14. Confirm the popup's title reflects the currently reachable "Send to:" target and updates live on roster changes and Settings -> Multiplayer Send-matrix changes. Check Direct/Friends/Guild/Raid colors and the banner's `+N` overlap badge.
15. On the Announcer's own banner (idle icon expanding on playback, independent of the favourites popup): test known-duration progress, overlapping sounds, Stop All, closing the Main Soundbook mid-play, and reopening it.

### Playback and failure handling

16. Test `.ogg`, `.mp3`, and `.wav` examples and alternate audio.
17. Temporarily register a missing local file. Confirm one useful local message, no repeated spam, no Lua error, and no interruption of an already playing valid sound.
18. Test combat and boss-encounter playback restrictions.
19. Hold a favourite hotkey and rapidly invoke a macro. Confirm normal clicks remain responsive while sustained bursts are limited.

### Multiplayer matrix

Use at least two clients, ideally including two same-named characters on different realms.

20. Test Self, Friends, Guild, Party, Raid, and Direct output with matching and missing sounds.
21. Disable each receive mode while an entry from that mode is queued; confirm it is purged immediately.
22. Flood valid play messages from one sender and several senders. Confirm the queue never exceeds five, playback remains paced, duplicates coalesce only per sender+sound, and Stop All clears pending playback.
23. Send malformed, oversized, control-character, unknown-command, wrong-channel, unsupported-version, and invalid-target packets; none may execute or raise a Lua error.
24. Test delivery confirmations, per-sound mute, individual timed mute, global timed/indefinite receive mute, expiry, and reload behavior.
25. As party/raid leader, test individual mute/unmute and Mute All for Next Fight, Next Boss, 30 minutes, 60 minutes, and Until Raid Ends. Confirm non-leaders cannot apply admin commands and success appears only after an acknowledgement.
26. Confirm same-named cross-realm players remain separate in menus, mutes, cooldowns, and acknowledgements.

### Analytics and idle performance

27. Disable analytics with `/sb analytics off` (there is no Settings toggle - see "Anonymous community analytics" in `README.md`). Confirm `/sb doctor` reports `Analytics: OFF (idle)`, no statistics change after playback, and no new analytics packets are sent. Re-enable with `/sb analytics on` and confirm synchronization resumes.
28. Leave the addon idle with all windows hidden. Profile CPU/memory if available: no permanent frame `OnUpdate` should remain; only the low-frequency presence ticker is expected. Playback, drag, resize, visible countdown, and queue updates should attach work only while active.

## Client-owned behavior

The following cannot be proven by the mock runtime and must be judged in the live TBC Anniversary client:

- exact textures, font metrics, clipping, frame strata, hit boxes, and UI-scale behavior;
- audio decoding, audible overlap, sound-handle fidelity, and completion timing;
- protected keybindings and combat restrictions;
- Blizzard addon-channel delivery, throttling, roster timing, and cross-realm naming;
- real companion-addon load order.

Report any Lua error with the full stack, `/sb doctor` output, the action immediately before it, client build, and whether it reproduces after `/reload`.
