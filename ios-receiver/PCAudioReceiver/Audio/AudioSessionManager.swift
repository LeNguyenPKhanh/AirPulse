import Foundation
import AVFoundation
import MediaPlayer
import UIKit

/// Configures iOS `AVAudioSession`, `MPNowPlayingInfoCenter`, and `MPRemoteCommandCenter`
/// so AirPulse appears in the iOS Lock Screen, Notification Center, Control Center,
/// and Dynamic Island while streaming, and automatically turns off Dynamic Island
/// after a few seconds of inactivity (paused/stopped or silent PC).
final class AudioSessionManager: ObservableObject {
    static let shared = AudioSessionManager()

    /// Default false so iOS enables Lock Screen / Notification Center / Dynamic Island Now Playing controls.
    /// Can be toggled on in-app if the user wants to mix with other iPhone apps simultaneously.
    @Published var mixWithOthers: Bool = false {
        didSet {
            if isSessionActive {
                reconfigureSession()
            }
        }
    }

    @Published var duckOthers: Bool = false {
        didSet {
            if isSessionActive {
                reconfigureSession()
            }
        }
    }

    @Published private(set) var currentRouteDescription: String = "iPhone Speaker"

    var onInterruptionEnded: (() -> Void)?
    var onRemotePlayRequested: (() -> Void)?
    var onRemotePauseRequested: (() -> Void)?
    var onRemoteToggleRequested: (() -> Void)?
    var onInactivitySessionDeactivated: (() -> Void)?

    private var cachedArtwork: MPMediaItemArtwork?
    private var remoteCommandsConfigured = false
    private var isSessionActive = false
    private var inactivityDismissWorkItem: DispatchWorkItem?

