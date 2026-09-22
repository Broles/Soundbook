# Soundbook 2.5.0 verification checklist

## Automated verification completed

The release harness completed successfully with **169 Lua runtime assertions** plus structural checks:

- all 29 Lua files parse as Lua 5.1;
- all 29 TOC modules exist and execute in declared order in the mock runtime;
- 72 declared bundled sound records match 72 packaged primary audio files;
- target interface and version metadata are correct;
- database migration is detached and atomic for success, forced failure, cyclic input, and future-version input;
- corrupt settings, positions, favourites, sounds, channels, and targets are repaired safely;
- registry, companion registration, durations, favourites, macros, playback, missing files, transport priority, queue purges, identity, mutes, admin commands, and channel validation execute as expected;
- main, Mini, Settings, Edit Sound, History, Analytics, Intro, New Sounds, Send, and Individual Mute windows construct without a Lua error;
- empty library, long label, zero/one/20 favourites, and favourite overflow paths execute safely;
- analytics opt-out cancels startup/repeating synchronization state while preserving history.

This is static and logical verification, not a claim of in-game testing.

## Required live-client verification

Install with the client closed, enable Lua errors, log in, and run `/sb doctor` first.

### Upgrade and persistence

1. Upgrade a copy of a real 2.x SavedVariables file and confirm DB v24, favourites/gaps, custom names/icons, categories, keybindings, mutes, routing, and positions.
2. `/reload`, then fully log out/in and confirm the same state remains.
3. Keep the backup until this pass is complete.

### Main library and dialogs

4. Resize the main window through minimum, default, and maximum sizes. Confirm the grid changes between 2–3 columns and 10–16 rows, pages remain stable, labels do not overlap, and the first visible item is retained during reflow.
5. Test an empty numbered category, a one-result search, a long name, many results, page navigation, no-result state, and clearing search.
6. Test left-click, right-click, Shift-left-click, playing/muted/favourite states, and hotkey badges.
7. Open Edit Sound; verify proportional icon grid, name preview, internal ID, favourite, mute, alternate, macro/output controls, Save, Cancel, and outside-click cancellation.
8. Scroll Settings from top to bottom at multiple window heights. Verify section order, clipping, tooltips, sliders, dropdowns, checkboxes, category rows, keybindings, and the Analytics checkbox.

### Mini Soundbook

9. Test 0, 1, and 20 favourites, including gaps at positions 2 and 4.
10. Resize from narrow/tall to wide/short and confirm 3–10 columns, centered incomplete rows, usable icon growth, and no large dead area.
11. Test hover zoom near every edge, lock/unlock, move, swap, move into a gap, remove outside, and cancellation.
12. Verify left-click plays; right-click opens a clamped Send menu near all four screen edges.
13. Confirm the status strip keeps the sound name primary and sender/source secondary without replacing the grid. Check Direct/Friends/Guild/Raid/Party colors and the `+N` queue count.
14. Test known-duration progress, overlapping sounds, Stop All, hiding the Mini mid-play, and reopening it.

### Playback and failure handling

15. Test `.ogg`, `.mp3`, and `.wav` examples and alternate audio.
16. Temporarily register a missing local file. Confirm one useful local message, no repeated spam, no Lua error, and no interruption of an already playing valid sound.
17. Test combat and boss-encounter playback restrictions.
18. Hold a favourite hotkey and rapidly invoke a macro. Confirm normal clicks remain responsive while sustained bursts are limited.

### Multiplayer matrix

Use at least two clients, ideally including two same-named characters on different realms.

19. Test Self, Friends, Guild, Party, Raid, and Direct output with matching and missing sounds.
20. Disable each receive mode while an entry from that mode is queued; confirm it is purged immediately.
21. Flood valid play messages from one sender and several senders. Confirm the queue never exceeds five, playback remains paced, duplicates coalesce only per sender+sound, and Stop All clears pending playback.
22. Send malformed, oversized, control-character, unknown-command, wrong-channel, unsupported-version, and invalid-target packets; none may execute or raise a Lua error.
23. Test delivery confirmations, per-sound mute, individual timed mute, global timed/indefinite receive mute, expiry, and reload behavior.
24. As party/raid leader, test individual mute/unmute and Mute All for Next Fight, Next Boss, 30 minutes, 60 minutes, and Until Raid Ends. Confirm non-leaders cannot apply admin commands and success appears only after an acknowledgement.
25. Confirm same-named cross-realm players remain separate in menus, mutes, cooldowns, and acknowledgements.

### Analytics and idle performance

26. Disable Analytics in Settings. Confirm `/sb doctor` reports `Analytics: OFF (idle)`, no statistics change after playback, and no new analytics packets are sent. Re-enable it and confirm synchronization resumes.
27. Leave the addon idle with all windows hidden. Profile CPU/memory if available: no permanent frame `OnUpdate` should remain; only the low-frequency presence ticker is expected. Playback, drag, resize, visible countdown, and queue updates should attach work only while active.

## Client-owned behavior

The following cannot be proven by the mock runtime and must be judged in the live TBC Anniversary client:

- exact textures, font metrics, clipping, frame strata, hit boxes, and UI-scale behavior;
- audio decoding, audible overlap, sound-handle fidelity, and completion timing;
- protected keybindings and combat restrictions;
- Blizzard addon-channel delivery, throttling, roster timing, and cross-realm naming;
- real companion-addon load order.

Report any Lua error with the full stack, `/sb doctor` output, the action immediately before it, client build, and whether it reproduces after `/reload`.
