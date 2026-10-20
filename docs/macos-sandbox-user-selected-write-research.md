# Research: macOS App Sandbox write access to user-selected destinations

Card: t_c8d05ad3 (research Task 0) → feeds design card t_691e4034.
Read-only research deliverable; no product code changed by this card.
Date: 2026-10-19. Worktree: `wt/t_691853ee` (shared t_691e4034 workspace).

Purpose: authoritatively document the macOS sandbox mechanics that govern
least-privilege WRITE access to user-selected destinations (converted audio
output), covering the entitlement family, security-scoped URLs and their
lifecycle, app-container staging tradeoffs, and persistence (security-scoped
bookmarks). The card body asks about the `ENABLE_USER_SELECTED_FILES =
readonly` constraint; note that constraint has ALREADY been flipped to
`readwrite` (commit 990b5f9, both Debug and Release, pbxproj lines 391/435)
with built-product regression proof (commit 43c08bc). This research grounds
that decision and supplies the mechanics the design card must integrate.

## 0. Sources and authority

Apple's current developer documentation reorganized in 2025-2026; the modern
URLs (`developer.apple.com/documentation/xcode/accessing-files-from-the-macos-app-sandbox`,
`.../adopting-the-mac-app-sandbox`) now 404. The operative primary sources
used are Apple's archived App Sandbox documentation (fetched via
web.archive.org, snapshot timestamps cited) plus the LIVE system on this
machine (macOS 27.0.1, Build 26A434):

1. App Sandbox Design Guide — App Sandbox in Depth
   `http://web.archive.org/web/20201203170126/https://developer.apple.com/library/archive/documentation/Security/Conceptual/AppSandboxDesignGuide/AppSandboxInDepth/AppSandboxInDepth.html`
2. Entitlement Key Reference — Enabling App Sandbox chapter (entitlement
   key semantics, Xcode setting tables)
   `http://web.archive.org/web/20190102001110/https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html`
3. App Sandbox Design Guide — QuickStart (ts 20180920125203), Designing
   Your Sandbox (ts 20180920125840), About App Sandbox (ts 20180920120600),
   Implementation Checklist (ts 20190319123729).
4. Live system: `/System/Library/Sandbox/Profiles/application.sb`
   (macOS 27.0.1) — how the kernel sandbox profile actually gates
   user-selected/bookmark entitlements; Xcode 17 templates
   (`.../Library/Xcode/Templates/.../TemplateInfo.plist`) —
   `ENABLE_USER_SELECTED_FILES` is the standard Xcode mechanism.
5. Tunory codebase at `wt/t_691853ee` @ 8c96404 (verified idle/clean
   before reading).

The legacy guide is marked "retired" by Apple, but the mechanics it
documents — Powerbox, the user-selected entitlement family,
security-scoped URLs and bookmarks — are the SAME mechanisms enforced by
the live macOS 27 system profile (see §5), which corroborates it.

## 1. The sandbox model in one paragraph

A sandboxed app's filesystem access is confined to its container. Outside
the container, Apple's guide states there are exactly three ways a sandboxed
app can reach filesystem locations:

> "Your sandboxed app can access file system locations outside of its
> container in the following three ways: At the specific direction of the
> user; By using entitlements for specific file-system locations; When the
> file system location is in certain directories that are world readable."

  — AppSandboxInDepth (archived)

For Tunory's local-import flow the first two are the relevant ones, and
least privilege means using (1) — user direction — for anything the user
can choose, and avoiding (2) for broad locations (see §4 for the rejected
alternatives).

## 2. User intent and the Powerbox

- The system technology that expands the sandbox on user direction is
  called the Powerbox. "Powerbox has no API. Your app uses Powerbox
  transparently when you use the NSOpenPanel and NSSavePanel classes."
  SwiftUI's `.fileImporter` drives the same panels.
- Security property (why this is the least-privilege channel):
  "it cannot be manipulated programmatically—specifically, there is no
  mechanism for hostile code to use Powerbox for accessing the file system.
  Only a user, by interacting with Open and Save dialogs via Powerbox, can
  use those dialogs to reach portions of the file system outside of your
  previously established sandbox." (AppSandboxInDepth)
