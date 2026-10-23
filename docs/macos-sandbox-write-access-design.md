# Design: sandbox write access for user-selected destinations

Card: t_691e4034 (Task 1, design) → downstream t_01ae61ff (implement),
t_2a35f360 (built-product tests), t_d329acad (verify).
Upstream input: `docs/macos-sandbox-user-selected-write-research.md`
(t_c8d05ad3, commit f938752) — all Apple-source citations below trace to
that document (§ references are its sections).
Design deliverable; this card changes no product code. All file:line
anchors verified against `wt/t_691853ee` @ f938752 on 2026-10-19.

## 1. Problem and intended outcome

A signed, sandboxed Tunory must write converted audio (and only
converted audio) into a destination directory the user picks. The
least-privilege channel is the powerbox: `NSOpenPanel` /
`.fileImporter` grant a security-scoped URL, the app claims the grant
before I/O, and the engine performs its existing atomic
temp-file-plus-rename promote inside that directory.

Intended user-visible outcome:

1. Picking a destination folder and converting files lands validated
   `.m4a` output inside that folder; nothing else is written there.
2. Originals are never modified (byte-identical, sha-verified).
3. Every destination write is atomic — no partially-converted file is
   ever visible at a destination path; failures leave the destination
   untouched and clean of temp files.
4. Access persists only while the user's grant is alive; nothing is
   remembered across launches by default.

Much of this already exists and is verified: the entitlement flip
(`ENABLE_USER_SELECTED_FILES = readwrite`, commit 990b5f9, pbxproj
lines 391/435), the claim transport (`SecurityScopedAccess.swift`), the
view-model claim sites, and the engine's atomic promote. This design
(a) pins those as the canonical architecture, (b) names the small set
of concrete changes still required, and (c) details acquisition,
persistence, revocation, and the staging question the card body asks
for, so the implementer implements rather than re-decides.

## 2. Non-goals

- No Music.app import changes (automation entitlement path is out of
  scope; it never writes the library directly — phase-10 report §2).
- No drag-and-drop or Open Recent acquisition surfaces.
- No bookmark adoption in v1 (specified as the opt-in forward path,
  §5.4; adopting it now would add an entitlement with no requirement).
- No unbundling of the sandbox, no `files.all`, no standard-location or
  temporary-exception entitlements (research §3 rejected-alternatives
  table).
- No fix for headless CLI source reads — fail-closed by design
  (phase-10 report §4.2 item 2); unblocking needs a separate owner
  decision (non-sandboxed helper).
- No "convert first, pick destination later" UX rework.

## 3. Preserved invariants (must hold after implementation)

I1. Originals are never modified; conversion is read → encode to temp →
    validate → promote.
I2. Atomic promote: the output file appears at its destination path in
    one same-directory rename; the temp file (`.tunory-tmp-<uuid>.m4a`)
    is removed on every failure path (LocalImportEngine.swift:446-509).
I3. Destination guard: a file absent from the conversion journal is
    never overwritten, no matter how corrupt it looks
    (LocalImportEngine.swift:101-104, 480-500).
I4. Journal records are appended only after a successful promote
    (LocalImportEngine.swift:511-518); the journal is append-only and
    atomically replaced (:131-144).
I5. Claims are balanced: one release per successful claim, on every
    exit path, newest-first, exactly once (SecurityScopedAccess.swift).
I6. Claims are made on the panel-issued URLs — a rebuilt copy of the
    same path is not the granted URL; folder grants cover the subtree
    and stay claimed on the folder URL.
I7. The engine stays the single decision authority; the view model and
    CLI are presentation adapters (no second decision path).
I8. Deterministic ordering preserved: journal sort order, source
    ordering, plan ordering unchanged.
I9. Generation-guard semantics preserved: stale async completions
    cannot overwrite newer flow state (LocalImportViewModel generation).

## 4. Decisions

D1 — Entitlement: keep `com.apple.security.files.user-selected.read-write`
     (via `ENABLE_USER_SELECTED_FILES = readwrite`), and nothing
     broader. Already landed (990b5f9) and regression-pinned at the
     kernel-enforced level (43c08bc, 4/4). The implementer changes no
     entitlement; they verify the effective built product (§7).
     Rationale: the narrowest key that can implement "write where the
     user says" (research §3); broad alternatives all grant more than
     the user picked.

