import SwiftUI

/// The spike WP-818: what the pinch-related gestures of SwiftUI report together (PINCH-8).
///
/// The screen shows one rectangle that catches touches, carries the gestures a launch
/// argument names, and writes down everything they report: the order of the callbacks, the
/// start locations and anchors, and which half of a simultaneous pair has a value. The
/// gestures are built exactly as `ZTronDSPUI` builds them for its three paths.
///
/// Launch arguments:
///
/// | Argument | Meaning |
/// |---|---|
/// | `-SpikeGesture` | `spatial` (iOS 18), `magnify` (iOS 17), `legacy`, `spatialMagnify`, `spatialLegacy` (the pair together with the touches, as ground truth), `separate` (magnify and drag as two gestures), `cells` (a grid of small drag gestures: one per finger on any OS) |
/// | `-SpikeWidth`, `-SpikeHeight` | The size of the rectangle, in points (300 × 300) |
/// | `-SpikeLog` | The name of the log in the Documents folder (`pinch-spike`) |
///
/// A UI test synthesises the touches (`GalleryUITests/PinchSpikeUITests.swift`) and presses
/// "Mark" between two gestures; every mark and every end of a gesture saves the log.
struct PinchSpikeScreen: View {
    @State private var log = SpikeLog(name: Launch.value("SpikeLog") ?? "pinch-spike")
    /// Lines recorded, shown so that a UI test can see that its touches arrived.
    @State private var recorded = 0
    /// The fingers of the gesture that reports each touch, numbered as they appear.
    @State private var fingers = FingerNumbers()
    /// Marks set so far: a UI test sets one between two gestures, so that the log says where
    /// one ends and the next begins.
    @State private var marks = 0

