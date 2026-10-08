import AVFoundation
import SwiftUI
import UIKit

struct ContentView: View {
    let monitor: SoundMonitor

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @AppStorage(SettingsKey.sensitivity) private var sensitivity = SettingsDefault.sensitivity
    @AppStorage(SettingsKey.userID) private var userID = ""
    @AppStorage(SensitivityLevel.sensitive.thresholdKey) private var sensitiveThreshold = SensitivityLevel.sensitive.defaultThreshold
    @AppStorage(SensitivityLevel.normal.thresholdKey) private var normalThreshold = SensitivityLevel.normal.defaultThreshold
    @AppStorage(SensitivityLevel.sleeping.thresholdKey) private var sleepingThreshold = SensitivityLevel.sleeping.defaultThreshold
    @AppStorage(SettingsKey.sustainSeconds) private var sustainSeconds = SettingsDefault.sustainSeconds
    @AppStorage(SettingsKey.cooldownMinutes) private var cooldownMinutes = SettingsDefault.cooldownMinutes

    @State private var showingSettings = false
    @State private var hasBotToken = KeychainStore.botToken != nil

    var body: some View {
        NavigationStack {
            List {
                listeningSection
                levelSection
                sensitivitySection
                if monitor.status == .permissionDenied {
                    permissionSection
                }
                if !hasBotToken || userID.isEmpty {
                    setupSection
                }
                if let lastAlert = monitor.lastAlert {
                    lastAlertSection(lastAlert)
                }
            }
            .navigationTitle("LetMeSleep")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings, onDismiss: refreshTokenState) {
                SettingsView(monitor: monitor)
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active {
                    monitor.refreshAfterBecomingActive()
                    refreshTokenState()
                }
            }
        }
    }

    // MARK: - Sections

    private var listeningSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { monitor.isEnabled || monitor.status == .starting },
                set: { monitor.setEnabled($0) }
            )) {
                Label("Listen for noise", systemImage: "ear")
            }
            .disabled(monitor.status == .starting)

            statusRow
        } footer: {
            Text("Keeps listening with the screen locked. Audio is only metered, never recorded or saved.")
        }
    }

    private var levelSection: some View {
        Section("Level") {
            LabeledContent("Current level") {
                Text(monitor.isEnabled ? "\(Int(monitor.level.rounded())) dBFS" : "–")
                    .monospacedDigit()
            }
        }
    }

    private var sensitivitySection: some View {
        Section {
            Picker("Sensitivity", selection: $sensitivity) {
                ForEach(SensitivityLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Sensitivity")
        } footer: {
            Text("Messages after \(Int(sustainSeconds)) s above \(Int(currentThreshold)) dBFS, at most once every \(Int(cooldownMinutes)) min.")
        }
    }

    private var permissionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Microphone access is off", systemImage: "mic.slash")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text("LetMeSleep needs the microphone to measure how loud it is. Turn it on in Settings › Privacy & Security › Microphone.")
                    .font(.subheadline)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var setupSection: some View {
        Section {
            Button("Add Discord bot token and user ID") {
                showingSettings = true
            }
        } footer: {
            Text("You can watch the level without them, but no messages will be sent.")
        }
    }

    private func lastAlertSection(_ record: SoundMonitor.AlertRecord) -> some View {
        Section("Last alert") {
            VStack(alignment: .leading, spacing: 4) {
                switch record.outcome {
                case .sent:
                    Label("Sent at \(record.date.formatted(date: .omitted, time: .shortened))", systemImage: "paperplane")
                case .failed(let reason):
                    Label("Failed at \(record.date.formatted(date: .omitted, time: .shortened))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Text(reason)
                        .font(.footnote)
                }
                Text(record.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusRow: some View {
        switch monitor.status {
        case .off, .permissionDenied:
            Label("Not listening", systemImage: "moon.zzz")
                .foregroundStyle(.secondary)
        case .starting:
            Label("Starting…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
        case .listening:
            Label(listeningDescription, systemImage: listeningSymbol)
        case .interrupted:
            Label("Paused by a call or another app. Resumes automatically.", systemImage: "pause.circle")
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private var listeningDescription: String {
        switch monitor.decision {
        case .quiet:
            if let cooldownEndsAt = monitor.cooldownEndsAt {
                return "Quiet. Next message allowed after \(cooldownEndsAt.formatted(date: .omitted, time: .shortened))."
            }
            return "Quiet"
        case .building(let elapsed):
            return "Loud for \(Int(elapsed)) of \(Int(sustainSeconds)) s"
        case .alert:
            return "Too loud. Sending a message…"
        case .coolingDown(let remaining):
            return "Still loud. Next message in \(Duration.seconds(remaining).formatted(.time(pattern: .minuteSecond)))."
        }
    }

    private var listeningSymbol: String {
        switch monitor.decision {
        case .quiet: "waveform"
        case .building: "waveform.badge.exclamationmark"
        case .alert, .coolingDown: "speaker.wave.3"
        }
    }

    private var currentThreshold: Double {
        switch sensitivity {
        case .sensitive: sensitiveThreshold
        case .normal: normalThreshold
        case .sleeping: sleepingThreshold
        }
    }

    private func refreshTokenState() {
        hasBotToken = KeychainStore.botToken != nil
    }
}
