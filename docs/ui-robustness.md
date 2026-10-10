# Tunory UI robustness

## Goal and scope

Make the existing Status → Import and Review → Configure → Run → Results workflow, and the independent Recovery workflow, as dependable and accessible as the native patterns used in Gymphant and Owlory. Preserve Apple Music identity, append-only transaction semantics, fresh-read verification, file security scope, checkpoint integrity, and the CLI interface. No new music features, signing changes, third-party frameworks, or blanket state-model migrations are required.

## Evidence before implementation

The baseline macOS build and running interface were inspected. Source and accessibility inspection identified desktop-only minimum widths on all screens, an unlabeled paste editor, truncated candidate identities, immediate recovery dismissal, and missing model-level guards against overlapping or stale resolution work. The current authorization model exposes connectivity as a free-form string and does not guard its own request entry points. Existing transaction and recovery models retain canonical core write decisions.

The local, pre-existing DESIGN.md provides Tunory's state-first product direction. Current Gymphant and Owlory design guides inform semantic shared tokens, native navigation, accessible controls, explicit non-happy states, and honest visual-proof boundaries. Their domain-specific colors, product rules, and source implementations are not copied.

## Plan and acceptance rubric

1. **Native navigation and adaptive layout:** Status, Import, and Recovery remain distinct destinations, with a native navigation title and consistent reading width. No desktop minimum width is applied to iPhone screens. Long evidence, candidate names, and errors wrap. Prove through macOS and owned-iPhone-simulator rendering, including accessibility text sizes.
2. **State and action clarity:** every existing empty, loading, permission, parse, review, transaction, result, and recovery state explains what happened and the safe next action. Read-only catalog checks and review must not imply write verification. Progress must describe actual evidence rather than invented percentages. Prove through model tests and rendered state review.
3. **Explicit writes and protected progress:** configuration summarizes the exact recording count, target playlist, creation policy, and append-only behavior before confirmation. Recovery dismissal requires a native confirmation and affects saved progress only. A second import cannot run alongside transaction/recovery work. Prove with deterministic guards and UI review; live library writes are not authorized by this UI task.
4. **Async correctness:** authorization and connectivity requests cannot overlap; superseded resolution/confirmation results cannot overwrite new input or reset state. Input changes clear old resolution evidence. Transaction phase callbacks cannot contaminate a newer run, and persisted-write failures are visible. Prove with suspended fake services, re-entry tests, and existing core regressions.
5. **Accessibility and platform semantics:** meaningful labels and stable identifiers, native buttons and roles, keyboard access, semantic text and colors, non-color status, and adaptive action layouts. Prove through the runtime accessibility tree, keyboard traversal, light/dark rendering, and large text. Source inspection alone does not prove VoiceOver audibility or physical-device behavior.
6. **Validation and handoff:** affected app-model tests, TunoryCore regressions, macOS and iOS builds, diff/hygiene checks, and a requirement-by-requirement evidence record. Preserve hashes of pre-existing .swarm/ and DESIGN.md files. Publish reviewable logical commits and a draft PR; classify the final repository state honestly.

## Plan QA

The installed Xcode 27 SDK supports the current iPhone/macOS deployment targets and main-actor default isolation. Existing ObservableObject integrations will remain. The GUI continues to delegate mutation and reconciliation decisions to TunoryCore. UI verification uses test-owned data and explicit read-only actions; builds, previews, fixtures, and simulator results will not be described as live playlist-write or physical-iPhone proof.

## QA evaluation loop

For each iteration record the violated criterion, concrete evidence, severity, root cause, correction, and rerun result. Reassess the entire affected flow after fixes. Remaining evidence must be reported as PASS, FAIL, NOT ATTEMPTED, or BLOCKED rather than inferred from a build or a model's review.

## Implementation and preserved contracts

The existing workflow now uses native tabs and navigation, a shared adaptive reading surface, labeled input, complete recording metadata, and explicit write/dismissal confirmations. Status puts authorization and catalog connectivity before the introductory disclosure. Import models cancel and reject superseded work; transaction and recovery models guard running state and retain canonical phase evidence. Storage failures are visible. Per-recording acceptance badges require successful HTTP acknowledgments, and incomplete final reads cannot index beyond stored tracks.

