# Changelog

## 2.7.2

### Multi-client support

- One `Soundbook.toc` now covers every currently live WoW client family via the comma-separated multi-interface line: `## Interface: 11509, 16001, 20506, 50504, 120005` (Classic Era, WoW Forever, Burning Crusade Classic Anniversary, Mists of Pandaria Classic, Retail). This is the same mechanism BigWigs uses in its own single TOC file (verified directly against github.com/BigWigsMods/BigWigs), which also independently corroborates `16001` as WoW Forever's interface number. No per-flavor filenames, no filename-suffix guessing.
- Season of Discovery and Hardcore realms share Classic Era's client build, so interface `11509` covers them too. Wrath Classic and Cataclysm Classic are not listed: neither is currently offered as a standalone live realm type (the progression-realm cycle has moved on to Mists) - add their interface numbers to the comma list if/when Blizzard reopens them.
- Added `SB.GetNumGroupMembers()` compat wrapper (falls back to `GetNumRaidMembers`/`GetNumPartyMembers` on clients without the unified `GetNumGroupMembers` API) and switched every group-size check in `AdminPanel.lua` and `Communication.lua` to use it. Solo-case return value (`0`) checked against an external report of the live API - matches, no code change needed.
- Removed the OPie integration entirely (`OPieIntegration.lua` deleted, dropped from the TOC) to cut a third-party, Retail-only dependency out of the multi-client compatibility surface.

### Known open items

- WoW Forever is in beta; `C_Timer`, unified group APIs, and addon-message registration are assumed available based on the client's modern internals (corroborated by a third-party addon's TOC, a Blizzard statement on WoW Forever sharing Retail's 12.1.5 UI architecture, and an in-game `GetBuildInfo()` check) but not yet confirmed by a live playtest of Soundbook itself.
- Classic Era and BCC builds are static-analysis-verified against the existing compat layer in `Core.lua`; not covered by a live playtest as part of this change.
- Mists of Pandaria Classic and Retail were added without the same dedicated audit pass given to Forever/Classic Era/BCC - they rely on `Core.lua`'s existing modern-API-first fallbacks but flavor-specific concerns (combat-lockdown/taint edge cases) have not been separately checked.
- Retail's Interface number (`120005`) is unconfirmed and now actively in doubt: BigWigs' own current TOC lists `120007`, `120100`, and `120105` for Retail - none of which is `120005`. Verify with `/run print(select(4,GetBuildInfo()))` in-game and correct if needed.
- Mists of Pandaria Classic's AddOns folder name was not confirmed against a live install.
- Whether every one of the five targeted clients actually parses the comma-separated `## Interface:` line (versus reading only the first number and ignoring the rest) is not individually confirmed per client - only inferred from BigWigs shipping the same format for the same client set.

## 2.7.1

### Smart Search – Tag System

- Implemented tag-based search: sounds can now be found by emotion, context, origin, or synonym — not just their exact name.
- Searching `laugh` now finds **Zehahaha**, **Haha Peter**, **Rizzbot Laugh**, etc.
- Searching `raid` finds **Leeroy Jenkins**, **More Dots**, **Cthun You Will Die**, etc.
- All 76 Legacy and German Memes sounds ship with curated German and English tags.
- Tags are matched case-insensitively; name match is always preferred, tags are checked as fallback.
- Sound IDs, favourites, and analytics are completely unaffected.
- Companion addons (`Soundbook_Private`, `Soundbook_MySounds`) can include `tags` in their own entries.

### Tag updates

- **Are you lost**: added `babygirl`
- **Brother eeew**: added `arab`
- **Auf Alkohol**: added `homer`, `simpsons`
- **Schoki**: added `simpsons`, `ralph`, `fettsack`, `fatso`
- **Zehahaha**: added `marshall d. teach`, `blackbeard`, `one piece`, `anime`

---

## 2.7.0

### Legacy Soundbook – New Sounds

- Added **aaahhhhhh!** – classic panic scream reaction sound.
- Added **Brother eeew** – disgusted reaction meme.
- Added **Daddy Chill** – viral "chill out" meme clip.
- Added **Excuse me bruh** – confrontational reaction sound.
- Added **what did he sayyyyy** – shocked disbelief reaction meme.

---

## 3.0.0

### Core and data

- Added atomic copy → migrate → defaults → sanitize → validate → commit database preparation.
- Added safe recovery for cyclic/corrupt SavedVariables and non-committing compatibility for future database versions.
- Added shared validation for sound names/IDs, companion folders, player targets, output targets, numbers, and wire text.
- Advanced the database schema to version 24 while retaining valid existing preferences and content.

### Playback

- Protected custom file probes and stop calls from client/API errors.
- Cached missing file bases and reported a local failure only once per session.
- Probe a replacement before stopping current Soundbook playback.
- Bound active sound-handle lifetime and clean up naturally completed handles.
- Added a responsive token-bucket guard for held favourite hotkeys and macro bursts.
- Stop All now clears queued outgoing PLAY messages as well as active and incoming playback.

### Multiplayer

- Added a validated, bounded, priority-aware outbound transport.
- Added incoming packet limits, strict command/channel validation, bounded queueing, expiry, and deduplication.
- Kept separate senders' identical queued sounds distinct.
- Made player identity, mutes, cooldowns, acknowledgements, reachable-player lists, and admin authority realm-aware.
- Restricted Direct semantics to actual whispers and allowlisted admin acknowledgements/durations.
- Added compact Mini queue-depth feedback.

### Interface and performance

- Made the main library genuinely adaptive: 2–3 columns, 10–16 rows, and 20–48 entries per page.
- Added dynamic entry pooling, stable resize reflow, and debounced live layout refresh.
- Preserved the Arcane Codex component system and polished Mini Soundbook behavior.
- Removed permanent hidden Mini status/countdown work; updates now run only while visible or active.
- Added an Anonymous Community Analytics checkbox under Advanced / Debug.
- Disabling analytics now cancels delayed/repeating work and removes unsent analytics packets.
- Expanded `/sb doctor` with transport, grid, database, and analytics state.

### Compatibility and QA

- Retained TBC Anniversary interface `20506` and Classic API fallbacks.
- Added a full Lua 5.1/load-order/mock-runtime release harness.
- Verified 29 Lua modules, 72 bundled audio registrations/files, 169 runtime assertions, and every major UI builder.
- Added explicit migration, QA, and live-client verification documentation.
