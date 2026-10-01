# AGENTS.md

Tunory is an Apple-platform music app built around Apple Music / MusicKit workflows. This repository is the system of record for product behavior, application identity, architecture decisions, validation evidence, and agent handoffs.

Prefer the smallest safe change that preserves verified behavior. When a change reveals a durable architectural rule, operational procedure, or non-obvious root cause, document it in `docs/` and curate it into project memory when appropriate.

## Canonical Repository Identity

Treat these values as canonical unless the repository is intentionally migrated:

```text
Product / target / scheme / display name: Tunory
Bundle identifier:                       com.raelldottin.tunory
Apple Developer Team ID:                 DHJQ7QC53Z
Xcode project:                           Tunory.xcodeproj
Primary target / scheme:                 Tunory
GitHub repository:                       raelldottin/tunory
Canonical local path:                    /Users/raelldottin/Documents/Personal/Tunory
```

Do not reintroduce stale identifiers such as:

```text
Turnory
com.raelldottin.Tunory
```

Historical documentation may preserve an old identifier when it is describing an artifact that actually used it. Do not rewrite historical evidence merely to make a grep clean.

## Default Operating Mode

For non-trivial repository-changing work:

1. identify the bounded task or implementation slice;
2. capture the current repository state before mutation;
3. inspect the narrowest relevant files and contracts;
4. make the smallest change that satisfies the task;
5. run the narrowest relevant validation first;
6. expand validation only as needed;
7. leave a documented GitHub stop or an explicit blocked handoff.

Read-only research, analysis, comparison, and planning do not require a repository-changing slice. If that work turns into requested implementation, establish scope before mutation.

Do not make opportunistic product changes outside the active task.

## ECC Preflight

When Tunory work runs under Hermes, ECC enforcement is a hard preflight requirement.

Dispatcher-spawned workers may use a profile-specific `HERMES_HOME`, for example:

```text
~/.hermes/profiles/tunory-builder
~/.hermes/profiles/tunory-verifier
```

Do not assume plugins installed in the default Hermes home are active in a worker profile.

Before implementation in a fresh worker process, verify all of the following:

```text
ECC skills:                 PASS
ECC hooks:                  PASS
ECC doctor / health check:  PASS
Canonical Tunory repo:      PASS
```

The hook check must be live, not inferred from files on disk. Confirm that forbidden operations are blocked and benign operations are allowed.

If ECC hooks are repaired or enabled after a worker has already started, do not continue implementation in that process. Plugin state may have been snapshotted at startup. Requeue into a fresh worker and rerun the preflight.

If any ECC preflight check fails, block the task rather than implementing without enforcement.

## Agent Orchestration Safety

Workers must not directly mutate Hermes Kanban SQLite databases as a fallback for lifecycle operations.

If a child worker cannot perform a task lifecycle mutation such as complete, block, or requeue, it must return a structured lifecycle request to the dispatcher/orchestrator and exit. The dispatcher/orchestrator owns board mutation.

Do not teach or preserve direct SQLite mutation as an accepted recovery path.

Do not recursively self-spawn agents from inside an agent run unless the repository explicitly introduces and validates such an orchestration design.

## Diagnosis And Change Scope

For defect work:

- capture a reproducer or concrete failing evidence before changing implementation;
- identify the authoritative product or platform contract;
- distinguish product defects from stale expectations, generated artifacts, signing/configuration defects, environment failures, and test-fixture defects;
- fix the affected path first;
- change shared helpers or abstractions only when the confirmed defect requires it;
- preserve unrelated callers and defaults unless the task explicitly changes them.

When changing tests, fixtures, snapshots, thresholds, or expected values to resolve a failure, record why the old expectation is wrong or why the product contract is intentionally changing.

Do not weaken acceptance criteria merely to clear a gate.

## Generated Files And Repository Hygiene

Do not commit generated build output or local IDE state.

At minimum, keep these out of version control:

```gitignore
.DS_Store
Tools/AppleMusicAPI/.build/
Tools/AppleMusicAPI/AMHelper.app/
xcuserdata/
*.xcuserstate
```

If a generated path is already tracked, remove it from Git tracking without deleting the user's local copy when appropriate.

Before finalizing a change, inspect:

```bash
git status --short
git diff --check
git diff --cached --check
git ls-files | grep -E '(^|/)\.DS_Store$|^Tools/AppleMusicAPI/\.build/|AMHelper\.app/|xcuserdata/|\.xcuserstate$'
```

The final `git ls-files` check should produce no generated-artifact matches unless an explicitly documented exception exists.

## Commit Hygiene

Use logical commits that correspond to the active task.

Do not add generated attribution trailers or boilerplate such as:

