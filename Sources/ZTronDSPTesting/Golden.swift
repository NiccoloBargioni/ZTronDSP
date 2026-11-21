import Foundation

/// Why a golden-vector file could not be used. A malformed file is rejected, never read
/// partially.
///
/// A value, usable on any thread; it does not allocate, but for ``description``.
public enum GoldenError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No `<name>.json` in the folder of the bundle that was searched.
    case notFound(name: String)
    /// The file, or a raw file it names, cannot be read.
    case unreadable(file: String)
    /// The file does not have the form it should; `reason` says where.
    case malformed(file: String, reason: String)
    /// No case of that name; `file` holds the name of the generator that wrote the file.
    case missingCase(file: String, name: String)
    /// The case has no value under `key`.
    case missingValue(case: String, key: String)
    /// The entry under `key` is not of the kind `expected` names; for a parameter, a missing one
    /// as well.
    case wrongKind(case: String, key: String, expected: String)

    /// The error in words, naming the file or the case and the entry.
    public var description: String {
        switch self {
        case .notFound(let name): "golden file \(name) is not in the bundle"
        case .unreadable(let file): "golden file \(file) cannot be read"
        case .malformed(let file, let reason): "golden file \(file) is malformed: \(reason)"
        case .missingCase(let file, let name): "golden file \(file) has no case named \(name)"
        case .missingValue(let name, let key): "golden case \(name) has no entry \(key)"
        case .wrongKind(let name, let key, let expected): "entry \(key) of golden case \(name) is not \(expected)"
        }
    }
}

/// One value of a golden case.
///
/// An immutable value, usable on any thread; it does not allocate: it keeps the arrays it is
/// given.
public enum GoldenValue: Sendable, Equatable {
    /// A vector of reals, written inline as a JSON array.
    case real([Double])
    /// A vector of complex values, written inline as `{"re": […], "im": […]}`.
    case complex(real: [Double], imaginary: [Double])
    /// A raw little-endian Float32 file beside the JSON.
    case floats([Float], shape: [Int])
    /// A raw little-endian Float64 file beside the JSON.
    case doubles([Double], shape: [Int])
}

/// A parameter the generator recorded for a case.
///
/// An immutable value, usable on any thread; it does not allocate.
public enum GoldenParameter: Sendable, Equatable {
    /// A JSON number.
    case number(Double)
    /// A JSON string.
    case string(String)
    /// A JSON `true` or `false`.
    case bool(Bool)
    /// A JSON array of numbers.
    case numbers([Double])
}

/// One case of a golden file: the arguments the oracle was called with and what it returned.
///
/// An immutable value, usable on any thread. An accessor allocates when it has to build what it
/// returns (another precision, or a list from one number); otherwise it does not allocate.
public struct GoldenCase: Sendable {
    /// The case's name, unique in its file.
    public let name: String
    /// The parameters the generator recorded, by name.
    public let parameters: [String: GoldenParameter]
    /// What the oracle returned, by key.
    public let values: [String: GoldenValue]

    /// A real vector, whatever its storage.
    public func real(_ key: String) throws(GoldenError) -> [Double] {
        switch try value(key) {
        case .real(let values): return values
        case .doubles(let values, _): return values
        case .floats(let values, _): return values.map(Double.init)
        case .complex: throw .wrongKind(case: name, key: key, expected: "real")
        }
    }

    /// A complex vector as its real and imaginary parts.
    public func complex(_ key: String) throws(GoldenError) -> (real: [Double], imaginary: [Double]) {
        guard case .complex(let real, let imaginary) = try value(key) else {
            throw .wrongKind(case: name, key: key, expected: "complex")
        }
        return (real, imaginary)
    }

    /// A real vector in single precision.
    public func floats(_ key: String) throws(GoldenError) -> [Float] {
        switch try value(key) {
        case .floats(let values, _): return values
        case .real(let values): return values.map { Float($0) }
        case .doubles(let values, _): return values.map { Float($0) }
        case .complex: throw .wrongKind(case: name, key: key, expected: "real")
        }
    }

    /// The shape of a raw array; a plain vector has the shape `[count]`.
    public func shape(_ key: String) throws(GoldenError) -> [Int] {
        switch try value(key) {
        case .floats(_, let shape), .doubles(_, let shape): return shape
        case .real(let values): return [values.count]
        case .complex(let real, _): return [real.count]
        }
    }

