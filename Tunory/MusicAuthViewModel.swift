import Foundation
import Combine
import MusicKit

@MainActor
final class MusicAuthViewModel: ObservableObject {
    enum AuthState: Equatable {
        case unknown, notDetermined, denied, restricted, authorized
        case failure(String)
    }

    enum ConnectivityState: Equatable {
        case notTested, checking
        case reachable(albums: Int)
        case unreachable(String)

        var description: String {
            switch self {
            case .notTested: return String(localized: "Not tested")
            case .checking: return String(localized: "Checking the Apple Music catalog…")
            case .reachable(let count): return String(localized: "Catalog reachable; returned \(count) album(s).")
            case .unreachable(let detail): return String(localized: "Catalog unavailable: \(detail)")
            }
        }
    }

    @Published private(set) var state: AuthState = .unknown
    @Published private(set) var connectivity: ConnectivityState = .notTested
    @Published private(set) var isRequestingAuthorization = false
    @Published private(set) var isTestingConnectivity = false
    private let currentStatus: () -> MusicAuthorization.Status
    private let requestAccess: () async -> MusicAuthorization.Status
    private let checkCatalog: () async throws -> Int
    private var authorizationRevision: UInt = 0

    init(currentStatus: @escaping () -> MusicAuthorization.Status = { MusicAuthorization.currentStatus },
         requestAccess: @escaping () async -> MusicAuthorization.Status = { await MusicAuthorization.request() },
         checkCatalog: @escaping () async throws -> Int = {
             var request = MusicCatalogSearchRequest(term: "music", types: [Album.self])
             request.limit = 1
             return try await request.response().albums.count
         }) {
        self.currentStatus = currentStatus
        self.requestAccess = requestAccess
        self.checkCatalog = checkCatalog
        _state = Published(initialValue: Self.authState(currentStatus()))
    }

    private static func authState(_ status: MusicAuthorization.Status) -> AuthState {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .failure(String(localized: "Unknown Apple Music authorization state."))
        }
    }

    func refresh() {
        let next = Self.authState(currentStatus())
        guard next != state else { return }
        authorizationRevision &+= 1
        if connectivity != .notTested { connectivity = .notTested }
        state = next
    }

    func requestAuthorization() async {
        guard !isRequestingAuthorization, !isTestingConnectivity else { return }
        isRequestingAuthorization = true
        defer { isRequestingAuthorization = false }
        _ = await requestAccess()
        refresh()
        guard !Task.isCancelled, state == .authorized else { return }
        await runConnectivityCheck()
    }

    /// Catalog-only proof. This never writes to a library or playlist.
    func runConnectivityCheck() async {
        refresh()
        guard state == .authorized, !isTestingConnectivity else { return }
        isTestingConnectivity = true
        connectivity = .checking
        let revision = authorizationRevision
        defer {
            isTestingConnectivity = false
            if connectivity == .checking { connectivity = .notTested }
        }
        do {
            let albums = try await checkCatalog()
            refresh()
            guard !Task.isCancelled, revision == authorizationRevision, state == .authorized else { return }
            connectivity = .reachable(albums: albums)
        } catch {
            refresh()
            guard !Task.isCancelled, revision == authorizationRevision, state == .authorized else { return }
            connectivity = .unreachable(error.localizedDescription)
        }
    }
}
