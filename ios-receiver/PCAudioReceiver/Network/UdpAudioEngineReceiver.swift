import Foundation
import AVFoundation
import UIKit
import Darwin

/// Receives real-time UDP audio packets ("AS" 12-byte header), decodes Opus/PCM16 frames,
/// manages an adaptive low-latency jitter buffer, and schedules audio continuously on
/// `AVAudioEngine` so iOS background execution remains active indefinitely.
final class UdpAudioEngineReceiver: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var connectionStatus: String = "Disconnected"
    @Published private(set) var activeCodecName: String = "Idle"
    @Published private(set) var packetsReceived: UInt64 = 0
    @Published private(set) var packetsDropped: UInt64 = 0
    @Published private(set) var estimatedBufferMs: Double = 0.0

    @Published var volumeGain: Float = 1.0
    @Published var targetBufferMs: Double = 35.0 // Configurable 5ms - 80ms jitter ceiling

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let decoder = OpusAndPcmDecoder()

    private var socketFd: Int32 = -1
    private var receiveQueue = DispatchQueue(label: "com.antigravity.pcaudiostreamer.udp", qos: .userInteractive)
    private var keepAliveTimer: DispatchSourceTimer?

    private var inflightBuffers: Int32 = 0
    private let bufferLock = NSLock()
    private var lastSequenceNumber: UInt16?
    private var lastPacketTimestamp: TimeInterval = 0

    init() {
        setupAudioEngine()
        AudioSessionManager.shared.onInterruptionEnded = { [weak self] in
            self?.ensureEngineRunning()
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
        guard isRunning else { return }
        if !audioEngine.isRunning {
            do {
                AudioSessionManager.shared.reconfigureSession()
                try audioEngine.start()
                playerNode.play()
            } catch {
                print("[UdpAudioEngineReceiver] Failed to restart AVAudioEngine: \(error)")
            }
        }
    }

    func start(pcIpAddress: String, port: UInt16 = 49152) {
        if isRunning {
            stop()
        }

        AudioSessionManager.shared.reconfigureSession()

        do {
            if !audioEngine.isRunning {
                try audioEngine.start()
            }
            playerNode.play()
        } catch {
            connectionStatus = "AudioEngine Error: \(error.localizedDescription)"
            return
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            connectionStatus = "Failed to create UDP socket"
            return
        }
        socketFd = fd

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var rcvBufSize: Int32 = 131072
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcvBufSize, socklen_t(MemoryLayout<Int32>.size))

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

        if bindRes != 0 {
            close(fd)
            socketFd = -1
            connectionStatus = "Failed to bind UDP port \(port)"
            return
        }

        isRunning = true
        packetsReceived = 0
        packetsDropped = 0
        lastSequenceNumber = nil
        lastPacketTimestamp = CFAbsoluteTimeGetCurrent()
        connectionStatus = "Connecting to \(pcIpAddress):\(port)..."

        // Send initial UDP Handshake ("AH|<port>|<deviceName>") so Windows 11 PC locks onto our IP
        sendHandshake(toIp: pcIpAddress, port: port)

        // Start continuous background keep-alive & handshake timer
        startBackgroundKeepAliveTimer(pcIpAddress: pcIpAddress, port: port)

        // Start high-priority UDP receive loop
        receiveQueue.async { [weak self] in
            self?.receiveLoop(fd: fd)
        }
    }

    func stop() {
        isRunning = false
        keepAliveTimer?.cancel()
        keepAliveTimer = nil

        if socketFd >= 0 {
            close(socketFd)
            socketFd = -1
        }

        playerNode.stop()
        audioEngine.stop()

        DispatchQueue.main.async {
            self.connectionStatus = "Disconnected"
            self.activeCodecName = "Idle"
            self.estimatedBufferMs = 0.0
        }
    }

    private func sendHandshake(toIp ip: String, port: UInt16) {
        guard socketFd >= 0, !ip.isEmpty else { return }
        let deviceName = UIDevice.current.name
        let payload = "AH\(port)|\(deviceName)"
        guard let data = payload.data(using: .utf8) else { return }

        var targetAddr = sockaddr_in()
        targetAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        targetAddr.sin_family = sa_family_t(AF_INET)
        targetAddr.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &targetAddr.sin_addr)

        data.withUnsafeBytes { rawBytes in
            guard let base = rawBytes.baseAddress else { return }
            withUnsafePointer(to: &targetAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                    _ = sendto(socketFd, base, data.count, 0, addrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func startBackgroundKeepAliveTimer(pcIpAddress: String, port: UInt16) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isRunning else { return }

            let now = CFAbsoluteTimeGetCurrent()
            let silenceElapsed = now - self.lastPacketTimestamp

            // If no UDP packets arrived in the last 250ms, schedule a silent 10ms buffer
            // so iOS never suspends the background audio session when the screen is locked.
            if silenceElapsed > 0.250 {
                self.scheduleSilentKeepAlive()
            }

            // Re-send handshake every ~1.5s if waiting for stream
            if silenceElapsed > 1.5 {
                self.sendHandshake(toIp: pcIpAddress, port: port)
            }
        }
        keepAliveTimer = timer
        timer.resume()
    }

    private func scheduleSilentKeepAlive() {
        bufferLock.lock()
        let currentInflight = inflightBuffers
        bufferLock.unlock()

        guard currentInflight < 2,
              let silence = decoder.makeSilenceBuffer(frameCount: 480) else {
            return
        }

        enqueuePcmBuffer(silence, frameMs: 10.0)
    }

    private func receiveLoop(fd: Int32) {
        var packetBuf = [UInt8](repeating: 0, count: 4096)

        while isRunning && socketFd == fd {
            let bytesRead = recv(fd, &packetBuf, packetBuf.count, 0)
            if bytesRead <= 0 {
                if !isRunning { break }
                continue
            }

            // Check for Handshake ACK ("AH_ACK|PC_NAME")
            if bytesRead >= 6 && packetBuf[0] == 0x41 && packetBuf[1] == 0x48 {
                if let text = String(bytes: packetBuf[0..<bytesRead], encoding: .utf8),
                   text.hasPrefix("AH_ACK|") {
                    let pcName = text.replacingOccurrences(of: "AH_ACK|", with: "")
                    DispatchQueue.main.async {
                        self.connectionStatus = "Paired with \(pcName)"
                    }
                }
                continue
            }

            // Validate 12-byte Audio Stream Header ("AS" = 0x41 0x53)
            guard bytesRead > 12,
                  packetBuf[0] == 0x41,
                  packetBuf[1] == 0x53 else {
                continue
            }

            lastPacketTimestamp = CFAbsoluteTimeGetCurrent()

            let seq = (UInt16(packetBuf[2]) << 8) | UInt16(packetBuf[3])
            let codecByte = packetBuf[8]
            let payloadLen = Int((UInt16(packetBuf[9]) << 8) | UInt16(packetBuf[10]))
            let flags = packetBuf[11]

            guard bytesRead >= 12 + payloadLen, payloadLen > 0 else {
                continue
            }

            // Sequence drop detection
            var droppedThisStep: UInt64 = 0
            if let prevSeq = lastSequenceNumber {
                let expected = prevSeq &+ 1
                if seq != expected {
                    let diff = seq &- expected
                    if diff < 1000 {
                        droppedThisStep = UInt64(diff)
                    }
                }
            }
            lastSequenceNumber = seq

            // Adaptive jitter protection: if queued audio exceeds targetBufferMs, drop oldest buildup
            let maxAllowedBuffers = max(5, Int(ceil(targetBufferMs / 8.0)))
            bufferLock.lock()
            let currentQueued = Int(inflightBuffers)
            bufferLock.unlock()

            if currentQueued > maxAllowedBuffers + 4 {
                // Skip scheduling this frame to snap latency back down to targetBufferMs
                continue
            }

            let payloadData = Data(packetBuf[12..<(12 + payloadLen)])
            let isOpus = (codecByte & 0x02) != 0
            let isSilentKeepAlive = (flags & 0x04) != 0

            let pcmBuffer: AVAudioPCMBuffer?
            if isSilentKeepAlive {
                pcmBuffer = decoder.makeSilenceBuffer(frameCount: 240)
            } else if isOpus {
                pcmBuffer = decoder.decodeOpus(payload: payloadData, expectedFrames: 240, volumeGain: volumeGain)
            } else {
                pcmBuffer = decoder.decodePcm16(payload: payloadData, volumeGain: volumeGain)
            }

            if let validBuffer = pcmBuffer {
                let frameMs = Double(validBuffer.frameLength) / 48.0
                enqueuePcmBuffer(validBuffer, frameMs: frameMs)

                let totalRecv = packetsReceived &+ 1
                packetsReceived = totalRecv
                if droppedThisStep > 0 {
                    packetsDropped &+= droppedThisStep
                }

                // Throttle UI telemetry updates to every 20 packets (~100ms)
                if totalRecv % 20 == 1 {
                    let codecLabel = isOpus ? "Opus 48kHz Stereo" : "Raw PCM16 48kHz Stereo"
                    let bufferedMs = Double(currentQueued) * frameMs
                    DispatchQueue.main.async {
                        self.connectionStatus = "Streaming Live Audio"
                        self.activeCodecName = codecLabel
                        self.estimatedBufferMs = bufferedMs
                    }
                }
            }
        }
    }

    private func enqueuePcmBuffer(_ buffer: AVAudioPCMBuffer, frameMs: Double) {
        bufferLock.lock()
        inflightBuffers += 1
        bufferLock.unlock()

        if !playerNode.isPlaying {
            playerNode.play()
        }

        playerNode.scheduleBuffer(buffer) { [weak self] in
            guard let self = self else { return }
            self.bufferLock.lock()
            self.inflightBuffers = max(0, self.inflightBuffers - 1)
            self.bufferLock.unlock()
        }
    }
}
