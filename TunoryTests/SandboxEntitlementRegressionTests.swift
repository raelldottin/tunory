import XCTest
import Security

// GAP D (phase 11, t_7711fdbf): EFFECTIVE built-product entitlement
// regression. The Xcode setting ENABLE_USER_SELECTED_FILES = readwrite
// is only a source claim; the product contract is what the kernel
// enforces on the signed binary. This suite closes that distance.
//
// TunoryTests runs HOSTED inside the signed app (TEST_HOST /
// BUNDLE_LOADER), so this code executes in the real sandboxed process:
// SecTaskCreateFromSelf reads the effective, kernel-enforced
// entitlements of the BUILT product, not the project file. A silent
// revert of the pbxproj setting (or a broken signing step that drops
// the entitlement) fails here at test time, before any signed-GUI
// drive could regress into the readonly world where destination
// writes fail with sandbox denials.
//
// What this proves (Req 4-R):
//   1. the app-sandbox is ON (the feature must never ship unsandboxed);
//   2. user-selected read-write is the EFFECTIVE grant;
//   3. the readonly grant is ABSENT (read-write alone does not imply
//      readwrite behavior if the stale readonly key lingers);
//   4. no broad filesystem entitlements (least privilege).
//
// What this does NOT prove (Req 4-O — see the Phase 11 report):
//   the live signed-GUI powerbox drive (destination pick → convert →
//   bytes on disk). That needs a real NSOpenPanel grant and remains
//   an operator-gated live proof.

final class SandboxEntitlementRegressionTests: XCTestCase {

    /// Effective entitlements of THIS process, as the kernel sees them.
    private func effectiveEntitlement(forKey key: String) -> (present: Bool, value: CFTypeRef?) {
        guard let task = try? SecTaskCreateFromSelf(nil) else {
            XCTFail("SecTaskCreateFromSelf failed — cannot read effective entitlements")
            return (false, nil)
        }
        let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
        return (value != nil, value)
    }

    private func assertEntitlement(_ key: String,
                                   equalsBool expected: Bool,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        let (present, raw) = effectiveEntitlement(forKey: key)
        guard present, let raw else {
            XCTFail("Effective entitlement '\(key)' is absent on the signed test host — the built product does not carry it",
                    file: file, line: line)
            return
        }
        guard let boolValue = raw as? Bool else {
            XCTFail("Effective entitlement '\(key)' is not a boolean (got \(CFGetTypeID(raw)))",
                    file: file, line: line)
                    return
        }
        XCTAssertEqual(boolValue, expected,
                       "'\(key)' effective value is \(boolValue), expected \(expected)",
                       file: file, line: line)
    }

    private func assertEntitlementAbsent(_ key: String,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) {
        let (present, _) = effectiveEntitlement(forKey: key)
        XCTAssertFalse(present, "Effective entitlement '\(key)' must be absent (least privilege), but it is present",
                       file: file, line: line)
    }

    // MARK: - The GAP D contract

    func testSandboxIsOn() {
        // The read-write destination-write feature is only acceptable
        // inside the sandbox. This also pins the feature against an
        // accidental "fix" that disables App Sandbox entirely.
        assertEntitlement("com.apple.security.app-sandbox", equalsBool: true)
    }

    func testUserSelectedReadWriteIsEffective() {
        // The GAP D core: user-selected files grant must be read-write
        // so the signed app can write converted output into the
        // user-chosen destination directory.
        assertEntitlement("com.apple.security.files.user-selected.read-write", equalsBool: true)
    }

    func testUserSelectedReadOnlyIsAbsent() {
        // If the stale readonly key ever returns (e.g. a bad merge or
        // Xcode regenerating entitlements), the powerbox grants stay
        // read-only and destination writes silently regress. Fail
        // early here instead.
        assertEntitlementAbsent("com.apple.security.files.user-selected.read-only")
    }

    // MARK: - Least privilege (test-host aware)

    /// True when THIS process carries Xcode's test-runner re-signing.
    /// `xcodebuild test` re-signs the hosted app with test-manager
    /// entitlements (mach-lookups for com.apple.testmanagerd and an
    /// absolute-path read-only "/" exception for symbolication). Those
    /// are the harness, not the product: a plain `xcodebuild build`
    /// signs the same binary WITHOUT them (verified by `codesign -d
    /// --entitlements` on both products — see the Phase 11 report).
    /// The broad-read-only assertion is therefore scoped to non-test
    /// contexts; the write-capable escape hatches must be absent in
    /// EVERY context, because the harness does not inject those.
    private var isXcodeTestHost: Bool {
        guard let task = try? SecTaskCreateFromSelf(nil) else { return false }
        guard let raw = SecTaskCopyValueForEntitlement(
            task, "com.apple.security.temporary-exception.mach-lookup.global-name" as CFString, nil)
            as? [String] else { return false }
        return raw.contains("com.apple.testmanagerd")
    }

    func testNoBroadFilesystemEntitlements() {
        // Least privilege: the fix must not reach for the escape hatches.
        // com.apple.security.files.all is the true broad-grant key.
        assertEntitlementAbsent("com.apple.security.files.all")
        // A broad absolute-path WRITE exception would defeat the point
        // of powerbox-scoped grants; absent in every signing context.
        assertEntitlementAbsent("com.apple.security.temporary-exception.files.absolute-path.read-write")
        // A broad absolute-path READ exception is injected by the
        // Xcode test harness when running hosted tests; the shipped
        // product must not carry it (codesign-verified separately).
        if isXcodeTestHost {
            print("test host detected (testmanagerd mach-lookup present): " +
                  "skipping absolute-path read-only assertion here — Xcode injects it for the test runner")
        } else {
            assertEntitlementAbsent("com.apple.security.temporary-exception.files.absolute-path.read-only")
        }
    }
}
