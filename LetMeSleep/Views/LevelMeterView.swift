import SwiftUI

/// A horizontal level meter with the current threshold marked on it.
struct LevelMeterView: View {
    /// Current level in dBFS.
    var level: Float
    /// Alert threshold in dBFS.
    var threshold: Double
    var isActive: Bool
    var range: ClosedRange<Double> = SettingsDefault.levelRange

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(isActive ? "\(Int(level.rounded()))" : "–")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("dBFS")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Threshold \(Int(threshold))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(barColor)
                        .frame(width: width * fraction(of: isActive ? Double(level) : range.lowerBound))
                    Rectangle()
                        .fill(.primary)
                        .frame(width: 2, height: proxy.size.height + 8)
                        .offset(x: width * fraction(of: threshold) - 1)
                }
            }
            .frame(height: 14)
            .animation(.linear(duration: 0.25), value: level)

            HStack {
                Text("\(Int(range.lowerBound))")
                Spacer()
                Text("\(Int(range.upperBound))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sound level")
        .accessibilityValue(
            isActive
                ? "\(Int(level.rounded())) dBFS, threshold \(Int(threshold)) dBFS"
                : "Not listening, threshold \(Int(threshold)) dBFS"
        )
    }

    private var barColor: Color {
        guard isActive else { return .gray }
        let value = Double(level)
        if value > threshold { return .red }
        if value > threshold - 10 { return .orange }
        return .green
    }

    private func fraction(of value: Double) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }
}

#Preview {
    List {
        LevelMeterView(level: -52, threshold: -40, isActive: true)
        LevelMeterView(level: -33, threshold: -40, isActive: true)
        LevelMeterView(level: -160, threshold: -40, isActive: false)
    }
}
