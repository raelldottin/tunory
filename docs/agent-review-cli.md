# Agent review through gh and git

Tunory's CLI helper uses the existing authenticated `gh` account to record an
agent's completed review as a commit status. It runs without a separate review
service. The configured publisher is `raelldottin`, verified through `gh api user`.
Keep credentials in the existing CLI authentication store; no token is read,
printed, or stored by this helper.

## Contract and validation plan

`Tools/GitHub/agent_review.py record` records an attestation after the agent has
reviewed the exact committed diff. The helper does not run a review model or
establish reviewer independence. The agent must perform the review before
recording a result and report blocking findings as `failure`.

`check` requires the latest `Agent review` status on the current PR head to be
successful, published by the configured account, and linked to the exact current
head/base comparison. It also requires the latest applicable `Core tests` check
from `.github/workflows/core-tests.yml`, published by GitHub Actions (App ID
15368), for a `pull_request` run associated with this PR and source head.
The selected check must match its workflow run, job, and run attempt; both the
job and workflow must have completed successfully.

The job records its actual checkout as `TUNORY_CI_MERGE_SHA` before tests run.
The helper requires exactly one marker in that job's log, matching GitHub's
current PR merge commit, whose parents must be the current base and head. It
checks that the PR snapshot is unchanged after verification. Dispatch runs and
other workflows cannot replace the relevant PR run, even if they publish the
same job name on the same source SHA.

Acceptance: deterministic tests must cover missing, pending, failed, stale, and
unexpectedly published results; newer failures must override older success;
network failures and concurrent head/base changes must block. Recording must
reject dirty, foreign, and mismatched checkouts before writing. Validate local
tests, hosted CI, a live missing-review rejection, and an actual review status
write followed by API read-back and a successful check on the reviewed revision.

## Record and verify a review

Run from the clean Tunory checkout at the reviewed PR head. First inspect the
PR's full head/base SHAs, fetch those revisions, and review the exact diff and
relevant test results. Do not substitute a CI pass for a code review.

```bash
gh pr view 6 --repo raelldottin/tunory --json headRefOid,baseRefOid
git diff --stat <reviewed-base-sha>...<reviewed-head-sha>
git diff <reviewed-base-sha>...<reviewed-head-sha>
python3 -B Tools/GitHub/agent_review.py record 6 \
  --reviewed-head <reviewed-head-sha> \
  --reviewed-base <reviewed-base-sha> \
  --result success \
  --summary 'Reviewed the exact diff; no blocking findings'
python3 -B Tools/GitHub/agent_review.py check 6
```

Use `--result failure` with a concrete summary when findings block acceptance.
Both SHA arguments must be full 40-character hashes. The helper verifies the
checkout, publishing identity, current head/base, and latest status after posting.
A concurrent push can leave a status only on the old SHA; the command reports
blocked and a fresh review is required. A changed base also requires fresh review.

The helper supports open same-repository PRs targeting `main` or `dev`. It never
merges a PR or alters branch rules. `check` reports a status snapshot; draft
state, conflicts, other future required checks, and changes after the snapshot
remain separate merge conditions. Re-run it immediately before any authorized
merge, and honor GitHub's effective requirements when server protection becomes
available. GitHub job logs must still be available; missing/expired logs block
verification. Run fresh PR CI for the current merge snapshot when required.

## Tests and enforcement boundary

```bash
python3 -B -m unittest discover -s Tools/GitHub/tests -v
```

These tests use fake API data and stub Git commands; they publish no statuses.
The existing `Core tests` hosted job also runs them.

The private repository's current plan returns HTTP 403 for branch protection.
Consequently this CLI check cannot enforce merging on GitHub. GitHub's native
commit-status rule also does not pin a personal-account status creator; the CLI
enforces that identity itself. Server enforcement will need the supported plan
and a protected verification check or trusted App that enforces the same identity
and SHA contract. Keep the intended policy: CI plus exact-commit agent review,
without mandatory human or code-owner approval. No server rules are weakened.

## Historical acceptance before the provenance review

