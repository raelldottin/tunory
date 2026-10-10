import XCTest
import MusicKit
@testable import Tunory

@MainActor
final class MusicAuthViewModelTests: XCTestCase {
    func testRepeatedAuthorizationUsesOnePromptAndOneReadOnlyCheck() async {
        let gate = CatalogGate()
        var status: MusicAuthorization.Status = .notDetermined
        var prompts = 0
        var checks = 0
        let model = MusicAuthViewModel(currentStatus: { status }, requestAccess: {
            prompts += 1
            _ = await gate.check()
            status = .authorized
            return status
        }, checkCatalog: { checks += 1; return 1 })
        let request = Task { await model.requestAuthorization() }
        await gate.waitForRequest()
        await model.requestAuthorization()
        await model.runConnectivityCheck()
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(checks, 0)
        XCTAssertTrue(model.isRequestingAuthorization)
        await gate.release()
        await request.value
        XCTAssertEqual(model.state, .authorized)
        XCTAssertEqual(checks, 1)
        XCTAssertFalse(model.isRequestingAuthorization)
    }

    func testDeniedAuthorizationDoesNotCheckCatalog() async {
        var calls = 0
        let model = MusicAuthViewModel(currentStatus: { .denied }, checkCatalog: { calls += 1; return 1 })
        await model.runConnectivityCheck()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(model.state, .denied)
        XCTAssertEqual(model.connectivity, .notTested)
    }

    func testRepeatedConnectivityCheckUsesOneRequest() async {
        let gate = CatalogGate()
        let model = MusicAuthViewModel(currentStatus: { .authorized }, checkCatalog: { await gate.check() })
        let first = Task { await model.runConnectivityCheck() }
        await gate.waitForRequest()
        await model.runConnectivityCheck()
        let calls = await gate.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(model.isTestingConnectivity)
        await gate.release()
        await first.value
        XCTAssertEqual(model.connectivity, .reachable(albums: 1))
        XCTAssertFalse(model.isTestingConnectivity)
    }

    func testAuthorizationLossRejectsLateConnectivity() async {
        let gate = CatalogGate()
        var status: MusicAuthorization.Status = .authorized
        let model = MusicAuthViewModel(currentStatus: { status }, checkCatalog: { await gate.check() })
        let request = Task { await model.runConnectivityCheck() }
        await gate.waitForRequest()
        status = .denied
        model.refresh()
        await gate.release()
        await request.value
        XCTAssertEqual(model.state, .denied)
        XCTAssertEqual(model.connectivity, .notTested)
    }

    func testLossAndRegrantStillRejectsPriorCatalogEvidence() async {
        let gate = CatalogGate()
        var status: MusicAuthorization.Status = .authorized
        let model = MusicAuthViewModel(currentStatus: { status }, checkCatalog: { await gate.check() })
        let request = Task { await model.runConnectivityCheck() }
        await gate.waitForRequest()
        status = .denied
        model.refresh()
        status = .authorized
        model.refresh()
        await gate.release()
        await request.value
        XCTAssertEqual(model.state, .authorized)
        XCTAssertEqual(model.connectivity, .notTested)
    }

    func testCanceledConnectivityRemainsUntested() async {
        let gate = CatalogGate()
        let model = MusicAuthViewModel(currentStatus: { .authorized }, checkCatalog: { await gate.check() })
        let request = Task { await model.runConnectivityCheck() }
        await gate.waitForRequest()
        request.cancel()
        await gate.release()
        await request.value
        XCTAssertFalse(model.isTestingConnectivity)
        XCTAssertEqual(model.connectivity, .notTested)
    }

    func testConnectivityErrorCanBeRetried() async {
        var calls = 0
        let model = MusicAuthViewModel(currentStatus: { .authorized }, checkCatalog: {
            calls += 1
            if calls == 1 { throw URLError(.notConnectedToInternet) }
            return 1
        })
        await model.runConnectivityCheck()
        guard case .unreachable = model.connectivity else { return XCTFail("Network failure must remain visible.") }
        await model.runConnectivityCheck()
        XCTAssertEqual(model.connectivity, .reachable(albums: 1))
    }
}

actor CatalogGate {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Int, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    func check() async -> Int {
        callCount += 1
        guard callCount == 1 else { return 1 }
        return await withCheckedContinuation {
            continuation = $0
            waiter?.resume()
            waiter = nil
        }
    }

    func waitForRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        continuation?.resume(returning: 1)
        continuation = nil
    }
}
