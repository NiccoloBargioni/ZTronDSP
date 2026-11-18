import Foundation
import Testing
import ZTronDSPTesting

@Suite("Golden loader")
struct GoldenLoaderTests {
    /// A scratch folder per test, removed afterwards.
    private func withFolder(_ body: (URL) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ztd-golden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    private func write(_ text: String, _ name: String, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func rawFloats(_ values: [Float]) -> Data {
        var data = Data()
        for value in values { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private func rawDoubles(_ values: [Double]) -> Data {
        var data = Data()
        for value in values { withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    @Test func aWellFormedFileLoads() throws {
        try withFolder { folder in
            try rawFloats([1.5, -2.25, 3, 4, 5, 6]).write(to: folder.appendingPathComponent("frames.f32"))
            try rawDoubles([0.1, 0.2]).write(to: folder.appendingPathComponent("taps.f64"))
            let url = try write("""
                {"generator": "sample", "oracle": {"numpy": "2.2.6", "scipy": "1.15.3"},
                 "cases": [
                   {"name": "order-2", "parameters": {"order": 2, "family": "butterworth", "analog": true, "edges": [0.1, 0.2]},
                    "values": {"poles": {"re": [-0.7071067811865476, -0.7071067811865476], "im": [0.7071067811865476, -0.7071067811865476]},
                               "gain": [1.0],
                               "frames": {"raw": "frames.f32", "shape": [2, 3]},
                               "taps": {"raw": "taps.f64", "shape": [2]}}},
                   {"name": "empty", "values": {"zeros": {"re": [], "im": []}}}
                 ]}
                """, "sample.json", in: folder)

            let file = try GoldenFile(contentsOf: url)
            #expect(file.generator == "sample")
            #expect(file.oracle == ["numpy": "2.2.6", "scipy": "1.15.3"])
            #expect(file.cases.count == 2)

            let first = try file.require("order-2")
            #expect(try first.integer("order") == 2)
            #expect(try first.number("order") == 2)
            #expect(try first.string("family") == "butterworth")
            #expect(first.parameters["analog"] == .bool(true))
            #expect(try first.numbers("edges") == [0.1, 0.2])
            #expect(try first.numbers("order") == [2])
            let poles = try first.complex("poles")
            #expect(poles.real == [-0.7071067811865476, -0.7071067811865476])
            #expect(poles.imaginary == [0.7071067811865476, -0.7071067811865476])
            #expect(try first.real("gain") == [1.0])
            #expect(try first.floats("gain") == [1.0])
            #expect(try first.floats("frames") == [1.5, -2.25, 3, 4, 5, 6])
            #expect(try first.real("frames") == [1.5, -2.25, 3, 4, 5, 6])
            #expect(try first.shape("frames") == [2, 3])
            #expect(try first.real("taps") == [0.1, 0.2])
            #expect(try first.floats("taps") == [Float(0.1), Float(0.2)])
            #expect(try first.shape("taps") == [2])
            #expect(try first.shape("gain") == [1])
            #expect(try first.shape("poles") == [2])

            let empty = try file.require("empty")
            #expect(try empty.complex("zeros").real.isEmpty)
            #expect(empty.parameters.isEmpty)
        }
    }

    @Test func lookupsThatMissAreTypedErrors() throws {
        try withFolder { folder in
            let url = try write("""
                {"generator": "g", "oracle": {}, "cases": [{"name": "c", "parameters": {"text": "x"}, "values": {"v": [1], "z": {"re": [1], "im": [0]}}}]}
                """, "g.json", in: folder)
            let file = try GoldenFile(contentsOf: url)
            #expect(throws: GoldenError.missingCase(file: "g", name: "absent")) { try file.require("absent") }
            let c = try file.require("c")
            #expect(throws: GoldenError.missingValue(case: "c", key: "w")) { try c.real("w") }
            #expect(throws: GoldenError.wrongKind(case: "c", key: "z", expected: "real")) { try c.real("z") }
            #expect(throws: GoldenError.wrongKind(case: "c", key: "z", expected: "real")) { try c.floats("z") }
            #expect(throws: GoldenError.wrongKind(case: "c", key: "v", expected: "complex")) { try c.complex("v") }
            #expect(throws: GoldenError.wrongKind(case: "c", key: "text", expected: "a number parameter")) { try c.number("text") }
            #expect(throws: GoldenError.wrongKind(case: "c", key: "nope", expected: "a string parameter")) { try c.string("nope") }
            #expect(throws: GoldenError.wrongKind(case: "c", key: "text", expected: "a list of numbers")) { try c.numbers("text") }
        }
    }

    @Test func fractionalParametersAreNotIntegers() throws {
        try withFolder { folder in
            let url = try write("""
                {"generator": "g", "oracle": {}, "cases": [{"name": "c", "parameters": {"ripple": 0.5}, "values": {}}]}
                """, "g.json", in: folder)
            let c = try GoldenFile(contentsOf: url).require("c")
            #expect(throws: GoldenError.wrongKind(case: "c", key: "ripple", expected: "an integer parameter")) { try c.integer("ripple") }
        }
    }

    @Test(arguments: [
        ("not json at all", "not a JSON object"),
        ("[1, 2, 3]", "not a JSON object"),
        (#"{"oracle": {}, "cases": []}"#, "no generator name"),
        (#"{"generator": "g", "cases": []}"#, "no oracle versions"),
        (#"{"generator": "g", "oracle": {}}"#, "no cases"),
        (#"{"generator": "g", "oracle": {}, "cases": [{"values": {}}]}"#, "a case has no name"),
        (#"{"generator": "g", "oracle": {}, "cases": [{"name": "c"}]}"#, "case c has no values"),
        (#"{"generator": "g", "oracle": {}, "cases": [{"name": "c", "values": {}}, {"name": "c", "values": {}}]}"#, "case c appears twice"),
        (#"{"generator": "g", "oracle": {}, "cases": [{"name": "c", "values": {"v": "text"}}]}"#, "neither an array nor an object"),
        (#"{"generator": "g", "oracle": {}, "cases": [{"name": "c", "values": {"v": [1, "two"]}}]}"#, "neither an array nor an object"),
        (#"{"generator": "g", "oracle": {}, "cases": [{"name": "c", "values": {"v": [true]}}]}"#, "neither an array nor an object"),
        (#"{"generator": "g", "oracle": {}, "cases": [{"name": "c", "values": {"v": {"re": [1, 2], "im": [1]}}}]}"#, "two equal-length arrays"),
        (#"{"generator": "g", "oracle": {}, "cases": [{"name": "c", "values": {"v": {"real": [1]}}}]}"#, "unknown form"),
        (#"{"generator": "g", "oracle": {}, "cases": [{"name": "c", "values": {"v": {"raw": "x.f32"}}}]}"#, "no valid shape"),
        (#"{"generator": "g", "oracle": {}, "cases": [{"name": "c", "values": {"v": {"raw": "x.f32", "shape": [1.5]}}}]}"#, "no valid shape"),
        (#"{"generator": "g", "oracle": {}, "cases": [{"name": "c", "values": {"v": {"raw": "../x.f32", "shape": [1]}}}]}"#, "outside its folder"),
        (#"{"generator": "g", "oracle": {}, "cases": [{"name": "c", "values": {"v": {"raw": "present.bin", "shape": [1]}}}]}"#, "must end in .f32 or .f64"),
        (#"{"generator": "g", "oracle": {}, "cases": [{"name": "c", "parameters": {"p": {"nested": 1}}, "values": {}}]}"#, "unsupported type"),
        (#"{"generator": "g", "oracle": {}, "cases": [{"name": "c", "values": {"v": [1, NaN]}}]}"#, "not a JSON object"),
    ])
    func malformedFilesAreRejected(json: String, reason: String) throws {
        try withFolder { folder in
            try Data([0, 0, 0, 0]).write(to: folder.appendingPathComponent("present.bin"))
            let url = try write(json, "bad.json", in: folder)
            do {
                _ = try GoldenFile(contentsOf: url)
                Issue.record("a malformed file loaded")
            } catch let error as GoldenError {
                guard case .malformed(let file, let found) = error else {
                    Issue.record("expected a malformed error, got \(error)")
                    return
                }
                #expect(file == "bad.json")
                #expect(found.contains(reason), "\(found) does not mention \(reason)")
                #expect(error.description.contains("malformed"))
            }
        }
    }

    @Test func rawFilesMustMatchTheirShape() throws {
        try withFolder { folder in
            try rawFloats([1, 2, 3]).write(to: folder.appendingPathComponent("short.f32"))
            try rawDoubles([1, 2, 3]).write(to: folder.appendingPathComponent("short.f64"))
            try rawFloats([1, .nan]).write(to: folder.appendingPathComponent("nan.f32"))
            try rawDoubles([1, .infinity]).write(to: folder.appendingPathComponent("inf.f64"))
            for (name, shape) in [("short.f32", "[4]"), ("short.f64", "[2, 2]"), ("nan.f32", "[2]"), ("inf.f64", "[2]")] {
                let url = try write("""
                    {"generator": "g", "oracle": {}, "cases": [{"name": "c", "values": {"v": {"raw": "\(name)", "shape": \(shape)}}}]}
                    """, "g.json", in: folder)
                do {
                    _ = try GoldenFile(contentsOf: url)
                    Issue.record("\(name) loaded")
                } catch let error as GoldenError {
                    guard case .malformed(let file, _) = error else { Issue.record("unexpected \(error)"); continue }
                    #expect(file == name)
                }
            }
            let missing = try write("""
                {"generator": "g", "oracle": {}, "cases": [{"name": "c", "values": {"v": {"raw": "absent.f32", "shape": [1]}}}]}
                """, "g.json", in: folder)
            #expect(throws: GoldenError.unreadable(file: "absent.f32")) { try GoldenFile(contentsOf: missing) }
        }
    }

    @Test func missingFilesAreTypedErrors() {
        #expect(throws: GoldenError.unreadable(file: "nowhere.json")) {
            try GoldenFile(contentsOf: URL(fileURLWithPath: "/nonexistent/nowhere.json"))
        }
        #expect(throws: GoldenError.notFound(name: "no-such-vector")) {
            try GoldenFile(named: "no-such-vector", in: .main)
        }
        for error in [GoldenError.notFound(name: "n"), .unreadable(file: "f"), .missingCase(file: "f", name: "n"),
                      .missingValue(case: "c", key: "k"), .wrongKind(case: "c", key: "k", expected: "real")] {
            #expect(!error.description.isEmpty)
        }
    }
}
