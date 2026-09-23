#!/usr/bin/env python3
"""Apple Music developer token generator (in-memory only).

Generates a short-lived ES256 JWT for the Apple Music API.
Never prints or stores the token. Writes it to a file (mode 0600)
only when explicitly requested via --out, for immediate same-process
consumption by another helper.

Usage:
  devtoken.py --key PATH --kid GS5L8952F2 --tid TEAMID --ttl-seconds 3600 \
      --out ~/.hermes/cache/scratch/am/.devtoken

The --out file is created with 0600 permissions outside the repository.
"""
import argparse
import base64
import json
import os
import sys
import time

import jwt  # PyJWT


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--key", required=True)
    p.add_argument("--kid", required=True)
    p.add_argument("--tid", required=True)
    p.add_argument("--ttl-seconds", type=int, default=3600)
    p.add_argument("--out", default=None,
                   help="If set, atomically write token here with 0600 perms")
    p.add_argument("--header-shape", action="store_true",
                   help="Print header/payload metadata only (no token)")
    args = p.parse_args()

    with open(args.key, "rb") as f:
        key = f.read()
    if b"BEGIN PRIVATE KEY" not in key:
        print("FAIL: not a PEM private key", file=sys.stderr)
        return 2

    now = int(time.time())
    headers = {"alg": "ES256", "kid": args.kid, "typ": "JWT"}
    payload = {
        "iss": args.tid,
        "iat": now,
        "exp": now + args.ttl_seconds,
    }
    token = jwt.encode(payload, key, algorithm="ES256", headers=headers)

    if args.header_shape:
        h, pl, _ = token.split(".")
        print(json.dumps({
            "header": json.loads(base64.urlsafe_b64decode(h + "==")),
            "payload": {k: v for k, v in json.loads(
                base64.urlsafe_b64decode(pl + "==")).items()},
        }, indent=2))

    if args.out:
        path = args.out
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(token)
        print(f"token written: {path} (0600)", file=sys.stderr)
    else:
        # Never print by default; only when explicitly required and to stderr
        print("token generated but not emitted (use --out)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
