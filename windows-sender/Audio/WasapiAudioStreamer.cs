using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Concentus;
using Concentus.Enums;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using PcAudioStreamer.Protocol;

namespace PcAudioStreamer.Audio;

public sealed record AudioDeviceItem(string Id, string FriendlyName, bool IsDefault)
{
    public override string ToString() => IsDefault ? $"{FriendlyName} (Default)" : FriendlyName;
}

public sealed class WasapiAudioStreamer : IDisposable
{
    private static readonly Guid IeeeFloatSubtype = new("00000003-0000-0010-8000-00aa00389b71");

    private WasapiLoopbackCapture? _capture;
    private UdpClient? _udpSocket;
    private IPEndPoint? _targetEndpoint;
    private IOpusEncoder? _opusEncoder;
    private CancellationTokenSource? _cts;

    private ushort _sequenceNumber;
    private uint _sampleTimestamp;
    private long _lastPacketTick;
    private long _totalPacketsSent;
    private long _totalBytesSent;

    // Ring buffer for accumulating exact frame samples (e.g. 240 samples per channel for 5ms @ 48kHz)
    private short[] _sampleAccumBuffer = Array.Empty<short>();
    private int _sampleAccumCount;
    private readonly object _encodeLock = new();

    public bool IsStreaming { get; private set; }
    public bool UseOpusCodec { get; set; } = true;
    public int FrameDurationMs { get; set; } = 5; // 5ms = 240 samples/ch @ 48kHz
    public int OpusBitrateBps { get; set; } = 192000;
    public float VolumeGain { get; set; } = 1.0f;

    public float CurrentPeakLevel { get; private set; }
    public string ConnectedClientInfo { get; private set; } = "Waiting for iPhone connection...";
    public long TotalPacketsSent => Interlocked.Read(ref _totalPacketsSent);
    public long TotalBytesSent => Interlocked.Read(ref _totalBytesSent);

    public event Action<string>? ClientConnected;
    public event Action<float>? PeakLevelUpdated;

    public static IReadOnlyList<AudioDeviceItem> GetPlaybackDevices()
    {
        var list = new List<AudioDeviceItem>();
        using var enumerator = new MMDeviceEnumerator();
        string? defaultId = null;
        try
        {
            using var def = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            defaultId = def?.ID;
        }
        catch
        {
            // No default render device
        }

        foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        {
            list.Add(new AudioDeviceItem(device.ID, device.FriendlyName, device.ID == defaultId));
        }

        return list;
    }

    public void SetManualTarget(string ipAddress, int port)
    {
        if (IPAddress.TryParse(ipAddress.Trim(), out var ip))
        {
            _targetEndpoint = new IPEndPoint(ip, port);
            ConnectedClientInfo = $"Target iPhone: {_targetEndpoint}";
            ClientConnected?.Invoke(ConnectedClientInfo);
        }
    }

    public void Start(string? deviceId, int listenPort, string? initialTargetIp, int targetPort)
    {
        if (IsStreaming)
            return;

        _cts = new CancellationTokenSource();
        _sequenceNumber = 0;
        _sampleTimestamp = 0;
        _totalPacketsSent = 0;
        _totalBytesSent = 0;

        // Initialize Opus Encoder (48kHz Stereo, Restricted Low-Delay mode for <10ms latency)
        _opusEncoder = OpusCodecFactory.CreateEncoder(AudioPacketProtocol.SampleRate, AudioPacketProtocol.Channels, OpusApplication.OPUS_APPLICATION_RESTRICTED_LOWDELAY);
        _opusEncoder.Bitrate = OpusBitrateBps;
        _opusEncoder.Complexity = 5;
        _opusEncoder.SignalType = OpusSignal.OPUS_SIGNAL_MUSIC;
        _opusEncoder.UseVBR = false; // Constant bitrate keeps UDP packet sizes predictable

        int samplesPerChannelPerFrame = (AudioPacketProtocol.SampleRate * FrameDurationMs) / 1000; // e.g., 240 for 5ms
        int interleavedSamplesPerFrame = samplesPerChannelPerFrame * AudioPacketProtocol.Channels; // 480 shorts
        _sampleAccumBuffer = new short[interleavedSamplesPerFrame * 8];
        _sampleAccumCount = 0;

        // Bind UDP socket on listenPort so iPhone can send handshake packets directly to this port
        _udpSocket = new UdpClient(listenPort);
        _udpSocket.Client.SendBufferSize = 65536;

        if (!string.IsNullOrWhiteSpace(initialTargetIp))
        {
            SetManualTarget(initialTargetIp, targetPort);
        }

        // Select WASAPI Render Device for Loopback Capture
        using var enumerator = new MMDeviceEnumerator();
        MMDevice? targetDevice = null;
        if (!string.IsNullOrWhiteSpace(deviceId))
        {
            try { targetDevice = enumerator.GetDevice(deviceId); } catch { }
        }
        targetDevice ??= enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);