    /// A number parameter.
    ///
    /// - Throws: `GoldenError.wrongKind` when the parameter is missing or is not a number.
    public func number(_ parameter: String) throws(GoldenError) -> Double {
        guard case .number(let value)? = parameters[parameter] else {
            throw .wrongKind(case: name, key: parameter, expected: "a number parameter")
        }
        return value
    }

    /// A number parameter that is a whole number of magnitude below 9·10¹⁵.
    ///
    /// - Throws: `GoldenError.wrongKind` when the parameter is missing, is not a number, or is not
    ///   such a whole number.
    public func integer(_ parameter: String) throws(GoldenError) -> Int {
        let value = try number(parameter)
        guard value == value.rounded(), abs(value) < 9e15 else {
            throw .wrongKind(case: name, key: parameter, expected: "an integer parameter")
        }
        return Int(value)
    }

    /// A string parameter.
    ///
    /// - Throws: `GoldenError.wrongKind` when the parameter is missing or is not a string.
    public func string(_ parameter: String) throws(GoldenError) -> String {
        guard case .string(let value)? = parameters[parameter] else {
            throw .wrongKind(case: name, key: parameter, expected: "a string parameter")
        }
        return value
    }

    /// A list of numbers; a single number reads as a list of one.
    ///
    /// - Throws: `GoldenError.wrongKind` when the parameter is missing or is neither.
    public func numbers(_ parameter: String) throws(GoldenError) -> [Double] {
        switch parameters[parameter] {
        case .numbers(let values)?: return values
        case .number(let value)?: return [value]
        default: throw .wrongKind(case: name, key: parameter, expected: "a list of numbers")
        }
    }

    private func value(_ key: String) throws(GoldenError) -> GoldenValue {
        guard let value = values[key] else { throw .missingValue(case: name, key: key) }
        return value
    }
}

/// A golden-vector file written by a generator under `Tests/Golden/generators` (STG-2).
///
/// The format is JSON: `{"generator", "oracle": {library: version}, "cases": [{"name",
/// "parameters", "values"}]}`. A value is an array of numbers, `{"re": […], "im": […]}`, or
/// `{"raw": "<file>.f32|.f64", "shape": […]}` naming a little-endian raw file beside the JSON.
///
/// An immutable value, usable on any thread; loading one reads the file, synchronously, and
/// allocates.
public struct GoldenFile: Sendable {
    /// The name of the generator that wrote the file.
    public let generator: String
    /// The libraries that produced the vectors, with their versions.
    public let oracle: [String: String]
    /// The cases, in the order of the file.
    public let cases: [GoldenCase]

