# Soundbook 2.5.0 QA report

Version: **2.5.0**  
Database: **24**  
Target interface: **20506**  
Verification date: **2026-09-05**

## Outcome

The release candidate passes the available static and logical verification boundary:

- **29/29** Lua modules parse as Lua 5.1.
- **29/29** TOC modules exist and load in declared order.
- **72/72** declared bundled sounds have a matching packaged primary audio file.
- **169/169** runtime assertions pass in the WoW-compatible mock harness.
- All major windows construct and show without a simulated Lua error.

No World of Warcraft client was available in this environment. Visual, audible, secure-action, and real addon-channel behavior remains explicitly marked **in-game verification required**.

## Implemented 2.5.0 priorities

### 1. Transactional state foundation

`Validation.lua` and `Database.lua` separate trust-boundary checks and atomic SavedVariables preparation from the historical core. Upgrades run on a bounded detached copy and commit only after migration, defaults, sanitation, and validation succeed. Corrupt/cyclic and future-version states never overwrite the original data.

### 2. Bounded multiplayer transport and identity

`Transport.lua` centralizes outbound validation, rate limiting, bounded queuing, expiry, priority, and low-priority deduplication. Playback/control traffic outranks presence/analytics traffic. Incoming commands enforce a channel matrix, protocol validation, per-sender limits, and realm-safe identities. Direct flags are trusted only on real whispers; admin command kinds and durations are allowlisted.

### 3. Adaptive player-facing UI

The main library now adapts content density rather than merely resizing its frame: 2–3 columns, 10–16 rows, 20–48 entries per page, dynamic entry pooling, stable first-visible-item reflow, and debounced resize refresh. The existing Arcane Codex theme/component system remains shared across the product.

The Mini Soundbook retains its mature 3–10-column, fixed-20-position HUD design and gains compact pending-queue feedback. Its progress, drag, expansion, last-played, and mute countdown updates are attached only while active/visible.

### 4. Failure-tolerant playback and privacy control

Missing media probes are protected and cached. A new file is successfully probed before older Soundbook-owned playback is stopped. Held hotkeys/macros receive a local burst guard. Analytics has one centralized opt-out that stops collection, cancels delayed and repeating timers, and purges unsent analytics traffic without deleting history.

## Verification coverage

Logical tests exercise:

- fresh, historical, corrupt, cyclic, forced-failure, and future database paths;
- false-value preservation, clamping, duplicate/gapped favourites, and corrupt nested records;
- sound ID/name/folder/target validation and companion registration;
- 0, 1, 20, and overflow favourite states;
- macro parsing and explicit targets;
- successful/missing playback, cached probes, and no-cutoff failure behavior;
- outbound controls, burst queuing, priority, Stop All purge, and analytics purge;
- inbound command/channel/admin validation;
- realm-separated player identity and mute state;
- empty category, long label, adaptive grid baseline, and all major UI builders;
- analytics disable/enable state and history preservation.

## Performance review

- Main resize reflow is debounced during dragging and applied immediately at release.
- UI entries are pooled and reused; hidden capacity is not recreated each refresh.
- Sound order is cached and invalidated only by relevant changes.
- Playback polling exists only while tracked handles are active.
- Mini progress and drag use temporary `OnUpdate` handlers.
- Mini last-played and mute countdown tickers stop when hidden or no longer relevant.
- Incoming/outgoing queues use one-shot timers only while work exists.
- Analytics sync timers do not exist while analytics is disabled.
- Presence discovery remains a deliberate low-frequency 180-second ticker.

No automation subsystem exists in the supplied addon. None was invented for 2.5.0; this avoids adding complexity and regression risk without a real product workflow to preserve.

## Residual risk / live-client gate

The remaining risks are owned by client behavior, not uncovered logical failures:

- exact Arcane texture sampling, clipping, font sizes, frame levels, hover hit testing, and UI scale;
- `PlaySoundFile`, `StopSound`, and `C_Sound.IsPlaying` behavior for real files/handles;
- combat-protected favourite keybindings;
- real guild/friend/group addon-channel throttling and cross-version interoperability;
- companion-addon registration timing;
- migration against a user's complete real SavedVariables history.

The release is suitable for a focused in-game candidate pass using `TESTING.md`. It should not be described as in-game verified until that pass is completed.

---

## Soundbook 3.0 QA continuation - Round 5 (2026-09-23)

