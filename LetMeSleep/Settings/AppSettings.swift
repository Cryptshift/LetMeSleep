import Foundation

/// UserDefaults keys shared by `@AppStorage` in the views and `MonitorSettings`.
enum SettingsKey {
    static let userID = "discordUserID"
    static let sensitivity = "sensitivity"
    static let sustainSeconds = "sustainSeconds"
    static let cooldownMinutes = "cooldownMinutes"
    static let messageTemplate = "messageTemplate"
}

enum SettingsDefault {
    static let sensitivity = SensitivityLevel.normal
    static let sustainSeconds: Double = 5
    static let cooldownMinutes: Double = 5
    static let messageTemplate = AlertMessage.defaultTemplate
    /// Range offered by the threshold sliders and the level meter.
    static let levelRange: ClosedRange<Double> = -80...0
}

/// Three named thresholds. Each one is editable in Settings.
enum SensitivityLevel: String, CaseIterable, Identifiable, Sendable {
    case sensitive
    case normal
    case sleeping

    var id: Self { self }

    var title: String {
        switch self {
        case .sensitive: "Sensitive"
        case .normal: "Normal"
        case .sleeping: "Sleeping"
        }
    }

    /// UserDefaults key for this level's threshold (dBFS, stored as Double).
    var thresholdKey: String { "threshold.\(rawValue)" }

    /// Lower (more negative) triggers on quieter sounds.
    var defaultThreshold: Double {
        switch self {
        case .sensitive: -60
        case .normal: -40
        case .sleeping: -20
        }
    }
}

/// A snapshot of everything the monitor needs from Settings.
struct MonitorSettings: Sendable, Equatable {
    var sensitivity: SensitivityLevel
    var threshold: Double
    var sustainSeconds: Double
    var cooldownMinutes: Double
    var messageTemplate: String
    var userID: String

    static func load(from defaults: UserDefaults = .standard) -> MonitorSettings {
        let sensitivity = defaults.string(forKey: SettingsKey.sensitivity).flatMap(SensitivityLevel.init(rawValue:))
            ?? SettingsDefault.sensitivity
        return MonitorSettings(
            sensitivity: sensitivity,
            threshold: defaults.double(forKey: sensitivity.thresholdKey, default: sensitivity.defaultThreshold),
            sustainSeconds: defaults.double(forKey: SettingsKey.sustainSeconds, default: SettingsDefault.sustainSeconds),
            cooldownMinutes: defaults.double(forKey: SettingsKey.cooldownMinutes, default: SettingsDefault.cooldownMinutes),
            messageTemplate: defaults.string(forKey: SettingsKey.messageTemplate) ?? SettingsDefault.messageTemplate,
            userID: defaults.string(forKey: SettingsKey.userID) ?? ""
        )
    }

    var alertConfiguration: AlertConfiguration {
        AlertConfiguration(
            threshold: Float(threshold),
            sustainDuration: max(sustainSeconds, 0),
            cooldown: max(cooldownMinutes, 0) * 60
        )
    }
}

private extension UserDefaults {
    func double(forKey key: String, default defaultValue: Double) -> Double {
        (object(forKey: key) as? NSNumber)?.doubleValue ?? defaultValue
    }
}
