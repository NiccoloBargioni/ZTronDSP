import XCTest

/// The spike WP-818, from outside the application: what a UI test can synthesise, and what
/// the pinch-related gestures of SwiftUI report for it (PINCH-8).
///
/// Each test launches the gallery on its pinch-spike screen with one arrangement of gestures
/// and one size of the rectangle that catches the touches, and plays the same five things
/// into it, a mark between each two:
///
/// 1. `pinch(withScale: 2, velocity: 2)`: two fingers apart;
/// 2. `pinch(withScale: 0.5, velocity: -2)`: two fingers together;
/// 3. `rotate(.pi / 3, withVelocity: 2)`: two fingers around their middle;
/// 4. `twoFingerTap()`;
/// 5. a drag of one finger.
///
/// These are the multi-touch gestures XCUITest offers publicly. It has no public way to
/// describe the path of each finger: the fingers of a pinch land together, where XCUITest
/// puts them. The size of the rectangle is varied because that is the one thing a test can
/// change about where they land.
///
/// The application writes what its gestures report into `pinch-<gesture>-<width>x<height>.log`
/// in its Documents folder; `gallery.sh logs` copies the logs out. The test itself only
/// asserts that the touches arrived. The logs are read in
/// `Examples/ZTronDSPGallery/Spikes/WP-818-findings.md`.
final class PinchSpikeUITests: GalleryUITestCase {
    static let sizes: [(width: Int, height: Int)] = [(300, 300), (340, 140), (140, 340)]

    override func setUp() {
        continueAfterFailure = true
    }

    private var systemVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    @MainActor
    private func recorded(_ app: XCUIApplication) -> Int {
        Int(app.staticTexts["spike.summary"].label.split(separator: " ").last ?? "") ?? -1
    }

    @MainActor
    private func mark(_ app: XCUIApplication) {
        app.buttons["spike.mark"].tap()
    }

    /// Plays the five gestures into one arrangement at every size.
    @MainActor
    private func play(_ gesture: String) {
        for size in Self.sizes {
            let app = XCUIApplication()
            app.launchArguments = [
                "-GalleryExample", "pinchSpike", "-SpikeGesture", gesture, "-SpikeWidth", "\(size.width)", "-SpikeHeight", "\(size.height)",
                "-SpikeLog", "pinch-\(gesture)-\(size.width)x\(size.height)",
            ]
            app.launch()
            let catcher = app.descendants(matching: .any).matching(identifier: "spike.catcher").firstMatch
            XCTAssertTrue(catcher.waitForExistence(timeout: 300), "\(gesture) \(size): the rectangle is shown")
            let before = recorded(app)

            mark(app)
            catcher.pinch(withScale: 2, velocity: 2)
            mark(app)
            catcher.pinch(withScale: 0.5, velocity: -2)
            mark(app)
            catcher.rotate(.pi / 3, withVelocity: 2)
            mark(app)
            catcher.twoFingerTap()
            mark(app)
            catcher.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
                .press(forDuration: 0.1, thenDragTo: catcher.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
            mark(app)

            // Six marks, and whatever the gestures reported in between.
            XCTAssertGreaterThan(recorded(app), before + 6, "\(gesture) \(size): the gestures reported something")
            app.terminate()
        }
    }

    // MARK: The paths of PINCH-8, as the package builds them

    /// iOS 18 and later: `SpatialEventGesture`.
    @MainActor
    func testSpatialEventGesture() throws {
        try XCTSkipIf(systemVersion < 18, "SpatialEventGesture is iOS 18")
        play("spatial")
    }

    /// iOS 17: `MagnifyGesture` with a simultaneous `DragGesture`.
    @MainActor
    func testMagnifyWithDrag() throws {
        play("magnify")
    }

    /// iOS 15 and 16: `MagnificationGesture` with a simultaneous `DragGesture`. The gesture
    /// exists on every later OS, so what it reports there is recorded; iOS 15 and 16 cannot
    /// be run on this host.
    @MainActor
    func testMagnificationWithDrag() throws {
        play("legacy")
    }

    // MARK: Ground truth

    /// The pair of iOS 17 with the touches of iOS 18 on the same view: where the fingers
    /// are, beside what the pair says.
    @MainActor
    func testMagnifyWithDragBesideTheTouches() throws {
        try XCTSkipIf(systemVersion < 18, "SpatialEventGesture is iOS 18")
        play("spatialMagnify")
    }

    /// The pair of iOS 15 and 16 with the touches of iOS 18 on the same view.
    @MainActor
    func testMagnificationWithDragBesideTheTouches() throws {
        try XCTSkipIf(systemVersion < 18, "SpatialEventGesture is iOS 18")
        play("spatialLegacy")
    }

    /// The pinch and the drag as two gestures with callbacks of their own: the order in which
    /// they begin and end.
    @MainActor
    func testPinchAndDragAsSeparateGestures() throws {
        play("separate")
    }

    /// A grid of small drag gestures: each finger is reported by the cell it lands in, on
    /// every OS. This is how the fingers of a synthesised pinch are located on iOS 17.
    @MainActor
    func testOneDragPerFinger() throws {
        play("cells")
    }
}

/// The package's own gesture paths under real touches: a pinch on the gallery's pinch screen
/// scales what the screen's state holds. On iOS 18 and later this is the path of
/// `SpatialEventGesture`, on iOS 17 that of `MagnifyGesture` with a `DragGesture`.
///
/// On iOS 17 the two fingers of a synthesised pinch land together, the drag reports nothing,
/// and the finger line is not known (`Spikes/WP-818-findings.md`): such a pinch scales every
/// enabled axis (PINCH-8), so both the time span and the frequency range follow it there.
/// Before that correction the pinch scaled nothing on iOS 17.
final class PinchScreenUITests: GalleryUITestCase {
    @MainActor
    private func number(_ app: XCUIApplication, _ identifier: String, at index: Int) -> Double {
        let words = app.staticTexts[identifier].label.split(separator: " ")
        return index < words.count ? Double(words[index].replacingOccurrences(of: ",", with: ".")) ?? .nan : .nan
    }

