# Apple Music Integration Retrospective

Technical history of the "After Hours — Violin & Trumpet" automation work: what was tried, what failed, why, and the architecture that finally completed the task end-to-end through Apple's official Apple Music REST API.

## 1. Goal

Create and verify the Apple Music playlist **After Hours — Violin & Trumpet** with:

- exactly 17 requested recordings,
- all 17 exact recordings verified in My Library,
- playlist populated in exact requested order,
- no duplicate entries,
- existing playlist preserved (no destructive repair),
- independent final verification from fresh API reads (not from mutation acknowledgments).

Final verified state:

- Catalog: 17/17
- Library: 17/17
- Playlist: 17/17
- Ordering: PASS
- Duplicates introduced: 0
- Unexpected modifications: None detected
- Unresolved tracks: None
- Execution: COMPLETE

Playlist metadata:

- Name: `After Hours — Violin & Trumpet`
- Library playlist ID: `p.5PG55oBuOxMpdl`
- `canEdit`: `true`

## 2. Initial approach — Music.app GUI automation

The first attempt drove Music.app through Hermes `computer_use`.

Observed:

- `computer-use doctor` eventually reported Accessibility, Screen Recording, and AX checks passing.
- `list_windows` found the Music.app window and `bring_to_front` worked.
- Music.app's accessibility tree remained unavailable: `get_window_state` returned `ax_window_unresolved`; the process reported zero usable AX windows/elements.
- Clicking the Music search field and `type_text` returned unverifiable results — typed text did not appear in the field.
- Multiple foreground/background attempts produced the same result.
- System Events accessibility probing timed out.
- Blind pixel clicking was rejected as unsafe and unverifiable.
- The anti-loop rule stopped further retries.

Why abandoned: the failure was no longer generic macOS Accessibility permission. Music.app itself was not exposing a usable accessibility tree to the automation path, so Hermes could neither target controls nor verify effects.

**Do not retry this path in Tunory** unless there is new evidence that Music.app's accessibility behavior has changed.

## 3. AppleScript attempt

A separate track drove Music.app via AppleScript.

What worked:

- Direct Music.app AppleScript could enumerate windows/playlists. Read-only scripting proved the application was reachable.

What did not work:

- The AppleScript `add` path expects local/file-backed objects, not arbitrary Apple Music catalog URLs. Attempting a catalog URL produced error `-43`.
- `open location` navigated to/opened content but did not add the catalog recording to My Library.
- The earlier third-party playlist skill used title/artist matching through AppleScript, which is too ambiguous for classical recordings.

Why abandoned: the task required exact recording identity, not title-level matching. AppleScript offered no reliable catalog-ID-driven write path for the Library and playlist workflow.

AppleScript remains a last-resort compatibility tool, not Tunory's primary architecture.

## 4. Third-party Apple Music skill investigation

`https://github.com/nvhoanganh/apple-music-playlist-skill` was evaluated (pinned commit observed: `54b02bfacc9677212a91f58f6502c606da2f3a05`).

Architecture observed:

- iTunes Search API for matching,
- a third-party hosted developer-token service,
- Music User Token stored on disk,
- `POST /v1/me/library`,
- AppleScript title-based playlist sweep.

Rejected aspects:

- fuzzy catalog matching with fallback to first search result,
- title/artist substring matching (wrong-answer-prone for classical),
- no exact Library-ID reconciliation,
- destructive `--replace` mode,
- plaintext `user_token.txt`,
- reliance on third-party hosted authorization/token infrastructure.

Useful findings retained:

- Apple Music REST endpoint shapes,
- proof that direct Library writes are possible,
- the general authorization recipe,
- the value of driving everything by exact catalog IDs.

The repository was not used directly: its trust model and matching semantics were incompatible with the exact-recording requirement and with the security rules for the private key and tokens.

## 5. Incorrect MusicKit entitlement assumption

An early diagnosis treated `com.apple.developer.musickit` as a required managed entitlement needing a matching provisioning profile. That diagnosis was wrong.

Per Apple documentation and DTS guidance applied during this work: MusicKit is an **App Service** enabled on the App ID, not an entitlement manually placed in the entitlements file. Adding `com.apple.developer.musickit` by hand is incorrect and can itself prevent launch.

