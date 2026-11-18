import AVFAudio
import Foundation
import Testing
import ZTronDSPCore
@testable import ZTronDSPIO

/// What a simulator allows of the real thing: the process's own `AVAudioSession`, a real
/// `AVAudioEngine` with the sink node of the factory, and the host's microphone as the
/// simulator passes it on (WP-704 smoke test; WP-708 as far as a simulator goes).
///
/// The tests share the one audio session of the test process, so they run one after another,
/// and each puts the category back. Every test that makes a real `AVAudioEngine` is in this
/// suite for the same reason: on the simulator the audio units behind several engines are
/// opened in the test process itself, and opening them side by side from parallel tests has
/// ended in AudioToolbox's "Initialize: RPC timeout. Apparently deadlocked. Aborting now." Everything that waits on hardware is time-boxed, and what
/// the environment did is written to the log on lines that start with `[ZTD-SIM]`: a machine
/// without an input, or with another answer to the permission, is an environment, not a
/// failure.
///
/// The test host is the `xctest` agent. The system cannot construct a privacy identity for
/// it, so its permission to record reads as denied and cannot be granted; the tests that
/// capture therefore replace the one seam that asks, and nothing else.
@Suite("Simulator", .serialized)
struct SimulatorTests {
    static func note(_ text: String) {
        print("[ZTD-SIM] \(text)")
    }

    /// Puts the process's session back to what a new process has.
    private func restoreSession() {
        try? AVAudioSession.sharedInstance().setCategory(.soloAmbient, mode: .default, options: [])
    }

