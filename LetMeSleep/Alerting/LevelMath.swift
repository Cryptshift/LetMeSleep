import Foundation

/// Helpers for dBFS levels as reported by `AVAudioRecorder` metering.
///
/// dBFS is relative to the loudest signal the microphone can report (0 dBFS).
/// Quieter sounds are more negative. It is *not* a calibrated dB SPL value.
enum DecibelMath {
    /// The quietest level `AVAudioRecorder` reports (digital silence).
    static let floor: Float = -160

    /// Converts a dBFS level to linear power so levels can be averaged correctly.
    static func power(fromDecibels decibels: Float) -> Double {
        pow(10, Double(max(decibels, floor)) / 10)
    }

    /// Converts linear power back to dBFS, clamped to `floor`.
    static func decibels(fromPower power: Double) -> Float {
        guard power > 0, power.isFinite else { return floor }
        return max(Float(10 * log10(power)), floor)
    }
}

/// A rolling average of the most recent `capacity` level samples.
///
/// Samples are averaged in the power domain (not by averaging dB values directly),
/// which matches how loudness actually adds up.
struct RollingLevelAverage: Sendable {
    let capacity: Int
    private var powers: [Double] = []
    private var nextIndex = 0

    init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        powers.reserveCapacity(capacity)
    }

    /// The current average in dBFS, or `nil` before the first sample.
    var average: Float? {
        guard !powers.isEmpty else { return nil }
        return DecibelMath.decibels(fromPower: powers.reduce(0, +) / Double(powers.count))
    }

    /// Adds a sample (dBFS) and returns the updated average.
    @discardableResult
    mutating func add(_ decibels: Float) -> Float {
        let power = DecibelMath.power(fromDecibels: decibels.isFinite ? decibels : DecibelMath.floor)
        if powers.count < capacity {
            powers.append(power)
        } else {
            powers[nextIndex] = power
        }
        nextIndex = (nextIndex + 1) % capacity
        return average ?? DecibelMath.floor
    }

    mutating func reset() {
        powers.removeAll(keepingCapacity: true)
        nextIndex = 0
    }
}
