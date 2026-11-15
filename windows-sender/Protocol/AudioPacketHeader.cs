using System;
using System.Buffers.Binary;

namespace PcAudioStreamer.Protocol;

/// <summary>
/// Implements the 12-byte UDP Audio Packet Header defined in Section 5 of the specification:
/// [0..1]   Magic Header:    0x41 0x53 ("AS" - Audio Stream)
/// [2..3]   Sequence Number: uint16 rolling packet counter (big-endian / network byte order)
/// [4..7]   Timestamp:       uint32 sample timestamp (48kHz clock)
/// [8]      Codec & Channels:Bitmask (0x01 = Raw PCM16, 0x02 = Opus; bit 7 = Stereo(1)/Mono(0))
/// [9..10]  Payload Length:  uint16 length of audio frame in bytes
/// [11]     Flags:           Bitmask (0x01 = Heartbeat/Keep-alive, 0x02 = Volume Sync, 0x04 = Silence)
/// [12..]   Audio Payload:   Encoded Opus frame or raw PCM16 samples
/// </summary>
public static class AudioPacketProtocol
{
    public const int HeaderSize = 12;
    public const byte MagicByte0 = 0x41; // 'A'
    public const byte MagicByte1 = 0x53; // 'S'

    // Handshake magic ("AH" - Audio Handshake from iPhone to PC)
    public const byte HandshakeMagic0 = 0x41; // 'A'
    public const byte HandshakeMagic1 = 0x48; // 'H'

    public const int SampleRate = 48000;
    public const int Channels = 2;
    public const int DefaultUdpPort = 49152;

    // BLE Service UUID used for Auto-Discovery between Windows 11 and iOS
    public static readonly Guid BleServiceUuid = new("A1B2C3D4-E5F6-4789-ABCD-EF0123456789");
    public const ushort BleManufacturerCompanyId = 0xFFFF; // Custom development ID for local discovery
}

[Flags]
public enum AudioCodecByte : byte
{
    RawPcm16 = 0x01,
    Opus = 0x02,
    StereoFlag = 0x80
}

[Flags]
public enum PacketFlags : byte
{
    None = 0x00,
    HeartbeatKeepAlive = 0x01,
    VolumeSync = 0x02,
    SilentFrame = 0x04
}

public readonly struct AudioPacketHeader
{
    public ushort SequenceNumber { get; init; }
    public uint Timestamp { get; init; }
    public AudioCodecByte CodecAndChannels { get; init; }
    public ushort PayloadLength { get; init; }
    public PacketFlags Flags { get; init; }

    public void WriteToSpan(Span<byte> buffer)
    {
        if (buffer.Length < AudioPacketProtocol.HeaderSize)
            throw new ArgumentException("Buffer too small for 12-byte header.");

        buffer[0] = AudioPacketProtocol.MagicByte0;
        buffer[1] = AudioPacketProtocol.MagicByte1;
        BinaryPrimitives.WriteUInt16BigEndian(buffer.Slice(2, 2), SequenceNumber);
        BinaryPrimitives.WriteUInt32BigEndian(buffer.Slice(4, 4), Timestamp);
        buffer[8] = (byte)CodecAndChannels;
        BinaryPrimitives.WriteUInt16BigEndian(buffer.Slice(9, 2), PayloadLength);
        buffer[11] = (byte)Flags;
    }
}
