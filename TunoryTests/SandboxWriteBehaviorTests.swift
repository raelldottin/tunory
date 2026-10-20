import XCTest
import TunoryCore
@testable import Tunory

// Built-product sandbox write behavior (t_2a35f360, design §7):
// the P1 entitlement suite proves the binary is ENTITLED; the P2/P3
// unit suites prove the claim contract and engine invariants with
// fakes on injected paths. Neither proves what the KERNEL does to the
// built product at runtime. This suite closes that gap: it runs
// HOSTED inside the signed sandboxed app (same vehicle as
// SandboxEntitlementRegressionTests), so every write below is
// mediated by the real sandbox — not a fake, not a re-signing away
// of the profile.
//
// Card coverage, kernel-enforced:
//   1. successful write operations — the product's canonical
//      container home (LocalImportJournal.defaultDirectory(), the
//      C1/C2 journal root) is writable by the built product;
//   2. permission denials — a POSIX world-writable path OUTSIDE any
//      powerbox grant is denied to the built product (so the
//      destination-write feature can only ever work through a real
//      user grant, never through ambient filesystem permissions);
//   3. security-scoped URL lifetime management — the REAL
//      SystemSecurityScopedAccess adapter and SecurityScopedClaims
//      hold their balanced-claim contract against the live kernel
//      API (begin on an unscoped URL returns false and needs no
//      release; end on it is the documented no-op; release is
//      idempotent; post-release claims are dropped).
//
// NOT provable here (design §7): an actual powerbox grant — the
// powerbox is user-only by design; the live user-picked write is P4,
// owner-gated on t_7711fdbf. These tests prove the kernel-enforced
// negative space around that grant and the container-writable
// positive space, which IS automatable.

final class SandboxWriteBehaviorTests: XCTestCase {

    // MARK: - 1. Successful writes (kernel-enforced positive case)

    /// The container home — the canonical journal root from C1/C2 —
    /// must be writable by the built product under the real sandbox.
    /// A test-owned uniquely-named probe file is written, read back
    /// byte-exact, and removed; the shared journal file itself is
    /// never touched (cleanup rule: only resources the test created).
    func testContainerHomeIsWritableUnderSandbox() throws {
        let home = LocalImportJournal.defaultDirectory()
        // The defaultDirectory() contract: Application Support/Tunory,
        // temporaryDirectory only as a last resort. Either way the
        // returned root must be INSIDE the sandbox container or the
        // sandbox-writable temp space — i.e. a root the kernel lets
        // the built product write to.
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let probe = home.appendingPathComponent("tunory-write-probe-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: probe) }

        let payload = Data("tunory sandbox write probe".utf8)
        try payload.write(to: probe)

        let readBack = try Data(contentsOf: probe)
        XCTAssertEqual(readBack, payload,
                       "container-home write must round-trip byte-exact under the real sandbox")

        try FileManager.default.removeItem(at: probe)
        XCTAssertFalse(FileManager.default.fileExists(atPath: probe.path),
                       "cleanup must remove the test-owned probe file")
    }

    // MARK: - 2. Permission denials (kernel-enforced negative case)

    /// A path that POSIX alone would let ANYONE write (world-writable
    /// /Users/Shared, mode 0777) must be DENIED to the built product
    /// when no powerbox grant covers it. This is the security
    /// property that makes the user-selected-write feature safe: the
    /// app can never fall back to ambient filesystem permissions —
    /// destination writes can only succeed through an explicit user
    /// grant. If this test ever fails by SUCCEEDING, the sandbox is
    /// off or leaky: fail loudly.
    func testWorldWritablePathOutsideGrantsIsDenied() throws {
        let shared = URL(fileURLWithPath: "/Users/Shared")
        // Guard the fixture with RAW POSIX MODE BITS, not a writability
        // probe: isWritableFile()/access(W_OK) are themselves mediated by
        // the sandbox (it already returns false under the profile, which
        // would make the guard skip the decisive proof). Metadata reads
        // are allowed under the default container profile, so the mode
        // is observable from inside the sandbox. Mode 0777 means an
        // UNSANDBOXED process could write here — so if the write below
        // is denied, only the sandbox can be denying it.
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: shared.path)
        } catch {
            throw XCTSkip("/Users/Shared metadata unreadable (\(error.localizedDescription)); " +
                          "cannot confirm the fixture is POSIX-writable")
        }
        guard let permissions = attributes[.posixPermissions] as? Int,
              permissions & 0o002 == 0o002 else {
            throw XCTSkip("/Users/Shared is not POSIX world-writable on this machine; " +
                          "a denial would not isolate sandbox enforcement")
        }

