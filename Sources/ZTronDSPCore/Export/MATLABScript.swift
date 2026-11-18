import Foundation

/// Anything that exports as a MATLAB script (§6.14, MAT-1). The script defines its data as
/// variables and then plots them; it is text, and the app decides where it goes (MAT-5).
///
/// `matlabScript()` runs in the background (BG-1, MAT-6): never on the main thread.
public protocol MATLABExportable: Sendable {
    func matlabScript() async throws(DSPError) -> String
}

/// A MATLAB script under construction: variable definitions, then plot commands (MAT-2).
///
/// The commands are core MATLAB only, so a script also runs in GNU Octave. Numbers are
/// written so that they read back exactly: 17 significant digits from `Double`, 9 from
/// `Float`; an undefined value is written as `NaN`, which a plot skips (MAT-3). A script
/// carries no date and no machine name: equal input gives equal text (MAT-4).
///
/// A script is an immutable value; every call returns a new one. Building one allocates and
/// belongs on the background executor, never on the analysis thread.
public struct MATLABScript: Hashable, Sendable {
    /// The lines of the script, in order.
    public let lines: [String]

    /// The most elements one variable may hold (MAT-4).
    public static let elementLimit = 4_000_000

    public init() {
        lines = []
    }

    init(lines: [String]) {
        self.lines = lines
    }

    /// The script as text, one statement per line, ending in a newline.
    public var text: String {
        lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    private func adding(_ line: String) -> MATLABScript {
        MATLABScript(lines: lines + [line])
    }

    // MARK: Numbers

    /// A `Double` as MATLAB reads it back exactly.
    public static func format(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Inf" : "Inf" }
        return String(format: "%.17g", value)
    }

    /// A `Float` as MATLAB reads it back exactly.
    public static func format(_ value: Float) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Inf" : "Inf" }
        return String(format: "%.9g", Double(value))
    }

    private static func checkName(_ name: String) throws(DSPError) {
        let scalars = Array(name.unicodeScalars)
        let isLetter: (Unicode.Scalar) -> Bool = { ("a" ... "z").contains($0) || ("A" ... "Z").contains($0) }
        let isDigit: (Unicode.Scalar) -> Bool = { ("0" ... "9").contains($0) }
        guard let first = scalars.first, isLetter(first), scalars.count <= 63,
              scalars.allSatisfy({ isLetter($0) || isDigit($0) || $0 == "_" })
        else {
            throw .invalidParameter(stage: .none, parameter: "name", reason: "\"\(name)\" is not a MATLAB variable name")
        }
    }

    private static func checkSize(_ elements: Int) throws(DSPError) {
        guard elements <= elementLimit else {
            throw .exportTooLarge(elements: elements, limit: elementLimit)
        }
    }