D2 — Acquisition: powerbox only, through the three existing surfaces —
     `.fileImporter` for files (LocalImportView.swift:38-42),
     destination directory panel (:47-58, `presentOutputPicker`),
     source folder panel (:63-76, `presentFolderPicker`). The app has
     no drag/drop or Open Recent handlers, so every grant in this flow
     is an explicit panel interaction (research §2, verified). Keep it
     that way: programmatic acquisition does not exist, and the
     powerbox is precisely the channel hostile code cannot drive.

D3 — Grant retention and claiming: keep the existing transport pattern
     — `SecurityScopedAccessClaiming` protocol + `SystemSecurityScopedAccess`
     adapter as the ONLY callers of start/stop APIs; view model retains
     the exact panel-issued URLs (`grantedFileURLs`,
     `grantedOutputDirectory`, LocalImportViewModel.swift:100-101) and
     claims them per operation with `SecurityScopedClaims` + `defer`.
     One contract gap to fix (change C3 below): `select(folders:)`
     reads `.isDirectoryKey` on panel URLs before any claim
     (LocalImportViewModel.swift:165-181) — claim-first must hold for
     metadata reads too, not just file bodies.

D4 — Write mechanism: direct write into the destination directory with
     same-directory temp + validated promote (current engine behavior,
     LocalImportEngine.swift:446-509). App-container staging is
     REJECTED. The final artifact must land in the user-chosen folder,
     so a read-write grant on that folder is required either way;
     staging adds no entitlement it can avoid, breaks same-directory
     atomicity (cross-directory move is a copy with a partially-visible
     window unless same volume), doubles I/O, and adds staging-residue
     cleanup on failure (research §7, full comparison table). Revisit
     only if a future requirement asks "convert first, pick
     destination later" — noted as a non-goal.

D5 — Journal location: unify on the app container. Today the GUI keeps
     the conversion journal in the container
     (`Application Support/Tunory/local-import-journal.json`,
     LocalImportViewModel.swift:117-120) while the CLI constructs
     `LocalImportJournal(directory: outputDirectory)`
     (TunoryApp.swift:644), writing Tunory state INTO the user's
     destination folder. Divergence consequences, both fixed by
     unifying on the container:
     a. Least-privilege write targets: the user granted the folder for
        converted audio, not for Tunory bookkeeping. After this change
        the ONLY things written into the grant are the converted
        outputs and their transient temp files.
     b. Destination-guard truth: "did we produce this destination file"
        is journal-keyed. Two placements mean the GUI and CLI consult
        different record sets for the same output directory, so
        ours-vs-foreign classification differs by surface. One shared
        container journal makes the guard's ours-determination complete
        across surfaces (records are path-keyed; the guard matches
        identically). This is the fail-safe direction: the guard sees a
        superset of prior conversions — skip-if-valid and conflict
        behavior only get more accurate, and I3 is unchanged.
     c. The CLI journal read/write works inside the sandbox (container
        is always readable/writable; no powerbox grant needed), which
        the output-directory placement cannot promise headlessly.
     GUI behavior is unchanged; this is the canonical home.

D6 — Persistence across launches: NONE in v1 — the documented default
     (research §4: powerbox access "does not automatically persist
     across app launches"; the only exception is Resume for files open
     at termination). Destination and sources are re-picked via panel
     every session. This is fail-closed and matches shipped behavior;
     adding persistence would broaden the entitlement surface without a
     product requirement (AGENTS.md: no speculative capabilities). The
     full bookmark mechanism is specified in §5.4 as the opt-in
     forward path for an owner-approved "remember destination" feature.

D7 — Revocation semantics:
     Within a run — grants live as long as the panel-issued URL objects
     are retained; `reset()` drops them (regression-tested:
     `testResetDropsStaleGrants`). Mid-run destination loss (user
     deletes the folder mid-conversion) manifests as an I/O failure
     that the engine's failure paths already convert to a failed
     outcome with temp cleanup — fail-closed, destination untouched
     (I2, I3). Mid-run foreign writes to the destination are caught by
     the promote-time destination re-check (LocalImportEngine.swift:
     480-500).
     Across runs — v1 persists nothing, so there is nothing to revoke:
     each session's grants are born and die with the user's panel pick.
     Under the v2 bookmark path — stale resolution (`bookmarkDataIsStale`
     → recreate from the resolved URL), resolution failure (folder
     deleted/moved beyond tracking → treat as revoked → re-ask via
     powerbox). Never trust a remembered path string; resolve the
     bookmark (research §6).

