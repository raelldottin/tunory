# Phase 10 — Local Music Import Integration Report

Date: 2026-10-13 (native-engine update 2026-10-14)
Task: t_559e5375 (Phase 10 — Local Music Import Integration and Release Readiness)
Repository: raelldottin/tunory
Report author: tunory-builder (Hermes Kanban worker)

## 0. Native in-process conversion engine (owner decision D1, 2026-10-13)

Owner decision D1 replaced the external FFmpeg conversion with an
in-process AVFoundation/Core Audio engine. The engine now runs entirely
inside the sandboxed app: no external executable, no Homebrew or PATH
dependency, no sandbox changes. Design and evidence:

- **Decoding/encoding** (`LocalImportEngine.encode/encodeOnQueue`):
  `AVAudioFile` streaming copy in 65,536-frame chunks, Float32 client
  format on both read and write sides (forcing integer commonFormat on the
  writer against Float32 buffers corrupts audio — measured ≈5.4x amplitude
  error, d1-probe probe7; the encoder converts internally).
- **AAC 256 kbps profile**: `kAudioFormatMPEG4AAC` at the reader's sample
  rate/channel count. `AVEncoderBitRateKey` is deliberately NOT set:
  empirically (macOS 27 SDK, probe5/probe7) 256,000 makes Apple's encoder
  overshoot to 412–424 kbps and 128,000 is ignored; the encoder default
  lands at ~260 kbps @44.1 kHz on worst-case pink noise (within the
  256k+10% contract ceiling) and lower on real music (VBR).
- **ALAC profile**: `kAudioFormatAppleLossless`; Float32 → bit-exact PCM
  roundtrip verified (maxDiff=0 across 441,000+ frames; 24-bit sources
  land as 32-bit ALAC, a lossless superset).
- **Metadata + artwork** (`applyMetadata` + FLAC PICTURE parser): after
  encode+flush, source tags are mapped to common identifiers and injected
  via a passthrough `AVAssetExportSession` (payload untouched — verified);
  FLAC artwork is parsed from the file-level PICTURE block (type 6;
  AVFoundation does not expose it) and injected as artwork. No source
  metadata/artwork → no-op.
- **Flush discipline**: `AVAudioFile` flushes on deinit only; the writer
  is function-scoped so deinit fires deterministically before validation
  and atomic promotion.
- **Removed**: `runFFmpeg`, `ffmpegURL`, `ffmpegPresent`,
  `resolveFFmpegInPATH` — zero `Process(`/ffmpeg references remain in the
  engine or app layer (verifier-verified).
- **Dependency licensing**: none added — AVFoundation/Core Audio are
  Apple system frameworks. FFmpegKitNext and libFLAC were NOT adopted
  (native decoding proved sufficient, including FLAC).

**Transaction-safety defect fixed (26faebb, verifier-proven):**
`sha256Hex` previously returned the empty-data digest (e3b0c442…) for
read-denied files, misclassifying two distinct unreadable files as
byte-duplicates of each other (live-observed: a FLAC and an MP3, both
sandbox read-denied). It now returns nil on open-failure and read-failure;
the regression test `testUnreadableFileHasNoSHA256AndIsNotDuplicate`
covers it. No digest is better than a wrong digest.

## 1. Repository reconciliation (objective 1)

Verified facts (from live git/GitHub inspection, 2026-10-13):

- `main` = `0ddd5d4`, synchronized with `origin/main`.
- `codex/agents-research-qa-guidance` = `221788a`, synchronized; PR #1 (→ main), MERGEABLE, not merged (unrelated to this phase).
- `codex/ui-robustness` = `0f53c1a`, synchronized; PR #2 (→ codex/agents-research-qa-guidance), MERGEABLE, not merged (unrelated to this phase).
- `codex/local-import` = `dd98980`, 4 commits ahead of `codex/ui-robustness`
  (merge-base `0f53c1a`): `07553a5`, `7cf3a95`, `25f1cab`, `dd98980`.
  Published to `origin/codex/local-import` (fast-forward push, new branch; no
  reset/rebase/force-push of anything). Review PR: **#3** (base
  `codex/ui-robustness`). PRs #1/#2 were NOT merged — out of scope here.
