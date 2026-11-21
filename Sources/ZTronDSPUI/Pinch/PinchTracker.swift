import CoreGraphics
import Foundation
import SwiftUI

/// What a pinch gesture reported, whichever gesture it was: the one seam between the
/// gestures SwiftUI offers on each OS and the tracker that reads a pinch out of them
/// (PINCH-8). A test scripts a sequence of these; in an app each OS path makes them from
/// what its gestures say.
///
/// An immutable value.
enum PinchSample: Equatable {
    /// iOS 18 and later (`SpatialEventGesture`): where the two fingers are now.
    case touches(CGPoint, CGPoint)
    /// iOS 17 (`MagnifyGesture` with a simultaneous `DragGesture`): the magnification, the
    /// pinch's start location, which is its centroid, and where the first finger went down,
    /// when the drag says so. It says so when the first finger lands before the second;
    /// when both land together the drag reports nothing for the whole pinch, and this is
    /// `nil` throughout.
    case magnification(scale: CGFloat, start: CGPoint, firstFingerStart: CGPoint?)
    /// iOS 15 and 16 (`MagnificationGesture` with a simultaneous `DragGesture`): the
    /// magnification, where the first finger went down and how far it has travelled since,
    /// when the drag says so; `nil` throughout when both fingers land together, as above.
    case legacy(scale: CGFloat, firstFingerStart: CGPoint?, firstFingerTravel: CGSize?)
}

/// Where a pinch stands: which axes it scales, by how much, and around which point.
///
/// An immutable value.
struct PinchState: Equatable {
    /// The axes the pinch scales. They are decided once, from the line through the two
    /// fingers when the pinch begins (PINCH-3), and limited to the axes that are enabled: a
    /// pinch along an axis that is not enabled scales nothing, and this is empty. A pinch
    /// whose finger line is not known scales every enabled axis (PINCH-8).
    var axes: Axis.Set
    /// The distance between the fingers now over their distance when the pinch began
    /// (PINCH-4). Above 1 the fingers have moved apart.
    var scale: CGFloat
    /// The point the pinch is anchored at now, in the view's coordinates: the value under it
    /// stays under it. `nil` where the gestures do not say.
    var centroid: CGPoint?
    /// The point it was anchored at when it began.
    var startCentroid: CGPoint?
}

/// Reads a pinch out of what the gestures report: the finger line gives the axis, the
/// distance between the fingers the scale, their middle the centroid (WP-819).
///
/// One tracker follows one pinch: feed it every sample, and call ``end()`` when the fingers
/// lift. Where the finger line comes from differs by OS (PINCH-8):
///
/// | Sample | The finger line |
/// |---|---|
/// | `.touches` | Both touch locations. |
/// | `.magnification` | From the pinch's start location (the centroid) to the first finger's start location, which the drag reports only when the first finger lands before the second. |
/// | `.legacy` | The direction the first finger travels in its first 8 points; nothing scales until then. With one axis enabled, that axis is used at once. |
///
/// **A finger line that is not known.** When both fingers land together, the drag of the
/// `.magnification` and of the `.legacy` path reports nothing for the whole pinch (found by
/// the spike WP-818 on iOS 17.5, 18.6 and 27.0), so there is no first finger to draw a line
/// to and no travel to read. Such a pinch scales every enabled axis, from its first report.
/// It is told from a drag that has not travelled far enough yet by the drag's silence: a
/// drag that has reported once and falls silent decides nothing.
///
/// On the legacy path the scale counts from the moment the axis is known, so that the
/// picture does not jump by what the fingers moved while nothing scaled.
///
/// A plain value for the main actor; nothing here allocates.
struct PinchTracker: Equatable {
    /// How far the first finger travels before its direction counts, in points.
    static let decisionDistance: CGFloat = 8

    /// The axes `.pinchScaling(_:)` enabled.
    let enabled: Axis.Set
    /// The axes this pinch scales; `nil` until the finger line is known.
    private var decided: Axis.Set?
    /// The distance between the fingers when the pinch began.
    private var initialDistance: CGFloat?
    private var startCentroid: CGPoint?
    /// On the legacy path: the magnification at the moment the axis was decided.
    private var referenceScale: CGFloat = 1
    /// On the legacy path: whether the drag has reported the first finger in this pinch.
    private var heardTheFirstFinger = false

    init(enabled: Axis.Set) {
        self.enabled = enabled
    }

