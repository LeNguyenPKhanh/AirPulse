using System;
using System.Collections.Generic;
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
    public const string AutoDefaultId = "__AUTO_DEFAULT__";
    public override string ToString() => Id == AutoDefaultId
        ? $"⚡ {FriendlyName}"
        : (IsDefault ? $"{FriendlyName} (Current Default)" : FriendlyName);
}

/// <summary>
/// Custom low-latency WASAPI Loopback capture using a 10ms buffer instead of NAudio's default 100ms buffer
/// (which caused 62ms gaps between callbacks and triggered the iPhone's 30ms silence keep-alive timer!).
/// </summary>
public sealed class LowLatencyLoopbackCapture : WasapiCapture
{
    public LowLatencyLoopbackCapture(MMDevice captureDevice)
        : base(captureDevice, useEventSync: false, audioBufferMillisecondsLength: 10)
    {
    }

    protected override AudioClientStreamFlags GetAudioClientStreamFlags()
    {
        return AudioClientStreamFlags.Loopback | base.GetAudioClientStreamFlags();
    }
}

public sealed class WasapiAudioStreamer : IDisposable
{
    [DllImport("winmm.dll", EntryPoint = "timeBeginPeriod")]
    private static extern uint TimeBeginPeriod(uint uMilliseconds);

    [DllImport("winmm.dll", EntryPoint = "timeEndPeriod")]
    private static extern uint TimeEndPeriod(uint uMilliseconds);

    private static readonly Guid IeeeFloatSubtype = new("00000003-0000-0010-8000-00aa00389b71");

    // 480 stereo samples @ 48kHz = 10.0ms per UDP packet
    private const int SamplesPerChannelPerPacket = 480;
    private const int InterleavedShortsPerPacket = SamplesPerChannelPerPacket * AudioPacketProtocol.Channels; // 960 shorts = 1920 bytes

    private LowLatencyLoopbackCapture? _capture;
    private MMDevice? _activeDevice;
    private string? _requestedDeviceId;
    private string? _activeDeviceId;
    private bool _weMutedActiveDevice;
    private bool _needsPrebufferCushion = true;

    private UdpClient? _udpSocket;
    private IPEndPoint? _targetEndpoint;
    private IOpusEncoder? _opusEncoder;
    private CancellationTokenSource? _cts;

    private ushort _sequenceNumber;
    private uint _sampleTimestamp;
    private long _lastAudioSendTick;
    private long _totalPacketsSent;
    private long _totalBytesSent;

    // Continuous resampler state across WASAPI buffer boundaries (eliminates boundary clicks on 44.1kHz devices)
    private double _resamplePhase;
    private float _prevLeftSample;
    private float _prevRightSample;
    private bool _hasPrevSample;

    // Frame accumulator for exact 480-sample (10ms) packets
    private readonly short[] _accumBuffer = new short[InterleavedShortsPerPacket * 16];
    private int _accumCount;
    private readonly object _captureLock = new();

    private bool _mutePcSpeaker = true;

    public bool IsStreaming { get; private set; }
    public bool UseOpusCodec { get; set; } = false; // Raw PCM 16-bit by default for 100% distortion-free audio
    public int FrameDurationMs { get; set; } = 10;
    public int OpusBitrateBps { get; set; } = 192000;
    public float VolumeGain { get; set; } = 1.0f;

    public bool MutePcSpeaker
    {
        get => _mutePcSpeaker;
        set
        {
            _mutePcSpeaker = value;
            ApplyPcSpeakerMuteState();
        }
    }

    public float CurrentPeakLevel { get; private set; }
    public string ConnectedClientInfo { get; private set; } = "Waiting for iPhone connection...";
    public long TotalPacketsSent => Interlocked.Read(ref _totalPacketsSent);
    public long TotalBytesSent => Interlocked.Read(ref _totalBytesSent);

    public event Action<string>? ClientConnected;
    public event Action<float>? PeakLevelUpdated;

    public static IReadOnlyList<AudioDeviceItem> GetPlaybackDevices()
    {
        var list = new List<AudioDeviceItem>
        {
            new(AudioDeviceItem.AutoDefaultId, "Auto (Follow Windows Default Speaker)", false)
        };

        using var enumerator = new MMDeviceEnumerator();
        string? defaultId = null;
        try
        {
            using var def = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            defaultId = def?.ID;
        }
        catch
        {
            // Ignore if no default device
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
            _needsPrebufferCushion = true;
            ConnectedClientInfo = $"Target iPhone: {_targetEndpoint}";
            ClientConnected?.Invoke(ConnectedClientInfo);
            ApplyPcSpeakerMuteState();
        }
    }

