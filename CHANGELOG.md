# Changelog

## 3.0.0

### Main Soundbook redesign

- Replaced the paged, right-side-tabbed book with one continuously scrolling Sound Library: Favourites first (compact - occupied slots only, expanding to all 20 as drop targets during a drag), then a collapsible section per category. Collapse state is remembered per category.
- New compact toolbar (Settings / Raid Admin / Lock / Search / Quick Audio / Close) replaces the old tall crest header and the right-side category-tab dock.
- Search and the tag filter pills (New/Trending/Popular/Loved/Legendary/Cringe/Dusty) now render as one flat cross-category result list, auto-expanding matching sections and restoring their collapsed state afterward.
- New Output Rail (`ALL` / `G` / `P/R` / `F` / `NO`, left edge) replaces the old header dropdown for the global Default Output Channel. Hovering Guild/Party-Raid/Friends opens a flyout offering the whole group or an individual recipient subset, fanned out through the existing Direct/whisper transport - no new wire protocol.
- Community Analytics finally has a real menu entry (Settings -> Advanced/Debug -> "Community Analytics"), alongside a visible "Share Anonymous Analytics" checkbox.

### Announcer (replaces the Mini Soundbook window)

- New always-on HUD: an idle app icon that expands into a compact banner (sound name, sender, channel, real playback progress - never a faked percentage for an unknown duration) whenever a Soundbook sound plays, local or received, then collapses back down.
- Handles overlapping sounds (`+N` badge, promotes the next one when the primary ends) and shows a compact queue indicator when remote sounds are waiting.
- Right-click the active banner to mute just that one sound; right-click the idle icon for Quick Options (mute incoming, lock, muted players, open Soundbook).
- Expands away from whichever screen edge it's closest to, so it always stays fully on-screen. Small indicators for an active incoming-mute or raid-admin restriction show directly on the idle icon.
- Favourites themselves moved out of this HUD and into the Main Soundbook's own Library (see above) - the Announcer's only job now is "what is Soundbook doing right now."

### Edit Sound

- No longer permanently embeds the icon grid - "Change Icon" opens a popup picker instead, shrinking the window noticeably.
- Fixed: saving with all 20 Favourite slots full used to abort the entire save (name/icon/mute/output/macro changes lost too); now only the favourite change is reverted, with an inline message, and everything else still saves.
- Added a "Discard unsaved changes?" prompt before closing (X, Cancel, Escape, or clicking outside) with unsaved edits, and before switching to edit a different sound while the current one is still unsaved.

### Compatibility

- SavedVariables migrated automatically and non-destructively on first login (database v26 -> v27) - existing favourites, keybinds, sound customizations, history, analytics, and settings all carry over. The old Mini Soundbook's position/visibility/opacity seed the new Announcer's once; its own SavedVariables fields are left untouched, not deleted.
- Every existing slash command, the minimap button, companion-addon sound registration (`Soundbook_Private`/`Soundbook_MySounds`), and the `/sb play` macro contract are unchanged.

## 2.7.2

### Multi-client support

- One `Soundbook.toc` now covers every currently live WoW client family via the comma-separated multi-interface line: `## Interface: 11509, 16001, 20506, 50504, 120100` (Classic Era, WoW Forever, Burning Crusade Classic Anniversary, Mists of Pandaria Classic, Retail). This is the same mechanism BigWigs uses in its own single TOC file (verified directly against github.com/BigWigsMods/BigWigs), which also independently corroborates `16001` as WoW Forever's interface number and `120100` as Retail's current one. No per-flavor filenames, no filename-suffix guessing.
- Season of Discovery and Hardcore realms share Classic Era's client build, so interface `11509` covers them too. Wrath Classic and Cataclysm Classic are not listed: neither is currently offered as a standalone live realm type (the progression-realm cycle has moved on to Mists) - add their interface numbers to the comma list if/when Blizzard reopens them.
- Added `SB.GetNumGroupMembers()` compat wrapper (falls back to `GetNumRaidMembers`/`GetNumPartyMembers` on clients without the unified `GetNumGroupMembers` API) and switched every group-size check in `AdminPanel.lua` and `Communication.lua` to use it. Solo-case return value (`0`) checked against an external report of the live API - matches, no code change needed.
- Removed the OPie integration entirely (`OPieIntegration.lua` deleted, dropped from the TOC) to cut a third-party, Retail-only dependency out of the multi-client compatibility surface.

### Known upstream bug: WoW Forever SavedVariables

- Confirmed on builds 1.60.1.69893 and 1.60.1.69913 via multiple independent Blizzard forum threads (EU and US) plus a third-party workaround tool (`ForeverSVFix` on GitHub): addon SavedVariables are written correctly but not loaded back on login, `/reload`, or character switch. Every session starts blank. This is a client bug upstream of Soundbook - nothing in `Core.lua`'s compat layer can work around it. Expect favourites/settings/history to reset on Forever until Blizzard fixes it.

### Known open items

- `C_Timer`, unified group APIs, and addon-message registration on WoW Forever are assumed available based on the client's modern internals (corroborated by a third-party addon's TOC, a Blizzard statement on WoW Forever sharing Retail's 12.1.5 UI architecture, and an in-game `GetBuildInfo()` check) but not yet confirmed by a live playtest of Soundbook itself.
- Classic Era and BCC builds are static-analysis-verified against the existing compat layer in `Core.lua`; not covered by a live playtest as part of this change.
- Mists of Pandaria Classic and Retail were added without the same dedicated audit pass given to Forever/Classic Era/BCC - they rely on `Core.lua`'s existing modern-API-first fallbacks but flavor-specific concerns (combat-lockdown/taint edge cases) have not been separately checked.
- Mists of Pandaria Classic's AddOns folder name was not confirmed against a live install.
- Whether every one of the five targeted clients actually parses the comma-separated `## Interface:` line (versus reading only the first number and ignoring the rest) is not individually confirmed per client - inferred from BigWigs and multiple CurseForge-published addons (e.g. GuildOS) shipping the same format for the same client set, including Forever specifically.
- CurseForge's "WoW Forever" flavor is confirmed to exist and be usable by ordinary authors (not beta-partner-restricted), evidenced by real GitHub issues/PRs from third-party addon projects publishing to it. Not yet confirmed how it appears in this specific project's upload form.

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
