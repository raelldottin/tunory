# Native review and CI policy

Verified 2026-10-21 for `raelldottin/tunory`. The repository was observed public
after the earlier private-plan HTTP 403 blocker. This task did not change its
visibility. No existing rulesets were present when this policy was applied.

Ruleset **Tunory agent review and CI**, ID `25528120`, is active on both
`refs/heads/main` and `refs/heads/dev`. Its desired configuration is tracked in
`Tools/GitHub/review-ruleset.json`.

- Pull requests are required; required approving review count is **0**.
- Code-owner, last-push, and extra unattributed-change approvals are disabled.
- `Core tests` is required from GitHub Actions, integration ID `15368`.
- The `Agent review` commit-status context is required on the proposed revision.
- Strict up-to-date status checks are enabled, with no bypass actors.
- Force updates and deletion of the protected branches are blocked.

The rules were verified for both names before `dev` was created, so the new
branch was protected from its first ref creation. `dev` was bootstrapped at
reviewed, CI-passing commit `b12869d8b2e7150dc99dc55f462fdfa91ae7d8a7`.
`main` was not advanced or merged by this task.

## Pre-merge verification and trust boundary

Continue using the stronger [agent review CLI](agent-review-cli.md) before an
authorized merge:

```bash
python3 -B Tools/GitHub/agent_review.py check <PR-number>
```

GitHub's native rules enforce required contexts and the Core tests integration;
they cannot pin a personal-account status creator or validate the PR job's
checkout marker. The CLI additionally verifies the review publisher, head/base,
workflow/job/attempt, and actual tested merge snapshot. Native eligibility does
not replace that check. A protected server verifier or trusted App would be
needed to make all those additional CLI conditions automatic server checks.

At configuration time `raelldottin` was the only collaborator with write access.
Reassess status-publishing trust when granting write access or changing Actions
permissions. The current workflow uses read-only permissions. The review status
is an agent attestation, not proof that an independent review service ran.

## Read-back and maintenance

```bash
gh api repos/raelldottin/tunory/rulesets/25528120
gh api repos/raelldottin/tunory/rules/branches/main
gh api repos/raelldottin/tunory/rules/branches/dev
gh api repos/raelldottin/tunory/git/ref/heads/dev
```

Use the effective branch-rules endpoint for ruleset verification. The legacy
branch-protection endpoint is not sufficient evidence of ruleset enforcement.
Inspect all rulesets, including inherited ones, before making changes. Update
the existing ID with `PUT` using the tracked payload; do not blindly `POST`
duplicate rulesets or remove unrelated rules. Re-read the complete effective
rules afterward.

## Native eligibility proof

Temporary, documentation-only PR #8 targeted protected `dev` and was never
merged. Its native GitHub eligibility and the CLI check were observed directly:

| Case | Status | Observation |
| --- | --- | --- |
| CI success, missing review | PASS | Head `ae706cec2ec4019b5caece1baa2be3de93b4febe`, [run 39557036475](https://github.com/raelldottin/tunory/actions/runs/39557036475): Core tests succeeded; GitHub `mergeStateStatus` was `BLOCKED`. |
| Both results pass | PASS | After a genuine review of the proof-only documentation and its attestation, GitHub reported `CLEAN`, zero human reviews, and the stricter CLI check passed. |
| Review success, pending CI | PASS | Head `649e58c84b49364aa063638bf422d1f771dcfc2c`: review status was `SUCCESS`, Core tests was `IN_PROGRESS`, and GitHub reported `BLOCKED`. |
| CI subsequently completes | PASS | [Run 39557226814](https://github.com/raelldottin/tunory/actions/runs/39557226814) succeeded; GitHub reported `CLEAN` with zero human reviews and the CLI check passed. |
| Cleanup | PASS | PR #8 closed without merging. Only its proof-owned source branch and worktree were removed; protected `dev` remains. |

This is native configuration and merge-eligibility proof. No merge request was
attempted in a blocked state, and no proof PR was merged. It does not establish
device, signed-app, MusicKit-write, or deployment behavior.
