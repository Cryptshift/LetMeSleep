import Foundation

/// When an alert is allowed to fire.
struct AlertConfiguration: Sendable, Equatable {
    /// Level (dBFS) the room has to stay above. Closer to 0 means louder.
    var threshold: Float
    /// How long the level has to stay above `threshold` before alerting.
    var sustainDuration: TimeInterval
    /// Minimum time between two alerts.
    var cooldown: TimeInterval
    /// Short dips below the threshold (gaps in speech, a quiet moment in a game)
    /// up to this long don't reset the "loud for N seconds" timer.
    var quietTolerance: TimeInterval = 1
}

/// What the tracker decided for one sample.
enum AlertDecision: Sendable, Equatable {
    /// Below the threshold (or the loud streak ended).
    case quiet
    /// Loud, but not for long enough yet.
    case building(elapsed: TimeInterval)
    /// Loud for long enough and outside the cooldown: send a message now.
    case alert(averageLevel: Float, duration: TimeInterval)
    /// Loud for long enough, but a message was sent recently.
    case coolingDown(remaining: TimeInterval)
}

/// Pure "is it loud for long enough, and may we message again?" logic.
///
/// Feed it one (already smoothed) level per sample. It never sends anything itself.
struct AlertTracker: Sendable {
    private(set) var loudSince: Date?
    private(set) var lastLoudAt: Date?
    private(set) var lastAlertAt: Date?
    private var powerSum: Double = 0
    private var sampleCount = 0

    mutating func evaluate(level: Float, at now: Date, configuration: AlertConfiguration) -> AlertDecision {
        guard level > configuration.threshold else {
            return evaluateQuietSample(at: now, configuration: configuration)
        }

        if loudSince == nil {
            startStreak(at: now)
        }
        lastLoudAt = now
        powerSum += DecibelMath.power(fromDecibels: level)
        sampleCount += 1

        let elapsed = now.timeIntervalSince(loudSince ?? now)
        guard elapsed >= configuration.sustainDuration else {
            return .building(elapsed: elapsed)
        }

        if let remaining = cooldownRemaining(at: now, configuration: configuration) {
            return .coolingDown(remaining: remaining)
        }

        let averageLevel = DecibelMath.decibels(fromPower: powerSum / Double(max(sampleCount, 1)))
        lastAlertAt = now
        // The next alert needs its own sustained stretch (and the cooldown to pass).
        startStreak(at: now)
        return .alert(averageLevel: averageLevel, duration: elapsed)
    }

    /// Seconds until another alert is allowed, or `nil` if one is allowed now.
    func cooldownRemaining(at now: Date, configuration: AlertConfiguration) -> TimeInterval? {
        guard let lastAlertAt else { return nil }
        let remaining = configuration.cooldown - now.timeIntervalSince(lastAlertAt)
        return remaining > 0 ? remaining : nil
    }

    /// Forgets the current loud streak but keeps the cooldown, so toggling
    /// detection off and on can't be used to spam messages.
    mutating func resetStreak() {
        loudSince = nil
        lastLoudAt = nil
        powerSum = 0
        sampleCount = 0
    }

    private mutating func evaluateQuietSample(at now: Date, configuration: AlertConfiguration) -> AlertDecision {
        if let loudSince, let lastLoudAt, now.timeIntervalSince(lastLoudAt) <= configuration.quietTolerance {
            // A brief dip: keep the streak alive, but never alert on a quiet sample.
            return .building(elapsed: now.timeIntervalSince(loudSince))
        }
        resetStreak()
        return .quiet
    }

    private mutating func startStreak(at now: Date) {
        loudSince = now
        powerSum = 0
        sampleCount = 0
    }
}
