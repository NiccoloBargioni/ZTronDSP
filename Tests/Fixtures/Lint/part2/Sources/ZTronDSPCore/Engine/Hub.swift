final class Hub {
    func attach(_ source: any SampleSource) {
        if source is PushSampleSource { }                           // !! ATT-2
        if let pull = source as? any PullSampleSource { _ = pull }  // !! ATT-2
        let hardware = source as! HardwareInputSource               // !! ATT-2
        _ = hardware
        switch source {
        case let file as FileSource: _ = file                       // !! ATT-2
        case is ZTronDSPIO.EngineNodeTapSource: break               // !! ATT-2
        default: break
        }
        let upcast = source as any SampleSource
        _ = upcast
        for session in [source] { _ = session }      // not a hot directory: `for … in` is allowed here
    }
}
