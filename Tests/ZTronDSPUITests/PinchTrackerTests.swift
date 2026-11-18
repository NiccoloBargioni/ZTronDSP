import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import ZTronDSPUI

/// The pinch tracker (WP-819): scripted touch sequences, fed through the one seam every OS
/// path uses, give the axis, the scale and the centroid that PINCH-3 and PINCH-4 specify.
///
/// What the gestures of iOS 15 to 17 really report together is the subject of the spike
/// WP-818, which has not run: the sequences for those two paths follow the table of PINCH-8
/// as it stands.
@MainActor
@Suite("Pinch tracker")
struct PinchTrackerTests {
    nonisolated static let both: Axis.Set = [.horizontal, .vertical]

    /// Two fingers `distance` apart around `center`, on a line `degrees` from horizontal.
    private func fingers(around center: CGPoint = CGPoint(x: 100, y: 100), distance: CGFloat, degrees: CGFloat) -> (CGPoint, CGPoint) {
        let angle = degrees * .pi / 180
        let offset = CGVector(dx: cos(angle) * distance / 2, dy: sin(angle) * distance / 2)
        return (CGPoint(x: center.x - offset.dx, y: center.y - offset.dy), CGPoint(x: center.x + offset.dx, y: center.y + offset.dy))
    }

    // MARK: The finger line names the axis (PINCH-3)

    @Test(arguments: [
        (0.0, Axis.Set.horizontal), (15, .horizontal), (30, .horizontal), (-30, .horizontal), (150, .horizontal), (180, .horizontal), (210, .horizontal),
        (90, .vertical), (60, .vertical), (75, .vertical), (-90, .vertical), (120, .vertical), (270, .vertical),
        (45, both), (31, both), (59, both), (135, both), (-45, both), (225, both),
    ])
    func theLineThroughTheFingersDecidesTheAxis(degrees: Double, expected: Axis.Set) {
        let angle = degrees * .pi / 180
        // Sines and cosines of the boundary angles are a rounding error off: nudge the line off the boundary.
        let nudge = abs(degrees.truncatingRemainder(dividingBy: 30)) < 1e-9 && abs(degrees.truncatingRemainder(dividingBy: 90)) > 1e-9
            ? (expected == .horizontal ? 0.999 : 1.001) : 1.0
        let line = CGVector(dx: cos(angle) * 80, dy: sin(angle) * 80 * nudge)
        #expect(PinchTracker.axes(along: line) == expected, "\(degrees)° from horizontal")
    }

    @Test func aLineOfNoLengthNamesNoAxis() {
        #expect(PinchTracker.axes(along: .zero) == nil)
        #expect(PinchTracker.axes(along: CGVector(dx: CGFloat.nan, dy: 1)) == nil)
        #expect(PinchTracker.axes(along: CGVector(dx: 0, dy: 0.001)) == .vertical)
    }

    // MARK: iOS 18 and later: both touch locations

    @Test func twoTouchesGiveTheAxisTheScaleAndTheCentroid() throws {
        var tracker = PinchTracker(enabled: Self.both)
        // Nine degrees off horizontal, around (100, 100).
        let first = tracker.update(.touches(CGPoint(x: 50, y: 92), CGPoint(x: 150, y: 108)))
        #expect(first == PinchState(axes: .horizontal, scale: 1, centroid: CGPoint(x: 100, y: 100), startCentroid: CGPoint(x: 100, y: 100)))
        #expect(tracker.isDecided)
        // The fingers move apart to one and a half times the distance and the pinch drifts 20 points to the right.
        let moved = tracker.update(.touches(CGPoint(x: 45, y: 88), CGPoint(x: 195, y: 112)))
        let second = try #require(moved)
        #expect(second.axes == .horizontal)
        #expect(abs(second.scale - 1.5) < 1e-9, "the ratio of the current distance to the initial one (PINCH-4)")
        #expect(second.centroid == CGPoint(x: 120, y: 100) && second.startCentroid == CGPoint(x: 100, y: 100))
        // Closer than they began.
        let closer = tracker.update(.touches(CGPoint(x: 80, y: 96.8), CGPoint(x: 120, y: 103.2)))
        #expect(abs((closer?.scale ?? 0) - 0.4) < 1e-9)
    }

