import Foundation
import AVFoundation
import UIKit
import Darwin

/// Receives real-time UDP audio packets ("AS" 12-byte header), decodes Opus/PCM16 frames,
/// manages an adaptive low-latency jitter buffer, and schedules audio continuously on
/// `AVAudioEngine` without blocking the main UI thread on rapid start/stop toggles.
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
    private let controlQueue = DispatchQueue(label: "com.antigravity.pcaudiostreamer.control", qos: .userInteractive)

    private var socketFd: Int32 = -1
    private var sessionGeneration: UInt64 = 0
    private var keepAliveTimer: DispatchSourceTimer?

    private var inflightBuffers: Int32 = 0
    private var lastSequenceNumber: UInt16?
    private var lastPacketTimestamp: TimeInterval = 0
    private var lastHandshakeTimestamp: TimeInterval = 0
    private var pairedPcName: String = "Windows 11 PC"
    private var activePcIp: String = ""
    private var activePcPort: UInt16 = 49152

    init() {
        setupAudioEngine()
        AudioSessionManager.shared.onInterruptionEnded = { [weak self] in
            self?.controlQueue.async {
                self?.ensureEngineRunning()
            }
        }
    }

    deinit {
        stop()
    }

    private func setupAudioEngine() {
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: decoder.audioFormat)
        audioEngine.prepare()
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

    func start(pcIpAddress: String, port: UInt16 = 49152) {
        let cleanIp = pcIpAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanIp.isEmpty else { return }

        stateLock.lock()
        sessionGeneration &+= 1
        let gen = sessionGeneration
        let oldFd = socketFd
        socketFd = -1
        isRunning = true
        activePcIp = cleanIp
        activePcPort = port
        pairedPcName = cleanIp
        stateLock.unlock()

        // ImmediatelyUpdate UI state so button responds in <1ms without freezing
        DispatchQueue.main.async {
            self.packetsReceived = 0
            self.packetsDropped = 0
            self.estimatedBufferMs = 0.0
            self.outputPeakLevel = 0.0
            self.connectionStatus = "Connecting to \(cleanIp)..."
        }

        // Perform socket teardown/bind and audio engine activation off the main thread
        controlQueue.async { [weak self] in
            guard let self = self else { return }

            // Cleanly wake & close any previous socket
            if oldFd >= 0 {
                _ = Darwin.shutdown(oldFd, SHUT_RDWR)
                _ = Darwin.close(oldFd)
            }

            self.stateLock.lock()
            guard self.sessionGeneration == gen, self.isRunning else {
                self.stateLock.unlock()
                return
            }
            self.stateLock.unlock()

            self.ensureEngineRunning()

            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else {
                DispatchQueue.main.async {
                    if self.sessionGeneration == gen {
                        self.isRunning = false
                        self.connectionStatus = "Socket Error"
                    }
                }
                return
            }

            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var rcvBufSize: Int32 = 131072
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBufSize, socklen_t(MemoryLayout<Int32>.size))

            // 200ms receive timeout so recv() never hangs forever
            var tv = timeval(tv_sec: 0, tv_usec: 200_000)
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
                DispatchQueue.main.async {
                    if self.sessionGeneration == gen {
                        self.isRunning = false
                        self.connectionStatus = "Port \(port) Busy — Tap Again"
                    }
                }
                return
            }

            let now = CFAbsoluteTimeGetCurrent()
            self.stateLock.lock()
            guard self.sessionGeneration == gen, self.isRunning else {
                self.stateLock.unlock()
                _ = Darwin.close(fd)
                return
            }
            self.socketFd = fd
            self.lastSequenceNumber = nil
            self.lastPacketTimestamp = now
            self.lastHandshakeTimestamp = now
            self.inflightBuffers = 0
            self.stateLock.unlock()

            // Send initial handshake ("AH<port>|<deviceName>")
            self.sendDatagram(fd: fd, payload: "AH\(port)|\(UIDevice.current.name)", toIp: cleanIp, port: port)

            // Ensure background keep-alive timer is running
            self.startBackgroundKeepAliveTimer(generation: gen, pcIpAddress: cleanIp, port: port)

            // Launch non-blocking receive loop on global concurrent high-priority queue
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                self?.receiveLoop(fd: fd, generation: gen)
            }
        }
    }

    func stop() {
        stateLock.lock()
        sessionGeneration &+= 1
        isRunning = false
        let oldFd = socketFd
        socketFd = -1
        let ip = activePcIp
        let port = activePcPort
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        inflightBuffers = 0
        stateLock.unlock()

        // Update UI immediately on main thread
        DispatchQueue.main.async {
            self.connectionStatus = "Ready to Connect"
            self.estimatedBufferMs = 0.0
            self.outputPeakLevel = 0.0
        }

        // Perform network & playerNode reset asynchronously so UI never blocks
        controlQueue.async { [weak self] in
            if oldFd >= 0 {
                if !ip.isEmpty {
                    // Notify Windows 11 PC immediately so it restores PC speakers right away
                    self?.sendDatagram(fd: oldFd, payload: "AH_STOP", toIp: ip, port: port)
                }
                _ = Darwin.shutdown(oldFd, SHUT_RDWR)
                _ = Darwin.close(oldFd)
            }

            guard let self = self else { return }
            self.audioLock.lock()
            if self.audioEngine.isRunning {
                self.playerNode.reset()
            }
            self.audioLock.unlock()
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

    private func startBackgroundKeepAliveTimer(generation: UInt64, pcIpAddress: String, port: UInt16) {
        stateLock.lock()
        keepAliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        keepAliveTimer = timer
        stateLock.unlock()

        timer.schedule(deadline: .now() + .milliseconds(40), repeating: .milliseconds(40))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            self.stateLock.lock()
            let valid = self.isRunning && self.sessionGeneration == generation
            let fd = self.socketFd
            let lastPkt = self.lastPacketTimestamp
            let lastHs = self.lastHandshakeTimestamp
            let currentInflight = self.inflightBuffers
            self.stateLock.unlock()

            guard valid, fd >= 0 else { return }

            let now = CFAbsoluteTimeGetCurrent()
            let silenceElapsed = now - lastPkt

            // If no UDP packets arrived in the last 250ms, schedule a silent 10ms buffer
            // so iOS never suspends the background audio session when the screen is locked.
            if silenceElapsed > 0.250 && currentInflight < 2 {
                if let silence = self.decoder.makeSilenceBuffer(frameCount: 480) {
                    self.enqueuePcmBuffer(silence, generation: generation)
                }
            }

            // Re-send handshake at most once every 2.0 seconds when no audio is flowing
            if silenceElapsed > 2.0 && (now - lastHs) >= 2.0 {
                self.stateLock.lock()
                self.lastHandshakeTimestamp = now
                self.stateLock.unlock()
                self.sendDatagram(fd: fd, payload: "AH\(port)|\(UIDevice.current.name)", toIp: pcIpAddress, port: port)
            }
        }
        timer.resume()
    }

    private func receiveLoop(fd: Int32, generation: UInt64) {
        var packetBuf = [UInt8](repeating: 0, count: 4096)
        var localPacketsReceived: UInt64 = 0
        var localPacketsDropped: UInt64 = 0

        while true {
            stateLock.lock()
            let active = isRunning && sessionGeneration == generation && socketFd == fd
            stateLock.unlock()
            if !active { break }

            let bytesRead = recv(fd, &packetBuf, packetBuf.count, 0)
            if bytesRead <= 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                    continue
                }
                break
            }

            let now = CFAbsoluteTimeGetCurrent()

            // 1. Check for Handshake ACK ("AH_ACK|PC_NAME")
            if bytesRead >= 6 && packetBuf[0] == 0x41 && packetBuf[1] == 0x48 {
                if let text = String(bytes: packetBuf[0..<bytesRead], encoding: .utf8),
                   text.hasPrefix("AH_ACK|") {
                    let pcName = text.replacingOccurrences(of: "AH_ACK|", with: "")
                    stateLock.lock()
                    self.lastPacketTimestamp = now
                    self.pairedPcName = pcName
                    let alreadyStreaming = localPacketsReceived > 0
                    stateLock.unlock()

                    DispatchQueue.main.async {
                        guard self.sessionGeneration == generation, self.isRunning else { return }
                        self.connectionStatus = alreadyStreaming
                            ? "Streaming • \(pcName)"
                            : "Connected • \(pcName)"
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
            self.lastPacketTimestamp = now
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

            // Adaptive jitter protection
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
                enqueuePcmBuffer(validBuffer, generation: generation)

                localPacketsReceived &+= 1
                if droppedThisStep > 0 {
                    localPacketsDropped &+= droppedThisStep
                }

                // Update UI every 8 packets (~80ms) with unified status ("Streaming • <PC>")
                if localPacketsReceived % 8 == 1 {
                    var peak: Float = 0.0
                    if !isSilentKeepAlive, let ch = validBuffer.floatChannelData?[0] {
                        let n = Int(min(validBuffer.frameLength, 240))
                        for i in stride(from: 0, to: n, by: 4) {
                            let a = abs(ch[i])
                            if a > peak { peak = a }
                        }
                    }
                    let codecLabel = isOpus ? "Opus 48kHz" : "PCM 48kHz"
                    let bufferedMs = Double(currentQueued) * frameMs
                    let totalRecvSnapshot = localPacketsReceived
                    let totalDropSnapshot = localPacketsDropped

                    DispatchQueue.main.async {
                        guard self.sessionGeneration == generation, self.isRunning else { return }
                        self.connectionStatus = "Streaming • \(pcName)"
                        self.activeCodecName = codecLabel
                        self.estimatedBufferMs = bufferedMs
                        self.packetsReceived = totalRecvSnapshot
                        self.packetsDropped = totalDropSnapshot
                        self.outputPeakLevel = min(1.0, peak)
                    }
                }
            }
        }
    }

    private func enqueuePcmBuffer(_ buffer: AVAudioPCMBuffer, generation: UInt64) {
        stateLock.lock()
        guard isRunning, sessionGeneration == generation else {
            stateLock.unlock()
            return
        }
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
                if self.sessionGeneration == generation {
                    self.inflightBuffers = max(0, self.inflightBuffers - 1)
                }
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