- Grant scope follows exactly what the user picked:
  - Folder pick: "the system makes the ~/Documents folder, its contents,
    and its subfolders available to your app" — a folder grant covers the
    whole subtree.
  - Single-file pick: "If a user instead opens a specific file, or saves
    to a new file, the system makes the specified file, and that file
    alone, available to your app." — a file grant covers that file only.
- Other user interactions also expand the sandbox automatically: "dragging
  items to your app or choosing items from the Open Recent menu,
  automatically expand your sandbox to include those items," and macOS
  Resume re-adds "any items that are automatically opened."
  Tunory's local-import flow has NO drag/drop or Open Recent handlers
  (verified: no `onDrop`/`dropDestination`/`NSItemProvider` in the app
  sources), so every grant in this flow comes from an explicit panel
  interaction.

## 3. The user-selected entitlement family (exact semantics)

From the archived Entitlement Key Reference:

| Entitlement key | Apple's documented meaning |
|---|---|
| `com.apple.security.files.user-selected.read-only` | "Read-only access to files the user has selected using an Open or Save dialog" |
| `com.apple.security.files.user-selected.read-write` | "Read/write access to files the user has selected using an Open or Save dialog" |
| `com.apple.security.files.user-selected.executable` | "Allows apps to write executable files" (quarantine/Gatekeeper exemption for executables; irrelevant for audio output) |

- Xcode surface (Table 4-2): the "User Selected File" target setting maps
  to the read-only / read-write keys. In project terms this is
  `ENABLE_USER_SELECTED_FILES = readonly | readwrite`, which Xcode
  synthesizes into the effective entitlement at signing time — the key
  does NOT need to appear in the `.entitlements` file. (Verified on
  Tunory: `Tunory.entitlements` contains no user-selected key, yet the
  signed product carries the entitlement — proven by GAP D regression
  commit 43c08bc via `SecTaskCopyValueForEntitlement` inside the signed
  test host.)
- Semantics: "When you enable user-selected file access, you gain
  programmatic access to files and folders that the user opens using an
  NSOpenPanel object, and files the user saves using an NSSavePanel
  object." (EntitlementKeyReference)
- IMPORTANT: the entitlement does not itself grant any file access. It
  only makes the powerbox channel effective; the actual grant is always
  the specific thing the user picked in the panel, scoped as in §2.

### Why read-write (not read-only) for Tunory

The destination for converted audio is a user-chosen directory OUTSIDE the
app container. Writing the converted output (and the atomic temp file that
precedes the promote rename) into that directory requires read-write scope
on the user-selected grant. With `readonly`, any write into the user-chosen
destination fails (the pre-990b5f9 fail-closed behavior: the 2026-10-13
signed-app baseline proved zero outputs written, originals byte-identical).

### Rejected broader alternatives (least-privilege comparison)

| Alternative | Why rejected |
|---|---|
| `com.apple.security.files.all` | True escape hatch: grants the whole user filesystem. The GAP D regression (43c08bc) explicitly asserts its ABSENCE in every context. |
| Standard-location entitlements (`com.apple.security.musicfolder.read-write` etc.) | Grant the ENTIRE Music/Movies/Pictures/Downloads folder regardless of user choice — broader than user intent, and writes outside user direction. |
| `com.apple.security.temporary-exception.files.absolute-path-read-write` | Blunt absolute-path exception; time-limited crutch, defeats the sandbox model. |
| Disable App Sandbox | Regression test 43c08bc pins app-sandbox ON; the feature is only acceptable inside the sandbox. |

The user-selected read-write grant is therefore the narrowest entitlement
that can implement "write converted audio where the user says."

## 4. Security-scoped URLs: acquisition, claiming, release

### Acquisition

Only the powerbox (or drag/Resume) issues security-scoped URLs. There is
no programmatic way to obtain one for an arbitrary path. Tunory's two
acquisition surfaces today:

- `.fileImporter` (SwiftUI) — individual audio files (LocalImportView.swift:38).
- `NSOpenPanel` directory picks — destination folder
  (LocalImportView.swift:47-58, `presentOutputPicker`) and source folders
  (LocalImportView.swift:63-76, GAP A `presentFolderPicker`).

### Lifecycle within a run (the mandatory claim protocol)

Apple's guide (AppSandboxInDepth, "Using Security-Scoped Bookmarks" step
list, which restates the URL rule for all security-scoped URLs):