Identity, signing, MusicKit configuration, exact catalog IDs, deterministic matching, append-only transaction decisions, independent final readback, file-picker security scope, and CLI behavior remain governed by their original contracts. The only core change adds reportable checkpoint deletion while retaining the existing best-effort API. No third-party dependencies were added.

### Deterministic runtime validation

Debug builds accept an explicit `--ui-validation <scenario>` argument and visibly label sample data. The scenarios `normal`, `denied`, `restricted`, `catalog-failure`, `recovery`, `corrupt-recovery`, `diverged-recovery`, `stopped-write`, and `failed-readback` inject in-memory services without network capability and test-owned checkpoint storage. Ordinary Debug launches continue to use live services; Release excludes this adapter. Fixture success proves presentation and orchestration against canonical DTOs, not real Apple Music writes.

The shared Tunory scheme now includes hosted app-model tests and native UI tests. Run tests with the Debug configuration. On iPhone, use an explicitly owned simulator UUID; on macOS, the UI runner needs an available authenticated desktop session. Keep builds serialized per DerivedData directory.

```bash
swift test --package-path Packages/TunoryCore --scratch-path /tmp/TunoryCoreUIValidation
xcodebuild -project Tunory.xcodeproj -scheme Tunory -destination 'platform=macOS' \
  -derivedDataPath /tmp/TunoryUIRobustness -only-testing:TunoryTests test
xcodebuild -project Tunory.xcodeproj -scheme Tunory \
  -destination 'platform=iOS Simulator,id=<owned-simulator-UUID>' \
  -derivedDataPath /tmp/TunoryUIRobustnessSimulator -parallel-testing-enabled NO \
  -collect-test-diagnostics never -only-testing:TunoryUITests test
```

### Findings and corrections

| Finding | Criterion / severity | Evidence and correction |
| --- | --- | --- |
| Desktop minimum widths clipped iPhone navigation | 1 / high | Baseline simulator screenshot; minimum dimensions now apply only to macOS. |
| Duplicate, canceled, or reset resolution could publish stale review state | 4 / high | Six failing model regressions before the fix; generation checks and cancellation reject old work. |
| Checkpoint deletion failure could be reported as success | 3, 4 / high | Test-owned read-only storage reproduced failure; reportable deletion now retains state and exposes the error. |
| Failed HTTP acknowledgments appeared as accepted mutations | 2 / high | Transaction and Recovery regressions failed before correction; badges now require successful outcomes, with per-recording errors. |
| Scrolling tests targeted the nested editor and assumed a visible native cancel row | 5 / test defect | Runtime screenshots and accessibility trees showed the actual layout and popover dismissal region; tests now use outer-scroll drags, keyboard dismissal, and native cancel affordances. |
| A row identifier hid recording-button identifiers | 5 / medium | The buttons rendered but could not be found by identifier; an explicit accessibility container preserves their separate controls. |
| Large-text assertion matched multiple Label children | 5 / test defect | XCTest reported multiple matching elements; the assertion now measures the identified text child and exercises the full fixture flow. |
| Xcode failure-diagnostic collection stalled after tests finished | 6 / environment | The combined iPhone log records completed cases but the collector did not finalize; it was stopped and native tests rerun with verbose diagnostic collection disabled. |
| A test labeled dark appearance still rendered light | 5 / test defect | Screenshot inspection rejected the label as proof; Debug validation now accepts `--ui-dark` and applies an explicit scene color scheme, without changing normal app preferences. |
| Initial and unchanged authorization assignments published during view updates | 4 / medium | Native XCTest logged a SwiftUI publication warning; models now initialize their Published backing storage and publish refreshes only when values change. Targeted runtime checks no longer emit that warning. |
| Engine factory closure lacked an explicit actor contract | 4 / medium | The installed compiler reported an actor-isolation diagnostic; the UI-owned factory is now explicitly MainActor, preserving the existing service boundary. |
| Verification UI exposed debug descriptions of Boolean and array values | 2, 5 / medium | Release compilation flagged unsupported localized interpolation. Results now describe ordering, duplicate recording IDs, unexpected IDs, and unidentifiable tracks in user-facing terms. A duplicate-final-read fixture exercises this failure state. |
| Overlapping simulator runs disrupted test bootstrap | 6 / execution defect | A focused test was started before the previous native suite finished; one app launch and the focused runner failed. Those runs are not final acceptance. The complete final suite runs serially against the owned simulator. |

### Desktop verification prerequisite

Native macOS tests were attempted twice and executed zero cases. Both runners reported:

