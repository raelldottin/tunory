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
head/base comparison. It also requires the latest `Core tests` check to be
successful on that head and published by GitHub Actions (App ID 15368).

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
available.

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
