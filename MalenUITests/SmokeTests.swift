import XCTest

final class SmokeTests: XCTestCase {
    /// Fixture template in a temp store → open it → paint screen → back → still in the gallery.
    @MainActor func testOpenArtworkPaintAndReturn() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestStore", "-uiTestFixedTemplate"]
        app.launch()

        let card = app.buttons["artworkCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["newPicture"].exists)
        card.tap()

        XCTAssertTrue(app.buttons["pot-1"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["pot-3"].exists)
        app.buttons["pot-2"].tap()
        XCTAssertTrue(app.buttons["pot-2"].isSelected)
        attach(app, "Malen")

        app.buttons["backToGallery"].tap()
        XCTAssertTrue(app.buttons["artworkCard"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "artworkCard").count, 1)
        attach(app, "Galerie")
    }

    /// Bundled motif → editor → „Los geht's“ → paint → back → the new picture is in the gallery.
    @MainActor func testCreateFromMotif() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-uiTestStore"]
        app.launch()

        let motif = app.buttons["motif-fox"]
        XCTAssertTrue(motif.waitForExistence(timeout: 10))
        try XCTSkipUnless(motif.isEnabled, "Motiv-Bilder fehlen noch im Asset-Katalog")
        motif.tap()

        let start = app.buttons["startPainting"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: start)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 20), .completed)
        attach(app, "Editor")
        start.tap()

        // Debug build of the full-resolution engine on a CI runner can take a while.
        XCTAssertTrue(app.buttons["backToGallery"].waitForExistence(timeout: 120))
        app.buttons["backToGallery"].tap()
        XCTAssertTrue(app.buttons["artworkCard"].waitForExistence(timeout: 10))
    }

    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