Actions taken:

- The entitlement was removed from `Tunory/Tunory.entitlements` and from all helper signing invocations.
- MusicKit was enabled as an App Service on the App ID `com.raelldottin.Tunory` in the Apple Developer portal instead.

Evidence it is not required: the final working helper (`AMHelper.app`) was signed **without** `com.apple.developer.musickit` — its entitlements contain only the default sandbox set — and it successfully obtained a Music User Token and completed the full workflow.

**Do not add `com.apple.developer.musickit` to future Tunory entitlements.**

## 6. Signing and helper-app failures

Several configurations failed before the working setup. These failures were useful because they isolated developer authentication, user authorization, bundle identity, and token-provider behavior as separate problems.

- **Ad hoc signing:** binary launched and `MusicAuthorization.currentStatus` read as `authorized`, but `MusicUserTokenProvider.userToken` failed with "Permission denied".
- **Apple Development cert (team `52S9T2SC6T`) with bundle `com.raelldottin.Tunory.AMHelper`:** team mismatch with the Media Services key's team (`DHJQ7QC53Z`) and a different App ID; user token request failed ("Failed to request user token").
- **Developer ID Application (team `DHJQ7QC53Z`) with bundle `com.raelldottin.Tunory`:** team and bundle aligned; the user token request still failed with an opaque error (see §8 — the actual root cause was the Info.plist, not signing).

Note: not every failure was caused by signing. The final blocker turned out to be a metadata gap in the helper's Info.plist.

## 7. Media Services key verification

Final verified configuration:

