/// The namespace of the package's one-shot functions: conversions, transform lengths,
/// convolution and the like (specification §6). They are plain computations: synchronous,
/// and they run where they are called (§9.2), so each may be called on any thread. A function
/// that returns an array allocates it; the pointer forms say when they do not allocate and may
/// run on the analysis thread.
public enum DSP {}
