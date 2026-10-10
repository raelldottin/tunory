import XCTest

@MainActor
final class WorkflowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ scenario: String = "normal", largeText: Bool = false, dark: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-validation", scenario]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if dark { app.launchArguments += ["--ui-dark"] }
        app.launch()
        let banner = app.descendants(matching: .any).matching(identifier: "validation.banner").firstMatch
        guard banner.waitForExistence(timeout: 10) else {
            XCTFail("UI tests must never interact with an app that is not in explicit, network-free validation mode.")
            throw ValidationError.missingBanner
        }
        XCTAssertFalse(app.descendants(matching: .any)["validation.setupError"].exists)
        #if os(iOS)
        for title in ["Status", "Import", "Recovery"] {
            let tab = app.buttons[title].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 5), "Native tab must be available: \(title)")
            XCTAssertTrue(tab.isHittable)
        }
        #endif
        return app
    }

    private enum ValidationError: Error { case missingBanner, missingControl }

    private func dismissKeyboard(_ app: XCUIApplication) {
        #if os(iOS)
        let done = app.buttons["import.dismissKeyboard"]
        if done.exists && done.isHittable { done.tap() }
        #endif
    }

    private func cancelConfirmation(_ app: XCUIApplication, button: String) throws {
        let cancel = app.buttons[button].firstMatch
        if cancel.exists && cancel.isHittable {
            interact(cancel)
            return
        }
        // Native popovers omit the cancel row; their outside-dismiss region is the cancel action.
        let outside = app.descendants(matching: .any)["PopoverDismissRegion"]
        guard outside.waitForExistence(timeout: 5) else {
            XCTFail("Expected native cancel control or popover dismissal region.")
            throw ValidationError.missingControl
        }
        outside.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8)).tap()
    }

    private func interact(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func control(_ identifier: String, in app: XCUIApplication) throws -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        for _ in 0..<12 {
            if element.exists && element.isHittable { return element }
            #if os(macOS)
            app.scrollViews["screen.scroll"].scroll(byDeltaX: 0, deltaY: -350)
            #else
            let scroll = app.scrollViews["screen.scroll"]
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.8))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.25))
            start.press(forDuration: 0.05, thenDragTo: end)
            #endif
        }
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Missing control accessibility tree"
        tree.lifetime = .keepAlways
        add(tree)
        capture("Missing control \(identifier)", app: app)
        XCTFail("Expected accessible control: \(identifier)")
        throw ValidationError.missingControl
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func configure(_ app: XCUIApplication) throws {
        interact(try control("status.openImport", in: app))
        let editor = try control("import.pastedText", in: app)
        XCTAssertEqual(editor.label, "Song list")
        interact(editor)
        editor.typeText("First Song")
        dismissKeyboard(app)
        interact(try control("import.parse", in: app))
        interact(try control("import.resolve", in: app))
        _ = try control("import.candidate.1.101", in: app)
        capture("Recording choices with full identities", app: app)
        interact(try control("import.candidate.1.101", in: app))
        let next = try control("import.continue", in: app)
        XCTAssertTrue(next.isEnabled)
        interact(next)
        XCTAssertTrue(app.textFields["configure.playlistName"].waitForExistence(timeout: 5))
        capture("Explicit write boundary", app: app)
    }

    private func confirmImport(_ app: XCUIApplication) throws {
        interact(try control("configure.start", in: app))
        XCTAssertTrue(app.sheets["Start this Apple Music import?"].waitForExistence(timeout: 5))
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Start Import", "configure.start"))
            .allElementsBoundByIndex.first { $0.isHittable }
        guard let confirm else { XCTFail("Expected native write confirmation."); throw ValidationError.missingControl }
        interact(confirm)
    }

    func testReviewAndNativeWriteConfirmationCanBeCanceled() throws {
        let app = try launch()
        capture("Status and read-only boundaries", app: app)
        try configure(app)
        interact(try control("configure.start", in: app))
        XCTAssertTrue(app.sheets["Start this Apple Music import?"].waitForExistence(timeout: 5))
        capture("Native import confirmation", app: app)
        try cancelConfirmation(app, button: "Cancel")
        XCTAssertTrue(app.textFields["configure.playlistName"].exists)
        XCTAssertFalse(app.buttons["transaction.viewResults"].exists)
    }

    func testConfirmedFixtureImportShowsVerifiedResults() throws {
        let app = try launch()
        try configure(app)
        try confirmImport(app)
        let results = app.buttons["transaction.viewResults"]
        XCTAssertTrue(results.waitForExistence(timeout: 10))
        capture("Canonical transaction phase evidence", app: app)
        interact(try control("transaction.viewResults", in: app))
        XCTAssertTrue(app.staticTexts["Playlist complete"].waitForExistence(timeout: 5))
        capture("Verified fixture results", app: app)
        XCTAssertTrue(app.buttons["results.restart"].exists)
    }

    func testFailedFixtureWriteCannotShowSuccessfulAddBadge() throws {
        let app = try launch("stopped-write")
        try configure(app)
        try confirmImport(app)
        XCTAssertTrue(app.buttons["transaction.viewResults"].waitForExistence(timeout: 10))
        interact(try control("transaction.viewResults", in: app))
        XCTAssertTrue(app.staticTexts["Finished with problems"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Library add accepted"].exists)
        XCTAssertFalse(app.staticTexts["Playlist append accepted"].exists)
        capture("Stopped transaction and per-recording error", app: app)
    }

    func testCatalogFailureHasAnExplicitRetry() throws {
        let app = try launch("catalog-failure")
        interact(try control("status.openImport", in: app))
        let editor = try control("import.pastedText", in: app)
        interact(editor)
        editor.typeText("First Song")
        dismissKeyboard(app)
        interact(try control("import.parse", in: app))
        interact(try control("import.resolve", in: app))
        XCTAssertTrue(app.descendants(matching: .any)["import.catalogError"].waitForExistence(timeout: 10))
        let retry = try control("import.retryResolution", in: app)
        XCTAssertTrue(retry.isEnabled)
        XCTAssertFalse(app.buttons["import.continue"].isEnabled)
        capture("Catalog failure and safe retry", app: app)
    }

    func testFailedFinalReadbackExplainsDuplicatesAndCannotShowCompletion() throws {
        let app = try launch("failed-readback")
        try configure(app)
        try confirmImport(app)
        interact(try control("transaction.viewResults", in: app))
        XCTAssertTrue(app.staticTexts["Finished with problems"].exists)
        XCTAssertFalse(app.staticTexts["Playlist complete"].exists)
        XCTAssertTrue(try control("results.verificationFailure", in: app).exists)
        XCTAssertTrue(app.staticTexts["Duplicated recording IDs: 101."].exists)
        capture("Failed final readback with duplicate identity", app: app)
    }

    func testUnreadableCheckpointDismissalRequiresConfirmation() throws {
        let app = try launch("corrupt-recovery")
        interact(try control("recovery.dismiss", in: app))
        XCTAssertTrue(app.sheets["Dismiss saved import progress?"].waitForExistence(timeout: 5))
        capture("Native checkpoint dismissal confirmation", app: app)
        try cancelConfirmation(app, button: "Keep Saved Progress")
        XCTAssertTrue(app.buttons["recovery.dismiss"].exists)
    }

    func testDivergedRecoveryStopsAndKeepsRetryAvailable() throws {
        let app = try launch("diverged-recovery")
        capture("Recovery checkpoint", app: app)
        interact(try control("recovery.resume", in: app))
        XCTAssertTrue(app.buttons["recovery.retry"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["recovery.error"].exists)
        capture("Divergence without writes", app: app)
    }

    func testRecoveryFixtureCompletesWithPerRecordingEvidence() throws {
        let app = try launch("recovery")
        interact(try control("recovery.resume", in: app))
        XCTAssertTrue(app.staticTexts["Recovered playlist verified"].waitForExistence(timeout: 10))
        capture("Verified recovery results", app: app)
        XCTAssertTrue(app.descendants(matching: .any)["results.recording.1"].exists)
    }

    func testDeniedPermissionHasActionableStatus() throws {
        let app = try launch("denied")
        XCTAssertTrue(app.buttons["status.refreshAccess"].exists)
        XCTAssertFalse(app.buttons["status.testConnectivity"].isEnabled)
        capture("Denied access", app: app)
    }

    func testRestrictedPermissionExplainsTheSafeNextAction() throws {
        let app = try launch("restricted")
        XCTAssertTrue(app.staticTexts["Access restricted"].exists)
        XCTAssertFalse(app.buttons["status.testConnectivity"].isEnabled)
        capture("Restricted access", app: app)
    }

    #if os(iOS)
    func testDarkAppearanceReviewAndRecoveryRemainNavigable() throws {
        let app = try launch(dark: true)
        capture("Dark appearance status", app: app)
        try configure(app)
        app.terminate()
        let recovery = try launch("recovery", dark: true)
        XCTAssertTrue(try control("recovery.resume", in: recovery).isHittable)
        capture("Dark appearance recovery", app: recovery)
    }

    func testAccessibilityTextActuallyEnlargesAndRemainsNavigable() throws {
        let normal = try launch()
        let height = normal.staticTexts["status.authorization"].firstMatch.frame.height
        normal.terminate()
        let large = try launch(largeText: true)
        XCTAssertGreaterThan(large.staticTexts["status.authorization"].firstMatch.frame.height, height)
        capture("Accessibility XXXL status", app: large)
        try configure(large)
        capture("Accessibility XXXL configuration", app: large)
        try confirmImport(large)
        interact(try control("transaction.viewResults", in: large))
        XCTAssertTrue(large.staticTexts["Playlist complete"].exists)
        capture("Accessibility XXXL results", app: large)
    }
    #endif
}