    /// Whether this machine's input delivers anything at all, asked of AVFAudio alone: a plain
    /// tap on the input node of an engine of the test's own, with nothing of the package in
    /// between. It is the measure of what the package's own capture must then deliver.
    private func inputDelivers() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        guard (try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])) != nil,
              (try? session.setActive(true)) != nil else { return false }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }
        let heard = Shared(0)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { buffer, _ in
            heard.withLock { $0 += Int(buffer.frameLength) }
        }
        defer {
            input.removeTap(onBus: 0)
            engine.stop()
        }
        guard (try? engine.start()) != nil else { return false }
        return await eventually(timeout: 3) { heard.get() > 0 }
    }

    /// A hardware source on the real session and the real engine, with the user's answer given.
    private func realSource(policy: AudioSessionPolicy = .playAndRecord, voiceProcessing: Bool = false, interfaces: SystemInterfaces = .current) -> HardwareInputSource {
        HardwareInputSource(
            input: nil, dataSource: nil, policy: policy, voiceProcessing: voiceProcessing, session: SystemAudioSession(),
            authorizer: FakeAuthorizer(.granted), capture: EngineInputCapture(interfaces: interfaces), notifications: .default)
    }

    // MARK: The permission of the test host

    @Test(.timeLimit(.minutes(1)))
    func aHostWithoutPermissionIsRefusedBeforeTheSessionIsTouched() async throws {
        defer { restoreSession() }
        restoreSession()
        let permission = SystemMicrophoneAuthorizer().permission
        Self.note("host \(Bundle.main.bundleIdentifier ?? "?"), permission to record: \(permission)")
        switch permission {
        case .denied:
            await #expect(throws: DSPError.permissionDenied) { try await HardwareInputSource().prepare() }
            await #expect(throws: DSPError.permissionDenied) { try await DSPEngine(blockSize: 512).attach(Pipeline(), to: HardwareInputSource()) }
            #expect(AVAudioSession.sharedInstance().category == .soloAmbient, "the session is not touched for a user who said no")
        case .granted:
            let source = HardwareInputSource()
            try await source.prepare()
            #expect(source.format.isValid)
        case .undetermined:
            // Asking would put up a prompt nobody answers.
            Self.note("permission undetermined: the public initialiser was not prepared")
        }
    }

    // MARK: The system's session behind the seam

    /// The adapter over `AVAudioSession` reads what the session says and reports what the
    /// system refuses as an error of the package.
    @Test func theSystemSessionForwardsAndTranslates() throws {
        defer { restoreSession() }
        restoreSession()
        let system = SystemAudioSession()
        let real = AVAudioSession.sharedInstance()
        #expect(system.category == real.category && system.mode == real.mode && system.categoryOptions == real.categoryOptions)
        #expect(system.isInputAvailable == real.isInputAvailable)
        #expect(system.availableInputs.map(\.id) == (real.availableInputs ?? []).map(\.uid))
        #expect(system.currentInput?.id == real.currentRoute.inputs.first?.uid)
        let absent = AudioInput(id: "no-such-port", name: "Nowhere", kind: .usb)
        #expect(throws: DSPError.sourceUnavailable(reason: "the input Nowhere is not available")) { try system.setPreferredInput(absent) }
        #expect(throws: DSPError.sourceUnavailable(reason: "the input Nowhere is not available")) { try system.setPreferredDataSource("Front", for: absent) }

        // What the system accepts is what the session then says.
        try system.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        #expect(real.category == .playAndRecord && real.mode == .measurement && real.categoryOptions == [.defaultToSpeaker, .allowBluetoothA2DP])
        try system.setAllowHapticsAndSystemSoundsDuringRecording(true)
        #expect(real.allowHapticsAndSystemSoundsDuringRecording)
        try system.setActive(true, options: [])
        try system.setPreferredInput(nil)
        if let input = system.availableInputs.first {
            try system.setPreferredInput(input)
            #expect(throws: DSPError.self) { try system.setPreferredDataSource("no such data source", for: input) }
            Self.note("the simulator's input: \(input.name), \(input.kind), data sources \(input.dataSources)")
        }
    }

    @Test func theInputsOfTheSimulatorAreListed() async throws {
        defer { restoreSession() }
        restoreSession()
        do throws(DSPError) {
            _ = try await HardwareInputSource.availableInputs(policy: .external)
            Issue.record("solo ambient permits no input")
        } catch {
            guard case .sessionConfigurationFailed(let reason) = error else {
                Issue.record("expected sessionConfigurationFailed, got \(error)")
                return
            }
            #expect(reason.contains(AVAudioSession.Category.soloAmbient.rawValue))
        }
        #expect(AVAudioSession.sharedInstance().category == .soloAmbient, ".external never mutates the session")

        let inputs = try await HardwareInputSource.availableInputs()
        Self.note("inputs under .playAndRecord: \(inputs.map { "\($0.name) (\($0.kind))" })")
        #expect(AVAudioSession.sharedInstance().category == .playAndRecord, "the category is brought to where the policy wants it")
        #expect(inputs.allSatisfy { $0.kind != .bluetooth }, "no Bluetooth microphone under a policy that did not ask for one")
        #expect(inputs == SystemAudioSession().availableInputs)
        #expect(Set(inputs.map(\.id)).count == inputs.count, "every input has an identifier of its own")
    }

    // MARK: WP-704: the smoke test

    /// Format discovered, frames delivered: the real session, the real engine, the sink node
    /// made with the real-time-safe initialiser where the system has it and with the classic
    /// one, and whatever the simulator passes on as the microphone.
    ///
    /// A machine without an input cannot deliver frames, and that is its environment. What no
    /// environment explains is one kind of sink node delivering and the other not: the two
    /// run the same block on the same input.
    @Test(.timeLimit(.minutes(1)))
    func smoke() async throws {
        defer { restoreSession() }
        let microphoneWorks = await inputDelivers()
        Self.note("smoke: AVFAudio's own tap on the input \(microphoneWorks ? "hears frames" : "hears nothing") on this machine")
        var delivered: [SystemInterfaces: Bool] = [:]
        for interfaces in [SystemInterfaces.current, .classic] {
            restoreSession()
            let source = realSource(interfaces: interfaces)
            do throws(DSPError) {
                try await source.prepare()
            } catch {
                // No input on this machine: there is nothing to smoke-test, and nothing hangs.
                Self.note("smoke (\(interfaces)): the source could not be prepared: \(error)")
                guard case .sourceUnavailable = error else {
                    Issue.record("a simulator without an input is sourceUnavailable, not \(error)")
                    return
                }
                continue
            }
            let format = source.format
            #expect(format.isValid && format.channelCount >= 1, "the format is discovered: \(format)")
            let session = AVAudioSession.sharedInstance()
            #expect(session.category == .playAndRecord && session.categoryOptions == [.defaultToSpeaker, .allowBluetoothA2DP], "CAP-1, CAP-2 on the real session")
            #expect(session.allowHapticsAndSystemSoundsDuringRecording, "CAP-5 on the real session")

            let attached = try await Attachment(source, blockSize: 512)
            #expect(attached.session.environment.sampleRate == format.sampleRate && attached.session.environment.channelCount == format.channelCount)
            try attached.session.start()
            let tenth = Int(format.sampleRate / 10)
            let arrived = await eventually(timeout: 5) { attached.sink.frameCount >= tenth }
            delivered[interfaces] = arrived
            let samples = attached.sink.samples()
            let peak = samples.map { abs($0) }.max() ?? 0
            Self.note("smoke (\(interfaces)): format \(format); \(attached.sink.frameCount) frames in the time box; peak \(peak); real-time-safe initialiser \(ztd_sink_node_has_realtime_safe_initialiser())")
            #expect(arrived || !microphoneWorks, "the input delivers on this machine, so the source delivers: frames within five seconds")
            if arrived {
                #expect(attached.sink.channelCount == format.channelCount, "frames arrive in the discovered format")
                #expect(samples.allSatisfy { $0.isFinite })
                #expect(attached.sink.blockSizes.allSatisfy { $0 == 512 })
                #expect(attached.session.state == .running)
                #expect(!attached.log.all.contains { if case .overrun = $0 { true } else { false } }, "the analysis thread keeps up with the hardware")
            } else {
                Self.note("smoke (\(interfaces)): the engine started and delivered no frames within five seconds")
            }
            attached.session.stop()
            let stopped = attached.sink.frameCount
            await pause(milliseconds: 100)
            #expect(attached.sink.frameCount == stopped, "a stopped source delivers nothing")
            attached.session.detach()
        }
        #expect(delivered[.current] == delivered[.classic], "the sink node of either initialiser delivers, or neither does: \(delivered)")
    }

    /// The real capture engine, step by step, as the source takes the steps.
    @Test(.timeLimit(.minutes(1)))
    func theRealCaptureEngineTakesEveryStep() async throws {
        defer { restoreSession() }
        restoreSession()
        let capture = EngineInputCapture()
        #expect(capture.engineIdentity == nil && !capture.inputFormat().isValid, "nothing is built before the first rebuild")
        capture.stop()
        capture.disconnect()
        capture.setRing(nil)
        #expect(throws: DSPError.self) { try capture.connect() }
        #expect(throws: DSPError.self) { try capture.start() }
        try capture.setVoiceProcessing(false)

        try capture.rebuild()
        #expect(capture.engineIdentity != nil)
        try capture.rebuild()
        #expect(capture.engineIdentity != nil, "a rebuild is an engine again")

        // The input has its format once the session permits input and is active.
        try SystemAudioSession().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try SystemAudioSession().setActive(true, options: [])
        try capture.rebuild()
        let format = capture.inputFormat()
        Self.note("capture engine: the input delivers \(format)")
        guard format.isValid else { return }
        try capture.connect()
        capture.disconnect()
        try capture.connect()
        try capture.start()
        await pause(milliseconds: 50)
        // A session whose engine runs is busy: where the system refuses to deactivate it, the
        // refusal is an error of the package.
        do throws(DSPError) {
            try SystemAudioSession().setActive(false, options: [])
            Self.note("capture engine: the simulator deactivated a session whose engine runs")
            try SystemAudioSession().setActive(true, options: [])
        } catch {
            Self.note("capture engine: deactivation refused while the engine runs: \(error)")
            guard case .sessionConfigurationFailed = error else {
                Issue.record("expected sessionConfigurationFailed, got \(error)")
                return
            }
        }
        capture.stop()
        capture.stop()
    }

    @Test(.timeLimit(.minutes(1)))
    func voiceProcessingIsAskedOfTheRealEngine() async throws {
        defer { restoreSession() }
        restoreSession()
        let source = realSource(voiceProcessing: true)
        do throws(DSPError) {
            try await source.prepare()
            Self.note("voice processing: prepared, format \(source.format)")
            #expect(source.format.isValid)
        } catch {
            Self.note("voice processing: refused here: \(error)")
            switch error {
            case .unsupportedConfiguration, .sourceUnavailable: break
            default: Issue.record("a refusal of voice processing is unsupportedConfiguration or sourceUnavailable, not \(error)")
            }
        }
    }

    // MARK: WP-708: capture while the app plays, as far as a simulator goes

    /// The app's player: an engine of its own that plays silence in a loop on the output.
    final class Player: @unchecked Sendable {
        // `@unchecked Sendable`: the test starts and stops it on its own task; the closures that
        // watch it only read what the engine says about itself.
        let engine = AVAudioEngine()
        private let node = AVAudioPlayerNode()

        func start() throws {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
            let silence = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
            silence.frameLength = 4_410
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            try engine.start()
            node.scheduleBuffer(silence, at: nil, options: .loops)
            node.play()
        }

        /// Frames the output has rendered: it moves for as long as playback renders.
        var renderedFrames: Int64 { engine.outputNode.lastRenderTime?.sampleTime ?? -1 }
    }

    /// What the system posted while the test ran.
    final class Posted: Sendable {
        private let counts = Shared<[String: Int]>([:])
        private let tokens = Shared<[any NSObjectProtocol]>([])

        init(player: AVAudioEngine) {
            let counts = counts
            let identity = ObjectIdentifier(player)
            var tokens: [any NSObjectProtocol] = []
            for (key, name) in [("interruption", AVAudioSession.interruptionNotification), ("route", AVAudioSession.routeChangeNotification),
                                ("reset", AVAudioSession.mediaServicesWereResetNotification)] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                    counts.withLock { $0[key, default: 0] += 1 }
                })
            }
            tokens.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { notification in
                let isPlayer = notification.object.map { ObjectIdentifier($0 as AnyObject) } == identity
                counts.withLock { $0[isPlayer ? "player configuration" : "other configuration", default: 0] += 1 }
            })
            self.tokens.set(tokens)
        }

        deinit {
            for token in tokens.get() { NotificationCenter.default.removeObserver(token) }
        }

        func count(_ key: String) -> Int { counts.withLock { $0[key, default: 0] } }
        var all: [String: Int] { counts.get() }
    }

    /// Playback first, then capture, on the real session: what the simulator shows of the two
    /// cases of §4.6. The app's player is restarted once if the category change stopped it,
    /// as an app does on a configuration change.
    @Test(.timeLimit(.minutes(1)), arguments: [AVAudioSession.Category.playAndRecord, .playback])
    func captureWhileTheAppPlays(category: AVAudioSession.Category) async throws {
        defer { restoreSession() }
        // Before the app's session is set up: whether this machine's input delivers at all.
        let microphoneWorks = await inputDelivers()
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = category == .playAndRecord ? [.defaultToSpeaker] : []
        try session.setCategory(category, mode: .default, options: options)
        try session.setActive(true)
        let player = Player()
        do {
            try player.start()
        } catch {
            Self.note("capture while playing (\(category.rawValue)): the simulator has no output to play on: \(error)")
            return
        }
        defer { player.engine.stop() }
        guard await eventually(timeout: 5, { player.renderedFrames > 4_410 }) else {
            Self.note("capture while playing (\(category.rawValue)): the player started and rendered nothing within five seconds: no output on this machine")
            return
        }
        let outputBefore = session.currentRoute.outputs.map(\.portType)
        let posted = Posted(player: player.engine)
        let renderedBefore = player.renderedFrames

        let source = realSource()
        do throws(DSPError) {
            try await source.prepare()
        } catch {
            Self.note("capture while playing (\(category.rawValue)): no input on this machine: \(error)")
            return
        }
        let attached = try await Attachment(source, blockSize: 512)
        try attached.session.start()
        let tenth = Int(source.format.sampleRate / 10)
        let arrived = await eventually(timeout: 5) { attached.sink.frameCount >= tenth }
        await pause(milliseconds: 300)

        // An app restarts its player when the engine says its configuration changed.
        var restarted = false
        if !player.engine.isRunning {
            try player.engine.start()
            restarted = true
        }
        let renderedAfterCapture = player.renderedFrames
        await pause(milliseconds: 300)
        let stillRendering = player.renderedFrames > renderedAfterCapture || player.renderedFrames > renderedBefore
        Self.note("capture while playing (\(category.rawValue)): frames arrived \(arrived) (\(attached.sink.frameCount)); posted \(posted.all); "
            + "player restarted \(restarted), rendering \(stillRendering); output \(outputBefore.map(\.rawValue)) → \(session.currentRoute.outputs.map { $0.portType.rawValue }); "
            + "category \(session.category.rawValue), options \(session.categoryOptions.rawValue)")

        #expect(arrived || !microphoneWorks, "the input delivers on this machine, so frames arrive while the app plays")
        #expect(posted.count("interruption") == 0, "no interruption")
        #expect(posted.count("reset") == 0)
        #expect(session.currentRoute.outputs.map(\.portType) == outputBefore, "playback stays on the same output port")
        #expect(posted.count("player configuration") <= 1, "at most one configuration change for the app's player")
        #expect(stillRendering, "playback renders while the microphone is captured")
        #expect(session.category == .playAndRecord)
        if category == .playAndRecord {
            // Case A: nothing is reconfigured.
            #expect(session.categoryOptions == options && session.mode == .default, "the app's options are untouched (CAP-3)")
            #expect(!restarted && posted.count("player configuration") == 0, "the app's player was not disturbed")
        } else {
            // Case B: one change, with the options that keep playback where it was.
            #expect(session.categoryOptions == [.defaultToSpeaker, .allowBluetoothA2DP])
        }
        if arrived { #expect(attached.sink.samples().allSatisfy { $0.isFinite }) }
        attached.session.stop()
        attached.session.detach()
    }

    // MARK: WP-706: a real node, in manual rendering mode

    /// Tapped samples ≡ rendered samples, through the interface the running system prefers
    /// and through the classic one.
    @Test(arguments: [SystemInterfaces.current, .classic])
    func tappedSamplesAreTheRenderedSamples(interfaces: SystemInterfaces) async throws {
        let engine = AVAudioEngine()
        let rendering = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        // A source node whose samples are known: a ramp on the left, its negative on the right.
        let position = Shared(0)
        let generator = AVAudioSourceNode(format: rendering) { _, _, frameCount, buffers -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            let start = position.withLock { value -> Int in
                defer { value += Int(frameCount) }
                return value
            }
            for (channel, buffer) in list.enumerated() {
                guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0 ..< Int(frameCount) {
                    let value = Float((start + frame) % 20_000) / 20_000
                    samples[frame] = channel == 0 ? value : -value
                }
            }
            return noErr
        }
        // Manual rendering first: the engine's output is then never the hardware.
        try engine.enableManualRenderingMode(.offline, format: rendering, maximumFrameCount: 4_096)
        engine.attach(generator)
        engine.connect(generator, to: engine.mainMixerNode, format: rendering)
        try engine.start()
        defer { engine.stop() }

        let tap = AudioNodeTap(node: engine.mainMixerNode, bus: 0, interfaces: interfaces)
        #expect(tap.output == NodeOutput(format: SignalFormat(sampleRate: 48_000, channelCount: 2), isAttached: true, hasBus: true, isFloat: true))
        let source = EngineNodeTapSource(tap: tap, blockSize: 512, clock: LeapingClock())
        let attached = try await Attachment(source, blockSize: 512)
        #expect(attached.session.environment.sampleRate == 48_000 && attached.session.environment.channelCount == 2)
        try attached.session.start()

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))
        var rendered: [[Float]] = [[], []]
        for _ in 0 ..< 24 {
            let status = try engine.renderOffline(4_096, to: buffer)
            #expect(status == .success)
            let data = try #require(buffer.floatChannelData)
            for channel in 0 ..< 2 {
                rendered[channel].append(contentsOf: UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength)))
            }
            // The tap's thread and the analysis thread take what was rendered.
            await pause(milliseconds: 10)
        }
        #expect(rendered[0].count == 24 * 4_096)
        #expect(rendered[0].contains { $0 != 0 }, "the engine rendered the generator's signal")
        // The tap hands over whole bursts: what it has delivered by now is a prefix of what was rendered.
        let left = rendered[0], right = rendered[1]
        #expect(await eventually { attached.sink.frameCount >= left.count / 2 }, "bursts arrive: \(attached.sink.frameCount) of \(left.count) frames")
        await pause(milliseconds: 100)
        let tapped = attached.sink.frameCount
        #expect(tapped % 512 == 0 && attached.sink.channelCount == 2)
        #expect(attached.sink.samples(ofChannel: 0) == Array(left[..<tapped]), "left: tapped ≡ rendered")
        #expect(attached.sink.samples(ofChannel: 1) == Array(right[..<tapped]), "right: tapped ≡ rendered")
        attached.session.stop()
        attached.session.detach()
    }

    @Test func aRealNodeSaysWhatCanBeTapped() async throws {
        let detached = AVAudioMixerNode()
        #expect(!AudioNodeTap(node: detached, bus: 0).output.isAttached)
        AudioNodeTap(node: detached, bus: 0).remove()                // nothing to remove, and no harm
        let engine = AVAudioEngine()
        let mixer = AVAudioMixerNode()
        engine.attach(mixer)
        let tap = AudioNodeTap(node: mixer, bus: 7)
        #expect(!tap.output.hasBus && tap.output.isAttached && !tap.output.format.isValid, "a mixer has one output bus")
        await #expect(throws: DSPError.self) { try await EngineNodeTapSource(node: mixer, bus: 7).prepare() }
        await #expect(throws: DSPError.self) { try await EngineNodeTapSource(node: detached).prepare() }
        let source = EngineNodeTapSource(node: mixer)
        try await source.prepare()
        #expect(source.format.isValid, "the public initialiser taps bus 0 of the node")
    }
}

