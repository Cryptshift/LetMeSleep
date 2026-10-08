import Foundation
import Testing
@testable import LetMeSleep

struct AlertTrackerTests {
    let config = AlertConfiguration(threshold: -40, sustainDuration: 5, cooldown: 300, quietTolerance: 1)
    let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    let loud: Float = -30
    let quiet: Float = -55

    /// Feeds `level` every 0.25 s for t in `from...to` and returns (t, decision) pairs.
    func feed(
        _ tracker: inout AlertTracker,
        level: Float,
        from: TimeInterval,
        to: TimeInterval
    ) -> [(time: TimeInterval, decision: AlertDecision)] {
        var results: [(TimeInterval, AlertDecision)] = []
        var t = from
        while t <= to {
            results.append((t, tracker.evaluate(level: level, at: start + t, configuration: config)))
            t += 0.25
        }
        return results
    }

    func alertTimes(_ results: [(time: TimeInterval, decision: AlertDecision)]) -> [TimeInterval] {
        results.compactMap { result in
            if case .alert = result.decision { result.time } else { nil }
        }
    }

    @Test func quietRoomNeverAlerts() {
        var tracker = AlertTracker()
        let results = feed(&tracker, level: quiet, from: 0, to: 60)
        #expect(results.allSatisfy { $0.decision == .quiet })
    }

    @Test func levelEqualToThresholdIsNotLoud() {
        var tracker = AlertTracker()
        #expect(tracker.evaluate(level: -40, at: start, configuration: config) == .quiet)
    }

    @Test func loudButShorterThanSustainOnlyBuilds() {
        var tracker = AlertTracker()
        let results = feed(&tracker, level: loud, from: 0, to: 4.75)
        #expect(alertTimes(results).isEmpty)
        #expect(results.last?.decision == .building(elapsed: 4.75))
    }

    @Test func alertsOnceLoudForTheSustainDuration() throws {
        var tracker = AlertTracker()
        let results = feed(&tracker, level: loud, from: 0, to: 5)
        #expect(alertTimes(results) == [5])
        guard case let .alert(averageLevel, duration) = try #require(results.last?.decision) else {
            Issue.record("expected an alert")
            return
        }
        #expect(abs(averageLevel - loud) < 0.01)
        #expect(duration == 5)
    }

    @Test func cooldownLimitsContinuousNoiseToOneMessagePerPeriod() {
        var tracker = AlertTracker()
        let results = feed(&tracker, level: loud, from: 0, to: 700)
        #expect(alertTimes(results) == [5, 305, 605])

        let between = results.filter { $0.time > 10 && $0.time < 305 }
        #expect(between.allSatisfy {
            if case .coolingDown = $0.decision { true } else { false }
        })
    }

    @Test func cooldownRemainingCountsDown() {
        var tracker = AlertTracker()
        _ = feed(&tracker, level: loud, from: 0, to: 5)
        #expect(tracker.cooldownRemaining(at: start + 5, configuration: config) == 300)
        #expect(tracker.cooldownRemaining(at: start + 65, configuration: config) == 240)
        #expect(tracker.cooldownRemaining(at: start + 305, configuration: config) == nil)
    }

    @Test func shortDipDoesNotResetTheStreak() {
        var tracker = AlertTracker()
        var results = feed(&tracker, level: loud, from: 0, to: 3)
        results += feed(&tracker, level: quiet, from: 3.25, to: 3.75) // 0.75 s dip
        results += feed(&tracker, level: loud, from: 4, to: 6)
        #expect(alertTimes(results) == [5])
    }

    @Test func longerDipResetsTheStreak() {
        var tracker = AlertTracker()
        var results = feed(&tracker, level: loud, from: 0, to: 3)
        results += feed(&tracker, level: quiet, from: 3.25, to: 4.5) // 1.5 s dip
        results += feed(&tracker, level: loud, from: 4.75, to: 12)
        #expect(alertTimes(results) == [9.75])
    }

    @Test func neverAlertsOnAQuietSample() {
        var tracker = AlertTracker()
        _ = feed(&tracker, level: loud, from: 0, to: 4.75)
        #expect(tracker.evaluate(level: quiet, at: start + 5, configuration: config) == .building(elapsed: 5))
        guard case .alert = tracker.evaluate(level: loud, at: start + 5.25, configuration: config) else {
            Issue.record("expected the next loud sample to alert")
            return
        }
    }

    @Test func resetStreakKeepsTheCooldown() {
        var tracker = AlertTracker()
        _ = feed(&tracker, level: loud, from: 0, to: 5)
        tracker.resetStreak() // e.g. detection toggled off and on
        let results = feed(&tracker, level: loud, from: 6, to: 60)
        #expect(alertTimes(results).isEmpty)
    }

    @Test func averageLevelCoversTheWholeLoudStretch() throws {
        var tracker = AlertTracker()
        // Alternate -30 and -20 dBFS: the power average is about -24.6 dBFS.
        var t: TimeInterval = 0
        var last: AlertDecision = .quiet
        while t <= 5 {
            let level: Float = Int(t * 4).isMultiple(of: 2) ? -30 : -20
            last = tracker.evaluate(level: level, at: start + t, configuration: config)
            t += 0.25
        }
        guard case let .alert(averageLevel, _) = last else {
            Issue.record("expected an alert, got \(last)")
            return
        }
        let expected = DecibelMath.decibels(fromPower: (11 * DecibelMath.power(fromDecibels: -30) + 10 * DecibelMath.power(fromDecibels: -20)) / 21)
        #expect(abs(averageLevel - expected) < 0.01)
    }
}