    /// <summary>
    /// Allows switching the captured Windows playback device live without stopping the UDP session.
    /// </summary>
    public void SwitchCaptureDevice(string? deviceId)
    {
        _requestedDeviceId = deviceId;
        if (IsStreaming)
        {
            RestartWasapiCaptureInternal();
        }
    }

    public void Start(string? deviceId, int listenPort, string? initialTargetIp, int targetPort)
    {
        if (IsStreaming)
            return;

        TimeBeginPeriod(1);

        _requestedDeviceId = deviceId;
        _cts = new CancellationTokenSource();
        _sequenceNumber = 0;
        _sampleTimestamp = 0;
        _totalPacketsSent = 0;
        _totalBytesSent = 0;

        _opusEncoder = OpusCodecFactory.CreateEncoder(
            AudioPacketProtocol.SampleRate,
            AudioPacketProtocol.Channels,
            OpusApplication.OPUS_APPLICATION_RESTRICTED_LOWDELAY
        );
        _opusEncoder.Bitrate = OpusBitrateBps;
        _opusEncoder.Complexity = 5;
        _opusEncoder.SignalType = OpusSignal.OPUS_SIGNAL_MUSIC;
        _opusEncoder.UseVBR = false;

        _udpSocket = new UdpClient();
        _udpSocket.Client.ExclusiveAddressUse = false;
        _udpSocket.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        _udpSocket.Client.Bind(new IPEndPoint(IPAddress.Any, listenPort));
        _udpSocket.Client.SendBufferSize = 131072;

        if (!string.IsNullOrWhiteSpace(initialTargetIp))
        {
            SetManualTarget(initialTargetIp, targetPort);
        }

        IsStreaming = true;
        RestartWasapiCaptureInternal();

        // 1. Listen for iPhone UDP Handshake ("AH")
        _ = Task.Run(() => ListenForIphoneHandshakeAsync(_cts.Token));

        // 2. Monitor default audio device changes & send gentle keep-alive when PC is completely silent
        _ = Task.Run(() => DeviceWatchdogAndKeepAliveLoopAsync(_cts.Token));
    }

    private void RestartWasapiCaptureInternal()
    {
        lock (_captureLock)
        {
            RestorePcSpeakerMuteState();

            try { _capture?.StopRecording(); } catch { }
            try { _capture?.Dispose(); } catch { }
            _capture = null;

            _accumCount = 0;
            _resamplePhase = 0.0;
            _hasPrevSample = false;

            var enumerator = new MMDeviceEnumerator();
            MMDevice? targetDevice = null;

            if (!string.IsNullOrWhiteSpace(_requestedDeviceId) &&
                _requestedDeviceId != AudioDeviceItem.AutoDefaultId)
            {
                try { targetDevice = enumerator.GetDevice(_requestedDeviceId); } catch { }
            }

            targetDevice ??= enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            _activeDevice = targetDevice;
            _activeDeviceId = targetDevice.ID;

            _capture = new LowLatencyLoopbackCapture(targetDevice);
            _capture.DataAvailable += OnWasapiDataAvailable;
            _lastAudioSendTick = Environment.TickCount64;
            _capture.StartRecording();

            ApplyPcSpeakerMuteState();
        }
    }

    private void ApplyPcSpeakerMuteState()
    {
        if (_activeDevice == null)
            return;

        try
        {
            bool shouldMute = IsStreaming && _mutePcSpeaker && _targetEndpoint != null;
            if (shouldMute)
            {
                if (!_activeDevice.AudioEndpointVolume.Mute)
                {
                    _activeDevice.AudioEndpointVolume.Mute = true;
                    _weMutedActiveDevice = true;
                }
            }
            else
            {
                RestorePcSpeakerMuteState();
            }
        }
        catch
        {
            // Ignore volume API errors
        }
    }

