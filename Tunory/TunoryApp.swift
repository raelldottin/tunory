import SwiftUI
import MusicKit
import Foundation
import TunoryCore

// Tunory has two run modes:
//
//  • GUI (default): shows the existing ContentView.
//
//  • CLI (Hermes orchestration): when launched with a leading command verb.
//    Every verb below uses MusicKit's in-process authorization — no
//    developer-token files, no token values crossing any boundary:
//
//        Tunory status
//              -> prints current MusicAuthorization status.
//        Tunory authorize
//              -> requests MusicAuthorization, then verifies a real
//                 MusicDataRequest catalog read works (read-only ping).
//        Tunory catalog <manifest.json>
//              -> Gate 3: validates every manifest catalog id against the
//                 storefront catalog. Prints a JSON report.
//        Tunory preflight <manifest.json|-> <playlist-name>
//              -> discovers the playlist (unique name, canEdit), reads
//                 tracks, classifies state. Prints a JSON report; exit 3
//                 on any stop condition.
//        Tunory plan <manifest.json|-> <playlist-name>
//              -> preflight + library enumeration; prints the immutable
//                 append plan JSON (no writes).
//        Tunory append <plan.json|->
//              -> executes the plan exactly (append-only, one per step,
//                 fresh re-preflight first). Prints per-step outcomes.
//        Tunory verify <manifest.json|-> <playlist-name>
//              -> independent fresh read-back of catalog + playlist.
//                 Prints the verification JSON; exit 3 if not verified.
//        Tunory transact <manifest.json|-> <playlist-name> [--checkpoint <path>]
//              -> full §20 library-first transaction in one invocation:
//                 catalog gate, preflight, reconcile, add-missing, fresh
//                 library verify, plan, append-only execute with per-step
//                 verification, and the independent final read-back.
//                 Prints one JSON line per phase; exit 0 only when the
//                 final read-back verifies the exact manifest sequence.
//                 On an interrupted execute, prints (and, with
//                 --checkpoint, persists) a credential-free checkpoint.
//        Tunory recover <checkpoint.json|->
//              -> restart reconciliation: loads the checkpoint, reads
//                 Apple's actual state by fresh reads, then either
//                 reports alreadyComplete, stops with the exact
//                 divergence, or resumes the SAME canonical §20
//                 transaction re-derived from actual state.
//        Tunory run <manifest.json|-> <playlist-name> [--result <path>]
//              -> Phase 7 Hermes automation envelope: runs the same
//                 canonical §20 transaction, then writes ONE structured
//                 result file (AutomationResult JSON: playlist identity +
//                 state, per-recording track rows with Library status,
//                 playlist status, positions, and errors, phase labels,
//                 and the checkpoint for an interrupted execute). With
//                 --result the file is written to that path AND printed to
//                 stdout; without it the file goes to stdout only.
//                 Exit codes: 0 verified; 2 usage/manifest error; 3 stop
//                 condition or not verified; 4 result file not writable.
//
//    Arguments taking a path accept "-" to read stdin (the sandboxed app
//    cannot read arbitrary filesystem paths; orchestrators pipe content).
//    CLI verbs never start the GUI: dispatch happens before any UI machinery
//    is created (no SwiftUI .task dependence — that path is not guaranteed
//    in headless contexts and made orchestration nondeterministic).
//    In every mode, tokens are never printed or logged: all Apple Music
//    traffic goes through MusicDataRequest, whose shared tokenProvider
//    keeps developer and user credentials inside MusicKit.

@main
enum LaunchMode {
    static func main() {
        // Deterministic dispatch decided once, before any UI machinery:
        // a leading CLI verb never starts SwiftUI/AppKit — no window can
        // appear, and nothing can interact with a transaction mid-run.
        // The verb runs on a task; the main thread blocks until the
        // process exits with the verb's exit code.
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, CLI.supportedVerbs.contains(first) {
            Task {
                let code = await CLI.run(args: args)
                fflush(stdout)
                fflush(stderr)
                exit(code)   // terminates the process
            }
            // Service the main queue (MusicKit hops through it) until the
            // task above exits the process. dispatchMain never returns.
            dispatchMain()
        } else {
            TunoryApp.main()
        }
    }
}