- Key ID: `GS5L8952F2`
- Team ID: `DHJQ7QC53Z` (resolved from Tunory's `DEVELOPMENT_TEAM` in `Tunory.xcodeproj/project.pbxproj`)
- Private key file used during development: `/Users/raelldottin/Downloads/AuthKey_GS5L8952F2.p8` (contents never copied into any artifact, log, or repository)
- The key file is a 256-bit EC private key (`openssl pkey -text` confirmed P-256), consistent with ES256.

Apple Developer portal showed for the key: name "Tunory", Enabled Services: **Media Services** (including MusicKit), with Media configuration associated with Tunory.

Gate evidence:

- ES256 developer JWT generated with header `{alg: ES256, kid: GS5L8952F2}` and claims `{iss: DHJQ7QC53Z, iat, exp}` (one-hour TTL).
- The JWT authenticated a read-only catalog request: `GET /v1/catalog/us/songs/1436241421` returned HTTP 200 with the expected track ("The Lark Ascending" — Hilary Hahn, LSO & Sir Colin Davis).

Distinctions worth keeping:

- **Media Services key configuration** authorizes the developer JWT against Apple's APIs.
- **MusicKit App Service** on the App ID authorizes the signed app to participate in MusicKit.
- **User authorization** (`MusicAuthorization.request()`) is a per-user, per-device consent and is independent of both.

These fail independently; each must be verified separately.

## 8. Opaque MusicUserToken failure and actual fix

With correct team, correct bundle ID, MusicKit enabled on the App ID, and MusicKit enabled on the key, `MusicUserTokenProvider.userToken(for:options:)` still failed with the opaque Swift error `MusicKit.MusicTokenRequestError code=0` (empty `userInfo`).

`log stream --predicate 'subsystem CONTAINS[c] "musickit"'` exposed the underlying error:

```
ICError -7101 "Invalid request: Missing requesting bundle version for user token request."
```

Fix: add `CFBundleVersion` and `CFBundleShortVersionString` to the helper's `Info.plist`, re-sign, and force LaunchServices to re-register the bundle (`lsregister -f`) — the system had cached the older bundle record, so the first post-fix attempt still failed until re-registration.

**The issue was not solved by adding a MusicKit entitlement.** Observed failure mode was Apple's media-services token endpoint rejecting a bundle with no version metadata; the entitlement hypothesis earlier in the session was a wrong turn.

Final successful authorization chain:

1. Signed helper app (`AMHelper.app`, Developer ID Application, team `DHJQ7QC53Z`).
2. Bundle identity `com.raelldottin.Tunory` (the App ID with MusicKit App Service enabled).
3. Info.plist contains `CFBundleVersion`, `CFBundleShortVersionString`, and `NSAppleMusicUsageDescription`.
4. Valid developer JWT (see §7).
5. `MusicAuthorization.currentStatus == .authorized` (consent had been granted previously via Apple's system dialog).
6. `MusicUserTokenProvider.userToken(for:options:)` returned a valid Music User Token (never printed or persisted).
7. Read-only `GET /v1/me/library/playlists` returned HTTP 200 with real playlist data.

## 9. Successful architecture

```
Hermes
  ↓
Signed Tunory / AMHelper process   (Swift, MusicKit, in-memory tokens)
  ↓
Developer JWT  (ES256; kid=GS5L8952F2, iss=DHJQ7QC53Z, 1h TTL)
  ↓
Music User Token  (obtained via MusicUserTokenProvider; never logged)
  ↓
Apple Music REST API  (api.music.apple.com)
  ↓
My Library
  ↓
Existing Apple Music playlist ("After Hours — Violin & Trumpet")
  ↓
Independent read-back verification
```

The completed run did **not** use: Music.app GUI automation, Accessibility automation, AppleScript, third-party token hosting, or fuzzy catalog search.

## 10. Exact manifest and catalog identity

The workflow reused the existing manifest at `~/.hermes/cache/scratch/am/manifest.json` (17 ordered entries with catalog IDs, names, artists, and Apple Music URLs). Catalog IDs were treated as the authoritative recording identity; title/artist strings were used for display and sanity-checks only.

Final catalog IDs by position (values from the verified final state):

| Pos | Catalog ID | Track |
|----:|-----------:|-------|
| 1 | 1436241421 | The Lark Ascending — Hilary Hahn, LSO & Sir Colin Davis |
| 2 | 1440767734 | Mercy — Hilary Hahn & Cory Smythe |
| 3 | 1395267545 | Sonata for Violin Solo No. 1, BWV 1001: III. Siciliana — Hilary Hahn |
| 4 | 1046363534 | Violin Partita No. 2 in D minor, BWV 1004: III. Sarabande — Hilary Hahn |
| 5 | 1645448977 | 3 Songs, Op. 7: I. Après un rêve — María Dueñas & Itamar Golan |
| 6 | 1452405044 | Spiegel im Spiegel — Nicola Benedetti & Alexei Grynyuk |
| 7 | 1452264394 | Violin Concerto No. 1, BWV 1041: 2. Andante — Janine Jansen & friends |
| 8 | 1630765082 | Quiet City — Scott Stroman, Britten Sinfonia & Alison Balsom |
| 9 | 899233733 | Oblivion — Alison Balsom, Guy Barker & Guy Barker Orchestra |
| 10 | 914235474 | 14 Songs, Op. 34: No. 14, Vocalise — Alison Balsom, Edward Gardner & Göteborg Symfoniker |
| 11 | 914235476 | Violin Concerto in A minor, BWV 1041: II. Andante — Alison Balsom, Edward Gardner & Göteborg Symfoniker |
| 12 | 1103481569 | The Way You Look Tonight — Alison Balsom & Tom Poster |
| 13 | 899233701 | 3 Gymnopédies: III. Lent et grave — Alison Balsom, Guy Barker & Guy Barker Orchestra |
| 14 | 1561852388 | Concerto in C minor, S. Z799: Adagio (arr. Bach/Helseth) — Tine Thing Helseth & Kåre Nordstoga |
| 15 | 1561852587 | Den första gång jag såg dig (arr. Helseth & Nordstoga) |
| 16 | 1561127084 | Sofðu unga ástin mín (arr. Jarle Storløkken) |
| 17 | 1561852731 | Peer Gynt, Op. 23: Solveig's Lullaby (arr. Helseth) |

Notable corrections from earlier research (final values above supersede any provisional values in pre-manifest working notes):

- Track 11: final catalog ID `914235476` (the Alison Balsom / Edward Gardner / Göteborg performance).
- Track 14: final catalog ID `1561852388`.
- Track 16: final catalog ID `1561127084`.
- Track 17: final catalog ID `1561852731`.

Why exact identity mattered most: the playlist intentionally contains **two different performances** of Bach's Violin Concerto in A minor BWV 1041, II. Andante — pos 7 (`1452264394`, Janine Jansen) and pos 11 (`914235476`, Alison Balsom trumpet arrangement). Title- or work-level matching cannot distinguish these; only catalog IDs can. The same applies across classical repertoire with many recordings per work.

## 11. Library workflow

Successful sequence:

1. Read existing Library first (`GET /v1/me/library/songs`, full pagination).
2. Compute which manifest catalog IDs were absent.
3. Add missing songs only, via `POST /v1/me/library?ids[songs]={catalogId}` — one request per recording for attributable failures. Each returned HTTP 202.
4. Treat 202 as acknowledgment only. Wait, then perform a fresh full Library re-read.
5. Verify each of the 17 catalog IDs is now present, and record its Library song ID (`i.…`).

Important implementation discovery: for `library-songs` resources, the catalog identity was found under **`attributes.playParams.catalogId`**, not under `relationships.catalog`. The relationship payload was absent for many library items (notably iTunes-Match-era uploads) — only 57 of the first 5,075 enumerated items exposed a `relationships.catalog` entry, while 5,783 of the full set exposed `playParams.catalogId`. `orchestrate.py` now checks `playParams.catalogId` first and falls back to `relationships.catalog`.

Don't rely on `relationships.catalog` alone for library-song → catalog mapping; the successful run disproved that assumption.

Library final result: **17/17**.

## 12. Library pagination finding

Observed behavior of `GET /v1/me/library/songs?limit=100`:

- First page honored `limit=100`.
- Subsequent pages returned 25 items regardless of the requested limit.
- `meta.total` reported ~11,496 songs; full enumeration fetched 11,513 items across ~450 requests before `next` became absent.

Implication for Tunory: do not repeatedly enumerate the full Library inside one transaction. Recommended:

- enumerate once per transaction,
- cache catalog-ID → Library-ID mappings for the run,
- use targeted lookup/search when reliable (with the caveat that `ids[catalog]=…` is **not** a supported filter — it was ignored and returned a default page; library search `/v1/me/library/search?types=library-songs` does work for targeted checks),
- refresh only affected state,
- avoid one full Library scan per track.

This is an optimization recommendation grounded in observed behavior, not a hard correctness requirement.

## 13. Playlist preflight

Target: `After Hours — Violin & Trumpet` — ID `p.5PG55oBuOxMpdl`, `canEdit: true`.

Baseline at write time: **EMPTY** (zero tracks). That is the safest starting state and made ordered appends unambiguous.

Also observed: `GET /v1/me/library/playlists/{id}/tracks` for an empty playlist returns HTTP 404 ("No related resources"), which the orchestrator treats as "empty" rather than fatal.

Classification model used/planned for preflight:

- `EMPTY` — no tracks; append full sequence.
- `EXACT_COMPLETE` — exactly tracks 1..17 once each, in order; skip mutations.
- `CORRECT_PREFIX` — tracks 1..N correct, nothing else; append suffix only.
- `WRONG_ORDER` — known tracks present but misordered; stop, don't self-repair.
- `CONTAINS_DUPLICATES` — duplicates present; stop.
- `CONTAINS_UNRELATED_TRACKS` — unexpected entries; stop.

Only `EMPTY`, `CORRECT_PREFIX`, and `EXACT_COMPLETE` are treated as automatically safe.

## 14. Playlist append workflow

Endpoint: `POST /v1/me/library/playlists/{id}/tracks` with body `{ "data": [{ "id": "<library-song-id>", "type": "library-songs" }] }` — Library IDs were preferred because they had just been verified.

Observed: HTTP 204 for each of the 17 append operations; ordering preserved end-to-end.

Write discipline:

1. Append exact track.
2. Allow bounded propagation; re-verify state.
3. Continue only after state is known.
4. Never re-issue a write whose status is uncertain without first reconciling current state.
5. Preserve any existing correct prefix.

Final: Playlist 17/17, Ordering PASS, Duplicates introduced 0.

## 15. Expired developer JWT failure

A mid-session failure deserves its own record: one orchestration run aborted in Gate 3 when the catalog fetch for track 16 returned HTTP 401. Cause: the developer JWT had been minted with a one-hour TTL roughly an hour earlier and expired mid-run.

Recovery: generate a fresh developer JWT, re-run the orchestration, and let the gates re-verify from scratch. Nothing depended on the partial failed run.

Lessons for Tunory:

- Inspect token expiry before starting a transaction.
- Refresh before expiry, or choose a TTL comfortably longer than the bounded operation.
- Never blindly retry a 401 as if it were a track-specific data problem; check auth freshness first.

## 16. Independent final verification

Completion is defined by fresh reads, not mutation acknowledgments. After the appends, the playlist was re-fetched and compared against the manifest:

| # | Track | Catalog ID | Library ID | Position |
|--:|-------|-----------:|------------|---------:|
| 1 | The Lark Ascending | 1436241421 | i.aJG7WX4HEWOpld | 1 ✓ |
| 2 | Mercy | 1440767734 | i.06QzBY1SVMDra6 | 2 ✓ |
| 3 | Sonata BWV 1001: III. Siciliana | 1395267545 | i.xrXo0AYS4qk0Er | 3 ✓ |
| 4 | Partita BWV 1004: III. Sarabande | 1046363534 | i.vMXDzrVF9BzQbR | 4 ✓ |
| 5 | Après un rêve | 1645448977 | i.rXzG1odHDpvV68 | 5 ✓ |
| 6 | Spiegel im Spiegel | 1452405044 | i.7PJOB4ofV1ql46 | 6 ✓ |
| 7 | BWV 1041: II. Andante (Jansen) | 1452264394 | i.EYVNKmoszMV7oZ | 7 ✓ |
| 8 | Quiet City | 1630765082 | i.B0Vmg2KHeW6dJX | 8 ✓ |
| 9 | Oblivion | 899233733 | i.dlvJb1PF6A2Lve | 9 ✓ |
| 10 | Vocalise | 914235474 | i.NJvkVDXHPDxarK | 10 ✓ |
| 11 | BWV 1041: II. Andante (Balsom) | 914235476 | i.9oJEpRNhNvzdlg | 11 ✓ |
| 12 | The Way You Look Tonight | 1103481569 | i.aJGqrkqFEWOpld | 12 ✓ |
| 13 | Gymnopédies: III | 899233701 | i.06QzBO1tVMDra6 | 13 ✓ |
| 14 | Concerto in C minor: Adagio | 1561852388 | i.xrXo0XYF4qk0Er | 14 ✓ |
| 15 | Den första gång jag såg dig | 1561852587 | i.vMXDzXVt9BzQbR | 15 ✓ |
| 16 | Sofðu unga ástin mín | 1561127084 | i.rXzG1pZFDpvV68 | 16 ✓ |
| 17 | Solveig's Lullaby | 1561852731 | i.7PJOB6OTV1ql46 | 17 ✓ |

Fresh read-back confirmed: Catalog 17/17; Library 17/17; Playlist 17/17; exact manifest order; exactly one occurrence of each recording; playlist size exactly 17; zero duplicates introduced; no unexpected modifications relative to the pre-mutation baseline.

## 17. Security handling

- `.p8` contents were never printed, logged, committed, uploaded, or included in any artifact.
- The developer JWT was written only to a 0600 file in the scratch directory (`~/.hermes/cache/scratch/am/.devtoken`), read by tooling via a path environment variable, and deleted at the end of the session.
- The Music User Token was obtained in-process by the helper via `MusicUserTokenProvider`, kept in memory, and never printed, persisted, or passed through chat.
- Authorization headers were redacted from logs (helper prints only `__HTTP_STATUS__`).
- Baseline/checkpoint artifacts contain no credentials:
  - `~/.hermes/cache/scratch/am/afterhours-baseline.json`
  - `~/.hermes/cache/scratch/am/afterhours-checkpoint.json`
- Nothing secret was committed to Git. The private key lives outside the repository and stays there.

## 18. Final artifacts

Verified to exist at documentation time:

- Helper app (signed): `/Users/raelldottin/Documents/Personal/Tunory/Tools/AppleMusicAPI/AMHelper.app` — Developer ID Application, team `DHJQ7QC53Z`, bundle `com.raelldottin.Tunory`.
- Helper source: `/Users/raelldottin/Documents/Personal/Tunory/Tools/AppleMusicAPI/Sources/AMHelper/main.swift` (SwiftPM package, see `Package.swift`).
- Orchestrator: `/Users/raelldottin/Documents/Personal/Tunory/Tools/AppleMusicAPI/orchestrate.py`.
- Developer token generator: `/Users/raelldottin/Documents/Personal/Tunory/Tools/AppleMusicAPI/devtoken.py`.
- Baseline/checkpoint: `~/.hermes/cache/scratch/am/afterhours-baseline.json`, `~/.hermes/cache/scratch/am/afterhours-checkpoint.json` (playlist id, `canEdit`, baseline state `EMPTY`, library catalog snapshot, timestamp; no secrets).
- Manifest: `~/.hermes/cache/scratch/am/manifest.json`.

## 19. What Tunory should implement permanently

Tunory should:

- use Apple's official Apple Music REST API,
- treat exact catalog IDs as recording identity,
- use signed native MusicKit authorization (`MusicAuthorization`, `MusicUserTokenProvider`) inside a properly-versioned bundle,
- keep developer and user credentials out of orchestrator output (in-memory or Keychain, paths-not-values across process boundaries),
- reconcile against existing Library state before any writes,
- reuse the existing playlist, verify uniqueness of the name, and check `canEdit`,
- classify playlist state (EMPTY / EXACT_COMPLETE / CORRECT_PREFIX / WRONG_ORDER / CONTAINS_DUPLICATES / CONTAINS_UNRELATED_TRACKS) and write only in provably safe states,
- use read-after-write verification with bounded retries,
- preserve correct prefixes; never destructively repair without explicit authorization,
- recover idempotently (state classification makes re-runs safe),
- manage developer-token lifetime deliberately (check expiry, refresh proactively),
- cache catalog→Library mappings per transaction; never full-scan the Library per track,
- expose a narrow manifest-driven automation interface to Hermes.

Tunory should NOT depend on:

- Music.app Accessibility,
- blind GUI clicks,
- AppleScript title matching,
- fuzzy catalog matching,
- third-party developer-token hosting,
- `com.apple.developer.musickit`,
- plaintext user-token files.

## 20. Operational runbook

### Preconditions

- Valid Media Services key (MusicKit enabled on the key).
- Correct team ID; App ID for the bundle has the MusicKit App Service enabled.
- Signed Tunory/helper build whose Info.plist carries `CFBundleVersion`, `CFBundleShortVersionString`, and `NSAppleMusicUsageDescription`.
- User authorization granted (`MusicAuthorization.authorized`).
- Exact catalog manifest (ordered, unique catalog IDs).
- Target playlist uniquely identified and `canEdit == true`.

### Execution

1. Generate/validate developer token; confirm with a read-only catalog call.
2. Obtain/reuse authorized Music User Token (helper-internal).
3. Read the target playlist; classify state against the manifest.
4. Read/reconcile the Library; compute missing catalog IDs.
5. Add missing Library tracks (`POST /v1/me/library?ids[songs]=…`), one at a time.
6. Verify Library contains all manifest IDs (fresh read).
7. Append the missing playlist suffix in manifest order (204 per append).
8. Verify after writes.
9. Perform fresh final reads of playlist and Library.
10. Emit the completion report (catalog/library/playlist counts, ordering, duplicates, anomalies).

### Stop conditions

- authentication failure (developer or user),
- ambiguous manifest identity,
- playlist not uniquely identifiable,
- playlist `canEdit == false`,
- playlist in a non-safe state (wrong order, duplicates, unrelated tracks),
- unexpected recording observed after a write,
- bounded verification retries exhausted,
- token expiration without successful refresh.

On any stop: preserve completed work, save checkpoint state, report the exact unresolved item, and wait for human direction.
