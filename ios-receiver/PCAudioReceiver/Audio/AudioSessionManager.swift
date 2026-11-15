import Foundation
import AVFoundation

/// Configures iOS `AVAudioSession` for non-interruptive background playback (.playback + .mixWithOthers)
/// so incoming Windows 11 audio mixes seamlessly alongside native iOS apps (YouTube, TikTok, games)
/// and continues playing when the iPhone screen is locked.
final class AudioSessionManager: ObservableObject {
    static let shared = AudioSessionManager()

    @Published var mixWithOthers: Bool = true {
        didSet { reconfigureSession() }
    }

    @Published var duckOthers: Bool = false {
        didSet { reconfigureSession() }
    }

    @Published private(set) var currentRouteDescription: String = "System Output"

    var onInterruptionEnded: (() -> Void)?

    private init() {
        setupNotifications()
        reconfigureSession()
    }

    func reconfigureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            var options: AVAudioSession.CategoryOptions = []
            if mixWithOthers {
                options.insert(.mixWithOthers)
            }
            if duckOthers {
                options.insert(.mixWithOthers)
                options.insert(.duckOthers)
            }

            try session.setCategory(
                .playback,
                mode: .default,
                options: options
            )
            try session.setPreferredSampleRate(48000.0)
            try session.setPreferredIOBufferDuration(0.005) // ~5ms ultra-low latency hardware buffer
            try session.setActive(true, options: [])
            updateRouteDescription()
        } catch {
            print("[AudioSessionManager] Failed to configure AVAudioSession: \(error.localizedDescription)")
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        if type == .ended {
            reconfigureSession()
            onInterruptionEnded?()
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        updateRouteDescription()
        onInterruptionEnded?()
    }

    private func updateRouteDescription() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if let first = outputs.first {
            DispatchQueue.main.async {
                self.currentRouteDescription = "\(first.portName) (\(first.portType.rawValue))"
            }
        }
    }
}
