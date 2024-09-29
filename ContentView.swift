import Foundation
import AVFoundation
import SwiftUI
// Enum to define sensitivity levels
enum SensitivityLevel: String, CaseIterable {
    case sensitive = "Sensitive"
    case normal = "Normal"
    case sleeping = "Sleeping"
}
class SoundDetector: NSObject, AVAudioRecorderDelegate, ObservableObject {
    var audioRecorder: AVAudioRecorder?
    var timer: Timer?
    @Published var detectedSound: String = ""
    @Published var isDetectionEnabled: Bool = false {
        didSet {
            if isDetectionEnabled {
                startDetection()
            } else {
                stopDetection()
            }
        }
    }
    @Published var sensitivityLevel: SensitivityLevel = .normal
    @Published var botToken: String = "SET TOKEN"
    @Published var userId: String = "FIND USING DEVELOPER MODE ON DISCORD"
    @Published var sensitiveDecibel: Float = -60.0
    @Published var normalDecibel: Float = -40.0
    @Published var sleepingDecibel: Float = -20.0
    override init() {
        super.init()
    }
    // Fetch decibel threshold based on the current sensitivity level
    var currentDecibelThreshold: Float {
        switch sensitivityLevel {
        case .sensitive:
            return sensitiveDecibel
        case .normal:
            return normalDecibel
        case .sleeping:
            return sleepingDecibel
        }
    }
    // Start sound detection
    func startDetection() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatAppleLossless),
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
            ]
            audioRecorder = try AVAudioRecorder(url: URL(fileURLWithPath: "/dev/null"), settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            // Start a timer to check sound levels
            timer = Timer.scheduledTimer(timeInterval: 3.0, target: self, selector: #selector(checkSoundLevel), userInfo: nil, repeats: true)
        } catch {
            print("Error setting up audio recorder: \(error.localizedDescription)")
        }
    }
    // Stop sound detection
    func stopDetection() {
        audioRecorder?.stop()
        audioRecorder = nil
        timer?.invalidate()
        timer = nil
        detectedSound = "Sound detection disabled"
    }
    // Check sound level and trigger message sending if threshold is exceeded
    @objc func checkSoundLevel() {
        audioRecorder?.updateMeters()
        let decibelLevel = audioRecorder?.averagePower(forChannel: 0) ?? -1000.0
        if decibelLevel > currentDecibelThreshold {
            self.detectedSound = "Sound detected: \(decibelLevel) dB"
            sendDiscordMessage(decibelLevel: decibelLevel)
        } else {
            self.detectedSound = "No significant sound detected"
        }
    }
    // Send message to Discord via a DM
    func sendDiscordMessage(decibelLevel: Float) {
        let createDMChannelURL = URL(string: "https://discord.com/api/v10/users/@me/channels")!
        var request = URLRequest(url: createDMChannelURL)
        request.httpMethod = "POST"
        request.setValue("Bot \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let jsonBody = ["recipient_id": userId]
        request.httpBody = try? JSONSerialization.data(withJSONObject: jsonBody, options: [])
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                print("Failed to create DM channel: \(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse, let data = data else {
                print("Invalid response from Discord")
                return
            }
            if httpResponse.statusCode == 429 {
                if let retryAfter = httpResponse.allHeaderFields["Retry-After"] as? String {
                    print("Rate limited, retry after \(retryAfter) seconds")
                    DispatchQueue.global().asyncAfter(deadline: .now() + Double(retryAfter)!) {
                        self.sendDiscordMessage(decibelLevel: decibelLevel)
                    }
                }
                return
            }
            guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
                print("Failed to create DM channel, status code: \(httpResponse.statusCode)")
                return
            }
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let channelId = json["id"] as? String {
                    self.sendMessageToChannel(channelId: channelId, decibelLevel: decibelLevel)
                }
            } catch {
                print("Error parsing JSON response: \(error.localizedDescription)")
            }
        }
        task.resume()
    }
    // Send the actual message to the Discord DM channel
    func sendMessageToChannel(channelId: String, decibelLevel: Float) {
        let sendMessageURL = URL(string: "https://discord.com/api/v10/channels/\(channelId)/messages")!
        var request = URLRequest(url: sendMessageURL)
        request.httpMethod = "POST"
        request.setValue("Bot \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let messageBody = ["content": "Detected sound with decibel level: \(decibelLevel) dB"]
        request.httpBody = try? JSONSerialization.data(withJSONObject: messageBody, options: [])
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("Failed to send message: \(error.localizedDescription)")
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                print("Invalid response when sending message")
                return
            }
            if httpResponse.statusCode == 429 {
                if let retryAfter = httpResponse.allHeaderFields["Retry-After"] as? String {
                    print("Rate limited, retry after \(retryAfter) seconds")
                    DispatchQueue.global().asyncAfter(deadline: .now() + Double(retryAfter)!) {
                        self.sendMessageToChannel(channelId: channelId, decibelLevel: decibelLevel)
                    }
                }
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                print("Failed to send message, status code: \(httpResponse.statusCode)")
                return
            }
            print("Message sent successfully")
        }
        task.resume()
    }
}
struct SettingsView: View {
    @ObservedObject var soundDetector: SoundDetector
    var body: some View {
        Form {
            Section(header: Text("Discord Settings")) {
                TextField("Bot Token", text: $soundDetector.botToken)
                TextField("User ID", text: $soundDetector.userId)
            }
            Section(header: Text("Sensitivity Decibels")) {
                HStack {
                    Text("Sensitive Mode")
                    Spacer()
                    TextField("Decibels", value: $soundDetector.sensitiveDecibel, format: .number)
                        .keyboardType(.decimalPad)
                }
                HStack {
                    Text("Normal Mode")
                    Spacer()
                    TextField("Decibels", value: $soundDetector.normalDecibel, format: .number)
                        .keyboardType(.decimalPad)
                }
                HStack {
                    Text("Sleeping Mode")
                    Spacer()
                    TextField("Decibels", value: $soundDetector.sleepingDecibel, format: .number)
                        .keyboardType(.decimalPad)
                }
            }
        }
        .navigationTitle("Settings")
        .padding()
    }
}
struct ContentView: View {
    @StateObject private var soundDetector = SoundDetector()
    @State private var showingSettings = false
    var body: some View {
        NavigationView {
            VStack {
                // Toggle for enabling or disabling sound detection
                Toggle(isOn: $soundDetector.isDetectionEnabled) {
                    Text("Enable Sound Detection")
                        .font(.headline)
                }
                .padding()
                // Sensitivity level control using a Picker
                Picker("Sensitivity", selection: $soundDetector.sensitivityLevel) {
                    ForEach(SensitivityLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(level)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())  // Modern segmented control style
                .padding()
                // Display the current status of sound detection
                Text("Status: \(soundDetector.detectedSound)")
                    .padding()
                Spacer()
            }
            .padding()
            .navigationTitle("Sound Detector")
            .toolbar {
                // Add the gear icon that leads to settings
                Button(action: {
                    showingSettings.toggle()
                }) {
                    Image(systemName: "gear")
                        .imageScale(.large)
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView(soundDetector: soundDetector)
                }
            }
        }
    }
}