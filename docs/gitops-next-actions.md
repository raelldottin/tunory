# Tunory GitOps next actions

Scope: `raelldottin/tunory` only. This checklist turns the broad GitOps work into
bounded actions. It does not implement deployment, change other apps, validate
device alarms, or estimate effort from task history.

## Audit and acceptance

Research snapshot: 2026-10-20, `origin/main` at `0ddd5d4`. The existing stacked
PRs and local work-in-progress commit are separate work. Recheck this inventory
after those branches merge. This table preserves the initial audit; the first
CI implementation and hosted evidence below supersede the workflow gap.

| Observation | Status | Evidence and boundary |
| --- | --- | --- |
| Tracked CI workflows | PASS | `git ls-files .github` returned no paths; the gap is confirmed. |
| Hosted workflow inventory | PASS | `gh workflow list --all -R raelldottin/tunory` returned no workflows. There are no existing CI jobs to reuse. |
| Core package tests | PASS | The command below exited 0: 155 XCTest cases, zero failures. |
| Shared Xcode test scheme | PASS | `Tunory.xcodeproj/xcshareddata/xcschemes/Tunory.xcscheme` has an empty `TestAction` on this base. Package tests run separately. |
| Project settings inspection | PASS | `xcodebuild -project Tunory.xcodeproj -scheme Tunory -showBuildSettings` exited 0. This is configuration evidence. |
| Toolchain | PASS | Apple Swift 6.4, Xcode 27.1; the core package explicitly uses Swift 5 language mode. |
| Branch inventory | PASS | GitHub has `main` and feature branches; `dev` does not exist. |
| Server-enforced review policy | BLOCKED | Protection reads for both requested branch names returned HTTP 403: private repository plan restriction. |
| Hosted CI execution at initial audit | NOT ATTEMPTED | No workflow existed. See the later hosted evidence below. |
| Signed app, device, live MusicKit, release | NOT ATTEMPTED | Outside this documentation slice. |

The first missing check identified was **Core tests**. It reuses an executable
suite already present on `main`, without signing or live Apple Music access.
The initial clean compile reported existing Swift concurrency warnings in test
code; this audit does not resolve them or change language mode.

Acceptance for this slice: inventory the real jobs and one missing check, verify
the reusable command, record executable next actions with dependencies and proof,
and capture the selected review policy without claiming it is enforced.

## Small tasks and explicit next actions

| Task | State | Next action | Completion evidence |
| --- | --- | --- | --- |
| Audit Tunory CI | PASS | Use the inventory above when preparing the first workflow. | Actual tracked and hosted workflow inventories, plus one named missing check. |
| Reuse the core validation checklist | PASS | Run the checklist below on the revision being changed. | Exact SHA, toolchain, command, exit status, test total, and failures recorded. |
| Add the first CI check | PASS | Use the combined CLI check when evaluating PR #6 for integration. | `Core tests` passed all 155 tests on `890de43`; the same workflow failed with exit 1 on the intentional test in `cb72356`. The job also runs the subsequent CLI safety suite. |
| Add exact-commit agent review | BLOCKED | Close the P1 provenance finding with fresh hosted acceptance of the [corrected helper](agent-review-cli.md), then review and attest the exact PR head. | Local correction passes 29 safety tests. The old revision's review was replaced with failure; a fresh PR job must prove the actual current merge checkout before the corrected gate passes. Server enforcement remains separately blocked. |
| Enforce the chosen branch policy | BLOCKED | Resolve the GitHub plan prerequisite, then verify server rules and apply the policy below after both checks exist. | Read-back of effective rules for both branches and a disposable PR proving blocked and allowed cases. |
| Establish `dev` | NOT ATTEMPTED | After branch gates are available, create `dev` from the agreed reviewed integration commit and apply the same policy. | Branch SHA and effective rules independently read back. Do not enable an unprotected integration path while enforcement is blocked. |
| Define deployment scope | NOT ATTEMPTED | In a separate focused task, record supported destinations, signing, artifacts, approvals, and device evidence before pipeline implementation. | A reviewed release contract and its validation plan. |

These are checklist tasks, not claims that personal task records, Hermes tasks,
or GitHub issues were edited. No matching GitOps task was found in the inspected
Tunory Hermes board, and GitHub had no open issues at audit time.

## First CI implementation slice

The new `Core CI` workflow runs the existing package suite as the `Core tests`
job on PRs targeting `main` or `dev`, and on pushes to those branches. Manual
dispatch is available after the workflow reaches the default branch. It uses
`macos-15` with the installed Xcode 16.4 toolchain, read-only repository access,
an immutable checkout action reference, and a task-owned runner scratch path.
Superseded runs are canceled; a failed test command fails the job.