Additive to the above, not a replacement. Covers the fifth round of the 3.0
UI/UX iteration (Favourites grid, Popout Direction/live preview, right-side
broadcast tabs, Raid Admin sync, and this round's fixes/refinements), run
against the same mock WoW API harness described above (6 regression scripts,
all green after every change in this round).

### P0 - sound playback truncation ("Bad To The Bone" and others)

**Root cause, confirmed by direct binary analysis, not a Lua bug.** Every
`StopSound` call site in every file the `.toc` actually loads was traced by
hand (`SoundPlayer.lua`'s `StopAllOwnSounds`, called only from disabled-
overlap logic or an explicit user Stop) - none of them are duration-timer
driven, and the UI's progress ticker is provably display-only. `FavouritesWindow.lua`
contains code that LOOKS like a duration-based auto-stop timer, but that
file is not in `Soundbook.toc` and never loads - dead code, not a live bug
source.

The actual cause: `Sounds/Legacy/Bad To The Bone.mp3` and
`Sounds/Legacy/Dry Fart.mp3` are truncated/corrupted audio files on disk.
Walking every MPEG frame header in all 79 resolvable shipped `.mp3` files
and comparing the measured duration against `SoundDurations.lua`'s
registered value found 77 exact matches (confirming the measurement method
is sound) and exactly these two outliers - "Bad To The Bone" measures
**1.027s** of real audio against a registered 2.247s, "Dry Fart" measures
**0.183s** against a registered 0.392s. Both files end in ~200 bytes of a
single repeated byte value, not a normal MP3 encoder footer - consistent
with a truncated/interrupted encode, not an intentionally short clip.

Fix applied: `SoundDurations.lua`'s two entries now match the real files,
so the UI stops promising a duration the audio can't deliver. **This does
not restore the missing ~1.2s of "Bad To The Bone."** That requires
replacing the shipped file with a correct, full-length encode - the audio
data simply isn't in the repository. Flag this to the user directly.

Also verified and hardened, per the explicit invariant requested: no
per-handle timer/callback exists anywhere in the playback path, so a stale
callback cannot act on a newer playback instance - `trackedHandles[handle]`
is always a fresh table on every new play (no state carries over even if a
handle number is reused), and the single shared poll ticker reads live
table state every tick rather than closing over per-instance data.

### Popup wrong direction near a screen edge

Root cause: `SB.ResolvePopoutDirection` compared `anchorFrame:GetCenter()`
directly against `UIParent:GetWidth()/GetHeight()` without accounting for
`GetEffectiveScale()` - two different frames' coordinate methods are each
returned in that frame's OWN local unit space. The Announcer icon carries
an independent `SetScale` (Announcer Size, 0.7-1.6), so at any non-default
size the region math was silently skewed and could resolve a genuinely
edge-positioned icon into the centre "vertical" band. Fixed by normalizing
through the effective-scale ratio before computing the region percentage.
Regression-tested with a synthetic case reproducing the exact real-edge/
non-default-scale scenario.

### Idle Announcer drag shows no preview

Root cause: `StartIconDragPreview`/`ShowDemoBanner`/`ShowRaidMuteBanner`
all called `banner:Show()` without resetting alpha. `CollapseToIdle`'s own
fade-out leaves the banner sitting at alpha 0 once idle; a bare `Show()`
never undid that, so the preview was technically shown (`IsShown()==true`)
but fully invisible. Dragging while a sound was already playing never hit
this because `RenderPrimary` always explicitly fades to alpha 1 first.
Fixed at all three call sites. Regression-tested end-to-end: play a real
sound, let it end naturally (alpha fades to 0), then start a drag and
assert the banner is both shown AND at full alpha.

### Favourites popup scrollbar removed

The `ScrollFrame`/viewport cap is gone - every current Favourite (up to
the 20-slot maximum) is always laid out and shown at once. Column count
still follows Announcer Size (2 vs. 3, per the original request), with an
added safety net that only ever escalates 2->3 columns if a 2-column
layout would grow past 60% of screen height (inert at any normal
screen/Announcer Size combination - the true worst case, 20 Favourites at
2 columns, is 240px). Popup height is purely content-driven; fewer
Favourites means a smaller popup, verified at both 4 and 20 entries.

### Fresh-install crash (found by this round's regression pass, not previously reported)

`PrepareDatabase`'s fast path for a brand-new install (`rawDatabase == nil`)
returned the raw defaults table without ever running `SanitizeDatabase` -
and the defaults table never had a `ui.outputRail` entry at all. Every
new player's very first `RefreshBroadcastTabs()` call (opening the Main
window) crashed with "attempt to index local 'rail' (a nil value)." An
upgrading player never hit this since their path always runs
`SanitizeDatabase`. Fixed by giving `ui.outputRail` an empty default and
making the fresh-install path run `SanitizeDatabase` too, keeping both
paths structurally consistent instead of hand-syncing two shapes.

### Main window layout hierarchy

Shared layout metrics (safe inset, toolbar height, section gap, search
min/preferred/max width, Output Rail top offset) replace ad-hoc per-row
padding. Title has more breathing room and is vertically centred; Search
now has a responsive 140-320px width instead of stretching to fill the
header; Close/Lock/Audio icons share identical geometry via the existing
`MiniControlButton` chrome (Close keeps a distinct red hover tint);
toolbar/filter/Library gaps are normalized; the Library scroll frame has a
wider right inset for the scrollbar; the Output Rail's vertical start now
aligns with where Library content actually begins instead of a hardcoded
offset guess.

### Edit Sound refinement

