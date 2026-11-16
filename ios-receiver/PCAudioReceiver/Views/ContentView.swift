import SwiftUI
import WebKit
import UIKit

// MARK: - Apple-Style Launch / Loading Screen Overlay

struct AirPulseLaunchOverlay: View {
    @State private var pulseRings = false
    @State private var progressOffset: CGFloat = -90

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.059, green: 0.075, blue: 0.114),
                    Color(red: 0.090, green: 0.094, blue: 0.161),
                    Color(red: 0.051, green: 0.063, blue: 0.094)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 1.0, green: 0.53, blue: 0.40).opacity(0.28), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 180
                    )
                )
                .frame(width: 340, height: 340)
                .offset(x: -70, y: -150)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 0.47, green: 0.78, blue: 1.0).opacity(0.24), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 180
                    )
                )
                .frame(width: 340, height: 340)
                .offset(x: 80, y: 150)

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        .frame(width: 126, height: 126)
                        .scaleEffect(pulseRings ? 1.18 : 0.92)
                        .opacity(pulseRings ? 0.0 : 0.75)

                    Circle()
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                        .frame(width: 98, height: 98)
                        .scaleEffect(pulseRings ? 1.10 : 0.95)

                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: 78, height: 78)
                        .overlay(
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.55),
                                            Color.white.opacity(0.12)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1
                                )
                        )
                        .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 10)

                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.96, green: 0.96, blue: 0.97),
                                    Color(red: 0.72, green: 0.88, blue: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

                VStack(spacing: 6) {
                    Text("AirPulse")
                        .font(.system(size: 26, weight: .bold, design: .default))
                        .tracking(-0.5)
                        .foregroundColor(Color(red: 0.96, green: 0.96, blue: 0.97))

                    Text("Initializing Liquid Glass Engine...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.52))
                }

                ZStack {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 130, height: 4)

                    Capsule()
                        .fill(Color.white.opacity(0.88))
                        .frame(width: 48, height: 4)
                        .offset(x: progressOffset)
                }
                .clipShape(Capsule())
                .frame(width: 130, height: 4)
                .padding(.top, 6)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulseRings = true
            }
            withAnimation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true)) {
                progressOffset = 90
            }
        }
    }
}

// MARK: - Full-Screen WKWebView Hosting Official naughtyduk/liquidGL Library

