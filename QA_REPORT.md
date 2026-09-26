# Soundbook QA report

Historical technical protocol, oldest entry first: the original 2.5.0 release candidate report below, followed by dated/named development rounds carrying the product through the Soundbook 3.0 redesign up to the current build (3.0.0, database v28). Each entry reflects the state and understanding at the time it was written; later entries supersede earlier claims about current behavior where they conflict - see `README.md`, `CHANGELOG.md`, and `MIGRATION.md` for the current-state summary instead of relying on any single entry here in isolation.

## Soundbook 2.5.0 QA report (original entry)

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

---

## Round 9 - Targeted corrections: shared header, header controls, resize/popup bugfixes, Settings tabs, New Sounds isolation

A precise, targeted list of corrections, not another broad redesign pass -
applied literally against each numbered requirement rather than
re-touching areas not named.

### 1. Shared header (Main / Settings / Keybindings)

Main's title row (previously a small, left-aligned, custom-built label +
divider) is now `Theme.CreateHeader` itself - the exact same crest/gold-
divider component Edit Sound's own header already used, at the requested
~60px height with a new shared `Title` font tier (~24px at normal scale,
1.5x `GameFontNormalLarge`'s 16px baseline). The label is centred against
the header's own **full width**, not "whatever space is left" - the back
button and the utility icons are separate overlays anchored to the
header's own corners, so neither can pull the title off-centre. Settings
and Keybindings already shared Main's header via the existing panel-swap
mechanism (Task #31, an earlier round), so they inherited this
automatically - opening either now shows the same centred, crested header
with a `< Soundbook` back button (was `< Library` - there was never a
destination called "Library").

### 2. Main top-right controls

Quick Audio / Lock / Close, in that order, 24x24 visual size, 6px gaps,
16px inside the header's own right edge. Each gets a ~28x28 effective
click target via `SetHitRectInsets` (no separate wrapper frame needed for
this). Quick Audio's icon changed from a WoW inventory icon
(`INV_Misc_Bell_01`) to a new `Theme.CreateAudioGlyph` - a monochrome
speaker-with-slash glyph pulled from Soundbook's own `ControlIcons.tga`
atlas (verified by rendering the actual texture - the atlas's "mute"
quadrant literally *is* a speaker icon, not a placeholder). Hover across
all three now reads as Arcane Cyan instead of gold - gold was previously
used for both hover AND pressed, making the two indistinguishable; gold
is now reserved for pressed/active states only.

### 3. Search

Centred in the content area below the header, 66% of available width
with a 320px minimum (was a fixed-position box anchored to the old
toolbar's bottom-left, 140px minimum). Uses a single `TOP` anchor plus an
explicit width recomputed on resize, so changing only the width keeps it
centred automatically - verified to stay centred at both the Main
window's minimum (560px) and maximum (720px) width.

### 4. Bugfixes

- **Resize grip**: a plain click (no drag) could visibly expand the
  window. Root cause: `OnMouseDown` called `main:StartSizing("BOTTOMRIGHT")`
  unconditionally - WoW's `StartSizing` ties the given corner directly to
  the *current* cursor position from that instant on, not a delta from
  where the click started. The grip's own hit region is deliberately
  larger than (and inset from) the window's true corner (an earlier
  round's "too small to click" fix), so a click anywhere in that padding
  made the corner jump to the cursor immediately, even with zero
  movement afterward. Fixed by switching to
  `RegisterForDrag`/`OnDragStart`/`OnDragStop` - WoW's own drag detection
  already requires genuine mouse movement while held before `OnDragStart`
  fires, so a plain click never reaches it at all. Same pattern `main`
  itself already used for window-move, just never applied to the grip.
- **Broadcast/channel popup** used to open LEFT of its trigger by
  deliberate previous-round design ("toward the screen interior") -
  directly over the Library/sound list. Now opens RIGHT (outside the
  Main window, 8px gap) by default, via an explicit
  `GetRight()`-vs-`GetScreenWidth()` check, flipping left only when the
  screen genuinely doesn't have room - not left to `SetClampedToScreen`
  alone, which could slide it back over the Library on a narrow or
  off-centre screen.
- **Default Output tabs** (Guild/Raid/Friends) became fully unclickable
  (`EnableMouse(false)`) whenever the player had zero people in that
  bucket (not in a guild, no group, no online friends) - silently
  removing the option instead of just showing "nobody there right now."
  The flyout's own empty-state message ("Not currently in a guild", etc.)
  already existed and worked correctly - the only bug was that you could
  never actually open it. Now always clickable; still dimmed (60% alpha)
  for information only.

### 5. Mini Soundbook

- Favourite-selection popup's column width raised 10% (150→165px at 2
  columns, 118→130px at 3) - width only, row height and every interaction
  unchanged. Verified via the mock harness: popup width now reports
  338/398 (was 308/362).
- "Play sound locally" / "Play locally" → "Play for Yourself" everywhere
  this Mini Soundbook state is shown (the Favourites popup's own summary
  header, both the "no per-sound overrides" and "override present"
  phrasings).

### 6. New Sounds preview isolation

Every row click now calls `SB:StopAllSounds()` - the same public stop
path the Mini Soundbook's own Stop button and `/sb stop` already use -
immediately before `SB:TriggerSound(soundID, "SELF")`. `SB:PlaySound`
only self-stops previous audio when the player's "Allow overlapping
sounds" setting is *off*; this explicit call makes New Sounds behave like
an exclusive one-at-a-time preview player regardless of that setting,
without ever touching the saved setting itself. `SB:TriggerSound`'s
`"SELF"` override already took absolute precedence over both the global
Default Output and any per-sound "Default Output" override
(`SB:ResolveOutputTarget` checks the explicit override first) - already
correct, verified by reading the resolution order rather than assumed.

### 7. Settings

- **Tab labels**: shortened to one word each - Sound / Sharing / Mini /
  Library / Advanced - underlying section keys and content completely
  unchanged. Tabs now share the row's live width evenly (recomputed on
  resize, so five labels never clip even at the Main window's 560px
  minimum), 8px gap, 28px height.
- **Tab active state rebuilt**: no filled tile any more. Active = primary
  text + a 2px underline (width = label width + 12px) in that category's
  own colour - Sound: Arcane Cyan, Sharing: the existing Guild green,
  Mini: GOLD, Library: the existing Friends blue, Advanced: the existing
  Raid/Party orange. Hover (inactive only) tints the text toward that
  same colour at reduced intensity; inactive stays dim. Verified this
  doesn't recolour anything outside the tab strip itself.
- **"Channels" heading**: was a plain small `HighlightSmall` label,
  visually weaker than "Notifications" right below it despite both being
  section headings. Now uses the same `Theme.CreateSectionHeader`
  component (gold text + divider line) both already shared before this
  fix only applied to one of them.
- **"Chat Notifications" → "Notifications"**, and the large empty gap
  above it is gone: the Global Receive Mute info block used to reserve a
  fixed 54px whether or not a mute was actually active (explicit earlier
  design intent, since revised) - it now collapses to ~1px when idle and
  reflows automatically via WoW's own live anchor resolution, so
  Notifications starts right after Channels with one clean ~24px gap
  instead of a large reserved blank region. Still expands to the real
  54px content when a mute genuinely is active.
- **Footer removed**: the persistent "Help & Information" footer
  (divider, label, two half-width buttons, version text) is gone
  entirely - no empty container left in its place. Replay Introduction
  and Latest Sound Updates moved into Advanced, stacked one-per-row with
  Run Diagnostics (8px gaps, full content-column width instead of the
  old cramped half-width pairing) as one three-button action area; the
  version text moved down with them. Every button's own click action is
  unchanged.

### Verified already correct (no change needed)

- **Fresh-install two-column layout**: the default `mainWidth` (560,
  `Core.lua`'s `defaults.ui.mainWidth`) is already below the 3-column
  threshold (`THREE_COLUMN_WIDTH = 600`), so a genuinely fresh install
  already renders 2-column without any code change - confirmed by reading
  both values directly, not by assumption.
- **Content margins**: the Library's left/right/bottom insets were
  already effectively symmetric (a 2px difference on the right is
  reserved for the scrollbar itself, not visible content) from an earlier
  round's own pass - left untouched rather than introduced a new
  asymmetry.

### Verification

All 8 mock regression scripts pass (`loader.lua`, `loader2.lua`,
`loader_broadcast.lua`, `loader_favgrid.lua`, `loader_popout.lua`,
`loader_raidadmin.lua`, `loader_settings.lua`, `loader_playback.lua`).
Updated `loader_settings.lua`'s own header-swap test for the new
`main.header`/`main.header.backBtn` structure (replacing the retired
`toolbar.mainTitle`/`toolbar.contextTitle` pair), and `loader_broadcast.lua`'s
Self Only header-text assertion for the new "Play for Yourself:" wording.

### Still gated on a live client

Every change this round is either a verified geometry/anchor-chain fix
(read against the real formulas, not eyeballed), a root-caused behavioural
bugfix (resize grip, popup direction, Default Output availability), or a
verified texture/asset substitution (Quick Audio's speaker glyph,
confirmed by rendering `ControlIcons.tga` directly rather than guessing
what a texture atlas quadrant contains). This environment still has no
live WoW client - the final "does the header actually read as ~60px and
~24px at a real UI scale, does the resize grip feel right under a real
mouse" pass needs one in-game check, same residual gap every visual round
has disclosed.

---

## Round 10 - Settings position, resize/lock rework, Output Rail overhaul, Mini Soundbook fixes, Ignore blocking

Another precise, targeted correction list - Settings' category strip
position, the Main resize grip's real root cause, Lock semantics, Output
Rail behaviour, two Mini Soundbook bugs, and a new multiplayer feature
(Ignore blocking). Explicit instruction honoured: no broad redesign, no
change to the header itself.

### 1. Settings: category strip position

Re-anchored `Settings.lua`'s tab row directly off `mainFrame` using a
newly-exposed `SB.LIBRARY_CONTENT_TOP_OFFSET` (the same pixel offset
UI.lua's Output Rail already computed) instead of the previous indirect
multi-hop `SetAllPoints` chain through frames (header/search/filter row)
that are `Hidden`, not just repositioned, while Settings is the active
view. Static reading of the old chain suggested it should already resolve
to the same Y as the first Library row (both computed to 159px); this fix
is robust regardless of whether that was the exact prior cause, since a
single shared, always-live pixel value can only be more reliable than an
indirect chain through sometimes-hidden frames, never less.

### 2. Main resize grip - real root cause, second pass

The first round's fix (`RegisterForDrag`/`OnDragStart` instead of
`OnMouseDown`) stopped a zero-movement *click* from engaging resize, but
a genuine *drag* could still visibly jump the window the instant it
crossed WoW's own drag threshold - because the handler still called
`main:StartSizing(point)`, which ties the given corner directly to the
cursor's live absolute screen position from the instant it's engaged, not
a delta from where the drag started. Combined with the grip's own
deliberately-oversized hit region (an earlier round's own click-ability
fix), engaging `StartSizing` from anywhere inside that padding jumped the
window by exactly that offset.

Fixed by abandoning `StartSizing`/`StopMovingOrSizing` entirely: on
`OnDragStart`, the window's current on-screen `TOPLEFT` is captured
(`GetLeft()`/`GetTop()`) and re-pinned there, plus the cursor's own
starting position (`GetCursorPosition()`, scale-corrected via
`GetEffectiveScale()`); every `OnUpdate` tick then recomputes width/height
purely from the cursor's own movement *since drag-start* (delta, not
absolute position), clamped to the existing 560-720/560-760 bounds, and
applies it via `SetSize()`. Mathematically deterministic regardless of
where inside the grip the drag began - the "jump" class of bug is no
longer reachable at all, not just less likely.

Verified via a new mock-harness assertion in `loader.lua`: a plain click
(no `OnDragStart` ever fires - proven by asserting the old
`OnMouseDown`/`OnMouseUp` handlers are gone) does nothing; a simulated
40px cursor delta resizes by exactly 40px, not a jump to some absolute
position; a simulated 5000px delta clamps to exactly 720x760, never
exceeds it.

### 3. Lock semantics reworked

Old rule: Lock blocked both moving and resizing Main. New rule (explicit
requirement): unlocked - movable and resizable, grip visible and
interactive; locked - **still movable** by dragging the header, **only**
resizing is disabled, and the grip is completely hidden (`SetShown(false)`)
and mouse-disabled (`EnableMouse(false)`, `SetHitRectInsets(0,0,0,0)`) so
no invisible hit area survives. Unlocking restores the grip and manual
resizing immediately. Mini Soundbook's own, separate lock semantics are
unchanged. Verified in the same `loader.lua` test: locking hides the grip
and makes a drag-start on it a no-op (defence in depth, since `IsShown`/
`EnableMouse` already stop a real click from reaching it), while Main's
own `OnDragStart` still fires normally throughout.

### 4. Main bottom content spacing

`libraryScroll.scroll`'s bottom anchor gained +10px inset (`SAFE_INSET+10`
instead of `SAFE_INSET`) between the last sound row/pagination area and
the inner bottom frame, at the existing left/right insets - no new empty
footer, scales with window height like every other Library anchor already
does.

### 5. "Favourites" -> "My Favourites"

Renamed the Main Library section's visible heading only - the tab display
label and the direct `ConfigureHeader` call both now say "My Favourites";
underlying section key/data (`"favourites"`) untouched. Mini Soundbook's
own separate wording was out of this round's scope and left alone.

### 6. Category-header tooltips

Every collapsible category header (a pooled/reused row) now carries a
dynamic `tooltipTitle`/`tooltipBody` pair (set in `ConfigureHeader`, since
`Theme.AttachTooltip`'s fixed-text-at-attach-time shape doesn't fit a
reused row) and a new `OnEnter`/`OnLeave` pair that shows it: **My
Favourites** - "Click to collapse or expand. Add favourites with Shift +
Click, or enable Favourite in Edit Sound."; **Hide/Hidden** - "Click to
collapse or expand. Hide a sound from Edit Sound by enabling Hide."; every
other category - "Click to collapse or expand this category."

### 7. Main Output/Channel Selector overhaul

- **Always selectable at zero recipients**: All/Raid/Guild/Friends/Self
  Only remain visible and clickable regardless of group/guild/friend
  availability - no auto-fallback, no hiding/disabling. A new
  `rail.channelSelected[bucket]` boolean, set/cleared alongside every
  member-selection mutation, distinguishes "explicitly selected, zero
  eligible members" from "never touched" (the member array alone can't
  tell these apart), driving the tab's active/visual state independent of
  member count.
- **"Raid" label always**: the merged Raid/Party target now always
  displays as "Raid" in this selector (was conditional on `IsInRaid()`/
  `IsInGroup()`); the underlying Raid/Party transport resolution
  (`SB.ResolveGroupChannel`) is unchanged.
- **Exact channel colours**: a new `HexColor(hex)` helper (the standard
  `tonumber(hex:sub(1,2),16)/255` pattern) implements the exact requested
  hex values precisely - All `#F2F5FF`, Friends `#B88CF2` (deliberately
  different from the existing `SB.CHANNEL_COLOR.FRIENDS`, used only
  elsewhere), Guild `#8CE09E`, Raid `#FAB87A`, Self Only `#7A7A80` - as
  full-colour active text, a same-colour tinted background, and a
  same-colour accent border, all visible even with zero recipients
  (driven by `channelSelected` above, not hover).
- **Click selects the whole channel AND opens its submenu**: Guild/Raid/
  Friends now call `SB.SetBroadcastBucketAllSelected(bucket, true)` before
  opening the flyout, so a single click both selects the whole channel
  (Friends -> "All Friends", Guild -> "All Guild", Raid -> the whole
  Raid/Party target) and opens the member submenu with it already shown
  selected; individual members remain separately selectable underneath.
  A second click on an already-open bucket still toggles it closed
  (unchanged). Works identically with zero members (submenu just shows an
  empty state, channel still counts as selected).