> "In a sandboxed app, you cannot access the file-system resource that a
> security-scoped URL points to until you call the
> startAccessingSecurityScopedResource method on the URL. When you no
> longer need access to a resource that you obtained using security scope
> (typically, after you close the resource) you must call the
> stopAccessingSecurityScopedResource method on the resource's URL."

Rules that follow:

1. Claim BEFORE any I/O on the URL. An unclaimed open does not produce a
   helpful sandbox error at the app layer — in Tunory's flow it manifested
   as the prober misreporting valid files "undecodable by AVFoundation"
   (defect t_d07f9a4d, documented in SecurityScopedAccess.swift:6-12).
2. Claims must be balanced: one `stopAccessing` per `true` begin, on every
   exit path including thrown errors.
3. Claim the URL the powerbox issued. A rebuilt copy of the same path
   (e.g. a child file URL constructed inside a granted folder) is NOT the
   granted URL; the folder grant covers the subtree, so claims stay on the
   panel-returned folder URL (LocalImportViewModel.swift:158-164, 95-99).
4. After a stop, re-claim before touching the resource again (Apple's
   step-4 rule).

Tunory's existing implementation matches this contract and is the
reference for the design card:

- `SecurityScopedAccessClaiming` protocol + `SystemSecurityScopedAccess`
  adapter — the ONLY place the app touches
  start/stopAccessingSecurityScopedResource (transport layer, no decision
  logic; SecurityScopedAccess.swift).
- `SecurityScopedClaims` — batch of claims for one operation, released
  newest-first exactly once, idempotent, paired with `defer`
  (SecurityScopedAccess.swift:55-82).
- `LocalImportViewModel.analyze/convert/...` claim every granted URL the
  operation touches (selected files/folders + destination) and release on
  every exit path (LocalImportViewModel.swift:199-205).
- Unit tests assert the claim CONTRACT without faking sandbox proof:
  TunoryTests `LocalImportViewModelSecurityScopeTests` (5/5 at the
  phase-10 integration tip 9cc872d).

### Persistence across runs — the default is NONE

> "Your app's access to file-system locations outside of its container—as
> granted to your app by way of user intent, such as through
> Powerbox—does not automatically persist across app launches or system
> restarts. When your app reopens, you have to start over. (The one
> exception to this is for files open at the time that your app
> terminates, which remain in your sandbox thanks to the macOS Resume
> feature.)"  — AppSandboxInDepth, "Persistent Resource Access"

So today's Tunory behavior — destination and sources re-picked via panel
every session — is the fail-closed default. Anything remembered across
launches requires security-scoped bookmarks (§6).

## 5. Live-system corroboration (macOS 27.0.1)

From `/System/Library/Sandbox/Profiles/application.sb` (read 2026-10-19):

```scheme
(when (or (entitlement "com.apple.security.files.bookmarks.app-scope")
          (entitlement "com.apple.security.files.bookmarks.document-scope")
          (entitlement "com.apple.security.files.bookmarks.collection-scope")
          (entitlement "com.apple.security.files.user-selected.read-only")
          (entitlement "com.apple.security.files.user-selected.read-write"))
      (allow mach-lookup (global-name "com.apple.scopedbookmarksagent.xpc")))
```

Interpretation (two distinct facts, two proof levels):

- The bookmark-resolution XPC service is reachable whenever ANY of the
  user-selected/bookmark entitlements is present (live-system fact).
- Creating *scoped* bookmarks still requires the dedicated bookmark
  entitlements (`bookmarks.app-scope` / `bookmarks.document-scope`)
  per Apple's documented 5-step procedure (§6) — the XPC reachability
  alone is not documented as sufficient. Tunory currently has NEITHER
  bookmark entitlement (Tunory.entitlements holds only app-sandbox,
  disable-library-validation(false), network.client,
  automation.apple-events), and the live powerbox drive needed to prove
  bookmark behavior end-to-end has NOT been run (see §9).

This also confirms the live system still enforces exactly the entitlement
keys the archived guide documents.

## 6. Security-scoped bookmarks (persistence mechanism)

Available since macOS 10.7.3. Apple's guide lists the canonical example
use case as — verbatim — "A user-selected download, processing, or
output folder", which is exactly Tunory's destination-directory problem.

### Two types

- App-scoped bookmark: persistent access for the APP to a user-specified
  file or folder. Create after obtaining initial access via NSOpenPanel;
  "store it as part of the app's configuration (perhaps in a property
  list file or using the NSUserDefaults class)". This is the type a
  remembered destination folder needs.
