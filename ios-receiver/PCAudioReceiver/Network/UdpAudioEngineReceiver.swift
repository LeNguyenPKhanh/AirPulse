import Foundation
import AVFoundation
import UIKit
import Darwin

/// Receives real-time UDP audio packets ("AS" 12-byte header), decodes Opus/PCM16 frames,
/// and schedules audio continuously on a persistent `AVAudioEngine` + persistent UDP socket.
/// Supports Lock Screen, Notification Center, Control Center, and Dynamic Island Now Playing controls.
final class UdpAudioEngineReceiver: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var connectionStatus: String = "Ready to Connect"
    @Published private(set) var activeCodecName: String = "PCM 48kHz"
    @Published private(set) var packetsReceived: UInt64 = 0
    @Published private(set) var packetsDropped: UInt64 = 0
    @Published private(set) var estimatedBufferMs: Double = 0.0
    @Published private(set) var outputPeakLevel: Float = 0.0

    @Published var volumeGain: Float = 1.0
    @Published var targetBufferMs: Double = 25.0 // Configurable 10ms - 80ms jitter ceiling

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let decoder = OpusAndPcmDecoder()

    private let stateLock = NSLock()
    private let audioLock = NSLock()

    private var persistentSocketFd: Int32 = -1
    private var boundPort: UInt16 = 49152
    private var sessionGeneration: UInt64 = 0
    private var keepAliveTimer: DispatchSourceTimer?
    private var isDestroyed = false

    private var inflightBuffers: Int32 = 0
    private var lastSequenceNumber: UInt16?
    private var lastAudioPacketTime: TimeInterval = 0
    private var lastHandshakeSentTime: TimeInterval = 0
    private var pairedPcName: String = "Windows 11 PC"
    private var activePcIp: String = UserDefaults.standard.string(forKey: "lastPcIpAddress") ?? "192.168.102.5"
    private var activePcPort: UInt16 = 49152

    init() {
        setupAudioEngine()
        setupPersistentSocket(port: 49152)
        startPersistentHeartbeatTimer()
        bindRemoteMediaCommands()

        AudioSessionManager.shared.onInterruptionEnded = { [weak self] in
            self?.ensureEngineRunning()
        }
    }

    deinit {
        isDestroyed = true
        keepAliveTimer?.cancel()
        if persistentSocketFd >= 0 {
            _ = Darwin.shutdown(persistentSocketFd, SHUT_RDWR)
            _ = Darwin.close(persistentSocketFd)
        }
    }

    // MARK: - Lock Screen / Notification Center / Dynamic Island Remote Controls

    private func bindRemoteMediaCommands() {
        AudioSessionManager.shared.onRemotePlayRequested = { [weak self] in
            guard let self = self else { return }
            self.resumeFromRemote()
        }

        AudioSessionManager.shared.onRemotePauseRequested = { [weak self] in
            guard let self = self else { return }
            self.stop()
        }

        AudioSessionManager.shared.onRemoteToggleRequested = { [weak self] in
            guard let self = self else { return }
            if self.isRunning {
                self.stop()
            } else {
                self.resumeFromRemote()
            }
        }
    }

    func resumeFromRemote() {
        stateLock.lock()
        let ip = activePcIp.isEmpty
            ? (UserDefaults.standard.string(forKey: "lastPcIpAddress") ?? "192.168.102.5")
            : activePcIp
        let port = activePcPort
        stateLock.unlock()

        start(pcIpAddress: ip, port: port)
    }

    // MARK: - Persistent AVAudioEngine & Persistent UDP Socket

    private func setupAudioEngine() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: decoder.audioFormat)
        audioEngine.prepare()
        ensureEngineRunning()
    }

    private func ensureEngineRunning() {
        audioLock.lock()
        defer { audioLock.unlock() }

        if !audioEngine.isRunning {
            do {
                AudioSessionManager.shared.reconfigureSession()
                try audioEngine.start()
            } catch {
                print("[UdpAudioEngineReceiver] Failed to start AVAudioEngine: \(error)")
            }
        }
        if audioEngine.isRunning && !playerNode.isPlaying {
            playerNode.play()
        }
    }

    private func setupPersistentSocket(port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var rcvBufSize: Int32 = 262144
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBufSize, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var localAddr = sockaddr_in()
        localAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        localAddr.sin_family = sa_family_t(AF_INET)
        localAddr.sin_port = port.bigEndian
        localAddr.sin_addr.s_addr = INADDR_ANY

        let bindRes = withUnsafePointer(to: &localAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindRes == 0 else {
            _ = Darwin.close(fd)
            return
        }

        persistentSocketFd = fd
        boundPort = port

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            self?.persistentReceiveLoop(fd: fd)
        }
    }

    // MARK: - Instant, Lock-Free Start & Stop

    func start(pcIpAddress: String, port: UInt16 = 49152) {
        let cleanIp = pcIpAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanIp.isEmpty else { return }

        ensureEngineRunning()

        let now = CFAbsoluteTimeGetCurrent()
        stateLock.lock()
        sessionGeneration &+= 1
        let gen = sessionGeneration
        isRunning = true
        activePcIp = cleanIp
        activePcPort = port
        lastSequenceNumber = nil
        lastAudioPacketTime = 0 // Force immediate handshake retry until first audio packet arrives
        lastHandshakeSentTime = now
        let fd = persistentSocketFd
        let pcName = pairedPcName
        stateLock.unlock()

        DispatchQueue.main.async {
            self.packetsReceived = 0
            self.packetsDropped = 0
            self.estimatedBufferMs = 0.0
            self.outputPeakLevel = 0.0
            self.connectionStatus = "Connecting to \(cleanIp)..."
            AudioSessionManager.shared.updateNowPlayingInfo(
                isStreaming: true,
                pcName: pcName,
                codec: self.activeCodecName
            )
        }

        // Send immediate handshake + 2 rapid follow-ups at +120ms and +300ms so even if the user
        // spammed Stop/Start rapidly, the Start handshake always wins after any in-flight Stop!
        let hsPayload = "AH\(boundPort)|\(UIDevice.current.name)"
        sendDatagram(fd: fd, payload: hsPayload, toIp: cleanIp, port: port)

        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let stillActive = self.isRunning && self.sessionGeneration == gen
            self.stateLock.unlock()
            if stillActive {
                self.sendDatagram(fd: fd, payload: hsPayload, toIp: cleanIp, port: port)
            }
        }

        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self = self else { return }
            self.stateLock.lock()
            let stillActive = self.isRunning && self.sessionGeneration == gen
            self.stateLock.unlock()
            if stillActive {
                self.sendDatagram(fd: fd, payload: hsPayload, toIp: cleanIp, port: port)
            }
        }
    }

    func stop() {
        stateLock.lock()
        sessionGeneration &+= 1
        let gen = sessionGeneration
        isRunning = false
        let fd = persistentSocketFd
        let ip = activePcIp
        let port = activePcPort
        let pcName = pairedPcName
        stateLock.unlock()

        DispatchQueue.main.async {
            self.connectionStatus = "Ready to Connect"
            self.estimatedBufferMs = 0.0
            self.outputPeakLevel = 0.0
            AudioSessionManager.shared.updateNowPlayingInfo(
                isStreaming: false,
                pcName: pcName,
                codec: self.activeCodecName
            )
        }

        // Send AH_STOP immediately and once more at +60ms (only if still stopped)
        if fd >= 0 && !ip.isEmpty {
            sendDatagram(fd: fd, payload: "AH_STOP", toIp: ip, port: port)
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
                guard let self = self else { return }
                self.stateLock.lock()
                let stillStopped = !self.isRunning && self.sessionGeneration == gen
                self.stateLock.unlock()
                if stillStopped {
                    self.sendDatagram(fd: fd, payload: "AH_STOP", toIp: ip, port: port)
                }
            }
        }
    }

    private func sendDatagram(fd: Int32, payload: String, toIp ip: String, port: UInt16) {
        guard fd >= 0, !ip.isEmpty, let data = payload.data(using: .utf8) else { return }

        var targetAddr = sockaddr_in()
        targetAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        targetAddr.sin_family = sa_family_t(AF_INET)
        targetAddr.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &targetAddr.sin_addr)

        data.withUnsafeBytes { rawBytes in
            guard let base = rawBytes.baseAddress else { return }
            withUnsafePointer(to: &targetAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                    _ = sendto(fd, base, data.count, 0, addrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    // MARK: - Background Keep-Alive & Automatic Re-Handshake Timer

    private func startPersistentHeartbeatTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.isDestroyed else { return }

            let now = CFAbsoluteTimeGetCurrent()
            self.stateLock.lock()
            let active = self.isRunning
            let fd = self.persistentSocketFd
            let ip = self.activePcIp
            let port = self.activePcPort
            let lastAudio = self.lastAudioPacketTime
            let lastHs = self.lastHandshakeSentTime
            let currentInflight = self.inflightBuffers
            self.stateLock.unlock()

            let silenceElapsed = now - lastAudio

            // 1. Keep AVAudioEngine warm when idle/paused or waiting for packets so iOS Lock Screen
            //    media controls & Dynamic Island Now Playing never disappear when screen is locked.
            if (!active || silenceElapsed > 0.20) && currentInflight < 2 {
                if let silence = self.decoder.makeSilenceBuffer(frameCount: 480) {
                    self.enqueueSilentKeepAlive(silence)
                }
            }

            // 2. If streaming is ON and no audio packets arrived in the last 0.6s, automatically
            //    re-send the "AH" handshake every 0.6s so the PC always resumes streaming!
            if active && fd >= 0 && !ip.isEmpty && silenceElapsed > 0.60 && (now - lastHs) >= 0.60 {
                self.stateLock.lock()
                self.lastHandshakeSentTime = now
                self.stateLock.unlock()
                self.sendDatagram(fd: fd, payload: "AH\(self.boundPort)|\(UIDevice.current.name)", toIp: ip, port: port)
            }
        }
        keepAliveTimer = timer
        timer.resume()
    }

    // MARK: - Persistent UDP Receive Loop

    private func persistentReceiveLoop(fd: Int32) {
        var packetBuf = [UInt8](repeating: 0, count: 4096)

        while !isDestroyed {
            let bytesRead = recv(fd, &packetBuf, packetBuf.count, 0)
            if bytesRead <= 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                    continue
                }
                if isDestroyed { break }
                usleep(10_000)
                continue
            }

            stateLock.lock()
            let active = isRunning
            let gen = sessionGeneration
            stateLock.unlock()

            // When stopped/paused, ignore any incoming packets
            if !active {
                continue
            }

            let now = CFAbsoluteTimeGetCurrent()

            // 1. Check for Handshake ACK ("AH_ACK|PC_NAME")
            if bytesRead >= 6 && packetBuf[0] == 0x41 && packetBuf[1] == 0x48 {
                if let text = String(bytes: packetBuf[0..<bytesRead], encoding: .utf8),
                   text.hasPrefix("AH_ACK|") {
                    let pcName = text.replacingOccurrences(of: "AH_ACK|", with: "")
                    stateLock.lock()
                    self.pairedPcName = pcName
                    let hasAudio = self.lastAudioPacketTime > 0
                    stateLock.unlock()

                    DispatchQueue.main.async {
                        guard self.isRunning, self.sessionGeneration == gen else { return }
                        self.connectionStatus = hasAudio
                            ? "Streaming • \(pcName)"
                            : "Connected • \(pcName)"
                        AudioSessionManager.shared.updateNowPlayingInfo(
                            isStreaming: true,
                            pcName: pcName,
                            codec: self.activeCodecName
                        )
                    }
                }
                continue
            }

            // 2. Validate 12-byte Audio Stream Header ("AS" = 0x41 0x53)
            guard bytesRead > 12,
                  packetBuf[0] == 0x41,
                  packetBuf[1] == 0x53 else {
                continue
            }

            let seq = (UInt16(packetBuf[2]) << 8) | UInt16(packetBuf[3])
            let codecByte = packetBuf[8]
            let payloadLen = Int((UInt16(packetBuf[9]) << 8) | UInt16(packetBuf[10]))
            let flags = packetBuf[11]

            guard bytesRead >= 12 + payloadLen, payloadLen > 0 else {
                continue
            }

            stateLock.lock()
            self.lastAudioPacketTime = now
            var droppedThisStep: UInt64 = 0
            if let prevSeq = self.lastSequenceNumber {
                let expected = prevSeq &+ 1
                if seq != expected {
                    let diff = seq &- expected
                    if diff < 1000 {
                        droppedThisStep = UInt64(diff)
                    }
                }
            }
            self.lastSequenceNumber = seq
            let currentQueued = Int(self.inflightBuffers)
            let pcName = self.pairedPcName
            stateLock.unlock()

            // Adaptive jitter ceiling
            let maxAllowedBuffers = max(4, Int(ceil(targetBufferMs / 10.0)))
            if currentQueued > maxAllowedBuffers + 3 {
                continue
            }

            let payloadData = Data(packetBuf[12..<(12 + payloadLen)])
            let isOpus = (codecByte & 0x02) != 0
            let isSilentKeepAlive = (flags & 0x04) != 0

            let pcmBuffer: AVAudioPCMBuffer?
            if isSilentKeepAlive {
                pcmBuffer = decoder.makeSilenceBuffer(frameCount: 480)
            } else if isOpus {
                pcmBuffer = decoder.decodeOpus(payload: payloadData, expectedFrames: 480, volumeGain: volumeGain)
            } else {
                pcmBuffer = decoder.decodePcm16(payload: payloadData, volumeGain: volumeGain)
            }

            if let validBuffer = pcmBuffer {
                let frameMs = Double(validBuffer.frameLength) / 48.0
                enqueueAudioBuffer(validBuffer)

                DispatchQueue.main.async {
                    guard self.isRunning, self.sessionGeneration == gen else { return }
                    self.packetsReceived &+= 1
                    if droppedThisStep > 0 {
                        self.packetsDropped &+= droppedThisStep
                    }

                    if self.packetsReceived % 6 == 1 {
                        var peak: Float = 0.0
                        if !isSilentKeepAlive, let ch = validBuffer.floatChannelData?[0] {
                            let n = Int(min(validBuffer.frameLength, 240))
                            for i in stride(from: 0, to: n, by: 4) {
                                let a = abs(ch[i])
                                if a > peak { peak = a }
                            }
                        }
                        let codecLabel = isOpus ? "Opus 48kHz" : "PCM 48kHz"
                        let statusText = "Streaming • \(pcName)"
                        let statusChanged = self.connectionStatus != statusText

                        self.connectionStatus = statusText
                        self.activeCodecName = codecLabel
                        self.estimatedBufferMs = Double(currentQueued) * frameMs
                        self.outputPeakLevel = min(1.0, peak)

                        if statusChanged {
                            AudioSessionManager.shared.updateNowPlayingInfo(
                                isStreaming: true,
                                pcName: pcName,
                                codec: codecLabel
                            )
                        }
                    }
                }
            }
        }
    }

    private func enqueueAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        guard isRunning else {
            stateLock.unlock()
            return
        }
        inflightBuffers += 1
        stateLock.unlock()

        audioLock.lock()
        if !audioEngine.isRunning {
            try? audioEngine.start()
        }
        if audioEngine.isRunning {
            if !playerNode.isPlaying {
                playerNode.play()
            }
            playerNode.scheduleBuffer(buffer) { [weak self] in
                guard let self = self else { return }
                self.stateLock.lock()
                self.inflightBuffers = max(0, self.inflightBuffers - 1)
                self.stateLock.unlock()
            }
        } else {
            stateLock.lock()
            inflightBuffers = max(0, inflightBuffers - 1)
            stateLock.unlock()
        }
        audioLock.unlock()
    }

    private func enqueueSilentKeepAlive(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        inflightBuffers += 1
        stateLock.unlock()

        audioLock.lock()
        if audioEngine.isRunning {
            if !playerNode.isPlaying {
                playerNode.play()
            }
            playerNode.scheduleBuffer(buffer) { [weak self] in
                guard let self = self else { return }
                self.stateLock.lock()
                self.inflightBuffers = max(0, self.inflightBuffers - 1)
                self.stateLock.unlock()
            }
        } else {
            stateLock.lock()
            inflightBuffers = max(0, inflightBuffers - 1)
            stateLock.unlock()
        }
        audioLock.unlock()
    }
}
