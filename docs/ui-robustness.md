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

### Historical desktop verification prerequisite

Native macOS tests were attempted twice and executed zero cases. Both runners reported:

```text
Failed to initialize for UI testing:
Error Domain=com.apple.LocalAuthentication Code=-4 "System authentication is running."
Authentication canceled.
```

The command was the macOS `xcodebuild ... -only-testing:TunoryUITests/WorkflowUITests/testReviewAndNativeWriteConfirmationCanBeCanceled test` invocation using `/tmp/TunoryUIRobustness`. Logs are `/tmp/tunory-ui-native-macos-tests.log` and `/tmp/tunory-ui-native-macos-tests-retry.log`. Native computer-use inspection also returned `cgWindowNotFound` for the current task-owned build. These failures prevented desktop acceptance at initial publication. The resumed native XCTest evidence below supersedes that blocker; the failed runs remain historical evidence.

## Initial published acceptance evidence: 2026-10-10

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

At initial publication, `Invalid frame dimension (negative or non-finite)` appeared while opening the editor. Changing keyboard-toolbar grouping did not eliminate it, and that speculative change was reverted. The exercised controls passed, but the warning's origin was unproven and desktop acceptance remained blocked. The follow-up investigation and acceptance below supersede these open items.

## Resumed QA: keyboard toolbar and desktop acceptance

Temporary Debug probes isolated the frame warning: fixed-frame, flexible-frame/FocusState, scroll-view, and navigation-stack editor cases passed without it; adding the native keyboard toolbar reproduced it. All five probe cases passed. Logs: `/tmp/tunory-ui-editor-probe.log` and `/tmp/tunory-ui-editor-isolation.log`. The probes were removed after diagnosis.

Done now uses the native iPhone navigation toolbar and clears the same editor focus state. The first correction exposed a separate validation-fixture defect: its top safe-area banner covered navigation controls, so a reported tap did not dismiss the keyboard. The banner now occupies its own row above the tab container. Native tests require Done to be present and hittable, then require the keyboard to disappear. Focused normal and Accessibility XXXL screenshots confirm dismissal and continued parsing/review; those logs contain no frame warning. Failed iterations are retained in `/tmp/tunory-ui-navigation-done-qa.log`, `-v2-qa.log`, and `-v3-qa.log`; the targeted XXXL correction passes in `/tmp/tunory-ui-navigation-done-v4-qa.log`.

The iPhone scroll helper now checks visible control bounds and can scroll back toward controls it overshot. A control taller than the viewport may be used when its center is visible. This preserves the full workflow assertions rather than bypassing the controls under test.

After resume, macOS XCTest initialized and exposed two test expectations that were specific to iPhone: the native desktop sheet has the accessibility label `alert`, and an unscoped Cancel query selected a Touch Bar button. Tests now verify the sheet's actual title and scope actions to its visible buttons. The failed desktop runs are `/tmp/tunory-ui-desktop-resume.log` and `-v2.log`; the corrected cancellation flow passes in `-v3.log`.

The Debug fixture supports explicit `--ui-light` and `--ui-dark` appearance overrides. Neither changes ordinary launches or system appearance. Desktop captures now use the task-owned app window, avoiding unrelated desktop content. Native light/dark Status, recording review, configuration, and recovery captures were inspected, along with workflow confirmation and result captures. Keyboard proof includes editor entry, Command-A replacement, and Escape cancellation of the write confirmation; it does not claim VoiceOver audibility or exhaustive keyboard navigation.

| Follow-up check | State | Evidence / practical limit |
| --- | --- | --- |
| macOS native workflow, keyboard, light/dark appearance | PASS | 13 tests, zero failures; `/tmp/tunory-ui-desktop-final-suite.log`. Result: `/tmp/TunoryUIRobustness/Logs/Test/Test-Tunory-2026.10.10_08-10-55--0400.xcresult`. Window captures: `/tmp/tunory-ui-desktop-final-artifacts/manifest.json`. |
| iPhone native workflow and light/dark appearance | PASS | 12 tests, zero failures, in `/tmp/tunory-ui-navigation-done-final-suite.log`, followed by the newly added explicit light test in `/tmp/tunory-ui-iphone-light-qa.log`. Results: `/tmp/TunoryUIRobustnessSimulator/Logs/Test/Test-Tunory-2026.10.10_08-09-02--0400.xcresult` and `Test-Tunory-2026.10.10_08-15-23--0400.xcresult`. Captures: `/tmp/tunory-ui-navigation-done-final-artifacts/manifest.json` and `/tmp/tunory-ui-iphone-light-artifacts/manifest.json`. No frame warning occurs in either log. |
| iPhone Accessibility XXXL and explicit Done dismissal | PASS | Full review/configuration/import/results flow in `/tmp/tunory-ui-navigation-done-v4-qa.log`; focused/dismissed keyboard captures in `/tmp/tunory-navigation-done-v4-artifacts/manifest.json`. |
| macOS Release build | PASS | `/tmp/tunory-ui-navigation-done-release-final.log`. |
| Identity, fixture exclusion, protected files, structural checks | PASS | Built Debug macOS, Release macOS, and iPhone products retain `com.raelldottin.tunory` / `Tunory`. Release contains none of `--ui-validation`, `--ui-dark`, or `--ui-light`. All 62 protected hashes match; whitespace, project plist, scheme XML, and generated-artifact checks pass. |
| Physical iPhone, VoiceOver audibility, live Apple Music writes | NOT ATTEMPTED | Fixture acceptance uses in-memory services and test-owned storage. No real library writes were performed. |

The full native follow-up commands use the documented destinations and DerivedData directories with `-parallel-testing-enabled NO -collect-test-diagnostics never -only-testing:TunoryUITests test`. The final iPhone light check substitutes `-only-testing:TunoryUITests/WorkflowUITests/testLightAppearanceReviewAndRecoveryRemainNavigable`. Tests are serialized within each destination and DerivedData directory. No service-model or core transaction implementation changed during this follow-up; the initial 156 core and 29 hosted model test results remain applicable to those unchanged contracts.

The desktop and editor-warning acceptance items are closed at the native fixture level. Physical-device, spoken accessibility, and live-service proof remain separate. The draft PR contains only task-owned changes. An unexplained Xcode project-file edit appeared after the checkpoint and is preserved outside the follow-up commit; `.swarm/` and `DESIGN.md` also remain protected. This prevents a fully clean or protected-dirty stop classification until ownership of that project edit is established.
