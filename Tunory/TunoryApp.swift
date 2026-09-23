import SwiftUI
import MusicKit
import Foundation

// Tunory has two run modes:
//
//  • GUI (default): shows the existing ContentView.
//  • CLI (Hermes orchestration): when launched with a leading command argument:
//
//        Tunory authorize          -> calls MusicAuthorization.request() once,
//                                     prints "authorized"/"denied"/"restricted"/"notDetermined"
//        Tunory status             -> prints current MusicAuthorization status
//        Tunory call METHOD PATH [json-body-file]
//                                   -> performs Apple Music REST call using
//                                      developer token from $AM_DEV_TOKEN_FILE
//                                      plus MusicKit-fetched Music User Token.
//                                      Response JSON to stdout, HTTP status to stderr.
//
//     In CLI mode the app activates, runs the operation, and exits.
//     In every mode, tokens are never printed or logged.

@main
struct TunoryApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    var body: some View {
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, ["authorize","status","call"].contains(first) {
            CLIRunnerView(args: args)
        } else {
            ContentView()
        }
    }
}

struct CLIRunnerView: View {
    let args: [String]
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .task {
                let code = await runCLI(args: args)
                fflush(stdout)
                exit(code)
            }
    }
}

// MARK: - CLI plumbing

func devToken() throws -> String {
    guard let path = ProcessInfo.processInfo.environment["AM_DEV_TOKEN_FILE"],
          !path.isEmpty else {
        throw NSError(domain: "Tunory", code: 10,
                      userInfo: [NSLocalizedDescriptionKey: "AM_DEV_TOKEN_FILE not set"])
    }
    return try String(contentsOfFile: path, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func userToken() async throws -> String {
    let dt = try devToken()
    let provider = MusicUserTokenProvider()
    return try await provider.userToken(for: dt, options: MusicTokenRequestOptions())
}

func runCLI(args: [String]) async -> Int32 {
    guard let cmd = args.first else { return 2 }
    switch cmd {
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
            // Verify user token fetch works too; do not print the token.
            do {
                let _ = try await userToken()
                fputs("user-token acquired (redacted)\n", stderr)
            } catch {
                fputs("user-token failed: \(error.localizedDescription)\n", stderr)
            }
            print("authorized")
            return 0
        case .denied: print("denied"); return 3
        case .restricted: print("restricted"); return 3
        case .notDetermined: print("notDetermined"); return 3
        @unknown default: print("unknown"); return 3
        }

    case "call":
        guard args.count >= 3 else {
            fputs("call METHOD PATH [json-body]\n", stderr)
            return 2
        }
        return await restCall(method: args[1], path: args[2],
                              bodyFile: args.count > 3 ? args[3] : nil)

    default:
        return 2
    }
}

func restCall(method: String, path: String, bodyFile: String?) async -> Int32 {
    guard MusicAuthorization.currentStatus == .authorized else {
        fputs("not authorized\n", stderr); return 3
    }
    guard let url = URL(string: "https://api.music.apple.com" + path) else {
        fputs("bad path\n", stderr); return 2
    }
    let dt: String, ut: String
    do { dt = try devToken() } catch {
        fputs("dev token missing\n", stderr); return 2
    }
    do { ut = try await userToken() } catch {
        fputs("user token failed: \(error.localizedDescription)\n", stderr); return 4
    }
    _ = dt // already fetched above; keep symmetric
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 90
    req.setValue("Bearer \(dt)", forHTTPHeaderField: "Authorization")
    req.setValue(ut, forHTTPHeaderField: "Music-User-Token")
    if let bf = bodyFile {
        req.httpBody = try? Data(contentsOf: URL(fileURLWithPath: bf))
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        fputs("__HTTP_STATUS__=\(http.statusCode)\n", stderr)
        return http.statusCode >= 400 ? 1 : 0
    } catch {
        fputs("request failed: \(error.localizedDescription)\n", stderr)
        return 5
    }
}
