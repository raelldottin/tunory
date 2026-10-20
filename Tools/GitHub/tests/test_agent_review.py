import argparse
import copy
import importlib.util
import subprocess
from pathlib import Path
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "agent_review", Path(__file__).resolve().parents[1] / "agent_review.py"
)
review = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(review)
HEAD = "a" * 40
BASE = "b" * 40


class FakeGitHub:
    def __init__(self):
        self.pr = {
            "state": "open",
            "head": {"sha": HEAD, "repo": {"full_name": review.REPO}},
            "base": {"sha": BASE, "ref": "main", "repo": {"full_name": review.REPO}},
        }
        self.statuses = [{
            "id": 1, "context": review.CONTEXT, "state": "success",
            "creator": {"login": review.PUBLISHER},
            "target_url": review.evidence_url(HEAD, BASE),
        }]
        self.checks = [{
            "id": 1, "name": "Core tests", "status": "completed",
            "conclusion": "success", "head_sha": HEAD,
            "app": {"id": review.CI_APP_ID},
        }]
        self.login = review.PUBLISHER
        self.posts = []
        self.read_count = 0
        self.change_at = None

    def read(self, path):
        if path == "user":
            return {"login": self.login}
        self.read_count += 1
        pr = copy.deepcopy(self.pr)
        if self.change_at is not None and self.read_count >= self.change_at:
            pr["head"]["sha"] = "c" * 40
        return pr

    def pages(self, path):
        if "/statuses?" in path:
            return [[], self.statuses]  # Exercise pagination, not only page one.
        return [{"check_runs": []}, {"check_runs": self.checks}]

    def post(self, path, payload):
        self.posts.append((path, payload))
        status = dict(payload, id=2, creator={"login": self.login})
        self.statuses.append(status)
        return status