    private static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''").replacingOccurrences(of: "\n", with: " ") + "'"
    }

    // MARK: Variables

    /// A comment line.
    public func comment(_ text: String) -> MATLABScript {
        adding("% " + text.replacingOccurrences(of: "\n", with: " "))
    }

    /// A scalar.
    public func scalar(_ name: String, _ value: Double) throws(DSPError) -> MATLABScript {
        try Self.checkName(name)
        return adding("\(name) = \(Self.format(value));")
    }

    /// A row vector of doubles.
    public func vector(_ name: String, _ values: [Double]) throws(DSPError) -> MATLABScript {
        try Self.checkName(name)
        try Self.checkSize(values.count)
        return adding("\(name) = [\(values.map { Self.format($0) }.joined(separator: " "))];")
    }

    /// A row vector of single-precision values.
    public func vector(_ name: String, _ values: [Float]) throws(DSPError) -> MATLABScript {
        try Self.checkName(name)
        try Self.checkSize(values.count)
        return adding("\(name) = [\(values.map { Self.format($0) }.joined(separator: " "))];")
    }

    /// A row vector of optional values; `nil` is written as `NaN` (MAT-3).
    public func vector(_ name: String, optional values: [Double?]) throws(DSPError) -> MATLABScript {
        try vector(name, values.map { $0 ?? .nan })
    }

    /// A complex row vector.
    public func vector(_ name: String, real: [Double], imaginary: [Double]) throws(DSPError) -> MATLABScript {
        try Self.checkName(name)
        guard real.count == imaginary.count else {
            throw .invalidParameter(stage: .none, parameter: name, reason: "\(real.count) real parts and \(imaginary.count) imaginary parts")
        }
        try Self.checkSize(real.count)
        let elements = zip(real, imaginary).map { re, im -> String in
            let sign = im.sign == .minus ? "-" : "+"
            return "\(Self.format(re))\(sign)\(Self.format(abs(im)))i"
        }
        return adding("\(name) = [\(elements.joined(separator: " "))];")
    }

    /// A matrix from its rows, which must be of equal length.
    public func matrix(_ name: String, rows: [[Double]]) throws(DSPError) -> MATLABScript {
        try Self.checkName(name)
        let columns = rows.first?.count ?? 0
        guard rows.allSatisfy({ $0.count == columns }) else {
            throw .invalidParameter(stage: .none, parameter: name, reason: "the rows of a matrix must be of equal length")
        }
        try Self.checkSize(rows.count * columns)
        let body = rows.map { $0.map { Self.format($0) }.joined(separator: " ") }.joined(separator: "; ")
        return adding("\(name) = [\(body)];")
    }

    /// A single-precision matrix stored row by row: `rows · columns` values.
    public func matrix(_ name: String, values: [Float], rows: Int, columns: Int) throws(DSPError) -> MATLABScript {
        try Self.checkName(name)
        guard rows >= 0, columns >= 0, values.count == rows * columns else {
            throw .invalidParameter(stage: .none, parameter: name, reason: "\(values.count) values do not fill \(rows) × \(columns)")
        }
        try Self.checkSize(values.count)
        var parts: [String] = []
        parts.reserveCapacity(rows)
        for row in 0 ..< rows {
            parts.append(values[row * columns ..< (row + 1) * columns].map { Self.format($0) }.joined(separator: " "))
        }
        return adding("\(name) = [\(parts.joined(separator: "; "))];")
    }

    // MARK: Plot commands (core MATLAB only)

    /// The line styles a plot command takes, such as `"-"`, `"o"`, `"r--"`.
    private func plotting(_ command: String, _ x: String, _ y: String, _ style: String?) -> MATLABScript {
        adding(style.map { "\(command)(\(x), \(y), \(Self.quoted($0)));" } ?? "\(command)(\(x), \(y));")
    }

    /// `plot(x, y)`: the names of two variables, or expressions over them.
    public func plot(_ x: String, _ y: String, style: String? = nil) -> MATLABScript { plotting("plot", x, y, style) }
    /// `semilogx(x, y)`.
    public func semilogx(_ x: String, _ y: String, style: String? = nil) -> MATLABScript { plotting("semilogx", x, y, style) }
    /// `loglog(x, y)`.
    public func loglog(_ x: String, _ y: String, style: String? = nil) -> MATLABScript { plotting("loglog", x, y, style) }
    /// `stem(x, y)`.
    public func stem(_ x: String, _ y: String, style: String? = nil) -> MATLABScript { plotting("stem", x, y, style) }

    /// `imagesc(x, y, c)` with the y axis pointing up, as a heat map is read.
    public func imagesc(_ x: String, _ y: String, _ c: String) -> MATLABScript {
        adding("imagesc(\(x), \(y), \(c));").adding("axis xy;")
    }

    /// `subplot(rows, columns, index)`.
    public func subplot(_ rows: Int, _ columns: Int, _ index: Int) -> MATLABScript {
        adding("subplot(\(rows), \(columns), \(index));")
    }

    public func xlabel(_ text: String) -> MATLABScript { adding("xlabel(\(Self.quoted(text)));") }
    public func ylabel(_ text: String) -> MATLABScript { adding("ylabel(\(Self.quoted(text)));") }
    public func title(_ text: String) -> MATLABScript { adding("title(\(Self.quoted(text)));") }
    /// `grid on` or `grid off`.
    public func grid(_ on: Bool = true) -> MATLABScript { adding(on ? "grid on;" : "grid off;") }
    /// `hold on` or `hold off`.
    public func hold(_ on: Bool = true) -> MATLABScript { adding(on ? "hold on;" : "hold off;") }
    public func colorbar() -> MATLABScript { adding("colorbar;") }
    /// `axis` with a keyword: `equal`, `tight`, `square`, `xy`, `ij`.
    public func axis(_ keyword: String) -> MATLABScript {
        adding("axis \(keyword.filter { $0.isLetter });")
    }
    /// `axis([xmin xmax ymin ymax])`.
    public func axis(x: ClosedRange<Double>, y: ClosedRange<Double>) -> MATLABScript {
        adding("axis([\(Self.format(x.lowerBound)) \(Self.format(x.upperBound)) \(Self.format(y.lowerBound)) \(Self.format(y.upperBound))]);")
    }

    /// The scripts joined, this one first.
    public func appending(_ other: MATLABScript) -> MATLABScript {
        MATLABScript(lines: lines + other.lines)
    }
}