D8 — Verification strategy and honest proof levels (§7): hosted tests
     prove the entitlement contract and the claim contract; ONLY the
     operator-driven live GUI drive proves a real powerbox write. The
     drive gate is already staged and blocked pending the owner
     (fixture at `~/Desktop/TunoryDriveFixture/`, MANUAL-DRIVE.md
     attachment 41 on t_7711fdbf). No test may claim live-write proof
     it did not observe.

## 5. Architecture

### 5.1 Component map (all existing except the noted change)

Presentation (LocalImportView.swift): the ONLY place panels appear.
  - fileImporter (files), presentOutputPicker (destination),
    presentFolderPicker (source folders). No decision logic.

Flow adapter (LocalImportViewModel.swift): retains panel-issued grant
  URLs; per-operation claim/release; routes every selection mode to
  the same canonical planner (`planFiles`/`planBatches`); generation
  guard for stale completions; resets drop grants.

Transport (SecurityScopedAccess.swift): protocol + system adapter +
  balanced claim batch. The only start/stop call sites in the flow.

Domain (TunoryCore/LocalImportEngine.swift): planning, probing,
  conversion, atomic promote, destination guard, journal — all
  sandbox-agnostic (takes paths; never claims, never decides scope).
  The engine must not learn about security scope: claiming stays at
  the view-model boundary (I5, I6, I7).

Persistence (TunoryCore LocalImportJournal): append-only, atomically
  replaced, single JSON file. NEW canonical home:
  `LocalImportJournal.defaultDirectory()` →
  `Application Support/Tunory/` — mirroring
  `MusicImportJournal.defaultDirectory()` (MusicImportEngine.swift:
  204-210) so both surfaces and the destination guard share one truth
  (D5). Journal records remain path-keyed and surface-agnostic.

CLI (TunoryApp.swift `local-import` verb): same engine, same planner,
  same journal (after C2). Headless source reads stay fail-closed
  (out of scope, §2).

### 5.2 Destination write sequence (canonical, per file)

1. User picks destination via powerbox (D2). Panel returns the
   security-scoped folder URL; view model stores it as
   `grantedOutputDirectory`.
2. Operation start (analyze / convert / survey / import): claim every
   granted URL the operation touches — sources and destination folder
   — via one `SecurityScopedClaims`; `defer { claims.release() }`
   (I5). Destination claim covers the whole subtree, temp file
   included (I6).
3. Engine plans: probe sources (claimed), consult journal + destination
   guard (I3).
4. Engine converts (only when user-confirmed): write
   `.tunory-tmp-<uuid>.m4a` INTO the destination directory, flush
   writer (function-scope discipline, LocalImportEngine.swift:543-552),
   validate (decodable, profile codec, duration within 1 s).
5. Promote-time destination re-check (I3), then same-directory rename
   (I2). Journal append only after success (I4).
6. Operation end: claims released newest-first, exactly once.
   Failure at any step: temp removed, destination untouched, claim
   still released via `defer`.

### 5.3 Grant lifecycle state machine (within a run)

    panel OK ──► acquired (URL is security-scoped)
                     │  retained in grantedFileURLs / grantedOutputDirectory
                     ▼
              re-picked? no ── operation claims (begin) ──► claimed
                     │                                        │
                     │                              I/O (probe/convert/guard)
                     │                                        │
                     ▼                                        ▼
              reset()/Clear ──► dropped           release (end) ──► retained
              (grants discarded; nothing            (balanced 1:1 with begins)
               persists across launches)

Rules: claim strictly before ANY access including resource-value reads
(C3); one end per true begin on every exit path; after a release the
grant must be re-claimed before the next access; claims attach to the
panel-issued URL, never to rebuilt copies (I6).

### 5.4 Persistence & revocation: v1 behavior and the v2 bookmark path

v1 (this design): state at launch = no grants. First destination pick
of a session is always an explicit powerbox interaction. Revocation
surface = none (nothing persists). Fail-closed by construction.

v2 (forward path, owner opt-in, NOT part of t_01ae61ff): if the owner
approves a "remember destination" feature, adopt app-scoped
security-scoped bookmarks exactly per research §6:

