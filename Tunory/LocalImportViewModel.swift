import Foundation
import Combine
import TunoryCore

/// Local-file import workflow: select → analyze → duplicates → review →
/// convert → music survey → music review → import → results.
/// Thin presentation adapter: every decision comes from the canonical
/// engines (`LocalImportEngine.planFiles`, `MusicImportEngine`); this
/// model only tracks flow state and the user's explicit choices.
/// The Music.app import step uses the Automation entitlement granted in
/// t_559e5375; live library writes are operator-gated (t_5ed9e8d3 /
/// t_ed3bfd46 cover signed-app + TCC proof).
@MainActor
final class LocalImportViewModel: ObservableObject {

    enum Step: Equatable {
        case select
        case analyzing
        case review
        case converting
        case results
        case musicSurvey
        case musicReview
        case musicImporting
        case musicResults
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

    // MARK: - Music.app import state (all decisions from MusicImportEngine)

    /// Import candidates derived from conversion outcomes: files the
    /// convert step actually produced (converted or passthrough).
    @Published private(set) var musicImportFiles: [URL] = []
    /// Survey classification per import candidate, from the engine.
    @Published private(set) var musicSurveys: [MusicLibraryCandidate] = []
    /// Files whose survey failed outright (Music busy, script error):
    /// fail-stop; never treated as "no candidates".
    @Published private(set) var musicSurveyFailures: [String] = []
    /// Per-file import outcomes, after the import run.
    @Published private(set) var musicOutcomes: [MusicImportOutcome] = []
    /// Warning from loading the Music import journal (unreadable etc.).
    @Published private(set) var musicJournalWarning: String?
    /// Index of the file being imported (progress indicator).
    @Published private(set) var importingIndex: Int?

    private let engine: LocalImportEngine
    private let musicEngine: MusicImportEngine
    private let journalDirectory: URL
    private let musicJournalDirectory: URL
    private let securityScopedAccess: SecurityScopedAccessClaiming
    /// Powerbox grants held for this run: the exact URLs the user handed
    /// us (fileImporter picks, NSOpenPanel directory). Claims must be
    /// made on these URLs — the sandbox tracks the grant on the URL the
    /// powerbox returned, so rebuilt copies of the path are matched back
    /// to the originals by standardized path before claiming.
    private var grantedFileURLs: [URL] = []
    private var grantedOutputDirectory: URL?
    private var selectedFiles: [URL] = []
    private var reviewDecisions: [Int: Row.ReviewDecision] = [:]
    private var generation = 0

