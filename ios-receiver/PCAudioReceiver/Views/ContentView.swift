import SwiftUI

struct ContentView: View {
    @StateObject private var audioSession = AudioSessionManager.shared
    @StateObject private var bleScanner = BleScannerManager()
    @StateObject private var receiver = UdpAudioEngineReceiver()

    @AppStorage("lastPcIpAddress") private var manualIpAddress: String = "192.168.1.100"
    @AppStorage("lastUdpPort") private var manualPortString: String = "49152"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    statusHeaderCard
                    bleDiscoveryCard
                    manualConnectionCard
                    mixingAndBackgroundCard
                    volumeAndLatencyCard
                    telemetryCard
                }
                .padding(16)
            }
            .background(Color(red: 0.06, green: 0.09, blue: 0.16).ignoresSafeArea())
            .navigationTitle("PC Audio Bridge")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - 1. Status Header
    private var statusHeaderCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(receiver.isRunning ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(receiver.connectionStatus)
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Text(receiver.activeCodecName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.25))
                    .cornerRadius(6)
            }

            Text("Output Route: \(audioSession.currentRouteDescription)")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(16)
        .background(Color(red: 0.12, green: 0.16, blue: 0.23))
        .cornerRadius(12)
    }

    // MARK: - 2. BLE & Wi-Fi Auto-Discovery
    private var bleDiscoveryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Auto-Discovery (BLE + Wi-Fi)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline.bold())
                    .foregroundColor(.cyan)
                Spacer()
                Button("Rescan") {
                    bleScanner.startScanning()
                }
                .font(.caption.bold())
                .buttonStyle(.bordered)
            }

            Text(bleScanner.bluetoothStateText)
                .font(.caption)
                .foregroundColor(.gray)

            if bleScanner.discoveredEndpoints.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Listening for Windows 11 PC broadcast...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(bleScanner.discoveredEndpoints) { endpoint in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(endpoint.name)
                                .font(.subheadline.bold())
                                .foregroundColor(.white)
                            Text("\(endpoint.ipAddress):\(endpoint.port) • via \(endpoint.source)")
                                .font(.caption2)
                                .foregroundColor(.gray)
                        }
                        Spacer()
                        Button(action: {
                            manualIpAddress = endpoint.ipAddress
                            manualPortString = String(endpoint.port)
                            receiver.start(pcIpAddress: endpoint.ipAddress, port: endpoint.port)
                        }) {
                            Text(receiver.isRunning && manualIpAddress == endpoint.ipAddress ? "Connected" : "Connect")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.cyan)
                                .foregroundColor(.black)
                                .cornerRadius(8)
                        }
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.25))
                    .cornerRadius(8)
                }
            }
        }
        .padding(16)
        .background(Color(red: 0.12, green: 0.16, blue: 0.23))
        .cornerRadius(12)
    }

    // MARK: - 3. Manual IP Connection & Primary Toggle
    private var manualConnectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Windows 11 PC Endpoint", systemImage: "desktopcomputer")
                .font(.subheadline.bold())
                .foregroundColor(.white)

            HStack(spacing: 10) {
                TextField("PC IPv4 (e.g. 192.168.1.100)", text: $manualIpAddress)
                    .keyboardType(.numbersAndPunctuation)
                    .textFieldStyle(.roundedBorder)

                TextField("Port", text: $manualPortString)
                    .keyboardType(.numberPad)
                    .frame(width: 85)
                    .textFieldStyle(.roundedBorder)
            }

            Button(action: toggleStream) {
                HStack {
                    Image(systemName: receiver.isRunning ? "stop.fill" : "play.fill")
                    Text(receiver.isRunning ? "STOP AUDIO STREAM" : "START AUDIO STREAM")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(receiver.isRunning ? Color.red : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
        }
        .padding(16)
        .background(Color(red: 0.12, green: 0.16, blue: 0.23))
        .cornerRadius(12)
    }

    // MARK: - 4. Native iOS Audio Mixing (.mixWithOthers / .duckOthers)
    private var mixingAndBackgroundCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("iOS Background & Audio Mixing", systemImage: "slider.horizontal.below.rectangle")
                .font(.subheadline.bold())
                .foregroundColor(.white)

            Toggle(isOn: $audioSession.mixWithOthers) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mix With Native iPhone Apps")
                        .font(.subheadline)
                    Text("Play PC audio simultaneously with YouTube, TikTok, Games & locked screen")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
            .tint(.green)

            Toggle(isOn: $audioSession.duckOthers) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duck Other Apps (.duckOthers)")
                        .font(.subheadline)
                    Text("Slightly lower other iPhone app volume while PC audio stream is active")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
            .tint(.cyan)
        }
        .padding(16)
        .background(Color(red: 0.12, green: 0.16, blue: 0.23))
        .cornerRadius(12)
    }

    // MARK: - 5. Volume & Latency Buffer Controls
    private var volumeAndLatencyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Volume & Latency Buffer", systemImage: "waveform.path.ecg")
                .font(.subheadline.bold())
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("PC Stream Volume")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Spacer()
                    Text("\(Int(receiver.volumeGain * 100))%")
                        .font(.caption.bold())
                }
                Slider(value: $receiver.volumeGain, in: 0.0...2.0, step: 0.05)
                    .tint(.cyan)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Max Jitter Buffer Ceiling")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Spacer()
                    Text("\(Int(receiver.targetBufferMs)) ms")
                        .font(.caption.bold())
                }
                Slider(value: $receiver.targetBufferMs, in: 5.0...50.0, step: 5.0)
                    .tint(.orange)
            }
        }
        .padding(16)
        .background(Color(red: 0.12, green: 0.16, blue: 0.23))
        .cornerRadius(12)
    }

    // MARK: - 6. Live Telemetry
    private var telemetryCard: some View {
        HStack {
            telemetryStat(title: "Buffer Latency", value: String(format: "%.1f ms", receiver.estimatedBufferMs))
            Spacer()
            telemetryStat(title: "Packets Recv", value: "\(receiver.packetsReceived)")
            Spacer()
            telemetryStat(title: "Dropped", value: "\(receiver.packetsDropped)")
        }
        .padding(16)
        .background(Color(red: 0.12, green: 0.16, blue: 0.23))
        .cornerRadius(12)
    }

    private func telemetryStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.gray)
            Text(value)
                .font(.subheadline.monospacedDigit().bold())
                .foregroundColor(.white)
        }
    }

    private func toggleStream() {
        if receiver.isRunning {
            receiver.stop()
        } else {
            let port = UInt16(manualPortString.trimmingCharacters(in: .whitespaces)) ?? 49152
            receiver.start(
                pcIpAddress: manualIpAddress.trimmingCharacters(in: .whitespaces),
                port: port
            )
        }
    }
}
