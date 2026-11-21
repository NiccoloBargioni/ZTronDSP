import XCTest

/// WP-810, from outside the application: it launches, and every example opens from the list
/// by a tap on its row, as a person opens it. What the components draw is seen from inside,
/// by the hosted tests (`GalleryTests/GalleryScreenTests.swift`).
final class GalleryWalkUITests: GalleryUITestCase {
    /// The rows of the list and the titles of their screens (`Gallery/Example.swift`).
    static let examples: [(row: String, title: String)] = [
        ("spectrogram", "SpectrogramView"),
        ("heatmap", "HeatmapView"),
        ("chromagram", "ChromagramView"),
        ("tempogram", "TempogramView"),
        ("waveform", "WaveformView"),
        ("appearance", "Appearance modifiers"),
        ("pinch", "Pinch scaling"),
        ("sizeChange", "Animated size"),
        ("animatedPipeline", "Animated pipeline value"),
        ("activation", "Activation"),
        ("sourceFed", "Source-fed views"),
        ("pinchSpike", "Pinch gestures (WP-818)"),
        ("sizeSpike", "Size transitions (WP-822)"),
    ]

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testEveryExampleOpensFromTheList() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["ZTronDSP"].waitForExistence(timeout: 300), "the list is shown")
        for example in Self.examples {
            let row = app.descendants(matching: .any).matching(identifier: "example." + example.row).firstMatch
            if !row.waitForExistence(timeout: 5) || !row.isHittable {
                app.swipeUp()
            }
            XCTAssertTrue(row.waitForExistence(timeout: 120), "the row of \(example.row)")
            row.tap()
            XCTAssertTrue(app.navigationBars[example.title].waitForExistence(timeout: 180), "the screen of \(example.row) opened")
            app.navigationBars[example.title].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["ZTronDSP"].waitForExistence(timeout: 180), "back at the list after \(example.row)")
        }
        XCTAssertEqual(app.state, .runningForeground, "the application is still running")
    }

    /// `-GalleryExample <name>` opens a screen at launch: how the other UI tests get to theirs.
    @MainActor
    func testALaunchArgumentOpensAScreen() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-GalleryExample", "activation"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Activation"].waitForExistence(timeout: 300))
        let toggle = app.descendants(matching: .any).matching(identifier: "activation.boost").firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 120), "the toggle over the state of the screen")
    }
}