- Canonical checkout `/Users/raelldottin/Documents/Personal/Tunory` carries
  user-owned dirty state NOT touched by this task:
  - `Tunory.xcodeproj/project.pbxproj` (modified) — Xcode 17.x re-serialization
    of the SAME committed dd98980 project semantics (checked: `git show
    dd98980:...pbxproj` == committed HEAD version; dirty file only reorders
    sections/reformats entries; no setting change). Left in place, untouched.
  - untracked: `.swarm/`, `DESIGN.md`, `Packages/.build/` (build artifacts).
- The stale workspace worktree registration for t_5ed9e8d3 was pruned
  (`git worktree prune`); its directory no longer existed. No work lost — the
  branch lives in the repository.

## 2. Implemented functionality (objective 2/3, from the completed swarm)

All of the following shipped on `codex/local-import` (dd98980) and were
re-verified in this phase, not re-implemented:

- `Packages/TunoryCore/Sources/TunoryCore/AudioProber.swift` — deterministic
  content probe: AVFoundation decode + CoreMedia format description (four-char
  codec codes); identity from container bytes, never file extensions.
- `Packages/TunoryCore/Sources/TunoryCore/LocalImportEngine.swift` — the
  canonical decision engine: planFiles/planBatch + `decision(for:)` as the
  single decision authority (the dead single-file `plan(source:)` duplicate
  was removed, Phase 10 cleanup PR #4), native in-process conversion
  (AVFoundation AAC 256 kbps reference profile; ALAC opt-in, lossless-only),
  lossy→lossy forbidden (mp3/aac passthrough), idempotent valid-output skip,
  never overwrite foreign destination files, append-only conversion journal,
  atomic temp+promote, metadata/artwork preservation via passthrough export,
  nil-on-error SHA-256 duplicate detection.
- `Packages/TunoryCore/Tests/TunoryCoreTests/LocalImportEngineTests.swift` —
  native conversion (AAC/ALAC), duplicate detection (SHA-256 byte equality,
  incl. unreadable-file non-duplicate regression), profile blocks,
  destination conflicts, idempotency, metadata/artwork roundtrip.
- GUI: `Tunory/LocalImportView.swift`, `LocalImportViewModel.swift` —
  select → analyze → duplicate review → convert → results; thin adapter over
  the engine (decisions never re-derived in presentation code).
- CLI: `Tunory/TunoryApp.swift` `local-import` verb — headless, same
  canonical engine, deterministic JSON output, honest exit codes
  (0 ok / 2 usage / 3 entry conflict or failure).
- Music.app import is wired as of `c22618e` + `4c4a1d6` (owner decision
  D2, 2026-10-14): `MusicImportEngine` (TunoryCore) + `MusicAppScripting`
  (in-process NSAppleScript adapter) + GUI survey → review → importing →
  results flow + `music-import` CLI verb. `add` via Music.app Apple Events
  is the only write; the app never touches the Music library database.
  Live TCC proof is still pending (§4.1).

## 3. Validation evidence (objective 5)

Re-validated at `codex/local-import` @ `26faebb` (native engine +
sha256Hex fix), run 2026-10-14:

| Check | Result |
|---|---|
| `swift test` (Packages/TunoryCore) @ 26faebb | **PASS — 180/180 tests, 0 failures** (incl. native AAC/ALAC conversion, duplicate safety, unreadable-file regression, idempotency, profile blocks, destination guards) |
| `swift test` on PR #4 re-stack merge (2ea9083 + 26faebb) | **PASS — 180/180 tests, 0 failures** |
| `xcodebuild … Debug, platform=macOS` @ 26faebb | **PASS — BUILD SUCCEEDED** (§3a, 2026-10-14) |
| `xcodebuild … Release, platform=macOS` @ 26faebb | **PASS — BUILD SUCCEEDED** (§3a, 2026-10-14) |
| Signed-app identity (`defaults read` on built app, run 86 & verifier re-check) | **PASS — `com.raelldottin.tunory`, display name `Tunory`, Team `DHJQ7QC53Z`** |
| Effective entitlements (codesign on built app, verifier re-check at aed2ad8) | app-sandbox ON, user-selected read-only ON, automation.apple-events ABSENT at that pre-D2 anchor (entitlement lands at c22618e; see §3a for the 9cc872d evidence) |
| Stale identifier sweep | PASS — remaining `Turnory` / `com.raelldottin.Tunory` hits are documented historical evidence in `docs/` and AGENTS.md's canonical "do not reintroduce" list |
| Generated-artifact tracking (`git ls-files` sweep) | PASS — no `.DS_Store`, `.build/`, `AMHelper.app/`, `xcuserdata/`, `*.xcuserstate` tracked |

### 3a. Build verification at the integration tip

Validation at `codex/local-import` @ `26faebb` (native engine + sha256Hex
fix), run 2026-10-14 (historical — predates the Music.app integration):

- `xcodebuild … Debug, platform=macOS`: **PASS — BUILD SUCCEEDED** (783s).
- `xcodebuild … Release, platform=macOS`: **PASS — BUILD SUCCEEDED** (792s).
- Built-product identity on the fresh Debug build:
  `CFBundleIdentifier = com.raelldottin.tunory`,
  `CFBundleDisplayName = Tunory`, `TeamIdentifier = DHJQ7QC53Z`;
  entitlements: app-sandbox ON, user-selected read-only ON,
  `com.apple.security.automation.apple-events` ABSENT at 26faebb —
  that entitlement enters the entitlements file at `c22618e` (owner
  decision D2, 2026-10-14), so it is NOT part of the 26faebb evidence.

Integration-tip validation (run 2026-10-15 at `wt/t_d07f9a4d` @ `9cc872d`,
which contains c22618e + 4c4a1d6 + the security-scoped fix; full evidence
in the t_1ffa71ab integration report §2):

- `swift test` (TunoryCore): **PASS — 207/207, 0 failures**.
- `xcodebuild test` (TunoryTests): **PASS — 35/35** (incl.
  LocalImportViewModelSecurityScopeTests 5/5); TunoryUITests **13/13**.
- `xcodebuild … Release, platform=macOS`: **BUILD SUCCEEDED** — first
  Release build at 9cc872d.
- Signed-product identity, both configurations:
  `com.raelldottin.tunory` / `Tunory` / Team `DHJQ7QC53Z`;
  `codesign --verify --deep --strict` OK (dev-signed; distribution
  signing NOT exercised).
- Effective entitlements on the built products (Debug and Release):
  app-sandbox **ON**, automation.apple-events **ON** (landed c22618e
  per D2), user-selected read-only **ON** (synthesized by
  `ENABLE_USER_SELECTED_FILES = readonly` in the committed pbxproj),
  network.client **ON**.

Historical baseline (2026-10-13, dd98980, ffmpeg-era engine): swift test
175/175 PASS; Debug and Release BUILD SUCCEEDED; live signed-app e2e
proved the sandbox fail-closed correctly — originals byte-identical
afterwards, zero partial outputs, zero journal records. **No duplicate
import, no metadata mutation, no library write occurred.** The native
engine preserves all of these properties by construction (in-process
APIs; no child processes at all).

## 4. Missing runtime proof / blocked acceptance criteria

1. **Music.app import (Apple Events automation) — PENDING TCC proof.**
  Owner decision D2 (2026-10-14) authorized the entitlement, which is now
  present. Live TCC acceptance proof (Music.app scripting prompt) and
  live Music.app writes (even to a disposable playlist) still need to be
  verified.
2. **Headless CLI source reads — BLOCKED by design.** The sandbox only
   grants reads for files picked via NSOpenPanel (GUI). A CLI caller
   passing paths on argv gets fail-closed analysis/conversion failures.
   GUI flow works; headless conversion needs either a non-sandboxed helper
   (owner decision) or another sanctioned mechanism.
3. **Live writes to the real Music library — NOT ATTEMPTED by policy.** No
   live library mutation was performed at any point in this phase.
4. **Release readiness — NOT proven.** With items 1–2 unresolved, the app
   is NOT release-ready for the end-to-end local-import feature: the
   conversion engine itself is now native, in-process, and
   sandbox-compatible (D1 resolved), but the final Music.app import step
   awaits owner authorization (D2) and human acceptance.

## 5. Owner decisions

- D1: **RESOLVED (2026-10-13)** — in-process AVFoundation/Core Audio
  conversion engine; no external ffmpeg. Implemented at `aed2ad8`,
  hardened at `26faebb`.
- D2: **RESOLVED (2026-10-14)** — owner authorized Apple Events automation
  entitlement and wiring Music.app import. The entitlement is now present.
  TCC acceptance proof for live Music.app writes still pending.
- D3: **RESOLVED as "do not merge"** — PRs #1/#2 remain open, untouched,
  merge decisions deferred to the owner.

## 6. Deliverables

- Branch published: `origin/codex/local-import` @ `26faebb`
  (aed2ad8 native engine; 26faebb sha256Hex fix + regression test).
- Integration stack published 2026-10-15: `origin/wt/t_d07f9a4d` @
  `9cc872d` — c22618e (Music.app Apple Events engine + entitlement) →
  4c4a1d6 (GUI/CLI wiring) → 9cc872d (security-scoped resource fix) —
  review PR with base `codex/local-import`.
- Review PR: https://github.com/raelldottin/tunory/pull/3 (base codex/ui-robustness).
- Cleanup PR #4 (wt/t_d354af27) re-stacked onto the new tip via merge
  commit `5e6d906` (fast-forward push, no force-push, no history
  rewrite): https://github.com/raelldottin/tunory/pull/4
- This report: `docs/phase10-local-import-integration-report.md`.

## 7. Clean-stop classification

- `codex/local-import` branch: synchronized with `origin/codex/local-import`
  (`git rev-list --left-right --count HEAD...@{u}` = `0 0`) at `c16ef31`.
- Publication worktree (wt/t_d07f9a4d @ `9cc872d`): this report update is
  committed on the publication branch; branch pushed to origin, no
  force-push at any point in Phase 10.
- Canonical checkout `/Users/raelldottin/Documents/Personal/Tunory`:
  **PROTECTED-DIRTY STOP** — upstream `codex/ui-robustness` synchronized;
  remaining dirty/untracked paths are user-owned, pre-existing, and were NOT
  changed by this task (reformatted `project.pbxproj` with unchanged
  semantics; `.swarm/`, `DESIGN.md`, `Packages/.build/`).
- PRs #1 and #2: left open, untouched, per owner decision D3.

## 8. Proof levels

- Swift unit/integration incl. native conversion (AAC 256k, ALAC,
  metadata/artwork, duplicate safety, idempotency): **PASS (runtime,
  180/180 @ 26faebb and on the PR #4 re-stack merge)**.
- Debug/Release builds @ 26faebb: recorded in §3a (final pass); verifier
  independently confirmed PASS at aed2ad8 (same code, pre-report).
- Signed-app identity/entitlements: **PASS (runtime, built product)** —
  sandbox ON, automation.apple-events ON (landed c22618e per owner
  decision D2, 2026-10-14), user-selected read-only ON; verifier
  re-check at aed2ad8 confirmed apple-events ABSENT there (correct —
  pre-D2 anchor).
- Sandbox behavior under denial: **PASS (live runtime evidence,
  fail-closed verified at dd98980; native engine is in-process so the
  exec-denial class no longer exists)**.
- Music.app automation import: **NOT ATTEMPTED (live TCC proof pending —
  D2 authorizes implementation and testing incl. the TCC prompt, but no
  live Apple Events exchange has been driven from the signed app)**.
- Live Music library writes: **NOT ATTEMPTED (policy)**.
- Release readiness: **NOT PROVEN (blocked on §4 items 1–2: TCC
  authorization for Music.app import and human acceptance)**.
