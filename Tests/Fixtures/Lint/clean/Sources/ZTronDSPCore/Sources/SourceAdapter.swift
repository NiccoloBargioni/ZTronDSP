/// The one place that tells push from pull (ATT-2). It is not under Engine/.
enum SourceAdapter {
    static func isPush(_ source: any SampleSource) -> Bool {
        source is any PushSampleSource
    }
}

protocol PushSampleSource: SampleSource {}
