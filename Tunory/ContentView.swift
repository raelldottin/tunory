import SwiftUI
import MusicKit
import Combine

@MainActor
final class MusicAuthViewModel: ObservableObject {
    enum AuthState: Equatable {
        case unknown
        case notDetermined
        case denied
        case restricted
        case authorized
        case failure(String)
    }

    @Published private(set) var state: AuthState = .unknown
    @Published private(set) var connectivity: String = "not tested"

    init() {
        refresh()
    }

    func refresh() {
        switch MusicAuthorization.currentStatus {
        case .authorized:
            state = .authorized
        case .denied:
            state = .denied
        case .restricted:
            state = .restricted
        case .notDetermined:
            state = .notDetermined
        @unknown default:
            state = .failure("unknown authorization status")
        }
    }

    func requestAuthorization() async {
        let status = await MusicAuthorization.request()
        refresh()
        if status == .authorized {
            await runConnectivityCheck()
        }
    }

    /// Read-only Apple Music API check: run a minimal catalog search (limit 1).
    /// Never mutates the user's library.
    func runConnectivityCheck() async {
        do {
            var request = MusicCatalogSearchRequest(term: "music", types: [Album.self])
            request.limit = 1
            let response = try await request.response()
            connectivity = "reachable (albums returned: \(response.albums.count))"
        } catch {
            connectivity = "unreachable: \(error.localizedDescription)"
        }
    }
}

struct ContentView: View {
    @StateObject private var model = MusicAuthViewModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("Tunory")
                .font(.largeTitle)

            Text(statusText)

            if model.state == .notDetermined || model.state == .denied {
                Button("Enable Apple Music Access") {
                    Task { await model.requestAuthorization() }
                }
            }

            if model.state == .authorized {
                Text("Connectivity: \(model.connectivity)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(minWidth: 420, minHeight: 240)
    }

    private var statusText: String {
        switch model.state {
        case .unknown: return "Checking MusicKit authorization…"
        case .notDetermined: return "MusicKit authorization has not been requested."
        case .denied: return "Apple Music access denied. Grant access in System Settings."
        case .restricted: return "Apple Music access is restricted on this device."
        case .authorized: return "Apple Music access granted (read-only)."
        case .failure(let msg): return "Error: \(msg)"
        }
    }
}

#Preview {
    ContentView()
}