Validation on 2026-10-20, candidate `e56d84d407d721163a76e02db4d1bb7262faceb4`:

| Check | Status | Evidence |
| --- | --- | --- |
| Focused safety tests | PASS | 18 local unittest cases; missing/stale/failed statuses, publisher/checkout guards, pagination, races, CLI availability, and network errors. |
| Hosted tests | PASS | [Run 39518305756](https://github.com/raelldottin/tunory/actions/runs/39518305756): 155 core tests and 18 CLI tests passed. |
| Missing live review | PASS | `python3 -B Tools/GitHub/agent_review.py check 6` exited 1 with `BLOCKED: Missing Agent review status on the current head` before publication. |
| Review publication | PASS | A completed agent review was recorded through `record` and read back as status ID `56843745674`, context `Agent review`, state `success`, creator `raelldottin`, with the exact head/base comparison URL. This is the agent's attestation, not an independent review service. |
| Pending live CI | PASS | After recording review and before CI completed, `check 6` exited 1 with `BLOCKED: Latest Core tests is not completed successfully`. |
| Combined live check | PASS | After hosted CI completed, `check 6` exited 0 and reported the exact candidate SHA and base `0ddd5d4ea59e58cfedc334e8073d81b214ae80c3`. |
| Server enforcement | BLOCKED | Protection reads for `main` and `dev` return HTTP 403 due to the private repository plan. No rule change or merge performed. |

The agent reviewed the CLI's read/write scope, exact-SHA checks, publisher
validation, race/error handling, test coverage, workflow permissions, and the
complete task diff. Publishing this evidence changes the head and requires a
fresh review attestation and passing CI before the new revision passes `check`.

## P1 provenance correction

Review of `0dfcbd9` found that a newer successful manual run could mask a failed
PR merge run. The existing gate checked only job name, source SHA, publisher,
and success. A deterministic reproduction returned PASS despite failed PR CI,
so the agent review status on that revision was replaced with `failure`.

Research also showed that workflow-run `pull_requests` metadata is dynamic:
old runs `39516987338` and `39518305756` reported PR #6's newer head while their
own `head_sha` retained their original revision. Do not use nested PR head/base
metadata as evidence of what a historical job checked out. The correction uses
run/job linkage plus the immutable checkout marker in the completed job's log.
ANSI log text is captured for parsing and never rendered by the helper.

The preservation contract remains the same: existing core tests, read-only CI
permissions, explicit review attestation, and no automatic merge or rule change.
The workflow adds one checkout marker and no dependency or artifact upload.

| Pre-publication check | Status | Evidence |
| --- | --- | --- |
| Regression exposes the defect | PASS | Before the fix, the manual-success and changed-base cases both failed with `Blocked not raised`; 20 tests ran, two failed. |
| Corrected safety suite | PASS | 29 tests passed, including those regressions and run/job/attempt identity, snapshot/log, and concurrency cases. |
| Workflow lint | PASS | `actionlint .github/workflows/core-tests.yml` exited 0. |
| Hosted corrected revision | PASS | [Run 39520452429](https://github.com/raelldottin/tunory/actions/runs/39520452429) on `951e1c0c9a93697067ff183f6e889b493faca8a2`: 155 core tests and 29 CLI tests passed. |
| Live run/job/checkout verification | PASS | Job `118962747409` was linked to the expected PR run and attempt; its marker matched merge `e1bf2c7400505961d6a62347a6aa8c41db36311a`, with current base/head parents. |
| Fresh review and combined check | PASS | After reviewing `951e1c0`, `record` published/read back success and `check 6` passed the corrected live provenance path. The earlier vulnerable revision remains marked failure. |

Acceptance requires a real completed PR job with the marker matching the current
merge commit, plus a fresh exact-head review. Existing pre-marker jobs must not
be accepted as replacement proof. Server enforcement remains separately blocked
by the repository plan.

The false-acceptance and stale-base cases were verified with deterministic API
fixtures, not a live bypass. The corrected positive path was verified against
GitHub. Subsequent documentation commits require their own passing PR job and
fresh review; PR #6 records final-head acceptance.
