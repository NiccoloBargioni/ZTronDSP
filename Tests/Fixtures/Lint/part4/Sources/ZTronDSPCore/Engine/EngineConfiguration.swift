public struct EngineConfiguration {                         // !! API-6
    public var blockSize: Int = 512                         // !! IMM-2
    public let crossovers: Int = 0
}
public final class SpectrogramStyle {}                      // !! API-6
public enum FilterSpecification {}                          // !! API-6
public protocol ExportOptions {}                            // !! API-6
public typealias RenderSettings = Int                       // !! API-6
public struct FeedDescriptor {}                             // !! API-6
public struct LowPassSpecs {}                               // !! API-6
public actor PlanParams {}                                  // !! API-6
public extension EngineConfiguration {
    struct NestedOptions {}                                 // !! API-6
}
