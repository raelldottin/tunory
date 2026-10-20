import XCTest

// Temporary proof-only branch: this test must fail the hosted Core tests job.
final class CIFailurePropagationProofTests: XCTestCase {
    func testIntentionalFailureReachesCI() {
        XCTFail("Intentional CI failure-propagation proof; never merge this branch.")
    }
}
