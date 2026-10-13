import XCTest

@MainActor
final class WorkflowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ scenario: String = "normal", largeText: Bool = false, dark: Bool = false, light: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-validation", scenario]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if dark { app.launchArguments += ["--ui-dark"] }
        if light { app.launchArguments += ["--ui-light"] }
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

    private func expectConfirmation(_ title: String, in app: XCUIApplication) {
        #if os(macOS)
        let dialog = app.sheets["alert"].firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        XCTAssertTrue(dialog.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", title, title)).firstMatch.exists)
        #else
        XCTAssertTrue(app.sheets[title].waitForExistence(timeout: 5))
        #endif
        capture("Native confirmation: \(title)", app: app)
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        #if os(iOS)
        let done = app.buttons["import.dismissKeyboard"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isHittable)
        capture("Focused editor with navigation Done", app: app)
        done.tap()
        let dismissed = NSPredicate(format: "exists == false")
        let keyboardGone = XCTNSPredicateExpectation(predicate: dismissed, object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardGone], timeout: 5), .completed)
        capture("Keyboard dismissed by navigation Done", app: app)
        #endif
    }

    private func cancelConfirmation(_ app: XCUIApplication, button: String) throws {
        #if os(macOS)
        let cancel = app.sheets["alert"].buttons[button].firstMatch
        #else
        let cancel = app.buttons[button].firstMatch
        #endif
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
            #if os(iOS)
            let scroll = app.scrollViews["screen.scroll"]
            let scrollFrame = scroll.frame
            let top = max(scrollFrame.minY, app.navigationBars.firstMatch.frame.maxY)
            let bottom = min(scrollFrame.maxY, app.tabBars.firstMatch.frame.minY)
            var scrollTowardTop = false
            #endif
            if element.exists && element.isHittable {
                #if os(iOS)
                let frame = element.frame
                if frame.minY >= top && frame.maxY <= bottom { return element }
                if frame.height > bottom - top, frame.midY > top, frame.midY < bottom { return element }
                scrollTowardTop = frame.height > bottom - top ? frame.midY <= top : frame.minY < top
                #else
                return element
                #endif
            }
            #if os(macOS)
            app.scrollViews["screen.scroll"].scroll(byDeltaX: 0, deltaY: -350)
            #else
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: scrollTowardTop ? 0.25 : 0.8))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: scrollTowardTop ? 0.8 : 0.25))
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
        #if os(macOS)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
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
        expectConfirmation("Start this Apple Music import?", in: app)
        #if os(macOS)
        let confirmationButtons = app.sheets["alert"].buttons
        #else
        let confirmationButtons = app.buttons
        #endif
        let confirm = confirmationButtons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Start Import", "configure.start"))
            .allElementsBoundByIndex.first { $0.isHittable }
        guard let confirm else { XCTFail("Expected native write confirmation."); throw ValidationError.missingControl }
        interact(confirm)
    }

    func testReviewAndNativeWriteConfirmationCanBeCanceled() throws {
        let app = try launch()
        capture("Status and read-only boundaries", app: app)
        try configure(app)
        interact(try control("configure.start", in: app))
        expectConfirmation("Start this Apple Music import?", in: app)
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
        expectConfirmation("Dismiss saved import progress?", in: app)
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

    func testDarkAppearanceReviewAndRecoveryRemainNavigable() throws {
        let app = try launch(dark: true)
        capture("Dark appearance status", app: app)
        try configure(app)
        app.terminate()
        let recovery = try launch("recovery", dark: true)
        XCTAssertTrue(try control("recovery.resume", in: recovery).isHittable)
        capture("Dark appearance recovery", app: recovery)
    }

    func testLightAppearanceReviewAndRecoveryRemainNavigable() throws {
        let app = try launch(light: true)
        capture("Light appearance status", app: app)
        try configure(app)
        app.terminate()
        let recovery = try launch("recovery", light: true)
        XCTAssertTrue(try control("recovery.resume", in: recovery).isHittable)
        capture("Light appearance recovery", app: recovery)
    }

    #if os(macOS)
    func testKeyboardEditingAndEscapeCancelWrites() throws {
        let app = try launch()
        interact(try control("status.openImport", in: app))
        let editor = try control("import.pastedText", in: app)
        interact(editor)
        editor.typeText("Wrong title")
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText("First Song")
        XCTAssertEqual((editor.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), "First Song")
        capture("Keyboard replacement in labeled song editor", app: app)
        interact(try control("import.parse", in: app))
        interact(try control("import.resolve", in: app))
        interact(try control("import.candidate.1.101", in: app))
        interact(try control("import.continue", in: app))
        interact(try control("configure.start", in: app))
        expectConfirmation("Start this Apple Music import?", in: app)
        app.typeKey(.escape, modifierFlags: [])
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.sheets["alert"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(app.textFields["configure.playlistName"].exists)
        XCTAssertFalse(app.buttons["transaction.viewResults"].exists)
        capture("Escape retained configuration without writes", app: app)
    }
    #endif

    #if os(iOS)
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
