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

---

## Soundbook 3.0 QA continuation - playback-state + hover-clip investigation (2026-09-23)

Additive, same as every round above. Triggered by two fresh reports
("Kids Saying Yay" staying highlighted as playing for several seconds
after its audio genuinely ended; "Bad To The Bone" still stopping around
1s) used as entry points for a systemic re-investigation, plus a Main
window hover-clipping report, per an explicit "do not implement sound-
specific timing workarounds before determining the underlying cause"
instruction.

### Root cause #1 (real bug, fixed): the Library grid's own highlight

The Library grid's gold "now playing" highlight (`UI.lua`'s
`playingSoundID`/`SetPlayingState`) was driven **entirely** by
`SB.db.settings.announceDuration`'s fixed timer, with no connection to
the real playback handle at all. Whenever that setting (now player-
configurable up to 15s, see the Settings-restructure round above) was set
longer than a given sound's actual length, the highlight necessarily
outlived the real audio by the difference - exactly "Kids Saying Yay"'s
report. Confirmed this is what was happening, not a duration-metadata
problem: "Kids Saying Yay"'s registered duration (8.202s) matches its
shipped file's measured duration to five decimal places - there was
nothing wrong with its data at all.

Fixed by making real handle state authoritative whenever it's available:
a new `SB:GetPrimaryPlaybackHandle()` (`SoundPlayer.lua`) lets `UI.lua`
correlate the handle-less `LOCAL_SOUND_PLAYED`/`REMOTE_SOUND_PLAYED`
events to the specific instance that was just started, and a new
`PLAYBACK_PROGRESS_ENDED` listener clears the highlight the instant that
**exact handle's** real audio ends - scoped by handle, not soundID, so a
stale/older or unrelated instance can never clear a newer one, and
retriggering the same sound before the previous instance finished keeps
the highlight up until the new instance's own end. `announceDuration`'s
timer stays as a safety-net ceiling only (whichever of the two fires
first wins) - unchanged behaviour for a client without handle tracking,
and for the common case where the setting is already shorter than the
sound. Announcer.lua's own "is this sound still playing" state was
already correctly handle-scoped (`activeDisplays`/`PLAYBACK_PROGRESS_
ENDED` match `entry.handle == state.handle`) - this bug was specific to
the Library grid's separate highlight mechanism.

### Root cause #2 (data, not code - already fixed, now with harder proof)

Full re-investigation against the task's explicit checklist - fixed-timer
vs. real handle, duration/lifetime coupling, precomputed-vs-physical
duration, learned-duration staleness, `IsPlaying` polling/cleanup,
cross-instance timer interference, non-overlap `StopSound` timing,
wrong-handle invalidation, same-sound retrigger races, local-vs-remote
paths, encoding/sample-rate outliers, and duration-as-artificial-stop-
time - found nothing wrong in the playback code for "Bad To The Bone".
`StopSound` has exactly one call site in the entire addon
(`StopAllOwnSounds`), reached only via disabled-overlap logic (which
probes file existence before ever stopping an older handle) or an
explicit user Stop - both already correctly scoped to the addon's own
handles, and neither is duration-driven.

