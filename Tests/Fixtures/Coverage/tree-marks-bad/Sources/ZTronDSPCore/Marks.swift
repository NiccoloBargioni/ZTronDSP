public func clamp(_ x: Int) -> Int {
    if x < 0 { return 0 } // coverage:ignore()
    if x > 9 { return 9 } // coverage:ignore(this line is executed by the tests)
    // coverage:ignore(a mark above a line that is not executable)

    // only a comment follows
    return x
}
