import XCTest

/// The base of the gallery's UI tests.
///
/// While a UI test runs, XCTest reports the crash of any process it holds critical as a
/// failure of that test, and it sees the crashes of every simulator of the Mac, not only of
/// the one the test runs on. On a machine where other simulators run other tests, a crash
/// over there ("Critical process xctest crashed") would fail a test over here. Such a report
/// is passed over unless it names the gallery.
class GalleryUITestCase: XCTestCase {
    override func record(_ issue: XCTIssue) {
        let text = issue.compactDescription
        if text.contains("Critical process"), text.contains("crashed"), !text.contains("ZTronDSPGallery") {
            print("GalleryUITestCase: passed over a crash that is not the gallery's: \(text)")
            return
        }
        super.record(issue)
    }
}
