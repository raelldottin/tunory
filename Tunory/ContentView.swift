import SwiftUI
import TunoryCore

struct ContentView: View {
    @StateObject private var authModel: MusicAuthViewModel
    @StateObject private var importModel: ImportViewModel
    @StateObject private var transactionModel: TransactionViewModel
    @StateObject private var recoveryModel: RecoveryViewModel
    #if DEBUG
    private let validationContext: UIValidationContext?
    #endif
    @Environment(\.scenePhase) private var scenePhase
    enum Destination: Hashable { case status, importReview, recovery }
    enum FlowStep: Hashable { case review, configure, run, results }
    @State private var selectedTab: Destination = .status
    @State private var flowStep: FlowStep = .review
    @State private var playlistName = ""
    @State private var createIfMissing = true
    @State private var showWriteConfirmation = false
    @State private var writeActionInFlight = false

    init() {
        #if DEBUG
        let validation = UIValidationContext.fromArguments()
        self.validationContext = validation
        if let validation {
            let auth = validation.makeAuth()
            _authModel = StateObject(wrappedValue: auth)
            _importModel = StateObject(wrappedValue: ImportViewModel(authModel: auth, makeEngine: validation.makeResolutionEngine))
            _transactionModel = StateObject(wrappedValue: TransactionViewModel(checkpointStore: validation.store,
                authorizationStatus: { validation.authorization }, makeEngine: validation.makeEngine))
            _recoveryModel = StateObject(wrappedValue: RecoveryViewModel(store: validation.store,
                authorizationStatus: { validation.authorization }, makeEngine: validation.makeEngine))
            if validation.opensRecovery { _selectedTab = State(initialValue: .recovery) }
            return
        }
        #endif
        let auth = MusicAuthViewModel()
        _authModel = StateObject(wrappedValue: auth)
        _importModel = StateObject(wrappedValue: ImportViewModel(authModel: auth))
        _transactionModel = StateObject(wrappedValue: TransactionViewModel())
        _recoveryModel = StateObject(wrappedValue: RecoveryViewModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            #if DEBUG
            validationBanner
            #endif
            TabView(selection: $selectedTab) {
                Tab("Status", systemImage: "waveform", value: Destination.status) {
                    NavigationStack { statusBody.navigationTitle("Tunory") }
                }
                Tab("Import", systemImage: "square.and.arrow.down", value: Destination.importReview) {
                    NavigationStack { flowBody.navigationTitle(importTitle) }
                }
                Tab("Recovery", systemImage: "arrow.clockwise", value: Destination.recovery) {
                    NavigationStack {
                        RecoveryView(model: recoveryModel,
                                     canResume: authModel.state == .authorized && !writeActionInFlight && !transactionModel.isRunning && !importModel.isBusy,
                                     onResume: resumeRecovery,
                                     onOpenStatus: { selectedTab = .status })
                            .navigationTitle("Recovery")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 520)
        #endif
        #if DEBUG
        .preferredColorScheme(validationContext?.colorScheme)
        #endif
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshAuthorization() }
        }
        .onChange(of: selectedTab) { _, tab in
            refreshAuthorization()
            if tab == .recovery, recoveryModel.stage != .finished { recoveryModel.loadPersisted() }
        }
        .onChange(of: transactionModel.stage) { _, stage in
            if stage == .finished { recoveryModel.loadPersisted() }
        }
        .task {
            refreshAuthorization()
            recoveryModel.loadPersisted()
        }
    }

    #if DEBUG
    @ViewBuilder private var validationBanner: some View {
        if let validationContext {
            VStack(alignment: .leading, spacing: 4) {
                Label("UI validation · sample data", systemImage: "testtube.2")
                Text("Sample data · no live Apple Music")
                if let error = validationContext.setupError { Text(error).accessibilityIdentifier("validation.setupError") }
            }
            .font(.caption).padding(8)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("validation.banner")
        }
    }
    #endif

    private func refreshAuthorization() {
        authModel.refresh()
        importModel.refreshAuth()
    }

    private var importTitle: String {
        switch flowStep {
        case .review: return String(localized: "Import and Review")
        case .configure: return String(localized: "Configure Playlist")
        case .run: return String(localized: "Import Progress")
        case .results: return String(localized: "Import Results")
        }
    }

    @ViewBuilder private var flowBody: some View {
        switch flowStep {
        case .review:
            ImportView(authModel: authModel, model: importModel,
                       isWorkflowBusy: writeActionInFlight || transactionModel.isRunning || recoveryModel.isRunning,
                       onOpenStatus: { selectedTab = .status },
                       onAllResolved: { flowStep = .configure })
        case .configure: configureBody
        case .run:
            TransactionProgressView(model: transactionModel, onViewResults: { flowStep = .results })
        case .results:
            ResultsView(model: transactionModel) {
                guard !transactionModel.isRunning, !recoveryModel.isRunning else { return }
                transactionModel.reset()
                importModel.reset()
                playlistName = ""
                flowStep = .review
            }
        }
    }

    private var canStart: Bool {
        importModel.canContinueReview
        && !writeActionInFlight && !importModel.isBusy && !transactionModel.isRunning && !recoveryModel.isRunning
        && authModel.state == .authorized
        && !playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var configureBody: some View {
        TunoryScreen {
            TunoryNotice(title: "Ready to build your playlist", message: "Review is read-only. Nothing changes until you confirm Start Import.", symbol: "checklist")
            GroupBox("Confirmed recordings") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(importModel.resolutions.count) recordings in the reviewed order")
                    Text("Exact Apple Music catalog identities will be used. Existing playlist tracks are never cleared or reordered.")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Target playlist") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Playlist name", text: $playlistName)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("configure.playlistName")
                        .accessibilityLabel("Playlist name")
                    Toggle("Create the playlist if no exact name matches", isOn: $createIfMissing)
                        .accessibilityIdentifier("configure.createIfMissing")
                    Text(createIfMissing
                         ? "A new playlist may be created. If one exact-name playlist exists, Tunory uses it only when fresh reads prove safe appends."
                         : "Tunory stops if there is no exact-name playlist. Multiple matches or an unsafe playlist always stop the import.")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            TunoryNotice(title: "This action changes Apple Music", message: "Tunory may add missing recordings to your library and append them to the target playlist. Each phase is checked with fresh reads. Partial progress may remain if Apple Music stops responding.", symbol: "exclamationmark.triangle")
            if authModel.state != .authorized {
                Button("Review Apple Music Access") { selectedTab = .status }
                    .accessibilityIdentifier("configure.authorization")
            }
            if recoveryModel.isRunning {
                Text("Recovery is running. Wait for it to finish before starting another import.")
            }
            TunoryActions {
                Button("Start Import") { showWriteConfirmation = true }
                    .buttonStyle(.borderedProminent).disabled(!canStart)
                    .accessibilityIdentifier("configure.start")
                Button("Back to Review") { flowStep = .review }
                    .buttonStyle(.bordered).accessibilityIdentifier("configure.back")
            }
        }
        .onAppear {
            if playlistName.isEmpty {
                playlistName = "Tunory Import \(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash)))"
            }
        }
        .confirmationDialog("Start this Apple Music import?", isPresented: $showWriteConfirmation, titleVisibility: .visible) {
            Button("Start Import") {
                refreshAuthorization()
                guard canStart else { return }
                transactionModel.playlistName = playlistName
                transactionModel.createIfMissing = createIfMissing
                let reviewed = importModel.resolutions
                writeActionInFlight = true
                flowStep = .run
                Task {
                    defer { writeActionInFlight = false }
                    await transactionModel.start(resolutions: reviewed)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Add missing recordings to your library and append \(importModel.resolutions.count) reviewed recordings to “\(playlistName)”. Existing tracks will not be removed or reordered. Playlist creation is \(createIfMissing ? "enabled" : "disabled").")
        }
    }

    private func resumeRecovery() {
        refreshAuthorization()
        guard authModel.state == .authorized, !writeActionInFlight,
              !transactionModel.isRunning, !importModel.isBusy else { return }
        writeActionInFlight = true
        Task {
            defer { writeActionInFlight = false }
            await recoveryModel.resume()
        }
    }

    private var statusBody: some View {
        TunoryScreen {
            GroupBox("Apple Music access") {
                VStack(alignment: .leading, spacing: 12) {
                    Label(authorizationTitle, systemImage: authModel.state == .authorized ? "checkmark.shield" : "lock")
                        .font(.headline).accessibilityIdentifier("status.authorization")
                    Text(authorizationDescription).foregroundStyle(.secondary)
                    if authModel.state == .notDetermined {
                        Button("Enable Apple Music Access") { Task { await authModel.requestAuthorization() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(authModel.isRequestingAuthorization || authModel.isTestingConnectivity)
                            .accessibilityIdentifier("status.requestAccess")
                    }
                    if authModel.isRequestingAuthorization { ProgressView("Waiting for authorization…") }
                    if authModel.state != .authorized && authModel.state != .notDetermined && authModel.state != .unknown {
                        Button("Refresh Access Status", action: refreshAuthorization)
                            .accessibilityIdentifier("status.refreshAccess")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Catalog connectivity · read-only") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(authModel.connectivity.description).accessibilityIdentifier("status.connectivity")
                    Text("This checks a catalog request. It does not verify library access or playlist writes.")
                        .font(.callout).foregroundStyle(.secondary)
                    if authModel.isTestingConnectivity { ProgressView("Checking connectivity…") }
                    Button(authModel.connectivity == .notTested ? "Test Connectivity" : "Test Again") {
                        Task { await authModel.runConnectivityCheck() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(authModel.state != .authorized || authModel.isTestingConnectivity || authModel.isRequestingAuthorization)
                    .accessibilityIdentifier("status.testConnectivity")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if recoveryModel.hasPending || recoveryModel.isRunning {
                TunoryNotice(title: "Saved import progress", message: "Review the checkpoint before starting another import. Opening Recovery does not write to Apple Music.", symbol: "arrow.clockwise")
                Button("Review Saved Progress") { selectedTab = .recovery }
                    .buttonStyle(.bordered).accessibilityIdentifier("status.openRecovery")
            }
            Button("Import a Song List") { selectedTab = .importReview }
                .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("status.openImport")
            DisclosureGroup("How Tunory imports music") {
                Text("Import a song list, confirm exact recordings, and review every change before writing to Apple Music.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var authorizationTitle: String {
        switch authModel.state {
        case .unknown: return String(localized: "Checking access")
        case .notDetermined: return String(localized: "Access not requested")
        case .denied: return String(localized: "Access denied")
        case .restricted: return String(localized: "Access restricted")
        case .authorized: return String(localized: "Access granted")
        case .failure: return String(localized: "Could not determine access")
        }
    }

    private var authorizationDescription: String {
        switch authModel.state {
        case .unknown: return String(localized: "Tunory is checking the current Apple Music permission.")
        case .notDetermined: return String(localized: "Allow Apple Music access to resolve songs. Review and catalog checks do not change your library.")
        case .denied:
            #if os(macOS)
            return String(localized: "Enable Tunory in System Settings → Privacy & Security → Media & Apple Music, then refresh.")
            #else
            return String(localized: "Enable Apple Music access for Tunory in Settings, then return here to refresh.")
            #endif
        case .restricted: return String(localized: "Device restrictions prevent Apple Music access. Review Screen Time or managed-device restrictions before trying again.")
        case .authorized: return String(localized: "Permission is available. Connectivity and write verification are separate checks.")
        case .failure(let detail): return detail
        }
    }
}