- Document-scoped bookmark: a document stores references to other files;
  resolvable by any app holding the bookmark data AND the owning document
  (portable). Constraint that rules it out for Tunory's destination: "A
  document-scoped bookmark can point only to a file, not a folder" — the
  destination is a folder.

### The five-step lifecycle (Apple's procedure, abridged)

1. Set the appropriate bookmark entitlement once per target:
   `com.apple.security.files.bookmarks.app-scope = true` (app-scoped) or
   `...document-scope = true` (document-scoped).
2. CREATE the bookmark when the user has indicated intent (powerbox
   grant in hand): `NSURL.bookmarkData(options: [.withSecurityScope])`
   (legacy names: `bookmarkDataWithOptions:includingResourceValuesForKeys:relativeToURL:error:`).
3. RESOLVE it later (e.g. after relaunch):
   `URL(resolvingBookmarkData:options:[.withSecurityScope]relativeTo:bookmarkDataIsStale:)`
   (legacy: `URLByResolvingBookmarkData:...`). Result is a
   security-scoped URL. If `bookmarkDataIsStale` is true (target moved /
   renamed), re-create the bookmark from the resolved URL.
4. Immediately `startAccessingSecurityScopedResource()` on the resolved
   URL before any I/O.
5. `stopAccessingSecurityScopedResource()` as soon as you are done.
   After a stop you must return to step 4 to use the resource again;
   after relaunch you must return to step 3.

### Revocation / staleness semantics for the design card

- Moving/renaming the bookmarked folder: resolution may still succeed
  (bookmark tracks the file ID) but reports stale → recreate. If the
  user deletes the folder, resolution fails → treat as revoked, re-ask
  via powerbox. Never assume the old path string still means the same
  folder: resolve the bookmark, not the path.
- Bookmarks preserve user intent, not blanket access: the grant remains
  exactly the originally-picked folder (subtree scope per §2). If the
  user intended a different folder later, they must re-pick.
- Storage location: app-scoped bookmark DATA belongs in the app container
  (config plist / UserDefaults). It is opaque data; it does not extend
  the sandbox until resolved AND claimed, so storing it is safe.
- Cost of adopting bookmarks: one new entitlement key
  (`bookmarks.app-scope`), plus the create/resolve/claim/release code at
  the transport layer, plus stale handling, plus tests. The GUI journal
  already lives in the container, so no persistence change is needed
  there.

## 7. App-container staging analysis (asked by the design card)

Question: stage converted output inside the app container and then
transfer into the user-selected destination, instead of writing directly?

The final artifact must land in the user-chosen folder, so a
read-write powerbox grant on that folder is required EITHER WAY. Staging
adds no entitlement it can avoid; it only changes WHERE the intermediate
bytes live.

| Aspect | Direct write (current) | Container staging |
|---|---|---|
| Entitlements needed | user-selected read-write (only) | user-selected read-write (SAME — final copy still writes into the destination) |
| Atomicity | temp file in SAME directory + rename — atomic on APFS (LocalImportEngine.swift:446-505, "research §5") | cross-directory move to destination is a COPY unless same volume → a partially-visible window in the destination, or double I/O + cleanup on failure |
| I/O cost | single write | write + copy (≈2x) |
| Failure residue | temp in destination removed on every failure path (engine does this) | staging residue in container must ALSO be cleaned; on copy failure the destination may hold a partial file |
| Journal | GUI journal already in container (app support) | same |
| Security | grant scoped exactly to what user picked | identical grant required; no security gain |

Conclusion for the design card: container staging offers NO security or
robustness advantage for this flow and costs atomicity + I/O. The current
design (write temp into the destination directory, validate, same-dir
rename) is the correct one, and it is precisely what requires the
read-write user-selected grant. Staging is only worthwhile if a future
requirement asks for "convert first, pick destination later" UX — noted
as a non-goal today.

One REAL inconsistency found for the design card: the CLI
`local-import` verb constructs its `LocalImportJournal(directory:
outputDirectory)` (TunoryApp.swift:644) — the journal is written INTO the
user-passed output directory — while the GUI keeps the journal in the app
container (LocalImportViewModel.swift:117-120). The CLI is already
fail-closed by design for headless source reads (phase-10 report §4.2),
but the design card should either align the CLI journal location or
document the divergence as intentional.

