import XCTest

/// The spike WP-822, from outside the application: the device is turned, which a hosted test
/// cannot do, and the application writes down which sizes SwiftUI hands a size probe while
/// the interface turns, and while a frame is animated (`Gallery/Spikes/SizeSpikeScreen.swift`).
///
/// The hosted spike turns the interface by asking the scene for another orientation
/// (`GalleryTests/SizeTransitionSpike.swift`). The log of this test, `size-spike-device.log`,
/// shows that a turn of the device hands the probe the same thing: the final size, once.
final class SizeSpikeUITests: GalleryUITestCase {
    @MainActor
    private func recorded(_ app: XCUIApplication) -> Int {
        Int(app.staticTexts["spike.summary"].label) ?? -1
    }

    @MainActor
    private func isLandscape(_ app: XCUIApplication) -> Bool {
        let frame = app.windows.firstMatch.frame
        return frame.width > frame.height
    }

    /// Waits until the application's window is as wide as `landscape` says, or the
    /// application is gone.
    @MainActor
    private func waitUntil(_ app: XCUIApplication, landscape: Bool) -> Bool {
        for _ in 0 ..< 1_200 {
            guard app.state == .runningForeground else { return false }
            if isLandscape(app) == landscape { return true }
            usleep(250_000)
        }
        return false
    }

    /// Presses "Save" until the number of lines the screen shows satisfies `done`, at most
    /// `attempts` times, and returns the last number read. A press can miss while the
    /// interface is still settling.
    @MainActor
    private func save(_ app: XCUIApplication, attempts: Int, until done: (Int) -> Bool) -> Int {
        var lines = -1
        for _ in 0 ..< attempts {
            guard app.state == .runningForeground else { return lines }
            app.buttons["spike.save"].tap()
            lines = recorded(app)
            if done(lines) { break }
            usleep(500_000)
        }
        return lines
    }

    @MainActor
    func testAnAnimatedFrameAndATurnOfTheDevice() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-GalleryExample", "sizeSpike", "-SpikeLog", "size-spike-device"]
        app.launch()
        let resize = app.buttons["spike.resize"]
        XCTAssertTrue(resize.waitForExistence(timeout: 300), "the spike's screen is shown")
        defer { XCUIDevice.shared.orientation = .portrait }

        // A frame animated inside withAnimation, there and back. The log is complete when it
        // has stopped growing.
        resize.tap()
        resize.tap()
        var seen = -1
        let afterFrame = save(app, attempts: 40) { lines in
            defer { seen = lines }
            return lines == seen
        }
        XCTAssertGreaterThan(afterFrame, 4, "the probe was handed sizes while the frame was animated")

        // The device is turned, and turned back. Before the corrections that the spike called
        // for, the drawable of a component shrank in a rotation and, on the way back, grew by
        // the same factor with every tick until Metal refused its texture: on the iOS 17.5
        // simulator the gallery ended here in three runs of six
        // (`Spikes/WP-822-findings.md`, finding B). The drawable is now sized with the
        // display's scale and bounded by the largest texture, so the application has to live.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitUntil(app, landscape: true), "the interface turned with the device")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitUntil(app, landscape: false), "and turned back")
        let afterTurn = save(app, attempts: 20) { $0 > afterFrame }
        XCTAssertEqual(app.state, .runningForeground, "the gallery lives through a rotation there and back")
        XCTAssertGreaterThan(afterTurn, afterFrame, "the probe was handed sizes while the interface turned")
        // A second turn, as a person who turns the device twice: the crash came on the way back.
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(waitUntil(app, landscape: true), "the interface turned again")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitUntil(app, landscape: false), "and back again")
        let afterSecondTurn = save(app, attempts: 20) { $0 > afterTurn }
        XCTAssertEqual(app.state, .runningForeground, "the gallery lives through the second rotation")
        XCTAssertGreaterThan(afterSecondTurn, afterTurn)
    }
}
