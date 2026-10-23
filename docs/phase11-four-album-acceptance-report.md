# Phase 11 — Four-Album Local Music Import Acceptance Report

- **Kanban card:** `t_6069340a` (root) — children `t_72d1c24a`, `t_e6a35c8e`, `t_21d15d73`, `t_0dc47722`, `t_6adaba95`
- **Branch:** `wt/t_691853ee` @ `8b106de` (clean; 0 ahead / 0 behind vs `origin` at QA time)
- **Pull request:** [#12](https://github.com/raelldottin/tunory/pull/12) — base `wt/t_d354af27` (PR #4 head), head `wt/t_691853ee`. The published chain is preserved: main ← #1 ← #2 ← #3 ← #5 ← #4 ← **#12**. No merges, force-pushes, resets, or destructive rebases were performed.
- **Reported by:** `tunory-builder` (root acceptance run), 2026-10-23
- **Environment:** macOS 27.0.1 (arm64, 12 cores / 32 GB); Xcode 27; `ffmpeg 9.0.2` at `/opt/homebrew/bin/ffmpeg` used **only** to synthesize deterministic test fixtures — the shipped app contains no external FFmpeg executable (Req 3 preserved).
- **ECC preflight (this run):** skills PASS · hooks PASS (live: `git commit --no-verify` blocked by `block-no-verify`; benign git allowed) · doctor PASS (0 errors, single install, schema v1) · canonical repo verified.

## 1. Objective

Make Tunory reliably import four folders of FLAC albums into the local macOS Music.app library without an Apple Music subscription: convert unsupported recordings natively, conservatively detect existing library recordings before any conversion or write, import only approved missing recordings behind an explicit UI confirmation, verify the result, and never modify existing recordings or original files.

## 2. What Phase 11 shipped (five child commits, all on PR #12)

| SHA | Card | Deliverable |
|---|---|---|
| `15eed22` | t_72d1c24a | Four-album selection proof: multi-root nested FLAC discovery (CD1/CD2), six metadata axes + embedded artwork preserved, originals byte-identical (Req 1) |
| `19625d9` | t_e6a35c8e | 9-field Music library survey (artist, album, album artist, disc, track added; per-field guards, conservative parsing) + position-aligned survey pairing with fail-closed handling of failed surveys (Req 2) |
| `da9aa8c` | t_21d15d73 | Pre-conversion Music.app duplicate preflight gating conversion (`preflightMusicLibrary()` → `convertAfterPreflight(reviewResolved:)`); sandbox write resolved with least privilege (user-selected read-write powerbox grant; journal in container); signed-app entitlement evidence (Req 2/3/4) |
| `63a8496` | t_0dc47722 | Integrated import flow: confirmation dialog is the sole write initiator; fresh per-write Music.app re-survey; `.attempted` → `.verified` journaling; fail-closed on state changes; read commands + `add` only (Req 5) |
| `8b106de` | t_6adaba95 | `FourAlbumAcceptanceTests` (760 lines): 4 albums / 40 real FLAC bitstreams / 13 library-existing / 27 missing, honest census, run-1 and idempotent run-2, adversarial review bucket (Req 6/7) |

Pre-existing GAP A–D work on the same branch (multi-folder GUI picker, metadata carry, conservative cross-format classifier + prober, entitlement regression + kernel-enforced sandbox-write behavior tests) is preserved and re-verified below. Phase 10 systems (native AAC 256 / ALAC conversion, Apple Events integration, journal, security-scoped access) were **not** rebuilt.

## 3. Independent QA re-run (Requirement 8) — executed 2026-10-23 at `8b106de`

| Gate | Command (verbatim) | Result |
|---|---|---|
| Core suite | `swift test --package-path Packages/TunoryCore` | **275/275 PASS, 0 failures**, 10.843 s, exit 0 |
| App-hosted GUI suite | `xcodebuild -project Tunory.xcodeproj -scheme Tunory -configuration Debug -destination 'platform=macOS' -allowProvisioningUpdates -only-testing:TunoryTests test` | **72/72 PASS, 0 failures** — `** TEST SUCCEEDED **`, exit 0 |
| macOS Debug build | `xcodebuild … -configuration Debug -destination 'platform=macOS' -allowProvisioningUpdates build` | `** BUILD SUCCEEDED **`, exit 0 |
| macOS Release build | `xcodebuild … -configuration Release -destination 'platform=macOS' -allowProvisioningUpdates build` | `** BUILD SUCCEEDED **`, exit 0 |
| Signed-product entitlements | `codesign -dv`, `codesign -d --entitlements :-`, `codesign --verify --deep --strict --verbose=2`, `defaults read …Info` | PASS — see §7 |
| Sandbox source/destination access | `SandboxWriteBehaviorTests` (5, kernel-enforced in the signed app) + `LocalImportViewModelSecurityScopeTests` (5) + `SandboxEntitlementRegressionTests` (4) | 14/14 PASS in today's app suite |
| Duplicate/idempotency | `FourAlbumAcceptanceTests` (3), `MusicDuplicatePreflightTests` (30), `MusicImportEngineTests` (44), preflight-conversion (5), survey-pairing (2) | all PASS — see §6 |
| Recovery | see §5 map | all PASS (within the suites above) |
| Apple Music catalog workflows preserved | `AppleMusicLinkParsingTests` 9 · `MatchEngineTests` 12 · `RESTEngineTests` 44 · `TransactionRunnerTests` 12 · `Phase6ScenarioTests` 13 · `Phase9ScenarioTests` 13 · `ResolutionEngineTests` 16 · `Manifest*` 20 · `PastedListParsingTests` 10 · `AutomationResultTests` 10 · `CheckpointRemovalTests` 1 | **155/155 PASS** in today's core run — catalog stack untouched by Phase 11 |
| GUI XCTest (`TunoryUITests`, 14 tests) | documented phase-10 invocation, 2 attempts | **NOT COMPLETED — environment-blocked**, see §8 |
| Git hygiene | `git status --short`, `git diff --check`, `git ls-files` artifact sweep | PASS — worktree clean, no whitespace errors, no tracked `.DS_Store`/`.build`/`xcuserdata`/`.xcuserstate`/`AMHelper.app` |

Build proof level (honest): today's Debug/Release builds ran against the project's warm DerivedData and relinked the app executables at HEAD 2026-10-23 12:43 (`8b106de` verified up to date in both configurations). HEAD differs from the child-verified `63a8496` **only** by the package test file `FourAlbumAcceptanceTests.swift` (+760 lines, test target only — `git diff --stat 63a8496..8b106de`), so the app targets compiled today are byte-for-byte the sources already built and test-verified by the children. The most recent cold Debug build evidence is run 142 at `fa98e3f` (44 min, BUILD SUCCEEDED).

### Test-suite census (today's runs, authoritative)

**TunoryCore 275:** LocalImportEngine 36 · MusicImportEngine 44 · MusicDuplicatePreflight 30 · RESTEngine 44 · ResolutionEngine 16 · MatchEngine 12 · ManifestParsing 12 · ManifestBuilder 8 · TransactionRunner 12 · Phase6Scenario 13 · Phase9Scenario 13 · AppleMusicLinkParsing 9 · PastedListParsing 10 · AutomationResult 10 · LocalImportJournal 2 · CheckpointRemoval 1 · **FourAlbumAcceptance 3**.

**TunoryTests (app-hosted) 72:** ImportViewModel 9 · LocalImportFolderSelection 8 · LocalImportViewModelMusicImportIntegration 11 · LocalImportViewModelPreflightConversion 5 · LocalImportViewModelMusicSurveyPairing 2 · LocalImportViewModelSecurityScope 5 · LocalImportCLIJournal 2 · MusicAuthViewModel 7 · ResultEvidence 3 · ReviewConfirmation 4 · SandboxEntitlementRegression 4 · SandboxWriteBehavior 5 · WorkflowSafety 7.

## 4. Requirement-by-requirement acceptance

| Req | Requirement | Status | Evidence |
|---|---|---|---|
| 1 | Four-album selection GUI, recursive discovery, metadata/artwork preservation, security-scoped URLs | **PASS (automated)** | multi-folder picker → `select(folders:)` → `planBatches`; `testFolderSelectionRecursesIntoSubfolders` (single parent folder); engine multi-root nested CD1/CD2 test with six metadata axes + embedded PICTURE byte-identity; security-scope claim-before-probe (5/5); SHA-256 originals unchanged |
| 2 | Library duplicate detection vs real Music.app survey, conservative classification, cross-format identity, never auto-import unresolved conflicts | **PASS (automated, mocked library)** | 9-field survey (19625d9); classify funnel: `noCandidate` / `exactDuplicate` (hash) / `verifiedExisting` (six axes + duration tolerance) / `needsReview` / `undecodableCandidate`; 9 cross-format AAC twins verified existing despite different hashes; property tests: single-axis sweep all-review, duration boundary, determinism; adversarial bucket 5-ambiguous never auto-imported |
| 3 | Convert only approved recordings; AAC 256 default + ALAC; no external FFmpeg; originals unchanged; validate before import | **PASS (automated)** | preflight gate: exactDuplicate/verifiedExisting/undecodable/failed-survey never converted (da9aa8c, 5 tests); validation = decodable + matchesProfile + duration ±1 s; engine conversion tests 36 incl. atomic promote, no partial files, idempotent valid-output skip |
| 4 | Sandbox write access resolved with least privilege; effective entitlements verified; no sandbox disable, no broad FS access | **PASS (signed-app runtime)** | user-selected read-write powerbox grant (not app-container staging); journal routed to container home (9334df1); kernel-enforced `SandboxWriteBehaviorTests` 5/5 (world-writable outside grants denied; user-selected rw effective; container writable); entitlements dump §7 |
| 5 | Music.app import via existing engine/Apple Events; read-only discovery; explicit confirmation; per-write recheck; no DB writes; non-destructive | **PASS (automated, mocked library)** | confirmation dialog sole write initiator (zero add commands before it); fresh `searchLibrary` before each of preflight/UI/import-time writes; `.attempted` journal before add, `.verified` after read-back; uncertain read-back → reconcile, never blind re-add; command surface = reads + `add` only |
| 6 | Four-album acceptance: honest counts, idempotent second run, ambiguous → review | **PASS (automated, mocked library)** | §6 |
| 7 | Failure & recovery cases | **PASS (automated)** | §5 |
| 8 | Independent QA | **PASS except GUI XCTest** (environment-blocked, prior evidence intact) | §3 |
| 9 | Delivery | **this report + PR #12 + §9–§12** | — |

## 5. Requirement 7 — recovery-case coverage map (all ten cases have concrete tests, all passing today)

| Case | Concrete tests (suite) |
|---|---|
| Missing files | `test_classify_missingCandidateFile_isUndecodable`, `test_importFile_missingFile_failsWithoutAdd` (MusicImportEngine); `testImportTimeFileDisappearanceIsCaughtBeforeAnyWrite` (app) |
| Corrupt FLAC | `testLoadTagsCorruptFileIsFailVisible`, `testProbeRejectsUndecodableContent`, `testFlacPictureParserRejectsNonFlacAndTruncated`, `test_realFLAC_garbagePositionalTags_stayNilAndReview`, `test_corruptFLAC_hashableButNeverVerified` |
| Permission denial | `testWorldWritablePathOutsideGrantsIsDenied` (kernel-enforced, signed app), `testUserSelectedReadWriteIsEffective` (SandboxWriteBehavior); `testNoBroadFilesystemEntitlements`, `testSandboxIsOn` (entitlement regression) |
| Music.app not running | `test_isMusicReachable_viaVersionProbe` (version probe) + failed-survey fail-stop chain: `test_surveyFile_failedSurvey_isNilFailStop`, `testFailedPreflightSurveyIsNeverConverted`, `testMidListSurveyFailureNeverShiftsPairingAndNeverAutoImports` — not-running and TCC denial both reduce to nil/failed survey at the adapter boundary, which fails closed end-to-end |
| TCC denial | `testImportTimeSurveyFailureStopsTheWrite` (no `.attempted` record, no add), `testUnresolvedReviewAndFailedSurveysAreNeverWritten`, plus the failed-survey chain above |
| Interrupted conversion | `testAtomicPromoteNoPartialFileVisible`, `testNeverOverwritesForeignFileAtDestination`, `testIdempotentSecondRunSkipsValidOutput`, `testReconvertsOurInvalidPriorOutput`, `testJournalAppendIsDeterministicAndAtomicFileExists`, `testJournalUnreadableTreatedAsEmpty`, `testReplayThroughSharedJournalSkipsValidDestination` |
| Interrupted Music.app import | `test_importFile_addReturnsNil_recordsFailureHonestly` (`.attempted` recorded, honest failure), `test_importFile_readBackDoesNotConfirm_reconcileBeforeRetry`, `test_importFile_readBackSurveyFails_reportsUncertain`, `test_importFile_retryAfterUncertain_reconcilesAgainstFreshState`, `testPriorVerifiedImportIsSkippedEvenAfterConfirmation` |
| Metadata conflicts | `test_importFile_metadataCollision_goesToReviewNotAutoImport`, `test_classify_metadataCandidateDifferentBytes_requiresReview`, `test_classify_compilationAlbumArtistMismatch_requiresReview`, `test_classify_discTrackTransposition_requiresReview`, `test_alternateMix_differentTitle_requiresReview`, `test_remaster_sameDurationDifferentDisc_requiresReview`, `test_liveVersion_differentAlbumAndDuration_neverVerified`, `testAmbiguousSourceRequiresExplicitResolutionBeforeConversion`, `testReviewPairingIsExactAndUnresolvedConflictsNeverAutoImport` |
| Repeated execution | `test_run1_honestCounts_thenRun2Idempotency_noBlindReAdd` (run-2: 0 adds, 27 priorVerified short-circuits), `test_importFile_priorVerifiedRecord_skipsWithoutReAdd`, `testIdempotentSecondRunSkipsValidOutput` |
| Destination collisions | `testNeverOverwritesForeignFileAtDestination`, `testReconvertsOurInvalidPriorOutput`, `testPlanBatchesSameNamedRootsCollideDeterministically`, `testIdempotentSecondRunSkipsValidOutput` |

## 6. Four-album acceptance results (Requirement 6)

Fixtures are **deterministic and disposable**: 4 albums (12/10/10/8 tracks), 40 real ffmpeg-generated FLAC bitstreams built at test time (no `XCTSkip` taken), nested `CD1`/`CD2` layout for the fourth album, 13 recordings simulated as already existing in a deterministic in-memory Music.app library (4 byte-identical hash twins + 9 cross-format AAC twins), 27 provably missing. Includes alternate mixes, remasters, live-version trap, compilation album-artist mismatch, disc/track transposition, at-tolerance boundary control.

- **Survey census (honest):** 27 `noCandidate` / 4 `exactDuplicate` / 9 `verifiedExisting` / **0** `needsReview` — ambiguous fixtures are a separate adversarial bucket, never misclassified to force numbers.
- **Run 1:** **27 imported / 13 skipped / 0 review / 0 failed / 0 unintended duplicates**; journal records 27 `.attempted` + 27 `.verified` (54 records); all 40 originals SHA-256 unchanged; the 13 pre-existing library references element-wise unchanged; library grew by exactly 27.
- **Run 2 (same operation again):** **0 newly imported, 0 adds**; 40 skipped; 27 `priorVerified` short-circuit **before** any re-survey; only the 13 existing titles re-surveyed; journal still 54; no unrelated library changes.
- **Adversarial bucket:** 5 ambiguous fixtures → all `needsReview`, never auto-imported; at-tolerance control verifies as existing; explicit resolution imports exactly the one resolved file.

Full detail: child report `four-album-acceptance-report.md` (attachment on card `t_6adaba95`) and `Packages/TunoryCore/Tests/TunoryCoreTests/FourAlbumAcceptanceTests.swift` (`8b106de`).

## 7. Signed-app runtime evidence (Requirement 4/8)

Release product (per-project DerivedData, relinked at HEAD 2026-10-23 12:43):

- `codesign -dv`: `Identifier=com.raelldottin.tunory`, `TeamIdentifier=DHJQ7QC53Z`; `codesign --verify --deep --strict --verbose=2` → `valid on disk` + `satisfies its Designated Requirement`.
- Bundle identity: `CFBundleIdentifier=com.raelldottin.tunory`, `CFBundleDisplayName=Tunory` — canonical for **both** Debug and Release.
- Effective Release entitlements: `com.apple.security.app-sandbox=true`, `com.apple.security.files.user-selected.read-write=true`, `com.apple.security.automation.apple-events=true`, `com.apple.security.cs.disable-library-validation=false`, `com.apple.security.network.client=true`, `get-task-allow=true` (development-signed; distribution signing not exercised — same classification as the Phase 10 report).
- **No broad filesystem entitlement**; sandbox never disabled. The Debug product additionally carries Xcode-injected test-host exceptions (`temporary-exception.files.absolute-path.read-only /`, `testmanagerd` mach-lookup) used only for app-hosted testing — absent from Release.
- Kernel-enforced behavior (not mock-only): `SandboxWriteBehaviorTests` inside the signed sandboxed app — 5/5 PASS.

## 8. Proof-level ledger (what is and is not proven)

| Claim | Proof level |
|---|---|
| Discovery/conversion/import/journal contracts, duplicate classification, idempotency, recovery, non-modification | **Runtime PASS** — 275 core + 72 app-hosted tests at `8b106de`, real FLAC fixtures, deterministic fakes |
| Sandbox + entitlements on the signed built product | **Runtime PASS** — `codesign` + kernel-enforced behavior tests |
| Builds at HEAD | **BUILD SUCCEEDED** Debug + Release (incremental at HEAD; cold-build evidence at `fa98e3f` run 142) |
| Live Music.app discovery / TCC prompt / real-library import | **NOT ATTEMPTED — owner-gated by board rule.** All automated library state is the injected fake; **no live Apple Events claim is made** |
| GUI XCTest (`TunoryUITests`) | **NOT COMPLETED this run** — runner init failed twice with `LocalAuthentication Code=-4 "System authentication is running"` (concurrent system-auth session; environmental, exit 65). The test file is byte-identical since before Phase 10's native pass (13/13 documented in `docs/phase10-local-import-integration-report.md`; `git diff --stat 9cc872d..HEAD -- TunoryUITests/` is empty). ViewModel-level GUI integration contracts at HEAD are covered by the 72-test app suite. Owner re-run: §9-A |

## 9. Remaining human acceptance — precise operator instructions

**A. GUI XCTest re-run (optional, ~5–10 min, requires an unlocked interactive session):**

```bash
cd <worktree>/repo   # workspaces/t_691853ee/repo @ 8b106de
xcodebuild -project Tunory.xcodeproj -scheme Tunory -configuration Debug \
  -destination 'platform=macOS' -allowProvisioningUpdates \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -only-testing:TunoryUITests test
```

Expect 14/14. The automation context cannot run this: the runner needs interactive system-auth, which a concurrent session was blocking.

**B. Live four-album Music.app acceptance (the owner-gated live drive, ~10–15 min):**

1. Launch the built Release app (`…/DerivedData/Tunory-*/Build/Products/Release/Tunory.app`).
2. Import tab → add the four real album folders (multi-select), **or** the single parent folder. Confirm nested/disc subfolders are discovered recursively and metadata rows look right.
3. On the first library survey, approve the Automation TCC prompt (Apple Events → Music).
4. Run duplicate preflight. Expect existing recordings listed as skipped (`exactDuplicate`/`verifiedExisting`); only missing recordings become import candidates; any conflict surfaces for explicit review (never auto-imported).
5. Pick the destination via the system picker (this grants the read-write powerbox access).
6. Convert (AAC 256 kbps default; ALAC optional), then confirm the import in the review dialog.
7. Verify the results screen: imported = missing only; skipped = existing; journal recorded.
8. Run the same operation again: expect 0 newly imported, prior-verified skips.
9. In Music.app: confirm no existing tracks were modified/overwritten and the new imports landed correctly.

Report counts + any deviation back on card `t_6069340a`.

## 10. Release-readiness verdict

**CONDITIONAL — automated acceptance complete; NOT release-ready for live Music.app use yet.**

All automated gates pass at `8b106de` (275 + 72 tests, both builds, signed-product entitlements, four-album honest-count acceptance, idempotency, recovery matrix, catalog-workflow regression 155/155). Live release additionally requires: (a) the owner-gated live GUI acceptance of §9-B (real TCC prompt, real library, four real albums), and optionally (b) the §9-A GUI XCTest re-run. No claim of live TCC proof is made anywhere in this report; simulated Music.app responses are never presented as live evidence.

## 11. Repository state and clean-stop classification

- **Worktree `wt/t_691853ee`: CLEAN** at `8b106de`, 0/0 vs origin (re-verified after all QA runs; test/build products live in DerivedData/SwiftPM `.build`, both ignored). This report is committed and pushed on PR #12.
- **Canonical checkout** (`/Users/raelldottin/Documents/Personal/Tunory`): carries a **pre-existing local-only commit `1fc4174` on `codex/ui-robustness`** (titled "wip(t_6069340a): stage uncommitted files for clean start") left by an earlier run of this card. Not pushed, **not touched by this run** — user-owned state preserved per `AGENTS.md`. Flagged for the owner to review/publish or discard.
- No background processes remain from QA; logs and result bundles are in the profile scratch directory and DerivedData `Logs/Test`.
- Classification: **clean stop (worktree)** + **protected-dirty (canonical checkout, pre-existing, owner-owned)**.

## 12. Commit SHAs and PR URLs

- Phase 11 commits: `15eed22` · `19625d9` · `da9aa8c` · `63a8496` · `8b106de` (HEAD, the five child cards in order)
- Earlier branch content (Phase 10 tail + GAP A–D): `c16ef31`…`fa98e3f` (21 commits) — unchanged, previously reviewed in prior cards
- PR #12: https://github.com/raelldottin/tunory/pull/12 (base `wt/t_d354af27` ← head `wt/t_691853ee`)
- Preserved chain: #1 `codex/agents-research-qa-guidance` ← #2 `codex/ui-robustness` ← #3 `codex/local-import` ← #5 `wt/t_d07f9a4d` ← #4 `wt/t_d354af27` ← **#12 `wt/t_691853ee`** (all open, none merged, no history rewritten)