    /// Loads `<name>.json` from the `Golden` folder of a test bundle.
    public init(named name: String, in bundle: Bundle, subdirectory: String? = "Golden") throws(GoldenError) {
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: subdirectory) else {
            throw .notFound(name: name)
        }
        try self.init(contentsOf: url)
    }

    /// Loads the file at `url`, and the raw files it names from the same folder.
    ///
    /// - Throws: `GoldenError.unreadable` for a file that cannot be read, `GoldenError.malformed`
    ///   for one that does not have the form above.
    public init(contentsOf url: URL) throws(GoldenError) {
        let file = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { throw .unreadable(file: file) }
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any]
        else { throw .malformed(file: file, reason: "not a JSON object") }

        guard let generator = root["generator"] as? String else {
            throw .malformed(file: file, reason: "no generator name")
        }
        guard let oracle = root["oracle"] as? [String: String] else {
            throw .malformed(file: file, reason: "no oracle versions")
        }
        guard let rawCases = root["cases"] as? [[String: Any]] else {
            throw .malformed(file: file, reason: "no cases")
        }

        var cases: [GoldenCase] = []
        var names = Set<String>()
        for rawCase in rawCases {
            guard let name = rawCase["name"] as? String else {
                throw .malformed(file: file, reason: "a case has no name")
            }
            guard names.insert(name).inserted else {
                throw .malformed(file: file, reason: "case \(name) appears twice")
            }
            guard let rawValues = rawCase["values"] as? [String: Any] else {
                throw .malformed(file: file, reason: "case \(name) has no values")
            }
            var parameters: [String: GoldenParameter] = [:]
            for (key, raw) in (rawCase["parameters"] as? [String: Any]) ?? [:] {
                guard let parameter = Self.parameter(raw) else {
                    throw .malformed(file: file, reason: "parameter \(key) of case \(name) has an unsupported type")
                }
                parameters[key] = parameter
            }
            var values: [String: GoldenValue] = [:]
            for (key, raw) in rawValues {
                values[key] = try Self.value(raw, key: key, caseName: name, file: file, directory: url.deletingLastPathComponent())
            }
            cases.append(GoldenCase(name: name, parameters: parameters, values: values))
        }

        self.generator = generator
        self.oracle = oracle
        self.cases = cases
    }

    /// The case with the given name.
    public func require(_ name: String) throws(GoldenError) -> GoldenCase {
        guard let found = cases.first(where: { $0.name == name }) else {
            throw .missingCase(file: generator, name: name)
        }
        return found
    }

    // MARK: Decoding

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func numbers(_ raw: Any) -> [Double]? {
        guard let array = raw as? [Any] else { return nil }
        var result: [Double] = []
        result.reserveCapacity(array.count)
        for element in array {
            guard let number = element as? NSNumber, !isBoolean(number) else { return nil }
            let value = number.doubleValue
            guard value.isFinite else { return nil }
            result.append(value)
        }
        return result
    }

    private static func parameter(_ raw: Any) -> GoldenParameter? {
        if let number = raw as? NSNumber {
            return isBoolean(number) ? .bool(number.boolValue) : .number(number.doubleValue)
        }
        if let string = raw as? String { return .string(string) }
        if let values = numbers(raw) { return .numbers(values) }
        return nil
    }

    private static func value(
        _ raw: Any, key: String, caseName: String, file: String, directory: URL
    ) throws(GoldenError) -> GoldenValue {
        if let values = numbers(raw) { return .real(values) }
        guard let object = raw as? [String: Any] else {
            throw .malformed(file: file, reason: "value \(key) of case \(caseName) is neither an array nor an object")
        }
        if let rawReal = object["re"], let rawImaginary = object["im"] {
            guard let real = numbers(rawReal), let imaginary = numbers(rawImaginary), real.count == imaginary.count else {
                throw .malformed(file: file, reason: "complex value \(key) of case \(caseName) needs two equal-length arrays of finite numbers")
            }
            return .complex(real: real, imaginary: imaginary)
        }
        if let rawName = object["raw"] as? String {
            guard let shapeNumbers = numbers(object["shape"] ?? []), !shapeNumbers.isEmpty,
                  shapeNumbers.allSatisfy({ $0 >= 0 && $0 == $0.rounded() })
            else { throw .malformed(file: file, reason: "raw value \(key) of case \(caseName) has no valid shape") }
            let shape = shapeNumbers.map { Int($0) }
            let count = shape.reduce(1, *)
            guard !rawName.contains("/"), !rawName.contains("..") else {
                throw .malformed(file: file, reason: "raw value \(key) of case \(caseName) names a file outside its folder")
            }
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(rawName)) else {
                throw .unreadable(file: rawName)
            }
            if rawName.hasSuffix(".f32") {
                guard data.count == count * 4 else {
                    throw .malformed(file: rawName, reason: "\(data.count) bytes where shape \(shape) needs \(count * 4)")
                }
                let values: [Float] = data.withUnsafeBytes { bytes in
                    (0 ..< count).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
                }
                guard values.allSatisfy(\.isFinite) else { throw .malformed(file: rawName, reason: "a non-finite value") }
                return .floats(values, shape: shape)
            }
            if rawName.hasSuffix(".f64") {
                guard data.count == count * 8 else {
                    throw .malformed(file: rawName, reason: "\(data.count) bytes where shape \(shape) needs \(count * 8)")
                }
                let values: [Double] = data.withUnsafeBytes { bytes in
                    (0 ..< count).map { Double(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self))) }
                }
                guard values.allSatisfy(\.isFinite) else { throw .malformed(file: rawName, reason: "a non-finite value") }
                return .doubles(values, shape: shape)
            }
            throw .malformed(file: file, reason: "raw value \(key) of case \(caseName) must end in .f32 or .f64")
        }
        throw .malformed(file: file, reason: "value \(key) of case \(caseName) has an unknown form")
    }
}