/// What the real session, the real engine and a real node refuse, on the simulator: each
/// refusal is an error of the package, never an exception of AVFAudio. Serialized with the
/// other tests that use the real session and real engines.
extension SimulatorTests {
    @Test func aCategoryTheSystemRefusesIsASessionConfigurationFailure() {
        defer { restoreSession() }
        restoreSession()
        let system = SystemAudioSession()
        for (category, mode) in [(AVAudioSession.Category(rawValue: "NoSuchCategory"), AVAudioSession.Mode.default),
                                 (.playback, AVAudioSession.Mode(rawValue: "NoSuchMode"))] {
            do throws(DSPError) {
                try system.setCategory(category, mode: mode, options: [])
                Issue.record("\(category.rawValue) with \(mode.rawValue) is no configuration of a session")
            } catch {
                guard case .sessionConfigurationFailed(let reason) = error else {
                    Issue.record("expected sessionConfigurationFailed, got \(error)")
                    continue
                }
                #expect(reason.contains(category.rawValue) && reason.contains(mode.rawValue), "the error names what was refused: \(reason)")
            }
        }
        #expect(system.category == .soloAmbient, "a refused category leaves the session as it was")

        // The policy passes the refusal on: a source under it is not prepared.
        let refused = AudioSessionPolicy.custom { session in
            try session.setCategory(AVAudioSession.Category(rawValue: "NoSuchCategory"), mode: .default, options: [])
        }
        #expect(throws: DSPError.self) { try refused.configure(system) }
    }