    init(engine: LocalImportEngine = LocalImportEngine(),
         musicEngine: MusicImportEngine? = nil,
         journalDirectory: URL? = nil,
         musicJournalDirectory: URL? = nil,
         securityScopedAccess: SecurityScopedAccessClaiming = SystemSecurityScopedAccess()) {
        self.engine = engine
        self.musicEngine = musicEngine
            ?? MusicImportEngine(scripting: MusicAppScripting())
        self.journalDirectory = journalDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                .map { $0.appendingPathComponent("Tunory", isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.musicJournalDirectory = musicJournalDirectory
            ?? MusicImportJournal.defaultDirectory()
        self.securityScopedAccess = securityScopedAccess
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
        // The powerbox granted access to exactly these URLs; keep them
        // so every later read (probe/convert/import) claims the grant
        // on the URL the sandbox actually issued it to.
        grantedFileURLs = urls
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
        grantedOutputDirectory = outputDirectory
        step = .analyzing
        rows = []
        reviewDecisions = [:]

        // Claim every powerbox grant this read touches (selected files
        // + destination directory, whose contents the destination guard
        // probes), and release on every exit path.
        let claims = SecurityScopedClaims(claiming: securityScopedAccess)
        defer { claims.release() }
        for url in grantedFileURLs { claims.claim(url) }
        claims.claim(outputDirectory)

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

        // Claim every grant the convert writes/reads touch, once for
        // the whole run (sources are re-read, destinations written,
        // temp files live inside the destination directory).
        let claims = SecurityScopedClaims(claiming: securityScopedAccess)
        defer { claims.release() }
        for url in grantedFileURLs { claims.claim(url) }
        if let outputDirectory = grantedOutputDirectory ?? outputDirectory {
            claims.claim(outputDirectory)
        }

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

    /// Import candidates for the Music step: files the convert step
    /// actually produced. Converted files import from their destination;
    /// passthrough files import from the original source (the engine's
    /// convert step leaves those untouched).
    var musicCandidatesFromOutcomes: [URL] {
        outcomes.compactMap { outcome -> URL? in
            switch outcome.status {
            case .converted:
                return outcome.destinationPath.map { URL(fileURLWithPath: $0) }
            case .passthrough:
                return URL(fileURLWithPath: outcome.sourcePath)
            default:
                return nil
            }
        }
    }

    // MARK: - Music import: survey (read-only, engine-decided)

    /// Read-only survey of every import candidate against live Music
    /// state. No write is issued and no journal record is written.
    func surveyMusicLibrary() async {
        let candidates = musicCandidatesFromOutcomes
        guard !candidates.isEmpty else { return }
        generation &+= 1
        let revision = generation
        step = .musicSurvey
        musicImportFiles = candidates
        musicSurveys = []
        musicSurveyFailures = []
        musicOutcomes = []
        musicJournalWarning = nil

        let journal = MusicImportJournal(directory: musicJournalDirectory)
        let (_, warning) = (try? journal.load()) ?? ([], nil)
        musicJournalWarning = warning

        // Import candidates are original sources (fileImporter grants)
        // and/or converted outputs inside the granted destination
        // directory; the survey reads both. Claim for the whole survey.
        let claims = SecurityScopedClaims(claiming: securityScopedAccess)
        defer { claims.release() }
        for url in grantedFileURLs { claims.claim(url) }
        if let outputDirectory = grantedOutputDirectory ?? outputDirectory {
            claims.claim(outputDirectory)
        }

        var surveys: [MusicLibraryCandidate] = []
        var failures: [String] = []
        for file in candidates {
            guard let survey = await musicEngine.surveyFile(file: file) else {
                failures.append(file.path)
                continue
            }
            guard revision == generation else { return }
            surveys.append(survey)
        }
        guard revision == generation else { return }
        musicSurveys = surveys
        musicSurveyFailures = failures
        step = .musicReview
    }

    /// True when at least one surveyed file requires explicit review
    /// (metadata collision) or the survey failed for any file: the import
    /// cannot proceed without explicit user action.
    var musicReviewRequired: Bool {
        musicSurveys.contains { $0.matchKind == .needsReview }
    }

    /// Files classified as safe to import (no exact duplicate, no
    /// metadata collision, no survey failure).
    var musicImportReadyFiles: [URL] {
        zip(musicImportFiles, musicSurveys).compactMap { file, survey in
            survey.matchKind == .noCandidate ? file : nil
        }
    }

    /// Files the user must explicitly resolve before import: metadata
    /// collisions. Exact duplicates and survey failures never enter the
    /// import list at all.
    var musicFilesNeedingReview: [URL] {
        zip(musicImportFiles, musicSurveys).compactMap { file, survey in
            survey.matchKind == .needsReview ? file : nil
        }
    }

    /// Import the surveyed candidates the user confirmed. The engine's
    /// fresh in-call survey governs every file; explicit user resolution
    /// (`reviewResolved`) is honored only for still-ambiguous surveys —
    /// exact duplicates are never overridden.
    func importToMusic(reviewResolved: Bool) async {
        let files = musicImportReadyFiles + (reviewResolved ? musicFilesNeedingReview : [])
        guard !files.isEmpty else {
            step = .musicResults
            return
        }
        generation &+= 1
        let revision = generation
        step = .musicImporting
        importingIndex = nil

        let journal = MusicImportJournal(directory: musicJournalDirectory)
        let (priorRecords, _) = (try? journal.load()) ?? ([], nil)

        // The import re-reads the candidate files (hash + Music.app's
        // own `add` reads the file via Apple Events). Claim the grants
        // for the whole import run.
        let claims = SecurityScopedClaims(claiming: securityScopedAccess)
        defer { claims.release() }
        for url in grantedFileURLs { claims.claim(url) }
        if let outputDirectory = grantedOutputDirectory ?? outputDirectory {
            claims.claim(outputDirectory)
        }

        for (index, file) in files.enumerated() {
            importingIndex = index
            let titleQuery = MusicImportEngine.titleQuery(forFileAt: file.path)
            let outcome = await musicEngine.importFile(file: file,
                                                      titleQuery: titleQuery,
                                                      journal: journal,
                                                      priorRecords: priorRecords,
                                                      reviewResolved: reviewResolved)
            guard revision == generation else { return }
            musicOutcomes.append(outcome)
        }
        importingIndex = nil
        step = .musicResults
    }

    /// Import only the confirmed files, keeping a review-free path when
    /// nothing needs resolution.
    func importToMusic() async {
        if musicReviewRequired {
            await importToMusic(reviewResolved: true)
        } else {
            await importToMusic(reviewResolved: false)
        }
    }

    /// Per-file outcome rows for the results screen.
    var musicResultsSummary: (imported: Int, skipped: Int, review: Int, failed: Int) {
        var imported = 0, skipped = 0, review = 0, failed = 0
        for outcome in musicOutcomes {
            switch outcome.status {
            case .imported: imported &+= 1
            case .skippedDuplicate: skipped &+= 1
            case .review: review &+= 1
            case .failed: failed &+= 1
            }
        }
        return (imported, skipped, review, failed)
    }

    // MARK: - Reset

    func reset() {
        generation &+= 1
        grantedFileURLs = []
        grantedOutputDirectory = nil
        selectedFiles = []
        selectedCount = 0
        rows = []
        reviewDecisions = [:]
        outcomes = []
        outputDirectory = nil
        journalWarning = nil
        convertingIndex = nil
        musicImportFiles = []
        musicSurveys = []
        musicSurveyFailures = []
        musicOutcomes = []
        musicJournalWarning = nil
        importingIndex = nil
        step = .select
    }
}