1. Entitlement: add `com.apple.security.files.bookmarks.app-scope` to
   Tunory.entitlements (one key; document-scoped bookmarks cannot
   target folders and are inapplicable). Extend
   SandboxEntitlementRegressionTests: assert the bookmark key present,
   and still assert no broad filesystem keys.
2. Create on grant: at the moment the user picks (powerbox grant in
   hand), `bookmarkData(options: [.withSecurityScope])` for the
   destination folder.
3. Store: opaque bookmark data in the app container only (UserDefaults
   or a plist under Application Support/Tunory). Bookmark data does
   not extend the sandbox until resolved AND claimed — storing it is
   inert.
4. Resolve after relaunch: `URL(resolvingBookmarkData:options:
   [.withSecurityScope]...)` → security-scoped URL; if
   `bookmarkDataIsStale`, re-create from the resolved URL; then
   immediately claim (start) before any I/O (5-step procedure, research
   §6.261-277).
5. Revocation: resolution failure (deleted folder) → revoked → clear
   the stored bookmark and re-ask via powerbox; stale → recreate;
   never fall back to the remembered path string.
UI must still show the resolved folder and offer "choose a different
folder" — persistence preserves user intent (the exact original
folder), it never broadens it.

## 6. Required implementation changes (for t_01ae61ff) — minimal set

C1. `LocalImportJournal.defaultDirectory()` (TunoryCore): returns
    `Application Support/Tunory/` (same value the GUI injects today,
    LocalImportViewModel.swift:117-120). Mirror the
    MusicImportJournal.defaultDirectory() fallback shape
    (temporaryDirectory as last resort). No behavior change for the
    GUI path (its injected directory already equals this value).

C2. CLI journal alignment (TunoryApp.swift:644): replace
    `LocalImportJournal(directory: outputDirectory)` with
    `LocalImportJournal(directory: LocalImportJournal.defaultDirectory())`.
    The output directory henceforth receives only converted audio (D5).
    No other CLI changes.

C3. Claim-first folder probe (LocalImportViewModel.swift:165-181):
    in `select(folders:)`, claim the panel URLs before reading
    `.isDirectoryKey` (e.g. wrap the filter in a SecurityScopedClaims
    batch released on exit). The panel already guarantees directories
    (`canChooseFiles = false`), so the filter stays as defense — but it
    must run under claim, honoring I5/I6 for metadata reads.

C4. Audit (verify, do not rewrite): every operation that touches a
    granted URL claims it first — analyze (:202-205), convertSelected
    (:261-266), surveyMusicLibrary (:335-340), importToMusic
    (:403-408) already do; confirm no new write path bypasses the
    engine (only `engine.convert` writes into the destination).

C5. Entitlement: NO change. Verify the effective built product only
    (codesign dump + regression suite, §7).

C6. Tests to add (claim/journal contract level):
    - select(folders:) claims before the isDirectory probe (order-
      assertable with the existing RecordingSecurityScopedAccess fake).
    - select(folders:) still dedupes/sorts and drops non-folders.
    - LocalImportJournal.defaultDirectory() points at the container
      home; CLI construction no longer journals into the output
      directory (guard: construct via defaultDirectory in the verb).

## 7. Test and verification plan (t_2a35f360 / t_d329acad)

Proof levels — what each check proves, and what it cannot:

P1. Entitlement contract (hosted, kernel-enforced):
    SandboxEntitlementRegressionTests inside the signed test host
    (SecTaskCreateFromSelf) — 4/4 must stay green: app-sandbox ON,
    user-selected read-write EFFECTIVE, stale read-only key ABSENT, no
    broad filesystem keys. Codesign `--entitlements` dump on plain
    Debug AND Release products (the test host injects harness
    entitlements; plain-build products must carry none beyond the
    designed surface, Appendix A). Proves: the binary is entitled.
    Does NOT prove: that a write succeeds.

P2. Claim contract (unit, fakes): LocalImportViewModelSecurityScopeTests
    (5 existing) + C6 additions. Proves: claim-before-use and balanced
    release in the view model. Does NOT prove: kernel behavior.

P3. Engine invariants (unit): existing TunoryCore suite (atomic
    promote, guard, journal, originals-untouched). Proves: decision and
    write mechanics on injected paths. Does NOT prove: sandbox grant
    presence.