Acceptance: `actionlint` passes, the local suite still passes, a hosted PR run
passes at a recorded revision, and a temporary PR with an intentionally failing
test produces a failed `Core tests` check. Remove only the proof-owned resources
after recording that result. Do not weaken tests or change product code to clear
the hosted job. Hosted toolchain incompatibilities require diagnosis and a
documented correction before claiming success.

This slice does not create `dev`, implement the agent-review publisher, configure
required checks, change branch protections, or add deployment/signing workflows.

The subsequent agent-review CLI slice is described in
[Agent review through gh and git](agent-review-cli.md). The owner selected the
existing CLI tools for publication; no external review service is required for
this attestation path. Server enforcement remains a separate blocked task.

### Hosted acceptance evidence

| Criterion | Status | Evidence |
| --- | --- | --- |
| Workflow syntax | PASS | `actionlint .github/workflows/core-tests.yml` exited 0. |
| Local behavior preserved | PASS | Existing suite: 155 tests, zero failures; no product or existing test code changed. |
| Hosted positive case | PASS | [Run 39516987338](https://github.com/raelldottin/tunory/actions/runs/39516987338), PR head `890de4383241d70dbe7fdb881731c89298fac74d`: 155 tests, zero failures. |
| Hosted negative case | PASS | [Run 39517064977](https://github.com/raelldottin/tunory/actions/runs/39517064977), temporary PR head `cb72356276311ab93e489fa16155ba932ff16f1e`: 156 tests, one intentional failure, command exit 1, check conclusion `failure`. |
| Check identity | PASS | Check name `Core tests`, publisher `github-actions`; API read-back associated each result with its expected PR head SHA. Standard PR checkout tests the merge snapshot. This is CI evidence, not an agent review of the source head. |
| Proof cleanup | PASS | Temporary PR #7 closed without merging; its proof-owned remote/local branch and worktree removed. The intentional test is absent from the implementation branch. |

Both hosted cases used Swift 6.1.2 / Xcode 16.4 on `macos-15`. The deliberate
failure came from `CIFailurePropagationProofTests.testIntentionalFailureReachesCI`
with `XCTFail("Intentional CI failure-propagation proof; never merge this branch.")`.
The command was the workflow's unchanged `swift test` invocation. This proves
test failures propagate to the hosted check; it does not prove a branch rule
rejects merging, because server enforcement remains blocked.

## Reusable core validation checklist

Run from the repository root. Use a fresh task-owned scratch path for concurrent
work; retain output with the task's evidence.

```bash
git rev-parse HEAD
swift --version
xcodebuild -version
swift test --package-path Packages/TunoryCore --scratch-path /tmp/tunory-core-validation
git diff --check
git diff --cached --check
git status --short
```

- Record the command's actual exit status and XCTest summary. A trailing Swift
  Testing summary of zero tests does not replace the XCTest total.
- Check that generated build output and IDE state remain untracked. Use the
  generated-artifact check in `AGENTS.md` before publishing.
- Reuse this evidence format for the first hosted workflow. Require a failed
  command to fail its job; do not suppress failures to obtain a green check.
- Record `PASS`, `FAIL`, `NOT ATTEMPTED`, or `BLOCKED` for each required check.
  Preserve the actual error for failures and the prerequisite for blocked checks.

Verification in this slice used the same `swift test` command with the scratch
path `/tmp/tunory-quick-wins-core-build`, against `0ddd5d4`. No application code
changed. No signed build or runtime claim follows from these package tests.

## Selected review policy for `main` and `dev`

Owner choice: **agent-review gate plus CI, with no mandatory human or code-owner
approval**. This is the intended policy, not the current enforced configuration.

- Require pull requests and passing CI, including `Core tests` once implemented.
  Preserve any existing required checks and unrelated protections discovered at
  implementation time; do not replace them with an incomplete list.
- Require `Agent review` from the selected trusted publisher on the exact current
  PR head SHA. Verify the SHA again before merge. A comment, review of a previous
  commit, or success attached only to an unrelated merge commit is insufficient.
- Treat missing, stale, failed, and pending agent review as blocking. Pin the
  allowed publishing app or identity. Test that an untrusted status publisher
  cannot satisfy the gate.
- Set mandatory approving human reviews to zero and disable mandatory code-owner
  approval while retaining the required PR/check gates. Do not remove protections
  as a workaround for absent agent-review automation.
- Verify both branches reject merges missing either required check and accept a
  PR only when the exact current head has passed review and applicable CI.

The live prerequisite check was:

```bash
gh api repos/raelldottin/tunory/branches/main/protection
gh api repos/raelldottin/tunory/branches/dev/protection
```

Both exited 1 with HTTP 403 and:

```text
Upgrade to GitHub Pro or make this repository public to enable this feature.
```

Do not change repository visibility to clear this blocker. A local hook or
documented convention cannot substitute for server enforcement. No protection
settings or branch visibility were changed by this slice.
