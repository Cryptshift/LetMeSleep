import SwiftUI

struct SettingsView: View {
    let monitor: SoundMonitor

    @Environment(\.dismiss) private var dismiss

    @State private var botToken = ""
    @State private var didLoadToken = false
    @AppStorage(SettingsKey.userID) private var userID = ""
    @AppStorage(SensitivityLevel.sensitive.thresholdKey) private var sensitiveThreshold = SensitivityLevel.sensitive.defaultThreshold
    @AppStorage(SensitivityLevel.normal.thresholdKey) private var normalThreshold = SensitivityLevel.normal.defaultThreshold
    @AppStorage(SensitivityLevel.sleeping.thresholdKey) private var sleepingThreshold = SensitivityLevel.sleeping.defaultThreshold
    @AppStorage(SettingsKey.sustainSeconds) private var sustainSeconds = SettingsDefault.sustainSeconds
    @AppStorage(SettingsKey.cooldownMinutes) private var cooldownMinutes = SettingsDefault.cooldownMinutes
    @AppStorage(SettingsKey.messageTemplate) private var messageTemplate = SettingsDefault.messageTemplate

    var body: some View {
        NavigationStack {
            Form {
                discordSection
                testMessageSection
                thresholdsSection
                alertsSection
                messageSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private var discordSection: some View {
        Section {
            SecureField("Bot token", text: $botToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: botToken) { _, newValue in
                    guard didLoadToken else { return }
                    KeychainStore.setBotToken(newValue)
                }
                .onAppear {
                    // Read the Keychain once, not on every re-render of the parent.
                    guard !didLoadToken else { return }
                    botToken = KeychainStore.botToken ?? ""
                    didLoadToken = true
                }
            TextField("Recipient user ID", text: $userID)
                .keyboardType(.numberPad)
        } header: {
            Text("Discord")
        } footer: {
            Text("The token is saved in this iPhone's Keychain only. For the user ID, turn on Developer Mode in Discord, then long-press the person and tap Copy User ID. The bot must share a server with them.")
        }
    }

    private var testMessageSection: some View {
        Section {
            Button {
                Task { await monitor.sendTestMessage() }
            } label: {
                HStack {
                    Text("Send test message")
                    if monitor.isSendingTestMessage {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(botToken.isEmpty || userID.isEmpty || monitor.isSendingTestMessage)

            if let result = monitor.testMessageResult {
                switch result.outcome {
                case .sent:
                    Label("Sent at \(result.date.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        } footer: {
            Text("Sends one real DM to the recipient, marked as a test.")
        }
    }

    private var thresholdsSection: some View {
        Section {
            LabeledContent("Current level") {
                Text(monitor.isEnabled ? "\(Int(monitor.level.rounded())) dBFS" : "Start listening to see it")
                    .monospacedDigit()
            }
            thresholdRow(.sensitive, value: $sensitiveThreshold)
            thresholdRow(.normal, value: $normalThreshold)
            thresholdRow(.sleeping, value: $sleepingThreshold)
            Button("Reset thresholds") {
                sensitiveThreshold = SensitivityLevel.sensitive.defaultThreshold
                normalThreshold = SensitivityLevel.normal.defaultThreshold
                sleepingThreshold = SensitivityLevel.sleeping.defaultThreshold
            }
        } header: {
            Text("Thresholds")
        } footer: {
            Text("Levels are dBFS: relative to the loudest sound the mic can report (0), not calibrated decibels. Closer to 0 means only louder noise counts. Start listening and watch the current level to pick values for your room.")
        }
    }

    private var alertsSection: some View {
        Section("Alerts") {
            Stepper(value: $sustainSeconds, in: 1...60, step: 1) {
                LabeledContent("Loud for at least", value: "\(Int(sustainSeconds)) s")
            }
            Stepper(value: $cooldownMinutes, in: 1...120, step: 1) {
                LabeledContent("Wait between messages", value: "\(Int(cooldownMinutes)) min")
            }
        }
    }

    private var messageSection: some View {
        Section {
            TextField("Message", text: $messageTemplate, axis: .vertical)
                .lineLimit(3...8)
            Button("Reset to default message") {
                messageTemplate = AlertMessage.defaultTemplate
            }
            .disabled(messageTemplate == AlertMessage.defaultTemplate)
        } header: {
            Text("Message")
        } footer: {
            Text("\(AlertMessage.levelPlaceholder) becomes the level in dBFS and \(AlertMessage.secondsPlaceholder) how many seconds it was loud.")
        }
    }

    private func thresholdRow(_ level: SensitivityLevel, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(level.title) {
                Text("\(Int(value.wrappedValue)) dBFS")
                    .monospacedDigit()
            }
            Slider(value: value, in: SettingsDefault.levelRange, step: 1) {
                Text("\(level.title) threshold")
            } minimumValueLabel: {
                Text("\(Int(SettingsDefault.levelRange.lowerBound))").font(.caption)
            } maximumValueLabel: {
                Text("\(Int(SettingsDefault.levelRange.upperBound))").font(.caption)
            }
        }
    }
}
