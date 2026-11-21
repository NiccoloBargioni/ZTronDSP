// expect: cannot find 'TestSignal' in scope
// expect: cannot find 'expectNoAllocations' in scope
// expect: cannot find 'ztdt_alloc_audit_begin' in scope
//
// §4.2, WP-901a: the test product `ZTronDSPTesting` (EXT-3) and its C half are imported by a test
// target of their own accord; the facade re-exports neither.
import ZTronDSP

func audited() {
    let signal = TestSignal.self
    expectNoAllocations { _ = signal }
    ztdt_alloc_audit_begin()
}
