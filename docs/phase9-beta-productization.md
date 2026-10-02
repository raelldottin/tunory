# Phase 9: End-to-End Beta Productization

Phase 9 turned the Phase 1–8 implementation into a complete user-facing beta
workflow. The proven §20 transaction semantics are unchanged; Phase 9 added the
minimum persistence, recovery UI, error-state UX, and application-state handling
a realistic beta needs.

## What Phase 9 added

### 1. Canonical recovery orchestration — `RecoveryFlow` (TunoryCore)

Phase 6 defined what recovery decides (`RecoveryPlanner`: pure, fail-closed
reconciliation of a checkpoint against freshly-read state). The Phase 6 CLI
`recover` verb then hand-rolled the sequencing around it. Phase 9 gave the GUI
a recovery path without the CLI, and the §19/§20 lesson (two hand-rolled
orchestrations of the same decision sequence will drift) applies: the
sequencing moved into TunoryCore as `RecoveryFlow`, and the CLI `recover` verb
became a thin adapter over the same steps.

`RecoveryFlow` exposes the steps individually so each front-end can interleave
its own I/O between them:

- `manifest(for:)` — canonical manifest rebuild from checkpoint catalog IDs via
  `ManifestParser.build` (one validated path; corrupt checkpoints fail closed
  before any network traffic);
- `decide(...)` — fresh preflight + pure `RecoveryPlanner` reconciliation,
  performs NO writes;
- `resume(...)` — the canonical §20 `TransactionRunner` over fresh state;
- `run(...)` — GUI convenience: all three in order, with corrupt checkpoints
  surfaced as a `.stopped(.checkpointDiverged)` outcome instead of a crash.

Every rule is unchanged from proven Phase 6 behavior: the checkpoint is a
cross-check, never replayed; resume re-derives its plan from Apple's actual
state; no write is issued before a fresh read proves the state safe.

### 2. Checkpoint persistence — `CheckpointStore` (TunoryCore)

The GUI's interrupted executes now persist their credential-free checkpoint
(`TransactionViewModel` → `CheckpointStore.save`) so recovery survives an app
relaunch. The store is deliberately mechanical (save/load/clear, no policy):

- single slot, newest interrupted transaction wins;
- a present-but-undecodable file surfaces as `.unreadable` — never silently
  ignored;
- `clearIfSuperseded(bySuccessWith:manifestCatalogIds:)` removes a stored
  checkpoint only when a VERIFIED success proves that EXACT transaction
  (same playlist id AND same manifest sequence) complete — a success for a
  different transaction says nothing about the stored one;
- location: `Application Support/Tunory/checkpoint.json` inside the app
  container (sandbox-resolved).

The checkpoint remains credential-free by construction (playlist identity,
manifest catalog IDs, proven counts — nothing else). Persistence never turns
a checkpoint into proof: recovery still reconciles against Apple's actual
state by fresh reads.

### 3. Recovery UI — `RecoveryView` + `RecoveryViewModel` (app layer)

A dedicated Recovery tab with explicit user actions only:

- **available** — shows exactly what the checkpoint PROVED at capture time
  (playlist identity, proven prefix count, catalog IDs) and explains that
  resuming re-reads Apple Music state right now;
- **Resume** (explicit user action) — runs the canonical `RecoveryFlow`:
  fresh reads → fail-closed decision → resumed §20 transaction; live phase
  evidence streams from the runner's `onPhase` callback;
- **Dismiss** (explicit user action) — removes the saved file only; Apple
  Music state is never touched;
- **unreadable** — a corrupt file is surfaced with its decode error and the
  same Dismiss action;
- **alreadyComplete** — fresh reads proved the playlist already matches the
  full manifest: nothing written, slot cleared, user informed;
- **stopped** — the exact §20 stop condition is shown (divergence reason,
  replaced playlist, unsafe state, authorization loss, connectivity).

The launch-time Status screen surfaces a pending checkpoint as a banner with
an "Open Recovery" jump — no automatic action is ever taken.

### 4. §10 divergence surfaced — `EvidencePresentation` (TunoryCore)

The catalog gate (Gate 3) has always recorded per-recording name divergence,
but the GUI never showed it. `EvidencePresentation.catalogDivergenceNotes`
derives the notes from the canonical `CatalogValidationReport` (presentation
never re-computes matching logic), and the results screen renders them as
explicit review information: identity is the catalog ID, the mismatch is
named, never silently accepted. A diverged-but-passed recording is review
information, not a failure; a diverged-and-failed one is a stop condition
(already handled by the gate).

### 5. Connectivity state — explicit test button

The Status screen's connectivity line was permanently "not tested" unless the
user re-ran authorization. It now has a Test Connectivity button (read-only
catalog ping, disabled while in flight).

### 6. `MusicAuthViewModel.isTestingConnectivity` re-entrancy guard

The connectivity check sets a published in-flight flag so the button can
disable itself; a slow request can no longer be doubled.

## Preserved invariants (unchanged from Phases 1–8)

- The canonical §20 `TransactionRunner` sequence and every stop condition;
- catalog-ID identity rules (§10) and Gate 3;
- append-only playlist behavior with per-step fresh-read proof (§14);
- the §12 single-enumeration rule and §11 202-is-not-proof discipline;
- checkpoint/recovery fail-closed rules (§ Phase 6 / `RecoveryPlanner`);
- zero-duplicate guarantees (`playlistVerificationFailed` on any drift);
- the Hermes automation contract (`run` verb, AutomationResult, exit codes)
  — untouched; `recover`'s output contract is byte-identical after the
  `RecoveryFlow` extraction.

## CLI `recover` after Phase 9

Same verbs, same output lines, same exit codes. The verb now delegates to
`RecoveryFlow.manifest` / `decide` / `resume` instead of hand-rolling the
sequencing — the CLI and GUI drive the identical canonical path.

## Proof levels reached (2026-10-02)

- TunoryCore: 155/155 tests green (142 regression + 13 new Phase 9 tests
  covering CheckpointStore lifecycle, strict supersede identity,
  credential-free persistence, RecoveryFlow fail-closed/alreadyComplete/
  resume/divergence/replaced-playlist/equals-canonical-run, divergence notes).
- Debug and Release macOS builds: PASS.
- Signed-app zero-write no-op path: live-proven via the `run` verb against
  the After Hours playlist (exactComplete, 17/17 tracks, zero writes, exit 0).
- Live divergence stop: the After Hours playlist was externally modified
  during the session; a subsequent run correctly stopped with
  `containsUnrelatedTracks` and issued zero writes — live proof of the
  divergence state handling.
- GUI rendering: OCR-verified from the real app — Status/Import/Recovery
  tabs, connectivity check (executed live: "reachable (albums returned: 1)"),
  Recovery empty state, launch states.
- GUI interactivity: tab switches, Test Connectivity, and the manifest open
  panel were driven by real clicks; the sandboxed file-picker could not be
  completed programmatically (SwiftUI window AX surface unresolved for the
  input driver while the user's session was active), so a full GUI click-
  through to a live write was NOT achieved.

## Remaining known gaps

- Full GUI click-through acceptance (import → transaction → results, and
  GUI-clicked resume) still needs a human pass or a focus-permissive
  automation window: the SwiftUI window's accessibility surface is
  unresolved for background input drivers, and foregrounding it would
  disrupt the active user session.
- The divergence-notes UI renders only after a transaction runs; it does not
  exist on the import-review screen (out of the approved scope: identity is
  established at resolution time there, and Gate 3 re-checks it before any
  write).
