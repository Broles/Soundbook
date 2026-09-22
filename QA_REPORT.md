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
