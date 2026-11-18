/// Declarations only: nothing here executes, and xccov leaves the file out of its report.
public protocol SignalDomain {
    static var name: String { get }
    func describe() -> String
    subscript(index: Int) -> Int { get }
}
public enum Samples {}
