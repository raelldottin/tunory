// AMHelper — CLI tool to request MusicAuthorization and make Apple Music API calls.
//
// Usage:
//   AMHelper status
//   AMHelper authorize
//   AMHelper call METHOD PATH [json-body-file]
//
// Dev token is read from $AM_DEV_TOKEN_FILE (path to a file with the JWT).
// User token is obtained via MusicKit's MusicUserTokenProvider — never printed.

import Foundation
import MusicKit

enum HError: Error { case usage, devTokenMissing }

func devToken() throws -> String {
    guard let path = ProcessInfo.processInfo.environment["AM_DEV_TOKEN_FILE"],
          !path.isEmpty else { throw HError.devTokenMissing }
    return try String(contentsOfFile: path, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func userToken() async throws -> String {
    let provider = MusicUserTokenProvider()
    let dt = try devToken()
    return try await provider.userToken(for: dt, options: MusicTokenRequestOptions())
}

@main
struct Main {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else { exit(2) }
        args.removeFirst()
        let code: Int32
        switch cmd {
        case "status":
            switch MusicAuthorization.currentStatus {
            case .authorized: print("authorized"); code = 0
            case .denied: print("denied"); code = 3
            case .restricted: print("restricted"); code = 3
            case .notDetermined: print("notDetermined"); code = 3
            @unknown default: print("unknown"); code = 3
            }
        case "authorize":
            let st = await MusicAuthorization.request()
            if st == .authorized {
                do { _ = try await userToken(); fputs("user-token acquired (redacted)\n", stderr) }
                catch { fputs("user-token err: \(error.localizedDescription)\n", stderr) }
                print("authorized"); code = 0
            } else {
                print("\(st)"); code = 3
            }
        case "call":
            guard args.count >= 2 else { fputs("call METHOD PATH [body]\n", stderr); exit(2) }
            code = await restCall(method: args[0], path: args[1],
                                  bodyFile: args.count > 2 ? args[2] : nil)
        default:
            exit(2)
        }
        fflush(stdout)
        exit(code)
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
        fputs("dev token missing\n", stderr); return 2 }
    do { ut = try await userToken() } catch {
        let ne = error as NSError
        fputs("user token failed: domain=\(ne.domain) code=\(ne.code) info=\(ne.userInfo)\n", stderr)
        return 4
    }
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