New, stronger evidence this is a corrupted source asset, not a WoW-side
encoding-compatibility problem: both "Bad To The Bone" and "Dry Fart"'s
own embedded LAME/Xing header **declares more MPEG frames than the file's
actual byte length can hold** - "Bad To The Bone" declares 42 frames,
only 20 are physically present; "Dry Fart" declares 14, only 7 are
present. That is the encoder's own record of how long the clip was
*supposed* to be (42 frames at 11025Hz ~= 2.19s, matching what "should be
around 2 seconds" expects), proving the file shipped in this repository
is missing real audio data, not that it was authored short. This
environment has no audio decode/encode tooling, and the missing frames
aren't recoverable from anything else in the repository - re-encoding
"to a conventional WoW-safe format" isn't possible here because there's
no complete source to re-encode from. A replacement recording is needed
if the original ~2.2s/~0.4s clips are wanted; until then, `SoundDurations.
lua`'s entries for both (set in an earlier round) correctly reflect what's
actually playable today, so the UI no longer promises more than the
shipped audio can deliver.

Re-ran the full library-wide audit (see the new tool below) against all
79 other shipped `.mp3` files: **zero** further duration mismatches
(tolerance 0.05s) and zero further sample-rate/MPEG-version outliers -
this is not a systemic library problem, just these two already-known,
already-flagged files.

### New developer tool - `tools/audit_sound_durations.py`

A standalone Python 3 script (standard library only, never loaded by the
`.toc`, adds no runtime addon complexity) that walks every shipped
`.mp3`'s real MPEG frames, compares the measured duration against
`SoundDurations.lua`, and flags: missing files, duration drift beyond a
configurable tolerance, sample-rate/MPEG-version outliers, and - the
specific signature that caught both known-corrupted files - a Xing/Info
header declaring more frames than the file's actual length can hold.
Never auto-edits anything; exits non-zero on any finding so it can gate
CI. Reproduces this round's manual findings exactly when run against the
current repository.

### Hover-clip fix (Main Soundbook, first row)

Root cause: the enlarged hover decoration on a Library entry
(`favouriteHover` - shown on every row on hover, not just Favourites) was
parented to the entry button itself, which lives inside the Library's own
`ScrollFrame` content. WoW clips anything nested under a `ScrollFrame`'s
content to that `ScrollFrame`'s own viewport **by ancestry**, regardless
of `FrameLevel` - raising the decoration's level (the pre-existing code
already tried `btn:GetFrameLevel()+30`) cannot escape that. On the first
visible row, the decoration's top edge (150% of the icon, deliberately
larger than its row) could extend above the viewport's own top edge and
get clipped there - worse with the tag filter bar visible, since that
shrinks the available viewport height further.

Fixed by reparenting the decoration to `main` directly (outside the
`ScrollFrame`'s clipped ancestry, per the task's own suggested approach)
while keeping its anchor point on the icon slot **inside** the scroll
content as the layout anchor - its on-screen position still tracks the
real icon exactly, including while scrolled, since WoW anchor resolution
doesn't require common ancestry. Since `Hide()` no longer cascades from
the entry button to a decoration that's no longer its child, added
explicit companion `Hide()` calls at both places entry buttons are bulk-
hidden (pool recycling in `RefreshLibraryImpl`, and the Settings/Admin/
Keybind-Mode panel-swap in `RefreshMainWindow`) so a row hovered right
when it's hidden/recycled can never leave an orphaned decoration floating
on screen.

### Verification

Upgraded the mock WoW API harness first - no existing test had ever
driven a real start -> playing -> natural-end cycle through
`SoundPlayer.lua`'s poll loop (`PlaySoundFile` always returned the fixed
handle `1`, `C_Sound.IsPlaying` always returned `false`, and
`C_Timer.NewTicker` never actually fired). `PlaySoundFile` now returns
unique incrementing handles, `C_Sound.IsPlaying` is controllable per
handle (`SetMockSoundPlaying`), and tickers are queued and advanceable on
demand (`TickMockTickers`), all opt-in so no existing test's behaviour
changed. New `loader_playback.lua` directly reproduces the reported bug
(`announceDuration=15s`, a sound's real playback ending well before that)
and confirms the highlight now clears promptly; also covers a stale/
unrelated handle's end event being ignored, same-sound retrigger
instance-scoping, several different sounds triggered in succession with
overlap disabled, and overlap-enabled never calling `StopSound`. All 7
pre-existing regression scripts stayed green throughout every change
this round.

### Still gated on a live client

The hover-clip fix's real-world correctness (the enlarged decoration
actually renders above the tag filter bar's own row and every other
Library element, with no z-order surprises against WoW's real rendering,
which a Lua-only mock cannot verify) needs one in-game pass, both with
and without the tag filter bar visible. The playback-state fix's
behaviour with a genuinely unreliable `C_Sound.IsPlaying` on some client
build (the scenario `MAX_TRACKED_LIFETIME`/`NEVER_STARTED_TIMEOUT` exist
to bound) is logically covered but not something this environment can
reproduce against a real client either.

