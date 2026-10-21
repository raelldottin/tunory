# macOS internal TestFlight: local archive evidence

This record describes source `64c8d95` before the owner-selected
[app icon](../app-icon.md) was integrated. Retain this evidence as historical;
rebuild and verify a candidate containing the new icon before uploading it.

## Decision, scope, and acceptance plan

On 2026-10-21 the owner selected **macOS internal TestFlight** as Tunory's first
deployment target. External TestFlight, public links, App Store release, direct
Developer ID distribution, and iPhone/iPad deployment are not selected by that
decision. The internal tester group and an upload/build assignment are not yet
specified or performed.

This slice prepares a local Release archive from protected `main` at
`64c8d95e9ed6e7c653a15d7f7267745e965bacab` and attempts a local-only App Store
Connect export. The source checkout was clean for the archive. No product code,
project settings, signing model, dependencies, or library-write behavior changed.
After an initial missing-profile failure, Xcode provisioning updates were enabled
for a local-export retry; no manual App Services changes were made. Stacked PRs
#1–#5 are not part of the candidate.

The plan's acceptance criteria are: preserve canonical app identity and Automatic
signing; archive with the installed toolchain; inspect the actual binary,
Info.plist, signature and generated entitlements; first attempt export without
upload or provisioning updates; and retain the exact result rather than presenting a
development-signed archive as a TestFlight-ready build. QA of the plan identified
distribution signing/profile availability and actual Apple processing as
independent prerequisites. After confirming the missing profile, the plan was
revised to allow Xcode to repair provisioning for the same team and bundle while
keeping `destination = export`. App/runtime, permission and live-write checks
remain separate from archive inspection.

## Results

