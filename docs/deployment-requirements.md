# Tunory deployment requirements

Requirements baseline: 2026-10-21, researched against `main` at
`90bba219d3a95d1080e26df971d3e3f9f20a5597`. This document defines the release
contract and validation plan. It does not implement a pipeline or certify a
release. Recheck the observations below on the actual release candidate.

## Scope and decisions

Owner-selected first deployment: **macOS internal TestFlight** (2026-10-21).
The [local archive record](releases/macos-internal-testflight-2026-10-21.md)
captures the selected route, candidate, successful development-signed archive,
and successful local App Store Connect export. Automatic provisioning and the
owner's local signing authorization resolved the first export's missing-profile
failure. An internal tester group and an upload/build assignment remain
unspecified. A Mac App Store
release, external TestFlight, direct notarized macOS distribution, and iPhone/iPad
deployment require separate selection and their applicable requirements below.

| Decision | Requirement before dependent implementation |
| --- | --- |
| Platforms and compatibility | macOS selected. The first local archive is arm64 with minimum macOS 27.0; confirm the intended compatibility promise before distribution. Do not silently lower deployment targets to fit a runner. |
| Distribution | Internal TestFlight selected. Verify the App Store Connect macOS app record and identify the exact internal tester group before upload or assignment. Other routes remain unselected. |
| Audience and release owner | Name the person authorized to approve the exact build, platform, tester group or public audience, and release action. Internal, external, and public-link beta distribution are distinct actions. |
| Version and support | Select the marketing version, an acceptable unused build number, release notes, support contact, and privacy-policy location. Existing `1.0 (1)` settings are not proof that this version/build is available for upload. |
| Automation | Select a runner with the required Xcode/SDK, credential provisioning method, artifact storage/access, retention period, and approval mechanism. Verify Apple's current upload requirements before choosing the toolchain. |

This requirements contract preserves app behavior, identity, project signing
settings, capabilities, library-write semantics, branch protections, and unmerged
product work. Defining requirements does not by itself authorize signing-account
mutation, archive, upload, tester assignment, tag, GitHub Release, or store
submission. Subsequent preparation and its actual results are recorded separately.

## Verified repository baseline

| Contract | Observation and source |
| --- | --- |
| App identity | Product/target/scheme/display name `Tunory`; bundle `com.raelldottin.tunory`; team `DHJQ7QC53Z`. Debug and Release macOS effective build settings agree; generic iOS Release settings also agree. |
| Declared platforms | `SUPPORTED_PLATFORMS = iphoneos iphonesimulator macosx`; Catalyst disabled. macOS and iOS minimum deployment targets are `27.0`. Other project-level OS settings do not declare additional supported app platforms. See `Tunory.xcodeproj/project.pbxproj`. |
| Toolchain and architecture | Inspection used local Xcode `27.1` (`27A9275`), Swift language mode `5.0`, default actor isolation `MainActor`. The inspected host macOS settings report `arm64`; this does not establish the architecture set of a distribution archive. |
| Signing and sandbox | Automatic signing, generated Info.plist, sandbox enabled. The source entitlements enable sandbox and outbound network access; disable-library-validation is false. Effective macOS Release hardened runtime is `NO`, a gap for direct notarization. |
| MusicKit | The generated Music usage description discloses library additions and playlist creation/updates. App requests use MusicKit and `MusicDataRequest` inside the signed app, not the historical helper's credential-generation scripts. |
| Archive configuration | Shared `Tunory` scheme has a Release archive action. Its test action has no explicit app test targets. An archive action in XML is not a successful archive. |
| Hosted CI | `.github/workflows/core-tests.yml` runs TunoryCore tests and agent-review CLI tests on macOS 15 with Xcode 16.4. It does not build, sign, archive, upload, or distribute the app. Its older package-test toolchain is not a release-toolchain choice. |
| Existing distribution | GitHub has no releases and only the Core CI workflow at inspection time. Apple Developer/App Store Connect app records, builds, agreements, certificates, and tester groups were not inspected. |
| Historical proof | [Phase 9](phase9-beta-productization.md) records macOS builds and selected signed-app/runtime observations from 2026-10-02. These are historical evidence, not validation of a new candidate or an iPhone/iPad release. |
| Product boundary | Open PRs #1–#5 contain stacked guidance/UI/local-import work outside this baseline. Requirements for a release that includes them must be reassessed after their normal integration gates; this document does not claim those features ship from `main`. |

## Release gates and required evidence

Every gate record must identify its candidate source SHA, platform, build number,
toolchain, date, operator, commands/observations, and proof location. Use `PASS`,
`FAIL`, `NOT ATTEMPTED`, or `BLOCKED`; retain actual errors and prerequisites.
Source inspection, unit tests, builds, signed-app runtime, Apple processing, and
distribution observations are separate proof levels.