---

## Round 7 - Settings blank-content regression, Settings header, Output Rail unification

### 1. Settings view rendering empty

**Root cause**: `SB.BuildSettingsPanel`'s five section `content` frames were
never given an explicit/provisional height at creation. `FitSettingsPanelHeight`
computes the real height from `content:GetTop()` minus the lowest child's
`GetBottom()`, guarded by `if top and bottom then ... end` - in real WoW,
`GetTop()`/`GetBottom()` can legitimately return `nil` before a frame has
ever actually been shown/laid out, and that guard just silently no-ops in
that case rather than falling back to anything. `BuildSettingsPanel` calls
`ShowSettingsSection` + `FitSettingsPanelHeight` synchronously at the end of
its own construction, which itself runs inside `BuildMainFrame` - i.e.
before the Main window has ever been shown once. That's exactly the nil-
geometry window. Every section's content frame was left at a fresh frame's
default (effectively zero) height: `Shown = true`, but functionally
invisible inside the ScrollFrame - tab buttons and the empty Help/version
footer were the only things with an explicit height, hence "tab buttons
present, content area almost entirely empty."

**Fix**: restored a provisional height on both the scroll child
(`SetSize(1, 2000)`) and each section's `content` frame (`SetHeight(2000)`)
at construction time - the same defensive pattern the pre-restructure
single-page Settings.lua used and which the 5-tab rewrite had dropped
without a replacement - plus floored the real computed height in
`FitSettingsPanelHeight` (`math.max(60, ...)`) so a bad transient reading
can never collapse it back to near-zero again.

**Also fixed in the same pass** (both were real, previously-unnoticed bugs,
not new regressions from this fix): Search and the Output Rail (broadcast
tabs) stayed visible and interactive while Settings/Admin/Keybind Mode
owned the content area - `RefreshMainWindow` hid the Library grid/filter
bar when switching to a panel view, but never touched `searchBox`,
`searchPlaceholder`, or `broadcastTabButtons`. Both are now hidden/shown in
lockstep with the panel state.

### 2. Settings: dedicated header

Settings/Admin/Keybind Mode now replace the Library's title row with
`[< Library]` + a context label naming the active view, instead of leaving
the "Soundbook" product title sitting above an unrelated internal view.
Same row/position as the title it replaces; Search is already hidden at
the same time (above), so the header reads as "you are in Settings now,"
not "the Library header, minus a working search box."

### 3. Output Rail: coherent segmented control

The five broadcast targets (All / Guild / Raid-Party / Friends / Self
Only) previously each drew their own independent backdrop and border,
stacked with a small gap - explicitly reported as "still looks like five
old-style bordered rectangles attached outside the window" despite already
having filled selected-state backgrounds, an accent strip, and a glow from
an earlier round. They now live inside one shared container frame that
draws a single background/border; each segment is borderless and
separated from its neighbour by a thin 1px divider line instead of a gap,
so it reads as one control with five selectable zones. Selected-state
visuals (filled Arcane-tinted background, brighter text, left-edge accent
marker, soft glow) and the dynamic Party/Raid label are unchanged from the
prior round, since neither was actually the reported problem - the
container-level bordering was.

### Verification

All 8 mock regression scripts (`loader.lua`, `loader2.lua`,
`loader_broadcast.lua`, `loader_favgrid.lua`, `loader_popout.lua`,
`loader_raidadmin.lua`, `loader_settings.lua`, `loader_playback.lua`) pass.
`loader_settings.lua` gained two new checks this round: one that walks the
real frame tree (not just "did it error") down to the Settings scroll
child and asserts its actual `GetHeight()` never collapses below 60px
across all five sections - this is the check that would have caught the
blank-Settings bug originally, since the mock's own `GetTop`/`GetBottom`
always return numeric fallbacks and never reproduce real WoW's nil-before-
first-Show behaviour on their own - and one that drives the Settings tab
open/closed via a real button click and asserts the title/back-button/
context-label swap happens correctly in both directions.

### Still gated on a live client

