/// Engine code: it never asks what kind of source it serves (ATT-2).
final class SessionHub<S: SampleSource> {
    let source: any SampleSource
    var isPushSource: Bool { false }

    init(source: S) {
        self.source = source as any SampleSource    // an upcast, not a test of the type
    }

    func describe(_ value: Any) -> String {
        if value is Int { return "a number" }
        if let text = value as? String { return text }
        return "something"
    }
}

protocol SampleSource: AnyObject {}
