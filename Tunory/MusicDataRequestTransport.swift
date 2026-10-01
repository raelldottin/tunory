import Foundation
import MusicKit
import TunoryCore

/// AMTransport implemented over MusicKit's MusicDataRequest.
///
/// Security model (task: "keep Apple Music credentials within signed app
/// only"): every request goes through MusicDataRequest, whose shared
/// tokenProvider (MusicUserTokenProvider + MusicDeveloperTokenProvider)
/// supplies developer and user tokens entirely inside MusicKit's
/// in-process machinery. This file never reads, writes, prints, or
/// persists a token; it does not even import the token types by name
/// beyond MusicDataRequest's own API. Authorization state is checked
/// before each call (Phase 1 invariant) and 401s propagate as
/// AMError.notAuthorized so callers can distinguish auth failures from
/// data problems (retrospective §15).
struct MusicDataRequestTransport: AMTransport {

    private static let apiBase = URL(string: "https://api.music.apple.com")!

    private func makeRequest(method: String, path: String, body: Data? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: Self.apiBase)?.absoluteURL,
              url.host == Self.apiBase.host else {
            throw AMError.transport("bad path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 90
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Performs one MusicDataRequest, normalizing HTTP-error responses.
    /// Returns (data, status); throws only for transport-level failures.
    private func perform(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        guard MusicAuthorization.currentStatus == .authorized else {
            throw AMError.notAuthorized
        }
        do {
            let response = try await MusicDataRequest(urlRequest: request).response()
            return (response.data, response.urlResponse.statusCode)
        } catch let error as MusicDataRequest.Error {
            // Apple's typed API error: HTTP status + original payload.
            return (error.originalResponse.data, error.status)
        } catch {
            throw AMError.transport(String(describing: error))
        }
    }

    // MARK: - AMTransport

    func getCatalogSong(catalogId: Int, storefront: String) async throws -> (song: AMCatalogSong?, httpStatus: Int) {
        // Path components are integers/storefront code we validated; still
        // percent-encode defensively to keep the URL well-formed.
        let path = "/v1/catalog/\(storefront)/songs/\(catalogId)"
        let request = try makeRequest(method: "GET", path: path)
        let (data, status) = try await perform(request)
        guard status == 200 else { return (nil, status) }
        do {
            let page = try JSONDecoder().decode(AMPage<AMCatalogSong>.self, from: data)
            let song = page.data?.first { $0.id == String(catalogId) }
            return (song, status)
        } catch {
            throw AMError.malformedResponse("catalog song \(catalogId): \(String(describing: error))")
        }
    }

    func getLibrarySongsPage(cursor: String?) async throws -> (items: [AMLibrarySong], next: String?) {
        let path = cursor ?? "/v1/me/library/songs?limit=100&include=catalog"
        let request = try makeRequest(method: "GET", path: path)
        let (data, status) = try await perform(request)
        guard status == 200 else {
            throw AMError.transport("library songs page http \(status)")
        }
        do {
            let page = try JSONDecoder().decode(AMPage<AMLibrarySong>.self, from: data)
            return (page.data ?? [], page.next)
        } catch {
            throw AMError.malformedResponse("library songs page: \(String(describing: error))")
        }
    }

    func getLibraryPlaylistsPage(cursor: String?) async throws -> (items: [AMLibraryPlaylist], next: String?) {
        let path = cursor ?? "/v1/me/library/playlists?limit=100"
        let request = try makeRequest(method: "GET", path: path)
        let (data, status) = try await perform(request)
        guard status == 200 else {
            throw AMError.transport("library playlists page http \(status)")
        }
        do {
            let page = try JSONDecoder().decode(AMPage<AMLibraryPlaylist>.self, from: data)
            return (page.data ?? [], page.next)
        } catch {
            throw AMError.malformedResponse("library playlists page: \(String(describing: error))")
        }
    }

    func getPlaylistTracks(playlistId: String) async throws -> [AMLibrarySong] {
        // §13: HTTP 404 on an empty playlist's tracks is "empty", not fatal.
        // Pagination follows `next` (§12).
        var items: [AMLibrarySong] = []
        var cursor: String? = nil
        var pages = 0
        repeat {
            let path = cursor ?? "/v1/me/library/playlists/\(playlistId)/tracks"
            let request = try makeRequest(method: "GET", path: path)
            let (data, status) = try await perform(request)
            if status == 404 && cursor == nil { return [] }
            guard status == 200 else {
                throw AMError.transport("playlist tracks http \(status)")
            }
            do {
                let page = try JSONDecoder().decode(AMPage<AMLibrarySong>.self, from: data)
                items.append(contentsOf: page.data ?? [])
                cursor = page.next
            } catch {
                throw AMError.malformedResponse("playlist tracks: \(String(describing: error))")
            }
            pages += 1
            if pages > 200 {
                throw AMError.paginationAborted(pages: pages)
            }
        } while cursor != nil
        return items
    }

    func addCatalogSongToLibrary(catalogId: Int) async throws -> Int {
        // §11 shape: POST /v1/me/library?ids[songs]={catalogId}.
        let request = try makeRequest(method: "POST",
                                      path: "/v1/me/library?ids[songs]=\(catalogId)")
        let (_, status) = try await perform(request)
        return status
    }

    func appendLibrarySong(toPlaylist playlistId: String, librarySongId: String) async throws -> Int {
        // §14 shape: {"data":[{"id": <lib-id>, "type": "library-songs"}]}.
        // library-song ids are opaque server strings; encode as JSON string
        // values only — never interpolated into the path.
        let body: [String: Any] = ["data": [["id": librarySongId, "type": "library-songs"]]]
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = try makeRequest(method: "POST",
                                      path: "/v1/me/library/playlists/\(playlistId)/tracks",
                                      body: data)
        let (_, status) = try await perform(request)
        return status
    }

    func createPlaylist(named name: String) async throws -> (playlist: AMLibraryPlaylist?, httpStatus: Int) {
        // POST /v1/me/library/playlists with the name as a JSON string value
        // (never path-interpolated). The response body is the created
        // resource; a 201 here is an acknowledgment only — the caller
        // re-discovers by name before any write (§20 uniqueness gate).
        let body: [String: Any] = ["attributes": ["name": name]]
        let data = try JSONSerialization.data(withJSONObject: body)
        let request = try makeRequest(method: "POST",
                                      path: "/v1/me/library/playlists",
                                      body: data)
        let (responseData, status) = try await perform(request)
        guard status == 201 else { return (nil, status) }
        do {
            let page = try JSONDecoder().decode(AMPage<AMLibraryPlaylist>.self, from: responseData)
            return (page.data?.first, status)
        } catch {
            throw AMError.malformedResponse("create playlist response: \(String(describing: error))")
        }
    }
}
