# Soundbook migration guide

The current build (Soundbook 3.0.0) uses database version **28**. The SavedVariables name remains `SoundbookDB`, so a normal folder replacement keeps existing settings regardless of which version you are upgrading from - the atomic upgrade sequence below runs every intermediate migration step automatically, including the version-24 pipeline this guide was originally written for.

## Before upgrading

1. Exit World of Warcraft completely.
2. Copy `WTF/Account/<account>/SavedVariables/Soundbook.lua` to a safe location.
3. Replace only the `Interface/AddOns/Soundbook` addon folder.
4. Keep the SavedVariables file in place.

## Atomic upgrade sequence

On `ADDON_LOADED`, Soundbook performs this sequence:

1. deep-copy the original SavedVariables table with cycle, depth, and entry limits;
2. migrate the detached working copy through every required historical version;
3. apply current defaults without replacing valid user values;
4. sanitize known fields and bounded collections;
5. validate required containers;
6. replace `SoundbookDB` only after every previous step succeeds.

The original table is never modified by a failed migration.

## Preserved data

Where valid, the migration retains:

- favourites and all 20 fixed positions, including gaps;
- category names and icons;
- per-sound names, icons, mute state, alternates, and output overrides;
- playback, routing, receive, notification, and analytics settings;
- Main window and Announcer positions/sizes;
- favourite keybindings;
- received history;
- individual and global receive mutes;
- known Soundbook users and learned durations;
- anonymous analytics history.

Numeric values are clamped to supported ranges. Invalid enum values, controls, unsafe targets, malformed records, duplicate favourites, out-of-range slots, and unknown option keys are repaired or discarded individually instead of invalidating the whole database.

## Version history (v24 through the current v28)

Each step below runs automatically and in order for any installation upgrading from an older version - you never need to be on an intermediate version first.

### Version 24 changes (historical - this is not the current schema)

- Database preparation is now copy/migrate/sanitize/validate/commit rather than mutating live SavedVariables during upgrade.
- Player identities used for new network/security state are canonical and realm-aware.
- Existing short-name mute and known-user keys remain readable as a compatibility fallback and are replaced lazily during normal use.
- Main-window size is constrained to the supported adaptive layout range.
- Known settings, history, durations, per-sound records, category data, positions, fonts, tags, and Mini state receive explicit type/range validation.

### Version 25 (Raid/Party merge, send side)

Raid and Party became one Send target. The old `broadcastModes.PARTY` flag is OR'd into the surviving `broadcastModes.RAID` flag once, so nobody who had Party-only broadcasting enabled silently loses it. Per-sound overrides already saved as `"PARTY"` are left untouched - every reader treats `"PARTY"` as an alias for `"RAID"` going forward.

### Version 26 (Raid/Party merge, receive side)

The same merge on the receive side: the old `receiveParty` flag is OR'd into `receiveRaid` once, then discarded.

### Version 27 (Announcer HUD replaces the old Mini Soundbook window)

The new `ui.announcer` table is seeded once from the old Mini Soundbook window's `favPos`/`favShown`/`favAlphaIdle`/`favAlphaHover`/`favLocked` fields, so an upgrading player's existing position/visibility/opacity/lock choices carry over to the Announcer instead of resetting to defaults. The old fields themselves are left fully intact, never deleted - only read from once.

### Version 28 (current - Announcer Size / Mini Soundbook Size split)

"Announcer Size" used to also drive the Mini Soundbook popup's own column/width scaling. The new `ui.announcer.favScale` field ("Mini Soundbook Size") is seeded once from the prior single `ui.announcer.scale` value, so an upgrading player's favourites don't silently change size. A fresh install gets `favScale = 1.0` directly. (A separate, legacy top-level `ui.favScale` field from an earlier iteration was never a source for this or any other migration and has since been removed as dead code - see "Later within 3.0.0" in `CHANGELOG.md`.)

## Recovery and future-version behavior

If copying, migration, or validation fails, Soundbook:

- keeps the original global SavedVariables table untouched;
- uses safe defaults for the current session;
- prints one clear recovery warning;
- reports recovery mode through `/sb doctor`;
- does not commit session changes over the original data.

If `dbVersion` is newer than the current version (28), Soundbook uses a detached compatibility copy for the session but preserves the future version and does not commit or downgrade it.

After any recovery warning, keep the backup and the original SavedVariables file. Run `/sb doctor`, enable `/sb debug` if needed, and provide both the diagnostic output and the saved file when reporting the issue.

## Verification after upgrade

Log in and confirm:

1. `/sb doctor` says `DB v28` and `Database: validated and writable`.
2. Favourites, gaps, keybindings, custom names/icons, categories, and window positions remain intact.
3. The main library resizes correctly, and the Announcer's Mini Soundbook popup opens and scales.
4. Playback, Stop All, receive mute, and one multiplayer path work.
5. Reload and log in again to confirm persistence.

See `TESTING.md` for the full checklist.