    @MainActor
    func testAPinchOnTheSpectrogramScalesItsBoundTimeSpanAndRange() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-GalleryExample", "pinch"]
        app.launch()
        let spectrogram = app.descendants(matching: .any).matching(identifier: "pinch.spectrogram").firstMatch
        XCTAssertTrue(spectrogram.waitForExistence(timeout: 300))
        XCTAssertEqual(number(app, "pinch.span", at: 1), 4, accuracy: 1e-9, "the span the screen starts with")
        let low = number(app, "pinch.range", at: 1), high = number(app, "pinch.range", at: 2)

        // Fingers apart: less is shown. Which axis scales is decided by the line through the
        // fingers when they land (PINCH-3), and XCUITest lands them where it sees fit: on
        // this view the fingers of a pinch that opens land on a flat line, those of a pinch
        // that closes on a steep one (WP-818). So each pinch must scale at least one axis the
        // right way, and none the wrong way.
        spectrogram.pinch(withScale: 2, velocity: 2)
        let span = number(app, "pinch.span", at: 1)
        let narrowedLow = number(app, "pinch.range", at: 1), narrowedHigh = number(app, "pinch.range", at: 2)
        print("ZTD pinch out: span 4 -> \(span), range \(low) ... \(high) -> \(narrowedLow) ... \(narrowedHigh)")
        XCTAssertLessThanOrEqual(span, 4, "fingers apart: no longer span")
        XCTAssertGreaterThanOrEqual(span, 0.5, "and not below the limit once the fingers have lifted (PINCH-6)")
        XCTAssertLessThanOrEqual(narrowedHigh - narrowedLow, high - low, "and no wider range")
        XCTAssertTrue(span < 4 || narrowedHigh - narrowedLow < high - low, "fingers apart: less is shown along at least one axis")
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 18 {
            XCTAssertTrue(span < 4 && narrowedHigh - narrowedLow < high - low, "before iOS 18 the finger line is not known: both axes are scaled")
        }

        // Fingers together: more is shown again.
        spectrogram.pinch(withScale: 0.5, velocity: -2)
        let wider = number(app, "pinch.span", at: 1)
        let widenedLow = number(app, "pinch.range", at: 1), widenedHigh = number(app, "pinch.range", at: 2)
        print("ZTD pinch in: span \(span) -> \(wider), range \(narrowedLow) ... \(narrowedHigh) -> \(widenedLow) ... \(widenedHigh)")
        XCTAssertGreaterThanOrEqual(wider, span, "fingers together: no shorter span")
        XCTAssertGreaterThanOrEqual(widenedHigh - widenedLow, narrowedHigh - narrowedLow, "and no narrower range")
        XCTAssertTrue(wider > span || widenedHigh - widenedLow > narrowedHigh - narrowedLow, "fingers together: more is shown along at least one axis")
    }
}