| Gate | Acceptance criterion | Required evidence |
| --- | --- | --- |
| G1: Source and review | Candidate comes from protected `main`; applicable CI and exact-commit agent review passed before its PR merge. Validate the resulting candidate SHA as well. A release tag or branch name alone is insufficient. | PR/head/base/merge SHAs, successful pre-merge CLI check, and CI run URL for the candidate. Existing [review policy](native-review-policy.md) remains in force: no mandatory human/code-owner PR approval. |
| G2: Deterministic checks | Run the existing core and review-tool suites successfully. Add applicable app/platform checks when those targets exist. | Commands, toolchain, exit codes, test counts, and CI run. The current baseline has 155 Swift and 29 Python tests; report actual results rather than hard-coding a count as a passing condition. |
| G3: Archive and identity | Produce a Release archive for each selected platform using an Apple-accepted Xcode/SDK. Inspect the archived app's identity, version/build, minimum OS, architectures, signature, and generated entitlements. | Archive/build log, effective Debug/Release settings, built Info.plist, signature/team and entitlement inspection, archive path and checksum. No ad hoc/unsigned build may be presented as distribution-signing proof. |
| G4: Authorization and runtime | Install and run the signed candidate on each selected platform. Verify denied/restricted/not-determined/authorized states, read-only connectivity, actual file-picker import/review, and recovery behavior. Exercise offline/expired-authorization and partial-failure paths without misleading success. | Device/Mac model, OS, install source, exact version/build, steps, expected/actual observations, and redacted screenshots/logs. Include supported appearance, accessibility labels/text sizes, and adaptive layouts. Simulator or macOS evidence cannot certify iPhone/iPad behavior. |
| G5: Music data integrity | For a write-capable release, prove explicit user intent, safe retry/no-op behavior, ordering, no duplicate playlist/items, and fail-closed divergence/recovery on the signed candidate. | Separately authorized, bounded live-write plan identifying the account, test-owned playlist and tracks, allowed side effects, and cleanup. Compare before/after library and playlist read-back; record partial writes and recovery. Never infer writes from a read-only request or delete pre-existing user data. |
| G6: Privacy and packaging | Review the candidate's actual data access, retention, dependencies, licensing, privacy disclosures, and required-reason API/privacy-manifest obligations. Package only intended runtime components. | Data/dependency inventory and applicable declarations, privacy-policy/support links, artwork/icon/metadata review, and artifact-content inspection. No tracked privacy manifest or export configuration was found in this baseline; applicability must be established rather than inventing a file or assuming compliance. |
| G7: Distribution | Complete the selected route below and verify the exact uploaded/exported build is available to its authorized audience. | Apple processing/build/group read-back or notarization/hosted artifact read-back plus a fresh installation. Upload success alone does not prove processing, membership, installability, or public availability. |
| G8: Support and recovery | Record how to halt distribution, handle a defective build, preserve checkpoints/user data, and ship a corrected build. | Named release owner, feedback/crash-report location and observation window, retained prior artifact/evidence, and route-specific halt procedure. Binary rollback cannot undo Apple Music library or playlist writes. |

MusicKit is an App Service on the canonical App ID. Verify its current service
configuration separately from signing, consent, and successful requests. Do not
invent `com.apple.developer.musickit`, add speculative capabilities, or treat an
absent manual entitlement as a defect. Runtime authorization and network failures
need diagnosis at the failing layer.

The prototype in `Tools/AppleMusicAPI/` is historical operational tooling, not a
shipping dependency. Do not bundle private keys, developer-token material,
provisioning credentials, local caches, generated helper apps, or build output.
Future CI must isolate signing access from untrusted PR execution, avoid printing
credentials, and retain only redacted evidence. No new backend or credential
service is required by this document.

## TestFlight and App Store route

1. Confirm active program/account access, agreements, canonical App ID service
   configuration, matching App Store Connect app/platform records, and the roles
   needed for upload and release. Record identifiers and verification results;
   do not copy credentials into the repository or evidence.
2. Archive/export for App Store Connect with appropriate distribution signing
   and provisioning while retaining the repository's Automatic signing model.
   Verify exported identity/entitlements and Apple's current toolchain acceptance.
   Resolve version/build collisions explicitly.
3. Upload only after the scoped upload action is authorized. Read back the
   processed platform, bundle, version, build number, processing state, and
   encryption/export-compliance status. Supply accurate compliance information;
   do not guess answers to clear a processing gate.
4. Start with the selected internal tester group. Record the authorized group
   and build assignment, then confirm an eligible tester can install and launch
   that exact build. Select a beta feedback contact and test instructions.
   External testing may require beta review. Public links or a broader group
   require authorization for that audience; do not promote automatically.
5. Before App Store submission, complete applicable privacy/support URLs,
   privacy declarations, age rating, screenshots, availability, pricing, review
   notes, and access instructions. Disclose Apple Music access accurately and
   review Apple Music metadata/artwork use against Apple's guidelines. Do not
   invent playback, background, alarm, or local-import promises absent from the
   selected candidate.
6. Record review approval separately from owner-authorized release. Select a
   release mode that allows the authorized release decision, then read back
   store availability and verify an installation from that channel. For a bad
   beta, halt/expire its distribution as appropriate; for a store defect,
   stop further rollout where supported and ship a corrected, higher build.
   Do not assume a previously distributed version can be restored instantly.