struct RollingLevelAverageTests {
    @Test func emptyHasNoAverage() {
        #expect(RollingLevelAverage(capacity: 4).average == nil)
    }

    @Test func singleSampleIsItsOwnAverage() {
        var average = RollingLevelAverage(capacity: 4)
        #expect(abs(average.add(-42) - -42) < 0.001)
    }

    @Test func averagesInThePowerDomain() {
        var average = RollingLevelAverage(capacity: 2)
        average.add(-20)
        let result = average.add(-160)
        // Half of -20 dBFS power is about -23.01 dBFS, not the -90 a naive dB mean gives.
        #expect(abs(result - -23.0103) < 0.001)
    }

    @Test func oldSamplesFallOutOfTheWindow() {
        var average = RollingLevelAverage(capacity: 4)
        for _ in 0..<4 { average.add(-160) }
        var result: Float = 0
        for _ in 0..<4 { result = average.add(-20) }
        #expect(abs(result - -20) < 0.001)
    }

    @Test func resetClearsSamples() {
        var average = RollingLevelAverage(capacity: 4)
        average.add(-10)
        average.reset()
        #expect(average.average == nil)
    }

    @Test func nonFiniteSamplesCountAsSilence() {
        var average = RollingLevelAverage(capacity: 1)
        #expect(average.add(-.infinity) == DecibelMath.floor)
        #expect(average.add(.nan) == DecibelMath.floor)
    }
}

struct AlertMessageTests {
    @Test func defaultTemplateFillsLevelAndSeconds() {
        let text = AlertMessage.render(template: AlertMessage.defaultTemplate, level: -32.6, duration: 4.6)
        #expect(text == "It's getting pretty loud: about -33 dB for the last 5 seconds. Mind keeping it down? 🙏")
    }

    @Test func blankTemplateFallsBackToDefault() {
        let text = AlertMessage.render(template: "  \n ", level: -30, duration: 5)
        #expect(text == AlertMessage.render(template: AlertMessage.defaultTemplate, level: -30, duration: 5))
    }

    @Test func customTemplateReplacesEveryPlaceholder() {
        let text = AlertMessage.render(template: "{db}/{db} for {seconds}s", level: -12, duration: 30)
        #expect(text == "-12/-12 for 30s")
    }

    @Test func longMessagesAreTrimmedToDiscordsLimit() {
        let text = AlertMessage.render(template: String(repeating: "a", count: 5000), level: -30, duration: 5)
        #expect(text.count == AlertMessage.maxLength)
    }
}