        _capture = new WasapiLoopbackCapture(targetDevice);
        _capture.DataAvailable += OnWasapiDataAvailable;
        _capture.RecordingStopped += (_, _) => { IsStreaming = false; };

        _lastPacketTick = Environment.TickCount64;
        _capture.StartRecording();
        IsStreaming = true;

        // Start background listener for iPhone BLE/UDP Handshake ("AH")
        _ = Task.Run(() => ListenForIphoneHandshakeAsync(_cts.Token));

        // Start background keep-alive timer so iOS AVAudioSession never suspends during PC silence
        _ = Task.Run(() => KeepAliveSilenceLoopAsync(samplesPerChannelPerFrame, _cts.Token));
    }

    private async Task ListenForIphoneHandshakeAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested && _udpSocket != null)
        {
            try
            {
                var result = await _udpSocket.ReceiveAsync(token);
                var data = result.Buffer;
                if (data.Length >= 2 &&
                    data[0] == AudioPacketProtocol.HandshakeMagic0 &&
                    data[1] == AudioPacketProtocol.HandshakeMagic1)
                {
                    // Packet format: "AH" + optional iPhone UDP receive port or device name
                    int clientPort = result.RemoteEndPoint.Port;
                    string deviceLabel = "iPhone";
                    if (data.Length > 2)
                    {
                        var text = Encoding.UTF8.GetString(data, 2, data.Length - 2).Trim();
                        var parts = text.Split('|');
                        if (parts.Length >= 1 && int.TryParse(parts[0], out int parsedPort) && parsedPort > 0)
                        {
                            clientPort = parsedPort;
                        }
                        if (parts.Length >= 2 && !string.IsNullOrWhiteSpace(parts[1]))
                        {
                            deviceLabel = parts[1];
                        }
                    }

                    _targetEndpoint = new IPEndPoint(result.RemoteEndPoint.Address, clientPort);
                    ConnectedClientInfo = $"Connected: {deviceLabel} ({_targetEndpoint})";
                    ClientConnected?.Invoke(ConnectedClientInfo);

                    // Reply with ACK so iPhone knows handshake succeeded
                    var ack = Encoding.UTF8.GetBytes($"AH_ACK|{Environment.MachineName}");
                    await _udpSocket.SendAsync(ack, ack.Length, _targetEndpoint);
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch
            {
                // Ignore transient socket errors
            }
        }
    }

    private async Task KeepAliveSilenceLoopAsync(int samplesPerChannelPerFrame, CancellationToken token)
    {
        short[] silentPcm = new short[samplesPerChannelPerFrame * AudioPacketProtocol.Channels];

        while (!token.IsCancellationRequested)
        {
            await Task.Delay(20, token).ConfigureAwait(false);

            long elapsedMs = Environment.TickCount64 - Interlocked.Read(ref _lastPacketTick);
            if (elapsedMs >= 25 && _targetEndpoint != null)
            {
                CurrentPeakLevel = 0f;
                PeakLevelUpdated?.Invoke(0f);

                lock (_encodeLock)
                {
                    EncodeAndSendFrame(
                        silentPcm.AsSpan(),
                        samplesPerChannelPerFrame,
                        PacketFlags.HeartbeatKeepAlive | PacketFlags.SilentFrame
                    );
                }
            }
        }
    }

    private void OnWasapiDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded <= 0 || _capture == null)
            return;

        Interlocked.Exchange(ref _lastPacketTick, Environment.TickCount64);

        var format = _capture.WaveFormat;
        int samplesPerChannelPerFrame = (AudioPacketProtocol.SampleRate * FrameDurationMs) / 1000;
        int interleavedSamplesPerFrame = samplesPerChannelPerFrame * AudioPacketProtocol.Channels;

        // Convert incoming WASAPI buffer (typically 32-bit IEEE Float Stereo @ 48kHz) to 16-bit Stereo PCM @ 48kHz
        Span<short> convertedSamples = ConvertWasapiBufferToPcm16Stereo48k(e.Buffer, e.BytesRecorded, format, out float peak);
        CurrentPeakLevel = peak;
        PeakLevelUpdated?.Invoke(peak);

        if (_targetEndpoint == null || convertedSamples.IsEmpty)
            return;

        lock (_encodeLock)
        {
            int offset = 0;
            while (offset < convertedSamples.Length)
            {
                int needed = interleavedSamplesPerFrame - _sampleAccumCount;
                int available = convertedSamples.Length - offset;
                int toCopy = Math.Min(needed, available);

                convertedSamples.Slice(offset, toCopy).CopyTo(_sampleAccumBuffer.AsSpan(_sampleAccumCount, toCopy));
                _sampleAccumCount += toCopy;
                offset += toCopy;

                if (_sampleAccumCount == interleavedSamplesPerFrame)
                {
                    EncodeAndSendFrame(
                        _sampleAccumBuffer.AsSpan(0, interleavedSamplesPerFrame),
                        samplesPerChannelPerFrame,
                        PacketFlags.None
                    );
                    _sampleAccumCount = 0;
                }
            }
        }
    }

    private Span<short> ConvertWasapiBufferToPcm16Stereo48k(byte[] buffer, int bytesRecorded, WaveFormat format, out float maxPeak)
    {
        maxPeak = 0f;
        float gain = VolumeGain;
        int srcChannels = Math.Max(1, format.Channels);

        // Fast path for IEEE 32-bit float (default Windows 11 WASAPI format)
        if (format.Encoding == WaveFormatEncoding.IeeeFloat ||
            (format is WaveFormatExtensible ext && ext.SubFormat == IeeeFloatSubtype))
        {
            int totalFloats = bytesRecorded / 4;
            int srcFrames = totalFloats / srcChannels;
            if (srcFrames <= 0)
                return Span<short>.Empty;

            // Simple ratio resample if device isn't 48000 Hz (most Windows 11 devices are 48000 Hz)
            double rateRatio = (double)format.SampleRate / AudioPacketProtocol.SampleRate;
            int dstFrames = format.SampleRate == AudioPacketProtocol.SampleRate
                ? srcFrames
                : Math.Max(1, (int)(srcFrames / rateRatio));

            short[] output = new short[dstFrames * 2];

            for (int i = 0; i < dstFrames; i++)
            {
                int srcFrameIndex = format.SampleRate == AudioPacketProtocol.SampleRate
                    ? i
                    : Math.Min(srcFrames - 1, (int)(i * rateRatio));

                int byteIndex = srcFrameIndex * srcChannels * 4;
                float left = BitConverter.ToSingle(buffer, byteIndex);
                float right = srcChannels >= 2
                    ? BitConverter.ToSingle(buffer, byteIndex + 4)
                    : left;

                float absL = Math.Abs(left);
                float absR = Math.Abs(right);
                if (absL > maxPeak) maxPeak = absL;
                if (absR > maxPeak) maxPeak = absR;

                left = Math.Clamp(left * gain, -1.0f, 1.0f);
                right = Math.Clamp(right * gain, -1.0f, 1.0f);

                output[i * 2] = (short)(left * 32767f);
                output[i * 2 + 1] = (short)(right * 32767f);
            }

            return output.AsSpan();
        }

        // Fallback for 16-bit PCM WASAPI format
        if (format.BitsPerSample == 16)
        {
            int totalShorts = bytesRecorded / 2;
            int srcFrames = totalShorts / srcChannels;
            short[] output = new short[srcFrames * 2];

            for (int i = 0; i < srcFrames; i++)
            {
                int byteIndex = i * srcChannels * 2;
                short left = BitConverter.ToInt16(buffer, byteIndex);
                short right = srcChannels >= 2
                    ? BitConverter.ToInt16(buffer, byteIndex + 2)
                    : left;

                float normL = Math.Abs(left / 32768f);
                if (normL > maxPeak) maxPeak = normL;

                output[i * 2] = (short)Math.Clamp(left * gain, short.MinValue, short.MaxValue);
                output[i * 2 + 1] = (short)Math.Clamp(right * gain, short.MinValue, short.MaxValue);
            }

            return output.AsSpan();
        }

        return Span<short>.Empty;
    }

    private void EncodeAndSendFrame(Span<short> interleavedPcm, int samplesPerChannel, PacketFlags flags)
    {
        var endpoint = _targetEndpoint;
        var socket = _udpSocket;
        if (endpoint == null || socket == null)
            return;

        byte[] packetBuffer;
        int payloadLength;
        AudioCodecByte codecByte;

        if (UseOpusCodec && _opusEncoder != null)
        {
            // Max Opus frame size is 1275 bytes
            packetBuffer = new byte[AudioPacketProtocol.HeaderSize + 512];
            payloadLength = _opusEncoder.Encode(
                interleavedPcm,
                samplesPerChannel,
                packetBuffer.AsSpan(AudioPacketProtocol.HeaderSize, 512),
                512
            );
            codecByte = AudioCodecByte.Opus | AudioCodecByte.StereoFlag;
        }
        else
        {
            // Raw PCM 16-bit Little-Endian stereo
            payloadLength = interleavedPcm.Length * sizeof(short);
            packetBuffer = new byte[AudioPacketProtocol.HeaderSize + payloadLength];
            MemoryMarshal.AsBytes(interleavedPcm).CopyTo(packetBuffer.AsSpan(AudioPacketProtocol.HeaderSize, payloadLength));
            codecByte = AudioCodecByte.RawPcm16 | AudioCodecByte.StereoFlag;
        }

        var header = new AudioPacketHeader
        {
            SequenceNumber = _sequenceNumber++,
            Timestamp = _sampleTimestamp,
            CodecAndChannels = codecByte,
            PayloadLength = (ushort)payloadLength,
            Flags = flags
        };
        _sampleTimestamp += (uint)samplesPerChannel;

        header.WriteToSpan(packetBuffer.AsSpan(0, AudioPacketProtocol.HeaderSize));
        int totalPacketSize = AudioPacketProtocol.HeaderSize + payloadLength;

        try
        {
            socket.Send(packetBuffer, totalPacketSize, endpoint);
            Interlocked.Increment(ref _totalPacketsSent);
            Interlocked.Add(ref _totalBytesSent, totalPacketSize);
        }
        catch
        {
            // Ignore transient UDP send failures
        }
    }

    public void Stop()
    {
        if (!IsStreaming)
            return;

        IsStreaming = false;
        try { _cts?.Cancel(); } catch { }
        try { _capture?.StopRecording(); } catch { }
        try { _capture?.Dispose(); } catch { }
        try { _udpSocket?.Close(); } catch { }
        try { _udpSocket?.Dispose(); } catch { }

        _capture = null;
        _udpSocket = null;
        CurrentPeakLevel = 0f;
    }

    public void Dispose()
    {
        Stop();
    }
}