More breathing room below the header before the icon/name block; icon
reduced from 64px to 56px (still within the requested 56-64px range) to
balance against the smaller adjacent controls; Favourite/Muted/Hide
checkboxes now chain off each other's actual rendered label width instead
of fixed 110px slots that left large, uneven gaps for short labels.

### Icon Picker layering

No longer centres on the exact same screen point as Edit Sound (which
visually buried it underneath) with a fixed, arbitrary frame level (300).
Now anchors directly to Edit Sound's own frame when Edit Sound is the
caller - sticky to its left with a small gap, falling back to the right
if there isn't room, with a frame level computed from Edit Sound's own
CURRENT level rather than a guessed constant. Falls back to the original
centred-on-Main placement for every other caller (Settings' Category icon
picker has no Edit Sound to anchor to).

### Still gated on a live client

Same residual-risk boundary as the 2.5.0 report above - exact pixel
layout, hover hit-testing, and real `PlaySoundFile`/`C_Sound.IsPlaying`
behavior are not something a Lua-only mock can fully replicate. In
particular: the Popout Direction fix's real-world correctness at actual
screen edges, and the Icon Picker's left/right fallback placement, are
logically verified but should get one in-game pass each.

---

## Soundbook 3.0 QA continuation - Settings restructure (2026-09-23)

Additive, same as Round 5 above. Covers the information-architecture
rework of Settings.lua and the relocation of Favourite Keybindings, Sound
History, and timed Receive Mute out of it, per the explicit task spec.

### What changed

Settings is now five sections behind a compact tab strip (Sound &
Playback, Sharing & Receiving, Mini Soundbook, Library & Appearance,
Advanced) instead of one continuous scroll, plus a persistent Help &
Information footer. No SavedVariables key changed; this is presentation/
navigation only. Three things moved out of Settings to where the task
spec asked for them (Favourite Keybindings -> a new Keybinding Mode on
the Main Soundbook's Favourites view; Sound History -> the shared Quick
Options menu, above Open Settings; timed 30/60-minute Receive Mute ->
the same Quick Options menu, next to the existing indefinite toggle), and
two things were removed outright rather than relocated, per an explicit
"do not expose analytics anywhere in Settings" instruction: the analytics
opt-out checkbox and the Community Analytics window button. The window
itself is untouched and still reachable via `/sb analytics`.

### Two judgment calls worth flagging explicitly

**"Now Playing / Announcement Duration."** The task spec describes this
control as governing a "Now Playing -> Last Sound" transition inside the
Mini Soundbook. That description matches the OLD pre-3.0 Favourites
window (FavouritesWindow.lua) exactly - which is dead code, not in the
`.toc`, never loads. In the current 3.0 Announcer, that separate "Last
Sound" display state doesn't exist any more; the setting this task refers
to (`SB.db.settings.announceDuration`) is still live, but now drives a
different thing entirely - how long the Library grid keeps its own
"just played" gold highlight on a sound's tile (`UI.lua`'s
`SetPlayingState`). I re-exposed the control under Mini Soundbook > Now
Playing with an honest description of what it actually does today,
preserving the underlying 0-15s range and its "0 = off" floor exactly.
Flagging this rather than silently mislabeling the control to match a
description that no longer corresponds to live behaviour.

**"Right-click Mini Soundbook icon" / "right-click Quick Audio icon."**
An earlier round of this same session explicitly rebound the Announcer
icon's clicks (Left = Favourites, Right = open Main Soundbook, Shift+Right
= Quick Options) at the user's own request. Rather than overriding that
established scheme to add a literal new plain-right-click menu, "Sound
History" and the mute durations were added to the Quick Options menu that
already existed at that Shift+Right-click / Quick-Audio-button
interaction - the one place in the addon that already had an "Open
Settings" row for History to sit above. Functionally reachable from both
launcher icons as specified (and still reachable via the Main toolbar's
Quick Audio button when the Mini Soundbook itself is hidden, satisfying
that specific requirement), just not literally bound to a bare right-click
on the Announcer icon.

### Verification

Extended the mock WoW API harness with a new `loader_settings.lua`:
switches through all 5 sections without error; starts and stops a timed
Receive Mute and confirms the compact info state appears/disappears
correctly; enters and exits Keybinding Mode via the same public toggle the
Favourites view's "Keybinds" button now calls; assigns a binding to both
an occupied slot and a genuinely empty one (confirming bindings still
don't depend on slot occupancy) and clears one; confirms the relocated
Quick Options rows exist. This surfaced a real, previously-unexercised
mock gap (`ClearOverrideBindings`/`SetOverrideBindingClick`/
`GetBindingKey`/`IsControlKeyDown`/`IsAltKeyDown` were never stubbed,
because no existing test had ever called `SB:SetFavouriteKeybind`
directly) - patched in the mock, not a product bug.

### Still gated on a live client

Same boundary as every round above - the exact visual balance of the new
tab strip, the Keybinding Mode grid's real-world row layout at different
window sizes, and genuine key-capture (`OnKeyDown` behavior, override
binding precedence against other addons/UI) all need one in-game pass.
