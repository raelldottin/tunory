import Foundation

// MARK: - Security-scoped resource access (transport layer)
//
// Under com.apple.security.app-sandbox, URLs handed to the app by the
// powerbox (SwiftUI fileImporter, NSOpenPanel) carry a grant that MUST
// be claimed with startAccessingSecurityScopedResource() before the
// file is read or written, and released afterwards. An unclaimed open
// fails, and the content probe then misreports valid files as
// "undecodable by AVFoundation" (defect t_d07f9a4d — the Apple-Music
// manifest flow already did this correctly; see
// ImportViewModel.importManifest).
//
// This is a TRANSPORT concern only. No decision logic lives here and
// the canonical engines (LocalImportEngine, AudioProber,
// MusicImportEngine) are untouched: claims are made at the view-model
// boundary, the narrowest scope that knows which powerbox URLs an
// operation will touch.
//
// The claiming surface is a protocol so unsandboxed unit tests can
// assert the claim CONTRACT (every operation that touches a granted
// URL claims first, and every claim is released) without faking
// sandbox proof — the sandbox itself is proven only by the signed-GUI
// drive (acceptance criterion 2 of t_d07f9a4d).

/// Claims and releases powerbox grants. `begin` returns true when a
/// grant was actually claimed (and `end` must later be called for it);
/// false when the URL carries no security scope (a plain filesystem
/// URL — nothing to release). Balanced: one `end` per `true` begin.
protocol SecurityScopedAccessClaiming: Sendable {
    @discardableResult
    func begin(url: URL) -> Bool
    func end(url: URL)
}

/// The system adapter — the ONLY place Tunory's local-import flow
/// touches the powerbox API. `stopAccessingSecurityScopedResource` on
/// a URL whose `begin` returned false is a documented no-op, so the
/// balanced-call contract is safe for non-scoped URLs too.
struct SystemSecurityScopedAccess: SecurityScopedAccessClaiming {
    func begin(url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func end(url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// One operation's balanced set of claims. Claim grants as the
/// operation touches granted URLs; `release()` returns them all,
/// newest-first, exactly once, on every exit path (pair it with
/// `defer`). Mirrors ImportViewModel.importManifest's
/// immediate-scope pattern, extended to span `await` points.
final class SecurityScopedClaims {
    private let claiming: SecurityScopedAccessClaiming
    private var claimed: [URL] = []
    private var released = false

    init(claiming: SecurityScopedAccessClaiming) {
        self.claiming = claiming
    }

    /// Claim `url`'s grant. No-op (and nothing to release) when the
    /// URL carries no security scope.
    func claim(_ url: URL) {
        guard !released else { return }
        if claiming.begin(url: url) {
            claimed.append(url)
        }
    }

    /// Release every grant this object actually claimed, in reverse
    /// order of claiming. Idempotent.
    func release() {
        guard !released else { return }
        released = true
        for url in claimed.reversed() {
            claiming.end(url: url)
        }
    }
}