P4. Live powerbox write (operator-gated, human): the ONLY proof that
    a real signed app converts into a real user-picked folder. Fixture
    staged (sample.wav sha256 e41525d1…, empty dest/,
    baseline.json + MANUAL-DRIVE.md). Success = ffprobe-valid AAC ~2.0 s
    in dest/, source byte-identical, no journal file in dest/ (D5
    makes this a new observable), no temp residue.

P5. Built-product observation: the GUI drive must run against a fresh
    signed Debug build of the implementing commit (the run-138 pattern
    on t_7711fdbf: app path in DerivedData, Local Files tab verified
    in the compiled dylib, effective entitlements dumped).

NOT PROVABLE by automation: P4 without a human pick (the powerbox is
user-only by design — that is the security property, research §2).

## 8. Acceptance criteria (each with its proving observation)

AC1. Effective built-product entitlements equal exactly Appendix A on
     Debug and Release (P1: codesign dump + 4/4 regression).
AC2. All grants in the flow originate from the three panels (P2/P3
     source audit: no drag/drop/Open Recent; no programmatic scoped
     URLs).
AC3. Claim-before-any-access holds everywhere, including the folder
     probe (P2: C6 order test).
AC4. The destination directory receives only converted audio and
     transient temp files (P3 engine audit + P4 observation: no
     journal file in dest/ after the drive).
AC5. CLI and GUI share one container journal (P3: defaultDirectory
     test; CLI verb constructs it there).
AC6. Originals byte-identical, outputs atomic and validated (P3 suite
     + P4 sha256/ffprobe).
AC7. Destination guard semantics unchanged and now cross-surface
     (P3: guard tests still pass with records originating from either
     surface — records are path-keyed and surface-agnostic).

## 9. Risks and mitigations

R1. Shared journal grows with all conversions ever (both surfaces).
    Mitigation: unchanged semantics (guard matches on destinationPath);
    size is bounded by conversion counts; a pruning story is a separate
    card if it ever matters.
R2. CLI-visible behavior change: journal no longer appears in the
    output folder. Mitigation: intended (D5a); call it out in the
    implementation commit message and release notes; the CLI's stdout
    outcome JSON is unchanged.
R3. select(folders:) claim fix could regress panel behavior.
    Mitigation: panel construction already guarantees directories; the
    filter is defense-in-depth and stays; order test pins the contract.
R4. Bookmark v2 scope creep. Mitigation: v2 is explicitly opt-in and
    out of t_01ae61ff's scope (§2, §5.4); the regression suite still
    asserts the bookmark key is ABSENT until adopted.
R5. Shared-worktree contention (sibling cards on wt/t_691853ee).
    Mitigation: implementer must verify the worktree is idle and clean
    before starting, baseline-retest at claim time, never revert
    sibling commits.

## 10. Open owner gates (unchanged by this design)

G1. Live signed-GUI powerbox drive (P4) — staged, blocked pending the
    owner's manual click-through (t_7711fdbf run 138 deliverable).
G2. Bookmark adoption ("remember destination") — owner decision; v2
    path fully specified in §5.4.
G3. Headless CLI unblocking — separate owner decision (phase-10 §4.2).

## Appendix A — final entitlement surface (v1)

Tunory.entitlements (unchanged by this design):
  com.apple.security.app-sandbox                = true
  com.apple.security.cs.disable-library-validation = false
  com.apple.security.network.client              = true
  com.apple.security.automation.apple-events     = true
Synthesized from build settings at signing time (not in the file):
  com.apple.security.files.user-selected.read-write   (ENABLE_USER_SELECTED_FILES
= readwrite, pbxproj 391/435)
Explicitly ABSENT (regression-pinned by 43c08bc, must stay absent):
  com.apple.security.files.user-selected.read-only
  com.apple.security.files.bookmarks.app-scope   (until v2 opt-in)
  com.apple.security.files.bookmarks.document-scope
  com.apple.security.files.all
  com.apple.security.*.folder.read-write (standard locations)
  com.apple.security.temporary-exception.files.*

## Appendix B — rejected alternatives

See research §3 (entitlement family comparison; files.all,
standard-location, temporary-exception, sandbox-off all rejected) and
§7 (app-container staging rejection, reproduced as D4). Historical
evidence preserved there; not restated.
