import SwiftUI
import MusicKit
import Combine
import TunoryCore

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
    @StateObject private var authModel = MusicAuthViewModel()
    @StateObject private var importModel: ImportViewModel
    @StateObject private var transactionModel = TransactionViewModel()
    @State private var selectedTab: Tab = .status
    @State private var playlistName: String = ""
    @State private var createIfMissing: Bool = true

    init() {
        // ImportViewModel needs the auth model; both are MainActor.
        let auth = MusicAuthViewModel()
        _authModel = StateObject(wrappedValue: auth)
        _importModel = StateObject(wrappedValue: ImportViewModel(authModel: auth))
    }

    /// The GUI flow state machine (Import → Review → Configure → Run →
    /// Results). Phase 5 keeps first release small and focused on
    /// importing music; each step exposes exactly one action.
    private enum FlowStep: Equatable {
        case review      // recording review (Import & Review screen)
        case configure   // playlist name + create policy
        case run         // progress screen
        case results     // results screen
    }
    @State private var flowStep: FlowStep = .review

    enum Tab: Hashable {
        case status
        case importReview
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Screen", selection: $selectedTab) {
                Text("Status").tag(Tab.status)
                Text("Import").tag(Tab.importReview)
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top], 16)

            Divider()
                .padding(.top, 8)

            switch selectedTab {
            case .status:
                statusBody
            case .importReview:
                flowBody
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onChange(of: selectedTab) { _, tab in
            if tab == .importReview { authModel.refresh() }
        }
    }

    // MARK: - Import flow

    @ViewBuilder
    private var flowBody: some View {
        // ImportView models its own idle→parsed→resolving→review phases;
        // the outer flow advances to configure only when every line is
        // resolved, and to run/results via explicit single actions.
        switch flowStep {
        case .review:
            ImportView(authModel: authModel, model: importModel,
                      onAllResolved: { flowStep = .configure })
        case .configure:
            configureBody
        case .run:
            TransactionProgressView(model: transactionModel,
                                    onViewResults: { flowStep = .results })
        case .results:
            ResultsView(model: transactionModel) {
                transactionModel.reset()
                importModel.reset()
                flowStep = .review
            }
        }
    }

    private var configureBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add to Library & Create Playlist")
                    .font(.title2.bold())
                Spacer()
                Button("Back to Review") {
                    transactionModel.reset()
                    flowStep = .review
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Review summary")
                    .font(.headline)
                Text("\(importModel.resolutions.count) recordings, all resolved to exact Apple Music catalog IDs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if unresolvedCount > 0 {
                    Label("\(unresolvedCount) line(s) still need review — the transaction cannot run until every line is confirmed.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Playlist")
                    .font(.headline)
                TextField("Playlist name", text: $playlistName)
                    .textFieldStyle(.roundedBorder)
                Toggle("Create the playlist if no playlist with this exact name exists",
                       isOn: $createIfMissing)
                    .font(.callout)
                Text("If a playlist with the same name already exists it is used as-is and only provably-safe appends are made; it is never cleared or reordered.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                if !canStart, unresolvedCount > 0 {
                    Text("Resolve every line first")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Start Import") {
                    flowStep = .run
                    Task {
                        transactionModel.playlistName = playlistName
                        transactionModel.createIfMissing = createIfMissing
                        await transactionModel.start(resolutions: importModel.resolutions)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if playlistName.isEmpty { playlistName = defaultPlaylistName }
        }
    }

    private var defaultPlaylistName: String {
        "Tunory Import \(Self.dateStamp())"
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private var unresolvedCount: Int {
        importModel.resolutions
            .filter { $0.status != .resolved }
            .count
    }

    private var canStart: Bool {
        !importModel.resolutions.isEmpty
            && unresolvedCount == 0
            && authModel.state == .authorized
            && !playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Status screen

    private var statusBody: some View {
        VStack(spacing: 16) {
            Text("Tunory")
                .font(.largeTitle)

            Text(statusText)

            if authModel.state == .notDetermined || authModel.state == .denied {
                Button("Enable Apple Music Access") {
                    Task { await authModel.requestAuthorization() }
                }
            }

            if authModel.state == .authorized {
                Text("Connectivity: \(authModel.connectivity)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(minWidth: 420, minHeight: 240)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusText: String {
        switch authModel.state {
        case .unknown: return "Checking MusicKit authorization…"
        case .notDetermined: return "MusicKit authorization has not been requested."
        case .denied: return "Apple Music access denied. Grant access in System Settings."
        case .restricted: return "Apple Music access is restricted on this device."
        case .authorized: return "Apple Music access granted (read-only)."
        case .failure(let msg): return "Error: \(msg)"
        }
    }
}