Both fixes above are verified by construction (the height floor
mathematically cannot produce a near-zero value again) and by a mock
harness test that reads the same frame tree and geometry API real WoW
exposes, but this environment has no live WoW client. The specific
nil-before-first-Show state that caused the original bug is not something
the current mock can spontaneously reproduce (it always returns a numeric
fallback), so this round's regression test asserts the *value* directly
rather than relying on the mock to hit that edge case naturally - that
gap is a real limitation of the test harness itself, not just this
feature, and is worth closing if another geometry-timing bug surfaces
again. The Output Rail's visual result (does it actually read as "one
control" against WoW's real rendering, spacing, and font metrics) still
needs one in-game screenshot pass, same as every prior round's UI-only
changes.

The broader redesign items from this round's request beyond the three
above - header/title typography restraint, Search preferred/max width,
unified header-action states, filter-row grid alignment, a full named-
metrics design-system pass, and a fresh re-verification of the Announcer
popup/Edit Sound/Icon Picker/playback-truncation fixes already shipped in
earlier rounds - were not revisited this round. Code inspection confirms
the Search min/max width clamp (`SEARCH_MIN_W`/`SEARCH_MAX_W`), the
restrained (non-oversized) title treatment, and the shared header-action
button component were already implemented in Round 5's header rework, and
`loader_popout.lua`/`loader_playback.lua` continue to pass every existing
assertion for popup direction, idle drag preview, and playback truncation
- but none of that was re-derived or re-tested fresh this round, only
re-run against the existing suite.

---

## Round 8 - UI/UX polish pass: shared design system across Main, Settings, Edit Sound, Keybindings

A layout/design-system pass, not a feature redesign - preserves every
existing workflow, keybinding, SavedVariables field and multiplayer
protocol untouched.

### 1. Shared foundation (Theme.lua / Core.lua)

- **New `Title` font tier**: a ~30% larger variant of `NormalLarge`,
  created once in Core.lua alongside the addon's other font objects (so
  it survives the user's own font/scale settings the same way every other
  Soundbook font object already does). Used for every screen's primary
  heading.
- **`Theme.ApplyTitleStyle`**: applies that font tier plus the exact
  colour/shadow `Theme.CreateHeader`'s own title already used (the
  established Edit Sound look) to a caller-built FontString - the "one
  primary title treatment" the request asked for, instead of each screen
  picking its own colour.
- **`Theme.LAYOUT`**: a small named spacing/sizing table (`SAFE_INSET`,
  `GAP_S/M/L/XL`, `CONTROL_H`, `HEADER_H`, `ICON_BTN`, `TAB_H`) that Main,
  Settings and Keybindings now read from instead of each re-deriving its
  own magic offsets.
- **`Theme.CreateTabButton`**: a genuine 4-state tab control
  (idle/hover/active/disabled). Replaces Settings' previous tab strip,
  which reused `CreateFlatButton` (only idle/hover/disabled) with a
  manually-toggled underline bolted on - its "active" state was literally
  the same fill a plain hover on any OTHER tab already produced, so a
  hovered inactive tab and the real active one looked identical.

### 2. Main Soundbook header

- Title row grown from 22px to 32px (`Theme.LAYOUT.HEADER_H`); "Soundbook"
  now renders in the shared `Title` tier with the Edit-Sound-matching
  colour/shadow instead of a smaller flat gold label - "clearly more
  prominent, comparable in visual quality and hierarchy to Edit Sound's
  title" without importing Edit Sound's own crest bar (no added
  ornamentation, per the request's own "do not add more ornamentation").
- Outer safe inset grew from 8px to 14px (`Theme.LAYOUT.SAFE_INSET`) -
  search, the header icons and the filter pills no longer sit flush
  against the decorative frame.
- The Settings/Admin/Keybind Mode "< Library" + context-label header that
  swaps into the same slot uses the identical title treatment, so
  switching views never changes which font/colour "the current screen's
  name" renders in.
- Close/Lock/Quick Audio re-centred within the taller title row
  (unchanged chrome, just repositioned).

### 3. Main Library