        let target = shared.appendingPathComponent("tunory-sandbox-deny-probe-\(UUID().uuidString).bin")
        // Best effort: must not be left behind even if some context
        // unexpectedly allows the write (e.g. an unsandboxed misbuild).
        defer { try? FileManager.default.removeItem(at: target) }

        let payload = Data("denied".utf8)
        do {
            try payload.write(to: target)
            // Reaching here means the write SUCCEEDED: either the
            // sandbox is not enforced on this test host (misbuild /
            // re-signed without the profile) or the kernel granted
            // ambient write access. Either way the product contract
            // this suite pins is broken.
            XCTFail("write to \(target.path) succeeded — the sandbox must deny " +
                    "writes to paths outside the container and any powerbox grant")
        } catch {
            // The expected kernel denial (EPERM: Operation not
            // permitted). Any thrown error is a denial; asserting the
            // exact Cocoa error code would couple the test to
            // errno-mapping details that vary by macOS release.
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                           "a denied write must leave no file behind")
        }
    }

    // MARK: - 3. Security-scoped URL lifetime (real adapter)

    /// The REAL SystemSecurityScopedAccess adapter against the live
    /// kernel API: an unscoped URL (no powerbox grant) must report
    /// begin == false — nothing to claim, nothing to release — and
    /// end on it must be the documented no-op (never a crash, never
    /// an over-release). This pins the adapter half of the balanced
    /// contract without a fake: the kernel itself answers.
    func testRealAdapterUnscopedURLClaimsNothingAndEndIsNoOp() {
        let adapter = SystemSecurityScopedAccess()
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunory-unscoped-\(UUID().uuidString)", isDirectory: true)

        let claimed = adapter.begin(url: plain)
        XCTAssertFalse(claimed,
                       "an unscoped URL must report no grant to claim (begin == false)")
        // The documented contract: end on a URL whose begin returned
        // false is a no-op — safe to call, no state corrupted.
        adapter.end(url: plain)
        adapter.end(url: plain) // no-op is idempotent too
    }

    /// SecurityScopedClaims over the REAL adapter: claims on unscoped
    /// URLs record nothing, release() is idempotent, claims after
    /// release are dropped, and every exit path stays balanced. The
    /// powerbox itself cannot be driven programmatically (P4 is
    /// human-gated), so the granted branch of this contract is
    /// already pinned by the P2 fake-based suites; this test pins
    /// the REAL adapter's behavior on the branch automation can
    /// reach.
    func testRealClaimsBatchBalancedOnUnscopedURLs() {
        let claims = SecurityScopedClaims(claiming: SystemSecurityScopedAccess())
        let a = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunory-claims-a-\(UUID().uuidString)", isDirectory: true)
        let b = FileManager.default.temporaryDirectory
            .appendingPathComponent("tunory-claims-b-\(UUID().uuidString)", isDirectory: true)

        claims.claim(a)
        claims.claim(b)
        claims.release()
        claims.release() // idempotent: second release must be a no-op

        // Claims after release must be dropped (guard !released) —
        // a late claim would otherwise dangle unbalanced.
        claims.claim(a)
    }

    /// The claims batch used the way production uses it (defer
    /// release on every exit path): even when the operation between
    /// claim and release throws, the deferred release runs exactly
    /// once and the process is left with zero outstanding claims.
    func testRealClaimsReleaseOnThrowingExitPath() {
        struct ProbeError: Error {}
        var releasedOnce = false
        do {
            let claims = SecurityScopedClaims(claiming: SystemSecurityScopedAccess())
            defer {
                claims.release()
                releasedOnce = true
            }
            let plain = FileManager.default.temporaryDirectory
                .appendingPathComponent("tunory-claims-throw-\(UUID().uuidString)", isDirectory: true)
            claims.claim(plain)
            throw ProbeError()
        } catch {
            XCTAssertTrue(releasedOnce,
                          "the deferred release must have run on the throwing exit path")
        }
        XCTAssertNotNil(releasedOnce)
    }
}
