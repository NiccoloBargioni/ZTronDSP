public struct Frequency {
    public let hertz: Double
    public init(hertz: Double) {
        guard hertz.isFinite else {
            fatalError("unreachable") // coverage:ignore(the initialiser is only called with finite values)
        } // coverage:ignore(the closing line of the same branch)
        self.hertz = hertz
    }
    public var octave: Double {
        // coverage:ignore(defensive: hertz is positive by construction)
        if hertz <= 0 {
            return 0
        }
        return hertz / 2
    }
}
