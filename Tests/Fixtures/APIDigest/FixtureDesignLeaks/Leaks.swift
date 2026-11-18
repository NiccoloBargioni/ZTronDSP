import FixtureCore

public func leaks() -> Int { packageOnlyHook() }
let hidden = PackageOnlyType()