    private let variant = Launch.value("SpikeGesture") ?? "legacy"
    private let width = Launch.value("SpikeWidth").flatMap(Double.init) ?? 300
    private let height = Launch.value("SpikeHeight").flatMap(Double.init) ?? 300

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 16) {
                Button("Mark") {
                    marks += 1
                    finish("mark \(marks)")
                }
                .accessibilityIdentifier("spike.mark")
                Text("\(variant) \(recorded)")
                    .font(.caption.monospacedDigit())
                    .accessibilityIdentifier("spike.summary")
            }
            catcher
                .frame(width: width, height: height)
                .coordinateSpace(name: "catcher")
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("spike.catcher")
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .onAppear {
            note("screen variant=\(variant) size=\(SpikeFormat.size(CGSize(width: width, height: height))) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
            log.save()
        }
    }

    private var surface: some View {
        Color.gray.opacity(0.25).contentShape(Rectangle())
    }

    @ViewBuilder
    private var catcher: some View {
        switch variant {
        case "spatial":
            if #available(iOS 18.0, *) { surface.gesture(touches) } else { unavailable }
        case "magnify":
            if #available(iOS 17.0, *) { surface.gesture(magnifyWithDrag) } else { unavailable }
        case "spatialMagnify":
            if #available(iOS 18.0, *) { surface.gesture(magnifyWithDrag).simultaneousGesture(touches) } else { unavailable }
        case "spatialLegacy":
            if #available(iOS 18.0, *) { surface.gesture(legacyWithDrag).simultaneousGesture(touches) } else { unavailable }
        case "separate":
            if #available(iOS 17.0, *) {
                surface.gesture(magnifyAlone).simultaneousGesture(dragAlone)
            } else {
                surface.gesture(legacyAlone).simultaneousGesture(dragAlone)
            }
        case "cells":
            cells
        default:
            surface.gesture(legacyWithDrag)
        }
    }

    private var unavailable: some View {
        Text("not available on this OS").accessibilityIdentifier("spike.unavailable")
    }

    private func note(_ text: String) {
        log.note(text)
        recorded = log.lines.count
    }

    private func finish(_ text: String) {
        note(text)
        log.save()
    }

    // MARK: iOS 18 and later: every touch by itself

    @available(iOS 18.0, *)
    private var touches: some Gesture {
        SpatialEventGesture(coordinateSpace: .local)
            .onChanged { events in
                for event in events {
                    note("spatial.changed finger=\(fingers.number(of: event.id)) phase=\(Self.name(event.phase)) at=\(SpikeFormat.point(event.location))")
                }
            }
            .onEnded { events in
                for event in events {
                    note("spatial.ended finger=\(fingers.number(of: event.id)) phase=\(Self.name(event.phase)) at=\(SpikeFormat.point(event.location))")
                }
                finish("spatial.end")
            }
    }

    @available(iOS 18.0, *)
    private static func name(_ phase: SpatialEventCollection.Event.Phase) -> String {
        switch phase {
        case .active: "active"
        case .ended: "ended"
        case .cancelled: "cancelled"
        @unknown default: "unknown"
        }
    }

    // MARK: iOS 17: MagnifyGesture with a simultaneous DragGesture

    @available(iOS 17.0, *)
    private var magnifyWithDrag: some Gesture {
        MagnifyGesture()
            .simultaneously(with: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                note("magnify.changed " + Self.describe(value.first) + " " + Self.describe(value.second))
            }
            .onEnded { value in
                finish("magnify.ended " + Self.describe(value.first) + " " + Self.describe(value.second))
            }
    }

    @available(iOS 17.0, *)
    private var magnifyAlone: some Gesture {
        MagnifyGesture()
            .onChanged { value in note("magnifyAlone.changed " + Self.describe(value)) }
            .onEnded { value in finish("magnifyAlone.ended " + Self.describe(value)) }
    }

    @available(iOS 17.0, *)
    private static func describe(_ value: MagnifyGesture.Value?) -> String {
        guard let value else { return "pinch=nil" }
        return "pinch.scale=\(SpikeFormat.number(value.magnification)) pinch.start=\(SpikeFormat.point(value.startLocation))"
            + " pinch.anchor=(\(SpikeFormat.number(value.startAnchor.x)),\(SpikeFormat.number(value.startAnchor.y)))"
    }

    // MARK: iOS 15 and 16: MagnificationGesture with a simultaneous DragGesture

    private var legacyWithDrag: some Gesture {
        MagnificationGesture()
            .simultaneously(with: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                note("legacy.changed " + Self.describe(scale: value.first) + " " + Self.describe(value.second))
            }
            .onEnded { value in
                finish("legacy.ended " + Self.describe(scale: value.first) + " " + Self.describe(value.second))
            }
    }

    private var legacyAlone: some Gesture {
        MagnificationGesture()
            .onChanged { scale in note("legacyAlone.changed " + Self.describe(scale: scale)) }
            .onEnded { scale in finish("legacyAlone.ended " + Self.describe(scale: scale)) }
    }

    private var dragAlone: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in note("dragAlone.changed " + Self.describe(value)) }
            .onEnded { value in finish("dragAlone.ended " + Self.describe(value)) }
    }

    private static func describe(scale: CGFloat?) -> String {
        guard let scale else { return "pinch=nil" }
        return "pinch.scale=\(SpikeFormat.number(scale))"
    }

    private static func describe(_ drag: DragGesture.Value?) -> String {
        guard let drag else { return "drag=nil" }
        return "drag.start=\(SpikeFormat.point(drag.startLocation)) drag.at=\(SpikeFormat.point(drag.location))"
            + " drag.move=\(SpikeFormat.size(drag.translation))"
    }

    // MARK: Any OS: one small drag gesture per cell, so that each finger reports by itself

    private var cells: some View {
        let columns = 6, rows = 6
        return VStack(spacing: 0) {
            ForEach(0 ..< rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0 ..< columns, id: \.self) { column in
                        Color.gray.opacity((row + column) % 2 == 0 ? 0.3 : 0.15)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .named("catcher"))
                                    .onChanged { value in note("cell.changed cell=\(row).\(column) " + Self.describe(value)) }
                                    .onEnded { value in finish("cell.ended cell=\(row).\(column) " + Self.describe(value)) })
                    }
                }
            }
        }
    }
}

/// Numbers the touches of a gesture in the order they appear: a touch's identifier says
/// nothing by itself. A reference, so that numbering a touch invalidates no view.
@MainActor
final class FingerNumbers {
    private var numbers: [AnyHashable: Int] = [:]

    func number(of id: some Hashable) -> Int {
        let key = AnyHashable(id)
        if let known = numbers[key] { return known }
        numbers[key] = numbers.count
        return numbers.count - 1
    }
}
