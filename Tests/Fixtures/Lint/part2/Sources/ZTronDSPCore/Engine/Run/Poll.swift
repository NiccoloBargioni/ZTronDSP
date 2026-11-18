func poll(_ source: any SampleSource) -> Bool {
    source is GeneratorSource                        // !! ATT-2
}
