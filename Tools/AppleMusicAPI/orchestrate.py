#!/usr/bin/env python3
"""Orchestrate the After Hours playlist build via the signed AMHelper binary.

All Apple Music API traffic runs through AMHelper (a signed macOS binary
that uses MusicKit's MusicUserTokenProvider). We never handle the user token
in this process.

Outputs a checkpoint JSON at $SCRATCH/afterhours-checkpoint.json.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from pathlib import Path

HELPER = "/Users/raelldottin/Documents/Personal/Tunory/Tools/AppleMusicAPI/AMHelper.app/Contents/MacOS/AMHelper"
DEV_TOKEN_FILE = "/Users/raelldottin/.hermes/cache/scratch/am/.devtoken"
SCRATCH = Path(os.path.expanduser("~/.hermes/cache/scratch/am"))
SCRATCH.mkdir(parents=True, exist_ok=True)
MANIFEST = SCRATCH / "manifest.json"
CHECKPOINT = SCRATCH / "afterhours-checkpoint.json"
BASELINE = SCRATCH / "afterhours-baseline.json"

PLAYLIST_NAME = "After Hours — Violin & Trumpet"


def call(method: str, path: str, body=None) -> tuple[int, dict | list | str]:
    """Run AMHelper. Returns (http_status, parsed_json_or_raw)."""
    env = os.environ.copy()
    env["AM_DEV_TOKEN_FILE"] = DEV_TOKEN_FILE
    cmd = [HELPER, "call", method, path]
    body_file = None
    if body is not None:
        body_file = SCRATCH / ".body.json"
        body_file.write_text(json.dumps(body))
        cmd.append(str(body_file))
    p = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=120)
    if body_file and body_file.exists():
        body_file.unlink()
    err = p.stderr
    status = None
    for line in err.splitlines():
        if line.startswith("__HTTP_STATUS__="):
            status = int(line.split("=", 1)[1])
    out = p.stdout.strip()
    if p.returncode != 0 and status is None:
        raise RuntimeError(f"helper failed rc={p.returncode} err={err!r}")
    try:
        parsed = json.loads(out) if out else {}
    except json.JSONDecodeError:
        parsed = out
    return (status or 0), parsed


def fetch_all_pages(path: str, max_pages: int = 200, allow_404_empty: bool = True) -> list[dict]:
    """Follow Apple Music API `next` pagination. Returns concatenated data."""
    items: list[dict] = []
    cur = path
    for _ in range(max_pages):
        if not cur:
            break
        st, body = call("GET", cur)
        if st == 401:
            raise RuntimeError("401 unauthorized - user token issue")
        if st == 404 and allow_404_empty:
            return items
        if st >= 400:
            raise RuntimeError("{} on {}: {}".format(st, cur, str(body)[:300]))
        if not isinstance(body, dict):
            raise RuntimeError("unexpected payload: " + str(body)[:200])
        items.extend(body.get("data", []))
        cur = body.get("next")
    return items


def catalog_check(manifest: list[dict]) -> list[dict]:
    """Verify each manifest catalog id via /v1/catalog/us/songs/{id}."""
    results = []
    for t in manifest:
        cid = t["catalogId"]
        st, body = call("GET", f"/v1/catalog/us/songs/{cid}")
        ok = False
        artist = name = ""
        if st == 200 and isinstance(body, dict) and body.get("data"):
            a = body["data"][0]["attributes"]
            name, artist = a.get("name", ""), a.get("artistName", "")
            ok = True
        results.append({
            "pos": t["pos"], "catalogId": cid,
            "expected_name": t.get("name"), "expected_artist": t.get("artist"),
            "actual_name": name, "actual_artist": artist,
            "ok": ok and st == 200,
        })
        status_str = "OK " if ok else "FAIL"
        line = "  catalog[%2d] %11s %s %s — %s" % (t["pos"], cid, status_str, name[:60], artist[:40])
        print(line)
    return results


def library_songs_by_catalog() -> dict[int, str]:
    """Map catalog ID -> library song ID for all library songs."""
    # /v1/me/library/songs returns library-song items with a catalog relationship
    items = fetch_all_pages("/v1/me/library/songs?limit=100&include=catalog")
    out = {}
    for it in items:
        rel = it.get("relationships", {}).get("catalog", {}).get("data", [])
        if rel:
            cid = rel[0].get("id")
            try:
                out[int(cid)] = it["id"]
            except (ValueError, TypeError):
                pass
    return out


def library_playlists() -> list[dict]:
    return fetch_all_pages("/v1/me/library/playlists")


def playlist_tracks(pid: str) -> list[dict]:
    return fetch_all_pages(f"/v1/me/library/playlists/{pid}/tracks")


def add_to_library(catalog_id: int) -> int:
    st, body = call("POST", f"/v1/me/library?ids[songs]={catalog_id}")
    return st


def append_tracks(pid: str, library_ids: list[str]) -> int:
    """Append tracks one-by-one. library_ids are library-song ids."""
    body = {"data": [{"id": lid, "type": "library-songs"} for lid in library_ids]}
    st, resp = call("POST", f"/v1/me/library/playlists/{pid}/tracks", body)
    return st


def main() -> int:
    manifest = json.loads(MANIFEST.read_text())
    assert len(manifest) == 17

    # Gate 3: catalog
    print("[Gate 3] catalog validation")
    cat_results = catalog_check(manifest)
    bad = [r for r in cat_results if not r["ok"]]
    if bad:
        print(f"FAILED catalog: {bad}")
        return 3
    print(f"Catalog 17/17 verified\n")

    # Gate 4: baseline
    print("[Gate 4] baseline")
    playlists = fetch_all_pages("/v1/me/library/playlists?limit=100")
    matches = [p for p in playlists if p["attributes"].get("name") == PLAYLIST_NAME]
    if len(matches) != 1:
        print("FAIL: expected 1 playlist named '{}', found {}".format(PLAYLIST_NAME, len(matches)))
        for p in matches:
            print("  -", p["id"], p["attributes"].get("canEdit"))
        return 4
    playlist = matches[0]
    pid = playlist["id"]
    can_edit = playlist["attributes"].get("canEdit", None)
    print("playlist id:", pid, "canEdit:", can_edit)
    if not can_edit:
        print("FAIL: playlist canEdit is False")
        return 4

    existing_tracks = playlist_tracks(pid)
    print("existing playlist tracks:", len(existing_tracks))

    existing_catalog_ids = []
    for t in existing_tracks:
        rel = t.get("relationships", {}).get("catalog", {}).get("data", [])
        if rel:
            try: existing_catalog_ids.append(int(rel[0]["id"]))
            except Exception: existing_catalog_ids.append(None)
        else: existing_catalog_ids.append(None)

    # classify playlist state
    manifest_ids = [t["catalogId"] for t in manifest]
    state = "EMPTY"
    if existing_catalog_ids:
        prefix_len = 0
        for i, cid in enumerate(existing_catalog_ids):
            if i < len(manifest_ids) and cid == manifest_ids[i]:
                prefix_len += 1
            else:
                break
        if len(existing_catalog_ids) == 17 and prefix_len == 17:
            state = "EXACT_COMPLETE"
        elif prefix_len == len(existing_catalog_ids):
            state = "CORRECT_PREFIX"
        else:
            state = "WRONG_ORDER"
        if len(set([c for c in existing_catalog_ids if c is not None])) != len([c for c in existing_catalog_ids if c is not None]):
            state = "CONTAINS_DUPLICATES"
    print("playlist state:", state)

    if state == "EXACT_COMPLETE":
        print("playlist already complete; nothing to do")
    elif state not in ("EMPTY", "CORRECT_PREFIX"):
        print("STOP: state {} requires manual reconciliation".format(state))
        return 4

    # snapshot library (reuse later to avoid re-listing)
    print("enumerating library songs (11300+ expected)...")
    lib_songs = fetch_all_pages("/v1/me/library/songs?limit=100&include=catalog", max_pages=1000)
    print("library songs fetched:", len(lib_songs))
    cat_to_lib = {}
    for it in lib_songs:
        cid_int = None
        # primary source: attributes.playParams.catalogId
        pp = it.get("attributes", {}).get("playParams", {}) or {}
        c = pp.get("catalogId")
        if c is not None:
            try: cid_int = int(c)
            except Exception: pass
        # fallback: relationships.catalog
        if cid_int is None:
            rel = it.get("relationships", {}).get("catalog", {}).get("data", [])
            if rel:
                try: cid_int = int(rel[0]["id"])
                except Exception: pass
        if cid_int is not None:
            cat_to_lib[cid_int] = it["id"]
    print("library catalog id map:", len(cat_to_lib))

    baseline = {
        "playlist_id": pid,
        "canEdit": can_edit,
        "existing_playlist_catalog_ids": existing_catalog_ids,
        "library_catalog_ids_present": sorted(cat_to_lib.keys()),
        "manifest_hash": str(hash(json.dumps(manifest, sort_keys=True))),
        "timestamp": time.time(),
        "playlist_state": state,
    }
    BASELINE.write_text(json.dumps(baseline, indent=2))
    CHECKPOINT.write_text(json.dumps(baseline, indent=2))

    if state == "EXACT_COMPLETE":
        return 0

    # Gate 5: library additions
    print("\n[Gate 5] library additions")
    manifest_ids = [t["catalogId"] for t in manifest]
    missing = [t for t in manifest if t["catalogId"] not in cat_to_lib]
    print("missing from library:", len(missing))
    for t in missing:
        cid = t["catalogId"]
        st = add_to_library(cid)
        print("  add pos=%2d cid=%d http=%d" % (t["pos"], cid, st))
        time.sleep(0.4)

    # Refresh library map (single full re-read)
    print("refreshing library list...")
    lib_songs = fetch_all_pages("/v1/me/library/songs?limit=100&include=catalog", max_pages=1000)
    cat_to_lib = {}
    for it in lib_songs:
        cid_int = None
        pp = it.get("attributes", {}).get("playParams", {}) or {}
        c = pp.get("catalogId")
        if c is not None:
            try: cid_int = int(c)
            except Exception: pass
        if cid_int is None:
            rel = it.get("relationships", {}).get("catalog", {}).get("data", [])
            if rel:
                try: cid_int = int(rel[0]["id"])
                except Exception: pass
        if cid_int is not None:
            cat_to_lib[cid_int] = it["id"]
    have = [t for t in manifest if t["catalogId"] in cat_to_lib]
    print("library reconciled: %d/17" % len(have))
    if len(have) != 17:
        missing2 = [t for t in manifest if t["catalogId"] not in cat_to_lib]
        print("STOP: still missing:")
        for t in missing2:
            print("  pos=", t["pos"], "cid=", t["catalogId"], t["name"])
        return 5

    # Gate 6: playlist append
    print("\n[Gate 6] playlist append")
    prefix = 0 if state == "EMPTY" else len(existing_catalog_ids)
    remaining = manifest[prefix:]
    for t in remaining:
        cid = t["catalogId"]
        lib_id = cat_to_lib[cid]
        st = append_tracks(pid, [lib_id])
        print("  append pos=%2d lib=%s cid=%d http=%d" % (t["pos"], lib_id, cid, st))
        if st >= 300:
            print("  STOP: append failed with HTTP", st)
            return 6
        time.sleep(0.5)

    return 0


if __name__ == "__main__":
    sys.exit(main())
