import SwiftUI
import AVFoundation
import Combine

struct ContentView: View {
    @StateObject private var audioSession = AudioSessionManager.shared
    @StateObject private var bleScanner = BleScannerManager()
    @StateObject private var receiver = UdpAudioEngineReceiver()

    @AppStorage("lastPcIpAddress") private var manualIpAddress: String = ""
    @AppStorage("lastUdpPort") private var manualPortString: String = "49152"
    @State private var isAnimatingWave: Bool = false
    @State private var showSettings: Bool = false
    @State private var ipDraft: String = ""
    @State private var portDraft: String = "49152"
    @State private var probeDebounceTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.06, green: 0.07, blue: 0.09), Color(red: 0.1, green: 0.1, blue: 0.13)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        headerSection
                        statusCard
                        discoveryCard
                        tuningCard
                        togglesCard
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("AirPulse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .onAppear {
                ipDraft = manualIpAddress
                portDraft = manualPortString

                bleScanner.onEndpointSeen = { ep in
                    receiver.notifyEndpointSeen(ip: ep.ipAddress, port: ep.port, name: ep.name)
                    DispatchQueue.main.async {
                        if manualIpAddress.isEmpty || !receiver.isRunning {
                            manualIpAddress = ep.ipAddress
                            manualPortString = String(ep.port)
                            ipDraft = ep.ipAddress
                            portDraft = String(ep.port)
                        }
                    }
                }
                receiver.onPcEndpointVerified = { ip, port, name in
                    bleScanner.registerEndpoint(
                        DiscoveredPcEndpoint(name: name, ipAddress: ip, port: port, source: "UDP Probe")
                    )
                }

                bleScanner.startScanning()
                receiver.triggerActiveLanProbe()
            }
            .onChange(of: manualIpAddress) { _, newVal in
                if ipDraft != newVal { ipDraft = newVal }
            }
            .onChange(of: manualPortString) { _, newVal in
                if portDraft != newVal { portDraft = newVal }
            }
            .onReceive(Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()) { _ in
                isAnimatingWave = receiver.isRunning
            }
        }
    }

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("AirPulse")
                    .font(.system(size: 28, weight: .bold, design: .default))
                Text("PC → iPhone audio bridge")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(receiver.isRunning ? Color.green : Color.cyan)
                    .frame(width: 8, height: 8)
                Text(receiver.activeCodecName)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Live Audio Bridge", systemImage: "waveform.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(receiver.connectionStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: "waveform")
                        .font(.title2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(receiver.isRunning ? "Streaming" : (receiver.isPcReachable ? "Ready" : "Waiting for PC"))
                        .font(.headline)
                    Text(receiver.reachablePcName.isEmpty ? bleScanner.bluetoothStateText : receiver.reachablePcName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            waveformView
            HStack(spacing: 12) {
                statBox(title: "Buffer", value: String(format: "%.1f ms", receiver.estimatedBufferMs))
                statBox(title: "Packets", value: "\(receiver.packetsReceived.formatted())")
                statBox(title: "Dropped", value: "\(receiver.packetsDropped.formatted())")
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private func statBox(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
    }

    private var waveformView: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !receiver.isRunning)) { timeline in
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let bars = 32
                let barW = max(2, (w - CGFloat(bars - 1) * 2) / CGFloat(bars))
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<bars, id: \.self) { i in
                        let phase = Double(i) * 0.35 + t * 4
                        let peak = Double(max(0.05, min(1, receiver.outputPeakLevel)))
                        let amp = receiver.isRunning ? (0.18 + 0.82 * peak * abs(sin(phase))) : 0.12
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(0.85))
                            .frame(width: barW, height: max(4, h * amp))
                            .animation(.easeOut(duration: 0.08), value: receiver.outputPeakLevel)
                    }
                }
                .frame(width: w, height: h)
            }
        }
        .frame(height: 44)
        .padding(.vertical, 4)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
    }

    private var discoveryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("PC DISCOVERY & CONNECTION")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    bleScanner.startScanning()
                    receiver.triggerActiveLanProbe()
                } label: {
                    Text("Rescan")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glass)
            }

            if bleScanner.discoveredEndpoints.isEmpty {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Searching local network...")
                            .font(.subheadline.weight(.medium))
                        Text("Ensure AirPulse is running on your PC")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
            } else {
                ForEach(bleScanner.discoveredEndpoints) { ep in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ep.name).font(.subheadline.weight(.medium))
                            Text("\(ep.ipAddress):\(ep.port) · \(ep.source)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            selectEndpoint(ep)
                        } label: {
                            Text(receiver.isRunning && receiver.currentTargetIp == ep.ipAddress ? "Connected" : "Connect")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                    }
                    .padding(12)
                    .background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
                }
            }

            HStack(spacing: 10) {
                TextField("PC IP (auto)", text: $ipDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .padding(12)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
                    .onChange(of: ipDraft) { _, _ in scheduleProbe() }
                TextField("Port", text: $portDraft)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numberPad)
                    .frame(width: 90)
                    .padding(12)
                    .background(.white.opacity(0.08), in: .rect(cornerRadius: 12))
                    .onChange(of: portDraft) { _, _ in scheduleProbe() }
            }

            Button {
                toggleStream()
            } label: {
                HStack {
                    Image(systemName: receiver.isRunning ? "stop.fill" : (receiver.isPcReachable ? "play.fill" : "lock.fill"))
                    Text(streamButtonTitle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.glassProminent)
            .disabled(!receiver.isRunning && !receiver.isPcReachable)
            .opacity((!receiver.isRunning && !receiver.isPcReachable) ? 0.5 : 1)
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var streamButtonTitle: String {
        if receiver.isRunning { return "Stop Audio Stream" }
        if receiver.isPcReachable {
            if receiver.reachablePcName.isEmpty { return "Start Audio Stream" }
            return "Start Audio Stream • \(receiver.reachablePcName)"
        }
        return "Waiting for PC Connection..."
    }

    private var tuningCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("ACOUSTIC & BUFFER TUNING")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("PC Stream Volume")
                    Spacer()
                    Text("\(Int(receiver.volumeGain * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(receiver.volumeGain * 100) },
                    set: { receiver.volumeGain = Float($0 / 100) }
                ), in: 0...200, step: 1)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Jitter Buffer Cushion")
                    Spacer()
                    Text("\(Int(receiver.targetBufferMs)) ms")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $receiver.targetBufferMs, in: 20...100, step: 1)
            }
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private var togglesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DYNAMIC ISLAND, LOCK SCREEN & MIXING")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle(isOn: $audioSession.mixWithOthers) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mix With Other iPhone Apps")
                        .font(.subheadline.weight(.medium))
                    Text("Keep OFF for Lock Screen/Dynamic Island controls. Turn ON to mix with games/apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Color.green)

            Toggle(isOn: $audioSession.duckOthers) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Duck Other Audio")
                        .font(.subheadline.weight(.medium))
                    Text("Lower other app volume while streaming")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Color.green)
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
    }

    private func selectEndpoint(_ ep: DiscoveredPcEndpoint) {
        ipDraft = ep.ipAddress
        portDraft = String(ep.port)
        manualIpAddress = ep.ipAddress
        manualPortString = String(ep.port)
        receiver.notifyEndpointSeen(ip: ep.ipAddress, port: ep.port, name: ep.name)
        receiver.updateManualTarget(ip: ep.ipAddress, port: ep.port)
    }

    private func scheduleProbe() {
        probeDebounceTask?.cancel()
        probeDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            let ip = ipDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            let port = UInt16(portDraft.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 49152
            manualIpAddress = ip
            manualPortString = String(port)
            receiver.updateManualTarget(ip: ip, port: port)
        }
    }

    private func toggleStream() {
        let ip = ipDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = UInt16(portDraft.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 49152
        manualIpAddress = ip
        manualPortString = String(port)
        if receiver.isRunning {
            receiver.stop()
        } else {
            guard receiver.isPcReachable else {
                receiver.triggerActiveLanProbe()
                return
            }
            receiver.start(pcIpAddress: ip, port: port)
        }
    }
}

#Preview {
    ContentView()
}
