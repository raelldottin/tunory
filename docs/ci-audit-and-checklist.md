# CI audit and reusable verification checklist

Scope: the user authorized the repository quick wins from the Owlory actionability proposal. For Tunory, inventory existing CI, identify one missing check and document an actually verified test command. Deployment pipelines, signing, TestFlight, production release and live Apple Music writes are separate work.

## Bounded plan

- Base: current fetched `origin/main`, `0ddd5d4ea59e58cfedc334e8073d81b214ae80c3`, in an isolated worktree. Preserve the original checkout and its one unpublished commit on `codex/ui-robustness`.
- Allowed changes: this document and the Tests section of `AGENTS.md`. No application, test, dependency, workflow or credential changes.
- Acceptance: inventory GitHub Actions and default-branch workflow files, run the existing `Packages/TunoryCore` suite with isolated scratch output, record exact source/toolchain/results, publish the verified command and a single actionable CI gap. Review diff hygiene and finish clean/mirrored on the new branch.

## CI inventory, 2026-10-20

- GitHub default branch: `main`; repository is not archived.
- Fetched default-branch tree contains no `.github` workflow files.
- Live GitHub Actions workflows endpoint returned **0 workflows**; workflow-runs endpoint returned **0 runs**. These observations describe GitHub Actions, not every possible external CI provider or repository protection setting.
- Existing coverage sources include the host Swift package `Packages/TunoryCore`, plus app and UI test targets. A registered CI job is not implied by test files alone.

## One explicit next action

**Add a PR-only macOS check that runs the verified TunoryCore package tests.**

Reason: deterministic host tests already exist while GitHub Actions has no registered workflow. The identifiable result is one PR check with an exact test count and failure status. This is a proposed next check, not an implemented workflow or a deployment pipeline. Preserve Swift language/deployment settings and use the package's supported toolchain.

## Reusable CI audit checklist

1. Record the repository, source revision, supported toolchain and clean/dirty state.
2. Inventory workflow files, registered jobs, triggers and recent runs separately; distinguish configured work from executed checks.
3. Map each check to its exact command, working directory, platform, prerequisites and expected artifact. Keep credentials outside logs and project files.
4. Execute the narrow existing check in isolated scratch storage. Record PASS, FAIL, BLOCKED or NOT ATTEMPTED, including counts and any failure reason. Never infer app, device or live-service proof from package tests.
5. Choose one missing check and give it an explicit next action and observable completion evidence. Keep release/signing/approval decisions out of the test-only quick win.
6. Review the scoped diff, commit/push the branch and verify the worktree is clean and mirrored. Preserve unrelated source-checkout work.

## Local command verification

**PASS:** 155 XCTest tests, zero failures, from unchanged core source at `0ddd5d4ea59e58cfedc334e8073d81b214ae80c3`. Swift 6.4 (`swiftlang-6.4.0.34.1`), arm64 macOS host; existing package tools minimum 6.0, Swift language mode 5 and macOS 13 platform declaration were preserved.

Exact invocation, from the repository root:

```bash
swift test --package-path Packages/TunoryCore --scratch-path /tmp/tunory-repository-quick-wins-20261020-core-build
```

The durable `AGENTS.md` command uses a shorter task-owned scratch path; the package and test options are identical. Log: `/tmp/tunory-core-quickwins-20261020.log`; SHA256 `f0c6633e2e1bee4eaf006c8be3a3b67553b57efbdfcada702fbbac67e928c142`. No generated output or raw log is committed.

Proof reached: deterministic host core tests plus source/live GitHub Actions inventory. Native app/UI, MusicKit authorization, signing, device and release proof are **NOT ATTEMPTED**, as outside this documentation quick win. No workflow was added or dispatched and no Apple Music data was mutated.
