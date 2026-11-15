import SwiftUI

// MARK: - Apple Liquid Glass ViewModifier & Animated Aurora Backdrop

struct LiquidGlassCard: ViewModifier {
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                ZStack {
                    // 1. Frosted Ultra-Thin Glass Blur Layer
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)

                    // 2. Subtle Internal Glass Tint & Top Specular Sheen
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.14),
                                    Color.cyan.opacity(0.04),
                                    Color.clear,
                                    Color.indigo.opacity(0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                // 3. Refractive Specular Rim Highlight (Liquid Glass Edge)
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.65),
                                Color.cyan.opacity(0.30),
                                Color.white.opacity(0.08),
                                Color.indigo.opacity(0.45)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.2
                    )
            )
            .shadow(color: Color.black.opacity(0.38), radius: 16, x: 0, y: 8)
    }
}

extension View {
    func liquidGlassCard(cornerRadius: CGFloat = 20) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius))
    }
}

struct LiquidAuroraBackground: View {
    @State private var animateOrbs = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.05, blue: 0.12),
                    Color(red: 0.06, green: 0.10, blue: 0.22),
                    Color(red: 0.04, green: 0.06, blue: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Floating Cyan Liquid Orb
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.cyan.opacity(0.45), Color.clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 190
                    )
                )
                .frame(width: 360, height: 360)
                .offset(x: animateOrbs ? -80 : 70, y: animateOrbs ? -180 : -60)
                .blur(radius: 30)

            // Floating Electric Indigo Orb
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.indigo.opacity(0.48), Color.clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 210
                    )
                )
                .frame(width: 400, height: 400)
                .offset(x: animateOrbs ? 90 : -70, y: animateOrbs ? 160 : 40)
                .blur(radius: 35)

            // Floating Blue Pulse Orb
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.blue.opacity(0.35), Color.clear],
                        center: .center,
                        startRadius: 5,
                        endRadius: 160
                    )
                )
                .frame(width: 300, height: 300)
                .offset(x: animateOrbs ? -40 : 50, y: animateOrbs ? 260 : 180)
                .blur(radius: 28)
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeInOut(duration: 8.0).repeatForever(autoreverses: true)) {
                animateOrbs = true
            }
        }
    }
}

// MARK: - Main ContentView

struct ContentView: View {
    @StateObject private var audioSession = AudioSessionManager.shared
    @StateObject private var bleScanner = BleScannerManager()
    @StateObject private var receiver = UdpAudioEngineReceiver()

    @AppStorage("lastPcIpAddress") private var manualIpAddress: String = "192.168.102.5"
    @AppStorage("lastUdpPort") private var manualPortString: String = "49152"

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidAuroraBackground()

                ScrollView(showsIndicators: false) {
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
            }
            .navigationTitle("AirPulse • Liquid Glass")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - 1. Status Header
    private var statusHeaderCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(receiver.isRunning ? Color.green : Color.cyan)
                    .frame(width: 10, height: 10)
                    .shadow(color: receiver.isRunning ? .green : .cyan, radius: 6)

                Text(receiver.connectionStatus)
                    .font(.headline)
                    .foregroundColor(.white)

                Spacer()

                Text(receiver.activeCodecName)
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.8)
                    )
            }

            Text("Output Route: \(audioSession.currentRouteDescription)")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
        }
        .liquidGlassCard()
    }

    // MARK: - 2. BLE & Wi-Fi Auto-Discovery
    private var bleDiscoveryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Auto-Discovery (BLE + Wi-Fi)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline.bold())
                    .foregroundColor(.cyan)
                Spacer()
                Button(action: {
                    bleScanner.startScanning()
                }) {
                    Text("Rescan")
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().strokeBorder(Color.white.opacity(0.4), lineWidth: 0.8)
                        )
                }
                .foregroundColor(.white)
            }

            Text(bleScanner.bluetoothStateText)
                .font(.caption)
                .foregroundColor(.white.opacity(0.65))

            if bleScanner.discoveredEndpoints.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.85)
                    Text("Listening for Windows 11 PC broadcast...")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
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
                                .foregroundColor(.white.opacity(0.7))
                        }
                        Spacer()
                        Button(action: {
                            manualIpAddress = endpoint.ipAddress
                            manualPortString = String(endpoint.port)
                            receiver.start(pcIpAddress: endpoint.ipAddress, port: endpoint.port)
                        }) {
                            Text(receiver.isRunning && manualIpAddress == endpoint.ipAddress ? "Connected" : "Connect")
                                .font(.caption.bold())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    LinearGradient(
                                        colors: [Color.cyan, Color.blue],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.8)
                                )
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8)
                    )
                }
            }
        }
        .liquidGlassCard()
    }

    // MARK: - 3. Manual IP Connection & Primary Toggle
    private var manualConnectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Windows 11 PC Endpoint", systemImage: "desktopcomputer")
                .font(.subheadline.bold())
                .foregroundColor(.white)

            HStack(spacing: 10) {
                TextField("PC IPv4 (e.g. 192.168.102.5)", text: $manualIpAddress)
                    .keyboardType(.numbersAndPunctuation)
                    .padding(10)
                    .background(Color.black.opacity(0.28))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
                    )

                TextField("Port", text: $manualPortString)
                    .keyboardType(.numberPad)
                    .frame(width: 85)
                    .padding(10)
                    .background(Color.black.opacity(0.28))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
                    )
            }

            Button(action: toggleStream) {
                HStack {
                    Image(systemName: receiver.isRunning ? "stop.fill" : "play.fill")
                    Text(receiver.isRunning ? "STOP AUDIO STREAM" : "START AUDIO STREAM")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    LinearGradient(
                        colors: receiver.isRunning
                            ? [Color.red.opacity(0.9), Color.pink.opacity(0.8)]
                            : [Color.cyan.opacity(0.9), Color.blue.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.55), lineWidth: 1.0)
                )
                .shadow(color: (receiver.isRunning ? Color.red : Color.cyan).opacity(0.4), radius: 10, x: 0, y: 4)
            }
        }
        .liquidGlassCard()
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
                        .foregroundColor(.white.opacity(0.65))
                }
            }
            .tint(.cyan)

            Toggle(isOn: $audioSession.duckOthers) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duck Other Apps (.duckOthers)")
                        .font(.subheadline)
                    Text("Slightly lower other iPhone app volume while PC audio stream is active")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.65))
                }
            }
            .tint(.indigo)
        }
        .liquidGlassCard()
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
                        .foregroundColor(.white.opacity(0.75))
                    Spacer()
                    Text("\(Int(receiver.volumeGain * 100))%")
                        .font(.caption.bold())
                        .foregroundColor(.cyan)
                }
                Slider(value: $receiver.volumeGain, in: 0.0...2.0, step: 0.05)
                    .tint(.cyan)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Max Jitter Buffer Ceiling")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.75))
                    Spacer()
                    Text("\(Int(receiver.targetBufferMs)) ms")
                        .font(.caption.bold())
                        .foregroundColor(.cyan)
                }
                Slider(value: $receiver.targetBufferMs, in: 10.0...80.0, step: 5.0)
                    .tint(.indigo)
            }
        }
        .liquidGlassCard()
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
        .liquidGlassCard()
    }

    private func telemetryStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.65))
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