struct TunoryApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    var body: some View {
        ContentView()
    }
}

// MARK: - CLI plumbing

enum CLI {

    static let supportedVerbs = ["status", "authorize", "catalog", "preflight",
                                 "plan", "append", "verify", "transact", "recover",
                                 "run", "local-import", "music-import"]

    /// Optional out-of-band argument `--checkpoint <path>` (extracted from
    /// args in `run`): where `transact` persists its interrupted-execute
    /// checkpoint. Kept out of the positional grammar so the canonical
    /// verbs stay stable.
    enum Environment {
        static var checkpointPath: String?
        /// `--result <path>` for the `run` verb (Phase 7): where the
        /// structured AutomationResult file is written.
        static var resultPath: String?
    }

    /// Reads raw bytes from a file path, or from stdin when the path is "-"
    /// (the app is sandboxed: arbitrary paths are unreadable; orchestrators
    /// pipe content through stdin).
    private static func readData(_ path: String) -> Data? {
        if path == "-" {
            return FileHandle.standardInput.readDataToEndOfFile()
        }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    private static func require(_ condition: Bool, _ message: String) -> Int32? {
        condition ? nil : { fputs("error: \(message)\n", stderr); return 2 }()
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            print("{\"encoding_error\": true}")
        }
    }

    static func run(args: [String]) async -> Int32 {
        // Extract out-of-band flags before positional dispatch (verb first).
        var positional: [String] = []
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg == "--checkpoint", let path = iterator.next() {
                Environment.checkpointPath = path
            } else if arg == "--result", let path = iterator.next() {
                Environment.resultPath = path
            } else {
                positional.append(arg)
            }
        }
        let args = positional
        guard let verb = args.first else { return 2 }
        switch verb {
        case "status":
            switch MusicAuthorization.currentStatus {
            case .authorized: print("authorized"); return 0
            case .denied: print("denied"); return 3
            case .restricted: print("restricted"); return 3
            case .notDetermined: print("notDetermined"); return 3
            @unknown default: print("unknown"); return 3
            }

        case "authorize":
            let status = await MusicAuthorization.request()
            switch status {
            case .authorized:
                // Prove the full in-process credential chain works with a
                // read-only catalog ping through MusicDataRequest. Tokens
                // never leave MusicKit.
                if let url = URL(string: "https://api.music.apple.com/v1/catalog/us/songs/1436241421") {
                    do {
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 30
                        _ = try await MusicDataRequest(urlRequest: request).response()
                        fputs("data-request ping ok\n", stderr)
                    } catch {
                        fputs("data-request ping failed: \(String(describing: error))\n", stderr)
                        print("authorized")
                        return 0
                    }
                }
                print("authorized")
                return 0
            case .denied: print("denied"); return 3
            case .restricted: print("restricted"); return 3
            case .notDetermined: print("notDetermined"); return 3
            @unknown default: print("unknown"); return 3
            }

        case "catalog":
            guard args.count == 2 else { fputs("catalog <manifest.json>\n", stderr); return 2 }
            guard let manifest = loadManifest(args[1]) else { return 2 }
            guard await ensureAuthorized() else { return 3 }
            let engine = RESTEngine(transport: MusicDataRequestTransport())
            let report = await engine.validateCatalog(manifest: manifest)
            printJSON(report)
            return report.passed ? 0 : 3

        case "preflight":
            guard args.count == 3 else { fputs("preflight <manifest.json|-> <playlist-name>\n", stderr); return 2 }
            guard let manifest = loadManifest(args[1]),
                  !args[2].isEmpty else { return 2 }
            let name = args[2]
            guard await ensureAuthorized() else { return 3 }
            let engine = RESTEngine(transport: MusicDataRequestTransport())
            let result = await engine.preflightPlaylist(named: name, manifest: manifest)
            switch result {
            case .ok(let playlist, let state, let missing):
                printJSON(PreflightReport(playlist: playlist, state: state,
                                          missingCatalogIds: missing))
                return 0
            case .stop(let error):
                printJSON(ErrorReport(error: error))
                return 3
            }

        case "plan":
            guard args.count == 3 else { fputs("plan <manifest.json|-> <playlist-name>\n", stderr); return 2 }
            guard let manifest = loadManifest(args[1]),
                  !args[2].isEmpty else { return 2 }
            let name = args[2]
            guard await ensureAuthorized() else { return 3 }
            let engine = RESTEngine(transport: MusicDataRequestTransport())
            let preflight = await engine.preflightPlaylist(named: name, manifest: manifest)
            guard case .ok = preflight else {
                if case .stop(let error) = preflight {
                    printJSON(ErrorReport(error: error))
                }
                return 3
            }
            let library: [Int: String]
            do {
                library = try await engine.enumerateLibrary()
            } catch {
                printJSON(ErrorReport(error: .transport(String(describing: error))))
                return 4
            }
            switch RESTEngine.deriveAppendPlan(preflight: preflight, manifest: manifest,
                                               library: library) {
            case .success(let plan):
                printJSON(plan)
                return 0
            case .failure(let error):
                printJSON(ErrorReport(error: error))
                return 3
            }

        case "append":
            guard args.count == 2 else { fputs("append <plan.json>\n", stderr); return 2 }
            guard let data = readData(args[1]),
                  let plan = try? JSONDecoder().decode(AppendPlan.self, from: data) else {
                fputs("error: unreadable plan file\n", stderr)
                return 2
            }
            guard await ensureAuthorized() else { return 3 }
            let engine = RESTEngine(transport: MusicDataRequestTransport())
            do {
                let outcomes = try await engine.executeAppendPlan(plan)
                printJSON(ExecutionReport(playlistId: plan.playlistId,
                                          playlistName: plan.playlistName,
                                          stepCount: plan.steps.count,
                                          outcomes: outcomes))
                return 0
            } catch let error as AMError {
                printJSON(ErrorReport(error: error))
                return 3
            } catch {
                printJSON(ErrorReport(error: .transport(String(describing: error))))
                return 4
            }

        case "verify":
            guard args.count == 3 else { fputs("verify <manifest.json|-> <playlist-name>\n", stderr); return 3 }
            guard let manifest = loadManifest(args[1]),
                  !args[2].isEmpty else { return 2 }
            let name = args[2]
            guard await ensureAuthorized() else { return 3 }
            let engine = RESTEngine(transport: MusicDataRequestTransport())
            let library: [Int: String]
            do {
                library = try await engine.enumerateLibrary()
            } catch {
                printJSON(ErrorReport(error: .transport(String(describing: error))))
                return 4
            }
            let reconciliation = RESTEngine.reconcile(manifest: manifest, library: library)
            let preflight = await engine.preflightPlaylist(named: name, manifest: manifest)
            guard case .ok(let playlist, _, _) = preflight else {
                if case .stop(let error) = preflight {
                    printJSON(ErrorReport(error: error))
                }
                return 3
            }
            let tracks: [AMLibrarySong]
            do {
                tracks = try await MusicDataRequestTransport().getPlaylistTracks(playlistId: playlist.id)
            } catch {
                printJSON(ErrorReport(error: .transport(String(describing: error))))
                return 4
            }
            let verification = RESTEngine.verifyPlaylist(playlistId: playlist.id,
                                                         manifest: manifest,
                                                         tracks: tracks,
                                                         shareUrl: playlist.shareUrl)
            printJSON(VerifyReport(libraryVerified: reconciliation.missing.isEmpty,
                                   libraryMissing: reconciliation.missing.map(\.catalogId),
                                   playlist: verification))
            return verification.verified && reconciliation.missing.isEmpty ? 0 : 3

        case "transact":
            // Full §20 library-first transaction in one invocation, now
            // driven by the canonical TransactionRunner (the same
            // sequence the GUI executes — one implementation, two
            // front-ends). One JSON line per phase; exit 0 only when the
            // final read-back verifies the exact manifest sequence.
            guard args.count == 3 else { fputs("transact <manifest.json|-> <playlist-name>\n", stderr); return 2 }
            guard let manifest = loadManifest(args[1]),
                  !args[2].isEmpty else { return 2 }
            let name = args[2]
            guard await ensureAuthorized() else { return 3 }
            let engine = RESTEngine(transport: MusicDataRequestTransport())
            let runner = TransactionRunner(engine: engine)
            let report = await runner.run(manifest: manifest, playlistName: name) { outcome in
                printJSON(TransactPhaseReport(phase: phaseLabel(outcome.kind),
                                              detail: outcome.report))
            }
            if let plan = report.plan, !plan.steps.isEmpty {
                printJSON(plan)
            }
            let libraryVerification = report.libraryVerification
            if let verification = libraryVerification {
                printJSON(verification)
            }
            if let readback = report.finalReadback {
                printJSON(VerifyReport(libraryVerified: libraryVerification?.verified == true,
                                       libraryMissing: libraryVerification?.missingCatalogIds ?? [],
                                       playlist: readback))
            }
            if let stopped = report.phases.last, stopped.kind == .stopped,
               let error = stopped.error {
                printJSON(ErrorReport(error: error))
                // Phase 6: an interrupted execute leaves a credential-free
                // checkpoint so a restart can reconcile against Apple's
                // actual state instead of guessing. Written to the
                // --checkpoint path when given, else printed to stdout.
                if stopped.appendOutcomes?.isEmpty == false,
                   let checkpoint = TransactionRunner.checkpoint(
                    forInterruptedExecuteIn: report,
                    capturedAtMillisSinceEpoch: Int64(Date().timeIntervalSince1970 * 1000)) {
                    if let checkpointPath = Environment.checkpointPath,
                       let data = try? JSONEncoder().encode(checkpoint) {
                        try? data.write(to: URL(fileURLWithPath: checkpointPath))
                        printJSON(checkpoint)
                        fputs("checkpoint written to \(checkpointPath)\n", stderr)
                    } else {
                        printJSON(checkpoint)
                    }
                }
                return 3
            }
            return report.succeeded ? 0 : 3

        case "recover":
            // Phase 6 restart reconciliation, now sequenced by the
            // canonical RecoveryFlow (Phase 9): loads a credential-free
            // checkpoint from a previous interrupted `transact`, reads
            // Apple's ACTUAL state by fresh reads only, and either
            //   • resumes by running the SAME canonical §20 transaction
            //     (which re-derives its own plan from reality), or
            //   • stops with the exact divergence when reality no longer
            //     honors the checkpoint's proven claims.
            // No write is attempted before the fresh read-back proves the
            // state safe (the runner's own preflight enforces §13/§20).
            // Output contract is unchanged from Phase 6: same lines, same
            // order, same exit codes.
            guard args.count == 2 else {
                fputs("recover <checkpoint.json|->\n", stderr)
                return 2
            }
            guard let data = readData(args[1]),
                  let checkpoint = try? JSONDecoder().decode(TransactionCheckpoint.self,
                                                             from: data) else {
                fputs("error: unreadable checkpoint\n", stderr)
                return 2
            }
            guard await ensureAuthorized() else { return 3 }
            // Canonical step 1: rebuild the manifest the checkpoint was
            // captured against (one validated path; corruption fails
            // closed here, before any network traffic).
            let manifest: ParsedManifest
            do {
                manifest = try RecoveryFlow.manifest(for: checkpoint)
            } catch {
                fputs("error: invalid checkpoint manifest: \(error)\n", stderr)
                return 2
            }
            // Canonical step 2: fresh preflight + pure reconciliation.
            let engine = RESTEngine(transport: MusicDataRequestTransport())
            switch await RecoveryFlow.decide(checkpoint: checkpoint,
                                             manifest: manifest,
                                             engine: engine) {
            case .alreadyComplete:
                printJSON(RecoveryReport(action: "alreadyComplete",
                                         playlistId: checkpoint.playlistId,
                                         resumeFromPosition: nil,
                                         storedCatalogIds: checkpoint.manifestCatalogIds))
                return 0
            case .stop(let error):
                printJSON(ErrorReport(error: error))
                return 3
            case .resume(let info, let stored, let resumePos):
                printJSON(RecoveryReport(action: "resume",
                                         playlistId: info.id,
                                         resumeFromPosition: resumePos,
                                         storedCatalogIds: stored))
                fflush(stdout)
                // Canonical step 3: resume = the canonical runner over
                // fresh state. It re-runs every gate and re-derives the
                // plan; the checkpoint's role ended here (it was the
                // cross-check).
                let report = await RecoveryFlow.resume(
                    checkpoint: checkpoint, manifest: manifest, engine: engine) { outcome in
                    printJSON(TransactPhaseReport(phase: phaseLabel(outcome.kind),
                                                  detail: outcome.report))
                }
                if let plan = report.plan, !plan.steps.isEmpty {
                    printJSON(plan)
                }
                if let verification = report.libraryVerification {
                    printJSON(verification)
                }
                if let readback = report.finalReadback {
                    printJSON(VerifyReport(libraryVerified: report.libraryVerification?.verified == true,
                                           libraryMissing: report.libraryVerification?.missingCatalogIds ?? [],
                                           playlist: readback))
                }
                if let stopped = report.phases.last, stopped.kind == .stopped,
                   let error = stopped.error {
                    printJSON(ErrorReport(error: error))
                    return 3
                }
                return report.succeeded ? 0 : 3
            }

        case "run":
            return await runAutomation(args: args)

        case "local-import":
            // Headless local-file import, driven by the SAME canonical
            // LocalImportEngine the GUI uses (one implementation, two
            // front-ends). Plans from actual content — never filenames —
            // and never touches the Apple Music library: converted copies
            // land in the requested output directory; adding them to
            // Music.app stays a manual operator action.
            //   local-import <output-dir> [--profile aac256|alac]
            //                [--duplicates keep|skip] <file-or-dir>...
            // Exit 0 only when every processed entry ends converted,
            // skipped-valid, or passthrough; conflicts/undecodables
            // exit 3 without writing those files.
            return await runLocalImport(args: args)

        case "music-import":
            // Headless Music.app library import, driven by the SAME
            // canonical MusicImportEngine the GUI uses (one
            // implementation, two front-ends). Read-only survey first;
            // exact duplicates are always skipped; metadata collisions
            // are reported and require --resolve-review to import;
            // every add is journaled before it is issued.
            //   music-import [--resolve-review] <file>...
            // Exit 0 only when every file ends imported or
            // skipped-duplicate; review/failed outcomes exit 3.
            return await runMusicImport(args: args)

        default:
            return 2
        }
    }

    // MARK: - Phase 7: Hermes automation envelope (`run` verb)
    //
    // The narrow automation interface: Hermes writes a validated manifest,
    // launches the signed app with `run`, and reads back ONE structured
    // result file. The result is derived by the canonical
    // AutomationResultBuilder from the canonical TransactionReport —
    // this verb never decides anything itself, and no token, developer
    // or user, ever crosses the process boundary (all Apple traffic stays
    // inside MusicDataRequestTransport).
    private static func runAutomation(args: [String]) async -> Int32 {
        // args[0] is the verb; positions 1-2 are the envelope.
        guard args.count == 3 else {
            fputs("run <manifest.json|-> <playlist-name> [--result <path>]\n", stderr)
            return 2
        }
        guard let manifest = loadManifest(args[1]),
              !args[2].isEmpty else { return 2 }
        let name = args[2]
        // No early authorization bail: the transport fail-closes with
        // AMError.notAuthorized (no prompt, deterministic), the runner
        // stops at the catalog gate with the typed §15 error, and the
        // derivation still produces the structured result file — the
        // automation contract requires the document on every
        // transactional invocation, authorization failures included.
        let engine = RESTEngine(transport: MusicDataRequestTransport())
        let runner = TransactionRunner(engine: engine)
        let report = await runner.run(manifest: manifest, playlistName: name)

        // Canonical, pure derivation of the structured result file.
        let result = AutomationResultBuilder.build(
            manifest: manifest,
            report: report,
            capturedAtMillisSinceEpoch: Int64(Date().timeIntervalSince1970 * 1000))

        // One JSON document, deterministically encoded (sorted keys).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(result),
              let text = String(data: data, encoding: .utf8) else {
            fputs("error: could not encode automation result\n", stderr)
            return 4
        }

        // Write the file when a --result path was given. The app is
        // sandboxed: a relative path resolves against the app's own
        // container; an absolute path must be somewhere the app may
        // write (its container — intermediate directories are created
        // here; an arbitrary user path is NOT writable without a
        // powerbox grant, which headless runs cannot present). Failure
        // to write the file is a distinct exit (4): the caller must know
        // the result never landed — stdout still carries the document.
        var fileWriteFailed = false
        if let resultPath = Environment.resultPath {
            let url = URL(fileURLWithPath: resultPath)
            do {
                // Materialize intermediate directories (container paths
                // like results/2026/run1.json).
                let directory = url.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic])
                fputs("result written to \(url.path)\n", stderr)
            } catch {
                fputs("error: cannot write result file \(resultPath): \(error)\n", stderr)
                fileWriteFailed = true
            }
        }

        // The same document goes to stdout in every case: stdout is the
        // always-available channel (Hermes may use either or both).
        print(text)

        if fileWriteFailed { return 4 }
        if !result.succeeded { return 3 }
        return 0
    }

    // MARK: - Local import verb (`local-import`)
    //
    // Thin adapter ONLY: every decision — passthrough, conversion profile,
    // destination guarding, duplicate classification, validation — is
    // derived by the canonical LocalImportEngine shared with the GUI. This
    // verb parses arguments, prints the engine's plan/outcomes, and derives
    // the exit code. It never re-implements a financial/media decision and
    // never touches the Apple Music library.
    private static func runLocalImport(args: [String]) async -> Int32 {
        // args[0] verb; args[1] output dir; then flags and at least one input.
        guard args.count >= 3 else {
            fputs("local-import <output-dir> [--profile aac256|alac] [--duplicates keep|skip] <file-or-dir>...\n", stderr)
            return 2
        }
        let outputDirectory = URL(fileURLWithPath: args[1])
        var profile = ConversionProfile.aac256
        var skipDuplicates = true

        var inputs: [URL] = []
        var index = 2
        while index < args.count {
            let arg = args[index]
            if arg == "--profile", index + 1 < args.count {
                guard let parsed = ConversionProfile(rawValue: args[index + 1]) else {
                    fputs("error: unknown profile '\(args[index + 1])' (aac256|alac)\n", stderr)
                    return 2
                }
                profile = parsed
                index += 2
            } else if arg == "--duplicates", index + 1 < args.count {
                switch args[index + 1] {
                case "skip": skipDuplicates = true
                case "keep": skipDuplicates = false
                default:
                    fputs("error: --duplicates expects keep|skip\n", stderr)
                    return 2
                }
                index += 2
            } else if arg.hasPrefix("--") {
                fputs("error: unknown flag '\(arg)'\n", stderr)
                return 2
            } else {
                inputs.append(URL(fileURLWithPath: arg))
                index += 1
            }
        }
        guard !inputs.isEmpty else {
            fputs("error: no input files or directories\n", stderr)
            return 2
        }
        guard FileManager.default.fileExists(atPath: outputDirectory.path) else {
            fputs("error: output directory does not exist: \(outputDirectory.path)\n", stderr)
            return 2
        }

        let engine = LocalImportEngine()

        // Partition into explicit files vs directories; each kind goes
        // through its own canonical planning surface.
        var fileInputs: [URL] = []
        var directoryInputs: [URL] = []
        for input in inputs {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                directoryInputs.append(input)
            } else {
                fileInputs.append(input)
            }
        }

        let journal = LocalImportJournal(directory: outputDirectory)
        let journalRecords = (try? journal.load())?.records ?? []

        var plans: [LocalImportPlan] = []
        if !fileInputs.isEmpty {
            plans.append(await engine.planFiles(files: fileInputs,
                                                 outputDirectory: outputDirectory,
                                                 profile: profile,
                                                 journalRecords: journalRecords))
        }
        for directory in directoryInputs {
            plans.append(await engine.planBatch(sourceRoot: directory,
                                                outputRoot: outputDirectory,
                                                profile: profile,
                                                journalRecords: journalRecords))
        }

        // Resolve dependencies between plans: the same file may appear via
        // an explicit path AND inside a selected directory; a destination
        // written by one plan changes the decision for the duplicate in a
        // later plan. Process sequentially: canonical planning re-derives
        // decisions from live state, so the engine itself stays the single
        // decision authority (verified after conversion too).
        func printPlanJSON(_ plan: LocalImportPlan) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(plan),
                  let text = String(data: data, encoding: .utf8) else {
                fputs("error: could not encode plan\n", stderr)
                return
            }
            print(text)
        }
        func printOutcomeJSON(_ outcome: ConversionOutcome) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(outcome),
                  let text = String(data: data, encoding: .utf8) else {
                fputs("error: could not encode outcome\n", stderr)
                return
            }
            print(text)
        }

        var exitCode: Int32 = 0
        for plan in plans {
            printPlanJSON(plan)
            for entry in plan.entries {
                if skipDuplicates, entry.duplicateOfIndex != nil {
                    // SHA-256-identical to an earlier entry in the SAME
                    // plan: keep the first copy, skip subsequent byte
                    // duplicates (engine already classified them via
                    // duplicateOfIndex; nothing is imported to a library
                    // here, so skipping only avoids redundant conversion).
                    continue
                }
                let outcome = await engine.convert(entry: entry,
                                                  profile: profile,
                                                  journal: journal)
                printOutcomeJSON(outcome)
                switch outcome.status {
                case .converted, .skippedValid, .passthrough:
                    break
                case .conflict, .failed:
                    exitCode = 3
                }
            }
        }
        return exitCode
    }

    // MARK: - Music import verb (`music-import`)
    //
    // Thin adapter ONLY: every decision — survey classification, duplicate
    // skipping, review gating, journaling — is derived by the canonical
    // MusicImportEngine shared with the GUI. This verb parses arguments,
    // prints the engine's surveys/outcomes as JSON lines, and derives the
    // exit code. It never re-implements a duplicate decision.
    private static func runMusicImport(args: [String]) async -> Int32 {
        // args[0] verb; then optional flags and at least one input file.
        guard args.count >= 2 else {
            fputs("music-import [--resolve-review] <file>...\n", stderr)
            return 2
        }

        var resolveReview = false
        var inputs: [URL] = []
        var index = 1
        while index < args.count {
            let arg = args[index]
            if arg == "--resolve-review" {
                resolveReview = true
                index += 1
            } else if arg.hasPrefix("--") {
                fputs("error: unknown flag '\(arg)'\n", stderr)
                return 2
            } else {
                inputs.append(URL(fileURLWithPath: arg))
                index += 1
            }
        }
        guard !inputs.isEmpty else {
            fputs("error: no input files\n", stderr)
            return 2
        }
        for input in inputs where !FileManager.default.fileExists(atPath: input.path) {
            fputs("error: input file does not exist: \(input.path)\n", stderr)
            return 2
        }

        let engine = MusicImportEngine(scripting: MusicAppScripting())
        let journal = MusicImportJournal(directory: MusicImportJournal.defaultDirectory())
        let (priorRecords, journalWarning) = (try? journal.load()) ?? ([], nil)
        if let journalWarning {
            // Fail-visible, not fatal: the journal being unreadable must
            // never silently enable a re-import the records would have
            // blocked.
            fputs("warning: \(journalWarning)\n", stderr)
        }

        func printJSONLine<T: Encodable>(_ value: T) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(value),
                  let text = String(data: data, encoding: .utf8) else {
                fputs("error: could not encode outcome\n", stderr)
                return
            }
            print(text)
        }

        var exitCode: Int32 = 0
        for file in inputs {
            // The engine's fresh in-call survey governs every file; the
            // --resolve-review flag is the CLI's explicit user resolution
            // for still-ambiguous surveys only (exact duplicates are
            // never overridden by it).
            let titleQuery = MusicImportEngine.titleQuery(forFileAt: file.path)
            let outcome = await engine.importFile(file: file,
                                                  titleQuery: titleQuery,
                                                  journal: journal,
                                                  priorRecords: priorRecords,
                                                  reviewResolved: resolveReview)
            printJSONLine(outcome)
            switch outcome.status {
            case .imported, .skippedDuplicate:
                break
            case .review, .failed:
                exitCode = 3
            }
        }
        return exitCode
    }

    private static func ensureAuthorized() async -> Bool {
        guard MusicAuthorization.currentStatus == .authorized else {
            fputs("not authorized\n", stderr)
            return false
        }
        return true
    }

    /// Stable CLI phase labels for the canonical runner kinds (matches the
    /// historical transact output contract).
    static func phaseLabel(_ kind: TransactionPhaseOutcome.Kind) -> String {
        switch kind {
        case .catalogGate: return "catalog"
        case .preflight: return "preflight"
        case .reconcile: return "reconcile"
        case .libraryAdd: return "library-add"
        case .libraryVerify: return "library-verify"
        case .plan: return "plan"
        case .execute: return "append"
        case .finalReadback: return "final-readback"
        case .stopped: return "stopped"
        }
    }

    private static func loadManifest(_ path: String) -> ParsedManifest? {
        guard let data = readData(path) else {
            fputs("error: cannot read manifest \(path)\n", stderr)
            return nil
        }
        do {
            return try ManifestParser.parse(data: data)
        } catch {
            fputs("error: invalid manifest: \(error)\n", stderr)
            return nil
        }
    }
}