| Check | Status | Evidence |
| --- | --- | --- |
| Candidate CI | PASS | [Core CI run 39624115471](https://github.com/raelldottin/tunory/actions/runs/39624115471), source `64c8d95e9ed6e7c653a15d7f7267745e965bacab`: 155 Swift tests and 29 Python tests, zero failures. |
| Local environment | PASS | macOS `27.0.1`; Xcode `27.1` build `27A9275`; macOS SDK `27.0`. Debug and Release use Swift `5.0`, default actor isolation `MainActor`, Automatic signing and team `DHJQ7QC53Z`. |
| Release archive | PASS | Command below exited `0`, with `** ARCHIVE SUCCEEDED **`. The shared scheme's Release archive action was used without `-allowProvisioningUpdates` or signing overrides. |
| Built identity | PASS | `CFBundleIdentifier = com.raelldottin.tunory`; `CFBundleDisplayName = Tunory`; version/build `1.0 (1)`; `LSMinimumSystemVersion = 27.0`. Availability of this version/build in App Store Connect was not checked. |
| Actual architecture | PASS | `lipo -archs` reports **arm64 only** for `Contents/MacOS/Tunory`. This artifact does not establish Intel support. No OS/architecture settings were changed to broaden compatibility. |
| Local signature | PASS | `codesign --verify --deep --strict --verbose=2` exited `0`; the app is signed by **Apple Development**, team `DHJQ7QC53Z`. This is development-signature integrity proof, not App Store distribution-signing proof. |
| Generated entitlements | PASS | Sandbox, outbound network access and user-selected read-only file access are true; disable-library-validation is false. No manually invented MusicKit entitlement was added. No embedded provisioning profile is present. |
| First local App Store Connect export | FAIL | Without provisioning updates, `xcodebuild -exportArchive` exited `70`: no matching Mac App Store provisioning profile was available. Exact diagnostic below. |
| Provisioning retry and app distribution signature | PASS | With `-allowProvisioningUpdates`, Xcode obtained a matching embedded profile and re-signed the app with **Apple Distribution**, team `DHJQ7QC53Z`. Strict verification of the app extracted from the final package exited `0`; its application identifier is `DHJQ7QC53Z.com.raelldottin.tunory`. |
| Installer package/local export | PASS | After the owner completed the local signing prompt, the retry exited `0` with `** EXPORT SUCCEEDED **`. `pkgutil --check-signature` exited `0` for the `Tunory.pkg` installer, signed by the team's 3rd Party Mac Developer Installer certificate. |
| Packaged contents and profile | PASS | Static extraction found one `Tunory.app`, canonical bundle/display name and team, version `1.0 (1)`, minimum macOS `27.0`, arm64 only. Its embedded profile targets `OSX`, team `DHJQ7QC53Z`, expires `2027-03-07 23:31:20 UTC`, has no provisioned-device list and does not provision all devices. |
| Export destination and audience restriction | PASS | Xcode's output `ExportOptions.plist` reports `method = app-store-connect`, `destination = export`, `testFlightInternalTestingOnly = true`, and version/build management disabled. Actual Apple processing and internal-group eligibility remain unverified until upload. |
| Signed runtime, UI and live MusicKit checks | NOT ATTEMPTED | No application launch, authorization prompt, real-library read or write was performed in this slice. Historical runtime proof does not certify this archive. |
| Manual Apple account/App ID/App Store Connect record inspection | NOT ATTEMPTED | Xcode accessed the team for provisioning, but service configuration, app/platform records, version/build availability, agreements, roles and tester groups were not independently verified. |
| Upload, processing and tester assignment | NOT ATTEMPTED | No upload, Apple processing, build/group assignment, internal tester installation, external distribution, or public release occurred. |

The archive emitted existing actor-isolation warnings in `MusicKitSources.swift`,
an unused-value warning in `ProgressView.swift`, and localized-interpolation
deprecation warnings in `ResultsView.swift`. The App Intents metadata tool also
reported that extraction was skipped without an AppIntents dependency. These did
not fail this Swift 5 archive. They were retained in the log; no language mode,
warning threshold or source behavior was changed to clear a gate.

## Commands and failure

Run from the clean candidate checkout. Paths below belong to this evidence run;
use fresh, task-owned output paths for another candidate.

```bash
xcodebuild -project Tunory.xcodeproj -scheme Tunory -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath /tmp/tunory-macos-testflight-evidence-64c8d95/Tunory.xcarchive \
  -derivedDataPath /tmp/tunory-macos-testflight-evidence-64c8d95/DerivedData \
  -resultBundlePath /tmp/tunory-macos-testflight-evidence-64c8d95/archive.xcresult \
  archive

xcodebuild -exportArchive \
  -archivePath /tmp/tunory-macos-testflight-evidence-64c8d95/Tunory.xcarchive \
  -exportPath /tmp/tunory-macos-testflight-evidence-64c8d95/export \
  -exportOptionsPlist Tools/Release/macos-internal-testflight-export.plist
```

The export used the identical settings before they were added to the repository.
The checked-in plist specifies `method = app-store-connect`, `destination = export`,
`signingStyle = automatic`, team `DHJQ7QC53Z`,
`testFlightInternalTestingOnly = true`, and
`manageAppVersionAndBuildNumber = false`. The installed `xcodebuild -help`
documents those options: `export` is local; the internal-only flag excludes
external TestFlight and App Store distribution. It does not assign a tester group
or grant upload permission.

Actual export diagnostic, exit `70`:

```text
error: exportArchive No profiles for 'com.raelldottin.tunory' were found

Xcode couldn't find any Mac App Store provisioning profiles matching
'com.raelldottin.tunory'. Automatic signing is disabled and unable to generate
a profile. To enable automatic signing, pass -allowProvisioningUpdates to xcodebuild.

** EXPORT FAILED **
```

The first exporter could not generate a missing profile because provisioning
updates were not enabled for that operation. The project's
`CODE_SIGN_STYLE = Automatic` was preserved. The focused retry used the same
archive and plist, a fresh output directory, and `-allowProvisioningUpdates`:

```bash
xcodebuild -exportArchive \
  -archivePath /tmp/tunory-macos-testflight-evidence-64c8d95/Tunory.xcarchive \
  -exportPath /tmp/tunory-macos-testflight-evidence-64c8d95/export-with-provisioning \
  -exportOptionsPlist Tools/Release/macos-internal-testflight-export.plist \
  -allowProvisioningUpdates
```

Xcode progressed past app re-signing, and the staged app's generated entitlements
contained the canonical application/team identifiers, sandbox, network-client
and user-selected read-only access; disable-library-validation remained false.
An embedded distribution profile was present. Package creation then paused at
installer signing with `write: Permission denied`. The computer-use tool
explicitly refused access to `com.apple.SecurityAgent` for safety reasons; no
alternate inspection or bypass of that system authorization was attempted. The
owner completed the local signing prompt and reported “Prompt completed.” The
existing command then exited `0` and produced `Tunory.pkg`, with
`** EXPORT SUCCEEDED **`. No project signing changes, privilege bypass, password
handling by the agent, or upload was needed.

Static verification used:

```bash
pkgutil --check-signature /tmp/tunory-macos-testflight-evidence-64c8d95/export-with-provisioning/Tunory.pkg
pkgutil --expand-full /tmp/tunory-macos-testflight-evidence-64c8d95/export-with-provisioning/Tunory.pkg /tmp/tunory-macos-testflight-evidence-64c8d95/expanded-package
```

The extracted app was inspected with `lipo -archs`, Info.plist reads and
`codesign --verify --deep --strict`; its signature, generated entitlements and
embedded profile were also inspected. No package installation or app launch was
performed. A successful local export is not proof of App Store Connect acceptance
or a TestFlight tester installation.

## Retained local artifacts

The successful archive was copied to Xcode's local archive directory:

```text
~/Library/Developer/Xcode/Archives/2026-10-21/Tunory-64c8d95.xcarchive
```

The archive ZIP, build/export logs, result bundle, tested export options and final
export package/metadata are
retained outside the repository at:

```text
~/Library/Developer/Xcode/TunoryReleaseEvidence/2026-10-21-64c8d95/
```

| File | SHA-256 |
| --- | --- |
| `Tunory.xcarchive.zip` | `3fdfeedea69a4120aec582ec92be01d447512cb63b4ed717f94a1ac88a03257b` |
| `archive.log` | `98da15d784ac769b1443fb4f956d4bb34822675f74d7cc8cfa6ce051ce4644e3` |
| `export.log` | `9628f65594b00de0ce573bf7d8b2199b0b9018ede087891316b99890f4a99b9c` |
| `export-with-provisioning.log` | `07072984255610cb2222c1457876daf2092df06634f8d2db919c80df6aec382d` |
| `export/Tunory.pkg` | `c521344d3a2f0b23d50b511acda62035edef8d3629e70a11291ea40a14c0348d` |

Archived executable SHA-256:
`d267ede2455c058b9d2df4654c84775a19b9216a6837ee58e4fd53a28fe5f068`.
These local artifacts were not committed or uploaded. Retain them until a
replacement candidate is verified or the owner chooses an evidence-retention
policy. The ZIP is a preserved development archive; `export/Tunory.pkg` is the
separately verified App Store Connect export for internal TestFlight. Neither
artifact has been uploaded or proven installable through TestFlight.

## Next bounded actions

1. Preserve the verified archive and local export. Provisioning and installer
   signing succeeded; neither initial failure remains a current blocker. Future
   exports may require the owner to complete local signing authorization again.
2. Finish the intended macOS/CPU compatibility, version/build and release-owner
   decisions in the [deployment requirements](../deployment-requirements.md).
   This local artifact only proves arm64/macOS 27.0 support at build/signature
   inspection level, not runtime compatibility.
3. Before uploading, verify the App Store Connect macOS record, available
   version/build, required roles/agreements and export compliance. Identify the
   exact internal tester group, release owner and intended upload/assignment.
4. Complete the signed-runtime and separately authorized live-write acceptance
   plan. Only then proceed through an explicitly scoped upload, processing,
   group-membership read-back and actual internal-tester installation.

Apple's [App Store Connect release notes](https://developer.apple.com/help/app-store-connect/release-notes/)
list Xcode 27.1/macOS SDK 27.0 TestFlight upload support at inspection time.
The [upload guide](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)
still requires successful processing; neither toolchain support nor a local
archive proves that Apple has accepted this candidate.