## 8. Tunory state inventory (verified at 8c96404, 2026-10-19)

- `Tunory.xcodeproj/project.pbxproj:391,435` — `ENABLE_USER_SELECTED_FILES
  = readwrite` (Debug + Release), flipped from `readonly` at 990b5f9
  (2026-10-16, GAP D).
- `Tunory/Tunory.entitlements` — app-sandbox ON,
  disable-library-validation false, network.client ON,
  automation.apple-events ON. No user-selected key (synthesized by Xcode
  from the build setting); no bookmark entitlements.
- `Tunory/SecurityScopedAccess.swift` — claim protocol, system adapter,
  balanced batch claims (transport only).
- `Tunory/LocalImportViewModel.swift` — grantedFileURLs /
  grantedOutputDirectory retention; claims on panel-issued URLs; folder
  claims stay on the folder URL; GUI journal in app container.
- `Tunory/LocalImportView.swift` — fileImporter + NSOpenPanel pickers;
  no drag/drop or Open Recent surface.
- `TunoryTests/SandboxEntitlementRegressionTests.swift` (43c08bc) —
  kernel-enforced entitlement contract of the signed product:
  app-sandbox ON, user-selected read-write EFFECTIVE, stale readonly
  ABSENT, no broad filesystem grants. Negative-verified (reverting to
  readonly flipped the assertions).
- `Packages/TunoryCore/Sources/TunoryCore/LocalImportEngine.swift` —
  atomic temp+promote in the destination directory; destination guard
  re-check at promote time.
- Music.app import path (automation.apple-events) is OUT OF SCOPE for
  this card; it writes via Apple Events to Music.app, never direct
  library-database access (phase-10 report §2).

## 9. Proof levels

| Claim | Level |
|---|---|
| Entitlement key semantics / powerbox / bookmark procedure | PASS — Apple archived primary docs (quoted; archive URLs + timestamps in §0) |
| Live macOS 27 sandbox profile gates the same keys | PASS — read from /System/Library/Sandbox/Profiles/application.sb on this machine |
| Signed product carries user-selected read-write (Debug+Release), readonly absent, no files.all | PASS — GAP D regression tests (43c08bc, 4/4 in signed test host) + codesign effective-entitlement checks recorded in that commit |
| Claim protocol contract in unit tests | PASS — LocalImportViewModelSecurityScopeTests 5/5 at integration tip (phase-10 report §3) |
| Sandbox fail-closed under readonly (pre-flip) | PASS — 2026-10-13 signed-app baseline (zero outputs, originals byte-identical) |
| Live powerbox drive in the signed GUI (destination write observed end-to-end) | NOT ATTEMPTED (operator-gated; blocked earlier by AX window enumeration — see 43c08bc commit message) |
| Security-scoped bookmark create/resolve on THIS product | NOT ATTEMPTED — no bookmark entitlement present; documented from Apple primary sources only |

## 10. Direct answers for design card t_691e4034

1. Least-privilege write access = `com.apple.security.files.user-selected.read-write`
   (via `ENABLE_USER_SELECTED_FILES = readwrite`), powerbox-acquired
   destination grant, claims balanced at the transport boundary. Already
   in place at the source level; regression-pinned at the product level.
2. Security-scoped URL integration: acquire via panel only; retain the
   issued URLs; claim before I/O, release on all exits
   (SecurityScopedAccess.swift is the pattern; keep it).
3. Persistence: default is none. If "remember destination" is desired,
   add `com.apple.security.files.bookmarks.app-scope` and follow the
   5-step lifecycle (§6), storing opaque bookmark data in the app
   container; resolve-not-paths; treat stale/delete as revocation and
   re-ask. Document-scoped bookmarks cannot point at folders — not
   applicable.
4. Revocation: within a run, destination guard re-check at promote time
   (already implemented); across runs, bookmark staleness/failure →
   fail closed to re-picking.
5. App-container staging: rejected for this flow (§7) — same entitlement
   required, worse atomicity, more I/O, no security gain. Current
   same-directory temp+rename promote is the correct mechanism.
6. Open item for the design: CLI journal placement divergence
   (TunoryApp.swift:644 vs GUI container journal).
7. Outstanding runtime proof: live signed-GUI powerbox drive (operator-
   gated); bookmark round-trip if adopted.