```text
Failed to initialize for UI testing:
Error Domain=com.apple.LocalAuthentication Code=-4 "System authentication is running."
Authentication canceled.
```

The command was the macOS `xcodebuild ... -only-testing:TunoryUITests/WorkflowUITests/testReviewAndNativeWriteConfirmationCanBeCanceled test` invocation using `/tmp/TunoryUIRobustness`. Logs are `/tmp/tunory-ui-native-macos-tests.log` and `/tmp/tunory-ui-native-macos-tests-retry.log`. Native computer-use inspection also returned `cgWindowNotFound` for the current task-owned build. Complete or dismiss the pending host authentication, then rerun desktop workflow, keyboard, and appearance checks. Builds and hosted model tests cannot close this prerequisite.

## Acceptance evidence: 2026-10-10

Xcode 27.0; owned iPhone 18 Pro / iOS 27 simulator `0C347D23-B637-4DF6-B753-779CE0DDD930`. The final iPhone invocation used the shared Debug scheme, this destination, `/tmp/TunoryUIRobustnessSimulator`, `-parallel-testing-enabled NO`, `-collect-test-diagnostics never`, and `test`. It exited successfully with all 41 cases passing: 29 model tests and 12 native UI tests. The final run was serialized and no source changed during it.

| Check | State | Evidence / practical limit |
| --- | --- | --- |
| Core regressions | PASS | 156 tests; `/tmp/tunory-core-ui-tests-final.log`. Includes actual checkpoint-deletion failure on test-owned storage. |
| Hosted app models, macOS | PASS | 29 tests; `/tmp/tunory-ui-ship-macos-models.log`. Async supersession, cancellation, re-entry, denied writes, persistence failure, and evidence derivation. |
| Hosted app models, iPhone simulator | PASS | 29 tests in `/tmp/tunory-ui-final-suite.log`. |
| iPhone native workflow | PASS | 12 UI tests in the same final suite. Full fixture import, explicit write cancellation, catalog retry, failed writes, failed final readback, denied/restricted access, recovery success/divergence, and checkpoint-dismissal cancellation. |
| iPhone navigation, accessibility text, keyboard | PASS | All three native tabs are hittable; identified editor supports entry and Done dismissal; Accessibility XXXL text is measured larger and the full review/configuration/result flow remains usable. |
| iPhone light and dark appearance | PASS | Native screenshots inspected; dark mode uses the explicit Debug fixture override after the initial mislabeled capture was rejected. Recording metadata wraps and results distinguish accepted writes from final verification. |
| macOS Debug and Release build | PASS | Hosted Debug suite builds the current app; Release build log `/tmp/tunory-ui-ship-release.log`. Touched-source actor and interpolation diagnostics resolved. |
| Built identity and fixture exclusion | PASS | Debug macOS, Release macOS, and simulator Info.plist report `com.raelldottin.tunory` / `Tunory`. Release binary contains neither validation switch. |
| Protected files and Git hygiene | PASS | All 62 baseline `.swarm/` / `DESIGN.md` file hashes match; whitespace, project plist, scheme XML, and tracked-generated-artifact checks pass. Task-owned ByteRover initialization removed. |
| macOS native workflow, keyboard, appearance | BLOCKED | LocalAuthentication prevents runner initialization; zero cases executed. Earlier baseline desktop inspection does not prove the changed interface. |
| Physical iPhone, VoiceOver audibility, live Apple Music writes | NOT ATTEMPTED | Outside this fixture validation. No real user-library write was performed or claimed. |

Local native attachments are retained in `/tmp/tunory-ui-accepted-artifacts/manifest.json`, with earlier diagnostic captures in `/tmp/tunory-ui-native-artifacts-initial/` and actual dark-mode captures in `/tmp/tunory-ui-appearance-artifacts/`. They are not committed build products; regenerate them with the documented fixture/test commands and `xcresulttool export attachments`.

A remaining SwiftUI diagnostic, `Invalid frame dimension (negative or non-finite)`, appears while opening the text editor. Changing the keyboard toolbar grouping did not eliminate it, so that speculative change was reverted. The exercised editor, keyboard-dismissal control, and subsequent navigation pass, but the warning's origin is not proven and remains an investigation item. Fixture/build success does not waive the blocked desktop acceptance. Publish this slice as a draft and keep the UI robustness goal incomplete until the required desktop checks can run.