Apple's [upload guide](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
distinguishes upload from processing. Its
[TestFlight guide](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
describes build/group assignment and beta review. Recheck both at release time.
The [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/),
especially sections 4.5.2 and 5.1, govern Apple Music and privacy disclosures.

## Direct notarized macOS route

This route applies only if selected. The observed `ENABLE_HARDENED_RUNTIME = NO`
means the present Release configuration is not ready for notarization; a focused
implementation and signed-runtime validation are required before distribution.

Require Developer ID Application signing, hardened runtime with only justified
exceptions, a valid timestamp, successful notarization, and ticket stapling where
supported. Choose `.dmg`, `.pkg`, or `.zip` deliberately; a ZIP itself cannot be
stapled, so staple its app before repackaging. Verify signature, notarization
result/log, stapled ticket, Gatekeeper acceptance, supported architectures, and
launch from a fresh downloaded/quarantined artifact on a supported Mac.

Select a versioned HTTPS host and update mechanism. Publish a checksum and release
notes alongside the exact authorized artifact; download it again and compare its
digest. Keep prior installers available under the chosen retention policy, stop
serving a defective build, and preserve user state when reinstalling or shipping
a fix. App Store Connect processing/group evidence does not satisfy this route.

See Apple's [Developer ID guidance](https://developer.apple.com/developer-id/),
[notarization requirements](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
and [packaging guidance](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

## Reusable validation and release record

The following inspection/check commands are supported from the repository root.
Use task-owned scratch directories. These commands do not archive or distribute:

```bash
git rev-parse HEAD
xcodebuild -version
xcodebuild -project Tunory.xcodeproj -scheme Tunory -configuration Debug -destination 'platform=macOS' -showBuildSettings
xcodebuild -project Tunory.xcodeproj -scheme Tunory -configuration Release -destination 'platform=macOS' -showBuildSettings
xcodebuild -project Tunory.xcodeproj -scheme Tunory -configuration Release -destination 'generic/platform=iOS' -showBuildSettings
swift test --package-path Packages/TunoryCore --scratch-path /tmp/tunory-release-core-validation
python3 -B -m unittest discover -s Tools/GitHub/tests -v
git diff --check
git diff --cached --check
git status --short
```

Before a PR merge, use the existing
[exact-commit CLI procedure](agent-review-cli.md). It requires an open PR; do not
run it after merge as proof of a closed PR or of a release binary. Release archive
and export commands/configuration must be reviewed for the selected route in the
next implementation slice; none exists here as a verified deployment procedure.

Each release record must contain:

- selected platform(s), minimum OS/architectures, route, audience, release owner,
  and the exact authorized action;
- source/head/base/merge SHAs, CI/review proof, Xcode/SDK, version/build, archive
  and export identifiers, artifact names/digests, and retention/access policy;
- G1–G8 statuses with proof links, actual failures, missing prerequisites, and
  explicit authorization/evidence for live library writes;
- Apple app/build/group identifiers and processing/compliance/membership states,
  or notarization submission and downloaded artifact verification;
- installation/runtime evidence, release approval/read-back, feedback/crash
  observation owner/window, and halt/recovery instructions.

## Next implementation slices and current proof

| Slice | Concrete next action | Acceptance before progressing |
| --- | --- | --- |
| Choose the release | macOS internal TestFlight is selected; finish compatibility, group, version/build and release-owner details in the release record. | A candidate-specific record with the remaining decisions filled in. |
| Prove a local archive | [Release archive and local-only distribution export passed](releases/macos-internal-testflight-2026-10-21.md), including final package/app signature and identity inspection. Finish the bounded runtime/write plan before progressing. | G2–G3 evidence recorded; G4–G5 require actual signed-runtime and separately authorized live-write proof. No upload is implied. |
| Prove signed runtime | Execute the approved platform smoke matrix and separately authorized test-owned writes. | G4–G6 pass with actual device/Mac and artifact identity. |
| Add distribution automation | Implement one selected route with isolated signing, retained artifacts, explicit promotion, and failure handling. | Exercise its success/failure paths and G7–G8 with the exact authorized build/audience. |

The original requirements slice reached repository/configuration inspection and
documentation review. Subsequent [macOS internal TestFlight preparation](releases/macos-internal-testflight-2026-10-21.md)
produced and inspected a development-signed Release archive (`PASS`). Its first
local export failed for a missing provisioning profile (`FAIL`); a provisioning
retry and owner-completed signing prompt produced a verified Apple Distribution
app and signed installer package (`PASS`). Local export preparation is complete.
Signed runtime/device tests, live music writes,
independent Apple account/app-record inspection, upload, notarization, and
distribution remain `NOT ATTEMPTED`. Overall release acceptance is still `BLOCKED`
on candidate-specific G4–G8 evidence and remaining release decisions. Package CI
and historical macOS proof do not close those gates.
