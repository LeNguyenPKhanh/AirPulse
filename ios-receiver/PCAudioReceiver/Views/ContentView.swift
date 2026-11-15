import SwiftUI
import WebKit
import UIKit

// MARK: - Full-Screen WKWebView Hosting Official naughtyduk/liquidGL Library

struct LiquidGLWebView: UIViewRepresentable {
    @ObservedObject var audioSession: AudioSessionManager
    @ObservedObject var bleScanner: BleScannerManager
    @ObservedObject var receiver: UdpAudioEngineReceiver
    @Binding var manualIpAddress: String
    @Binding var manualPortString: String

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
        context.coordinator.pushStateToWeb()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: LiquidGLWebView
        weak var webView: WKWebView?
        private var isWebReady = false
        private var stateTimer: Timer?

        init(parent: LiquidGLWebView) {
            self.parent = parent
            super.init()
            self.stateTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                self?.pushStateToWeb()
            }
        }

        deinit {
            stateTimer?.invalidate()
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
                    self.pushStateToWeb()

                case "rescan":
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                    self.parent.bleScanner.startScanning()

                case "connectEndpoint":
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if let ip = body["ip"] as? String {
                        let portNum = (body["port"] as? Int) ?? 49152
                        self.parent.manualIpAddress = ip
                        self.parent.manualPortString = String(portNum)
                        self.parent.receiver.start(pcIpAddress: ip, port: UInt16(portNum))
                    }

                case "toggleStream":
                    UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                    if self.parent.receiver.isRunning {
                        self.parent.receiver.stop()
                    } else {
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

                self.pushStateToWeb()
            }
        }

        func pushStateToWeb() {
            guard isWebReady, let webView = webView else { return }

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

            webView.evaluateJavaScript("window.updateAppState && window.updateAppState(\(jsonString));", completionHandler: nil)
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
        LiquidGLWebView(
            audioSession: audioSession,
            bleScanner: bleScanner,
            receiver: receiver,
            manualIpAddress: $manualIpAddress,
            manualPortString: $manualPortString
        )
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
    }
}
