import Foundation
import AVFoundation
import UIKit
import Darwin

/// Ultra-low-jitter UDP audio receiver using a Lock-Free Circular Ring Buffer and
/// CoreAudio's real-time `AVAudioSourceNode` render callback.
/// Eliminates per-packet heap allocations, `scheduleBuffer` completion queue delays when
/// switching iOS apps (e.g. opening Settings), and periodic clock-drift skips.
final class UdpAudioEngineReceiver: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var connectionStatus: String = "Ready to Connect"
    @Published private(set) var activeCodecName: String = "PCM 48kHz"
    @Published private(set) var packetsReceived: UInt64 = 0
    @Published private(set) var packetsDropped: UInt64 = 0
    @Published private(set) var estimatedBufferMs: Double = 0.0
    @Published private(set) var outputPeakLevel: Float = 0.0

    @Published var volumeGain: Float = 1.0
    @Published var targetBufferMs: Double = 45.0 // 45ms default cushion prevents Wi-Fi & app-switch stutters

    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private let decoder = OpusAndPcmDecoder()

    // Lock-free power-of-two stereo ring buffer (65,536 frames = ~1.36s @ 48kHz)
    private let ringCapacity: Int = 65536
    private let ringMask: Int = 65535
    private let ringLeft: UnsafeMutablePointer<Float>
    private let ringRight: UnsafeMutablePointer<Float>
    private var writeIndex: Int64 = 0
    private var readIndex: Int64 = 0
    private var isPrimed: Bool = false
    private var lastSampleL: Float = 0.0
    private var lastSampleR: Float = 0.0
    private var driftStepCounter: Int = 0

    private let stateLock = NSLock()
    private let audioLock = NSLock()

    private var persistentSocketFd: Int32 = -1
    private var boundPort: UInt16 = 49152
    private var sessionGeneration: UInt64 = 0
    private var keepAliveTimer: DispatchSourceTimer?
    private var isDestroyed = false

    private var lastSequenceNumber: UInt16?
    private var lastAudioPacketTime: TimeInterval = 0
    private var lastHandshakeSentTime: TimeInterval = 0
    private var pairedPcName: String = "Windows 11 PC"
    private var activePcIp: String = UserDefaults.standard.string(forKey: "lastPcIpAddress") ?? "192.168.102.5"
    private var activePcPort: UInt16 = 49152

    init() {
        ringLeft = UnsafeMutablePointer<Float>.allocate(capacity: ringCapacity)
        ringRight = UnsafeMutablePointer<Float>.allocate(capacity: ringCapacity)
        ringLeft.initialize(repeating: 0.0, count: ringCapacity)
        ringRight.initialize(repeating: 0.0, count: ringCapacity)

        setupRealTimeAudioEngine()
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
        ringLeft.deallocate()
        ringRight.deallocate()
    }

    // MARK: - Lock Screen / Notification Center / Dynamic Island Remote Controls

    private func bindRemoteMediaCommands() {
        AudioSessionManager.shared.onRemotePlayRequested = { [weak self] in
            self?.resumeFromRemote()
        }
        AudioSessionManager.shared.onRemotePauseRequested = { [weak self] in
            self?.stop()
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

    // MARK: - CoreAudio Real-Time AVAudioSourceNode Setup

    private func setupRealTimeAudioEngine() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2)!

        sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let count = Int(frameCount)
            guard abl.count >= 2,
                  let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let outR = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }

            if !self.isRunning {
                for i in 0..<count {
                    outL[i] = 0.0
                    outR[i] = 0.0
                }
                return noErr
            }

            let wIdx = self.writeIndex
            var rIdx = self.readIndex
            var available = Int(wIdx - rIdx)

            let targetFrames = max(1920, Int(self.targetBufferMs * 48.0)) // At least 40ms pre-buffer cushion

            // Wait until pre-buffer cushion is filled before starting playback
            if !self.isPrimed {
                if available >= targetFrames {
                    self.isPrimed = true
                } else {
                    for i in 0..<count {
                        outL[i] = 0.0
                        outR[i] = 0.0
                    }
                    return noErr
                }
            }

            // If extreme buildup (> 400ms), snap to target cushion
            if available > 19200 {
                rIdx = wIdx - Int64(targetFrames)
                self.readIndex = rIdx
                available = targetFrames
            }

            // If underrun occurs, smoothly fade last sample to zero over 32 samples and re-prime
            if available < count {
                for i in 0..<count {
                    if i < available {
                        let maskIdx = Int(rIdx) & self.ringMask
                        let sL = self.ringLeft[maskIdx]
                        let sR = self.ringRight[maskIdx]
                        outL[i] = sL
                        outR[i] = sR
                        self.lastSampleL = sL
                        self.lastSampleR = sR
                        rIdx &+= 1
                    } else {
                        let fade = max(0.0, 1.0 - Float(i - available) / 32.0)
                        outL[i] = self.lastSampleL * fade
                        outR[i] = self.lastSampleR * fade
                    }
                }
                self.readIndex = rIdx
                self.isPrimed = false
                return noErr
            }

            // Smooth fractional clock-drift catch-up (no sudden 10ms packet drops!)
            // If buffer exceeds targetFrames + 35ms (1680 frames), smoothly advance 1 extra frame every 192 samples (~0.5% pitch-imperceptible)
            let shouldSlip = available > (targetFrames + 1680)
            let gain = self.volumeGain

            for i in 0..<count {
                let maskIdx = Int(rIdx) & self.ringMask
                var sL = self.ringLeft[maskIdx]
                var sR = self.ringRight[maskIdx]

                if shouldSlip {
                    self.driftStepCounter &+= 1
                    if self.driftStepCounter >= 192 && (wIdx - rIdx) > Int64(count + 2) {
                        self.driftStepCounter = 0
                        let nextIdx = Int(rIdx &+ 1) & self.ringMask
                        sL = 0.5 * (sL + self.ringLeft[nextIdx])
                        sR = 0.5 * (sR + self.ringRight[nextIdx])
                        rIdx &+= 1
                    }
                }

                outL[i] = max(-1.0, min(1.0, sL * gain))
                outR[i] = max(-1.0, min(1.0, sR * gain))
                rIdx &+= 1
            }

            self.lastSampleL = outL[count - 1]
            self.lastSampleR = outR[count - 1]
            self.readIndex = rIdx
            return noErr
        }

        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: format)
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
    }

    // MARK: - Persistent UDP Socket with High-Priority Receive Thread

    private func setupPersistentSocket(port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var rcvBufSize: Int32 = 524288 // 512 KB kernel UDP receive buffer
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

        // Dedicated high-priority Thread so GCD thread-pool starvation during app switches never delays UDP reads
        let thread = Thread { [weak self] in
            pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
            self?.persistentReceiveLoop(fd: fd)
        }
        thread.name = "AirPulse.UdpRealtimeReceiveThread"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: - Instant Start & Stop

    func start(pcIpAddress: String, port: UInt16 = 49152) {
        let cleanIp = pcIpAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanIp.isEmpty else { return }

        ensureEngineRunning()

        let now = CFAbsoluteTimeGetCurrent()
        stateLock.lock()
        sessionGeneration &+= 1
        let gen = sessionGeneration
        isPrimed = false
        readIndex = writeIndex
        isRunning = true
        activePcIp = cleanIp
        activePcPort = port
        lastSequenceNumber = nil
        lastAudioPacketTime = 0
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
        isPrimed = false
        readIndex = writeIndex
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

    // MARK: - Automatic Re-Handshake Heartbeat

    private func startPersistentHeartbeatTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(200), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self = self, !self.isDestroyed else { return }

            self.ensureEngineRunning()

            let now = CFAbsoluteTimeGetCurrent()
            self.stateLock.lock()
            let active = self.isRunning
            let fd = self.persistentSocketFd
            let ip = self.activePcIp
            let port = self.activePcPort
            let lastAudio = self.lastAudioPacketTime
            let lastHs = self.lastHandshakeSentTime
            self.stateLock.unlock()

            let silenceElapsed = now - lastAudio

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

    // MARK: - Zero-Allocation Persistent UDP Receive Loop

    private func persistentReceiveLoop(fd: Int32) {
        var packetBuf = [UInt8](repeating: 0, count: 4096)
        let normScale: Float = 1.0 / 32768.0

        while !isDestroyed {
            let bytesRead = recv(fd, &packetBuf, packetBuf.count, 0)
            if bytesRead <= 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                    continue
                }
                if isDestroyed { break }
                usleep(5_000)
                continue
            }

            stateLock.lock()
            let active = isRunning
            let gen = sessionGeneration
            stateLock.unlock()

            if !active {
                continue
            }

            let now = CFAbsoluteTimeGetCurrent()

            // 1. Handshake ACK ("AH_ACK|PC_NAME")
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
            let pcName = self.pairedPcName
            stateLock.unlock()

            let isOpus = (codecByte & 0x02) != 0
            let isSilentKeepAlive = (flags & 0x04) != 0
            var peak: Float = 0.0
            var framesWritten: Int = 0

            if isSilentKeepAlive {
                framesWritten = 480
                var w = self.writeIndex
                for _ in 0..<480 {
                    let idx = Int(w) & self.ringMask
                    self.ringLeft[idx] = 0.0
                    self.ringRight[idx] = 0.0
                    w &+= 1
                }
                self.writeIndex = w
            } else if !isOpus {
                // Fast zero-allocation PCM16 stereo decode directly into lock-free ring buffer
                let totalShorts = payloadLen / 2
                let frameCount = totalShorts / 2
                framesWritten = frameCount
                var w = self.writeIndex

                packetBuf.withUnsafeBytes { rawBytes in
                    guard let baseAddr = rawBytes.baseAddress else { return }
                    let shortPtr = (baseAddr + 12).assumingMemoryBound(to: Int16.self)
                    for f in 0..<frameCount {
                        let sL = Float(Int16(littleEndian: shortPtr[f * 2])) * normScale
                        let sR = Float(Int16(littleEndian: shortPtr[f * 2 + 1])) * normScale
                        let absL = abs(sL)
                        if absL > peak { peak = absL }

                        let idx = Int(w) & self.ringMask
                        self.ringLeft[idx] = sL
                        self.ringRight[idx] = sR
                        w &+= 1
                    }
                }
                self.writeIndex = w
            } else {
                // Opus fallback decode into ring buffer
                let payloadData = Data(packetBuf[12..<(12 + payloadLen)])
                if let validBuffer = decoder.decodeOpus(payload: payloadData, expectedFrames: 480, volumeGain: 1.0),
                   let ch0 = validBuffer.floatChannelData?[0],
                   let ch1 = validBuffer.floatChannelData?[1] {
                    let n = Int(validBuffer.frameLength)
                    framesWritten = n
                    var w = self.writeIndex
                    for f in 0..<n {
                        let sL = ch0[f]
                        let sR = ch1[f]
                        let absL = abs(sL)
                        if absL > peak { peak = absL }

                        let idx = Int(w) & self.ringMask
                        self.ringLeft[idx] = sL
                        self.ringRight[idx] = sR
                        w &+= 1
                    }
                    self.writeIndex = w
                }
            }

            if framesWritten > 0 {
                let bufferedFrames = max(0, Int(self.writeIndex - self.readIndex))
                let bufferedMs = Double(bufferedFrames) / 48.0

                DispatchQueue.main.async {
                    guard self.isRunning, self.sessionGeneration == gen else { return }
                    self.packetsReceived &+= 1
                    if droppedThisStep > 0 {
                        self.packetsDropped &+= droppedThisStep
                    }

                    // Throttle UI updates to every 10 packets (~100ms) to minimize main-thread CPU load
                    if self.packetsReceived % 10 == 1 {
                        let codecLabel = isOpus ? "Opus 48kHz" : "PCM 48kHz"
                        let statusText = "Streaming • \(pcName)"
                        let statusChanged = self.connectionStatus != statusText

                        self.connectionStatus = statusText
                        self.activeCodecName = codecLabel
                        self.estimatedBufferMs = bufferedMs
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
}
