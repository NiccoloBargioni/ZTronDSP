# ``ZTronDSPIO``

The sources that reach the hardware and the app's own audio: the microphone and the inputs the
system offers, a tap on a node of the app's audio engine, a file, and the audio-session policy they
share.

## Overview

Every source here is a `SampleSource` of the core: a pipeline is attached to it with
`DSPEngine.attach(_:to:)` as to any other. The engine calls `prepare`, `start`, `stop` and
`connect(to:)` on its control context. What runs on Core Audio's I/O thread for
``HardwareInputSource`` is one nonblocking C function that copies frames into the engine's ring;
when the ring is full the newest frames are dropped and counted, and the session reports an
overrun. ``AudioSessionPolicy`` says what capture may do to the app's audio session, and
``AudioSessionControlling`` is what the package asks of that session: the one seam between the
capture rules and `AVAudioSession`, which a test drives with a session of its own.

## Topics

### Sources

- ``HardwareInputSource``
- ``AudioInput``
- ``EngineNodeTapSource``
- ``FileSource``

### The audio session

- ``AudioSessionPolicy``
- ``AudioSessionControlling``