    /// The axes a finger line names (PINCH-3): within 30° of horizontal the horizontal axis,
    /// within 30° of vertical the vertical axis, otherwise both. `nil` for a line of no
    /// length, which has no direction.
    static func axes(along line: CGVector) -> Axis.Set? {
        let across = abs(line.dx), up = abs(line.dy)
        guard across.isFinite, up.isFinite, across > 0 || up > 0 else { return nil }
        let degrees = atan2(up, across) * 180 / .pi
        if degrees <= 30 { return .horizontal }
        if degrees >= 60 { return .vertical }
        return [.horizontal, .vertical]
    }

    /// True once the pinch knows its axes.
    var isDecided: Bool { decided != nil }

    /// Takes one report of the gesture. Returns where the pinch stands, or `nil` while
    /// nothing scales yet because the finger line is not known.
    mutating func update(_ sample: PinchSample) -> PinchState? {
        switch sample {
        case .touches(let first, let second):
            let line = CGVector(dx: second.x - first.x, dy: second.y - first.y)
            let distance = hypot(line.dx, line.dy)
            let middle = CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
            if decided == nil {
                guard let named = Self.axes(along: line) else { return nil }
                decided = named.intersection(enabled)
                initialDistance = distance
                startCentroid = middle
            }
            guard let decided, let initialDistance, initialDistance > 0 else { return nil }
            return PinchState(axes: decided, scale: distance / initialDistance, centroid: middle, startCentroid: startCentroid)

        case .magnification(let scale, let start, let firstFingerStart):
            if decided == nil {
                if let finger = firstFingerStart {
                    if let named = Self.axes(along: CGVector(dx: finger.x - start.x, dy: finger.y - start.y)) {
                        decided = named.intersection(enabled)
                    } else if let only = onlyEnabledAxis {
                        decided = only
                    } else {
                        return nil
                    }
                } else {
                    // The drag is silent: both fingers landed together, and the finger line
                    // is not known. The pinch scales every enabled axis (PINCH-8).
                    decided = enabled
                }
                startCentroid = start
            }
            guard let decided else { return nil }
            return PinchState(axes: decided, scale: scale, centroid: startCentroid, startCentroid: startCentroid)

        case .legacy(let scale, let firstFingerStart, let travel):
            if decided == nil {
                if let only = onlyEnabledAxis {
                    decided = only
                    referenceScale = 1
                } else if let travel {
                    heardTheFirstFinger = true
                    guard hypot(travel.width, travel.height) >= Self.decisionDistance,
                          let named = Self.axes(along: CGVector(dx: travel.width, dy: travel.height)) else { return nil }
                    decided = named.intersection(enabled)
                    referenceScale = scale > 0 && scale.isFinite ? scale : 1
                } else if !heardTheFirstFinger {
                    // The drag is silent from the first report on: both fingers landed
                    // together, and the finger line is not known. The pinch scales every
                    // enabled axis at once, by the whole magnification (PINCH-8).
                    decided = enabled
                    referenceScale = 1
                } else {
                    return nil
                }
                startCentroid = firstFingerStart
            }
            guard let decided else { return nil }
            return PinchState(axes: decided, scale: scale / referenceScale, centroid: startCentroid, startCentroid: startCentroid)
        }
    }

    /// The fingers lifted: the tracker is ready for the next pinch.
    mutating func end() {
        decided = nil
        initialDistance = nil
        startCentroid = nil
        referenceScale = 1
        heardTheFirstFinger = false
    }

    /// The enabled axis, when exactly one is enabled: then no finger line is needed.
    private var onlyEnabledAxis: Axis.Set? {
        enabled == .horizontal || enabled == .vertical ? enabled : nil
    }
}

/// The touches of a gesture that reports each finger by itself: which are down, and where.
/// The two that went down first are the pinch.
///
/// A plain value; `ID` is whatever the gesture tells its touches apart by.
struct TouchBook<ID: Hashable> {
    private var order: [ID] = []
    private var locations: [ID: CGPoint] = [:]

    /// A touch moved, or lifted.
    mutating func record(_ id: ID, at location: CGPoint, isDown: Bool) {
        if isDown {
            if locations[id] == nil { order.append(id) }
            locations[id] = location
        } else if locations.removeValue(forKey: id) != nil {
            order.removeAll { $0 == id }
        }
    }

    /// Fingers that are down.
    var count: Int { order.count }

    /// The two fingers of the pinch, in the order they went down; `nil` with fewer than two.
    var pair: (CGPoint, CGPoint)? {
        guard order.count >= 2, let first = locations[order[0]], let second = locations[order[1]] else { return nil }
        return (first, second)
    }

    /// Forgets every touch.
    mutating func clear() {
        order = []
        locations = [:]
    }
}
