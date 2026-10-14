import Foundation
import Combine
import TunoryCore

/// Local-file import workflow: select → analyze → duplicates → review →
/// convert → results. Thin presentation adapter: every decision comes
/// from the canonical LocalImportEngine (`planFiles`); this model only
/// tracks flow state and the user's explicit duplicate-review choices.
///
/// The Music.app import step is intentionally NOT wired: the app has no
/// Automation entitlement and live library writes need explicit operator
/// approval (t_5ed9e8d3). The flow ends at conversion results; the user
/// drag-imports into Music.app themselves.
@MainActor
final class LocalImportViewModel: ObservableObject {

    enum Step: Equatable {
        case select
        case analyzing
        case review
        case converting
        case results
    }

    /// One presented file row: engine plan entry + review decision.
    struct Row: Identifiable, Equatable {
        enum ReviewDecision: Equatable { case notReviewed, include, skip }

        let id: Int
        let planEntry: LocalImportPlanEntry
        let reviewDecision: ReviewDecision

        var decision: ConversionDecision { planEntry.decision }
        var probe: AudioProbe { planEntry.probe }
        var relativePath: String { planEntry.relativePath }
        var sourcePath: String { planEntry.sourcePath }

        /// True when this row is a batch duplicate the user must resolve.
        var requiresReview: Bool {
            planEntry.duplicateOfIndex != nil
                && (decision == .convert || decision == .passthroughNative)
        }

        /// The user-visible action that will be taken for this row.
        var summary: String {
            switch decision {
            case .convert: return "Convert"
            case .passthroughNative: return "Import as-is (already supported)"
            case .skipValidOutput: return "Already converted (skipped)"
            case .conflictDestinationValidForeign: return "Blocked: destination file exists"
            case .conflictDestinationInvalidForeign: return "Blocked: destination file exists"
            case .undecodableSource: return "Unsupported or corrupted"
            case .blockedByProfile: return "Blocked: profile not applicable"
            }
        }
    }

    // MARK: - State

    @Published private(set) var step: Step = .select
    @Published private(set) var selectedCount = 0
    @Published private(set) var rows: [Row] = []
    @Published private(set) var outputDirectory: URL?
    @Published private(set) var profile: ConversionProfile = .aac256
    @Published private(set) var outcomes: [ConversionOutcome] = []
    @Published private(set) var journalWarning: String?
    /// Index of the file being converted (progress indicator).
    @Published private(set) var convertingIndex: Int?

    private let engine: LocalImportEngine
    private let journalDirectory: URL
    private var selectedFiles: [URL] = []
    private var reviewDecisions: [Int: Row.ReviewDecision] = [:]
    private var generation = 0

    init(engine: LocalImportEngine = LocalImportEngine(),
         journalDirectory: URL? = nil) {
        self.engine = engine
        self.journalDirectory = journalDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                .map { $0.appendingPathComponent("Tunory", isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    // MARK: - Derived review state

    /// True when every duplicate-requiring-review has an explicit decision.
    var reviewComplete: Bool { pendingReviewCount == 0 }

    var pendingReviewCount: Int {
        rows.filter { $0.requiresReview && reviewDecisions[$0.id] == nil }.count
    }

    /// Entries the user has marked for processing (engine plan +
    /// explicit duplicate decisions).
    var selectedForProcessing: [LocalImportPlanEntry] {
        rows.compactMap { row in
            guard row.decision == .convert || row.decision == .passthroughNative else { return nil }
            if row.requiresReview, reviewDecisions[row.id] != .include { return nil }
            return row.planEntry
        }
    }

    // MARK: - Selection

    func select(files urls: [URL]) {
        reset()
        guard !urls.isEmpty else { return }
        selectedFiles = urls.sorted { $0.standardizedFileURL.path < $1.standardizedFileURL.path }
        selectedCount = urls.count
    }

    func setProfile(_ newProfile: ConversionProfile) {
        profile = newProfile
    }

    // MARK: - Analyze (all decisions from the engine)

    func analyze(outputDirectory: URL) async {
        guard !selectedFiles.isEmpty else { return }
        generation &+= 1
        let revision = generation
        self.outputDirectory = outputDirectory
        step = .analyzing
        rows = []
        reviewDecisions = [:]

        let journal = LocalImportJournal(directory: journalDirectory)
        let (records, warning) = (try? journal.load()) ?? ([], nil)
        journalWarning = warning

        let plan = await engine.planFiles(files: selectedFiles,
                                          outputDirectory: outputDirectory,
                                          profile: profile,
                                          journalRecords: records)
        guard revision == generation else { return }
        rows = plan.entries.enumerated().map { index, entry in
            Row(id: index, planEntry: entry, reviewDecision: .notReviewed)
        }
        step = .review
    }

    // MARK: - Review

    func decide(rowID: Int, include: Bool) {
        reviewDecisions[rowID] = include ? .include : .skip
        rows = rows.map { row in
            guard row.id == rowID else { return row }
            return Row(id: row.id, planEntry: row.planEntry,
                       reviewDecision: include ? .include : .skip)
        }
    }

    // MARK: - Convert

    func convertSelected() async {
        let entries = selectedForProcessing
        guard !entries.isEmpty else { return }
        generation &+= 1
        let revision = generation
        step = .converting
        outcomes = []
        convertingIndex = nil

        let journal = LocalImportJournal(directory: journalDirectory)

        for (index, entry) in entries.enumerated() {
            convertingIndex = index
            let outcome = await engine.convert(entry: entry, profile: profile, journal: journal)
            guard revision == generation else { return }
            outcomes.append(outcome)
        }
        convertingIndex = nil
        step = .results
    }

    // MARK: - Results

    var resultsSummary: (converted: Int, skippedValid: Int, passthrough: Int,
                         conflict: Int, failed: Int) {
        var converted = 0, skipped = 0, passthrough = 0, conflict = 0, failed = 0
        for outcome in outcomes {
            switch outcome.status {
            case .converted: converted &+= 1
            case .skippedValid: skipped &+= 1
            case .passthrough: passthrough &+= 1
            case .conflict: conflict &+= 1
            case .failed: failed &+= 1
            }
        }
        return (converted, skipped, passthrough, conflict, failed)
    }

    // MARK: - Reset

    func reset() {
        generation &+= 1
        selectedFiles = []
        selectedCount = 0
        rows = []
        reviewDecisions = [:]
        outcomes = []
        outputDirectory = nil
        journalWarning = nil
        convertingIndex = nil
        step = .select
    }
}