    private void RestorePcSpeakerMuteState()
    {
        if (_activeDevice == null)
            return;

        try
        {
            if (_weMutedActiveDevice)
            {
                _activeDevice.AudioEndpointVolume.Mute = false;
                _weMutedActiveDevice = false;
            }
        }
        catch
        {
            // Ignore shutdown errors
        }
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
                    _needsPrebufferCushion = true;
                    ConnectedClientInfo = $"Connected: {deviceLabel} ({_targetEndpoint})";
                    ClientConnected?.Invoke(ConnectedClientInfo);

                    ApplyPcSpeakerMuteState();

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

    private async Task DeviceWatchdogAndKeepAliveLoopAsync(CancellationToken token)
    {
        short[] silentPcm = new short[InterleavedShortsPerPacket];
        int tickCounter = 0;

        while (!token.IsCancellationRequested && IsStreaming)
        {
            await Task.Delay(50, token).ConfigureAwait(false);
            tickCounter++;

            // 1. Every ~500ms, if in Auto mode, check if the user switched Windows Default Output Device
            if (tickCounter % 10 == 0 &&
                (string.IsNullOrWhiteSpace(_requestedDeviceId) || _requestedDeviceId == AudioDeviceItem.AutoDefaultId))
            {
                try
                {
                    using var enumerator = new MMDeviceEnumerator();
                    using var currentDefault = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                    if (currentDefault != null && currentDefault.ID != _activeDeviceId)
                    {
                        RestartWasapiCaptureInternal();
                    }
                }
                catch
                {
                    // Ignore transient device enumeration errors
                }
            }

            // 2. Send a keep-alive frame every 25ms when PC has no audio so iPhone queue stays primed and never underruns
            long elapsedSinceAudio = Environment.TickCount64 - Interlocked.Read(ref _lastAudioSendTick);
            if (elapsedSinceAudio >= 150 && _targetEndpoint != null)
            {
                CurrentPeakLevel = 0f;
                PeakLevelUpdated?.Invoke(0f);
                _needsPrebufferCushion = true;
                Interlocked.Exchange(ref _lastAudioSendTick, Environment.TickCount64);

                lock (_captureLock)
                {
                    EncodeAndSendFrame(
                        silentPcm.AsSpan(),
                        SamplesPerChannelPerPacket,
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

        Interlocked.Exchange(ref _lastAudioSendTick, Environment.TickCount64);

        lock (_captureLock)
        {
            if (_capture == null)
                return;

            var format = _capture.WaveFormat;
            Span<short> converted = ConvertWasapiBufferToPcm16Stereo48k(e.Buffer, e.BytesRecorded, format, out float peak);
            CurrentPeakLevel = peak;
            PeakLevelUpdated?.Invoke(peak);

            if (_targetEndpoint == null || converted.IsEmpty)
                return;

            // Append converted samples to accumulator
            int spaceLeft = _accumBuffer.Length - _accumCount;
            int toCopy = Math.Min(spaceLeft, converted.Length);
            converted.Slice(0, toCopy).CopyTo(_accumBuffer.AsSpan(_accumCount, toCopy));
            _accumCount += toCopy;

            // Send complete 10ms (480-sample) packets
            int packetsSentInBurst = 0;
            while (_accumCount >= InterleavedShortsPerPacket)
            {
                if (_needsPrebufferCushion)
                {
                    _needsPrebufferCushion = false;
                    // Prime the iPhone AVAudioPlayerNode queue with 3 silent 10ms cushion buffers (30ms ahead of playhead)
                    // so Packet N+1 always arrives over Wi-Fi BEFORE Packet N finishes playing!
                    Span<short> cushion = stackalloc short[InterleavedShortsPerPacket];
                    cushion.Clear();
                    for (int c = 0; c < 3; c++)
                    {
                        EncodeAndSendFrame(cushion, SamplesPerChannelPerPacket, PacketFlags.None);
                    }
                }

                if (packetsSentInBurst > 0)
                {
                    // Gentle 2ms spacing when a callback delivers >1 packet
                    Thread.Sleep(2);
                }

                EncodeAndSendFrame(
                    _accumBuffer.AsSpan(0, InterleavedShortsPerPacket),
                    SamplesPerChannelPerPacket,
                    PacketFlags.None
                );
                packetsSentInBurst++;

                int remaining = _accumCount - InterleavedShortsPerPacket;
                if (remaining > 0)
                {
                    _accumBuffer.AsSpan(InterleavedShortsPerPacket, remaining).CopyTo(_accumBuffer.AsSpan(0, remaining));
                }
                _accumCount = remaining;
            }
        }
    }

    private Span<short> ConvertWasapiBufferToPcm16Stereo48k(byte[] buffer, int bytesRecorded, WaveFormat format, out float maxPeak)
    {
        maxPeak = 0f;
        float gain = VolumeGain;
        int srcChannels = Math.Max(1, format.Channels);

        if (format.Encoding == WaveFormatEncoding.IeeeFloat ||
            (format is WaveFormatExtensible ext && ext.SubFormat == IeeeFloatSubtype))
        {
            int totalFloats = bytesRecorded / 4;
            int srcFrames = totalFloats / srcChannels;
            if (srcFrames <= 0)
                return Span<short>.Empty;

            // Fast 1:1 path for 48,000 Hz (e.g. Realtek(R) Audio) — ZERO resampling needed!
            if (format.SampleRate == AudioPacketProtocol.SampleRate)
            {
                short[] output = new short[srcFrames * 2];
                for (int i = 0; i < srcFrames; i++)
                {
                    int byteIndex = i * srcChannels * 4;
                    float left = BitConverter.ToSingle(buffer, byteIndex) * gain;
                    float right = (srcChannels >= 2 ? BitConverter.ToSingle(buffer, byteIndex + 4) : left) * gain;

                    float absL = Math.Abs(left);
                    float absR = Math.Abs(right);
                    if (absL > maxPeak) maxPeak = absL;
                    if (absR > maxPeak) maxPeak = absR;

                    output[i * 2] = (short)(Math.Clamp(left, -1.0f, 1.0f) * 32767f);
                    output[i * 2 + 1] = (short)(Math.Clamp(right, -1.0f, 1.0f) * 32767f);
                }
                maxPeak = Math.Clamp(maxPeak, 0f, 1f);
                return output.AsSpan();
            }

            // Phase-continuous linear interpolation for 44,100 Hz -> 48,000 Hz (zero boundary clicks!)
            double step = (double)format.SampleRate / AudioPacketProtocol.SampleRate; // e.g. 44100 / 48000 = 0.91875
            int maxOutFrames = (int)Math.Ceiling((srcFrames + 1) / step) + 2;
            short[] resampled = new short[maxOutFrames * 2];
            int outFrameCount = 0;

            if (!_hasPrevSample)
            {
                _prevLeftSample = BitConverter.ToSingle(buffer, 0);
                _prevRightSample = srcChannels >= 2 ? BitConverter.ToSingle(buffer, 4) : _prevLeftSample;
                _hasPrevSample = true;
                _resamplePhase = 0.0;
            }

            while (_resamplePhase < srcFrames)
            {
                int idx = (int)_resamplePhase;
                float frac = (float)(_resamplePhase - idx);

                float l0, r0, l1, r1;
                if (idx == 0)
                {
                    l0 = _prevLeftSample;
                    r0 = _prevRightSample;
                    l1 = BitConverter.ToSingle(buffer, 0);
                    r1 = srcChannels >= 2 ? BitConverter.ToSingle(buffer, 4) : l1;
                }
                else
                {
                    int b0 = (idx - 1) * srcChannels * 4;
                    int b1 = idx * srcChannels * 4;
                    l0 = BitConverter.ToSingle(buffer, b0);
                    r0 = srcChannels >= 2 ? BitConverter.ToSingle(buffer, b0 + 4) : l0;
                    l1 = BitConverter.ToSingle(buffer, b1);
                    r1 = srcChannels >= 2 ? BitConverter.ToSingle(buffer, b1 + 4) : l1;
                }

                float left = (l0 + frac * (l1 - l0)) * gain;
                float right = (r0 + frac * (r1 - r0)) * gain;

                float absL = Math.Abs(left);
                float absR = Math.Abs(right);
                if (absL > maxPeak) maxPeak = absL;
                if (absR > maxPeak) maxPeak = absR;

                resampled[outFrameCount * 2] = (short)(Math.Clamp(left, -1.0f, 1.0f) * 32767f);
                resampled[outFrameCount * 2 + 1] = (short)(Math.Clamp(right, -1.0f, 1.0f) * 32767f);
                outFrameCount++;

                _resamplePhase += step;
            }

            // Save last sample of this buffer and wrap phase for the next callback
            int lastByteIdx = (srcFrames - 1) * srcChannels * 4;
            _prevLeftSample = BitConverter.ToSingle(buffer, lastByteIdx);
            _prevRightSample = srcChannels >= 2 ? BitConverter.ToSingle(buffer, lastByteIdx + 4) : _prevLeftSample;
            _resamplePhase -= srcFrames;

            maxPeak = Math.Clamp(maxPeak, 0f, 1f);
            return resampled.AsSpan(0, outFrameCount * 2);
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
        RestorePcSpeakerMuteState();
        TimeEndPeriod(1);

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
