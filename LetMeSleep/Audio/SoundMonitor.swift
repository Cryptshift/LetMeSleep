import AVFoundation
import Observation

/// Meters the microphone, decides when it's been loud for long enough, and
/// sends the Discord alert. All state lives on the main actor.
@MainActor
@Observable
final class SoundMonitor {
    enum Status: Equatable {
        case off
        case starting
        case listening
        /// A call, alarm or another app took the microphone; we resume when it ends.
        case interrupted
        case permissionDenied
        case failed(String)
    }

    struct AlertRecord: Equatable {
        enum Outcome: Equatable {
            case sent
            case failed(String)
        }

        var date: Date
        var message: String
        var outcome: Outcome
    }

    static let sampleInterval: Duration = .milliseconds(250)
    /// 4 samples × 0.25 s = a 1 second rolling average.
    static let averagingWindow = 4

    private(set) var status: Status = .off
    /// True only while detection is really running (or paused by an interruption).
    private(set) var isEnabled = false
    /// Rolling-average level in dBFS.
    private(set) var level: Float = DecibelMath.floor
    private(set) var decision: AlertDecision = .quiet
    private(set) var cooldownEndsAt: Date?
    private(set) var lastAlert: AlertRecord?
    private(set) var inputName: String?
    private(set) var testMessageResult: AlertRecord?
    private(set) var isSendingTestMessage = false

    @ObservationIgnored private let discord: DiscordClient
    @ObservationIgnored private let session = AVAudioSession.sharedInstance()
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var samplingTask: Task<Void, Never>?
    @ObservationIgnored private var average = RollingLevelAverage(capacity: SoundMonitor.averagingWindow)
    @ObservationIgnored private var tracker = AlertTracker()
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(discord: DiscordClient = DiscordClient()) {
        self.discord = discord
        observeAudioSession()
    }

    var permission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    // MARK: - Start / stop

    func setEnabled(_ enabled: Bool) {
        if enabled {
            Task { await start() }
        } else {
            stop()
        }
    }

    func start() async {
        guard !isEnabled, status != .starting else { return }
        status = .starting

        guard await requestPermissionIfNeeded() else {
            isEnabled = false
            status = .permissionDenied
            return
        }

        do {
            try activateSession()
            try startRecorder()
        } catch {
            teardown()
            isEnabled = false
            status = .failed("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }

        average.reset()
        tracker.resetStreak()
        isEnabled = true
        status = .listening
        startSampling()
    }

    func stop() {
        teardown()
        isEnabled = false
        status = .off
        level = DecibelMath.floor
        decision = .quiet
    }

    /// Call at launch and whenever the app comes back to the foreground: picks up
    /// a permission change made in the Settings app, and retries after an
    /// interruption whose "ended" notification never arrived.
    func refreshAfterBecomingActive() {
        switch status {
        case .off, .permissionDenied:
            status = permission == .denied ? .permissionDenied : .off
        case .interrupted where isEnabled:
            resume()
        default:
            break
        }
    }

    // MARK: - Audio session

    private func requestPermissionIfNeeded() async -> Bool {
        switch permission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    private func activateSession() throws {
        // .playAndRecord + .mixWithOthers so starting detection doesn't stop other
        // audio (white noise, music). .defaultToSpeaker keeps that audio on the
        // speaker instead of the earpiece. .measurement turns off automatic gain
        // so levels are comparable over time. No Bluetooth input: we want the
        // phone's own microphone.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
        inputName = session.currentRoute.inputs.first?.portName
    }

    private func startRecorder() throws {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatAppleLossless),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
        ]
        // Metering only: audio goes to /dev/null and is never stored.
        let recorder = try AVAudioRecorder(url: URL(fileURLWithPath: "/dev/null"), settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            throw MonitorError.recorderDidNotStart
        }
        self.recorder = recorder
    }

    private func teardown() {
        samplingTask?.cancel()
        samplingTask = nil
        recorder?.stop()
        recorder = nil
        // Let other apps' audio resume at full volume.
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resume() {
        do {
            try activateSession()
            if let recorder, !recorder.isRecording {
                if !recorder.record() {
                    self.recorder = nil
                    try startRecorder()
                }
            } else if recorder == nil {
                try startRecorder()
            }
            average.reset()
            tracker.resetStreak()
            status = .listening
            if samplingTask == nil {
                startSampling()
            }
        } catch {
            teardown()
            isEnabled = false
            status = .failed("Couldn't resume listening: \(error.localizedDescription)")
        }
    }

    // MARK: - Sampling

    private func startSampling() {
        samplingTask?.cancel()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: SoundMonitor.sampleInterval)
                guard !Task.isCancelled, let self else { return }
                self.takeSample()
            }
        }
    }

    private func takeSample() {
        guard status == .listening, let recorder else { return }
        guard recorder.isRecording else {
            // Something stopped the recorder without an interruption notification.
            if !recorder.record() { status = .interrupted }
            return
        }

        recorder.updateMeters()
        level = average.add(recorder.averagePower(forChannel: 0))

        let settings = MonitorSettings.load()
        let configuration = settings.alertConfiguration
        let now = Date()
        decision = tracker.evaluate(level: level, at: now, configuration: configuration)
        cooldownEndsAt = tracker.cooldownRemaining(at: now, configuration: configuration).map { now.addingTimeInterval($0) }

        if case let .alert(averageLevel, duration) = decision {
            let message = AlertMessage.render(template: settings.messageTemplate, level: averageLevel, duration: duration)
            Task { lastAlert = await send(message, userID: settings.userID) }
        }
    }

    // MARK: - Discord

    func sendTestMessage() async {
        guard !isSendingTestMessage else { return }
        isSendingTestMessage = true
        defer { isSendingTestMessage = false }
        let settings = MonitorSettings.load()
        let sample = AlertMessage.render(
            template: settings.messageTemplate,
            level: Float(settings.threshold),
            duration: settings.sustainSeconds
        )
        testMessageResult = await send("(Test from LetMeSleep) \(sample)", userID: settings.userID)
    }

    private func send(_ message: String, userID: String) async -> AlertRecord {
        do {
            try await discord.sendDirectMessage(message, botToken: KeychainStore.botToken ?? "", userID: userID)
            return AlertRecord(date: Date(), message: message, outcome: .sent)
        } catch {
            return AlertRecord(date: Date(), message: message, outcome: .failed(error.localizedDescription))
        }
    }

    // MARK: - Interruptions and route changes

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated { self?.handleInterruption(type) }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleRouteChange() }
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        })
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        guard isEnabled, let type else { return }
        switch type {
        case .began:
            status = .interrupted
            level = DecibelMath.floor
            decision = .quiet
        case .ended:
            // A monitoring app should always try to pick up again, whether or
            // not the system hints .shouldResume.
            resume()
        @unknown default:
            break
        }
    }

    private func handleRouteChange() {
        inputName = session.currentRoute.inputs.first?.portName
        guard isEnabled, status == .listening else { return }
        // A different microphone means different levels.
        average.reset()
        tracker.resetStreak()
        if let recorder, !recorder.isRecording, !recorder.record() {
            status = .interrupted
        }
    }

    private func handleMediaServicesReset() {
        // Every audio object is invalid after a reset; rebuild from scratch.
        samplingTask?.cancel()
        samplingTask = nil
        recorder = nil
        guard isEnabled else { return }
        resume()
    }
}

enum MonitorError: LocalizedError {
    case recorderDidNotStart

    var errorDescription: String? {
        switch self {
        case .recorderDidNotStart: "The microphone didn't start recording."
        }
    }
}