    private init() {
        setupNotifications()
        updateRouteDescription()
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
            // Best-effort preferred sample rate & 15ms hardware DMA buffer (graceful on all iPhones/iPads/AirPods)
            try? session.setPreferredSampleRate(48000.0)
            try? session.setPreferredIOBufferDuration(0.015)
            try session.setActive(true, options: [])
            isSessionActive = true
            updateRouteDescription()
        } catch {
            print("[AudioSessionManager] Failed to configure AVAudioSession: \(error.localizedDescription)")
        }
    }

    // MARK: - Lock Screen, Notification Center & Dynamic Island Now Playing

    private func setupRemoteTransportControls() {
        guard !remoteCommandsConfigured else { return }
        remoteCommandsConfigured = true

        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.onRemotePlayRequested?()
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.onRemotePauseRequested?()
            return .success
        }

        commandCenter.stopCommand.addTarget { [weak self] _ in
            self?.onRemotePauseRequested?()
            return .success
        }

        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.onRemoteToggleRequested?()
            return .success
        }

        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        commandCenter.changePlaybackPositionCommand.isEnabled = false
    }

    private func setRemoteCommandsEnabled(_ enabled: Bool) {
        setupRemoteTransportControls()
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = enabled
        commandCenter.pauseCommand.isEnabled = enabled
        commandCenter.stopCommand.isEnabled = enabled
        commandCenter.togglePlayPauseCommand.isEnabled = enabled

        if enabled {
            UIApplication.shared.beginReceivingRemoteControlEvents()
        } else {
            UIApplication.shared.endReceivingRemoteControlEvents()
        }
    }

    func updateNowPlayingInfo(isStreaming: Bool, pcName: String, codec: String) {
        DispatchQueue.main.async {
            self.inactivityDismissWorkItem?.cancel()
            self.inactivityDismissWorkItem = nil

            self.setRemoteCommandsEnabled(true)

            var info: [String: Any] = [
                MPMediaItemPropertyTitle: isStreaming ? "AirPulse • \(pcName)" : "AirPulse • Paused",
                MPMediaItemPropertyArtist: isStreaming
                    ? "PC Live Audio (\(codec))"
                    : "Stream Paused • Closing in 4s...",
                MPMediaItemPropertyAlbumTitle: "AirPulse Liquid Glass Audio Bridge",
                MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: isStreaming ? 1.0 : 0.0,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0
            ]

            if let artwork = self.getOrCreateArtwork() {
                info[MPMediaItemPropertyArtwork] = artwork
            }

            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            if #available(iOS 13.0, *) {
                MPNowPlayingInfoCenter.default().playbackState = isStreaming ? .playing : .paused
            }

            // When stopped/paused, automatically dismiss Dynamic Island & Now Playing after 4 seconds of inactivity
            if !isStreaming {
                let workItem = DispatchWorkItem { [weak self] in
                    self?.dismissDynamicIslandCompletely()
                }
                self.inactivityDismissWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: workItem)
            }
        }
    }

    /// Hides the Dynamic Island Now Playing Live Activity when the PC has been completely silent for a few seconds,
    /// while keeping the background audio session alive so audio resumes instantly when the PC plays sound again.
    func hideNowPlayingForSilence() {
        DispatchQueue.main.async {
            self.inactivityDismissWorkItem?.cancel()
            self.inactivityDismissWorkItem = nil
            self.setRemoteCommandsEnabled(false)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            if #available(iOS 13.0, *) {
                MPNowPlayingInfoCenter.default().playbackState = .stopped
            }
        }
    }

    /// Completely tears down Dynamic Island, Lock Screen Now Playing, and deactivates AVAudioSession after inactivity.
    func dismissDynamicIslandCompletely() {
        DispatchQueue.main.async {
            self.inactivityDismissWorkItem?.cancel()
            self.inactivityDismissWorkItem = nil

            self.onInactivitySessionDeactivated?()
            self.setRemoteCommandsEnabled(false)

            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            if #available(iOS 13.0, *) {
                MPNowPlayingInfoCenter.default().playbackState = .stopped
            }

            if self.isSessionActive {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                self.isSessionActive = false
            }
        }
    }

    private func getOrCreateArtwork() -> MPMediaItemArtwork? {
        if let existing = cachedArtwork {
            return existing
        }

        let size = CGSize(width: 600, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let colorSpace = CGColorSpaceCreateDeviceRGB()

            // 1. Rich Midnight Silk Background
            let bgColors = [
                UIColor(red: 0.06, green: 0.08, blue: 0.14, alpha: 1.0).cgColor,
                UIColor(red: 0.11, green: 0.10, blue: 0.22, alpha: 1.0).cgColor,
                UIColor(red: 0.05, green: 0.07, blue: 0.12, alpha: 1.0).cgColor
            ] as CFArray
            if let grad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.5, 1.0]) {
                cg.drawLinearGradient(grad, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }

            // 2. Soft Warm Coral & Sky Orbs (Apple Music / Dynamic Island aesthetic)
            let coralColors = [
                UIColor(red: 1.0, green: 0.52, blue: 0.38, alpha: 0.65).cgColor,
                UIColor(red: 1.0, green: 0.52, blue: 0.38, alpha: 0.0).cgColor
            ] as CFArray
            if let coralGrad = CGGradient(colorsSpace: colorSpace, colors: coralColors, locations: [0.0, 1.0]) {
                cg.drawRadialGradient(
                    coralGrad,
                    startCenter: CGPoint(x: 160, y: 150),
                    startRadius: 10,
                    endCenter: CGPoint(x: 160, y: 150),
                    endRadius: 320,
                    options: []
                )
            }

            let skyColors = [
                UIColor(red: 0.38, green: 0.78, blue: 1.0, alpha: 0.60).cgColor,
                UIColor(red: 0.38, green: 0.78, blue: 1.0, alpha: 0.0).cgColor
            ] as CFArray
            if let skyGrad = CGGradient(colorsSpace: colorSpace, colors: skyColors, locations: [0.0, 1.0]) {
                cg.drawRadialGradient(
                    skyGrad,
                    startCenter: CGPoint(x: 450, y: 440),
                    startRadius: 10,
                    endCenter: CGPoint(x: 450, y: 440),
                    endRadius: 340,
                    options: []
                )
            }

            // 3. Center Glass Squircle
            let cardRect = CGRect(x: 130, y: 130, width: 340, height: 340)
            let cardPath = UIBezierPath(roundedRect: cardRect, cornerRadius: 84)
            UIColor(white: 1.0, alpha: 0.12).setFill()
            cardPath.fill()
            UIColor(white: 1.0, alpha: 0.35).setStroke()
            cardPath.lineWidth = 4
            cardPath.stroke()

            // 4. Stylized Acoustic Waveform Bars
            let barHeights: [CGFloat] = [70, 130, 200, 150, 220, 120, 75]
            let barWidth: CGFloat = 20
            let spacing: CGFloat = 16
            let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * spacing
            var startX = (size.width - totalWidth) / 2.0

            UIColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 0.95).setFill()
            for h in barHeights {
                let y = (size.height - h) / 2.0
                let barRect = CGRect(x: startX, y: y, width: barWidth, height: h)
                let barPath = UIBezierPath(roundedRect: barRect, cornerRadius: barWidth / 2.0)
                barPath.fill()
                startX += barWidth + spacing
            }
        }

        let artwork = MPMediaItemArtwork(boundsSize: size) { _ in image }
        cachedArtwork = artwork
        return artwork
    }

    // MARK: - Notifications

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

        if type == .ended && isSessionActive {
            reconfigureSession()
            onInterruptionEnded?()
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        updateRouteDescription()
        if isSessionActive {
            onInterruptionEnded?()
        }
    }

    private func updateRouteDescription() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if let first = outputs.first {
            DispatchQueue.main.async {
                self.currentRouteDescription = first.portName
            }
        }
    }
}
