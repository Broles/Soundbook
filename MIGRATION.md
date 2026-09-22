# Soundbook 2.5.0 migration guide

Soundbook 2.5.0 uses database version **24**. The SavedVariables name remains `SoundbookDB`, so a normal folder replacement keeps existing settings.

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
- main and Mini positions/sizes;
- favourite keybindings;
- received history;
- individual and global receive mutes;
- known Soundbook users and learned durations;
- anonymous analytics history.

Numeric values are clamped to supported ranges. Invalid enum values, controls, unsafe targets, malformed records, duplicate favourites, out-of-range slots, and unknown option keys are repaired or discarded individually instead of invalidating the whole database.

## Version 24 changes

- Database preparation is now copy/migrate/sanitize/validate/commit rather than mutating live SavedVariables during upgrade.
- Player identities used for new network/security state are canonical and realm-aware.
- Existing short-name mute and known-user keys remain readable as a compatibility fallback and are replaced lazily during normal use.
- Main-window size is constrained to the supported adaptive layout range.
- Known settings, history, durations, per-sound records, category data, positions, fonts, tags, and Mini state receive explicit type/range validation.

## Recovery and future-version behavior

If copying, migration, or validation fails, Soundbook:

- keeps the original global SavedVariables table untouched;
- uses safe defaults for the current session;
- prints one clear recovery warning;
- reports recovery mode through `/sb doctor`;
- does not commit session changes over the original data.

If `dbVersion` is newer than 24, Soundbook uses a detached compatibility copy for the session but preserves the future version and does not commit or downgrade it.

After any recovery warning, keep the backup and the original SavedVariables file. Run `/sb doctor`, enable `/sb debug` if needed, and provide both the diagnostic output and the saved file when reporting the issue.

## Verification after upgrade

Log in and confirm:

1. `/sb doctor` says `DB v24` and `Database: validated and writable`.
2. Favourites, gaps, keybindings, custom names/icons, categories, and window positions remain intact.
3. The main library and Mini resize correctly.
4. Playback, Stop All, receive mute, and one multiplayer path work.
5. Reload and log in again to confirm persistence.

See `TESTING.md` for the full checklist.
