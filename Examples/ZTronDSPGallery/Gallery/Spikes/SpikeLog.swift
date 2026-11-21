import Foundation

/// What a spike records: numbered lines with the time since the log was made, kept in memory
/// and written into the application's Documents folder as `<name>.log`. A UI test cannot
/// read the application's memory; the file is read from outside, with
/// `xcrun simctl get_app_container <device> com.zombietron.ztrondsp.gallery data`.
///
/// Threading: main actor.
@MainActor
final class SpikeLog {
    let name: String
    private(set) var lines: [String] = []
    private let start = ProcessInfo.processInfo.systemUptime

    init(name: String) {
        self.name = name
    }

    /// Adds a line: its number, the seconds since the log was made, and `text`.
    func note(_ text: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        lines.append(String(format: "%05d %9.4f ", lines.count, elapsed) + text)
    }

    /// Where the log is written.
    var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(name + ".log")
    }

    /// Writes every line recorded so far, replacing what an earlier call wrote.
    func save() {
        guard let url else { return }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Numbers as a spike writes them: short, and the same on every run.
enum SpikeFormat {
    static func number(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    static func point(_ point: CGPoint) -> String {
        "(" + number(point.x) + "," + number(point.y) + ")"
    }

    static func size(_ size: CGSize) -> String {
        "(" + number(size.width) + "," + number(size.height) + ")"
    }
}