// MARK: - CLI report envelopes

/// One line per transaction phase (streamed progress evidence).
struct TransactPhaseReport: Codable {
    let phase: String
    let detail: String
}

struct PreflightReport: Codable {
    let playlist: PlaylistInfo
    let state: PlaylistState
    let missingCatalogIds: [Int]
}

struct ErrorReport: Codable {
    struct ErrorPayload: Codable {
        let kind: String
        let detail: String
    }
    let error: ErrorPayload

    init(error: AMError) {
        let kind: String
        let detail: String
        switch error {
        case .transport(let message): kind = "transport"; detail = message
        case .notAuthorized: kind = "notAuthorized"; detail = "MusicKit authorization required"
        case .catalogLookupFailed(let id, let status):
            kind = "catalogLookupFailed"; detail = "catalog id \(id) http \(status)"
        case .libraryAddFailed(let id, let status):
            kind = "libraryAddFailed"; detail = "catalog id \(id) http \(status)"
        case .playlistCreationFailed(let status):
            kind = "playlistCreationFailed"; detail = "http \(status)"
        case .playlistAppendFailed(let pos, let id, _, let status):
            kind = "playlistAppendFailed"; detail = "pos \(pos) catalog id \(id) http \(status)"
        case .playlistNotFound(let name): kind = "playlistNotFound"; detail = name
        case .playlistAmbiguous(let name, let count):
            kind = "playlistAmbiguous"; detail = "\(name) matched \(count) playlists"
        case .playlistNotEditable(let id): kind = "playlistNotEditable"; detail = id
        case .playlistNotSafeToWrite(let id, let state):
            kind = "playlistNotSafeToWrite"; detail = "playlist \(id) state \(state)"
        case .librarySongMissing(let id):
            kind = "librarySongMissing"; detail = "catalog id \(id) absent from library"
        case .playlistVerificationFailed(let reason):
            kind = "playlistVerificationFailed"; detail = reason
        case .paginationAborted(let pages):
            kind = "paginationAborted"; detail = "stopped after \(pages) pages"
        case .malformedResponse(let message): kind = "malformedResponse"; detail = message
        case .checkpointDiverged(let reason):
            kind = "checkpointDiverged"; detail = reason
        }
        self.error = ErrorPayload(kind: kind, detail: detail)
    }
}

struct ExecutionReport: Codable {
    let playlistId: String
    let playlistName: String
    let stepCount: Int
    let outcomes: [AppendOutcome]
}

struct VerifyReport: Codable {
    let libraryVerified: Bool
    let libraryMissing: [Int]
    let playlist: PlaylistVerification
}

/// Reconcile decision for a persisted checkpoint (recover verb, phase 1).
struct RecoveryReport: Codable {
    let action: String
    let playlistId: String
    let resumeFromPosition: Int?
    let storedCatalogIds: [Int]
}