    /// The axis is the one the line named when the pinch began: turning the fingers
    /// afterwards does not change it.
    @Test func theAxisIsDecidedOnceWhenThePinchBegins() {
        var tracker = PinchTracker(enabled: Self.both)
        let start = fingers(distance: 100, degrees: 85)
        #expect(tracker.update(.touches(start.0, start.1))?.axes == .vertical)
        let turned = fingers(distance: 120, degrees: 5)
        let state = tracker.update(.touches(turned.0, turned.1))
        #expect(state?.axes == .vertical && abs((state?.scale ?? 0) - 1.2) < 1e-9)
    }

    @Test func aDiagonalPinchScalesBothAxes() {
        var tracker = PinchTracker(enabled: Self.both)
        let start = fingers(distance: 100, degrees: 45)
        #expect(tracker.update(.touches(start.0, start.1))?.axes == Self.both)
    }

    /// A pinch along an axis that is not enabled does nothing (PINCH-3).
    @Test func aPinchAlongAnAxisThatIsNotEnabledScalesNothing() {
        var tracker = PinchTracker(enabled: .horizontal)
        let vertical = fingers(distance: 100, degrees: 90)
        let state = tracker.update(.touches(vertical.0, vertical.1))
        #expect(state?.axes == [], "no axis: the view changes nothing")
        // A diagonal pinch scales the one axis that is enabled.
        tracker.end()
        let diagonal = fingers(distance: 100, degrees: 45)
        #expect(tracker.update(.touches(diagonal.0, diagonal.1))?.axes == .horizontal)
        // With nothing enabled nothing is ever scaled.
        var off = PinchTracker(enabled: [])
        #expect(off.update(.touches(diagonal.0, diagonal.1))?.axes == [])
    }

    @Test func fingersOnOnePointWaitForALine() {
        var tracker = PinchTracker(enabled: Self.both)
        let point = CGPoint(x: 50, y: 50)
        #expect(tracker.update(.touches(point, point)) == nil && !tracker.isDecided, "no line yet")
        let apart = fingers(distance: 60, degrees: 0)
        #expect(tracker.update(.touches(apart.0, apart.1))?.scale == 1, "the pinch begins with the first line")
    }

