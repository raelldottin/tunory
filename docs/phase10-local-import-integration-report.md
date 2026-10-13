# Phase 10 — Local Music Import Integration Report

Date: 2026-10-13
Task: t_559e5375 (Phase 10 — Local Music Import Integration and Release Readiness)
Repository: raelldottin/tunory
Report author: tunory-builder (Hermes Kanban worker)

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
  canonical decision engine: plan/planFiles/planBatch (pure, no side effects),
  owner reference conversion (ffmpeg AAC 256 kbps; ALAC opt-in, lossless-only),
  lossy→lossy forbidden (mp3/aac passthrough), idempotent valid-output skip,
  never overwrite foreign destination files, append-only conversion journal,
  atomic temp+promote, race-free ffmpeg child handling with concurrent stderr
  drain.
- `Packages/TunoryCore/Tests/TunoryCoreTests/LocalImportEngineTests.swift` —
  20+ tests incl. live-ffmpeg synthetic conversion, duplicate detection
  (SHA-256 byte equality), profile blocks, destination conflicts, idempotency.
- GUI: `Tunory/LocalImportView.swift`, `LocalImportViewModel.swift` —
  select → analyze → duplicate review → convert → results; thin adapter over
  the engine (decisions never re-derived in presentation code).
- CLI: `Tunory/TunoryApp.swift` `local-import` verb — headless, same
  canonical engine, deterministic JSON output, honest exit codes
  (0 ok / 2 usage / 3 entry failure / 4 ffmpeg unusable in sandbox).
- Music.app import is intentionally NOT wired: no Automation entitlement;
  the flow ends at conversion results; adding to Music.app is a manual
  operator action. The app never touches the Music library database.

## 3. Validation evidence (objective 5) — run 2026-10-13, fresh worktree at dd98980

| Check | Result |
|---|---|
| `swift test` (Packages/TunoryCore) | **PASS — 175/175 tests, 0 failures** (incl. live-ffmpeg synthetic conversion, duplicate safety, idempotency, profile blocks, destination guards) |
| `xcodebuild … Debug, platform=macOS` | **PASS — BUILD SUCCEEDED** |
| `xcodebuild … Release, platform=macOS` | **PASS — BUILD SUCCEEDED** |
| Signed-app identity (`defaults read` on built Debug app) | **PASS — `com.raelldottin.tunory`, display name `Tunory`, Team `DHJQ7QC53Z`** |
| Effective entitlements (codesign on built app) | app-sandbox ON, network-client ON, user-selected read-only ON, library-validation OFF, `com.apple.security.automation.apple-events` ABSENT (expected) |
| Live signed-app CLI e2e (synthetic FLAC + MP3, scratch dirs) | **FAIL-CLOSED CORRECTLY** — see §4; transaction safety held |
| Stale identifier sweep | PASS — remaining `Turnory` / `com.raelldottin.Tunory` hits are documented historical evidence in `docs/` and AGENTS.md's canonical "do not reintroduce" list |
| Generated-artifact tracking (`git ls-files` sweep) | PASS — no `.DS_Store`, `.build/`, `AMHelper.app/`, `xcuserdata/`, `*.xcuserstate` tracked |

Live e2e detail: the signed sandboxed app invoked as
`Tunory.app/Contents/MacOS/Tunory local-import <out> <src>`:

- Plan/analysis ran and emitted correct JSON (synthetic FLAC identified, mp3
  flagged for passthrough).
- Every conversion attempt failed closed: the sandbox denies exec on
  `/opt/homebrew/bin/ffmpeg` and denies reads of argv-passed paths that the
  powerbox never granted.
- Exit codes honest (3 per-entry failure, 4 ffmpeg-unusable); explicit
  `ffmpeg missing/unusable` detail in output.
- Originals byte-identical afterwards (SHA-256 verified); zero partial
  outputs in destination dirs; zero journal records written. **No duplicate
  import, no metadata mutation, no library write is possible in this state.**

## 4. Missing runtime proof / blocked acceptance criteria

1. **FFmpeg under the App Sandbox — BLOCKED on an owner packaging decision.**
   Live-proven: the signed app cannot exec the Homebrew ffmpeg. Options
   (from research t_dc244b34): user-installed ffmpeg must be reachable and
   executable by the sandboxed app (today it is not), or Tunory ships a
   signed, license-cleared, sandbox-compatible ffmpeg packaging. The Homebrew
   binary must NOT be redistributed. This is the single blocker between the
   current state and a working end-user conversion workflow.
2. **Headless CLI source reads — BLOCKED by design.** The sandbox only grants
   reads for files picked via NSOpenPanel (GUI). A CLI caller passing paths on
   argv gets fail-closed analysis/conversion failures. GUI flow works; headless
   conversion needs either a non-sandboxed helper (owner decision) or another
   sanctioned mechanism.
3. **Music.app import (Apple Events automation) — NOT ATTEMPTED, owner
   approval required.** No entitlement present; wiring it needs the owner's
   explicit go-ahead plus TCC proof (Music.app scripting prompt).
4. **Live writes to the real Music library — NOT ATTEMPTED by policy.** No
   live library mutation was performed at any point in this phase.
5. **Release readiness — NOT proven.** With items 1–3 unresolved, the app is
   NOT release-ready for the local-import feature; the GUI flow is usable
   only when the user's ffmpeg is sandbox-executable.

## 5. Owner decisions requested

- D1: FFmpeg packaging route for the sandbox (ship a signed compatible build
  vs. document user installation requirements vs. gated non-sandboxed helper).
- D2: Whether/when to add the Apple Events automation entitlement and wire
  Music.app import (requires TCC acceptance proof).
- D3: Whether to merge PRs #1/#2 (unrelated, left open deliberately).

## 6. Deliverables

- Branch published: `origin/codex/local-import` @ `dd98980`.
- Review PR: https://github.com/raelldottin/tunory/pull/3 (base codex/ui-robustness).
- This report: `docs/phase10-local-import-integration-report.md`.

## 7. Clean-stop classification

- `codex/local-import` worktree (t_559e5375): **FULLY CLEAN** — no dirty
  paths; branch synchronized with `origin/codex/local-import`
  (`git rev-list --left-right --count HEAD...@{u}` = `0 0` after this
  report commit lands on the same branch).
- Canonical checkout `/Users/raelldottin/Documents/Personal/Tunory`:
  **PROTECTED-DIRTY STOP** — upstream `codex/ui-robustness` synchronized;
  remaining dirty/untracked paths are user-owned, pre-existing, and were NOT
  changed by this task (reformatted `project.pbxproj` with unchanged
  semantics; `.swarm/`, `DESIGN.md`, `Packages/.build/`).
- PRs #1 and #2: left open, untouched, per task instruction.

## 8. Proof levels

- Swift unit/integration incl. live conversion: **PASS (runtime)**.
- Debug/Release builds: **PASS (runtime)**.
- Signed-app identity/entitlements: **PASS (runtime, built product)**.
- Sandbox behavior under denial: **PASS (live runtime evidence, fail-closed
  verified)**.
- Music.app automation import: **NOT ATTEMPTED (owner approval required)**.
- Live Music library writes: **NOT ATTEMPTED (policy)**.
- Release readiness: **NOT PROVEN (blocked on §4 items)**.
