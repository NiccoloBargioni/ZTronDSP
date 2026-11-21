# ``ZTronDSPTesting``

What the author of a stage needs to test it as the package tests its own: allocation audits,
closeness with a stated tolerance, seeded signals, golden vectors and benchmarks.

## Overview

A stage written outside the package is held to the rules the stock stages are held to (EXT-3), and
this product is how. ``expectNoAllocations(_:sourceLocation:_:)`` fails when the code it runs asks
the heap for anything on the caller's thread, and
``expectNoAllocationsRunning(_:format:blockSize:blocks:crossovers:_:sourceLocation:)`` compiles a
pipeline as an attachment does and runs its plan block by block on the caller's thread, inside
such an audit. ``expectClose(_:_:_:_:sourceLocation:)-(A,_,_,_,_)`` holds a sequence within a
``Tolerance`` of another and names the worst element when it is not. ``TestSignal`` and
``SeededGenerator`` make the same signal on every run, and ``GoldenFile`` reads the vectors an
oracle wrote.

The expectations are called from a test, on the test's own thread; they allocate outside what they
audit, and to record an issue. ``ThreadAllocationAudit`` is opened and closed on the thread it
audits, which may be an engine's analysis thread reached through a sink's callback, and neither
allocates there.

## Topics

### Allocation audits

- ``expectNoAllocations(_:sourceLocation:_:)``
- ``expectNoAllocationsRunning(_:format:blockSize:blocks:crossovers:_:sourceLocation:)``
- ``countAllocations(_:)``
- ``AllocationCounts``
- ``AllocationAudit``
- ``AllocationAuditError``
- ``ThreadAllocationAudit``
- ``forceAllocation(byteCount:)``
- ``forceReallocation(from:to:)``

### Closeness

- ``expectClose(_:_:_:_:sourceLocation:)-(A,_,_,_,_)``
- ``expectClose(_:_:_:_:sourceLocation:)-(T,_,_,_,_)``
- ``Tolerance``
- ``Closeness``
- ``ClosenessFailure``

### Signals

- ``TestSignal``
- ``SeededGenerator``
- ``StressFixture``
- ``Click``
- ``MedianOracle``
- ``floatingPointEnvironmentDigest()``

### Golden vectors

- ``GoldenFile``
- ``GoldenCase``
- ``GoldenValue``
- ``GoldenParameter``
- ``GoldenError``

### Benchmarks

- ``Benchmark``
- ``BenchmarkResult``
- ``BenchmarkReport``
- ``BenchmarkRegression``
