# Changelog

## 2.8.1

### Multi-client support: collapsed to one TOC file

- Replaced the five separate per-flavor TOC files from 2.8.0 (`Soundbook.toc`, `Soundbook-Classic.toc`, `Soundbook-BCC.toc`, `Soundbook-Mists.toc` + `Soundbook_Mists.toc`, `Soundbook_Mainline.toc`) with a single `Soundbook.toc` using the comma-separated multi-interface line: `## Interface: 11509, 16001, 20506, 50504, 120005`.
- Reason: cloned and directly inspected the BigWigs repo (github.com/BigWigsMods/BigWigs) after a claim that it ships a separate `BigWigs_Mists.toc` file turned out not to hold up - BigWigs actually ships exactly one `BigWigs.toc` with a comma-separated interface list, and that list independently includes `16001`, corroborating our WoW Forever interface number from a second, unrelated source. This removes every filename-suffix guess (`-Mists` vs `_Mists`, `-Mainline` vs `_Mainline`) that the previous approach depended on.
- `SB.GetNumGroupMembers()`'s solo-case return value (`0`) was checked against a developer report of the live API and is correct as shipped; no code change needed.

## 2.8.0

### Multi-client support

- Added dedicated TOC files: `Soundbook.toc` (WoW Forever, Interface 16001), `Soundbook-Classic.toc` (Classic Era, Interface 11509), `Soundbook-BCC.toc` (Burning Crusade Classic Anniversary, Interface 20506), `Soundbook-Mists.toc` + `Soundbook_Mists.toc` (Mists of Pandaria Classic, Interface 50504 - shipped under both naming conventions since the client-recognized suffix for this flavor wasn't confirmed), `Soundbook_Mainline.toc` (Retail, Interface 120005). CurseForge/WowUp now install the correct build per client automatically.
- Season of Discovery and Hardcore realms share Classic Era's client build, so `Soundbook-Classic.toc` covers them without any extra file. Wrath Classic and Cataclysm Classic are not shipped: neither is currently offered as a standalone live realm type (the progression-realm cycle has moved on to Mists).
- Added `SB.GetNumGroupMembers()` compat wrapper (falls back to `GetNumRaidMembers`/`GetNumPartyMembers` on clients without the unified `GetNumGroupMembers` API) and switched every group-size check in `AdminPanel.lua` and `Communication.lua` to use it.
- Removed the OPie integration entirely (`OPieIntegration.lua` deleted, dropped from all TOCs) to cut a third-party, Retail-only dependency out of the multi-client compatibility surface.

### Known open items

- WoW Forever is in beta; `C_Timer`, unified group APIs, and addon-message registration are assumed available based on the client's modern internals (confirmed via a third-party addon's TOC and in-game `GetBuildInfo()` check) but not yet confirmed by a live playtest of Soundbook itself.
- Classic Era and BCC builds are static-analysis-verified against the existing compat layer in `Core.lua`; not covered by a live playtest as part of this change.
- Mists of Pandaria Classic and Retail were added without the same dedicated audit pass given to Forever/Classic Era/BCC - they rely on `Core.lua`'s existing modern-API-first fallbacks but flavor-specific concerns (combat-lockdown/taint edge cases) have not been separately checked.
- Retail's Interface number (120005) is unconfirmed - Patch 12.1 may have already shifted it to 120100; verify with `/run print(select(4,GetBuildInfo()))` in-game.
- Mists of Pandaria Classic's AddOns folder name was not confirmed against a live install.

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
