// A world small enough to see through: three domains, three stages, and where each may stand.
protocol Domain {}
enum A: Domain {}
enum B: Domain {}
enum C: Domain {}
struct OnA { init() {} }
struct OnAB { init() {} }
struct Everywhere { init() {} }
func after(_ domain: A.Type, _ stage: OnA) {}
func after(_ domain: A.Type, _ stage: OnAB) {}
func after(_ domain: B.Type, _ stage: OnAB) {}
func after<D: Domain>(_ domain: D.Type, _ stage: Everywhere) {}
