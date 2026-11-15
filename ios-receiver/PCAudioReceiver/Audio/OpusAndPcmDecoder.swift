import Foundation
import AVFoundation
import AudioToolbox

/// Decodes incoming 12-byte header UDP payloads (either Raw PCM16 `0x01` or Opus `0x02`)
/// into native `AVAudioPCMBuffer` (48kHz, Float32 Non-Interleaved Stereo) ready for `AVAudioPlayerNode`.
final class OpusAndPcmDecoder {
    let audioFormat: AVAudioFormat
    private var audioConverter: AudioConverterRef?

    // Context used during AudioConverterFillComplexBuffer callback
    private final class OpusPacketContext {
        var dataPointer: UnsafeRawPointer
        var byteCount: UInt32
        var packetDescPtr: UnsafeMutablePointer<AudioStreamPacketDescription>
        var consumed: Bool = false

        init(dataPointer: UnsafeRawPointer, byteCount: UInt32, frameSamples: UInt32) {
            self.dataPointer = dataPointer
            self.byteCount = byteCount
            self.packetDescPtr = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
            self.packetDescPtr.initialize(to: AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: frameSamples,
                mDataByteSize: byteCount
            ))
        }

        deinit {
            packetDescPtr.deinitialize(count: 1)
            packetDescPtr.deallocate()
        }
    }

    init() {
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000.0,
            channels: 2,
            interleaved: false
        )!
        setupNativeOpusDecoder()
    }

    deinit {
        if let converter = audioConverter {
            AudioConverterDispose(converter)
        }
    }

    private func setupNativeOpusDecoder() {
        var inDesc = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 240, // 5ms @ 48kHz default (variable frames supported per packet)
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var outDesc = AudioStreamBasicDescription(
            mSampleRate: 48000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var converter: AudioConverterRef?
        let status = AudioConverterNew(&inDesc, &outDesc, &converter)
        if status == noErr {
            self.audioConverter = converter
        } else {
            print("[OpusAndPcmDecoder] AudioConverterNew status: \(status)")
        }
    }

    /// Creates a silent 5ms keep-alive buffer so iOS never suspends the background audio engine.
    func makeSilenceBuffer(frameCount: AVAudioFrameCount = 240) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        if let left = buffer.floatChannelData?[0], let right = buffer.floatChannelData?[1] {
            memset(left, 0, Int(frameCount) * MemoryLayout<Float>.size)
            memset(right, 0, Int(frameCount) * MemoryLayout<Float>.size)
        }
        return buffer
    }

    /// Decodes a raw PCM16 stereo payload (little-endian Int16 interleaved) into AVAudioPCMBuffer.
    func decodePcm16(payload: Data, volumeGain: Float) -> AVAudioPCMBuffer? {
        let totalShorts = payload.count / 2
        let frameCount = AVAudioFrameCount(totalShorts / 2)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount),
              let leftChannel = pcmBuffer.floatChannelData?[0],
              let rightChannel = pcmBuffer.floatChannelData?[1] else {
            return nil
        }

        pcmBuffer.frameLength = frameCount
        let scale: Float = (1.0 / 32768.0) * volumeGain

        payload.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else { return }
            let int16Ptr = baseAddress.assumingMemoryBound(to: Int16.self)
            for i in 0..<Int(frameCount) {
                let sampleL = Int16(littleEndian: int16Ptr[i * 2])
                let sampleR = Int16(littleEndian: int16Ptr[i * 2 + 1])
                leftChannel[i] = max(-1.0, min(1.0, Float(sampleL) * scale))
                rightChannel[i] = max(-1.0, min(1.0, Float(sampleR) * scale))
            }
        }

        return pcmBuffer
    }

    /// Decodes an Opus packet into AVAudioPCMBuffer using Apple's AudioConverter.
    func decodeOpus(payload: Data, expectedFrames: UInt32 = 480, volumeGain: Float) -> AVAudioPCMBuffer? {
        guard let converter = audioConverter, !payload.isEmpty else {
            return makeSilenceBuffer(frameCount: 240)
        }

        let maxFrames: UInt32 = max(expectedFrames, 960) // Up to 20ms @ 48kHz
        var decodedInt16 = [Int16](repeating: 0, count: Int(maxFrames * 2))

        var ioOutputDataPackets: UInt32 = maxFrames
        let status: OSStatus = payload.withUnsafeBytes { rawPayload in
            guard let baseAddr = rawPayload.baseAddress else { return -1 }
            let context = OpusPacketContext(
                dataPointer: baseAddr,
                byteCount: UInt32(payload.count),
                frameSamples: expectedFrames
            )
            let unmanagedCtx = Unmanaged.passUnretained(context)

            return decodedInt16.withUnsafeMutableBytes { outRawBytes in
                var outBufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2,
                        mDataByteSize: UInt32(outRawBytes.count),
                        mData: outRawBytes.baseAddress
                    )
                )

                let inputProc: AudioConverterComplexInputDataProc = { _, ioNumberDataPackets, ioData, outDataPacketDescription, inUserData in
                    guard let userData = inUserData else {
                        ioNumberDataPackets.pointee = 0
                        return -1
                    }
                    let ctx = Unmanaged<OpusPacketContext>.fromOpaque(userData).takeUnretainedValue()
                    if ctx.consumed {
                        ioNumberDataPackets.pointee = 0
                        return 100 // End of current packet
                    }

                    ctx.consumed = true
                    ioNumberDataPackets.pointee = 1
                    ioData.pointee.mNumberBuffers = 1
                    ioData.pointee.mBuffers.mNumberChannels = 2
                    ioData.pointee.mBuffers.mDataByteSize = ctx.byteCount
                    ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: ctx.dataPointer)

                    if let outDescPtr = outDataPacketDescription {
                        outDescPtr.pointee = ctx.packetDescPtr
                    }
                    return noErr
                }

                return AudioConverterFillComplexBuffer(
                    converter,
                    inputProc,
                    unmanagedCtx.toOpaque(),
                    &ioOutputDataPackets,
                    &outBufferList,
                    nil
                )
            }
        }

        if (status == noErr || status == 100) && ioOutputDataPackets > 0 {
            let pcmBytes = Data(bytes: decodedInt16, count: Int(ioOutputDataPackets) * 4)
            return decodePcm16(payload: pcmBytes, volumeGain: volumeGain)
        }

        return makeSilenceBuffer(frameCount: 240)
    }
}