    /// The system answers at once when the user has answered before, through either
    /// interface (E-16). An undetermined permission is not asked for: nobody would answer.
    @Test(.timeLimit(.minutes(1)), arguments: [SystemMicrophoneAuthorizer.Interface.application, .session])
    func theSystemAnswersAtOnceWhenTheUserHasAnswered(interface: SystemMicrophoneAuthorizer.Interface) async {
        let authorizer = SystemMicrophoneAuthorizer(interface: interface)
        let permission = authorizer.permission
        guard permission != .undetermined else {
            Self.note("permission (\(interface)): undetermined, not asked for")
            return
        }
        let granted = await authorizer.requestPermission()
        #expect(granted == (permission == .granted), "the answer is the one the user gave")
        #expect(authorizer.permission == permission, "and asking again changes nothing")
        if !granted {
            await #expect(throws: DSPError.permissionDenied) { try await MicrophoneAccess.ensure(authorizer) }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func theRealCaptureEngineReportsWhatTheSystemRefuses() async throws {
        defer { restoreSession() }
        restoreSession()
        try? AVAudioSession.sharedInstance().setActive(false)
        let capture = EngineInputCapture()
        try capture.rebuild()
        // Nothing is connected: the engine has nothing to run.
        do throws(DSPError) {
            try capture.start()
            Self.note("refusals: the simulator started an engine without a connection")
            capture.stop()
        } catch {
            guard case .sourceUnavailable = error else {
                Issue.record("an engine that does not start is sourceUnavailable, not \(error)")
                return
            }
        }
        // Under a category without input the input has no format. The source never asks for a
        // connection then; asked all the same, the capture reports an error through either
        // interface, and AVFAudio's exception for the classic call is never reached.
        let format = capture.inputFormat()
        Self.note("refusals: the input under solo ambient delivers \(format)")
        if !format.isValid {
            #expect(throws: DSPError.self) { try capture.connect() }
            let classic = EngineInputCapture(interfaces: .classic)
            try classic.rebuild()
            #expect(throws: DSPError.self) { try classic.connect() }
        }

        // A sink tap that cannot be had: the engine is not built.
        let unbuilt = EngineInputCapture()
        refuseAllocation(0)
        defer { refuseAllocation(-1) }
        #expect(throws: DSPError.resourceAllocationFailed(what: "the sink node of a hardware source")) { try unbuilt.rebuild() }
        #expect(unbuilt.engineIdentity == nil, "a capture that could not be built has no engine")
        refuseAllocation(-1)
        try unbuilt.rebuild()
        #expect(unbuilt.engineIdentity != nil, "and is, once memory is there")

        // A ring of more channels than a sink tap takes is not connected: its frames would be
        // discarded, and nothing is written past a buffer.
        let wide = RingProbe(format: SignalFormat(sampleRate: 48_000, channelCount: EngineInputCapture.maximumChannelCount + 1))
        let session = try await DSPEngine(blockSize: 64).attach(Pipeline(), to: wide)
        let ring = try #require(wide.writer)
        #expect(ring.channelCount == 257)
        unbuilt.setRing(ring)
        unbuilt.setRing(nil)
        session.detach()
    }

    @Test func aTapTheSystemRefusesIsAnError() {
        // A node without an engine has no bus to tap. The source asks first; the tap, asked all
        // the same, reports the refusal where the system has the error-returning call.
        guard #available(iOS 27.0, *) else { return }
        let tap = AudioNodeTap(node: AVAudioMixerNode(), bus: 0)
        do throws(DSPError) {
            try tap.install(bufferSize: 4_800) { _, _, _, _ in }
            Self.note("refusals: the simulator installed a tap on a node without an engine")
        } catch {
            guard case .sourceUnavailable = error else {
                Issue.record("a tap that is refused is sourceUnavailable, not \(error)")
                return
            }
        }
    }
}