```text
Co-Authored-By: Claude
Generated with Claude Code
```

Before a final push:

```bash
git fetch origin main
git status --short
git branch -vv
git rev-list --left-right --count HEAD...@{u}
```

Never force-push without explicit user approval in the current task.

Do not rewrite an existing commit merely to hide a later-discovered hygiene problem when a normal follow-up cleanup commit preserves clearer history.

## Clean Stop Rule

Every repository-changing handoff must classify the final repository state.

### FULLY CLEAN

- no dirty paths remain;
- current branch is synchronized with its upstream;
- `git rev-list --left-right --count HEAD...@{u}` returns `0 0`.

### PROTECTED-DIRTY STOP

- upstream is synchronized;
- only explicitly protected, pre-existing, user-owned dirty paths remain;
- those paths were not changed by the task;
- the handoff reports them.

This is not a fully clean stop.

### DIRTY / FAILED STOP

Use this when:

- task-created uncommitted changes remain;
- protected paths changed unexpectedly;
- unknown dirty paths exist;
- upstream diverges;
- required validation failed and the task cannot safely close.

Do not claim a clean stop when only the build is clean.

## Apple App Identity

Application identity is a release-critical contract.

For Debug and Release configurations, the effective bundle identifier must be:

```text
com.raelldottin.tunory
```

The built app display name must be:

```text
Tunory
```

With generated Info.plist enabled, inspect the effective build settings rather than assuming project/target renames update Info.plist keys.

Known canonical settings include:

```text
PRODUCT_BUNDLE_IDENTIFIER = com.raelldottin.tunory
INFOPLIST_KEY_CFBundleDisplayName = Tunory
```

After identity changes, verify the built product rather than relying only on source text.

Example:

```bash
APP="$(find ~/Library/Developer/Xcode/DerivedData \
  -path '*/Build/Products/Debug/Tunory.app' -print -quit)"

defaults read "$APP/Contents/Info" CFBundleIdentifier
defaults read "$APP/Contents/Info" CFBundleDisplayName
```

Expected:

```text
com.raelldottin.tunory
Tunory
```

## MusicKit Rules

MusicKit is an Apple Developer App Service for the Tunory App ID.

Do not manually add or invent this entitlement:

```text
com.apple.developer.musickit
```

The absence of that manually-added entitlement is not evidence that MusicKit is misconfigured.

When diagnosing MusicKit behavior, separate these layers:

1. Apple Developer App ID service configuration;
2. Xcode bundle identity and signing;
3. generated Info.plist usage description;
4. Music authorization state;
5. developer-token / MusicKit request behavior;
6. actual catalog or library request results.

Do not change signing, entitlements, or Apple Developer configuration merely because a runtime request failed. Prove which layer is failing first.

The Music usage description should remain explicit and user-facing. If its wording changes, preserve the real read/write behavior of the app.

## Entitlements And Signing

Use Automatic signing unless the task explicitly requires another signing model.

Do not add capabilities speculatively.

When changing signing or entitlements:

- inspect the effective Debug and Release settings;
- inspect the generated entitlements from a real build;
- distinguish App Services from entitlements;
- verify the resulting signed app rather than trusting the project editor alone.

Preserve unrelated sandbox permissions unless the task explicitly changes them.

## Architecture Direction

Keep framework-specific UI concerns at the presentation edge.

As Tunory grows, prefer these boundaries:

- **Domain** — music-selection rules, playlist intent, matching rules, transaction semantics;
- **Application** — orchestration, workflows, authorization sequencing, use cases;
- **Infrastructure** — MusicKit / Apple Music API adapters, persistence, networking, file access;
- **Presentation** — SwiftUI views and platform-specific UI behavior.

Do not introduce a large architecture migration solely to satisfy a small feature slice.

Keep model and matching logic deterministic where practical. Prefer protocols at framework boundaries so Apple-service behavior can be tested without requiring live services in every test.

## Apple Music Data Integrity

Treat user library and playlist mutations as externally visible operations.

For write paths:

- make the intended mutation explicit;
- avoid duplicate writes when retrying;
- preserve ordering when ordering is part of the product contract;
- distinguish read-only proof from write-capable proof;
- record partial-failure behavior;
- design retries so they do not silently multiply playlist items or create duplicate playlists.

Do not claim write behavior is verified from a read-only catalog request.

## Dependency Rule

Do not add or upgrade a third-party dependency merely because an implementation idea names it.

Before adoption, consider:

- license compatibility;
- supported Apple platform and Xcode versions;
- Swift / SwiftPM compatibility;
- binary or download size;
- startup and memory impact;
- privacy and network behavior;
- native Apple-framework alternatives;
- rollback path.