struct LiquidGLWebView: UIViewRepresentable {
    @ObservedObject var audioSession: AudioSessionManager
    @ObservedObject var bleScanner: BleScannerManager
    @ObservedObject var receiver: UdpAudioEngineReceiver
    @Binding var manualIpAddress: String
    @Binding var manualPortString: String
    @Binding var isWebLoaded: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "airpulse")

        let config = WKWebViewConfiguration()
        config.userContentController = contentController
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.055, green: 0.063, blue: 0.09, alpha: 1.0)
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.showsVerticalScrollIndicator = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.bounces = true

        context.coordinator.webView = webView

        if let indexURL = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: LiquidGLWebView
        weak var webView: WKWebView?
        private var isWebReady = false
        private var isEvaluatingJs = false
        private var isAppInForeground = true
        private var lastToggleActionTime: TimeInterval = 0
        private var stateTimer: Timer?

        init(parent: LiquidGLWebView) {
            self.parent = parent
            super.init()

            // Wire mutual discovery & reachability between BleScannerManager and UdpAudioEngineReceiver
            parent.bleScanner.onEndpointSeen = { [weak self] ep in
                guard let self = self else { return }
                self.parent.receiver.notifyEndpointSeen(ip: ep.ipAddress, port: ep.port, name: ep.name)
                DispatchQueue.main.async {
                    if self.parent.manualIpAddress.isEmpty || !self.parent.receiver.isRunning {
                        self.parent.manualIpAddress = ep.ipAddress
                        self.parent.manualPortString = String(ep.port)
                    }
                }
            }

            parent.receiver.onPcEndpointVerified = { [weak self] ip, port, name in
                guard let self = self else { return }
                self.parent.bleScanner.registerEndpoint(
                    DiscoveredPcEndpoint(name: name, ipAddress: ip, port: port, source: "UDP Probe")
                )
            }

            self.stateTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
                self?.pushStateToWeb()
            }

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appWillResignActive),
                name: UIApplication.willResignActiveNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appDidBecomeActive),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
        }

        deinit {
            stateTimer?.invalidate()
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func appWillResignActive() {
            isAppInForeground = false
        }

        @objc private func appDidBecomeActive() {
            isAppInForeground = true
            parent.receiver.triggerActiveLanProbe()
            pushStateToWeb()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "airpulse",
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else {
                return
            }

            DispatchQueue.main.async {
                switch action {
                case "ready":
                    self.isWebReady = true
                    self.parent.receiver.triggerActiveLanProbe()
                    self.pushStateToWeb()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) {
                            self.parent.isWebLoaded = true
                        }
                    }

                case "rescan":
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    self.parent.bleScanner.startScanning()
                    self.parent.receiver.triggerActiveLanProbe()

                case "updateTargetEndpoint":
                    if let ip = body["ip"] as? String {
                        let portNum = (body["port"] as? Int) ?? 49152
                        self.parent.manualIpAddress = ip
                        self.parent.manualPortString = String(portNum)
                        self.parent.receiver.updateManualTarget(ip: ip, port: UInt16(clamping: portNum))
                    }

                case "connectEndpoint":
                    let now = CFAbsoluteTimeGetCurrent()
                    guard now - self.lastToggleActionTime > 0.22 else { return }
                    self.lastToggleActionTime = now

                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if let ip = body["ip"] as? String {
                        let portNum = (body["port"] as? Int) ?? 49152
                        self.parent.manualIpAddress = ip
                        self.parent.manualPortString = String(portNum)
                        self.parent.receiver.notifyEndpointSeen(
                            ip: ip,
                            port: UInt16(clamping: portNum),
                            name: (body["name"] as? String) ?? "Windows PC"
                        )
                        self.parent.receiver.start(pcIpAddress: ip, port: UInt16(clamping: portNum))
                    }

                case "toggleStream":
                    let now = CFAbsoluteTimeGetCurrent()
                    guard now - self.lastToggleActionTime > 0.22 else { return }
                    self.lastToggleActionTime = now

                    if self.parent.receiver.isRunning {
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        self.parent.receiver.stop()
                    } else {
                        guard self.parent.receiver.isPcReachable else {
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                            self.parent.receiver.triggerActiveLanProbe()
                            return
                        }
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        let ip = (body["ip"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? self.parent.manualIpAddress
                        let portNum = (body["port"] as? Int) ?? Int(self.parent.manualPortString) ?? 49152
                        self.parent.manualIpAddress = ip
                        self.parent.manualPortString = String(portNum)
                        self.parent.receiver.start(pcIpAddress: ip, port: UInt16(clamping: portNum))
                    }

                case "setVolume":
                    if let val = body["value"] as? Double {
                        self.parent.receiver.volumeGain = Float(val)
                    }

                case "setBufferMs":
                    if let ms = body["value"] as? Double {
                        self.parent.receiver.targetBufferMs = ms
                    }

                case "setMixWithOthers":
                    UISelectionFeedbackGenerator().selectionChanged()
                    if let val = body["value"] as? Bool {
                        self.parent.audioSession.mixWithOthers = val
                    }

                case "setDuckOthers":
                    UISelectionFeedbackGenerator().selectionChanged()
                    if let val = body["value"] as? Bool {
                        self.parent.audioSession.duckOthers = val
                    }

                default:
                    break
                }
            }
        }

        func pushStateToWeb() {
            guard isWebReady, isAppInForeground, !isEvaluatingJs, let webView = webView else { return }

            let endpointsArray: [[String: Any]] = parent.bleScanner.discoveredEndpoints.map { ep in
                [
                    "name": ep.name,
                    "ip": ep.ipAddress,
                    "port": Int(ep.port),
                    "source": ep.source
                ]
            }

            let stateDict: [String: Any] = [
                "isRunning": parent.receiver.isRunning,
                "isPcReachable": parent.receiver.isPcReachable,
                "reachablePcName": parent.receiver.reachablePcName,
                "currentTargetIp": parent.receiver.currentTargetIp,
                "currentTargetPort": Int(parent.receiver.currentTargetPort),
                "connectionStatus": parent.receiver.connectionStatus,
                "activeCodecName": parent.receiver.activeCodecName,
                "routeDescription": parent.audioSession.currentRouteDescription,
                "btState": parent.bleScanner.bluetoothStateText,
                "endpoints": endpointsArray,
                "mixWithOthers": parent.audioSession.mixWithOthers,
                "duckOthers": parent.audioSession.duckOthers,
                "volumeGain": Double(parent.receiver.volumeGain),
                "targetBufferMs": parent.receiver.targetBufferMs,
                "estimatedBufferMs": parent.receiver.estimatedBufferMs,
                "packetsReceived": parent.receiver.packetsReceived,
                "packetsDropped": parent.receiver.packetsDropped,
                "peakLevel": Double(parent.receiver.outputPeakLevel)
            ]

            guard let jsonData = try? JSONSerialization.data(withJSONObject: stateDict, options: []),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return
            }

            isEvaluatingJs = true
            webView.evaluateJavaScript("window.updateAppState && window.updateAppState(\(jsonString));") { [weak self] _, _ in
                self?.isEvaluatingJs = false
            }
        }
    }
}

// MARK: - Main ContentView

struct ContentView: View {
    @StateObject private var audioSession = AudioSessionManager.shared
    @StateObject private var bleScanner = BleScannerManager()
    @StateObject private var receiver = UdpAudioEngineReceiver()

    @AppStorage("lastPcIpAddress") private var manualIpAddress: String = ""
    @AppStorage("lastUdpPort") private var manualPortString: String = "49152"
    @State private var isWebLoaded: Bool = false

    var body: some View {
        ZStack {
            LiquidGLWebView(
                audioSession: audioSession,
                bleScanner: bleScanner,
                receiver: receiver,
                manualIpAddress: $manualIpAddress,
                manualPortString: $manualPortString,
                isWebLoaded: $isWebLoaded
            )
            .ignoresSafeArea()

            if !isWebLoaded {
                AirPulseLaunchOverlay()
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
                    .zIndex(100)
            }
        }
        .preferredColorScheme(.dark)
    }
}