- **All/Self Only stay hover-only**: no member dropdown for either - only
  the required hover text ("Play for yourself and send to all enabled
  Soundbook channels." / "Play only for yourself. Nothing is sent to other
  players."), now anchored via `ANCHOR_NONE` + an explicit `SetPoint`
  (not `ANCHOR_LEFT`/`ANCHOR_RIGHT`, which position relative to the
  *cursor*, not the selector) with an 8px gap from the selector's own
  right edge, flipping to the left only when there isn't enough on-screen
  room to the right (`GetRight()` vs `GetScreenWidth()`, the same pattern
  the broadcast flyout's own left/right flip already used).

Verified via new targeted assertions in both `loader.lua` and
`loader_broadcast.lua`: Guild/Raid/Friends tabs are found and clickable
with a live roster; clicking Friends with zero eligible members still
marks it selected (`channelSelected.FRIENDS == true`) with 0 members
shown; the Raid tab's label reads "Raid" regardless of group state.

### 8. Mini Soundbook: Announcer Preview trigger bug

Opening the Announcer's Quick Options menu previously called
`ShowDemoBanner()` unconditionally at the end of
`SB.ShowAnnouncerQuickOptions`, showing fake preview content coupled to
the menu's own open state - wrong per explicit requirement ("opening
options must never show the Preview... do NOT couple preview visibility
to the options-menu open state"). Removed that entire code path
(`ShowDemoBanner`/`HideDemoBanner`/`demoBannerActive`, and the Announcer
Size slider's own `if demoBannerActive then banner:SetScale(...)` live-
preview hook) rather than patching around it - the Preview is now driven
exclusively by the icon's own pre-existing, already-correct reposition-
drag mechanism (`StartIconDragPreview`/`StopIconDragPreview`), completely
untouched by this fix.

Verified via a rewritten section of `loader_popout.lua`: a full snapshot
of the banner's observable state (`IsShown`, alpha, `nameText`,
`soundbookSoundID`) is taken before opening Quick Options, and asserted
byte-for-byte unchanged after opening, after changing the Announcer Size
slider, and after closing - `IsShown()`/alpha alone aren't reliable
signals here (the mock's queued `C_Timer` never actually runs
`CollapseToIdle`'s deferred `Hide()`), so the test checks that literally
nothing about the banner changes at all instead. The reposition-drag
preview itself, and its "a real sound arriving mid-preview must not be
clobbered" guarantee, are both re-verified working exactly as before,
just correctly re-anchored to the actual trigger.

### 9. Mini Soundbook: independent Announcer Size / Mini Soundbook Size

A single `ui.announcer.scale` used to drive both the Announcer's own
visuals (icon/banner `SetScale`) *and*, indirectly, the Favourites
popup's 2-vs-3 column threshold - resizing one always affected the other,
with no way to make favourites bigger without also blowing up the
Announcer. Split into two independent persisted fields:

- `ui.announcer.scale` ("Announcer Size") - Announcer icon/banner/Preview/
  Now Playing/announcer text only, via the existing `SB:RefreshAnnouncerScale`.
- `ui.announcer.favScale` ("Mini Soundbook Size", new) - the favourite-area
  popup only (icons, sound-name text, dropdown/name-area width), via a
  new `SB:RefreshMiniSoundbookScale()` that `favMenu:SetScale()`s it,
  called from `SB.ShowFavMenu`. `GetFavMenuColumns`'s 2-vs-3 threshold now
  keys off `favScale`, not `scale`.

Both: 50%-200%, step 10%, default 100%. `DB_VERSION` bumped 27->28 with a
migration that seeds `favScale` from whatever the single prior `scale`
already was (clamped into 0.5-2.0) for upgrading players - never resets
an existing user to 100%; a fresh install gets 1.0 in both directly from
the defaults table. Two new sliders added to Settings -> Mini
("Announcer Size", "Mini Soundbook Size" directly below it); the existing
Quick Options popup's own Announcer Size slider widened from 70-160 to
the same 50-200 range.

Verified via a new `loader_scalesplit.lua`: fresh-install defaults (both
1.0); migration from a pre-split v27 snapshot with `scale = 1.4` (both
fields end at 1.4, not reset); migration with an out-of-range prior value
(`9.9`) clamps `favScale` to exactly 2.0; changing one scale via its real
callback path rescales only its own frame, verified by reading
`icon:GetScale()`/`favMenu:GetScale()` directly before and after each
change; both values survive a simulated `/reload` (`PrepareDatabase` run
again on the resulting SavedVariables snapshot).

### 10. Multiplayer: Friends delivery path - verified, no fix needed

Read `Communication.lua`'s full Friends path end-to-end against the
requirement list: `SB.ComputeReachablePlayers()` already filters the
Friends bucket to `SB.db.knownUsers` (confirmed Soundbook installs) for
every dropdown/submenu; the actual "All Friends" broadcast
(`SendToFriends`) sends to every currently-connected friend blind (the
correct, standard presence-discovery approach - a client without the
addon just silently ignores the unknown prefix); a specific single friend
send reuses the same `SendToPlayerSilent`/`SB:SendSoundToPlayer` path
every other Direct target does; de-duplication against Guild/Raid overlap
already existed (`GetGroupCoveredNames`, and `SB.ComputeReachablePlayers`'s
own Friends > Raid > Guild priority claim); the ACK reply
(`SB.SendAddonMessage(...".."ACK"...)`) is only ever sent *after*
`SB:PlaySound(soundID, "remote")` returns true - never optimistic. No
code change was needed; this was a verification pass, not a bugfix.

### 11. Multiplayer: Ignore-list blocking (new feature)

Full write-up in this session's commit message
(`Add Ignore-list enforcement to Soundbook communication`) - summary:

- `SB:IsIgnored(name)` (Core.lua), same enumerate-and-match shape as the
  existing `SB:IsFriend`.
- Outbound: `SendToPlayerSilent` (the shared funnel for Default-Output/
  SUBSET targets) and `SendToFriends` silently skip anyone the sender has
  ignored, continuing delivery to everyone else; `SB:SendSoundToPlayer`
  (the explicit single-target SendMenu action) additionally prints
  "Cannot send to `<Player>`: Soundbook communication is blocked by
  Ignore." A whole-channel Guild/Raid broadcast can't be filtered
  per-recipient at send time, so that direction relies entirely on the
  inbound check.
- Inbound: `IsPlayableRightNow` (the pre-queue/pre-rate-limit gate, so an
  ignored sender's message never burns a queue slot or rate-limit credit)
  and `HandlePlayCommand` (the final redundant safety net for an entry
  that sat queued, mirroring the existing raid-mute/individual-mute
  pattern) both reject before playback - never queued, never played,
  never recorded to History, never given a normal success ACK. Replies
  with a new `IGNOREACK`, extending the existing ACK/MUTEACK/RXOFFACK
  protocol.
- Sender-side aggregate: a new `HandleIgnoreAck` folds `IGNOREACK` replies
  into the existing debounced receipt summary as "(N blocked by Ignore)",
  alongside "(N muted)"/"(N receive-off)" - one ignored recipient never
  hides or aborts the rest of a multi-recipient send's real results.
- Protocol correctness: Ignore is only ever reported when determined
  directly (our own ignore list) or explicitly signalled by the remote
  client (`IGNOREACK`) - never inferred from a bare timeout, which keeps
  its existing unreachable/no-ACK behaviour (the case where *they* have
  ignored *us*, and WoW's own whisper suppression means we never even see
  the send attempt at all).

Verified via a new `loader_ignore.lua`: outbound blocking for a single
target (no message sent, exact required chat line printed) and for "All
Friends" (1 of 3 skipped, the other 2 still sent); inbound rejection via
a real `CHAT_MSG_ADDON` round trip through the addon's own event handler
(`SoundbookCommFrame`) - zero `SB:PlaySound` calls, zero
`REMOTE_SOUND_PLAYED` fires (proving no History entry), exactly one
`IGNOREACK` reply, never a normal `ACK`; a non-ignored sender in the same
test still plays and ACKs normally (no false positives); and the
sender-side aggregate line, built from two real `ACK`s plus one
`IGNOREACK`, reads exactly `"...(Friend received: Alice, Bob) (1 blocked
by Ignore)"` - the two real recipients stay listed, the blocked one is
called out separately, nothing is hidden or aborted.

### Verification

All 10 mock regression scripts pass (`loader.lua`, `loader2.lua`,
`loader_broadcast.lua`, `loader_favgrid.lua`, `loader_popout.lua`,
`loader_raidadmin.lua`, `loader_settings.lua`, `loader_playback.lua`, and
this round's two new scripts, `loader_scalesplit.lua` and
`loader_ignore.lua`).

### Still gated on a live client

Every change this round is either a verified anchor-chain fix (read
against the real pixel formulas), a root-caused behavioural bugfix
(resize grip's `StartSizing` jump, the Announcer Preview trigger), a
verified data/migration change (the scale split, exercised against a
real pre-split SavedVariables snapshot), or a new protocol extension
exercised end-to-end through the addon's own real event handler in the
mock harness. This environment still has no live WoW client - the final
"does the resize grip feel right under a real mouse, do the exact hex
channel colours read correctly at real UI scale, does a real WoW Ignore
list round-trip through `GetNumIgnores`/`GetIgnoreName` exactly as
assumed" pass needs one in-game check, same residual gap every round has
disclosed.

---

## Round 11 - Regression fixes: empty nav element, Settings position (2nd pass), Output Selector rework, Mini Soundbook sizing/title

A focused regression-correction pass on top of Round 10's own work -
every item here is a reported regression from that round, not new scope.
Explicitly scoped: only the empty Main navigation element, Settings
vertical layout, channel selection/state logic, channel popup click-
routing, Mini Soundbook sizing access/item width, and the dynamic Mini
Soundbook title.

### 1. Main: empty navigation element above Settings

Root cause: the shared Admin/Settings utility tab rail
(`BuildUtilityTabs`, UI.lua) was always sized for two rows
(`TAB_H * 2`) with Settings permanently anchored one row down, regardless
of whether Admin was actually visible - hiding the Admin button
(`adminTabBtn:Hide()`) left its dark backdrop/border box and the
divider line beneath it fully intact, an empty row for every non-admin
player. `SB:RefreshAdminTabVisibility` now collapses the whole container
to one row (and re-anchors Settings to fill it) whenever Admin is
unavailable, and restores both immediately when it becomes available -
no empty visual row, no leftover hit area, the real Admin tab is
completely unaffected when it should show.

### 2. Settings: category strip position, 2nd pass

Round 10's own fix anchored the strip via `SB.LIBRARY_CONTENT_TOP_OFFSET`
- correct for the Library's first row, but that offset bakes in the
Library's own Search box + tag-filter row heights (159px), which Settings
has neither of - reusing it left exactly the reported large empty block.
Re-anchored directly off the shared header's own bottom edge
(`mainFrame.header`) instead, skipping the Library-specific offset
entirely: 30px below the header (target 28-32px), with the selected
category's content now starting 24px below the strip (was 10px). Header
itself untouched, as required.

### 3. Main Output Selector - full rework

Five compounding issues in the same control, all traced to their real
root causes rather than patched around:

- **Toggle-off never worked**: a second click on an already-selected
  Guild/Raid/Friends row used to only close an already-open submenu, and
  never actually cleared the selection - a genuinely stuck-on channel. A
  new shared `IsBucketActive` check now drives both the tab's own active
  visual and the click decision, so a second click on an active channel
  deselects it and closes its submenu, in one click, every time.
- **Group membership gated selectability** (`IsRailBucketAvailable`
  checked `IsInGuild()`/`IsInGroup()`/reachable-friend-count) - explicitly
  wrong per this round's requirement. Replaced with `IsChannelSendEnabled`,
  reading Settings -> Sharing's own "Send" toggle
  (`SB.db.settings.broadcastModes`) exclusively. A Send-disabled channel
  stays visible and dimmed but its click now no-ops; turning Send off
  immediately clears that channel's active selection and repaints the
  rail live (`SB.RefreshBroadcastTabs`, newly exposed for Settings.lua to
  call) - even while Settings, not the Library, is the currently-viewed
  content, since the rail lives in Main's always-visible chrome.
- **All/Self Only semantics**: `SB.SelectAllBroadcastTargets` now only
  ever selects Send-enabled channels and is a real toggle (a second click
  while every Send-enabled channel is already fully selected clears all
  of them), via a new shared `SB.IsAllBroadcastFullySelected` the tab's
  own active-state check and the click handler both read from. Fixed a
  related staleness bug while at it: unchecking a single member out of a
  full "Entire X" pick left `rail.channelSelected[bucket]` stuck at
  `true` (it was only ever set by the bulk-select function, never
  recomputed by an individual toggle) - `SetBroadcastRecipientSelected`
  now recomputes it from the real resulting selection every time, so a
  genuinely partial pick can never make "All" read as fully selected.
- **Highlight sizing**: the active-state "glow" texture was deliberately
  inset -4/+4px past each tab's own edges for a soft-glow look - since
  these rows stack with zero gap between them, that overhang visibly
  bled into whichever row sat directly above/below the active one.
  Removed entirely; the existing exact-bounds backdrop colour/border/
  accent strip already satisfy "highlight exactly matches the row" on
  their own.
- **Submenu click-routing**: the flyout's fullscreen click-outside
  catcher (`TOOLTIP` strata, covers the whole screen) used to
  unconditionally close-and-consume every click it received, including
  one that visually landed on a *different* selector row sitting
  underneath it - the row's own `OnClick` never fired, forcing a second
  click. The catcher now checks `IsMouseOver()` against every selector
  button first (a pure cursor-position check, unaffected by stacking
  order) - a hit closes the old submenu **and** runs that row's full
  click action in the same event, via a new shared
  `HandleBroadcastTabClick` both paths call identically. A genuine
  outside click still just closes, as before.

Verified via a new `loader_outputselector.lua` (9 sections): the glow
field is gone; toggle on/off each complete in one click; a Send-disabled
channel is dimmed, its click no-ops, and zero eligible members never
blocks a Send-enabled one; disabling Send immediately clears an active
selection; All selects only Send-enabled channels and clears on a second
click while fully selected; a partial pick (including the stale-flag
case) never reads as fully selected; Self Only exclusivity; Raid-open-
then-Self-Only and Raid-open-then-Friends both resolve in one routed
click via the real catcher handler with `IsMouseOver` stubbed true for
the target row; a genuine outside click still only closes, changing
nothing.

### 4. Mini Soundbook: size controls + favourite item width

- **Mini Soundbook Size now in the popup too**: the Quick Options popup
  only ever exposed "Announcer Size" - "Mini Soundbook Size" added
  directly beneath it, same 50%-200%/step-10% range, writing the exact
  same `ui.announcer.favScale` field Settings -> Mini's own slider
  already used (no duplicate SavedVariables) - changing either surface is
  reflected by the other the next time it's opened.
- **Favourite item width, 2nd pass**: "Emotional Damage" was still
  truncated at 100% Mini Soundbook Size after Round 9's first widening.
  `FAV_COL_W` raised again, 165->205 (2-column) and 130->160
  (3-column, same ratio preserved) - usable text width (colW minus the
  fixed icon/padding overhead) goes from 132px to 171px, just over the
  170px target. Icon size, row height, and every icon<->text/text<->edge
  gap are unchanged, width only, no font change - the popup's own width
  is already computed from these values, so it grows to fit with no
  separate overflow handling needed.

Verified via `loader_favgrid.lua` (corrected to key off `favScale`, the
field the column-count switch actually reads since Round 10's own scale
split - it had silently been exercising the wrong field with no
assertion on the result at all) - both column widths now asserted
exactly (418/488px).

### 5. Mini Soundbook: dynamic title

Replaces the static "Send sound to X:" header with a live, deduplicated
computation of who would actually receive the sound right now, reusing
`SB.ComputeReachablePlayers` (the same live source the Output Rail itself
reads) rather than building a second, independent recipient model.
Root-cause fix: the old per-bucket count came straight from the
selection's own stored length - a frozen snapshot from whenever the
channel was selected, never re-checked against who was still actually
online. "Guild selected, then everyone logs off" kept reporting the old
member count forever instead of falling back to "Play for Yourself:" -
the exact reported bug. The new `ComputeLiveEffectiveRecipients`
intersects each selected bucket against the CURRENT live reachable list,
deduplicated by `SB.PlayerKey` across buckets, and excludes anyone on the
local player's own Ignore list (the one Ignore direction this client can
ever determine directly - the reverse is fundamentally undetectable and
deliberately not guessed at, same protocol-correctness rule the Ignore
feature itself follows).

New wording: "Play for Yourself:" (zero real recipients right now,
whatever button is technically active), "Play for Guild/Raid/Friends
(X):" (exactly one contributing channel), "Play for People (X):" (more
than one contributing channel, or "All" selected with any real
recipients at all - even if only one channel happens to currently have
anyone, since the user's actual intent was "everyone", not one specific
group).

Live updates, entirely event-driven, no polling: the existing roster
event frame (Guild/Group/Friends roster changes) now also watches
`IGNORELIST_UPDATE` and refreshes unconditionally instead of only while
Main is open (the Mini popup can be, and often is, open on its own); a
new `KNOWN_USER_CHANGED` event fires the moment a brand-new Soundbook
presence is discovered (not on the routine per-message `lastSeen`
refresh an already-known user gets constantly, which would have been
spammy); Settings' own Send toggle already flows through the existing
`OUTPUT_SELECTION_CHANGED` chain (Round 10/11's own wiring); a new
`SOUND_DISPLAY_CHANGED` listener catches a per-sound Default Output
override changing while the popup is open.

Verified via a new `loader_minititle.lua` (9 sections): the core zero-
eligible regression (title falls back to "Play for Yourself:" the moment
a fully-online guild goes offline, popup already open, no re-select); all
three single-channel wording forms; multi-channel "People" wording;
All-selected forcing "People" wording even with only one bucket actually
contributing; a stale cross-bucket selection never over-counting;
Ignore exclusion; and three separate live-update triggers (a roster
event, a Settings Send toggle, a brand-new presence discovery) each
updating an already-open popup with no re-open call. `loader_broadcast.lua`'s
own header assertions updated to the new wording throughout.

### Verification

All 12 mock regression scripts pass (the 8 pre-Round-10 scripts, Round
10's own `loader_scalesplit.lua`/`loader_ignore.lua`, and this round's two
new scripts, `loader_outputselector.lua` and `loader_minititle.lua`).

### Still gated on a live client

Every change this round is either a verified layout/anchor fix (the
empty nav row, the Settings strip position), a root-caused interaction
bug (toggle-off, the submenu click-routing swallow, the glow overlap), a
verified data-correctness fix (the live-recipient title, the stale
`channelSelected` flag), or a widened but still-approximate pixel target
(the favourite item width - "roughly 170px" against WoW's real font
metrics, which this environment cannot render or measure; see the mock's
own `GetStringWidth` stub, a fixed constant regardless of actual text,
disclosed rather than papered over). This environment still has no live
WoW client - the final "does 'Emotional Damage' genuinely fit without a
pixel to spare, does the click-routing feel instant under a real mouse,
does the highlight read as flush against the row at real UI scale" pass
needs one in-game check, same residual gap every round has disclosed.

---

## Round 12 - Mini Soundbook: surface layering, hover-open, proximity auto-close

New feature plus a regression fix: multiple Mini Soundbook-related popups
could stay visibly stacked over each other, and there was no way to open
the Mini Soundbook without a click.

### 1. Single-active-transient-surface rule

Three surfaces - the expanded Mini Soundbook (favMenu), Quick Options
(quickMenu), and the Send-to/context menu (SendMenu.lua) - previously
had no coordination at all: opening any one of them never closed
another, leaving overlapping interactive controls. New rule, real
`Hide()` calls throughout, never a frame-strata change:

- Quick Options and the expanded Mini Soundbook are mutually exclusive -
  opening either closes the other first (`SB.ShowFavMenu`/
  `SB.ShowAnnouncerQuickOptions`).
- Quick Options and the context menu are mutually exclusive the same way
  (`SB.OpenSendMenu` now closes Quick Options first; opening Quick
  Options closes the context menu first).
- The context menu is deliberately exempt from closing the expanded Mini
  Soundbook - it's opened FROM one of its rows and is meant to coexist
  with it (unchanged existing `PinFavAlpha` behaviour).
- `Theme.CreateDropdown` gained `CloseList`/`IsListOpen`/`GetListFrame` -
  its floating list/catcher are separate top-level frames parented to
  `UIParent`, not real children of whatever owns the dropdown, so they
  never auto-hid with their owner before this. Closing Quick Options now
  also closes its own Popout Direction dropdown list, removing that
  invisible hit-frame too.

### 2. Mini Soundbook activation mode

New persisted `ui.announcer.openOnHover` (default `false` for fresh
installs and existing users alike - a plain new field, no migration
needed since the generic defaults-backfill already covers both cases
identically). Exposed as "Open Mini Soundbook on Hover" in both Quick
Options and Settings -> Mini, both editing the exact same field - no
duplicate value, no extra refresh plumbing, since the icon's own hover
handler reads it live on every hover regardless of which surface changed
it.

Hover-open is wired as a native `OnEnter` `HookScript` on the icon -
edge-triggered (fires once per genuine transition from outside the
icon's bounds to inside it, never a poll) and gated by both the setting
and Quick Options' own open state. This turned out to make every
"reopen-loop" edge case in the spec fall out for free, with no extra
suppression-flag state machine needed: nothing re-checks hover state
just because the cursor happens to still be resting on the icon after
some *other* surface closed elsewhere - a fresh `OnEnter` only ever fires
after a real `OnLeave` genuinely preceded it. Left-click keeps working
unchanged regardless of the setting; hovering never opens Quick Options
(unaffected by this setting entirely - still Shift+Right-click only).

### 3. Proximity-based auto-close

One shared, throttled ~0.1s ticker (`C_Timer.NewTicker`), applied to the
expanded Mini Soundbook and Quick Options only (the context menu keeps
its own existing outside-click dismiss, unchanged) - created only while
either is shown, cancelled the instant both are hidden via a single
canonical `NoteMiniSurfaceHidden` hook on both frames' own `OnHide`
(fires correctly no matter which code path actually closed them - a
row's own click-to-play, the outside-click catcher, or proximity
closing it itself - rather than needing every individual close call site
to remember its own "is the other one still open" check).

Combined active area = the icon (always) + favMenu (while shown) +
quickMenu (while shown) + quickMenu's own open Popout Direction dropdown
list (while open), +60px tolerance; closes after ~300ms continuously
outside that area. A shared `proximityActiveInteraction` flag - set by
the icon's own drag (repositioning the trigger) and by both the
Announcer Size and Mini Soundbook Size sliders' mouse-down/up inside
Quick Options - suspends the countdown entirely for as long as the
interaction lasts and restarts it fresh (not from wherever it left off)
the moment the interaction ends, exactly as specified ("restart the
outside-distance timer only after the active interaction ends").

### Verification

All 13 mock regression scripts pass (the 12 from prior rounds plus a new
`loader_minisurfaces.lua`): default setting value; every single-active-
surface combination (Quick Options vs. Mini Soundbook, Quick Options vs.
context menu, context menu legitimately coexisting with the expanded
Mini Soundbook); hover OFF does nothing while left-click still opens it;
hover ON opens without any click and never opens Quick Options; Quick
Options open suppresses hover-open underneath it, and a genuine
subsequent hover entry after it closes still works normally; and the
full proximity mechanics - never closes from inside tolerance or a
single outside sample, an active interaction (simulated via the icon's
own real drag scripts) suspends closing indefinitely and the countdown
restarts fresh once it ends, closes after exactly 3 consecutive ~0.1s
outside samples (~300ms).

### Still gated on a live client

Every change this round is either a root-caused interaction fix (the
mutual-exclusion rule, the dropdown list's own orphaned hit-frame) or a
mechanism verified end-to-end through the addon's own real event/script
handlers in the mock harness, including directly driving the shared
ticker via the harness's own `TickMockTickers`. This environment still
has no live WoW client and no real screen geometry (`GetLeft`/`GetRight`/
`GetTop`/`GetBottom` are fixed mock stubs, not real anchor-resolved
positions - the proximity test drives them and the cursor position
directly rather than through real on-screen layout) - the final "does
hover-open feel instant, does the 60px tolerance genuinely feel natural
moving between the trigger/Mini Soundbook/Quick Options/its dropdown,
does 300ms read as deliberate rather than laggy or twitchy" pass needs
one in-game check, same residual gap every round has disclosed.

---

## Round 13 - Settings layout root cause (3rd pass), Mini Soundbook Size live preview, Output Rail always-selected default

### 1. Settings layout regression - true root cause (3rd report)

The first two passes (Rounds 10-11) fixed the category strip's own
anchor math - correctly, but incompletely. The bug reported a 3rd time
was a **different mechanism neither pass touched**: `SB.BuildSettingsPanel`
built its `panel` frame with `panel:SetAllPoints(contentFrame)` and
`panel:SetClipsChildren(true)`. `SetClipsChildren` clips every
descendant to the *clipping frame's own rectangle*, regardless of how
that descendant is individually anchored - a child's `SetPoint` math can
be completely correct and still render invisible if it sits outside its
clipping ancestor's own bounds. `contentFrame` is the Library's content
region, anchored well below the shared header; `tabRow` (the category
strip) was anchored directly off `mainFrame.header`'s own bottom edge -
correct in isolation, but that placed it *above* `panel`'s clip
boundary, which was still pinned to `contentFrame`. The empty gap
users kept reporting was this clipped region, not a wrong offset number.

Fixed by giving `panel` its own independent anchors instead of
`SetAllPoints(contentFrame)` - LEFT/RIGHT/BOTTOM from `contentFrame` (its
horizontal region and bottom edge are still correct), but TOP from
`mainFrame.header`'s own BOTTOM (with a defensive fallback to
`contentFrame`'s TOP if the header isn't exposed yet) - so panel's own
clip rectangle now starts exactly where the category strip is anchored,
never clipping it away. One authoritative anchor chain: header -> (small
gap, `HEADER_TO_TABS_GAP = 20`, within the required 18-22px range) ->
category nav (fixed, never scrolls) -> (24px gap) -> the scroll frame,
identical for all 5 categories since none of them position their own
content independently - they all render inside the same shared
`scrollChild`. `panel.scroll` exposed alongside the existing
`panel.tabRow` purely for harness reachability.

Verified structurally, not just smoke-tested, for the first time this
round: `mock.lua`'s `SetPoint`/`SetAllPoints`/`ClearAllPoints` used to be
complete no-ops that didn't even record their arguments, so no prior test
could actually check an anchor chain - only whether building the UI
errored. Enhanced (purely additively - nothing could have depended on
the old no-op behaviour since nothing previously read it) to record every
call via a new `f:GetPointByName(point)` accessor. `loader_settings.lua`'s
new section 5 asserts: `panel` has no `ALL` point (`SetAllPoints` is
really gone); `panel`'s TOP is really anchored to `mainFrame.header`, not
`contentFrame`; `tabRow`'s TOP sits exactly 20px below the header; the
scroll frame's TOPLEFT sits exactly 24px below `tabRow`; and the same
holds identically across all 5 Settings categories via
`SB:ShowSettingsSection(key)`.

This resolves the clip-boundary bug precisely - it does not, and cannot,
resolve real pixel geometry: the mock's `GetLeft`/`GetRight`/`GetTop`/
`GetBottom` are still fixed stubs, not real anchor-resolved screen
coordinates, so the exact 70-80px "Playback appears below the divider"
target still needs a live-client visual check, same disclosed limitation
as every prior round's attempt at this same bug.

### 2. Mini Soundbook Size: live preview while dragging

An explicit, narrow exception to Round 12's single-active-transient-
surface rule, scoped only to dragging the Mini Soundbook Size slider
inside Quick Options:

- `SB.ShowFavMenu`'s own build+populate+position+show body was factored
  out into a shared `DisplayFavMenu(anchor, directionOverride)` local -
  `ShowFavMenu` itself still closes Quick Options first as before
  (unchanged, single-active-surface rule intact everywhere else); the
  new preview path calls `DisplayFavMenu` directly, bypassing that
  mutual exclusion for this one case only.
- `StartMiniSizePreview()` (wired to the slider's `OnMouseDown`): if the
  Mini Soundbook isn't already shown, force-opens it via `DisplayFavMenu`
  flanked on the *opposite* side from Quick Options (new
  `OppositeDirection(dir)` helper) so the two surfaces never overlap each
  other while both are visible, and marks that it was the one that forced
  it open. Also engages the existing interaction-priority flag
  (`SetMiniActiveInteraction`), same as every other slider in Quick
  Options, so proximity auto-close can never interrupt the drag.
- The slider's value-change callback now calls
  `SB:RefreshMiniSoundbookScale()` on every change, not only on
  `OnMouseUp` - the Mini Soundbook's actual on-screen size now updates
  continuously while dragging, from 50% to 200%, the same persisted
  `SB.db.ui.announcer.favScale` setting the slider always wrote to (no
  separate preview-only value introduced).
- `EndMiniSizePreview()` (wired to `OnMouseUp`): releases the interaction
  flag, and closes the Mini Soundbook again via the existing
  `SB.CloseFavMenu()` - but only if this preview was the one that forced
  it open. If it was already legitimately open beforehand (not reachable
  through the current UI today, since opening Quick Options always closes
  it first - kept as a defensive guard matching the exact requirement
  wording regardless), release leaves it exactly as it was.
- The separate Announcer Size slider and its own preview-independence
  guarantees (section 3, prior rounds) are untouched - opening Quick
  Options alone still previews neither Announcer nor Mini Soundbook Size.

Verified in a new section 5 of `loader_minisurfaces.lua`: drag-start
force-opens the Mini Soundbook while Quick Options stays open and usable;
dragging to 160% then 90% updates `favMenu:GetScale()` live at each step
(not deferred to release); release closes the forced-open Mini Soundbook
again while Quick Options remains open and the final value (0.9) persists
through the existing `favScale` setting; and a Mini Soundbook already
shown before a drag starts survives release untouched (the defensive
branch above). `loader_popout.lua`'s pre-existing assertions that opening
Quick Options alone, and changing Mini Soundbook Size, never touch the
separate Announcer Preview banner state still pass unchanged.

### 3. Output Rail: always-selected default ("All" on fresh install)

Before this round, `Database.lua`'s `SanitizeDatabase` left a genuinely
fresh install (no old single-bucket data to migrate) with `selfOnly =
false` and every bucket's `selected` list empty - a real, reachable
"nothing at all selected" state, not the required "All" default.

Fixed with a one-time flag rather than populating real recipient names
at Sanitize time - guild/group/friends rosters are frequently still
empty this early at login (the same reasoning the existing migration
comment already gives for not guessing membership during migration).
`SanitizeDatabase` now sets `ui.outputRail.needsDefaultAll = true`, but
only when there was no old single-bucket data to migrate from at all
(`oldMode == nil`) - an upgrading player's real, possibly-deliberate
existing choice (including a legitimate SELF/local-only start) is never
touched. `UI.lua`'s existing roster-ready event handler (already listens
for `GROUP_ROSTER_UPDATE`/`PLAYER_ENTERING_WORLD`/`GUILD_ROSTER_UPDATE`/
`FRIENDLIST_UPDATE`/`IGNORELIST_UPDATE`) now consumes this flag exactly
once, on whichever of those fires first after login, by calling the
*same* `SB.SelectAllBroadcastTargets()` a real "All" click performs -
never a separate ad-hoc selection path. Once consumed the flag is
cleared and never re-applied, so a player who deliberately changes their
pick afterward (including to Self Only) is never overridden again.

This does not change how selection already persists across `/reload` or
a full game restart - that was already ordinary SavedVariables
persistence, unaffected by this bug; the only real gap was the fresh-
install starting state.

Verified in two new sections of `loader_outputselector.lua`: a fresh
`SB:PrepareDatabase({})` is flagged; a new
`SB.__EmitRosterEvent()` (test/harness-only, since the mock WoW API's
`RegisterEvent` is a no-op and never dispatches a real event) drives the
production handler directly and confirms the flag is consumed exactly
once, `SB.IsAllBroadcastFullySelected()` reads true afterward, and a
later deliberate Self Only pick survives a subsequent roster event
untouched; a simulated *upgrading* player with an already-migrated,
empty Output Rail is confirmed to never receive the flag at all.

### Verification

All 13 mock regression scripts still pass, now with real structural
anchor-chain assertions for the Settings layout fix, a new live-preview
section in `loader_minisurfaces.lua`, and two new sections in
`loader_outputselector.lua` for the default-selection fix - no existing
assertion needed to change.

### Still gated on a live client

The Settings layout fix resolves the actual clipping bug, not real pixel
geometry - the mock harness still has no real anchor-chain math or
screen coordinates, so the specific "~70-80px below the divider" visual
target needs a live-client check, same disclosed limitation as prior
rounds. The Output Rail default-All fix is deliberately deferred to the
first roster-ready event after login rather than applied at Sanitize
time, since guild/friends/group rosters are frequently still empty at
that exact moment - if none of the five roster events happens to fire
before the player looks at the Output Rail for the very first time
after a truly fresh install, the tabs will briefly show "All" selected
with zero actual recipients until one does (the same "explicitly
selected, zero eligible" state already accepted elsewhere in this
addon for a legitimately empty guild) - worth a live-client sanity check
on a genuinely brand-new character/account, not just the existing SavedVariables-reset simulation this environment can run.

---

## Round 14 - Mini Soundbook proximity/overlap tuning, live Announcer Size, and a full playback/progress lifecycle rewrite

### 1. Mini Soundbook proximity auto-close - user report: closed almost instantly

Reported: opening the Mini Soundbook (a real click, cursor on the icon)
was followed by it closing again within a fraction of a second - no real
time to react, even with the cursor still near the icon.

Root cause was tuning, not logic - 60px tolerance and a 0.3s close delay
are small enough that a real player's UI scale and normal mouse drift
easily exceed them well before 300ms passes, especially moving from the
icon toward content inside the just-opened surface. Fixed with:

- Tolerance widened 60px -> 150px, close delay 0.3s -> 0.6s.
- New ~0.6s **opening grace period**: for a short window right after
  ANY of the tracked surfaces opens (a real click, hover-open, or the
  new size-preview forced-open below), outside-time can never
  accumulate at all, regardless of where the cursor already is at that
  exact instant - guarantees a minimum reaction window on every single
  open, not just a looser ongoing tolerance. Restarts on every fresh
  open, even if the shared ticker is already running for another
  surface (e.g. a size-preview opening while Quick Options is already
  up).

Verified in `loader_minisurfaces.lua`'s rewritten proximity section: the
cursor is placed far away BEFORE the Mini Soundbook even opens, and it
must still not close for the first several ticks purely from the
opening grace; the rest of the mechanics (inside-tolerance never closes,
a single outside sample never closes, interaction priority suspends
indefinitely and restarts fresh once it ends, closes after exactly 6
consecutive ~0.1s outside samples = 0.6s) all still hold at the new
timing.

### 2. Mini Soundbook Size preview overlapping Quick Options

Reported: the live-preview added last round (dragging the slider forces
the Mini Soundbook open so you can see the size) still visually
overlapped Quick Options.

Root cause: the preview positioned itself on the direction *opposite*
the icon's own resolved Popout Direction - correct on paper, but near a
screen edge `SetClampedToScreen` pulls an off-screen placement back
on-screen, landing right back on top of Quick Options (which sits
immediately next to the icon on the other side). Fixed by anchoring the
preview off **Quick Options' own actual resolved rectangle** instead,
continuing in the *same* direction Quick Options already opened toward
(the side `ResolvePopoutDirection` picked specifically because it has
room) - this can only ever be pushed further into open screen space,
never back toward Quick Options. `DisplayFavMenu` gained an optional
`positionAnchor` parameter for this (the anchor used for the one-time
`SetPoint` call only - `favMenu.__anchor`, used by
`SB:RefreshPopoutPositions` for everything else, stays the icon as
before). Verified structurally in `loader_minisurfaces.lua` via
`GetPointByName` - the preview's anchor `relTo` is asserted to be
`quickMenu` itself, not an independently-computed guess.

### 3. Announcer Size: added the same live preview

Explicit new request - Announcer Size (the icon/banner's own scale) had
no live preview at all before this round (a deliberate decision from an
earlier round, when it was still tied to the Announcer Preview banner -
no longer applicable now that it's a plain live rescale). The slider's
value-change callback now also calls `SB:RefreshAnnouncerScale()` on
every change, not only on release. No forced-open/positioning step is
needed the way Mini Soundbook Size needs one - the icon (and banner,
when shown) are always already on-screen and already independently
anchored off the icon's own *live* edges, so growing/shrinking it in
place can never newly overlap Quick Options (WoW re-resolves every
`SetPoint` relationship every frame - Quick Options' own anchor to the
icon's edge tracks the growth automatically). Verified in
`loader_popout.lua`: the icon's scale reflects the slider's value
immediately, with no mouse-up needed.

### 4. Playback/progress lifecycle: root-cause rewrite

The reported bugs - `Brother eeew` (and sometimes `Emotional Damage`)
showing no progress bar at all, `Haha Ostrich`/`Epic Saxx` leaving the
Announcer visible 6+ seconds after playback actually ended - turned out
to be two genuinely different root causes, both fixed structurally
rather than patched per-sound.

**4a. Duration coverage gap.** `Brother eeew`, `Daddy Chill`,
`Excuse me bruh`, `aaahhhhhh!`, and `what did he sayyyyy` - five real,
currently-shipped Legacy sounds - had no entry in `SoundDurations.lua`
at all, silently falling back to live-learning (which a bundled sound
should never need). `tools/audit_sound_durations.py` (previously only
checked registered entries against their files) now ALSO cross-checks
every bundled `Sounds.lua` entry (Legacy/German Memes - the only
categories that ship with real content) against `SoundDurations.lua`
and prints a ready-to-paste entry (same MPEG frame-walk measurement) for
anything missing. All 5 measured and added; a pre-existing case-only
mismatch (`Was Zitterstn so` vs. the real `Was zitterstn so.mp3`) was
also caught and corrected (harmless at runtime - `SoundRegistry.lua`'s
own lookup already has a case-insensitive fallback - but now the tool
reports zero coverage gaps and zero missing-file entries).

**4b. Progress UI depended on a WoW sound handle that doesn't always
exist.** `SoundPlayer.lua` only ever tracked a play (`TrackNewPlayback`)
`if handle then ... end` - `PlaySoundFile` can legitimately return
`willPlay=true` with a `nil` handle (already documented at the top of
this file re: per-sound volume/`supportsHandles`), and for that one
play, nothing was tracked at all: no `PLAYBACK_PROGRESS_STARTED`, no
duration ever reaching the Announcer, permanently stuck showing
"Playing" with no bar. This is the actual explanation for "sometimes"
`Emotional Damage` (which has a perfectly good known duration) - not a
data gap like `Brother eeew`, a runtime coin-flip on whether that one
`PlaySoundFile` call happened to hand back a handle.

**4c. `C_Sound.IsPlaying` had no ceiling.** The Announcer's own banner
had a *separate*, purely cosmetic progress-fill ticker (its own
`elapsed`/`duration` math) that never terminated anything by itself -
actually ending a display was 100% dependent on `SoundPlayer.lua`
observing a handle's `C_Sound.IsPlaying` transition from true to false.
Some clients/files (the exact reported case) report `IsPlaying=true`
for several seconds past the real audible end, and nothing capped that.

**The rewrite** (`SoundPlayer.lua`, `Announcer.lua`):

- Tracking keyed by a new local, always-available **playback-instance
  token** (`nextInstanceID`, monotonically incrementing) - never by
  handle (optional, can be `nil`) and never by `soundID` alone (the
  same sound can be retriggered/overlapped). `TrackNewPlayback` is now
  called unconditionally after every successful `PlaySoundFile`,
  handle or not.
- `PollTrackedInstances` (renamed from `PollTrackedHandles`) now checks
  a **known-duration ceiling** (`duration + 0.3s grace` - the exact
  margin this addon's own pre-3.0 Mini Soundbook used for precisely
  this "don't cut off right at the last instant" purpose, ported
  forward as a real reactive ceiling instead of a fixed timer) *before*
  anything else, every tick, for every instance - handle or not. Once
  elapsed passes that ceiling, the instance ends right there regardless
  of what `C_Sound.IsPlaying` still claims. This is also the *only* end
  signal at all for a handle-less instance - progress display and a
  guaranteed end no longer need a handle for anything.
- A handle-less instance with no known duration either (a companion
  sound's first play) still eventually fires a real END (not a silent
  drop) after a reasonable window, so nothing is ever left stuck
  showing "Playing" forever with no way to know better - the "never
  started" ambiguity that justifies a silent drop only applies when
  there was a handle to doubt in the first place.
- Real early-natural-end detection (via `C_Sound.IsPlaying`, when a
  handle exists) is unchanged and still takes priority *before* the
  ceiling is reached - "only ever trusted once observed playing at
  least once" (explicit requirement - avoids a startup race
  prematurely ending a long sound), so a sound that genuinely finishes
  early still ends early.
- `StopAllOwnSounds` (Stop button, `/sb stop`, and an overlap-disabled
  replacement cutting off the previous sound) now force-ends **every**
  currently-tracked instance synchronously, immediately, marking the
  fired state `stopped = true` - not waiting for the next 0.08s poll
  tick to notice, and distinguishable from a natural/ceiling end.
- **Announcer.lua**: `activeDisplays` entries are now matched by
  `instanceID`, never `handle` (two different handle-less instances
  used to be indistinguishable from each other by that field - a real
  contamination risk once handle-less tracking became possible). The
  existing "Now Playing Highlight Duration" setting (renamed "Now
  Playing Minimum Duration", Settings.lua) is now ALSO wired into the
  Announcer's own lifecycle as a genuine minimum: a natural/ceiling end
  arriving before the configured minimum defers the entry's actual
  removal (via a scoped `C_Timer.After`) to exactly when the minimum is
  reached, rather than vanishing early - but `state.stopped` (explicit
  Stop/overlap-cutoff) always bypasses this and clears immediately, per
  requirement. Matches this addon's own pre-3.0 precedent
  (`FavouritesWindow.lua`'s old `ShowNowPlaying`: minimum, extended up
  to the real duration + grace whenever that's longer) - reimplemented
  reactively on the new instance-token architecture instead of a fixed
  timer computed once.
- Promotion (an older, still-genuinely-playing overlapped sound
  becoming primary once a newer one ends) needed no new mechanism at
  all in the current 3.0 Announcer - `activeDisplays` already promotes
  implicitly by array position, and since the ceiling check applies
  uniformly regardless of primary/secondary status, a stale/expired
  secondary is removed via its own ceiling exactly like a primary would
  be - it can never resurface later just because a stale handle might
  still say something about it.

**Preserved, verified unchanged**: the Library grid's own "just played"
highlight (UI.lua's `SetPlayingState`) still reads `state.handle`
exactly as before (kept in the fired state alongside the new
`instanceID`, for zero-touch backward compatibility) -
`loader_playback.lua`'s full existing suite (instance-scoped cleanup,
stale-handle isolation, retrigger, overlap on/off) passes unchanged.
Local/remote playback, sending, ACKs, routing, analytics, history, and
Last Sound are all untouched - none of those files were modified.

### Verification

15 mock regression scripts now pass (the prior 13, `loader_popout.lua`
extended with a live-icon-scale assertion, `loader_minisurfaces.lua`
rewritten for the new proximity timing plus a new anchor-`relTo`
assertion, and a new dedicated `loader_playbacklifecycle.lua`): handle-
independent progress and its own duration-ceiling end; a known duration
overriding a stuck `IsPlaying=true`; the minimum genuinely holding a
real early end open, then clearing exactly at the minimum; an explicit
Stop bypassing the minimum immediately; an overlap-disabled replacement
clearing the cut-off sound's display immediately too; retrigger
isolation (a stale older instance's own end never affects a newer
retrigger); and secondary/overlap handling (an expired secondary is
dropped entirely, never re-promoted). `mock.lua` gained two small,
purely additive capabilities to make this possible at all: a mutable
simulated clock (`AdvanceMockTime`, `GetTime`/`GetTimePreciseSec`
previously a hardcoded constant - no prior test could ever prove
anything about elapsed real time) and a one-shot nil-handle injector for
`PlaySoundFile` (`SetMockForceNilHandleOnce`).

`tools/audit_sound_durations.py` was run directly (not through the mock
harness) and confirms zero coverage gaps, zero missing files, and zero
duration mismatches across all 85 registered/bundled sounds after this
round's fixes.

### Still gated on a live client

The lingering-announcer fix is verified via the mock's new simulated
clock, which correctly proves the addon's own decision logic (the
ceiling fires at the right elapsed time, in the right priority order),
but cannot reproduce the real client quirk itself (does `C_Sound.
IsPlaying` on TBC Anniversary genuinely report stale `true` for
`Haha Ostrich`/`Epic Saxx` specifically, and by how much) - worth
watching those two sounds specifically in-game to confirm the Announcer
now clears within ~0.3s of the real audio ending rather than the
previously-reported 6+. The 0.3s grace margin itself is a carried-
forward value from this addon's own pre-3.0 precedent, not re-derived
against real playback latency in this environment.

---

## Round 15 - Mini Soundbook proximity: scale-coordinate-space bug at 3-column size

### Report

Round 14's proximity tuning (wider tolerance, longer delay, opening
grace) did not fix the underlying bug: at Mini Soundbook Size 120%+
(the 3-column layout threshold), the Mini Soundbook still closed
instantly - even with the cursor hovering directly over it.

### Root cause

`Frame:GetLeft()/GetRight()/GetTop()/GetBottom()` return coordinates in
the frame's OWN local unit space (1 unit = that frame's own effective-
scale pixels), not pre-normalized to UIParent's scale. `icon` and
`favMenu` both carry independent `SetScale` values (Announcer Size /
Mini Soundbook Size) - the proximity system's `AddMiniBounds` read their
raw Get* values directly and compared them against the cursor position
(which IS correctly normalized to UIParent's scale), silently skewing
by exactly the scale ratio. Below ~1.15x the skew stayed inside even the
old 60px tolerance, masking it entirely; the 3-column threshold (1.15x+)
compounds a real scale AND a wider raw frame together, reliably
exceeding even Round 14's widened 150px tolerance. This is the exact
same class of bug already fixed once for `SB.ResolvePopoutDirection`'s
own `GetCenter()` call (see that function's own comment) - just never
applied to the proximity bounds code, which was written later.

### Fix

`AddMiniBounds` now multiplies each frame's raw bounds by
`frame:GetEffectiveScale() / UIParent:GetEffectiveScale()` before
merging them into the combined tolerance region - the same
scale-normalization technique already proven correct elsewhere in this
file. Applies uniformly to every frame the proximity system already
considers (icon, favMenu, quickMenu, the Popout Direction dropdown
list), so this also covers Announcer Size at any value, not just Mini
Soundbook Size.

### A second bug, in the test harness itself

Verifying this required a REAL scaled mock frame (not the synthetic
`FakeAnchor` tables `loader_popout.lua` already used specifically to
route around this exact gap). Doing so surfaced a second, independent
bug - this time in `mock.lua`: `GetEffectiveScale()` was defined TWICE
on the same frame table, and the second definition (`return 1`,
unconditionally) silently shadowed the first (`return f._scale or 1`) -
meaning `GetEffectiveScale()` on a real mock frame had never once
actually reflected `SetScale()`, for any test, ever. Fixed by removing
the stale duplicate. Confirmed harmless everywhere else: every other
`GetEffectiveScale()` call site in the addon (`UIParent`, `Minimap`,
scroll frames, `main`) queries a frame that never has `SetScale` called
on it, so their behavior is unchanged.

### Verification

A new regression test (`loader_minisurfaces.lua`, section 4b) sets Mini
Soundbook Size to 150% (3-column), places the cursor at the frame's REAL
on-screen edge (its own raw `GetRight()` times its own current scale),
and asserts it stays open well past both the opening grace and close
delay. Confirmed this genuinely reproduces the reported bug: reverted
against the pre-fix `Announcer.lua`, the same test fails exactly as
described (closes despite the cursor sitting on the real edge); with
the fix, it holds. All 14 mock regression scripts pass.

### Still gated on a live client

The mock's `GetLeft/Right/Top/Bottom` remain fixed stubs, not real
anchor-resolved geometry - this fix is proven correct in the coordinate
-space math (scale-correction applied, verified against a reproduced
failure), but the "does 150px feel right at 200% Mini Soundbook Size on
a real screen" question still needs an in-game check, same disclosed
limitation as every round's proximity work.

## Round 16: Settings two-pane redesign + header gear + Send-to selector

Two coordinated redesigns, implemented from a detailed design
specification rather than a bug report.

### Settings: 5-tab strip -> two-pane (vertical nav + scrolling content)

The old horizontal 5-tab strip (`BuildTabStrip`) is replaced by a
fixed-width (~128px) vertical left-hand nav (`BuildSectionNav`,
`CreateNavRow`) with a restrained active-state (a thin left accent bar +
soft tinted background, no heavy card/glow) and a normal hover state -
distinct from `Theme.CreateTabButton`'s underline-tab treatment, which
doesn't read well stacked vertically. Only the right-hand content pane
scrolls; `FitSettingsPanelHeight`'s scroll-width computation was
rederived from the new anchor geometry (nav's own left inset + `NAV_W`
+ `NAV_CONTENT_GAP` + the scroll region's own right inset), since the
old `panelW - 18` shortcut assumed a full-width single-column scroll
region that no longer exists. `CONTENT_W` (each section's own fixed
content-frame width) dropped from 480 to 340 to fit the narrower content
pane at the Main window's minimum resizable size (560px) - the exact
figure is derived arithmetically in `Settings.lua`'s own comment, not
guessed.

Five sections became seven - **General** (minimap button - the one
genuinely miscellaneous setting), **Playback** (output channel, overlap,
combat/encounter gates - local click behavior only), **Multiplayer**
(the Send/Receive channel matrix, Notifications, AND the remote repeat
cooldown/queueing controls, moved in from the old "Advanced Playback"
sub-group since both are about received sounds, not local playback),
**Favourites** (Mini Soundbook window/activation controls only),
**Appearance** (every Mini Soundbook size/opacity/font control, plus the
Main Soundbook's own font/scale, moved in from the old Library &
Appearance section - all pure look-and-feel now lives together),
**Categories** (library sort order + the per-category icon/name rows),
and **Advanced** (Diagnostics/Actions, Window Layout reset - moved in
from Library & Appearance - and a new "Open Sound History" button, the
one genuinely new element this round, wired to the same
`SB:ShowHistoryWindow()` Announcer.lua's Quick Options already calls).
Every relocated control keeps its exact existing SavedVariables key and
onClick/onChange behavior - this is a presentation/navigation move, not
a functional rewrite, and needs no SavedVariables migration.

### Main window: Output Rail -> "Send to:" dropdown + header gear

The right-side broadcast tabs/flyouts system (Guild/Raid/Friends
multi-select, All/Self Only, ~350 lines of `UI.lua`: `BuildBroadcastTabs`,
`HandleBroadcastTabClick`, `BuildBroadcastFlyout`, `SB.SetBroadcast*`,
`SB.SelectAllBroadcastTargets`, `SB.SelectSelfOnly`, `SB.
IsAllBroadcastFullySelected`, and the flyout catcher/click-routing
machinery around them) is removed entirely. In its place: a single-select
"Send to: X" dropdown in a new top control row directly below the
header, alongside Search (Default Output ~190px on the left, Search
filling the remainder on the right, same row/height). Built on
`Theme.CreateDropdown` + the SAME canonical `SB.ComputeOutputTargetOptions`/
`SB.OutputTargetRowFont` machinery `EditWindow.lua`'s own Default
Output/Macro Output dropdowns and `SendMenu.lua` already use - no
separately-built player/group list, so Guild/Raid-Party/Friends groups
always show (even empty/unreachable), reach counts stay live via the
existing `optionsProvider` re-query on every open, nested players keep
their realm-aware dedup, and channel colors/Debug Mode version-suffix
coloring are unchanged. The closed chip relabels only the "All"/"Self"
display text ("Send to: All" / "Send to: Self Only" instead of the
dropdown's own longer row text) via a `SetRowFont` wrapper that checks
`text == dd.label` before rewriting - list rows are untouched.

Settings itself moved from an external "Settings" text tab to a
24x24 gear icon button at the header's top-left (`Theme.
CreateSettingsGlyph`, WoW's built-in Trade_Engineering texture 134936,
desaturated + gold-tinted - no gear quadrant exists in the addon's own
`ControlIcons.tga` atlas, a binary asset this round couldn't extend).
The gear stays visible in every view (Library/Settings/Admin/Keybind
Mode) with an active-state tint while Settings is open; `<
Soundbook` now sits to the gear's right instead of the header's absolute
left edge, so the two coexist without overlapping or pulling the
centred title off-axis (`Theme.CreateHeader` anchors the title to the
header's own BOTTOM point, independent of either corner overlay). The
Admin utility tab dock lost its Settings row and collapses to nothing
(not just an empty box) when Admin is unavailable.

### Default Output routing: restored as the real global default

`SB:ResolveOutputTarget` (`Communication.lua`) previously treated
`SB.db.settings.defaultOutputTarget` as dead except as the per-sound-
override "no override" sentinel - the actual global default came from
the Output Rail's own multi-select data via `SB.ComputeEffectiveRecipients`
/`"SUBSET"`. This round reverts that: `defaultOutputTarget` is the real,
single-select global default again, with "All" meaning exactly what
`SB:BroadcastSound` (the original whole-channel broadcast, driven by
Settings -> Multiplayer's own Send-matrix checkboxes) already did - this
mapping was confirmed, not guessed, from `BuildChannelMatrix`'s own
pre-existing subHint text ("Send defines which channels are included
when the Main window's Default Output is set to All") and a pre-existing
code comment describing the same relationship. Routing priority is
unchanged: explicit override > per-sound override > global default >
"ALL" fallback. `Core.lua`'s fresh-install block was updated from
`defaultOutputTarget = "SELF"` to `"ALL"` to match the earlier, more
recent requirement that a fresh install always lands on All - the old
"SELF" value would otherwise have silently resurfaced now that this
field is live again. `SB.db.ui.outputRail`'s data model, sanitization,
and every manipulation function are left fully intact - no
SavedVariables migration needed, they simply have no surviving UI.

### Testing

Two mock regression scripts tested the removed Output Rail UI surface
directly (`loader_broadcast.lua`, `loader_outputselector.lua`) and were
retired - their entire subject no longer exists. `loader_settings.lua`
and `loader_minititle.lua` were rewritten against the new architecture:
header gear open/close and active state, all 7 nav sections switch
cleanly with no blank/near-zero-height collapse, exactly one nav row
reports active at a time, the Default Output dropdown's initial value/
closed-chip text, fresh-install `defaultOutputTarget == "ALL"`, and the
Mini Soundbook title's live reach computation across Self/single-bucket/
direct-player/All/zero-eligible/cross-channel-dedup/live-roster-event/
live-Send-toggle cases (via the new `SB.RefreshDefaultOutputDisplay`).
All 12 mock regression scripts pass; every changed file parses clean
under `luac -p`.

### Still gated on a live client

Every layout claim in this round (nav width/row height, the top row's
Default Output + Search proportions, gear button placement and title
centering, Settings' two-pane spacing at min/max window size) is
structurally correct (verified anchor targets, no clipping in the
mock's frame-tree walk) but **not** pixel-verified - the mock has no
real layout engine. Needs an in-game check against the task's own
10-point verify checklist, especially: visual balance of the new top
row at both 560px and 720px Main window width, the gear icon's actual
legibility/contrast at 24x24, and the nav's restrained active-state
actually reading as "selected" rather than just "slightly different."

## Note: development continued past Round 16

Round 16 above is the last dated round entry in this file, but it is not the final state of the product - further work happened afterward without a corresponding dated round being logged here. None of the bullets above were rewritten to account for it (per this report's own historical-record policy); this note only points at what changed, for anyone reading Round 16 as if it were current:

- Settings' section count changed from the seven Round 16 shipped with to **six** - the standalone Favourites section was folded into General.
- The Settings gear icon no longer uses WoW's built-in Trade_Engineering texture Round 16 describes; it - and the header's audio and close icons - were replaced with custom artwork (`Assets/SettingsGear.tga`, `AudioIcon.tga`, `CloseIcon.tga`).
- A four-phase dead-code cleanup (re-verified against HEAD at each step, not blindly copied from any single audit) removed: `FavouritesWindow.lua` and `Assets/ButtonFrame.tga` entirely; the `SUBSET` per-player output target and `SB.ComputeEffectiveRecipients` (the Output Rail's old routing mechanism, already non-functional since Round 16 removed its UI); the legacy top-level `ui.favScale` SavedVariables field (distinct from the live `ui.announcer.favScale` "Mini Soundbook Size" setting, which is unaffected); `SB.DefaultOutputChannelColor`; the unused `pinFavWindow` parameter of `SB.OpenSendMenu`; `Theme.MiniArcanePanel`; and `SB:PinFavAlpha`/`SB:UnpinFavAlpha`, consolidated into the existing `SB:RefreshAnnouncerAlpha`. `SB.IsSendMenuOpen` was evaluated for removal and kept - the mock regression suite uses it as its only way to check the send/context menu's open state.
- Database schema advanced from v27 (current at Round 16) to **v28**.

See `README.md`, `CHANGELOG.md` ("Later within 3.0.0"), and `MIGRATION.md` for the current-state description; no further dated rounds are recorded in this file as of this note.

## Soundbook 3.0.1: WoW-client compatibility hardening audit

A dedicated compatibility pass, on `dev/3.0.1`, targeting all five interfaces already declared in `Soundbook.toc` (Classic Era/Hardcore/SoD `11509`, WoW Forever `16001`, TBC Anniversary `20506`, Mists of Pandaria Classic `50504`, Retail `120100`). This is hardening, not a redesign - no feature, UI, SavedVariables format, DB version, `SB.COMM_PREFIX`, `SB.PROTOCOL_VERSION`, wire payload format, or sound ID changed. TBC Anniversary is the only client confirmed by live play; it was the regression baseline this pass was checked against throughout.

### APIs audited

Every `.lua` file listed in `Soundbook.toc` was checked for API calls that differ across the five target clients, with particular attention to the namespaces Blizzard has been migrating globals into (`C_AddOns`, `C_ChatInfo`, `C_FriendList`, `C_Sound`), plus timers, group/raid/guild/friend/Ignore APIs, addon metadata, sound playback/handles, keybindings, combat lockdown, frame templates/`BackdropTemplate`, and realm/name handling. Most of the addon already carried a "modern API first, capability-detected legacy fallback second" pattern (`SB.GetNumFriends`, `SB.GetFriendInfoByIndex`, `SB.SendAddonMessage`, `SB.GetUnitFullName`, `SB.RegisterAddonPrefix`, `SB.CreateFrame`'s `BackdropTemplate` mixin) and needed no change. `C_Timer`, `PlaySoundFile`, `SetOverrideBindingClick`/`ClearOverrideBindings`, `InCombatLockdown`, and the guild-roster globals (`GetNumGuildMembers`/`GetGuildRosterInfo`, already existence-guarded at every call site) were reviewed and found to already degrade safely; no verified modern replacement exists for the guild-roster globals as of this audit, so they were left as-is rather than guessing at an unverified `C_GuildInfo` signature.

### Compatibility wrappers added/fixed

- **Ignore list** (`Core.lua`): `SB:IsIgnored` relied solely on the legacy `GetNumIgnores`/`GetIgnoreName` globals. Added `SB.GetNumIgnores()`/`SB.GetIgnoreName(index)`, preferring `C_FriendList.GetNumIgnores`/`C_FriendList.GetIgnoreName` and falling back to the legacy globals - the exact pattern the Friends-list wrappers already used. `SB.PlayerKey`, realm-aware identity, Ignore ACK behavior, and the higher-level "have I ignored them" semantics are unchanged.

### Transport changes

`Transport.lua`'s `SendNow()` used to treat "the API call didn't raise a Lua error" as "the message was sent" - `C_ChatInfo.SendAddonMessage` can return a non-Success `Enum.SendAddonMessageResult` (throttle/rejection) without erroring at all, and that result was never inspected by any caller. Fixed: a new `ClassifySendResult` distinguishes success (`Enum.SendAddonMessageResult.Success`, or a `nil` result on clients/legacy APIs with no result signal at all) from a genuine failure, which is now retried up to a bounded `MAX_SEND_ATTEMPTS` (3) rather than silently discarded or retried forever; an entry that fails on its very first, no-queue-yet attempt now falls through into the normal bounded priority queue instead of being lost. The queue itself, its priority order (admin/ACK > PLAY > presence > analytics), duplicate-collapsing, and max-age expiry are unchanged. Also lowered `TOKEN_CAPACITY` (24 → 10) and `TOKEN_REFILL_PER_SECOND` (12 → 1), which were tuned far more aggressively than Blizzard's own per-prefix throttle tolerates in practice - reliability over raw throughput, per this round's own goal.

### Raid enumeration change

Five `GetRaidRosterInfo(i)` scans (`Communication.lua` x4, `AdminPanel.lua` x1) iterated `1..SB.GetNumGroupMembers()`, assuming raid indices are always a compact run - not guaranteed (a member can sit at an index past the current member count after roster churn). All five now iterate `1..SB.MAX_RAID_MEMBERS` (a new `Core.lua` constant: the `MAX_RAID_MEMBERS` global when present, else the standard fallback of 40), with the existing nil-guards unchanged. Party-branch loops (`party1..N` unit IDs, always contiguous) were deliberately left untouched. Recipient calculation, online checks, admin authority checks, leader/assistant handling, realm-aware identity, Raid Admin mute logic, and ACK logic are all otherwise unchanged - only the enumeration range.

### Tests performed

Static: `luac -p` across all 29 `Soundbook.toc`-listed files (clean); confirmed every listed file exists on disk. Regression: the full existing mock suite (13 scripts) still passes unchanged. A new `loader_compat.lua` (14th script) adds focused coverage for this round specifically: (1) Ignore-list lookups across a modern-only, legacy-only, mixed (modern must win), and neither-API-present environment - the last of these confirms `SB:IsIgnored` degrades to `false` without ever raising a Lua error; (2) a simulated permanent addon-message throttle - confirms a throttled send is never counted as sent, is retried a bounded number of times (exactly `MAX_SEND_ATTEMPTS`, verified by call count), is eventually dropped rather than queued forever, and that the transport recovers cleanly once the throttle clears; (3) a raid roster with a real member deliberately placed at index 25 while `GetNumGroupMembers()` reports 3 - confirmed reachable end-to-end through the public `SB.ComputeReachablePlayers()` path, not just via the raw loop bound.

### Remaining limitation

No physical Classic Era, WoW Forever, Mists of Pandaria Classic, or Retail client was available to this session - those four are technically/static validated only (audited against each client's documented API surface and this addon's own compatibility layer), not live-tested. TBC Anniversary remains the sole live-tested baseline. See `README.md`'s compatibility table for the per-client status this round leaves in place.

## Soundbook 3.0.2: per-player recipient subset for Guild/Raid/Friends

Restores per-player recipient selection for the Main window's "Send to:" channel (a similar feature existed briefly during 3.0's own Output Rail redesign before that whole rail was replaced by the current single-select dropdown - see `git log --oneline` for `306601f`/`cb4a651`/`5aa7f8b`). Reuses the existing `SB.ComputeReachablePlayers()` discovery and the existing transport (`SB.SendAddonMessage`) rather than building either in parallel; the old Output Rail's own `SB.db.ui.outputRail` SavedVariables shape is left completely untouched (still dead, still compatibility-only).

**Data model**: session/UI state only, never SavedVariables (explicit requirement) - a new module-local `channelSubset` table in `Communication.lua`, exposed via `SB.ActivateChannelSubset`/`ToggleChannelMember`/`ToggleAllChannelMembers`/`ResetChannelSubsetsExcept`/`ComputeChannelSubsetRecipients`/`GetChannelMemberRows`/`GetChannelSubsetCount`/`IsChannelSubsetActive`. A bucket (`GUILD`/`RAID`/`FRIENDS`) is `nil` until first activated (whole-channel behaviour, identical to before this round); once activated it's a concrete snapshot of reachable names that a later roster change can never silently grow, only narrow further by explicit toggle.

**UI** (`UI.lua`): a small "selected/available" chip next to the existing "Send to:" dropdown, shown only while the active channel is Guild/Raid/Friends, opening a checkbox flyout (reusing `Theme.CreateCheckbox`/`Theme.CreateScrollFrame`, the same click-outside-to-close catcher/`TOOLTIP`-strata pattern `Theme.CreateDropdown`'s own list already uses) below the Send-to control. Re-picking the already-active channel from the dropdown, or clicking the flyout's own header, both toggle everyone on the list off/on. Switching to a different channel clears the previous one's subset (`SB.ResetChannelSubsetsExcept`). Refreshes off the same `OUTPUT_SELECTION_CHANGED` event the roster-change listener already fires - no second polling/refresh path.

**Wire protocol** (`Communication.lua`): a Guild/Raid channel message can't be addressed to specific people at the WoW chat-channel level, so a narrowed subset instead sends individual whispers carrying a new `"SG"`/`"SR"` flag (`ParsePlayPayload` recognizes them alongside the existing `"D"` Direct flag; an unrecognized flag from an older client is still silently ignored, unchanged). `OnAddonMessage` remaps a whisper carrying either flag onto the logical `"GUILD"`/`"RAID"` channel immediately after parsing, before any of the existing receive-gating/priority/ACK-code/chat-label logic runs - every one of those ~12 call sites needed zero changes, since a remapped subset whisper now takes exactly the same code path a genuine channel-wide broadcast already did. Friends needed no wire change at all: a Friends broadcast was already individual per-friend whispers with no flag, so a subset there is just fewer names, same message shape. Per-sound "Default Output" overrides and macro `::Target` sends are explicitly excluded from subset filtering (checked via the same priority logic `SB:ResolveOutputTarget` already uses) - they keep reaching the whole channel exactly as before.

**Tests**: a new `loader_subsetselection.lua` (15th script) covers the task's four Verify scenarios end-to-end: (1) default-all-selected on first activation, toggle-all off/on (list stays visible with nobody selected), narrowing to 2 of 4 and confirming a dispatched send reaches exactly those 2, as individual `SG`-flagged whispers; (2) switching the active channel discards the previous one's subset, and reactivating it later starts fresh rather than resurrecting the old narrowing; (3) receive-side logical-channel preservation - a Guild-subset whisper is gated by `receiveGuild` (not `receiveFriends`/`receiveDirect`, both deliberately left on to prove it), ACKs with the Guild code (`"G"`), and a Raid-subset whisper behaves the same way gated by `receiveRaid` with ACK code `"R"`; a genuine Direct send is confirmed unaffected; (4) a zero-selected active channel sends to nobody without erroring, and a newly-reachable guild member appearing mid-session is confirmed absent from an already-narrowed selection. Full existing mock suite (14 prior scripts, including `loader_ignore.lua`) re-run and still passes; `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.2 (round 2): fold the recipient subset into the Send-to dropdown itself

Follow-up on the round above: the separate chip + attached flyout panel visually read as "two stacked widgets" and broke the header's alignment with Search. Reworked so the ENTIRE interaction lives inside the existing single "Send to:" dropdown - no second persistent control beside or below it.

**`Theme.lua`** (`Theme.CreateDropdown`, the shared dropdown widget also used by EditWindow.lua's two dropdowns, Settings' dropdowns, etc.) gained three purely additive, backward-compatible capabilities that no other existing consumer opts into:
- `opt.onRowClick` - a row can fully own its own click behaviour (skip the default "set value, close list, fire onChange" flow) instead of the generic single-select path.
- `opt.checkbox`/`opt.checked` - a lightweight checkbox glyph per row (same checkmark texture/backdrop language as `Theme.CreateCheckbox`), rendered before the row's indent so a member row's selected state reads the same as every other checkbox in the addon.
- `dd:RefreshList()` - re-fetches options via the existing `SetOptionsProvider` and rebuilds rows **in place** while the list stays open (no close/reopen, no scroll-position reset, no up/down-flip re-evaluation), and `dd:SetLabelText(text)` - sets the closed button's own label directly, independent of the static per-value text a normal `SetValue` looks up, so it can show a live "selected/available" count.

**`UI.lua`**: the old subset chip/flyout panel is gone. The "Send to:" dropdown's own option list is now hierarchical - All, Self, then Friends/Guild/Raid-Party, each carrying its live "selected/available" count as the row's right-aligned suffix. Clicking a Friends/Guild/Raid-Party row (`opt.onRowClick`) activates it (resetting any other channel's subset, selecting everyone reachable by default) and calls `dd:RefreshList()`, which re-renders the SAME open list with that channel's member rows (`opt.checkbox=true`) indented directly underneath - never closing the dropdown. Clicking the already-active channel's own row again toggles all its members off/on (`SB.ToggleAllChannelMembers`) instead of reactivating it. A member row's click toggles it (`SB.ToggleChannelMember`) and refreshes in place, so any number of members can be checked/unchecked without ever reopening the menu. Picking All/Self still closes the list normally, matching a plain dropdown pick. The closed chip's own text ("Send to: Friends (1/2)") is driven by `dd:SetLabelText`, refreshed on every toggle and on `OUTPUT_SELECTION_CHANGED` (the same roster-change event as before - `dd:RefreshList()` is a no-op while the list is closed, so this stays safe to call unconditionally). The dropdown's own existing `maxVisibleRows`/scroll-thumb mechanics keep a large expanded roster capped and scrollable instead of growing the popup indefinitely, with zero changes needed there.

No changes were needed in `Communication.lua` (the subset state/dispatch/wire-protocol logic from the round above is untouched) or `Announcer.lua` (still reads the same `SB.db.settings.defaultOutputTarget`/`SB.GetChannelSubsetCount` values, unaware of which UI produced them). The Send-to dropdown's individual per-player "Direct target" rows from the original pre-subset design were deliberately dropped (a channel's member checkboxes now cover "send to specific people in a channel"); a genuine one-off Direct send to anyone reachable is still available, unaffected, from a Mini Soundbook slot's own right-click "send to..." menu (`SendMenu.lua`, not touched).

**Tests**: a new `loader_sendto_dropdown.lua` (16th script) builds the real Main window (`SB:ShowMainWindow`) and drives the actual dropdown rows via their own `OnClick` handlers (found by walking `dd:GetListFrame():GetChildren()`, not a shortcut around the widget), covering: no leftover second control and an unchanged closed width; opening Friends selects all by default, expands in place, and survives repeated member toggles without the list closing; switching Friends -> Guild clears the Friends subset, collapses its rows, expands Guild's, and selects Guild's members by default; re-clicking the active Guild row toggles everyone off then back on without closing; a 20-member roster keeps the list height capped at `maxVisibleRows` rather than growing to fit all of them; and All/Self still close the list like a normal pick while clearing every channel's subset. Full mock suite (16 scripts total) passes; `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.2 (round 3): distinguish implicit-all from an explicit subset for newly available members

Audit finding: the round-2 implementation stored "everyone selected" as a frozen snapshot array, structurally identical to any other subset - a newly-reachable Soundbook user was never added, even when the channel had been left at 100% selected. Per this round's explicit requirement, that's wrong: "all reachable selected" must behave as a live/dynamic state that keeps tracking new arrivals, while an explicit narrowing (including "everyone deselected") must not.

**`Communication.lua`**: `channelSubset[bucket]` now holds one of three distinct states instead of two - `nil` (never activated, whole-channel), the string sentinel `"ALL"` (implicit "everyone currently reachable", recomputed live from `SB.ComputeReachablePlayers` on every read - the same "read is always fresh, nothing cached" ComputeReachablePlayers already guaranteed elsewhere), or a concrete array (an explicit, frozen subset, possibly empty). `SB.ActivateChannelSubset` now sets `"ALL"` instead of snapshotting a copy. A new internal `SetExplicitSubset` helper is the one place both `ToggleChannelMember` and `ToggleAllChannelMembers` finish through: it checks whether the resulting list happens to cover every currently-reachable member and, if so, collapses back to the dynamic `"ALL"` state instead of keeping a coincidentally-full frozen list - so "select everyone" always behaves the same way and keeps tracking future arrivals, regardless of whether it was reached via first activation, the toggle-all gesture, or manually re-checking every remaining box by hand. `ComputeChannelSubsetRecipients`/`GetChannelMemberRows`/`GetChannelSubsetCount` each gained an explicit `current == "ALL"` branch alongside their existing `not current` one; none of their read-only behaviour toward an explicit subset changed, and none of them ever mutate `channelSubset` themselves - a roster refresh (`SB:Fire("OUTPUT_SELECTION_CHANGED")`, already fired by UI.lua's existing `GROUP_ROSTER_UPDATE`/`GUILD_ROSTER_UPDATE`/`FRIENDLIST_UPDATE` listener) only ever changes what `SB.ComputeReachablePlayers` returns, never `channelSubset` itself, so it can never silently convert an explicit subset back into "all" - only a deliberate toggle that happens to reach 100% can.

No changes were needed in `UI.lua` - it already re-reads `GetChannelMemberRows`/`GetChannelSubsetCount` fresh on every `dd:RefreshList()`/`OUTPUT_SELECTION_CHANGED`, so it automatically reflects the corrected semantics with zero UI-layer changes. Wire protocol, dispatch, receive-gating and ACK behaviour (round 1) are untouched.

**Tests**: a new `loader_subset_growth.lua` (17th script) covers all three states from both a closed and an open dropdown: (closed, direct state calls) implicit ALL auto-grows from 3/3 to 4/4 when a friend comes online, with the new member's own row already checked; an explicit partial subset (2/3) shows the new arrival unchecked at 2/4; an explicit empty subset (0/3) stays at 0/4; switching away and reactivating starts fresh at the CURRENT roster size; manually re-checking every member collapses back to the dynamic ALL state, confirmed by a further new arrival still auto-joining. (Open, through the real `SB:ShowMainWindow` dropdown, rows clicked via their own `OnClick` handlers) a friend coming online while the list is open and Friends is at ALL immediately shows the new member's row already checked, list still open, no reopening; narrowing to an explicit subset while open, then a further new arrival appearing, shows up unchecked with the selected count unchanged, list still open the entire time. Full mock suite (17 scripts) passes; `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.2 (round 4): persist the recipient subset across /reload and relog

Explicit user request, superseding round 1's own "session/UI state only, never SavedVariables" design decision: the per-player recipient subset must survive `/reload` and a full relog, not reset to "everyone selected" every time.

**`Core.lua`**: `GetDefaultDatabase()` gained a new `ui.channelSubset = {}` default, right beside the existing (dead, compatibility-only) `ui.outputRail`.

**`Database.lua`** (`SanitizeDatabase`): a new block validates `ui.channelSubset` the same way `ui.outputRail.selected` already is - each of `GUILD`/`RAID`/`FRIENDS` is coerced to one of exactly three safe shapes: the literal string `"ALL"` (kept as-is), a deduplicated array of names that pass `SB.IsValidPlayerTarget` (anything else in the array is silently dropped), or `nil` (anything else - a garbage type, a corrupted value) - never raises an error regardless of what a hand-edited or corrupted SavedVariables file contains.

**`Communication.lua`**: the round-2/3 module-local `channelSubset` Lua table is gone. Every accessor (`SB.ActivateChannelSubset`/`IsChannelSubsetActive`/`ToggleChannelMember`/`ToggleAllChannelMembers`/`ResetChannelSubsetsExcept`/`ComputeChannelSubsetRecipients`/`GetChannelMemberRows`/`GetChannelSubsetCount`) now reads/writes `SB.db.ui.channelSubset[bucket]` through two tiny internal helpers (`GetSubset`/`SetSubset`, guarded against `SB.db` not existing yet). The three-state value shape from round 3 (`nil` / `"ALL"` / an explicit array) is completely unchanged - only where it lives changed, so every behavioural guarantee from round 3 (implicit ALL auto-grows, an explicit subset including empty never does, switching channels clears it, a toggle that reaches 100% collapses back to `"ALL"`) carries over unmodified, now simply surviving a reload too. No `UI.lua` changes were needed - it already only ever calls these same accessors.

**Tests**: a new `loader_subset_persistence.lua` (18th script) simulates a `/reload` the same way this suite already tests every other persisted setting (re-running `SB:PrepareDatabase` on the previous session's own `db` table, into a fresh addon environment - see `loader_scalesplit.lua`'s own reload section): an explicit partial subset (2/3) keeps the exact same two members selected after reload; the implicit `"ALL"` state survives as the live sentinel and still auto-includes a guildmate who joined only after the reload; an explicit empty subset (0/N) stays empty after reload rather than reverting to whole-channel or ALL; a bucket cleared before reload (switched away from) stays inactive after reload; and malformed saved data (a garbage-typed bucket, an array containing one name with an embedded `"|"`) is sanitized without error, dropping only the invalid entry. Full mock suite (18 scripts) passes; `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.2 (round 5): reset the subset (not the channel) on a genuine fresh login, keep it across /reload

Refinement of the round above, per explicit user clarification: round 4 made the subset survive `/reload` AND a full client restart identically (both just read the same SavedVariables file, with no way to natively distinguish them). The actual intent is narrower - the active CHANNEL (Guild/Raid/Friends/All/Self) should keep persisting across both, exactly like any other setting, but a narrowed per-player SUBSET should only survive a `/reload`; after a genuine relog/client restart it should reset back to "everyone selected", since a stale hand-picked list from a previous session is more likely to be surprising than useful days later.

**`Communication.lua`**: a `/reload` re-executes every addon file from scratch (same as a full restart, from a plain-Lua-state point of view), so the previous round's own module-local-vs-SavedVariables distinction can't tell these two apart on its own - the fix uses WoW's own native, documented signal instead: `PLAYER_ENTERING_WORLD` fires with an `isInitialLogin` boolean that is `true` only immediately after a genuine fresh login, never after a `/reload` while already in world. A new `SB.ResetChannelSubsetsOnFreshLogin(isInitialLogin)`, wired to a dedicated `PLAYER_ENTERING_WORLD` listener (`SoundbookSubsetLoginFrame`, named for mock-harness reachability the same way `SoundbookCommFrame` already is), clears every bucket back to `nil` only when `isInitialLogin` is true. Resetting to `nil` rather than explicitly `"ALL"` is sufficient and requires no special case: every existing read function already treats `nil` exactly like `"ALL"` for display and dispatch, so the reset immediately reads as "everyone selected" and keeps tracking future arrivals, matching round 3's own dynamic-ALL guarantee. `SB.db.settings.defaultOutputTarget` (the channel itself) has its own, entirely separate, always-persisted storage and needed no change at all.

**Tests**: a new `loader_subset_login_reset.lua` (19th script) covers exactly the two scenarios from the user's own request: (1) the active channel (Guild) survives both a simulated `/reload` (`isInitialLogin=false`) and a simulated full restart (`isInitialLogin=true`) unchanged; (2) a subset narrowed to 2 of 3 Guild members survives a `/reload` intact, but resets to 3/3 ("Guild all") after a simulated full restart from the SAME original narrowed SavedVariables, with the channel itself still reading Guild throughout - and the post-reset state is confirmed to behave as the live ALL state (a further new guildmate auto-joins), not a frozen snapshot. Full mock suite (19 scripts) passes; `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.2 (round 6): show actual recipient names in the Mini Soundbook title when they fit

Explicit user request: for a single active channel (Guild/Raid/Friends) with a small recipient list, the Mini Soundbook's title bar should show the real names ("Play for Alice and Bob:") instead of a bare count, but only when they'd genuinely fit - falling back to the count ("Play for Guild (3):") otherwise, exactly as before this round.

**`Announcer.lua`**: `ComputeLiveTargetCounts` now also returns the single-bucket case's actual effective recipient list (via the existing `SB.ComputeChannelSubsetRecipients`, falling back to the full reachable list exactly like `SB.GetChannelSubsetCount` already does for the count) rather than just a count. `DescribeEffectiveTargetPhrase` builds a candidate name-list string from it (`BuildNamesCandidate`/`JoinNamesNaturally` - "Alice", "Alice and Bob", "Alice, Bob and Carol", capped at 3 names - more than that never even attempts a fit-check, since a HUD title bar realistically can't fit more) and returns it as a new 4th value alongside the existing count phrase, never touching the unaffected multi-bucket "All" or Self-Only paths. `GetFavMenuHeaderText` is the one place that decides: it wraps the names candidate in the exact same "Play for X:"/"Default destination: X" phrasing the count phrase already uses, sets it on `favMenu.title` to measure its REAL rendered `GetStringWidth()` against the actual available width, and only keeps it if it fits - otherwise it restores the previous text and falls back to the count phrase, identical to today. `PopulateFavMenu` now computes the popup's grid width/columns *before* building the header (previously after), so the available width passed in is always the one this exact render is about to use, never one render stale.

Deliberately a genuine pixel measurement, not a name-count heuristic: two names that are individually short in COUNT can still be too WIDE to fit (long realm-attached names, a narrow popup at a small Mini Soundbook Size), and the fit-check catches that case correctly rather than assuming "2 or 3 names always fits".

**Test harness note**: `mock.lua`'s `FontString:GetStringWidth()` was hardcoded to always return `50` regardless of the text set on it - harmless for every prior test (none needed real text-width comparisons) but unable to exercise a genuine fit-check. Changed to a flat ~7px-per-character approximation (`#text * 7`) - the mock still has no real font metrics to draw on, but this is now proportional to text length, which is all a test needs to assert "this candidate is wider/narrower than that available width". Full existing suite re-verified unaffected by the change.

**Tests**: a new `loader_mini_title_names.lua` (20th script) covers: two and three short names both fit and enumerate naturally; four names (over the sane cap) always fall back to the count even though they'd technically fit pixel-wise; two individually-short-count but genuinely wide (long) names correctly fall back to the count too, proving this is a real measurement and not just a name-count cutoff; narrowing the channel subset live-updates which names show; and the multi-bucket "All" and Self-Only paths are completely unaffected. Full mock suite (20 scripts) passes; `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.2 (round 7): review and fix the round-6 title-bar logic against the full intended spec

Explicit user review request against a detailed spec, found to be only partially met by round 6. Three real defects and one missing recompute trigger were found and fixed in `Announcer.lua`/`Core.lua`, all scoped to the Mini Soundbook title logic only:

- **Fixed name-count cap violated "no fixed rule, pure fit-check" requirement.** `BuildNamesCandidate`/`JoinNamesNaturally` capped at 3 names regardless of whether more would actually fit. The cap is gone; any number of names is attempted, and the real `GetStringWidth()` measurement alone decides whether they're shown.
- **Zero selected recipients incorrectly read "Play for Yourself".** `ComputeLiveTargetCounts`'s single-bucket branch only recorded a count `if n > 0`, so an explicit empty subset (0 selected) fell through the same `isLocal`-style branch Self Only uses. Fixed to always record the bucket's actual count (including 0) and to stop treating a single-bucket target as "local"; a zero-selected channel now correctly reads "Guild (0):" (or Raid/Friends), never "Play for Yourself".
- **Missing recompute on font/Text Size change.** `SB:RefreshMainFont()` changes real glyph widths but nothing told an already-open Mini Soundbook to redo its fit-check, so a Text Size change mid-session could leave a stale names-vs-count decision on screen. `SB:RefreshMainFont()` now fires a new `MAIN_FONT_CHANGED` event; `Announcer.lua` listens for it and repopulates the Mini Soundbook (`PopulateFavMenu`) if it's currently open, alongside the existing resize/selection/roster-change recompute paths.
- **Player names now render in the channel's own colour**, per explicit follow-up request, matching the colour already used elsewhere in the addon for that channel (`SB.CHANNEL_COLOR`). A new `ColorizeForBucket` helper wraps both the names candidate AND its count-phrase fallback in the same `|cff<hex>...|r` inline colour code, so whichever one ends up shown is always coloured, never just the names case. WoW strips these escape codes before laying out/measuring text, so embedding them never skews the fit-check itself - confirmed by having the mock's own `GetStringWidth()` strip them the same way before approximating width.

Everything else from round 6 (real pixel fit-check, no partial-name truncation, recompute on resize/selection/roster change, "All"/Self Only unaffected, received/remote sounds still routed through the existing Announcer rather than the slot) was reviewed and found already correct - untouched.

**Test harness note**: `mock.lua`'s `GetStringWidth()` approximation now strips `|cxxxxxxxx`/`|r` color codes before counting characters, matching real WoW's own measurement behaviour (colour codes are never rendered as glyphs and must not count toward width).

**Tests**: `loader_mini_title_names.lua` rewritten (still the 20th script) with 8 scenarios: 2 short names fit and are colour-wrapped; 3 names enumerate naturally; 4 short names still show as names (no fixed cap); 2 long names correctly fall back to a colour-wrapped count; a narrowed subset live-updates the shown names; zero selected reads a colour-wrapped "Guild (0):", never "Play for Yourself"; "All"/Self Only remain unaffected; and a simulated `MAIN_FONT_CHANGED` (via `SB:RefreshMainFont()`) is confirmed to repopulate an open Mini Soundbook's title. Full mock suite (20 scripts) passes; `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.2 (round 8, P1): fix playback regression + channel-dropdown label refinements

Live-test report: clicking a sound with Guild/Raid/Friends/All selected frequently produced no audible playback, Self didn't reliably recover it on the first click, and the debug log showed a valid file being logged as `PlaySound: cached missing file '...' (source=local)`.

**Root cause investigation**: `SB:TriggerSound` already calls `SB:PlaySound(soundID, "local")` (SoundPlayer.lua) BEFORE `SB:DispatchDefaultOutput` (the network-send half), and `DispatchDefaultOutput` only ever runs `if played` and never blocks or delays on it - there is no code path where local playback waits on recipient/channel state, confirmed by tracing every caller of `SB:PlaySound` (`TriggerSound`, `Communication.lua`'s `PlayLocally`, the Announcer's own preview) and `SB:DispatchDefaultOutput` itself (network sends only, no second playback call). `GetChannel()` (the `PlaySoundFile` audio-channel argument, e.g. Master/SFX) was also confirmed completely unrelated to the Guild/Raid/Friends *output* channel - two different concepts that happen to share the word "channel". Recipient/channel-selection work earlier this cycle did not introduce this regression at the code level.

The actual root cause was `SoundPlayer.lua`'s missing-file cache: `SB:PlaySound` treated a SINGLE `willPlay=false` from `PlaySoundFile` as proof the file was missing and cached that verdict (`missingFileBases[fileBase] = true`) for the rest of the session, with no expiry and no corroboration required. `PlaySoundFile` can return `willPlay=false` for a real, valid file for reasons that have nothing to do with the file's existence (a one-off engine-level hiccup) - once that happened, every future click on that exact sound silently hit the cached-missing branch and returned `false` immediately, regardless of which output channel was selected, which is exactly the intermittent "frequently does nothing, several clicks eventually work" pattern reported (a later click could still succeed if it happened to resolve a *different* code path/extension order, but the poisoned fileBase itself never healed on its own).

**Fix**: the cache now requires `MISSING_STRIKES_TO_CONFIRM` (2) independent failed probe attempts - each covering every extension in `SB.SOUND_EXTENSIONS` - before trusting a negative result and caching it; a genuinely missing file fails identically every time, so it's still confirmed within the first click or two, with zero change to how quickly a real missing-file notice appears in practice. A confirmed-missing entry also expires after `MISSING_CACHE_TTL` (10s) rather than lasting the whole session, so even a fully confirmed miss re-probes later instead of staying poisoned past a since-fixed cause. A genuine success at any point immediately clears the strike count, the confirmed-missing timestamp, and the one-time user notice guard together, so a fileBase that starts working again is fully un-poisoned, not just allowed to bypass the cache once. No workaround retry loop was added anywhere in the click/trigger path itself - only the cache's own trust threshold changed.

**Channel-dropdown refinements** (`UI.lua`/`Communication.lua`, explicit follow-up requirements): the "No reachable Soundbook users right now." placeholder row under an expanded, empty channel is gone, with nothing put in its place - zero reachable members now just means the expanded list has nothing beneath the channel row. Both the closed "Send to:" label and each channel row's own count now follow one shared rule (`ChannelCountSuffix` in `UI.lua`): zero reachable recipients shows the bare channel name with no count at all (never "(0/0)"); the untouched default all-selected state shows a bare count ("Guild (3)", never "(3/3)"); an actual explicit narrowing - including an explicit 0-selected subset - shows "selected/available" ("Guild (2/3)", "Guild (0/3)"). Telling "untouched default" apart from "manually re-selected everyone" needed a new small accessor, `SB.IsChannelSubsetExplicit(bucket)` (Communication.lua), reading the same three-state `nil`/`"ALL"`/array value the rest of the subset system already uses - a manually-reselected "everyone" already collapses back to the dynamic `"ALL"` state via the existing `SetExplicitSubset` (round 3), so it correctly reads as "default", not "explicit", with no separate bookkeeping needed. No change was needed for "all reachable users disappear -> channel stays selected, no fallback" - `SB.db.settings.defaultOutputTarget` and the stored subset value were never touched by a roster change in the first place (only `ComputeReachablePlayers`'s live result changes), so the existing all-vs-explicit-subset semantics (round 3) already carry over unmodified; the label rule above just stops making that state look alarming.

**Tests**: a new `loader_playback_regression.lua` covers: a single simulated `PlaySoundFile` hiccup on click 1 does not block a normal, successful click 2 for the same sound; a genuinely-always-failing file is still confirmed missing and the user is still notified exactly once across three clicks (never once per click); a confirmed-missing entry expires after the TTL and successfully re-probes once the underlying file becomes playable again; and local playback succeeds for every one of SELF/ALL/GUILD/RAID/FRIENDS with zero reachable recipients on every multiplayer channel, plus a real explicit 0/2 Guild recipient selection - all six still fire `LOCAL_SOUND_PLAYED` normally. A new `loader_sendto_labels.lua` covers: the default all-selected state's bare count on both the closed label and the row's own suffix; an explicit narrowing down to 2/3 then to an explicit 0/3; zero reachable users showing the bare channel name with the row's suffix column hidden entirely (not just empty) and the active channel/target staying selected; and no `EMPTY:`-tagged placeholder row anywhere in the list. Full mock suite passes (both pre-existing failures in `loader_minititle.lua`/`loader_settings.lua` reconfirmed present on the unmodified base commit, unrelated to this round); `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.0: Send-to label colour fix, merge with the locator-glow experiment, version alignment

Two small follow-ups plus a branch merge, landing together as the build the user is taking into local WoW testing before any release:

**`UI.lua`**: the closed "Send to:" chip picked up a channel colour only incidentally before (or not at all, depending on the current/previous state) - explicit report: "Send to: Guild" was rendering in the plain text colour instead of Guild's own green, and this must hold regardless of whether anyone is currently reachable on that channel. `RefreshSendToLabel` now always passes an explicit colour to `dd:SetLabelText` - Guild/Raid/Friends/Self each in their own `SB.CHANNEL_COLOR`, "All" (which has no single channel colour) explicitly reset to the normal text colour (`Theme.TEXT`) rather than left unset, since `SetLabelText` only ever changes the colour when given one - without an explicit reset, switching from a coloured channel back to "All" would have kept showing the previous channel's colour.

**Merge**: `feature/mini-locator-glow` (the isolated proximity-glow experiment, branched earlier for side-by-side in-game comparison - see its own round's report) merged cleanly into this line with zero conflicts, since it only ever touched `Announcer.lua`/a new asset file and nothing else on this line touched `Announcer.lua` since they diverged. Both `dev/3.0.1`'s own subsequent work (the playback-cache fix, the channel-dropdown refinements, this round's colour fix) and the locator glow now ship together in one build.

**Version**: `Soundbook.toc`'s `## Version` had drifted to `3.0.2` while `README.md`'s own top-level heading and intro paragraph had said "Soundbook 3.0.0" the entire time (the 3.0 UI/UX redesign line's own name) - the TOC now reads `## Version: 3.0.0` to match, the one place `SB.VERSION` (Core.lua, via `C_AddOns.GetAddOnMetadata`) actually reads from. Nothing else needed changing - every in-addon version display already derives from this one TOC field. QA_REPORT's own historical "Soundbook 3.0.2 (round N)" entries above are left as-is - they are dated records of when each round of work actually shipped under that TOC number at the time, not a live version label to keep retroactively "correct".

**Tests**: full mock suite re-run post-merge, including `loader_locator_glow.lua` (previously only ever run on the isolated feature branch, now exercised together with every other change on this line for the first time) and a manual re-check of `loader_sendto_labels.lua`'s colour assertions extended to also cover the zero-reachable case staying coloured and switching to "All" resetting the colour. All pass except the same two pre-existing, unrelated failures (`loader_minititle.lua`/`loader_settings.lua`); `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.0: compact Announcer banner layout + white All/Self Only target colour

Explicit redesign request against an approved second mockup: the active Announcer banner had visually empty top/bottom bands, a small fixed 30px icon, and the duration ("0.8 / 1.3") floated isolated in the top-right corner disconnected from the progress bar it actually describes.

**`Announcer.lua`** (`BuildBanner`/`RelayoutBannerHeight`): every banner element's position now derives from one shared layout pass instead of a mix of static anchors (icon, name) and a separate dynamic one (track only). `RelayoutBannerHeight` computes `contentH` from the actual font metrics (name row + sender/duration row + progress bar, with tight `NAME_ROW_GAP`/`BAR_GAP` gaps) exactly as before, but now the icon's own size is DERIVED from that same `contentH` (`iconSize = contentH`) and anchored with the same `BANNER_PADDING` (5px, matching the previous icon-to-left-edge distance) on all of its top/bottom/left sides - filling nearly the full banner height instead of sitting at a fixed 30px near the top. The duration (`timeText`) moved off its old isolated `TOPRIGHT` anchor onto the SAME row as the sender/channel line (`subText`), right-aligned, with `subText`'s own right edge now anchored to `timeText`'s left edge (`SUB_TIME_GAP`) instead of a fixed banner-relative offset, so the two can never overlap regardless of sender-name length. The progress bar keeps starting at the same left edge as the text (`textLeft = PADDING + iconSize + ICON_TEXT_GAP`) and sitting directly below that row. Net effect at the default font scale: banner height is UNCHANGED from before (same formula's own natural total, just redistributed - verified equal, not just "not bigger"), while the icon grows from a fixed 30px to whatever the now-taller-relatively content column allows (order of ~46px depending on font scale) - "compact and information-dense", never a taller Announcer. `BuildBanner` itself no longer sets any position on these elements (previously static, now misleading) - `RelayoutBannerHeight` (called once via `SB:RefreshAnnouncerFont` right after construction, and again on every font/scale change) owns 100% of the layout, exactly matching the pattern the progress bar already used before this round. `ICON_SLOT_SIZE` (now-unused fixed constant) removed.

**`Core.lua`**: `SB.GetChannelColor` (the shared label->colour lookup behind the Announcer's own "sender -> channel" line, History's source colour, etc) mapped both "Self" and any unrecognized label - which included "All", since it was never in the lookup table at all - to `SB.CHANNEL_COLOR.SELF`'s grey. Per explicit report ("All must display in white, not grey. Self only must display in white, not grey."), both now resolve to a new `TARGET_WHITE` (matching `Theme.TEXT`/`V3.TEXT_PRIMARY`'s own off-white exactly, duplicated as a literal since Core.lua loads before Theme.lua) instead. `SB.CHANNEL_COLOR.SELF` itself is intentionally untouched - it's still read directly elsewhere for unrelated purposes (e.g. Settings' "General" tab colour) that have nothing to do with output-target labelling and must keep their existing grey. Guild/Raid/Friends/Direct are unaffected.

**`UI.lua`**: the Send-to dropdown's own closed-chip colouring (added the previous round) had the same bug in miniature - its "Self" branch read `SB.CHANNEL_COLOR.SELF` directly rather than going through the now-fixed shared lookup. Simplified to just leave the branch's default (`SB.Theme.TEXT`, the same white) in place for both "All" and "Self", removing the now-redundant explicit grey override.

**Tests**: a new `loader_banner_layout.lua` covers: the banner's total height exactly matches the new layout formula and is never taller than the old pre-redesign formula would have produced with the same real font metrics (computed dynamically from `SB.Fonts`, not assumed real-WoW point sizes); the icon is square, substantially bigger than the old fixed 30px, exactly fills the content-column height, and sits with an equal top/left inset (`PADDING`) that also matches its bottom inset from the banner's own bottom edge; the progress bar's left edge matches the text's left edge and its top sits directly below the sender/duration row; `SB.GetChannelColor` returns white for "Self"/"All" and the correct unchanged colour for Guild/Raid/Friends/Direct, while `SB.CHANNEL_COLOR.SELF` itself stays grey; and the banner's real `subText` (driven end-to-end through an actual `SB:TriggerSound` call with `defaultOutputTarget = "SELF"`) embeds the white hex around "- Self", not the old grey one. Full mock suite passes (the same two pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.0: fix overlap progress-reset regression, replace +N with remaining-time markers, keep Mini Soundbook open on click

**Progress-reset regression (`Announcer.lua`)**: live-test report - when one overlapping/background sound finished, the Announcer's currently-displayed sound briefly flashed/reset its elapsed time to 0 before recovering. Root cause: `RemoveDisplayByInstance` (the handler behind `PLAYBACK_PROGRESS_ENDED`, fired by SoundPlayer.lua for EVERY tracked instance - primary or background alike, per its own module comment) called `RenderPrimary()` unconditionally whenever ANY instance ended, including one that was never the displayed (last/primary) entry in `activeDisplays`. `RenderPrimary()` does a full repaint - `banner.fill:SetWidth(0.01)` then restarts the 0.1s progress ticker from scratch - so ending an unrelated background sound reset the UNTOUCHED primary's own fill/ticker, visibly flashing it back to (near) zero before the next tick caught it back up. Fixed by tracking whether the just-removed entry WAS the primary (the last element, checked at removal time): if it wasn't, only `RefreshOverlapMarkers()` runs (see below) - the primary's own fill/ticker/text are never touched; if it was, that's a genuine primary change and still gets the full `RenderPrimary()` repaint, exactly as before. `AddDisplay` (a new sound starting, always a genuine primary change) is unaffected and still always repaints fully.

**Replace "+N" with overlap markers (`Announcer.lua`)**: the numeric `+N` badge (`banner.overlapBadge`) is removed entirely, along with every reference to it (RenderPrimary, the persistent Raid Mute banner, the drag/resize preview). In its place, each OTHER currently-playing sound gets a thin (2px), additive-blended white vertical line inside the progress bar itself (`banner.markers`, a small pooled-texture array parented directly to `banner.track`, created lazily) - `RefreshOverlapMarkers()` positions each one at that background sound's own remaining time as a fraction of the PRIMARY's remaining time (`remaining / primaryRemaining`, clamped 0-1), matching the spec's own worked example (10s primary remaining, 4s background remaining -> marker at ~40% across the bar). Recomputed on every 0.1s progress tick (continuous movement, driven off the exact same ticker that already updates the primary's own fill - no separate ticker) AND immediately whenever a background sound starts (`AddDisplay`, for the just-demoted former primary) or ends (`RemoveDisplayByInstance`'s non-primary branch), so a marker appears/disappears instantly rather than waiting for the next tick. A background entry with no known duration gets no marker at all (never a guessed position - respects the same tracking-limitations philosophy `Soundbook-3.0-Discovery-Report` already establishes elsewhere). OVERLAY draw layer (above the fill's own ARTWORK layer) with additive blending keeps a marker clearly visible whether it lands over the filled or unfilled portion of the bar, without needing two different colours for the two cases.

**Mini Soundbook stays open on click (`Announcer.lua`)**: `GetOrCreateFavMenuRow`'s own `OnClick` no longer calls `favMenu:Hide()` after triggering the sound - the existing proximity/auto-collapse system (`StartMiniProximityTicker` et al., untouched) remains the sole thing that ever closes it, exactly as it already governs every other interaction (hover, Send-to). Each row gained its own progress fill (`row.progressFill`, a BACKGROUND-layer texture spanning the row's full width, so it sits behind the existing HIGHLIGHT hover texture and the ARTWORK/OVERLAY icon+text - neither stays readable is ever compromised and hover still highlights on top as before), driven by two new listeners on the exact same shared `PLAYBACK_PROGRESS_UPDATE`/`PLAYBACK_PROGRESS_ENDED` broadcast the Announcer banner itself already reacts to independently - no coordination or hand-off logic needed between the slot and the banner, each simply reacts to the live state while it's actually visible (gated on the Mini Soundbook actually being open; zero work while it's closed). A row is matched by `soundID` (the only identity a row itself has); two simultaneous instances of the identical sound update the same row, an accepted pre-existing tracking limitation, not invented state. `PopulateFavMenu` resets a row's stale progress fill only when that pooled row slot is genuinely reassigned to a *different* sound (a real favourites reorder/replace) - a repopulate for an unrelated reason (font/selection change) while the same sound keeps playing in that slot no longer visually interrupts it.

**Tests**: a new `loader_overlap_progress.lua` covers: a background sound's own natural end never resets or decreases the primary's fill width (only ever moves forward, and never collapses back to the ~0.01 "freshly restarted" width); a marker's position matches the remaining-time-fraction formula against the spec's own worked example; a marker disappears immediately when its sound ends while an unrelated second background marker stays untouched; and overlap-disabled mode never shows any markers at all (only one sound is ever tracked at a time, unaffected on/off semantics). `loader_playbacklifecycle.lua`'s own secondary/overlap scenario updated to assert on `banner.markers` instead of the now-removed `banner.overlapBadge`. A new `loader_minifav_progress.lua` covers: clicking a Favourite keeps the Mini Soundbook open and shows progress on that row; a second click while the first is still playing keeps both progressing simultaneously; hover and a further click both still work normally on a third row while others are actively playing; and once playback naturally ends, each row returns to its normal state while the Mini Soundbook itself stays open (closing remains purely the existing proximity system's job). Full mock suite passes (the same two pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.0: overlap marker contrast, Mini Soundbook item border, tooltip cleanup + anchor

**Marker contrast (`Announcer.lua`)**: the overlap markers' additive-blended white lost against a light/white progress fill - additive blending only ever brightens, it can never darken an already-bright destination pixel, so it physically cannot add contrast against near-white art (made worse by the earlier fix that renders the "All"/"Self only" target's fill in white). `GetOrCreateOverlapMarker` now builds each marker as two normal-`BLEND` textures instead of one `ADD`-blended one: a 4px dark shadow (`0,0,0`, alpha 0.55) behind a 2px gold core coloured with `Theme.GOLD` - the same gold used for the Mini Soundbook's own border - both parented to `banner.track` exactly as before. `RefreshOverlapMarkers`/`HideAllOverlapMarkers` now position/show/hide both layers together (`marker.shadow`/`marker.core`) at the identical remaining-time-fraction position the marker math already computed; only the marker's own visual shape changed, not its placement, pooling, or update timing.

**Mini Soundbook item border (`Announcer.lua`)**: each Favourite row now gets a thin 1px gold outline, additive to (never replacing) the existing hover highlight and per-row progress fill. `GetOrCreateFavMenuRow` switched from a plain `CreateFrame` to `SB.CreateFrame` (the addon's own `+BackdropTemplate` wrapper) so `SetBackdrop`/`SetBackdropBorderColor` become available, and gave the row a border-only backdrop (`edgeFile`/`edgeSize` only, no `bgFile` - the same pattern `UI.lua`'s `favouriteHover` already uses) hidden by default. A new `UpdateRowBorder(row)` helper derives visibility from two independent, already-tracked signals - `row.isHovered` (now set in the row's own `OnEnter`/`OnLeave`) and `row.progressFill:IsShown()` (already the single source of truth for "is this row's sound currently playing") - so the border can never drift out of sync with either state, and is wired into `OnEnter`, `OnLeave`, both `PLAYBACK_PROGRESS_UPDATE`/`PLAYBACK_PROGRESS_ENDED` listeners, and `PopulateFavMenu`'s existing pooled-row-reassignment reset (a row recycled for a different sound no longer carries over a stale hovered/playing border either). Because it's a single on/off border rather than two stacked layers, hover and playing together simply keep it shown - there is no "doubled" state to produce.

**Tooltip simplification + dynamic anchor (`Announcer.lua`)**: the idle icon's tooltip (previously hardcoded to `ANCHOR_LEFT`, white "Soundbook" title, and four lines including "Left Click: Send a Favourite") is simplified to the requested three lines - a gold-coloured "Soundbook" title (`unpack(Theme.GOLD)`, matching the same gold-title convention already used elsewhere, e.g. `UI.lua`'s sound tooltips) followed by "Right Click: Open Soundbook" and "Shift + Right Click: Quick Options" only; the conditional Raid Admin/receive-mute info blocks above these lines are untouched. Its anchor is now dynamic instead of a fixed side: it reuses the same `SB.ResolvePopoutDirection(icon)` the Mini Soundbook/Quick Options popups themselves already call to decide which side they expand toward, and maps that to the OPPOSITE `GameTooltip` anchor (`LEFT`->`ANCHOR_RIGHT`, `RIGHT`->`ANCHOR_LEFT`, `UP`->`ANCHOR_BOTTOM`, `DOWN`->`ANCHOR_TOP`) - so the tooltip always opens away from wherever a hover-opened Mini Soundbook would sit next to the icon, at any screen position, without a second independent screen-edge calculation or any hardcoded side.

**Tests**: `loader_overlap_progress.lua` updated for the new two-layer marker shape (`marker.core`/`marker.shadow` instead of a bare texture) and extended with an explicit assertion that the shadow is wider than the gold core and both are shown together; `loader_playbacklifecycle.lua`'s own marker-counting helper updated the same way. `loader_minifav_progress.lua` gained a new scenario covering the row border across every state transition the spec calls out: hover-only shows it, leaving while not playing removes it, playing-only (no hover) shows it and persists, hover joining an already-playing row keeps it shown (no doubling), hover ending while still playing keeps it, and playback ending while not hovered removes it. Full mock suite passes (the same two pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.0: fix icon invisible-until-toggled-in-Settings (PLAYER_ENTERING_WORLD self-heal)

**Live report**: the Announcer icon was not visible right after logging in with the previous TEST-ZIP; toggling Settings' "Show Mini Soundbook" checkbox off then on made it appear - both paths call the exact same `SB:ShowAnnouncer()`, so the icon's logical state (`SB.db.ui.announcer.shown = true`, `icon:Show()` called) was correct in both cases. The only real difference is *when*: `PLAYER_LOGIN` fires very early, before the client's own loading-screen fade/UI transition has genuinely finished, whereas the Settings toggle happens well after the world has fully loaded. A frame first `Show()`n mid-transition can end up logically shown but never actually get its first real paint, with nothing afterward ever forcing a fresh redraw - a known class of WoW addon timing issue, and the standard fix is to also re-assert UI state on `PLAYER_ENTERING_WORLD`, the event that fires once the world is genuinely ready (on every zone/instance load, not just once at login).

**Fix (`Core.lua`, `Announcer.lua`)**: `Core.lua`'s `initFrame` now also registers the native `PLAYER_ENTERING_WORLD` event and relays it as its own `SB:Fire("PLAYER_ENTERING_WORLD")` broadcast - a separate event from `PLAYER_LOGIN` (not folded into it) specifically because it needs to fire on every world entry, not just the first. `Announcer.lua` subscribes and re-runs `SB:ShowAnnouncer()` whenever `SB.db.ui.announcer.shown` is true - the same idempotent call `PLAYER_LOGIN` already makes, just re-asserted once the transition is truly over. It never overrides an explicit `HideAnnouncer()`: the check is purely against the persisted setting, so a player who deliberately hid the icon never has it forced back on by a zone change.

**Tests**: a new `loader_entering_world.lua` covers: the icon is shown by default right after `PLAYER_LOGIN` (sanity); manually hiding it (standing in for the "logically shown but never actually painted" case the mock can't otherwise represent) and then firing `PLAYER_ENTERING_WORLD` brings it back, confirming the self-heal; and firing `PLAYER_ENTERING_WORLD` after an explicit `SB:HideAnnouncer()` leaves it hidden, confirming the fix never fights a deliberate hide. Full mock suite passes (the same two pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file.

This is a best-effort fix based on a live report I could not reproduce directly (no WoW client in this environment) - please confirm after retesting whether the icon now shows up reliably on first login.

## Soundbook 3.0.0: overlap markers now independent per sound, cyan contrast, "Mini Soundbook" tooltip title

**Live report**: the overlap markers were "not reliably visible, do not clearly communicate progress, and one indicator has even moved backwards." The "moved backwards" report pinpoints the actual root cause: the previous formula positioned a marker at `backgroundRemaining / primaryRemaining`. Since BOTH the numerator and denominator shrink by the same real-time amount every tick, that fraction is NOT monotonic - `d(fraction)/dt = (backgroundRemaining - primaryRemaining) / primaryRemaining^2`, which is negative (the marker visibly drifts LEFT over time) whenever the background sound's remaining time is less than the primary's own remaining time, i.e. almost always. A concrete example: primary has 10s remaining and a background sound has 4s remaining -> fraction 0.4; one second later, primary has 9s remaining and the background sound has 3s remaining -> fraction 3/9 = 0.333, a real decrease despite the background sound genuinely progressing toward its own end.

**Fix - independent per-sound markers (`Announcer.lua`)**: `RefreshOverlapMarkers` no longer reads the primary's duration/remaining time AT ALL for marker placement. Each background entry's marker is now positioned purely by ITS OWN `elapsed / duration` (`elapsed = now - entry.startedAt`), clamped `0..1` - 0% at that sound's own start, 100% when it finishes, moving monotonically left-to-right by construction, since a single tracked instance's own `startedAt`/`duration` never change while it stays active. This matches the task's own worked example exactly (primary 10s; background A 4s/2s elapsed -> 50%; background B 8s/2s elapsed -> 25%, moving at genuinely different speeds since each is driven by its own duration). Removal is unchanged: a background sound's own `PLAYBACK_PROGRESS_ENDED` still removes only its own `activeDisplays` entry and its own marker (`RemoveDisplayByInstance`'s existing non-primary branch), never touching the primary's own fill/ticker or any other marker.

**Fix - marker visibility (`Announcer.lua`)**: the marker's core colour switches from gold (`Theme.GOLD`, easily lost against the primary bar's own orange/gold fill - too little hue separation to read as a distinct signal) to `V3.ARCANE_CYAN`, the same Arcane cyan/blue family already used elsewhere in the addon's own chrome. Cyan sits opposite gold/orange on the colour wheel, so it reads as clearly "different" against both the filled and unfilled portions of the bar. The existing dark shadow layer (4px, black, alpha 0.55, normal `BLEND` - not `ADD`, established in the previous round specifically because additive blending cannot darken a light fill) is unchanged and keeps the marker visible over light art too. Markers stay 2px (core) / 4px (shadow) - narrow, secondary indicators, never dominant - and multiple markers can still be visible simultaneously with no `+N` counter.

**Tracking correctness**: inspected `activeDisplays`/`SoundPlayer.lua`'s tracked-instance model directly - each entry already carries its own `instanceID`, `startedAt`, `duration`, and is added/removed independently via `AddDisplay`/`RemoveDisplayByInstance`, matched by `instanceID` (never by soundID alone), so no tracking-side change was needed for correctness, only the marker's own positioning math. The existing, documented dedup behaviour for retriggering an already-displayed sound (`AddDisplay` calls `SB.RemoveAnnouncerDisplayForSound(soundID)`, which restarts that ONE sound's own entry with fresh timing rather than stacking a duplicate) is exactly the "existing safe tracking behaviour" the task asks to preserve for the same-sound-played-simultaneously case, and is unaffected by this fix.

**Mini Soundbook icon tooltip title (`Announcer.lua`)**: the idle icon's own tooltip title changed from `"Soundbook"` to `"Mini Soundbook"` (still gold-coloured, `unpack(Theme.GOLD)`) - scoped to this one tooltip only; the minimap button's separate tooltip (`MinimapButton.lua`) still reads plain "Soundbook" and was deliberately left untouched, since the task calls for an icon-scoped wording fix, not a global rename. The two interaction lines below it ("Right Click: Open Soundbook", "Shift + Right Click: Quick Options") are unchanged.

**Tests**: `loader_overlap_progress.lua` rewritten for the new independent-per-sound formula - two background sounds of different durations (4s and 8s) at the same 2s-elapsed instant land at exactly 50% and 25% respectively (matching the task's own worked example); a new monotonicity check samples one marker across five ticks and asserts its position only ever increases (directly covering the "moved backwards" report); a new 3-simultaneous-background-sounds scenario (4 sounds tracked in total, matching the task's "at least 3 simultaneous overlapping sounds" verify point) confirms three independent markers appear together and that retriggering the sound that's already primary (the "same sound triggered more than once" verify point) restarts only that one entry, leaving all three background markers' own state completely undisturbed. A new `loader_minisoundbook_tooltip.lua` confirms the icon's tooltip title reads exactly "Mini Soundbook". Full mock suite passes (the same two pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.0: smooth Mini Soundbook per-item progress animation

**Live report**: the Mini Soundbook favourite row's own progress fill (added in an earlier round) advances in visibly coarse steps, most noticeable on short sounds. Root cause: the row fill was driven directly off `PLAYBACK_PROGRESS_UPDATE`, which SoundPlayer.lua fires from its own deliberately-paced playback-status polling ticker (`POLL_INTERVAL = 0.08s`, ~12.5Hz) - a real cost tied to querying tracked-instance state, not something to simply run faster. At that cadence a short sound (e.g. under a second) only gets a handful of visible width updates over its whole lifetime, reading as discrete jumps rather than a glide.

**Fix (`Announcer.lua`)**: row progress is now driven by a small, independent, purely time-based ticker (`ROW_PROGRESS_TICK = 1/60`, ~60fps cadence) decoupled entirely from SoundPlayer.lua's own poll - it never calls into SoundPlayer.lua or any `C_Sound`/tracking API itself, so playback-status polling frequency is completely unaffected, exactly as required. The existing `PLAYBACK_PROGRESS_UPDATE` listener now additionally stores `row.playStartedAt`/`row.playDuration` straight from that same event's own `state.startedAt`/`state.duration` (still the single source of truth for timing - nothing about duration calculation or playback tracking changed) and starts the fast ticker on demand (`StartRowProgressTickerIfNeeded`). Each fast tick recomputes every visible row's own width purely from `(now - playStartedAt) / playDuration`, clamped `0..1`, linearly - the exact same formula `PLAYBACK_PROGRESS_UPDATE` itself already used, just sampled far more often, so there is no easing and no possibility of the two update paths disagreeing. The ticker is created lazily (only once a row actually starts playing) and stops itself the moment no row has active progress left (`AnyRowProgressActive`, checked both from its own tick and proactively from the `PLAYBACK_PROGRESS_ENDED` listener) - never an always-on background cost. `row.playStartedAt`/`row.playDuration` are cleared alongside the existing progress-fill reset on natural end, on an invalid/unknown duration, and on a pooled row being reassigned to a different sound (`PopulateFavMenu`), so a stopped or reused row can never keep animating with stale timing. Nothing about the Announcer banner's own progress ticker, the overlap markers, hover/click handling, the per-row gold border, or Mini Soundbook expand/collapse was touched.

**Tests**: a new `loader_rowprogress_smoothing.lua` covers: a new, genuinely fast (<=1/30s, confirmed ~60fps) ticker is created the moment a row starts playing, distinct from and faster than SoundPlayer.lua's own unchanged 0.08s poll ticker (verified via a new `ActiveMockTickerIntervals()` test-harness introspection helper added to `mock.lua`, comparing declared ticker intervals before/after rather than assuming any particular absolute ticker count, since triggering a sound legitimately starts other unrelated tickers too); progress on a very short (0.5s) sound is monotonic and linear (no easing) across several small time steps, matching `elapsed/duration` directly; both a short and a long (8s) sound still finish at exactly their own real duration, confirming duration calculation and playback tracking are untouched; and the fast ticker stops itself once both rows have finished, confirming it never runs idle. Full mock suite passes (the same two pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.0: Announcer Size resize UX - forced 100% opacity + live preview

**Task**: dragging the Announcer Size slider gave no clear sense of the real result - at a low configured opacity the icon barely showed the change, and with nothing playing there was no banner at all to resize, only the bare idle icon. Explicit request: force full opacity and show a live, real-layout preview while actively resizing, mirroring the Mini Soundbook Size slider's own existing forced-open preview (`StartMiniSizePreview`/`EndMiniSizePreview`) rather than inventing a second mechanism.

**Fix (`Announcer.lua`)**: `IsPreviewActive()` (the existing guard `RenderPrimary`/`CollapseToIdle` already check before repainting over a preview) now also considers a new, genuinely separate `announcerSizePreviewActive` flag alongside the existing `dragPreviewActive` - kept distinct rather than reused, since the Announcer Size slider has none of the icon-drag preview's easter-egg/`OnUpdate` machinery, even though the two interactions can never physically overlap. New `StartAnnouncerSizePreview`/`EndAnnouncerSizePreview`, hooked onto the Quick Options popup's `sizeSlider` `OnMouseDown`/`OnMouseUp` (the only place the Announcer Size slider currently lives with a forced-preview counterpart to mirror - Settings.lua's own copy of the slider has no such hook either, matching existing precedent) implement the two required behaviours:

- *Opacity*: `icon:SetAlpha(1)` (and `banner:SetAlpha(1)` as a harmless belt-and-braces) on mouse-down. On mouse-up, `SB:RefreshAnnouncerAlpha()` re-reads the persisted `alphaIdle`/`alphaHover` fresh - since nothing here ever writes to those fields, "restore the exact opacity active before resizing" falls out naturally rather than needing a manually-snapshotted value. This restore is skipped while `#activeDisplays > 0` (a real sound genuinely playing) - `RenderPrimary` already keeps the icon pinned to full opacity for as long as a real banner is showing (its own pre-existing, unrelated invariant), and calling `RefreshAnnouncerAlpha()` on top of that would incorrectly dim it back down mid-playback.
- *Preview*: only when nothing is really playing (`#activeDisplays == 0`) does `StartAnnouncerSizePreview` force the banner open, reusing `PopulatePreviewBanner()` - the exact same deterministic, real-layout content function the icon-drag preview already shares - so the preview shows genuine Announcer dimensions/layout, never a placeholder rectangle, and never plays a sound, touches history/analytics, or sends anything over the network. If a real sound IS already displayed, no second banner is created; the existing per-tick `SB:RefreshAnnouncerScale()` call (already wired to the slider's value-changed callback from an earlier round) simply keeps resizing the real one live. On release, `EndAnnouncerSizePreview` calls `RestoreRealAnnouncerState()` (the same cleanup `StopIconDragPreview` already uses) only if this interaction genuinely forced the banner open - a real sound already active is left completely alone, never torn down or duplicated.

**Tests**: a new `loader_announcersize_preview.lua` covers, at a saved 40% Idle Opacity: resizing with nothing playing forces the icon and preview banner to 100% opacity, shows the real `PopulatePreviewBanner` layout (not a placeholder), tracks the slider continuously (both icon and banner scale live at two different sample values), and on release restores the icon to exactly 40% again while the temporary preview disappears - with `SB.db.ui.announcer.alphaIdle` read back as exactly `40` throughout, confirming the saved setting itself is never overwritten, and the newly chosen `SB.db.ui.announcer.scale` persists correctly. A second scenario triggers a real sound, confirms resizing shows that same real `soundbookSoundID` throughout (no duplicate preview), confirms its progress fill keeps advancing normally during the resize (playback untouched), and confirms it remains visible and unchanged after the interaction ends. The existing `loader_popout.lua` scenario (`qm.sizeSlider:SetValue(150)` alone, without a mouse-down/up drag, must never touch the Announcer Preview) still passes unmodified, confirming the new preview is scoped strictly to the actual drag interaction. Full mock suite passes (the same two pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.0: Announcer Size preview - stop the menu/slider drifting, avoid overlapping the menu

**Live report**: dragging `Announcer Size` visibly moved the Quick Options menu (and the slider inside it) out from under the cursor while resizing, and the preview banner could render directly behind the menu instead of beside it.

**Root cause (menu drift)**: `quickMenu` is anchored LIVE to the icon's own edge (`SB.PositionRelativeToIcon(quickMenu, icon, direction)` - a real `SetPoint` relationship WoW re-resolves every frame). `SB:RefreshAnnouncerScale()` calls `icon:SetScale(scale)` on every slider value change, which moves the icon's own edges continuously - and since quickMenu's anchor tracks that edge live, the whole menu (everything inside it, the slider included) visibly slid along with the icon's growth/shrinkage, moving the very control the player was trying to hold the cursor on.

**Root cause (menu overlap)**: the preview banner's own `LayoutBanner()` anchors it to the icon using the exact same `SB.ResolvePopoutDirection(icon)` call quickMenu itself uses for its own anchor - both resolve to the same side, so the preview rendered directly behind/under the menu being used to resize it (masked by strata differences at some sizes, fully overlapping at others).

**Fix (`Announcer.lua`)**: `StartAnnouncerSizePreview` now calls a new `FreezeQuickMenuPosition()` before anything else - it reads quickMenu's own current on-screen rectangle and re-anchors it to a fixed `UIParent`-relative point instead of the live icon edge, so it (and every child inside it) stops tracking the icon entirely for the rest of the interaction. `SB:RefreshPopoutPositions()` (the Popout Direction dropdown's own live-reposition path) now skips quickMenu while frozen, so nothing can silently undo the freeze mid-drag. `EndAnnouncerSizePreview` calls the matching `UnfreezeQuickMenuPosition()`, which simply re-runs the normal `SB.PositionRelativeToIcon` call - nothing is persisted, so the very next time the menu opens (or Popout Direction changes) it behaves exactly as before. For the overlap, a new `LayoutAnnouncerPreviewDuringResize()` chains the banner off quickMenu's own OUTER edge (`SB.PositionRelativeToIcon(banner, quickMenu, direction)`) instead of the icon directly whenever quickMenu is open - the exact same "continue in the same direction, off the other popup's edge" pattern `StartMiniSizePreview` already established for favMenu-vs-quickMenu adjacency - so the preview sits beside the menu, never behind it, with the banner's existing `SetClampedToScreen(true)` keeping it fully on-screen even near an edge. This applies whether the banner shows fake preview content or a real, already-playing sound being resized live (`StartAnnouncerSizePreview`'s early-return branch), and `EndAnnouncerSizePreview` explicitly restores the real banner's normal icon-relative position via a plain `LayoutBanner()` call for that branch, since `RestoreRealAnnouncerState()` (which handles the forced-preview branch) is never reached when nothing was forced open in the first place. Neither the menu's temporary freeze nor the banner's temporary quickMenu-relative anchor touch strata (the menu was already `DIALOG`, above the banner's `MEDIUM`, so it was always the top interactive layer regardless of position) or any persisted setting - purely in-session frame state, gone the moment the interaction ends.

## Soundbook 3.0.1: fresh-install/UI fix round (New-tag, Dusty grace period, Intro, minimap hover, Mini Soundbook grid, output colours, Quick Options deep-link)

Seven independent reports against a clean Soundbook 3.0.1 client, taken together as one round.

**1. Fresh install marking the whole library "New" (`SoundRegistry.lua`)**: `SB:BackfillAddedAt`'s own first-run detection (`local isFirstRun = not SB.db.knownSoundIDs`) never actually fired, on any install - `Database.lua`'s `SanitizeDatabase` unconditionally pre-creates `db.knownSoundIDs` as `{}` (`EnsureTable`) before `BackfillAddedAt` ever runs, so the nil-check was always false. In practice this was invisible for an established install (their real `knownSoundIDs` from an earlier working session is already non-empty, so `EnsureTable` is a no-op and every currently-known sound is skipped exactly as before), but a genuinely fresh install has no prior session to have populated it - every bundled sound got treated as "not first run", stamped `addedAt = time()`, and the entire starter library showed as New on first login. Switched the check to `SB.isFreshInstall` - Core.lua's own already-established, reliable fresh-install signal, computed before `SanitizeDatabase` ever touches the db and already used for `introSeen`/`defaultOutputTarget`/`favShown`/`announcer.shown`. A fresh install's bundled library now stays legacy (no addedAt, no New tag); a sound appearing in ANY later session (a real content update) still gets stamped and shows New exactly as before, on both a fresh and an established install.

**2. Dusty needs a 7-day fresh-install grace period (`Core.lua`, `UI.lua`)**: fixing #1 exposed a second, previously-latent bug - `UI.lua`'s `ComputeDustySet` falls back to a `math.huge` "days since" sentinel for any addedAt-less sound (explicit prior design intent: "a sound never played by anyone at all is the single most obviously dusty thing possible"), which bypasses the `DUSTY_MIN_DAYS` age floor entirely. Once #1 correctly leaves a fresh install's whole library addedAt-less, every one of those sounds would have hit that sentinel and shown Dusty from the very first login. `Core.lua`'s existing `if SB.isFreshInstall then ... end` block (the same one stamping `introSeen`/`defaultOutputTarget`) now also stamps a new `SB.db.installedAt = time()` - never backfilled for an existing/upgrading install. `ComputeDustySet`'s sentinel branch now computes a real age from `SB.db.installedAt` when present (so the existing `DUSTY_MIN_DAYS` floor applies to these sounds too, same as any other candidate) and only falls back to the unchanged `math.huge` behaviour when it's absent - i.e. every existing established install, exactly as before. `DUSTY_MIN_DAYS` raised `3` -> `7` to match the requested grace window.

**3. Fresh-install Welcome Intro not reliably appearing (`Intro.lua`)**: extensive tracing of `introSeen`'s flag state and the `PLAYER_LOGIN` trigger's own call site found no logical fault - a standalone simulation confirmed both the flag and the `SB:ShowIntro()` call fire correctly in an isolated fresh-install sequence. The one real, precedented explanation already lives elsewhere in this codebase: `Announcer.lua`'s own icon had the identical "invisible right after login" bug fixed two rounds ago (see above) - a frame first `Show()`n before the client's loading-screen fade/UI transition has genuinely finished can end up logically shown but never actually painted, with nothing afterward forcing a redraw. The Intro popup's own trigger is a one-shot `C_Timer.After(2, ...)` off `PLAYER_LOGIN` with no such self-heal. Added the same fix Announcer.lua already uses: a `PLAYER_ENTERING_WORLD` listener (fires once the world is genuinely ready, on every zone/instance load) that re-shows the intro if it's still unseen and not already visibly open - guarded so it never reshows/resets a popup the player is mid-reading or has already closed, and never fights the existing 2-second fast path.

**4. Minimap icon hover graphic (`MinimapButton.lua`)**: the button's `HIGHLIGHT`-layer texture (`Interface\Minimap\UI-Minimap-ZoomButton-Highlight`, Blizzard's stock bright-blue zoom-button glow) was sized to 30x30 against a 31x31 button holding an 18x18 icon - on hover it visually dominated/swallowed the much smaller book icon, reading as the icon being replaced by a large blue ring. Shrunk to 22x22, centred directly on the icon (not the button), and tinted Soundbook's own gold accent (`Theme.GOLD`, `0.92/0.68/0.28`) at reduced alpha instead of Blizzard's default blue - now reads as a subtle glow behind the unchanged, still fully visible icon. Tooltip, click routing, and drag are untouched.

**5. Mini Soundbook favourite grid: content-driven responsive columns (`Announcer.lua`)**: `GetFavMenuColumns` previously only ever chose 2 or 3 columns, keyed purely off Mini Soundbook Size (`favScale >= 1.15 -> 3, else 2`) with count only ever escalating 2->3 for a tall list - never fewer than 2, so even a single Favourite reserved a full 2-column-wide, half-empty panel, and 3 Favourites at the 3-column breakpoint rendered as an oddly wide single row. Replaced with a purely content-driven preferred-column table (1-3 -> 1, 4-6 -> 2, 7-12 -> 3, 13-16 -> 4, 17-20 -> 5, the requested breakpoints exactly), then adapted DOWNWARD from that preferred count in two independent directions: a per-column minimum real (scale-corrected) width floor (`MIN_REAL_COL_W = 95`) reduces columns rather than letting cards shrink past usefully fitting an icon plus readable name text, and a maximum real total-grid-width ceiling (`MAX_REAL_GRID_W = 650`) reduces columns as Mini Soundbook Size grows, so a large scale now naturally favours fewer, wider columns instead of the popup ballooning in real screen size - reversing the previous (backwards) "bigger scale = more columns" relationship. Base per-column widths (`FAV_COL_W`) extended from the existing `{2, 3}` sizes to `{1, 2, 3, 4, 5}`, with the 1/2/3-column widths kept at their existing tuned values. The container's own width/height (`favMenu`, `favMenu.content`) already derived from `columns * colW` and the real row count before this change and continues to do so - fewer/narrower columns automatically mean a smaller popup with no separately-reserved space. Favourite persistence, slot identity, keybind mapping, drag/drop/reorder, and the 20-slot limit are all untouched - this is rendering-only, driven by the exact same already-computed `favourites`/`shown` values as before.

**6. Output target colours: "All" white, "Self" neutral grey (`Core.lua`, `UI.lua`)**: an earlier round (see "white All/Self Only target colour" above) merged "Self" into the same white `TARGET_WHITE` as "All" to address a "Self should not be grey" complaint. This round's explicit ask reverses half of that: "All" stays the only bright-white output target; "Self" - an active, selectable target, not a disabled one - goes back to its own neutral grey (`SB.CHANNEL_COLOR.SELF`, already used elsewhere for unrelated neutral UI like Settings' "General" tab colour), never white and never the dimmed/disabled look. `CHANNEL_COLOR_BY_LABEL.Self` now points at `SB.CHANNEL_COLOR.SELF` instead of `TARGET_WHITE` (Core.lua), so every `SB.GetChannelColor("Self")` consumer (the Announcer banner's sender/channel line, `History.lua`'s source colour, chat notifications) picks it up automatically. `UI.lua`'s Send-to dropdown got two matching fixes: the closed "Send to: Self" chip (`RefreshSendToLabel`) now explicitly colours itself from `SB.CHANNEL_COLOR.SELF` instead of falling through to the default white; and the open list's own "Self" row now carries `isActiveChannel` (recomputed on every list rebuild, same as every real channel bucket already does) so it gets the same "full colour while selected, 55%-dimmed while not" treatment Guild/Raid/Friends rows already have, instead of always rendering in a flat 55%-dimmed grey regardless of whether Self was actually the current selection. Guild/Raid/Friends/Party/Direct are completely unchanged.

**7. Quick Options "Open Settings" only opened the main window (`UI.lua`, `Announcer.lua`)**: the row fired `SB:Fire("TOGGLE_MAIN_UI")` - the same generic toggle the launcher icon's own left-click uses - which lands on whichever internal view (Library, Admin, Keybind mode) happened to be showing last, never Settings specifically, and required a second click once open. Added `SB:ShowSettingsView()` (`UI.lua`, alongside `ShowMainWindow`/`ShowDefaultSounds`, after `BuildMainFrame` is defined so it can build the window on a first-ever call) - builds the main window if it doesn't exist yet, then unconditionally sets the same `isSettingsOpen`/`isAdminOpen`/`isKeybindModeOpen` mutual-exclusion state `ToggleSettings`'s own "opening" branch already uses, and shows the window. Since it always LANDS on Settings rather than toggling relative to prior state, it correctly covers both "closed -> open directly on Settings" and "open on another tab -> switch to Settings" in the one call. The Quick Options row now calls `SB:ShowSettingsView()` instead of firing `TOGGLE_MAIN_UI` - no new Settings UI, purely reusing the existing navigation/mutual-exclusion state.

**Tests**: a new `loader_freshinstall.lua` covers item 1 end-to-end - a fresh install's registry stays fully addedAt-less/non-New; a sound appearing in a later session still becomes properly New; and, separately, a realistic established install (its `knownSoundIDs` pre-populated with every currently-known sound, as any real prior session would leave it) stays completely unaffected by the fix, with a genuinely new sound on that install still becoming New too. A new `loader_dustygrace.lua` covers item 2 - confirms `DUSTY_MIN_DAYS` reads as 7 from the live source, confirms `installedAt` is wired inside Core.lua's fresh-install block specifically, replicates the sentinel-branch grace-period arithmetic at 0/6/8 days past install (inside vs. outside the window) and at no-`installedAt` (unchanged `math.huge`), and confirms `installedAt` survives `PrepareDatabase`/`SanitizeDatabase` unmodified on an existing install. `loader_favgrid.lua` rewritten for item 5's new column table - all of 1/3/4/6/8/12/16/20 favourites at default scale match their spec'd preferred column count exactly, 3 favourites confirmed to render as a genuine single vertical column (max column x-offset 0), and 20 favourites confirmed to use fewer columns at both a small and a large Mini Soundbook Size than at the normal default. A new `loader_outputcolors.lua` covers item 6 - "All" resolves to exact bright white, "Self" resolves to `SB.CHANNEL_COLOR.SELF` exactly (visually distinct from "All", confirmed near-equal r/g/b so it reads as neutral grey rather than any tinted colour), and Guild/Raid/Friends/Direct are confirmed byte-identical to their existing hex values. A new `loader_settings_deeplink.lua` covers item 7 - `SB:ShowSettingsView` exists, succeeds from a fully-closed Soundbook (and actually shows the window), and succeeds again when called while already open on the Library tab. Three pre-existing, unrelated mock-suite failures reconfirmed present on the unmodified base commit (`loader_minititle.lua`, `loader_settings.lua`, and a previously-unlisted `loader.lua` 3-column main-grid-width assertion - all three verified via `git stash` to fail identically before this round's changes too, so none are new regressions); every other test, including three existing files whose fixtures depended on the old fixed 2/3-column favourite grid or the old white-Self colour (`loader_banner_layout.lua`, `loader_mini_title_names.lua`, `loader_minisurfaces.lua`) and were updated to match the new intended behaviour rather than the old one, passes. `luac -p` clean across every `Soundbook.toc`-listed file.

Item 3 (the Intro fix) is a best-effort defensive hardening applied by direct analogy to an already-confirmed, already-fixed identical bug class in this same codebase (Announcer.lua's icon) - no distinct logic fault was found in isolated simulation, so please confirm after retesting whether the intro now reliably appears on a genuinely fresh install.

**Tests**: `loader_announcersize_preview.lua` gained two new scenarios - one drives the slider through several different values mid-drag and asserts quickMenu's frozen anchor point (`relTo == UIParent`, fixed x/y) never changes across any of them, and that releasing the slider restores its normal `relTo == icon` anchor with the temporary point gone entirely; the other opens Quick Options and asserts the banner's own anchor `relTo` is `quickMenu`, not the icon, confirming the collision-avoidance path is actually exercised. Full mock suite (including the existing `loader_popout.lua` positioning coverage) passes unmodified (the same two pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.1: fresh-install New/Dusty round 2 - community-analytics bypass, leftover-data cleanup, deterministic popup priority

Live report: the previous round's New-tag/Dusty/Intro/New-Sounds-popup fixes still showed wrong behaviour on a re-test. Two real, previously-missed gaps were found on a fresh, skeptical re-audit; a third, very likely explanation for the report itself was also confirmed and needs the user's own action, not a code fix.

**Real gap 1 - community analytics bypassing the local 7-day Dusty gate (`UI.lua`)**: round 1's `installedAt`-based grace period only guarded `ComputeDustySet`'s addedAt-less SENTINEL branch (`m.plays == 0`). `SB.Analytics_SoundMetrics(soundID, "all")` aggregates usage across every OBSERVED NODE community-wide (`Analytics.lua`'s `records[soundID][nodeID]`, "all" is a time filter - 48h/7d/30d play counts per node - not a local-vs-community scope), not just this local install - a bundled sound other players have used for months already has `m.plays > 0` and an old real `m.lastUsed` the moment a brand-new install's very first analytics sync arrives, taking the FIRST branch and computing `daysSince` straight from that old community timestamp, completely bypassing `installedAt`. Fixed by computing a local `knownDays` (from a real `addedAt`, else `installedAt`, else `nil` for an established install's untouched originals - unchanged behaviour) as an unconditional gate BEFORE either branch runs: `if not knownDays or knownDays >= DUSTY_MIN_DAYS then` - only once THIS installation has known the sound for at least 7 days does community data (or the addedAt/installedAt fallback) get to decide daysSince at all. A new `SB.IsSoundDusty(soundID)` accessor (thin wrapper around the otherwise module-local `GetDustySet`/`GetDustySetPrivate`) was added purely so this could be tested end-to-end against the real function instead of a re-implemented formula.

**Real gap 2 - leftover corrupted SavedVariables from testing round 1's OWN still-broken interim build (`Core.lua`)**: `SoundbookDB` is account-wide (`## SavedVariables: SoundbookDB` in the TOC, not per-character) - any test session that ran an earlier, still-broken build already persisted its entire-library-marked-New bug into real SavedVariables that then carries forward into every later login on that account, "fresh" character or not, until `NEW_TAG_DAYS` (48h) naturally expires it. A new one-time correction, same shape and same PLAYER_LOGIN-time spot as the three existing historical addedAt fixups (`privateLegacyFixApplied`/`companionAddedAtFixApplied`/`knownSoundsFix250Applied`), extracted as `SB:FixMassNewTagBugOnce()` (called from Core.lua's PLAYER_LOGIN handler, exposed so tests can call it directly without needing to fire native WoW events through the private init frame): if more than half of the ENTIRE currently-registered library is presently New at once - the unmistakable fingerprint of one mass-BackfillAddedAt-run bug, since a real content update only ever adds a small handful of sounds, never a majority of the whole registry - clears `addedAt` back to legacy for exactly that set, once, ever (`SB.db.massNewTagBugFixApplied`). A normal handful of genuinely recent additions on an established install is always far below that threshold and is left completely untouched.

**Hardening - deterministic fresh-install-wins popup priority (`NewSoundsWindow.lua`)**: static tracing again found the existing `introSeen`-only guard logically correct (Core.lua sets `introSeen = false` before `PLAYER_LOGIN` fires on a fresh install, so the New Sounds popup's own synchronous check already returned early in every traced scenario) - but per the explicit requirement ("fresh install must win over any New Sounds detection during that login, deterministically") a second, direct `if SB.isFreshInstall then return end` guard was added alongside the existing `introSeen` check, both at the synchronous PLAYER_LOGIN entry and inside the delayed `C_Timer.After(3, ...)` callback - belt-and-braces against the indirect signal ever being defeated by a future change, not evidence of an actual found bug in this specific path.

**Not a code bug - explained to the user**: `SoundbookDB` being account-wide (confirmed above) means testing on a new/different character is NOT a fresh install from Soundbook's own perspective once any earlier session on that account has run - this is almost certainly why a "fresh" re-test still showed round 1's leftover state. Real gap 2's corrective migration cleans up exactly this for anyone already carrying that leftover data forward; a genuinely clean test still requires deleting `WTF/Account/<account>/SavedVariables/Soundbook.lua` first, exactly as this round's own Verify step 1 asks for.

**Tests**: `loader_dustygrace.lua` gained an end-to-end section (not a re-implemented formula) that seeds a fake community analytics record with 30-day-old heavy usage on a real, isolated (competition-neutralised via a temporary `Analytics_IsHealthEligible` override) soundID and confirms `SB.IsSoundDusty` stays `false` on a fresh install's first login despite that old community data, then confirms it correctly becomes `true` once the local install has known the sound for >= 7 days (with `AdvanceMockTime` used to clear the Dusty-set's own 5s cache between the two reads). `loader_freshinstall.lua` gained a section simulating the exact "tester upgraded from the broken pre-fix build" scenario: manually stamps the entire registry `addedAt` (reproducing round 1's OWN bug's output) via the real `SB:GetSoundSaved`, confirms `SB:FixMassNewTagBugOnce()` clears all of it back to legacy, confirms a second call is a no-op that never touches a genuinely new sound added afterward, and confirms a normal established install with only 2 genuinely recent sounds is never touched by the same migration. A new `loader_firstrun_popups.lua` covers the full popup-priority matrix end-to-end (wrapping the real `SB.ShowIntro`/`SB.ShowNewSoundsWindow` to count real invocations, `FlushMockTimers()` to resolve both delayed triggers): a fresh install shows Intro exactly once and the New Sounds popup zero times; a second login without an update reopens neither automatically; and a returning, `introSeen`-true install with one genuinely new sound shows the New Sounds popup (not Intro). Full mock suite passes (the same three pre-existing, unrelated failures - `loader_minititle.lua`, `loader_settings.lua`, `loader.lua` - aside); `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.1: fresh-install round 3 - real end-to-end init-dispatch verification (no further code changes)

Live report: still broken after round 2. Every test up to this point (including round 2's) hand-simulates what Core.lua's `ADDON_LOADED`/`PLAYER_LOGIN` handler is SUPPOSED to do (`SB.isFreshInstall = true`, `SB.db.installedAt = time()`, ...) and then fires `SB:Fire("DB_READY"/"PLAYER_LOGIN")` directly - none of them ever actually exercised Core.lua's own real native-event dispatch end to end. A bug specifically in that dispatch itself (wrong order, a value read too early, something clobbered in between) would have been invisible to every test so far, hand-simulation quietly papering over exactly the class of bug being reported.

**Mock harness upgrade (`mock.lua`, test infra only, not shipped)**: `RegisterEvent` was previously a no-op; it now records which events a frame registered. A new `FindFrameByRegisteredEvent(eventName)` locates Core.lua's own unnamed, otherwise-unreachable native-event dispatcher frame (`initFrame`, a plain local with no `_G` name) by the fact that it's the one that called `RegisterEvent("ADDON_LOADED")`. A test can now grab its real `OnEvent` script and drive `ADDON_LOADED`/`PLAYER_LOGIN` through the EXACT SAME code path the real game client uses, with zero hand-simulated side effects.

**New `loader_real_init_sequence.lua`**, run against the current, unmodified round-2 source (no code changes made this round), fires that real dispatch with `_G.SoundbookDB = nil` (a truly empty SavedVariables) and confirms, against the real functions throughout: `SB.isFreshInstall == true` immediately after the real `ADDON_LOADED`; `SB.db.settings.introSeen ~= true` before `PLAYER_LOGIN`; `SB.db.installedAt` is stamped; after the real `PLAYER_LOGIN` and `FlushMockTimers()`, baseline New count = 0 and baseline Dusty count = 0 across the entire real registry (via `SB:IsSoundNew`/`SB.IsSoundDusty`); the real `SB.ShowIntro` fires exactly once; the real `SB.ShowNewSoundsWindow` never fires. A second real dispatch (simulating a reload with the player having actually closed the Intro) confirms `SB.isFreshInstall` correctly reads `false` and neither popup reopens. A third section walks `SB.db.installedAt` from 6 days old (Dusty count must stay 0) to 8 days old (a sound with real old community usage can become Dusty again, through the real gate). A fourth section re-fires the real dispatch on an established install (`_G.SoundbookDB` now set) with one genuinely new sound added to the registry: only that sound is New, no pre-existing sound is wrongly marked New, the new sound is not yet Dusty-eligible, and the New Sounds popup (not Intro) fires exactly once.

**Result: every scenario in the user's own spec passes against the real, already-shipped code with no further source changes.** This is the strongest evidence available in this environment (short of an actual WoW client) that the fresh-install initialization order, New/Dusty classification, and Intro/New-Sounds popup priority are all correct end-to-end. Round 2's own diagnosis - that `SoundbookDB` is account-wide and a test session that ever ran round 1's still-broken interim build leaves real leftover data behind until either 48h pass or `Soundbook.lua` is deleted - remains the most likely explanation for what's still being observed live; round 2's `SB:FixMassNewTagBugOnce()` cleans that up automatically going forward, but a genuinely from-scratch verification still needs `WTF/Account/<account>/SavedVariables/Soundbook.lua` deleted first. No WoW client is available in this environment to verify beyond this point.

**Tests**: `loader_real_init_sequence.lua` (new, described above). Full mock suite passes (the same three pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file. No `Soundbook.toc`-listed source file changed this round - only `mock.lua` (test infrastructure, not part of the shipped addon).

## Soundbook 3.0.1: minimap button UX - icon alignment root cause, top-of-minimap default, tooltip vs. Mini Soundbook overlap

Live report (with screenshot): the minimap icon was STILL visually broken after the earlier hover-highlight fix, and, separately, the minimap button's fresh-install default position needed to move to the top of the minimap, which then made its tooltip overlap the Mini Soundbook.

**1. Root cause of the persisting icon visual (`MinimapButton.lua`)**: the earlier round only shrank/tinted the hover HIGHLIGHT texture - the real fault was the icon/border PAIRING itself. `Interface\Minimap\MiniMap-TrackingBorder` is a 54x54 ring sprite anchored at the button's own `TOPLEFT` (extending well past the 31x31 button on two sides) - its artwork assumes a specific icon inset, the same one virtually every minimap-button addon (LibDBIcon and its many consumers) uses. This file instead centred an 18x18 icon on the raw 31x31 BUTTON (`SetPoint("CENTER")`), which is a different point than the ring sprite's own visual centre - the icon and the ring's actual "hole" never lined up, so part of the ring's own dark inner shading sat over the book artwork on every state (idle included), reading as a dark/blue circular overlay "replacing" the icon. Fixed by using the exact standard offset that sprite was authored for: icon now 20x20, anchored `TOPLEFT(7, -6)`, landing correctly inside the ring's real hole. The hover highlight (already shrunk/gold-tinted from the previous round) now anchors off the CORRECTLY-positioned icon and stays a subtle glow. A new pressed state was added (`OnMouseDown`/`OnMouseUp` dimming the icon's own alpha to 0.7, never a second texture layered on top) so every required state - idle, hover, pressed - keeps the book artwork visible and never gets covered by anything.

**2. Fresh-install minimap position: top of the minimap (`Core.lua`)**: `GetDefaultDB()`'s `ui.minimap.angle` default changed `215 -> 90` (`MinimapButton.lua`'s `UpdatePosition`: `cos(90)=0, sin(90)=1` -> straight up from the minimap's centre, the minimap's own 12 o'clock). Safe for existing installs by construction, not by a new fresh-install-only branch: `Database.lua`'s `SanitizeDatabase` already runs `ui.minimap.angle = ClampNumber(ui.minimap.angle, defaults.ui.minimap.angle, 0, 360)` on every login, and `ClampNumber` only ever substitutes the fallback when the existing value isn't already a real number - an established install's angle (from a manual drag, or simply already persisted at the old 215 default from any earlier login under this exact mechanism) is a real number by the time this fix ships, so `ClampNumber` keeps it untouched. Only an install with no persisted angle yet - a genuine first login - ever picks up the new default.

**3. Fresh-install Mini Soundbook position: top-centre of the screen (`Core.lua`)**: `GetDefaultDB()`'s `ui.announcer.pos` default changed from `{TOPRIGHT, TOPRIGHT, -60, -80}` (the screen's top-right corner - the same corner Blizzard's own default Minimap normally occupies, which is very likely why the top-of-minimap change in #2 started colliding with it) to `{TOP, TOP, 0, -80}` (centred under `UIParent`'s own top edge). Same `ClampNumber`-style preservation as #2 (`Database.lua`'s `SanitizePosition`, already existing) - an established install's own saved or dragged position is never moved.

**4. Tooltip no longer overlaps the Mini Soundbook (`MinimapButton.lua`)**: the tooltip's fixed `ANCHOR_LEFT` is replaced by a new `ResolveTooltipAnchor` that, only when the Announcer icon (`_G.SoundbookAnnouncerIcon`) actually exists and is shown, compares its real on-screen centre against the minimap button's own (both scale-corrected into `UIParent`'s coordinate space first, same pattern `SB.ResolvePopoutDirection` already uses elsewhere for an analogous problem) and picks whichever tooltip anchor (`ANCHOR_LEFT`/`RIGHT`/`TOP`/`BOTTOM`) points AWAY from it along whichever axis separates them more. Falls back to the original `ANCHOR_LEFT` whenever the Announcer icon doesn't exist yet, isn't shown, or its position can't be read - no behaviour change in the case nothing needs avoiding. The Mini Soundbook itself is never moved to make room - only the tooltip's own anchor adapts. Tooltip text content is unchanged.

**Mock harness fix (`mock.lua`, test infra only)**: `SetPoint(point, x, y)` - WoW's common 3-argument numeric shorthand for "anchor to my parent's same point with this offset," used by the new icon anchor above - was silently mishandled (the mock only ever modeled the full 5-argument form, so the numeric `x`/`y` landed in the `relTo`/`relPoint` slots and the real offsets were lost). Now detects a number in the second argument and resolves it as the shorthand form correctly.

**Tests**: a new `loader_minimap.lua` drives the real `ADDON_LOADED`/`PLAYER_LOGIN` dispatch (same technique as `loader_real_init_sequence.lua`) end-to-end: confirms a fresh install's `ui.minimap.angle` is exactly `90` and the real minimap button's resolved `CENTER` offset is `(0, 80)` (straight up); confirms `ui.announcer.pos` is exactly `TOP/TOP/0/-80`; confirms the icon's real size/anchor (`20x20` at `TOPLEFT(7,-6)`); confirms an established install's own custom angle (`260`) and Mini Soundbook position (`BOTTOMLEFT/40/40`) both survive a real dispatch completely untouched; and drives the real `OnEnter` handler (capturing `GameTooltip:SetOwner`'s anchor argument) across four cases - no Announcer icon, Announcer directly above, Announcer to the left, and Announcer present-but-hidden - confirming the tooltip anchor always points away from a visible Announcer icon and falls back to the original anchor otherwise. Full mock suite passes (the same three pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file.

**Version bump**: `Soundbook.toc`'s `## Version` had stayed pinned at `3.0.0` through every one of this line's rounds so far (an earlier round deliberately re-aligned it to match README's own "3.0 redesign line" heading), making it impossible to visually confirm in-game which build was actually loaded. Bumped to `3.0.1` - the one field `SB.VERSION`/`/sb doctor`'s version line actually reads from.

## Soundbook 3.0.1: minimap button visuals - drop every Blizzard minimap-button sprite entirely

Live report, with screenshot: after the icon/border realignment fix, the book icon was STILL being visually swallowed by a large circular overlay (screenshot showed it distinctly cyan, not any colour this file's own code ever set) - confirmed the player was genuinely running the 3.0.1 build (`/sb doctor`), ruling out a stale-install explanation.

**Root cause, finally isolated**: two straight rounds tried to tame Blizzard's own minimap-button art piece by piece - first the `UI-Minimap-ZoomButton-Highlight` hover texture (shrink + gold-tint), then `MiniMap-TrackingBorder`'s icon-inset alignment (the standard LibDBIcon offset) - and the book icon was still being visually replaced. The screenshot's cyan colour doesn't match anything either fix ever set, which means the overlay was never actually the (hover-only) highlight texture at all - it's `MiniMap-TrackingBorder` itself, an always-visible OVERLAY-layer texture this file never tinted or otherwise modified, whose own native rendered appearance can't be previewed in this sandboxed environment (no WoW client available). Two rounds of tuning its icon ALIGNMENT never had a chance of fixing this, because the alignment was never the actual problem - the texture's own colour/shape was.

**Fix (`MinimapButton.lua`)**: every Blizzard minimap-button sprite is dropped entirely - `MiniMap-TrackingBorder` and `UI-Minimap-ZoomButton-Highlight` are both gone, along with any assumption about what they render as. Replaced with plain, flat, fully self-controlled primitives that can never surprise: the button (now built via `SB.CreateFrame`, which already carries `BackdropTemplate`) gets a thin 1.5px gold `SetBackdrop` ring around its own edge with a fully transparent (`alpha 0`) fill, so nothing but a hairline border ever appears around the icon; the icon itself is centred at 20x20 with the same icon-padding texcoord crop (`0.08-0.92`) Theme.lua's own icon slots already use elsewhere in the addon; and the hover highlight is a plain `WHITE8X8` texture across the whole button, additively blended at a low 0.35 alpha and tinted gold - a soft glow wash, never a separate shaped graphic that could read as "replacing" the icon. Every colour and shape on this button is now something this file explicitly sets, not inherited from an unpredictable Blizzard asset - by construction, there is no art asset left that could ever again render as a large dark/blue/cyan circle over the icon.

**Tests**: `loader_minimap.lua` updated for the new visuals - confirms the icon is centred (not the old TOPLEFT ring-alignment offset, no longer relevant since the ring is gone), confirms it shows the real `SB.APP_ICON` texture, and confirms the highlight texture is the plain `WHITE8X8` this file controls rather than any named Blizzard sprite (a regression guard against ever silently reintroducing one). Full mock suite passes (the same three pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file. No WoW client is available in this environment, so the actual on-screen result still needs the user's own live confirmation - but every remaining visual element is now something explicitly authored here rather than borrowed Blizzard art whose rendered appearance couldn't be verified.

## Soundbook 3.0.1: minimap round 4 - restore round icon look, favMenu-aware tooltip, Announcer preview stacking, Quick Options naming

Live report, with screenshot: the icon now looked like a plain square, not round like other addons; the tooltip still overlapped the Mini Soundbook; opening Quick Options from inside the Main Soundbook and resizing Announcer Size showed the preview BEHIND Main instead of in front of it; and the Main toolbar's "Quick Audio" button/tooltip should read "Quick Options" (it opens that exact same menu everywhere else in the addon).

**1. Icon round again (`MinimapButton.lua`)**: round 3's flat self-controlled square backdrop genuinely fixed the earlier dark/cyan overlay report (no longer mentioned), but a `SetBackdrop` border is always rectangular - there is no way to get the familiar round minimap-button look without SOME round graphic, and `SetMask` isn't reliably available across every client this addon targets (Classic Era included). Restored the exact, extremely well-tested LibDBIcon-standard layering instead of this file's own earlier hand-rolled version: `MiniMap-TrackingBorder` (53x53, `TOPLEFT(0,0)`, OVERLAY layer - its own opaque ring visually crops a square icon's corners into the familiar round look) with the icon at the precise offset that art expects (20x20, `TOPLEFT(7,-5)`, BACKGROUND layer, plus the same dark `UI-Minimap-Background` padding layer LibDBIcon itself uses underneath it), and the hover highlight via Blizzard's own `SetHighlightTexture` (shown only on mouseover, sized to the button automatically) instead of a manually created/resized/tinted texture. The earlier dark/cyan overlay report is now understood to have most likely come from this file's OWN earlier hand-rolled highlight handling (manual sizing/anchoring against an, at the time, still-misaligned icon), not from these sprites' own native rendering - using the textures via their standard, proven API/offsets removes that class of bug entirely.

**2. Tooltip vs. Mini Soundbook, corrected target (`MinimapButton.lua`)**: round 3's `ResolveTooltipAnchor` only ever compared against the idle Announcer ICON's position - but "the Mini Soundbook" the report actually means is the EXPANDED favourites popup (`SoundbookFavMenu`, Announcer.lua's `favMenu`), a separate, often larger and differently-positioned frame once open. Now prefers `_G.SoundbookFavMenu` whenever it's shown (falling back to the idle icon otherwise, and to the original fixed anchor when neither is shown) before running the same scale-corrected, farthest-axis comparison as before.

**3. Announcer preview hidden behind Main Soundbook (`Announcer.lua`)**: root cause - the banner's own strata is a plain `"MEDIUM"` always, while the Main Soundbook window (`UI.lua`) is `"HIGH"`, a strictly higher WoW stacking tier - Main always won regardless of frame level or creation order, so opening Quick Options from Main's own toolbar and dragging Announcer Size hid the very preview meant to show the result. `StartAnnouncerSizePreview` now bumps the banner to `"DIALOG"` (matching `quickMenu`'s own strata, so both stay in the same tier) for the duration of the preview only, calling the already-idempotent `BuildBanner()` first so this applies even on the very first preview of a session; `EndAnnouncerSizePreview` restores it back to `"MEDIUM"` - real, non-preview playback has no reason to ever outrank Main.

**4. "Quick Audio" -> "Quick Options" (`UI.lua`, `README.md`)**: the Main Soundbook toolbar's audio-glyph button opens `SB.ShowAnnouncerQuickOptions` - the exact same menu the Announcer icon's own Shift+Right-click, and every comment/reference elsewhere in the addon, calls "Quick Options". Its tooltip title is corrected to match; `README.md`'s own toolbar list updated the same way.

## Soundbook 3.0.1: Mini Soundbook favourite grid - genuinely responsive redesign

Explicit follow-up task: the previous grid round's column-count table only ever keyed off favourite COUNT, never off the real available width/height a large Mini Soundbook Size actually has - at maximum size, 20 favourites could still collapse into a single, enormous vertical column covering most of the screen.

**Root cause of the old design's ceiling**: `PreferredColumnsForCount` alone decided columns; Mini Soundbook Size (`favScale`) could only ever narrow that count further (a floor check against a fixed per-column pixel width), never widen it - so a big Mini Soundbook with many favourites had no way to use its own extra space for more columns, only for taller rows within the same column count.

**Fix (`Announcer.lua`)**: `GetFavMenuLayout(count)` now derives columns, card width AND card height (row height) together, in "1x" reference units (the whole `favMenu` frame's own independent `SetScale` from `favScale` still multiplies everything out uniformly at render time, unchanged). Card width comes from a per-column-count table, `FAV_COL_W = {190, 150, 125, 110, 100}` for 1-5 columns - hand-verified so each column count's REAL (post-`favScale`) width clears the `MIN_REAL_COL_W` (95) legibility floor at smoothly graduated thresholds across the full 0.5-2.0 `favScale` slider range (col=5 needs `scale>=0.95`, col=4>=`0.864`, col=3>=`0.76`, col=2>=`0.633`, col=1>=`0.5`, the slider's own minimum) - no early cliff where the whole grid suddenly collapses. An earlier attempt derived width strictly as `rowHeight * 2.5` (the middle of the requested 2.0-3.0:1 "sound card" aspect range) but this was mathematically broken: `ROW_H_MAX * 2.5 = 90`, LESS than the 95px legibility floor, so `colW` clamped to a constant 95 for every column count and the aspect-driven variation never actually took effect - caught via hand-calculation across the count/scale verify matrix before it was ever tested, not from a failing test. Row height stays independently derived from a soft total-height budget divided by row count (`GRID_SOFT_H / rows`, clamped `ROW_H_MIN`/`ROW_H_MAX` = 22/36) - fewer rows read taller and more legible, many rows shrink back down - and the icon size scales with row height (`ICON_MIN`/`ICON_MAX` = 16/30), so a tall card never looks like an oversized button and a short one never loses its icon.

Column selection itself starts from `PreferredColumnsForCount` (purely content-driven: 1-3->1, 4-6->2, 7-12->3, 13-16->4, 17-20->5 - satisfying the explicit ">=7 favourites needs >=2 columns" and ">=13 needs >=3 columns" requirements by construction whenever width allows), then a one-directional escalate pass adds columns when the resulting row count would exceed `ROWS_SOFT_MAX` (6) and the next candidate's real width still clears the legibility floor, followed by a one-directional reduce pass that removes columns whenever the current real width has dropped below the floor. Escalation only ever adds columns, reduction only ever removes them - the two passes can never fight each other into an oscillation, and the same `(count, favScale)` input always resolves to the identical layout (deterministic, no per-call state).

At normal (1.0) Mini Soundbook Size this now spans the full range smoothly: 1/3 favourites stay 1 column, 4/6 become 2, 8/12 become 3, 16 becomes 4, 20 becomes 5 (4 rows) - never a single tall column. At maximum size (`favScale = 2.0`), 20 favourites still resolves to 5 columns (real card width ~200px, comfortably legible) - the explicit regression target. At minimum size (`favScale = 0.5`), the real-width floor collapses everything back to 1 column regardless of count, which is the intended, explicitly-allowed exception ("do not impose [multi-column] as rigid layouts if the window genuinely cannot support them") - a genuinely narrow Mini Soundbook cannot fit a legible 2-column grid.

**`BuildFavMenu`'s initial placeholder width** now references `FAV_COL_W[2]` instead of the old table's now-removed literal - purely a pre-first-populate sane default, immediately overwritten by the real layout on the first `PopulateFavMenu`.

**Preserved unchanged**: the 20 logical favourite slots, slot identity, saved-slot gaps, keybind-to-slot mapping, drag/drop/swap/drag-away-removal, hover/playing/progress visual states, lock behaviour, and saved Mini Soundbook size/position - `PopulateFavMenu`'s own slot-iteration loop (which decouples "visual grid position" from "logical slot number") was not touched, only the column/card-size decision feeding its per-row `SetSize`/`SetPoint` calls.

**Tests**: `loader_favgrid.lua` rewritten for the new `GetFavMenuLayout`-driven API (the old `GetFavMenuColumns`/fixed-count-only table it exercised no longer exists) - covers the task's own verify counts (1, 3, 4, 8, 12, 16, 20) at normal scale against the new per-column-count widths; explicitly confirms 20 favourites at maximum (`2.0`) Mini Soundbook Size resolves to more than 1 column; confirms `>=7` favourites (8) get at least 2 columns and `>=13` favourites (16) get at least 3 columns whenever width allows; confirms repeated `ShowFavMenu` calls at an unchanged `(count, favScale)` always produce byte-identical widths (resize-oscillation-stability guard); and replaces the old (now-inverted) "larger scale must reduce columns" assertion with the new, correct "columns are non-decreasing as Mini Soundbook Size grows" requirement. `loader_minisurfaces.lua`'s own hardcoded "3-column layout" sanity width (previously `488`, the old table's 3-column value) updated to the new table's `383` - a stale expectation from the old widths, not a functional regression. Full mock suite passes (the same three pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file. No WoW client is available in this environment - card proportions/text truncation/icon scaling were verified via the layout math and mock frame geometry, not a live rendered screenshot, so live in-game confirmation across the requested size range (minimum/narrow, medium, large square, maximum/tall, wide landscape) is still needed.

**Tests**: `loader_minimap.lua` updated - icon/border/highlight assertions now check the restored standard offsets and the real Blizzard texture paths (via the mock's own now-argument-aware `SetHighlightTexture`), and a new case confirms `SoundbookFavMenu` takes priority over the idle icon when both are shown (fake favMenu positioned opposite the fake icon; the tooltip anchor must follow favMenu, not the icon). `loader_announcersize_preview.lua` gained two strata assertions - `DIALOG` during an active resize, `MEDIUM` again once it ends - covering both the "nothing playing" and (implicitly, via the shared code path) "real sound playing" preview branches. Full mock suite passes (the same three pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file.

## Soundbook 3.0.3: New Sounds window gets direct Favourite management

New task, version bump 3.0.1 -> 3.0.3: every row in the New Sounds window gets an `Add Favourite`/`Remove Favourite` button, and clicking it while all 20 Favourite slots are already occupied opens a new "Favourites are full" modal with a 5x4 replacement grid instead of only reporting the failure to chat.

**Data layer (`Favorites.lua`)**: one new function, `SB:ReplaceFavourite(slot, soundID)` - swaps the sound stored in an already-occupied slot for a different one, updates both sounds' `saved.favourite`/analytics flags, and fires the existing `FAVOURITES_CHANGED` event, same as `AddFavourite`/`RemoveFavourite` already do. It never touches the slot's own keybind - keybinds are stored keyed by SLOT NUMBER in `Keybindings.lua`'s `SB.db.settings.favKeybinds`, entirely independent of which sound occupies that slot, so "the keybind survives a replacement" is true by construction, not something this function has to do anything special for. `AddFavourite`/`RemoveFavourite`/`MoveFavourite` are all unchanged - this is a pure addition, and the existing 20-slot/gap/no-compaction semantics they already implement are exactly what the new button reuses.

**New Sounds row button (`NewSoundsWindow.lua`)**: each pooled row gets a `Theme.CreateFlatButton` ("Add Favourite"/"Remove Favourite", the same flat-button chrome every other Soundbook button already uses - no new visual style) anchored `RIGHT, -8, 0` for consistent right padding; the sound-name text's own `RIGHT` anchor moved from the row edge to the button's `LEFT` edge so long names truncate against the button instead of running under it. The button is a real child `Button` sitting on top of `row` (itself a clickable `Button`) - the same "control on top of a clickable row never triggers the row's own click" pattern `UI.lua`'s section-header `Keybinds` button already relies on - so it can never accidentally trigger the row's SELF-only preview underneath it, and vice versa. Its own `OnClick` only ever calls `SB:IsFavourite`/`SB:RemoveFavourite`/`SB:GetFavouriteCount`/`SB:AddFavourite`/`SB:ShowReplaceFavouriteWindow` - never `SB:TriggerSound` or `SB:PlaySound`. The "Favourites full" check happens BEFORE ever calling `SB:AddFavourite` (which would otherwise only print to chat and return `false, "full"`), so the Replace Favourite modal is the real, primary path for that case - the existing chat message is simply never reached from this button at all. A new `SB:On("FAVOURITES_CHANGED", ...)` handler refreshes every visible row's OWN button label (not the list itself - New Sounds membership never depends on Favourite status) whenever Favourites change from ANY source while the window is open, so a replacement's displaced sound (if it also happens to be in New Sounds) flips back to "Add Favourite" immediately, with no reopen needed.

**Replace Favourite modal (new file, `ReplaceFavouriteWindow.lua`)**: a `DIALOG`-strata modal, opened above the New Sounds window using the exact same "same strata, frame level computed from the other window's own CURRENT level + 10, not a fixed guess" pattern `IconPicker.lua` already uses to open above Edit Sound, centred on `SoundbookNewSoundsWindow`. Title "Favourites are full", subtitle "Choose a Favourite to replace with:", the selected (new) sound's own icon+name line, then a fixed 5x4 grid (never virtualized/scrolled - only ever 20 cells) in exact slot order 1-20 left-to-right, top-to-bottom. Each cell shows the slot's icon, its slot number, and its keybind label (via the existing `SB:GetFavouriteHotkeyLabel`) only if one is set; hovering shows a tooltip with "Slot N", the slot's current sound name, and a "Keybind: X" line when bound. Clicking a cell calls `SB:ReplaceFavourite(slot, pendingSoundID)` and closes the window immediately - explicit requirement, "selecting the slot IS the confirmation," no second confirm step. A full-screen click-blocker (same construction as `EditWindow.lua`'s own `modalBlocker`) sits just below the window itself; clicking it, the `Cancel` button, or the close `X` all just hide the window without calling `SB:ReplaceFavourite` at all, so none of the three paths can ever change Favourite data.

**Tests**: new `loader_newsounds_favourites.lua` drives the real pooled rows/cells through the mock (reached via `GetChildren()`/`GetScrollChild()` walks, since both are unnamed pooled widgets local to their own files) and covers the task's own exact verify list: 0/20 places into slot 1; slots 1+3 occupied places into slot 2; removing from slot 2 empties it without shifting slot 3; a sound already favourited before opening shows `Remove Favourite` from the first render; 20/20 opens the Replace modal instead of the chat-only failure (asserting the fixture's own Favourite slots are byte-for-byte unchanged by merely opening it); replacing slot 7 changes only slot 7 and asserts every other slot's soundID is unchanged; slot 7's keybind (`CTRL-7`) is confirmed unchanged after the replacement; Cancel and the close `X` are each confirmed to leave a full snapshot of all 20 slots untouched; a `SB:TriggerSound` call-counting spy confirms Add Favourite, Remove Favourite, and a grid-cell replacement click each trigger zero playback; and a plain row click is confirmed to still preview with the `"SELF"` target override. Full mock suite passes (the same three pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file, including the two new files. No WoW client is available in this environment, so the visual layout (button/text fit at various New Sounds window widths, the replacement grid's own on-screen sizing) still needs the user's own live confirmation before this ships.

**Version bump**: `Soundbook.toc`'s `## Version` bumped `3.0.1 -> 3.0.3` per this round's own explicit instruction to start 3.0.3.

**Merge note**: pushing this round's commit was rejected - the shared branch had moved on independently in the meantime (four commits bumping `## Version` to `3.0.2` and further tuning the Mini Soundbook favourite grid's own density: `ROW_H_MIN/MAX`, `GRID_SOFT_H`, `ICON_MIN/MAX`, and `FAV_COL_W` all retuned smaller, plus a new name-length-driven per-column width and a real screen-width fit check replacing the old fixed per-column legibility floor). Merged that work in (`Soundbook.toc`'s single-line version conflict resolved to `3.0.3`, since it comes after both `3.0.1` and `3.0.2`; every other file merged cleanly) rather than overwriting it. That grid retune changed the real widths `loader_favgrid.lua` and `loader_minisurfaces.lua` (both written earlier this session, before that upstream work landed) asserted exact literal values against, breaking both - fixed by forcing short, fixed display names on `loader_favgrid.lua`'s own test sounds (so every card's width reduces back to the deterministic `FAV_COL_W[columns]` baseline regardless of Sounds.lua's real content) and mirroring the new screen-fit-based column-selection loop instead of the removed legibility-floor one; `loader_minisurfaces.lua`'s single hardcoded "3-column sanity" width updated `383 -> 413` to match the new `FAV_COL_W[3]` value. Both now pass against the current, merged `Announcer.lua`; full mock suite and `luac -p` re-verified clean after the merge (same three pre-existing, unrelated failures aside).

## Soundbook 3.0.3: decouple "Latest Sound Updates" from the temporary New tag, extend New to 5 days

New task: the New tag and the New Sounds/Latest Sound Updates window were the same underlying signal (`SB:IsSoundNew`) - once a sound's temporary New window expired (or the player had simply heard it enough), it silently vanished from Settings' "Latest Sound Updates" button too, with no way to look back at what a recent update actually added.

**1. New tag duration, 2 days -> 5 days (`SoundRegistry.lua`)**: `NEW_TAG_DAYS` changed `2 -> 5` (comment updated `48h -> 120h`). The existing early-expiry rule (>=3 self-triggered AND >=3 received plays, `SB:IsSoundNew`/`SB:BumpNewSoundHeardCount`) is completely unchanged - only the base window grew. `UI.lua`'s two own comments describing this window (Dusty's own "isn't dusty, it'd show New until that window passes" reasoning, and the New filter-pill's own visibility check) and `Analytics.lua`'s sort-priority comment updated from "48h" to "5-day/120h" to match - comments only, no logic in either file changed.

**2. New persistent state: the "latest update batch" (`SoundRegistry.lua`, `Database.lua`)**: `SB:BackfillAddedAt()` - already the one place that discovers genuinely new soundIDs each run (comparing against `SB.db.knownSoundIDs`, never touched on a fresh install) - now ALSO collects every soundID it discovers as new in that same run into `SB.db.latestSoundUpdate = { soundIDs = {...}, autoShown = false }`, replacing whatever batch was stored before wholesale (never merged/archived - explicit requirement, "only the most recent detected update batch must be persisted"). Crucially, this replacement only happens when the run actually found at least one new sound - an update that adds nothing leaves the previous batch (and its `autoShown` flag) completely untouched. A new `SB:GetLatestSoundUpdateSoundIDs()` returns that batch's soundIDs filtered to ones still in `SB.registry` (a later removal/rename can never crash or blank-render the window) - deliberately never filtered by `SB:IsSoundNew`, the 5-day timer, or the heard counters, so it keeps working long after all three have expired. `Database.lua`'s `SanitizeDatabase` gained the matching `EnsureTable(db, "latestSoundUpdate")` plus validation of its `soundIDs` (via the existing `SB.IsValidSoundID`, deduplicated) and `autoShown` (boolean) fields, same pattern as the existing `favourites`/`favKeybinds` sanitization just above it.

**3. `NewSoundsWindow.lua` rebuilt around the persisted batch, not `SB:IsSoundNew`**: `ComputeCurrentlyNew`/`ComputeUnseenNew`/`MarkAllAccountedFor`/the old `newSoundsPopupSeenIDs` "seen" table are all removed - that whole mechanism existed only to approximate "hasn't this been shown before", which the new `SB.db.latestSoundUpdate.autoShown` boolean now represents directly and reliably. `RefreshList` now sorts and renders `SB:GetLatestSoundUpdateSoundIDs()` instead of scanning the registry for currently-New sounds. `SB:ShowNewSoundsWindow()` - the one function both the automatic trigger and Settings' "Latest Sound Updates" button call - now checks whether a real batch has ever been recorded FIRST: if not, it prints `"No sound update has been recorded yet."` to chat and returns without ever building/showing the popup (explicit requirement: never a blank window, and never a manufactured "whole library" fallback batch); manual access from Settings is otherwise completely unconditional - it always shows the current batch regardless of the 5-day timer, the heard counters, whether the automatic popup already fired, or whether the player has opted out of *future* automatic popups. The automatic PLAYER_LOGIN trigger is the only thing that reads `newSoundsPopupOptOut` and the only thing that ever sets `autoShown = true`, exactly scoping the opt-out's meaning to "don't auto-open this for me" per the explicit requirement.

**4. Favourite controls (`Add Favourite`/`Remove Favourite`/the 20-slot Replace modal, shipped last round) are untouched** - they only ever read `SB:IsFavourite`/`SB:GetFavouriteCount`, never `SB:IsSoundNew`, so they already worked (and keep working) regardless of a row's New-tag status; nothing here needed to change for requirement 6.

**Tests**: new `loader_latest_sound_update.lua` covers the task's own exact verify list end to end - a fresh install shows Intro, never auto-opens New Sounds, and records no batch at all; an update that introduces 5 new sound IDs stamps exactly those 5 with `addedAt`, records exactly those 5 as the batch, auto-opens once, and does not repeat on a second login; the New tag is confirmed New at 4 days and expired at 5, and still expires early at exactly 3 self + 3 received (not just one of the two); after 6 days every New tag is gone but the batch is unchanged; a sound whose New tag expired early via heard-counts is confirmed still present in the batch; the opt-out is confirmed to still let the batch get detected/stored and still let Settings open it manually, while suppressing only the automatic popup; a no-op update is confirmed to leave the previous batch untouched, and a real one is confirmed to replace it entirely (not merge); and an install with no batch ever recorded is confirmed to print the exact feedback message and never open a window. `loader_newsounds_favourites.lua` (last round's Favourite-controls test) updated to populate `SB.db.latestSoundUpdate` directly instead of stamping `addedAt` on its fixture sounds, since the window no longer reads the latter at all. Full mock suite passes (the same three pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file.

No version bump this round - still 3.0.3, an unreleased/unmerged branch continuing the same in-progress version line as the previous two rounds.

## Soundbook 3.0.3: recover Latest Sound Updates for installs from before the batch existed

Follow-up bug report: an existing install that already had real `addedAt` timestamps (from before the previous round's `latestSoundUpdate` concept shipped) saw Settings' "Latest Sound Updates" print `"No sound update has been recorded yet."` forever, despite genuinely having a real recent update on record - `SB.db.latestSoundUpdate` itself simply never existed for any install predating that round, and nothing ever backfilled it from the `addedAt` data that already did.

**Recovery (`SoundRegistry.lua`)**: a new `SB:RecoverLatestSoundUpdateBatch()` reconstructs a batch from exactly the data `BackfillAddedAt` already wrote historically - scans every currently-registered sound's `SB.db.sounds[soundID].addedAt` directly (never `SB:IsSoundNew`, never gated by the 5-day window - a sound years past its own New tag must still be recoverable), finds the single newest `addedAt`, and groups in every sound within 60 seconds of it (`RECOVERY_BATCH_WINDOW_SECONDS`) - the same "one real content update landed together in one login" shape a real `BackfillAddedAt` discovery already assumes. Sounds with no `addedAt` at all (baseline/legacy) are never candidates. If it finds anything, it persists `SB.db.latestSoundUpdate = { soundIDs = recovered, autoShown = true }` immediately - `autoShown` starts `true` here specifically (unlike a real fresh discovery, which starts `false`): this batch is being surfaced right now via an explicit manual Settings click, not a genuinely new update, so it must never also trigger a surprise automatic popup on some future login for sounds the player has already had and just looked at.

**Wiring (`NewSoundsWindow.lua`)**: `SB:ShowNewSoundsWindow()` - the one function both Settings' button and the (separately gated, unchanged) automatic trigger call - now attempts recovery FIRST whenever no batch is currently stored, then re-checks; only when recovery ALSO finds nothing does it fall back to the chat message. Because recovery both persists and the very next line opens the window from that same persisted state, a single click fixes the stored data and shows the result in the same call - no reload, relog, or second click. A batch that's already validly stored is never touched by this at all (the recovery attempt is skipped entirely once `HasRecordedBatch()` is already true), and the automatic PLAYER_LOGIN trigger is unaffected - it only ever calls `ShowNewSoundsWindow` when a batch already exists, so it can never itself trigger a recovery.

**Tests**: new `loader_latest_batch_recovery.lua` covers the task's own exact verify list - 5 sounds with historical `addedAt` values a few seconds apart, no stored batch: one click recovers and opens exactly those 5 immediately; sounds without `addedAt` are confirmed excluded; the recovered batch is confirmed to survive past 5 days (no longer New, still shown); an already-valid stored batch is confirmed byte-for-byte unchanged by a second open; a fresh install with zero `addedAt` sounds is confirmed to recover nothing and persist nothing; an install with genuinely no `addedAt` anywhere prints exactly one message and opens no window; and a later genuinely new update is confirmed to replace a previously-recovered batch entirely, not merge with it. Full mock suite passes (the same three pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file.

No version bump this round - still 3.0.3, unreleased/unmerged.

## Soundbook 3.0.3: Replace Favourite grid refinement + Remove Favourite outline styling

Follow-up refinement task, two independent changes.

**1. Replace Favourite window: 5x4 -> 4x5, icon+name instead of slot+keybind (`ReplaceFavouriteWindow.lua`)**: `COLUMNS, ROWS = 5, 4` -> `4, 5` (still all 20 slots, still `LayoutGrid`'s own unchanged `slot = 1, SB.MAX_FAVOURITES` order - only the column/row shape changed, never which slot a cell represents). Each cell's `slotLabel`/`keyLabel` FontStrings are removed entirely and replaced with one `nameText` - centred, word-wrapped, and capped at `SetMaxLines(2)` (a real FontString API on every client this addon targets - it wraps AND ellipsizes a name that still doesn't fit in 2 lines on its own, so no separate manual truncation code was needed), constrained to `CELL_W - 8` so a long name can never bleed into a neighbouring cell. The icon grew slightly (28px -> 30px, `ICON_SIZE`) to read as the visually dominant element per the explicit requirement. The hover tooltip lost its "Slot N"/"Keybind: X" lines entirely too (explicit requirement: no slot number or keybind anywhere, including the hover state) - it now shows only the sound's own full, untruncated display name, useful specifically when the 2-line cap above has ellipsized it. `cell.slot` itself is unchanged and still drives `SB:ReplaceFavourite(self.slot, pendingSoundID)` on click - it's just never rendered anywhere now. `GRID_W`/`WINDOW_W`/the window's own height are all still derived from the `COLUMNS`/`ROWS`/`CELL_W`/`CELL_H` constants exactly as before, so nothing else in the file needed touching.

**2. Remove Favourite styling: no longer the same look as Add Favourite (`Theme.lua`, `NewSoundsWindow.lua`)**: `Theme.CreateFlatButton` gains a third variant, `"outline"` - a near-transparent dark fill (`0.01, 0.035, 0.075` at low alpha, the same navy tone New Sounds' own row backdrop already uses) and the existing neutral `Theme.BORDER` blue border (the same colour `Theme.Panel`'s own inner border already uses elsewhere) instead of the gold border both `"primary"` and `"secondary"` always painted before. A new `btn:SetVariant(newVariant)` lets a caller change this AFTER construction and re-applies the button's current hover/idle state immediately - needed because New Sounds' `favBtn` is one pooled, reused widget per row whose ROLE (Add vs. Remove) toggles live, never rebuilt. `NewSoundsWindow.lua`'s `RefreshFavButton` now calls `row.favBtn:SetVariant(isFav and "outline" or "primary")` alongside its existing label-text toggle, so Add Favourite keeps the prominent gold-bordered "primary" look while Remove Favourite becomes the dimmer, non-gold "outline" one - immediately readable as primary-action vs. already-added/secondary, entirely through Theme.lua's own existing button-variant system, no bespoke one-off styling in NewSoundsWindow.lua itself.

**Tests**: new `loader_replacefav_grid_style.lua` - confirms the grid renders exactly 20 cells spanning exactly 4 distinct columns and 5 distinct rows (derived from each cell's own real `TOPLEFT` anchor point, not re-implemented independently); confirms every one of the 20 slots is represented exactly once and each cell's `nameText` matches its occupying sound's real display name; confirms `slotLabel`/`keyLabel` no longer exist on a cell at all; confirms the hover tooltip's title is the sound's own name (never containing the word "Slot") and no tooltip line ever mentions "Keybind"; re-verifies (against the new cell shape) that a slot-7 replacement click changes only slot 7 and leaves a different slot's own keybind (`CTRL-3`) untouched; and, for the button styling, drives `SB:ShowNewSoundsWindow`/`SB:AddFavourite` on a real row and reads back the button's ACTUAL backdrop/border RGBA (the mock's `SetBackdropColor`/`SetBackdropBorderColor` now record their arguments instead of discarding them, the same fix already applied to `SetHighlightTexture` in an earlier round) to confirm Add Favourite's border is exactly `Theme.GOLD`, Remove Favourite's border is exactly `Theme.BORDER` (never gold), and Remove Favourite's fill alpha is visibly lower/more transparent than Add Favourite's. `loader_newsounds_favourites.lua` (an earlier round's own Replace-window test) updated for the removed `slotLabel`/`keyLabel` fields. Full mock suite passes (the same three pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file.

No version bump this round - still 3.0.3, unreleased/unmerged.

## Soundbook 3.0.4: Online Greetings

New feature: when a known Soundbook Friend or Guild member transitions offline -> online, the Announcer shows a distinct "Online Greeting" - never a generic "Welcome back" - and, if enabled and history exists, plays that player's own personal "Greeting Sound" (the sound they've sent YOU most often) locally, Self-only.

**1. Presence: a real offline/online EDGE, not just "has Soundbook" (`Communication.lua`)**: the existing `SB.db.knownUsers`/HELLO system only ever accumulates a `lastSeen` timestamp - it has no notion of "offline" at all, so it can't answer "did this person just come online" on its own. A new presence scan (`ScanPresence`) builds that missing signal from Blizzard's own real Friends/Guild roster online state (the exact same `SB.GetNumFriends`/`GetFriendInfoByIndex`/`GetGuildRosterInfo` calls `SB.ComputeReachablePlayers` already uses), driven purely by the `GUILD_ROSTER_UPDATE`/`FRIENDLIST_UPDATE` events WoW already fires on its own - no new outgoing addon traffic, no polling ticker. A local `onlineState` table is replaced wholesale on every scan; anyone previously online but missing from a later scan is implicitly "went offline", so their eventual reappearance is a genuine transition again. A `pastInitialSettle` flag, flipped only by a single `C_Timer.After(8, ...)` after `PLAYER_LOGIN`, guards every transition check - every scan before that fires still updates `onlineState` (so the picture is accurate once settled), it just can never itself trigger a greeting, which is what stops partial/staggered roster population right after login or `/reload` from reading as a burst of "just came online" events. A genuinely new transition is deferred another `GREETING_VERIFY_DELAY` (7s, comfortably past `SendHello`'s own 5s post-login delay) and re-verified at fire time - still online, and NOW a confirmed Soundbook user via `KnownUserInfo` - before it's allowed to actually fire, closing the race where a roster event arrives before that player's own HELLO has.

**2. Greeting Sound selection - local, never Analytics (`Communication.lua`, `Core.lua`, `Database.lua`)**: a new `SB.db.greetingStats[IdentityKey][soundID] = { count, lastReceived }` table, built by `BumpGreetingStat` hooked onto the EXISTING `REMOTE_SOUND_PLAYED` event - which only ever fires once `SB:PlaySound` has already succeeded, past the Ignore-list, per-sound mute, and Raid Admin checks - so a muted/rejected/invalid incoming sound can never build statistics, with zero extra gating needed here. `SB:GetGreetingSoundFor(name)` picks the highest `count`, tie-broken by most recent `lastReceived`, filtered to sounds still in `SB.registry`; no history at all returns nil, by design never a fallback. `Database.lua` gained a matching `EnsureTable(db, "greetingStats")`, same lightweight treatment as the existing `newSoundHeardCounts` (malformed entries are skipped defensively at read time, not sanitized eagerly).

**3. Announcer rendering (`Announcer.lua`)**: `AddDisplay` gained an `isGreeting` flag (every existing caller omits it, so ordinary sounds are completely unaffected); `RenderPrimary` branches on it to render `"<PLAYER> IS ONLINE"` as the title and `"Greeting Sound: <name> |cffHEX- <relationship>|r"` (or `"Soundbook |cffHEX- <relationship>|r"` with no sound) as the subtitle - the exact same colour/format machinery (`SB.GetChannelColor`, the `"%s |cff%s- %s|r"` pattern) the normal sender/channel line already uses, plain ASCII separators only (no Unicode middle dot - matches this file's own existing font-compatibility reasoning elsewhere). A real Greeting Sound goes through the identical `activeDisplays`/progress-ticker path any other local play uses (`SB:PlaySound` called directly rather than `SB:TriggerSound`, since this is strictly local/Self by definition - never subject to Default Output routing, never broadcast, never a delivery receipt), so it gets the exact same "normal playback progress behaviour" as any other sound with zero special-casing in the ticker itself. A notification-only greeting (no sound at all) is a new one-shot toast (`ShowGreetingNotification`) - no real `activeDisplays.duration`, so the existing `ValidDuration` branch already hides the progress bar correctly on its own - self-dismissing after 5s via the same `RemoveDisplayByInstance` path a real sound's natural end already uses.

**4. The two independent settings (`Settings.lua`, `Core.lua`)**: `onlineGreetings` (default ON) and `playGreetingSound` (default OFF), added to Multiplayer -> Notifications following the section's own existing `Checkbox`/`CHECKBOX_HELP` pattern exactly. `Communication.lua`'s `VerifyAndFireGreeting` is the one place both are read together: Greetings off + sound off -> nothing; Greetings on -> `SB:ShowOnlineGreeting` handles both the with/without-sound cases itself; Greetings off but a sound IS available -> explicit requirement, still play it as "required playback feedback" but through a plain `SB:TriggerSound(soundID, "SELF")` instead - ordinary local-play rendering, no greeting-specific framing, no standalone notification.

**5. Relationship classification**: no existing "Friend + Guild" concept anywhere in the addon (the existing `SB.ComputeReachablePlayers` bucketing is mutually-exclusive, Friends > Raid > Guild priority) - `ScanPresence` computes `isFriend`/`isGuild` independently per player per scan and combines them into `"Friend"`/`"Guild"`/`"Friend + Guild"` in `VerifyAndFireGreeting`. A new `["Friend + Guild"] = SB.CHANNEL_COLOR.FRIENDS` entry in Core.lua's `CHANNEL_COLOR_BY_LABEL` reuses the existing Friends colour (consistent with that same Friends > Guild precedence) rather than inventing a third one.

**Tests**: new `loader_onlinegreetings.lua` covers the task's own exact verify list - a Friend offline->online and a Guild-member offline->online each fire exactly one greeting; someone who is both fires exactly one, correctly labelled `"Friend + Guild"`; the full roster already online at login/reload fires zero greetings, including a second routine roster refresh right after; a Friend never confirmed to use Soundbook (no `NoteKnownUser`) never gets one; Play Greeting Sound off always means notification-only even with real history on file; Play Greeting Sound on selects and plays the CORRECT most-sent sound (built through the real `REMOTE_SOUND_PLAYED` counting hook, not hand-seeded) and the real Announcer banner text is asserted to contain both `"ERIN IS ONLINE"` and `"Greeting Sound: <name>"`; no history at all never manufactures a fallback sound; repeated presence refreshes while a player stays online never retrigger, while a genuinely observed offline->online cycle correctly fires a second time; and a full outbound-message capture during Greeting Sound playback confirms no `"|PLAY|"` traffic is ever sent. Full mock suite passes (the same three pre-existing, unrelated failures aside); `luac -p` clean across every `Soundbook.toc`-listed file.

**Version bump**: `## Version` `3.0.3 -> 3.0.4`.

## Soundbook 3.0.4 follow-up: Remote Playback header style + Online Greeting test command

Two independent, small follow-up items on top of Online Greetings.

**1. "Remote Playback" header now matches its sibling headers (`Settings.lua`)**: Multiplayer's "Remote Playback" sub-group used `DimSection` - a deliberately quieter, dim-text/no-divider header, originally chosen when it sat under the old "Advanced Playback" framing as a de-emphasized sub-group. Since "Channels" and "Notifications" above it were already promoted to the normal `Section`/`Theme.CreateSectionHeader` treatment (Normal font, gold text, gold divider line) in an earlier round, "Remote Playback" was the one sibling left behind, reading visually weaker than the other two. Switched to the same `Section(...)` call the other two use. `DimSection` itself is now unused anywhere in the file and was removed rather than left as dead code.

**2. `/sb testgreeting <name>` - manual Online Greeting preview (`Core.lua`, `Communication.lua`)**: live-testing Online Greetings previously needed a second real Soundbook client to actually go offline and back online. A new `SB:SimulateOnlineGreeting(name)` lets you preview the Announcer's greeting rendering for any name you type, wired up as a new `/sb testgreeting <name>` slash command (added to `/sb help` too). It reuses the real production code paths end to end - the exact same settings truth table (`onlineGreetings`/`playGreetingSound`) `VerifyAndFireGreeting` uses, `SB:GetGreetingSoundFor` for Greeting Sound selection, and `SB:ShowOnlineGreeting`/`SB:TriggerSound` for rendering - only the presence edge-detection itself and the "confirmed Soundbook user" gate are skipped, since a manually typed test name has neither a real transition nor necessarily a HELLO on file. Relationship (`Friend`/`Guild`/`Friend + Guild`) is read from your REAL, live Friends/Guild roster when the typed name matches someone on it, so testing against an actual guildmate/friend's name previews their real label and (if Play Greeting Sound is on) their real received-sound history; an unmatched/made-up name just previews as `Friend` with no Greeting Sound, since there's genuinely no history for a name that never sent you anything. A short chat line always confirms what was simulated (name, relationship, and the Greeting Sound if any) before the banner shows, so this also works as a quick standalone check without opening WoW's UI at all.

**Tests**: new `loader_testgreeting_cmd.lua` - empty name prints usage and fires nothing; an unmatched name previews once as "Friend" with no fabricated sound; a name matching a real online Guild member previews with the correct "Guild" label; a name with real seeded `REMOTE_SOUND_PLAYED` history previews with the correct most-sent Greeting Sound; both settings off fires neither a greeting nor a sound (matching what a real transition would do); Greetings off + a known Greeting Sound falls back to plain `SB:TriggerSound` local playback, never a standalone notification; and the real `/sb testgreeting <name>` slash command is confirmed to reach `SB:SimulateOnlineGreeting` with the typed name verbatim. All 7 scenarios passed on first run. Full mock suite re-run (the same three pre-existing, unrelated failures aside - `loader.lua`, `loader_minititle.lua`, `loader_settings.lua`); `luac -p` clean across every `Soundbook.toc`-listed file.

No version bump this round - still 3.0.4, unreleased/unmerged.

## Soundbook 3.0.4 Ausbau: persistent fallback Greeting Sound

Extends Online Greetings so a Friend/Guild Soundbook user with no received-sound history yet still gets a Greeting Sound, not just a bare notification.

**1. Fallback selection + persistence (`Communication.lua`)**: a new `ShortestFavouritesPool()` collects the CURRENTLY favourited sounds with a known duration (`SB.registry[id].durationSeconds` - explicit per-entry, precomputed, or already learned; reuses the existing duration-learning infrastructure verbatim, never guesses an unknown one), excludes anything currently muted, sorts ascending by duration, and caps at the 10 shortest (fewer than 10 eligible just uses all of them). `SB:GetGreetingFallbackSoundFor(name)` picks one at random from that pool (`math.random`, same pattern already used elsewhere in the addon, e.g. Announcer.lua's drag-preview) and persists it to the new `SB.db.greetingFallbackSounds[IdentityKey]` table (Core.lua default + Database.lua `EnsureTable`, same lightweight treatment as `greetingStats`) - so every later login reuses the SAME sound instead of re-randomizing. The pool itself is only ever computed inside this function, when an assignment is actually missing or invalid - no periodic scan, per the explicit requirement.

**2. Priority + validity**: `SB:ResolveGreetingSound(name)` is the new single entry point - real received history (`SB:GetGreetingSoundFor`, unchanged) always wins the moment it exists; the persisted fallback is only ever consulted when there's no history at all. Both `VerifyAndFireGreeting` (the real presence-driven path) and `SB:SimulateOnlineGreeting` (`/sb testgreeting`) now call this instead of the raw history lookup, so the manual test command previews the exact same fallback behaviour. Before trusting a persisted fallback, `ValidFallback` re-checks it still exists in the registry and isn't currently muted; an invalid one is silently replaced (and the replacement persisted) from a freshly computed pool. Removing the assigned sound from Favourites ALONE does not invalidate it - explicit requirement - since Favourites is only ever consulted when actually (re-)assigning, never as an ongoing validity condition.

**3. No fake history, no side effects**: a fallback play goes through the exact same `SB:PlaySound(soundID, "local")` call the history-based Greeting Sound already used (Self-only, never broadcast) - it was never routed through `REMOTE_SOUND_PLAYED`, `AnalyticsRecordPlay`, or any delivery-receipt path to begin with, so "never creates fake received history or analytics events" falls out of the existing architecture with zero extra gating needed.

**4. Announcer**: no changes needed - `RenderPrimary`'s existing `entry.isGreeting` branch already just checks whether `entry.soundID` is set, with zero awareness of where that id came from, so a fallback-sourced Greeting Sound renders identically to a history-sourced one, per the explicit "do not visually distinguish" requirement.

**Tests**: new `loader_greetingfallback.lua`, 10 scenarios matching the task's own verify list - the fallback is only ever drawn from the 10 shortest eligible favourites when more than 10 exist (verified via each pick's actual duration rank); the same fallback is reused across repeated lookups; two different players can independently land on two different fallbacks (proven with a stubbed `math.random`, not left to chance); fewer than 10 eligible favourites still works correctly using the smaller pool; zero known-duration favourites yields no fallback and notification-only resolution; a player's first successfully received sound immediately supersedes an already-assigned fallback; further receives keep following the normal most-frequently-received logic; a fallback play is confirmed to never send `|PLAY|` traffic, never bump `AnalyticsRecordPlay`, and never create a `greetingStats` entry; un-favouriting an assigned fallback's sound alone leaves the assignment untouched; and muting it correctly invalidates and replaces it with a fresh, persisted, non-muted pick. All 10 passed on first run after fixing one test-fixture bug (the setup helper was favouriting the entire registry instead of just the intended fixture sounds). Full mock suite re-run (the same three pre-existing, unrelated failures aside - `loader.lua`, `loader_minititle.lua`, `loader_settings.lua`); `luac -p` clean across every `Soundbook.toc`-listed file.

No version bump this round - still 3.0.4, unreleased/unmerged.