External projects may be used as behavioral or design references, but do not copy source unless licensing has been reviewed and approved.

## Proof Rule

Every handoff must state the proof level reached and the proof levels still missing.

Report required checks as:

```text
PASS
FAIL
NOT ATTEMPTED
BLOCKED
```

For failures, retain the command and actual error.

For blocked checks, identify the concrete prerequisite or policy restriction.

Do not infer success from source inspection when runtime proof is required.

## No Fake Completion

Do not claim Tunory behavior is verified unless it was proven at the appropriate level.

Examples:

- a successful compile does not prove MusicKit authorization;
- Music authorization does not prove developer-token connectivity;
- catalog connectivity does not prove playlist writes;
- simulator or macOS proof does not automatically prove iPhone behavior;
- source inspection does not replace a required signed-app or Apple Developer proof;
- an agent-generated statement does not replace required owner/human confirmation.

If required proof is unavailable, block or hand off with the missing proof stated explicitly.

## Validation

Use the narrowest relevant validation first.

### Project inspection

```bash
xcodebuild -project Tunory.xcodeproj -scheme Tunory -showBuildSettings
```

### macOS clean build

```bash
xcodebuild \
  -project Tunory.xcodeproj \
  -scheme Tunory \
  -configuration Debug \
  -destination 'platform=macOS' \
  -allowProvisioningUpdates \
  clean build
```

### Source / identity sweep

```bash
grep -RIn \
  --exclude-dir=.git \
  --exclude-dir=.build \
  --exclude-dir=AMHelper.app \
  -E 'Turnory|com\.raelldottin\.Tunory' .
```

Any remaining hit must be classified as either:

- active configuration defect; or
- intentional historical evidence.

Do not mechanically rewrite historical records.

### Git validation

```bash
git diff --check
git status --short
git branch -vv
```

### Tests

If dedicated test targets or Swift packages exist for the changed behavior, run the narrowest affected tests first, then broader tests before handoff when justified.

Do not invent a validation command that the repository does not support. If a Makefile, script, or CI workflow becomes authoritative later, update this file to point agents at it.

## Testing

- Add regression tests for confirmed bug fixes where practical.
- Keep tests deterministic with injected time, identifiers, and service boundaries.
- Prefer fakes/stubs for MusicKit-facing unit tests.
- Use live Apple services only when the acceptance requirement actually requires live proof.
- Keep write tests from mutating a real user library unless the task explicitly authorizes that proof.
- Use test-owned temporary storage and preferences when testing persistence.
- Clean up only resources created by the test.

## Documentation

Durable architecture rules, product contracts, root causes, and operational procedures belong in `docs/`.

Do not turn `AGENTS.md` into a chronological incident log.

When documentation describes historical experiments, preserve what actually happened and label historical state clearly rather than silently rewriting it to match current configuration.

## Project Memory

ByteRover is the durable project memory shared with Hermes.

Before revisiting a non-obvious architectural decision, root cause, established convention, or previously investigated problem, query ByteRover.

Curate information when it will be useful in future sessions:

- architectural decisions and rationale;
- confirmed root causes and fixes;
- stable project conventions;
- important constraints;
- verified operational procedures.

Do not curate:

- transient logs;
- speculative ideas;
- credentials;
- access tokens;
- signing secrets;
- temporary task state.

Repository files, current Apple Developer state, and current validation results outrank stale memory.

When a previous conclusion is superseded, update project memory rather than preserving the obsolete conclusion as current truth.

## Secrets And Apple Credentials

Never commit:

- Apple private keys;
- MusicKit keys;
- authentication tokens;
- provisioning credentials;
- certificates containing private key material;
- developer-token material;
- secrets copied from shell history or local configuration.

Before committing credential-adjacent changes, inspect the staged diff.

If a secret is found in Git history, do not merely delete the working-tree copy and claim remediation. Report the exposure and handle history/credential rotation explicitly.

## Product And UI Changes

Tunory should keep music workflows understandable before adding feature breadth.

For UI work:

- preserve clear authorization and connectivity states;
- distinguish read-only state from write-enabled actions;
- make destructive or externally visible playlist/library actions explicit;
- prefer native SwiftUI patterns unless the task requires another approach;
- avoid one-off visual systems that fight the rest of the app.

Do not obscure Apple authorization failures behind generic success UI.

## Final Response Requirements

Every repository-changing handoff must state:

1. what changed;
2. what existing behavior was preserved;
3. what tests or checks were run;
4. the proof level reached;
5. any remaining risk or blocked proof;
6. clean-stop status for every touched repository;
7. whether changes were committed and pushed, with the commit SHA when available.

If nothing changed, say so explicitly.
