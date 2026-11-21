import Foundation
import Testing

/// Asks whoever runs the tests from outside to do what a test cannot do from inside the
/// application: bring another application to the front, and the gallery back. `gallery.sh`
/// watches the application's Documents folder for the request and uses `simctl` for it; it
/// says that it does so in the environment of the tests.
enum Stagehand {
    /// True when the run has someone who answers.
    static var isPresent: Bool {
        ProcessInfo.processInfo.environment["GALLERY_STAGEHAND"] != nil
    }

    /// `leave`: another application is brought to the front. `return`: the gallery is.
    static func ask(_ request: String) throws {
        let folder = try #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        try request.write(to: folder.appendingPathComponent("stagehand-request"), atomically: true, encoding: .utf8)
    }
}
