#!/usr/bin/env python3
"""Record a completed agent review and check Tunory's current PR status gates."""

import argparse
import json
import re
import subprocess
import sys

REPO = "raelldottin/tunory"
PUBLISHER = "raelldottin"
CONTEXT = "Agent review"
CI_APP_ID = 15368  # github-actions, verified from Tunory's Core tests check.
API_ROOT = f"repos/{REPO}"


class Blocked(Exception):
    pass


def command(args, payload=None):
    result = subprocess.run(args, input=payload, text=True, capture_output=True, timeout=60)
    if result.returncode:
        raise Blocked(result.stderr.strip() or "Command failed")
    return result.stdout.strip()


class GitHub:
    def read(self, path):
        return json.loads(command(["gh", "api", path]))

    def pages(self, path):
        return json.loads(command(["gh", "api", "--paginate", "--slurp", path]))

    def post(self, path, payload):
        return json.loads(command(
            ["gh", "api", "--method", "POST", path, "--input", "-"],
            json.dumps(payload),
        ))


def snapshot(pr):
    if pr["state"] != "open" or pr["base"]["ref"] not in ("main", "dev"):
        raise Blocked("Use an open PR targeting main or dev")
    if any(pr[side]["repo"]["full_name"] != REPO for side in ("head", "base")):
        raise Blocked("This helper supports Tunory same-repository PRs")
    return pr["head"]["sha"], pr["base"]["sha"]


def unchanged(api, number, expected):
    if snapshot(api.read(f"{API_ROOT}/pulls/{number}")) != expected:
        raise Blocked("PR head or base changed; review the new revision")


def evidence_url(head, base):
    return f"https://github.com/{REPO}/compare/{base}...{head}"


def latest_review(api, head):
    statuses = [status for page in api.pages(
        f"{API_ROOT}/commits/{head}/statuses?per_page=100"
    ) for status in page if status["context"] == CONTEXT]
    if not statuses:
        raise Blocked("Missing Agent review status on the current head")
    # Do not fall back to an older passing result or skip an unexpected author.
    return max(statuses, key=lambda status: status["id"])


def verify_review(status, head, base, state="success"):
    if status["creator"]["login"] != PUBLISHER:
        raise Blocked("Latest Agent review has an unexpected publisher")
    if status["state"] != state:
        raise Blocked(f"Agent review is {status['state']}")
    if status.get("target_url") != evidence_url(head, base):
        raise Blocked("Review evidence does not match the current head and base")


def verify_ci(api, head):
    checks = [check for page in api.pages(
        f"{API_ROOT}/commits/{head}/check-runs?per_page=100"
    ) for check in page["check_runs"] if check["name"] == "Core tests"]
    if not checks:
        raise Blocked("Missing Core tests check on the current head")
    check = max(checks, key=lambda check: check["id"])
    if check["app"]["id"] != CI_APP_ID or check["head_sha"] != head:
        raise Blocked("Latest Core tests has an unexpected publisher or SHA")
    if check["status"] != "completed" or check["conclusion"] != "success":
        raise Blocked("Latest Core tests is not completed successfully")


def record(api, args):
    expected = args.reviewed_head, args.reviewed_base
    unchanged(api, args.pr, expected)
    if api.read("user")["login"] != PUBLISHER:
        raise Blocked(f"Publishing requires the configured CLI identity {PUBLISHER}")
    remote = command(["git", "remote", "get-url", "origin"])
    if remote not in (
        f"https://github.com/{REPO}.git", f"https://github.com/{REPO}",
        f"git@github.com:{REPO}.git", f"ssh://git@github.com/{REPO}.git",
    ):
        raise Blocked("Run from a checkout with Tunory as origin")
    if command(["git", "rev-parse", "HEAD"]) != args.reviewed_head:
        raise Blocked("Checkout HEAD does not match the reviewed head")
    if command(["git", "status", "--porcelain"]):
        raise Blocked("Review and commit the working-tree changes first")
    description = f"Agent review: {args.summary.strip()}"
    if not args.summary.strip() or len(description) > 140 or any(
        char in description for char in "\r\n"
    ):
        raise Blocked("Supply a nonempty single-line summary within 126 characters")
    unchanged(api, args.pr, expected)
    api.post(f"{API_ROOT}/statuses/{args.reviewed_head}", {
        "state": args.result,
        "context": CONTEXT,
        "description": description,
        "target_url": evidence_url(*expected),
    })
    # Read the current PR and latest status back; a concurrent push fails closed.
    verify_review(latest_review(api, args.reviewed_head), *expected, args.result)
    unchanged(api, args.pr, expected)
    print(f"Recorded {args.result}: {CONTEXT} on {args.reviewed_head}")


def check(api, args):
    head, base = snapshot(api.read(f"{API_ROOT}/pulls/{args.pr}"))
    verify_review(latest_review(api, head), head, base)
    verify_ci(api, head)
    unchanged(api, args.pr, (head, base))
    print(f"PASS: Agent review and Core tests on {head} (base {base})")
    print("Status snapshot only; GitHub branch rules, draft state, and mergeability are separate.")


def sha(value):
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise argparse.ArgumentTypeError("Use the full 40-character lowercase SHA")
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="operation", required=True)
    for name in ("record", "check"):
        sub = commands.add_parser(name)
        sub.add_argument("pr", type=int)
        if name == "record":
            sub.add_argument("--reviewed-head", type=sha, required=True)
            sub.add_argument("--reviewed-base", type=sha, required=True)
            sub.add_argument("--result", choices=("success", "failure"), required=True)
            sub.add_argument("--summary", required=True)
    args = parser.parse_args(argv)
    try:
        if args.pr < 1:
            raise Blocked("PR number must be positive")
        {"record": record, "check": check}[args.operation](GitHub(), args)
        return 0
    except (Blocked, KeyError, TypeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(f"BLOCKED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
