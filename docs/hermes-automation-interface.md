# Hermes Automation Interface (Phase 7)

Narrow local automation surface for Hermes ↔ Tunory. Exchanges files, never
credentials: developer and user tokens stay inside the signed app's
MusicKit/MusicDataRequest machinery and are never printed, exported, or
passed across the process boundary.

## Contract

    cat manifest.json | Tunory run - "<playlist-name>" [--result <path>]
    Tunory run <container-manifest.json> "<playlist-name>" [--result <path>]

1. Hermes writes a validated manifest (the same `ManifestParser` JSON
   contract every front-end uses: positions 1...N, positive unique catalog
   IDs, non-blank name/artist).
2. Hermes launches the signed app with the `run` verb.
3. The app performs the authorized MusicKit operations via the ONE
   canonical §20 `TransactionRunner` (catalog gate → preflight →
   reconcile → adds → fresh-read verify → plan → append-only execute with
   per-step proof → independent final read-back).
4. The app writes ONE structured result file (AutomationResult JSON) to
   `--result <path>` and always to stdout.

The manifest may be piped via stdin (`-`) or passed as a path readable by
the app. The app is sandboxed: arbitrary filesystem paths are NOT
readable — pipe through stdin, or place the file inside the app container
(`~/Library/Containers/com.raelldottin.Tunory/Data/`). Note: the
container directory on this machine carries the historical pre-rename
spelling (`com.raelldottin.Tunory`, an uppercase-T runtime artifact of
macOS container assignment from before the Phase 1 identifier fix); the
app's canonical bundle identifier remains `com.raelldottin.tunory`, and
this path is live-verified runtime evidence, not a canonical identifier.
Robust orchestrators should parse the resolved absolute path from the
process's stderr line `result written to <path>` rather than hard-coding
either spelling.

Result paths face the same constraint: the app reliably writes into its
own container (intermediate directories are created automatically), but
an orchestrator reading container contents back may need Full Disk
Access (macOS TCC protects `~/Library/Containers`). The always-available
channel is stdout: the identical JSON document is printed in every
invocation, so the simplest robust pattern is to capture stdout and treat
`--result` as a durable in-container audit copy.

## Result file schema (AutomationResult)

One JSON object:

    {
      "playlistName": "…",
      "playlistId": "p.…" | null,          // when discovery proved identity
      "playlistStateBefore": "empty" | "correctPrefix" | "exactComplete" | …,
      "succeeded": true|false,             // FINAL READ-BACK VERDICT ONLY
      "error": {"kind": "…", "detail": "…"} | null,   // §20 stop condition
      "phases": ["catalog","preflight",…],           // execution order
      "playlistVerified": true|false|null,           // §16 read-back ran?
      "checkpoint": {…} | null,            // interrupted-execute recovery
      "capturedAtMillisSinceEpoch": 0,
      "tracks": [                            // manifest order, pos 1...N
        {
          "pos": 1,
          "catalogId": 1436241421,           // authoritative identity (§10)
          "catalogVerified": true,           // Gate 3 verdict
          "name": "…", "artist": "…",
          "inLibraryBefore": true,           // phase-3 fresh read
          "libraryAddIssued": true,          // §11 write issued
          "libraryAddHttpStatus": 202,       // server ACK — never proof
          "inLibraryAfter": true,            // phase-5 fresh read proof
          "appendIssued": true,               // §14 write issued
          "appendHttpStatus": 204,            // server ACK — never proof
          "storedAtPosition": true,           // §16 exact-position proof
          "error": {"kind": "…", "detail": "…"} | null
        }, …
      ]
    }

### Acknowledgment vs proof (must-read)

`libraryAddHttpStatus` / `appendHttpStatus` record what the server
acknowledged. `inLibraryAfter` / `storedAtPosition` record what a FRESH
READ proved. A 2xx status alone never implies presence or storage; only
the fresh-read fields do. `succeeded` is true only when the final
read-back verified the exact manifest sequence.

### Error kinds (stable strings)

`transport`, `notAuthorized` (§15 — request MusicKit authorization, do
NOT treat as data failure), `catalogLookupFailed`, `libraryAddFailed`,
`playlistCreationFailed`, `playlistAppendFailed`, `playlistNotFound`,
`playlistAmbiguous`, `playlistNotEditable`, `playlistNotSafeToWrite`,
`librarySongMissing`, `playlistVerificationFailed`, `paginationAborted`,
`malformedResponse`, `checkpointDiverged`.

### Interrupted runs

An execute-phase interruption embeds a credential-free `checkpoint`
(playlist identity, manifest sequence, PROVEN stored prefix — the last,
uncertain step is excluded). Pass it to `Tunory recover` on restart;
recovery re-derives everything from Apple's actual state and stops for
human direction when reality diverges.

## Exit codes

    0  verified (final read-back proved the exact sequence)
    2  usage error / unreadable or invalid manifest
    3  §20 stop condition, or not verified / not authorized
    4  result file could not be written (stdout copy is still emitted)

## Determinism

`AutomationResultBuilder.build` is a pure function of (manifest,
TransactionReport, capturedAt): same inputs → identical bytes (sorted
keys). The runner, GUI, and CLI all consume the same canonical evidence;
the derivation never re-decides anything.

## Example

    cat manifest.json | /path/to/Tunory.app/Contents/MacOS/Tunory \
        run - "After Hours — Violin & Trumpet" --result results/run1.json
    echo $?   # 0 = verified