- Favourites section header: caret -> icon -> title -> Keybinds action
  now sit with deliberate `GAP_S`/`GAP_M`-based spacing instead of a
  tight, hard-coded 2px pairing; the Keybinds button uses the same
  secondary-button chrome Settings/Edit Sound already use, sized to
  clear the taller row comfortably.
- Sound rows: icon/name/hotkey/tag margins widened from 4/8px to the
  shared `GRID_LEFT_PAD`/`GAP_S` values (6px) - same row height and
  density as before (explicit requirement: "keep density"), just less
  visually compressed at the edges.
- Filter pills: now left-aligned to the same content guide the Library's
  own section headers and sound rows start from (`GRID_LEFT_PAD`),
  instead of centring independently across the toolbar's full width.
- Output Rail's Admin/Settings utility tabs (previously two individually
  bordered tiles sitting next to the now-unified broadcast-tab rail from
  the prior round) now live inside their own single shared bordered
  container, using the same borderless-segment-plus-divider treatment -
  the whole right-side dock reads as one design language again instead
  of one unified group next to two leftover old-style tiles.

### 4. Settings

- Tab strip rebuilt on `Theme.CreateTabButton` - the active tab now has
  a visibly distinct look (filled gold-tinted background + underline)
  from a merely-hovered inactive one, verified by a new regression check
  that exactly one tab reports active at a time after switching sections.
- Content column widened from 450px to 480px. Verified by hand against
  the real geometry chain (Main's minimum window width -> content region
  -> `FitSettingsPanelHeight`'s own scrollbar/margin reservations) to
  stay safely inside the actual scroll child width even at the Main
  window's smallest resizable size (560px) - not just "looks fine at the
  screenshot's window size."
- Tab row / scroll / footer margins now read from the same shared
  `Theme.LAYOUT` gaps Main's own toolbar uses.

### 5. Keybindings

- Removed the redundant in-panel "Favourite Keybindings" title - the
  Main toolbar's own context header (added last round) already names
  this screen using the identical shared title treatment, so the old
  second heading was pure duplication and part of what made the hint
  text/title/Done button compete for space.
- Rows restructured into clearer slot-number / icon+name / binding /
  Clear columns with a real left safe-area inset, plus the same
  alternating-row-tint and separator language the Main Library's own
  sound rows use - reads as the same product family instead of a bare,
  undecorated list.

### 6. Edit Sound

Deliberately left structurally untouched beyond inheriting the shared
`Title` font tier automatically through `Theme.CreateHeader` (which it
already used) - it was already the acknowledged reference for this
round's header treatment, already built on the same shared component
library (`Theme.CreateCheckbox`/`CreateInputBox`/`CreateSecondaryButton`/
`CreateIconSlot`) every other screen uses, and the request explicitly
asked to "preserve compactness; do not make it bigger unless required to
fix layout problems" - no layout problem was reported here.

### Verification

All 8 mock regression scripts pass (`loader.lua`, `loader2.lua`,
`loader_broadcast.lua`, `loader_favgrid.lua`, `loader_popout.lua`,
`loader_raidadmin.lua`, `loader_settings.lua`, `loader_playback.lua`).
`loader_settings.lua` gained a new check this round: walks the Settings
tab row's real children and asserts exactly one `Theme.CreateTabButton`
reports `IsActive() == true` after switching sections, and that it's the
one matching the section actually shown - this is the check that would
have caught the old "active looks like hover" issue, since every
previous test only checked "the right section's content is Shown", never
what the TAB ITSELF looked like.

### Still gated on a live client

This is a pure layout/typography/spacing pass verified by code reading,
manual geometry arithmetic (the Settings content-width safety margin
specifically), and the mock harness reading back real anchor/size values
where the harness's own geometry model supports it. This environment has
no live WoW client. Every spacing/sizing number above was chosen and
cross-checked by hand against the actual anchor chains and Main window's
real min/max resizable bounds (560-720 width), not eyeballed from a
screenshot - but the final "does this actually look premium and
cohesive" judgment call still needs one in-game pass, at more than one
window size and UI scale, the same residual gap every prior visual round
has disclosed.