class ReviewGateTests(unittest.TestCase):
    def setUp(self):
        self.api = FakeGitHub()
        self.args = argparse.Namespace(
            pr=6, reviewed_head=HEAD, reviewed_base=BASE, result="success",
            summary="Reviewed the exact diff; no blocking findings",
        )

    def check(self):
        review.check(self.api, self.args)

    def test_accepts_current_review_and_ci(self):
        self.check()

    def test_missing_pending_and_failed_review_block(self):
        for state in (None, "pending", "failure", "error"):
            with self.subTest(state=state), self.assertRaises(review.Blocked):
                self.api = FakeGitHub()
                if state is None:
                    self.api.statuses = []
                else:
                    self.api.statuses[0]["state"] = state
                self.check()

    def test_old_success_cannot_override_new_failure(self):
        self.api.statuses.append(dict(self.api.statuses[0], id=2, state="failure"))
        with self.assertRaises(review.Blocked):
            self.check()

    def test_unexpected_latest_publisher_cannot_reuse_old_success(self):
        self.api.statuses.append(dict(
            self.api.statuses[0], id=2, creator={"login": "other-account"}
        ))
        with self.assertRaises(review.Blocked):
            self.check()

    def test_stale_head_or_base_blocks(self):
        for side in ("head", "base"):
            with self.subTest(side=side), self.assertRaises(review.Blocked):
                self.api = FakeGitHub()
                self.api.pr[side]["sha"] = "c" * 40
                self.check()

    def test_missing_or_unsuccessful_ci_blocks(self):
        for state, conclusion in ((None, None), ("in_progress", None),
                                  ("completed", "failure"), ("completed", "skipped")):
            with self.subTest(state=state, conclusion=conclusion), self.assertRaises(review.Blocked):
                self.api = FakeGitHub()
                if state is None:
                    self.api.checks = []
                else:
                    self.api.checks[0].update(status=state, conclusion=conclusion)
                self.check()

    def test_old_ci_success_cannot_override_new_pending_run(self):
        self.api.checks.append(dict(self.api.checks[0], id=2, status="queued", conclusion=None))
        with self.assertRaises(review.Blocked):
            self.check()

    def test_ci_identity_and_sha_are_checked(self):
        for change in ({"app": {"id": 123}}, {"head_sha": "c" * 40}):
            with self.subTest(change=change), self.assertRaises(review.Blocked):
                self.api = FakeGitHub()
                self.api.checks[0].update(change)
                self.check()

    def test_pr_change_during_check_blocks(self):
        self.api.change_at = 2
        with self.assertRaises(review.Blocked):
            self.check()

    def git(self, args, payload=None):
        return {
            ("git", "remote", "get-url", "origin"): f"https://github.com/{review.REPO}.git",
            ("git", "rev-parse", "HEAD"): HEAD,
            ("git", "status", "--porcelain"): "",
        }[tuple(args)]

    def test_record_writes_exact_sha_and_reads_it_back(self):
        with patch.object(review, "command", side_effect=self.git):
            review.record(self.api, self.args)
        path, payload = self.api.posts[0]
        self.assertEqual(path, f"repos/{review.REPO}/statuses/{HEAD}")
        self.assertEqual(payload["target_url"], review.evidence_url(HEAD, BASE))
        self.assertEqual(payload["state"], "success")
        self.assertEqual(self.api.read_count, 3)

    def test_record_preserves_a_failed_review(self):
        self.args.result = "failure"
        with patch.object(review, "command", side_effect=self.git):
            review.record(self.api, self.args)
        self.assertEqual(self.api.posts[0][1]["state"], "failure")
        with self.assertRaises(review.Blocked):
            self.check()

    def test_wrong_cli_account_cannot_publish(self):
        self.api.login = "other-account"
        with self.assertRaises(review.Blocked):
            review.record(self.api, self.args)
        self.assertEqual(self.api.posts, [])

    def test_dirty_wrong_head_and_foreign_checkout_cannot_publish(self):
        cases = {
            ("git", "status", "--porcelain"): " M file.swift",
            ("git", "rev-parse", "HEAD"): "c" * 40,
            ("git", "remote", "get-url", "origin"): "https://github.com/other/repo.git",
        }
        for key, value in cases.items():
            with self.subTest(key=key), patch.object(
                review, "command", side_effect=lambda args, payload=None: (
                    value if tuple(args) == key else self.git(args)
                )
            ), self.assertRaises(review.Blocked):
                review.record(self.api, self.args)
            self.assertEqual(self.api.posts, [])

    def test_pr_change_before_or_after_post_is_detected(self):
        for change_at in (2, 3):
            with self.subTest(change_at=change_at):
                self.api = FakeGitHub()
                self.api.change_at = change_at
                with patch.object(review, "command", side_effect=self.git), self.assertRaises(review.Blocked):
                    review.record(self.api, self.args)
                self.assertEqual(len(self.api.posts), 0 if change_at == 2 else 1)

    def test_network_error_fails_closed(self):
        with patch.object(self.api, "pages", side_effect=review.Blocked("HTTP 503")):
            with self.assertRaisesRegex(review.Blocked, "HTTP 503"):
                self.check()

    def test_invalid_summary_cannot_publish(self):
        for summary in ("", "a\nb", "a" * 127):
            with self.subTest(summary=summary), patch.object(review, "command", side_effect=self.git):
                self.args.summary = summary
                with self.assertRaises(review.Blocked):
                    review.record(self.api, self.args)
                self.assertEqual(self.api.posts, [])

    def test_closed_foreign_and_other_target_prs_block(self):
        for change in ("closed", "foreign", "target"):
            with self.subTest(change=change), self.assertRaises(review.Blocked):
                self.api = FakeGitHub()
                if change == "closed":
                    self.api.pr["state"] = "closed"
                elif change == "foreign":
                    self.api.pr["head"]["repo"]["full_name"] = "other/repo"
                else:
                    self.api.pr["base"]["ref"] = "other"
                self.check()

    def test_cli_timeout_and_missing_binary_report_blocked(self):
        for error in (FileNotFoundError("gh unavailable"), subprocess.TimeoutExpired("gh", 60)):
            with self.subTest(error=error), patch.object(review.subprocess, "run", side_effect=error):
                self.assertEqual(review.main(["check", "6"]), 1)


if __name__ == "__main__":
    unittest.main()
