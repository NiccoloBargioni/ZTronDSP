import ZTronDSPCore

/// A stage. Its settings are labelled arguments, not an options object (API-6).
public struct Gain: Hashable, Sendable {
    public let decibels: Double
    public let isActive: Bool

    public init(_ decibels: Double, isActive: Bool = true) {
        self.decibels = decibels
        self.isActive = isActive
    }

    func describe(package: String) -> String { package + ".gain" }    // `package` as a label
    func open(path: String) {}                                         // `open` as a name
}

struct DesignOptions {}             // internal: API-6 is about public names
public struct StyleGuide {}         // "Style" is not where the name ends