    @Test func endingMakesTheTrackerReadyForTheNextPinch() {
        var tracker = PinchTracker(enabled: Self.both)
        let first = fingers(distance: 100, degrees: 0)
        _ = tracker.update(.touches(first.0, first.1))
        tracker.end()
        #expect(!tracker.isDecided)
        #expect(tracker.update(.touches(CGPoint(x: 10, y: -5), CGPoint(x: 10, y: 25)))
            == PinchState(axes: .vertical, scale: 1, centroid: CGPoint(x: 10, y: 10), startCentroid: CGPoint(x: 10, y: 10)))
    }

    // MARK: iOS 17: the pinch's start location and the first finger's start location

    @Test func theLineFromTheCentroidToTheFirstFingerDecidesOnIOS17() {
        var tracker = PinchTracker(enabled: Self.both)
        let centroid = CGPoint(x: 200, y: 150)
        // The first finger went down 60 points above the centroid: a vertical pinch.
        let state = tracker.update(.magnification(scale: 1.0, start: centroid, firstFingerStart: CGPoint(x: 205, y: 90)))
        #expect(state == PinchState(axes: .vertical, scale: 1, centroid: centroid, startCentroid: centroid))
        let later = tracker.update(.magnification(scale: 2.5, start: centroid, firstFingerStart: CGPoint(x: 205, y: 90)))
        #expect(later?.scale == 2.5 && later?.axes == .vertical && later?.centroid == centroid, "the scale is the gesture's magnification")

        var sideways = PinchTracker(enabled: Self.both)
        #expect(sideways.update(.magnification(scale: 1.1, start: centroid, firstFingerStart: CGPoint(x: 120, y: 160)))?.axes == .horizontal)
        var diagonal = PinchTracker(enabled: Self.both)
        #expect(diagonal.update(.magnification(scale: 1.1, start: centroid, firstFingerStart: CGPoint(x: 150, y: 100)))?.axes == Self.both)
    }

    @Test func withoutTheFirstFingerNothingScalesOnIOS17UnlessOneAxisIsEnabled() {
        let centroid = CGPoint(x: 200, y: 150)
        var tracker = PinchTracker(enabled: Self.both)
        #expect(tracker.update(.magnification(scale: 1.3, start: centroid, firstFingerStart: nil)) == nil, "the drag has not spoken yet")
        #expect(tracker.update(.magnification(scale: 1.3, start: centroid, firstFingerStart: centroid)) == nil, "a finger on the centroid gives no line")
        #expect(tracker.update(.magnification(scale: 1.4, start: centroid, firstFingerStart: CGPoint(x: 260, y: 150)))?.axes == .horizontal)

        var single = PinchTracker(enabled: .vertical)
        let state = single.update(.magnification(scale: 1.3, start: centroid, firstFingerStart: nil))
        #expect(state?.axes == .vertical && state?.scale == 1.3, "one axis enabled: no line is needed")
        // With the finger known, a pinch along the other axis does nothing.
        var across = PinchTracker(enabled: .vertical)
        #expect(across.update(.magnification(scale: 1.3, start: centroid, firstFingerStart: CGPoint(x: 260, y: 150)))?.axes == [])
    }

    // MARK: iOS 15 and 16: the direction the first finger travels in its first 8 points

    @Test func nothingScalesOnTheLegacyPathUntilTheFirstFingerHasTravelledEightPoints() {
        var tracker = PinchTracker(enabled: Self.both)
        let start = CGPoint(x: 80, y: 220)
        #expect(tracker.update(.legacy(scale: 1.0, firstFingerStart: start, firstFingerTravel: .zero)) == nil)
        #expect(tracker.update(.legacy(scale: 1.04, firstFingerStart: start, firstFingerTravel: CGSize(width: 3, height: 1))) == nil)
        #expect(tracker.update(.legacy(scale: 1.08, firstFingerStart: start, firstFingerTravel: CGSize(width: 7.9, height: 0))) == nil, "7.9 points: not yet")
        #expect(tracker.update(.legacy(scale: 1.09, firstFingerStart: nil, firstFingerTravel: nil)) == nil, "no drag, no direction")
        // Eight points to the right: a horizontal pinch. The scale counts from here.
        let decided = tracker.update(.legacy(scale: 1.10, firstFingerStart: start, firstFingerTravel: CGSize(width: 8, height: 1)))
        #expect(decided == PinchState(axes: .horizontal, scale: 1, centroid: start, startCentroid: start), "no jump by what moved before")
        let later = tracker.update(.legacy(scale: 1.65, firstFingerStart: start, firstFingerTravel: CGSize(width: 40, height: 30)))
        #expect(later?.axes == .horizontal && abs((later?.scale ?? 0) - 1.5) < 1e-9, "1.65 / 1.10")
    }

    @Test(arguments: [(CGSize(width: 0, height: -9), Axis.Set.vertical), (CGSize(width: -9, height: 2), .horizontal), (CGSize(width: 6, height: 6), both)])
    func theDirectionOfTravelDecidesOnTheLegacyPath(travel: CGSize, expected: Axis.Set) {
        var tracker = PinchTracker(enabled: Self.both)
        #expect(tracker.update(.legacy(scale: 1.2, firstFingerStart: .zero, firstFingerTravel: travel))?.axes == expected)
    }

    /// With one axis enabled, that axis is used at once (PINCH-8).
    @Test func withOneAxisEnabledTheLegacyPathScalesAtOnce() {
        var tracker = PinchTracker(enabled: .horizontal)
        let state = tracker.update(.legacy(scale: 1.07, firstFingerStart: nil, firstFingerTravel: nil))
        #expect(state == PinchState(axes: .horizontal, scale: 1.07, centroid: nil, startCentroid: nil), "the full magnification, from the first report")
        // Even when the finger then travels along the other axis: nothing is inferred.
        #expect(tracker.update(.legacy(scale: 1.3, firstFingerStart: .zero, firstFingerTravel: CGSize(width: 0, height: 40)))?.axes == .horizontal)
    }

    @Test func aMagnificationThatIsNoNumberDoesNotBecomeTheReference() {
        var tracker = PinchTracker(enabled: Self.both)
        let state = tracker.update(.legacy(scale: 0, firstFingerStart: .zero, firstFingerTravel: CGSize(width: 10, height: 0)))
        #expect(state?.scale == 0, "counted from 1")
    }

    // MARK: The touches of a gesture that reports each finger

    @Test func theTwoFingersThatWentDownFirstAreThePinch() {
        var book = TouchBook<Int>()
        #expect(book.pair == nil && book.count == 0)
        book.record(7, at: CGPoint(x: 1, y: 1), isDown: true)
        #expect(book.pair == nil && book.count == 1)
        book.record(3, at: CGPoint(x: 5, y: 5), isDown: true)
        book.record(9, at: CGPoint(x: 9, y: 9), isDown: true)
        #expect(book.count == 3)
        #expect(book.pair?.0 == CGPoint(x: 1, y: 1) && book.pair?.1 == CGPoint(x: 5, y: 5), "in the order they went down")
        book.record(7, at: CGPoint(x: 2, y: 1), isDown: true)
        #expect(book.pair?.0 == CGPoint(x: 2, y: 1), "a finger that moves keeps its place")
        // The first finger lifts: the next two are the pinch.
        book.record(7, at: CGPoint(x: 2, y: 1), isDown: false)
        #expect(book.pair?.0 == CGPoint(x: 5, y: 5) && book.pair?.1 == CGPoint(x: 9, y: 9))
        book.record(42, at: .zero, isDown: false)
        #expect(book.count == 2, "a finger that was never down")
        book.clear()
        #expect(book.pair == nil && book.count == 0)
    }

    // MARK: The session between the gestures and the view

    @Test func aSessionFollowsOnePinchAndReportsItsEndOnce() {
        let session = PinchSession()
        #expect(session.finish() == nil, "no pinch, no end")
        let start = fingers(distance: 100, degrees: 0), wider = fingers(distance: 200, degrees: 0)
        #expect(session.feed(.touches(start.0, start.1), enabled: Self.both)?.scale == 1)
        #expect(session.feed(.touches(wider.0, wider.1), enabled: Self.both)?.scale == 2)
        #expect(session.finish()?.scale == 2, "where the pinch stood")
        #expect(session.finish() == nil, "reported once")
        // The next pinch starts afresh.
        #expect(session.feed(.touches(wider.0, wider.1), enabled: Self.both)?.scale == 1)
        // Other axes enabled: the pinch is read with them.
        _ = session.finish()
        let vertical = fingers(distance: 100, degrees: 90)
        #expect(session.feed(.touches(vertical.0, vertical.1), enabled: .horizontal)?.axes == [])
    }

    @Test func aSessionReadsAPinchOutOfSingleTouches() {
        let session = PinchSession()
        #expect(session.touch(1, at: CGPoint(x: 50, y: 100), isDown: true, enabled: Self.both) == nil, "one finger is no pinch")
        let begun = session.touch(2, at: CGPoint(x: 150, y: 100), isDown: true, enabled: Self.both)
        #expect(begun?.state.axes == .horizontal && begun?.state.scale == 1 && begun?.ended == false)
        let moved = session.touch(2, at: CGPoint(x: 250, y: 100), isDown: true, enabled: Self.both)
        #expect(moved?.state.scale == 2 && moved?.state.centroid == CGPoint(x: 150, y: 100) && moved?.ended == false)
        // One finger lifts: the pinch has ended where it stood.
        let lifted = session.touch(1, at: CGPoint(x: 50, y: 100), isDown: false, enabled: Self.both)
        #expect(lifted?.state.scale == 2 && lifted?.ended == true)
        #expect(session.touch(2, at: CGPoint(x: 260, y: 100), isDown: true, enabled: Self.both) == nil, "the finger that stays is no pinch")
        // A second finger comes back: a new pinch, from 1.
        let again = session.touch(5, at: CGPoint(x: 260, y: 300), isDown: true, enabled: Self.both)
        #expect(again?.state.scale == 1 && again?.state.axes == .vertical)
        session.clearTouches()
        #expect(session.touch(9, at: .zero, isDown: true, enabled: Self.both)?.ended == true, "the pinch that was cut off is reported as ended")
    }
}
