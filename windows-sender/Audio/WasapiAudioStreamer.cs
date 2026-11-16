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
using NAudio.CoreAudioApi.Interfaces;
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

#region Windows 11 Process Loopback COM Interop (Pre-Mute / Pre-Volume System Audio Capture)

[StructLayout(LayoutKind.Sequential)]
internal struct AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS
{
    public uint TargetProcessId;
    public uint ProcessLoopbackMode; // 0 = INCLUDE, 1 = EXCLUDE_TARGET_PROCESS_TREE
}

[StructLayout(LayoutKind.Sequential)]
internal struct AUDIOCLIENT_ACTIVATION_PARAMS
{
    public uint ActivationType; // 1 = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK
    public AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS ProcessLoopbackParams;
}

[StructLayout(LayoutKind.Sequential)]
internal struct PROPVARIANT_BLOB
{
    public ushort vt; // VT_BLOB = 65
    public ushort wReserved1;
    public ushort wReserved2;
    public ushort wReserved3;
    public uint cbSize;
    public IntPtr pBlobData;
}

[ComImport, Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IActivateAudioInterfaceCompletionHandler
{
    void ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation);
}

[ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IActivateAudioInterfaceAsyncOperation
{
    void GetActivateResult(out int activateResult, [MarshalAs(UnmanagedType.IUnknown)] out object activatedInterface);
}

[ComImport, Guid("94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAgileObject
{
}

internal sealed class ActivateCompletionHandler : IActivateAudioInterfaceCompletionHandler, IAgileObject
{
    public readonly ManualResetEventSlim Done = new(false);
    public int HResult = -1;
    public object? AudioClientObj;

    public void ActivateCompleted(IActivateAudioInterfaceAsyncOperation activateOperation)
    {
        activateOperation.GetActivateResult(out HResult, out AudioClientObj);
        Done.Set();
    }
}

#endregion

public sealed class WasapiAudioStreamer : IDisposable
{
    [DllImport("winmm.dll", EntryPoint = "timeBeginPeriod")]
    private static extern uint TimeBeginPeriod(uint uMilliseconds);

    [DllImport("winmm.dll", EntryPoint = "timeEndPeriod")]
    private static extern uint TimeEndPeriod(uint uMilliseconds);

    [DllImport("Mmdevapi.dll", ExactSpelling = true, PreserveSig = false)]
    private static extern void ActivateAudioInterfaceAsync(
        [MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
        [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
        ref PROPVARIANT_BLOB activationParams,
        IActivateAudioInterfaceCompletionHandler completionHandler,
        out IActivateAudioInterfaceAsyncOperation activationOperation);

    // 480 stereo samples @ 48kHz = 10.0ms per UDP packet
    private const int SamplesPerChannelPerPacket = 480;
    private const int InterleavedShortsPerPacket = SamplesPerChannelPerPacket * AudioPacketProtocol.Channels; // 960 shorts = 1920 bytes

    private AudioClient? _processLoopbackClient;
    private readonly Dictionary<string, (bool OrigMute, float OrigVol)> _savedDeviceStates = new();
    private readonly object _muteLock = new();

    private UdpClient? _udpSocket;
    private IPEndPoint? _targetEndpoint;
    private IOpusEncoder? _opusEncoder;
    private CancellationTokenSource? _cts;

    private ushort _sequenceNumber;
    private uint _sampleTimestamp;
    private long _totalPacketsSent;
    private long _totalBytesSent;

    private readonly short[] _accumBuffer = new short[InterleavedShortsPerPacket * 16];
    private readonly byte[] _reusablePcmPacketBuf = new byte[AudioPacketProtocol.HeaderSize + (InterleavedShortsPerPacket * sizeof(short))];
    private int _accumCount;
    private bool _needsPrebufferCushion = true;
    private int _consecutiveSendErrors;

    private bool _mutePcSpeaker = true;

    public bool IsStreaming { get; private set; }
    public bool UseOpusCodec { get; set; } = false; // Raw PCM 16-bit by default
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
            new(AudioDeviceItem.AutoDefaultId, "System-Wide Pre-Mute Capture (All PC Apps)", true)
        };

        try
        {
            using var enumerator = new MMDeviceEnumerator();
            string? defaultId = null;
            try
            {
                using var def = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
                defaultId = def?.ID;
            }
            catch { }

            foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
            {
                list.Add(new AudioDeviceItem(device.ID, device.FriendlyName, device.ID == defaultId));
            }
        }
        catch { }

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

    public void SwitchCaptureDevice(string? deviceId)
    {
        // Process Loopback automatically captures across all output devices!
        ApplyPcSpeakerMuteState();
    }

    public void Start(string? deviceId, int listenPort, string? initialTargetIp, int targetPort)
    {
        if (IsStreaming)
            return;

        TimeBeginPeriod(1);

        _cts = new CancellationTokenSource();
        _sequenceNumber = 0;
        _sampleTimestamp = 0;
        _totalPacketsSent = 0;
        _totalBytesSent = 0;
        _accumCount = 0;
        _needsPrebufferCushion = true;

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

        // 1. Start dedicated MTA thread for Windows 11 Process Loopback ("VAD\Process_Loopback")
        // with automatic fallback to standard WasapiLoopbackCapture + Resampler for older Windows 10 PCs
        Exception? initError = null;
        bool useFallbackWasapi = false;
        using var readyEvent = new ManualResetEventSlim(false);
        var captureThread = new Thread(() =>
        {
            try
            {
                _processLoopbackClient = CreateProcessLoopbackAudioClient();
                _processLoopbackClient.Start();
            }
            catch
            {
                // Older Windows 10 builds or custom drivers without Process Loopback support:
                // seamlessly fall back to universal WasapiLoopbackCapture!
                useFallbackWasapi = true;
            }
            finally
            {
                readyEvent.Set();
            }

            if (!useFallbackWasapi && initError == null)
            {
                ProcessLoopbackCaptureThread(_cts.Token);
            }
            else if (useFallbackWasapi)
            {
                FallbackWasapiLoopbackThread(deviceId, _cts.Token);
            }
        })
        {
            IsBackground = true,
            Priority = ThreadPriority.Highest,
            Name = "AirPulse-UniversalAudioCapture-MTA"
        };
        captureThread.SetApartmentState(ApartmentState.MTA);
        captureThread.Start();
        readyEvent.Wait(4000);

        if (initError != null)
        {
            IsStreaming = false;
            try { _udpSocket?.Close(); } catch { }
            throw initError;
        }

        ApplyPcSpeakerMuteState();

        // 2. Listen for iPhone UDP Handshake ("AH") & Reachability Probes ("AH_PING")
        _ = Task.Run(() => ListenForIphoneHandshakeAsync(_cts.Token));
    }

    private static AudioClient CreateProcessLoopbackAudioClient()
    {
        var actParams = new AUDIOCLIENT_ACTIVATION_PARAMS
        {
            ActivationType = 1, // AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK
            ProcessLoopbackParams = new AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS
            {
                TargetProcessId = (uint)Process.GetCurrentProcess().Id,
                ProcessLoopbackMode = 1 // PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE (all apps on PC)
            }
        };

        IntPtr pParams = Marshal.AllocHGlobal(Marshal.SizeOf(actParams));
        try
        {
            Marshal.StructureToPtr(actParams, pParams, false);
            var propVar = new PROPVARIANT_BLOB
            {
                vt = 65, // VT_BLOB
                cbSize = (uint)Marshal.SizeOf(actParams),
                pBlobData = pParams
            };

            var handler = new ActivateCompletionHandler();
            Guid iidAudioClient = new("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
            ActivateAudioInterfaceAsync("VAD\\Process_Loopback", iidAudioClient, ref propVar, handler, out _);
            handler.Done.Wait(3000);

            if (handler.HResult != 0 || handler.AudioClientObj is not IAudioClient iAudioClient)
            {
                throw new InvalidOperationException($"Failed to activate Windows Process Loopback (HRESULT 0x{handler.HResult:X8})");
            }

            var client = new AudioClient(iAudioClient);
            // Initialize directly at 48,000 Hz Stereo IEEE Float (zero resampling needed!)
            var format = WaveFormat.CreateIeeeFloatWaveFormat(AudioPacketProtocol.SampleRate, AudioPacketProtocol.Channels);
            client.Initialize(
                AudioClientShareMode.Shared,
                AudioClientStreamFlags.Loopback,
                100000, // 10ms buffer in 100ns units
                0,
                format,
                Guid.Empty
            );
            return client;
        }
        finally
        {
            Marshal.FreeHGlobal(pParams);
        }
    }

    private void ProcessLoopbackCaptureThread(CancellationToken token)
    {
        var client = _processLoopbackClient;
        if (client == null)
            return;

        try { Thread.CurrentThread.Priority = ThreadPriority.Highest; } catch { }

        var captureClient = client.AudioCaptureClient;
        short[] cushionBuf = new short[InterleavedShortsPerPacket];
        short[] silentBuf = new short[InterleavedShortsPerPacket];
        long lastPacketSentTick = Environment.TickCount64;

        while (!token.IsCancellationRequested && IsStreaming)
        {
            Thread.Sleep(2);

            try
            {
                int packetSize = captureClient.GetNextPacketSize();
                bool capturedAny = false;

                while (packetSize > 0 && !token.IsCancellationRequested)
                {
                    IntPtr pBuffer = captureClient.GetBuffer(out int numFrames, out AudioClientBufferFlags flags);
                    if (numFrames > 0)
                    {
                        capturedAny = true;
                        float gain = VolumeGain;
                        float maxPeak = 0f;
                        bool isSilentFlag = (flags & AudioClientBufferFlags.Silent) != 0;

                        int shortsToWrite = numFrames * 2;
                        int spaceLeft = _accumBuffer.Length - _accumCount;
                        int count = Math.Min(spaceLeft, shortsToWrite);

                        unsafe
                        {
                            float* pf = (float*)pBuffer;
                            for (int i = 0; i < count; i++)
                            {
                                float sample = isSilentFlag ? 0f : (pf[i] * gain);
                                float abs = Math.Abs(sample);
                                if (abs > maxPeak) maxPeak = abs;

                                sample = Math.Clamp(sample, -1.0f, 1.0f);
                                _accumBuffer[_accumCount + i] = (short)(sample * 32767f);
                            }
                        }

                        _accumCount += count;
                        CurrentPeakLevel = Math.Clamp(maxPeak, 0f, 1f);
                        PeakLevelUpdated?.Invoke(CurrentPeakLevel);
                    }

                    captureClient.ReleaseBuffer(numFrames);
                    packetSize = captureClient.GetNextPacketSize();
                }

                // Transmit all complete 10ms (480-frame) packets
                while (_accumCount >= InterleavedShortsPerPacket)
                {
                    if (_needsPrebufferCushion && _targetEndpoint != null)
                    {
                        _needsPrebufferCushion = false;
                        for (int c = 0; c < 3; c++)
                        {
                            EncodeAndSendFrame(cushionBuf.AsSpan(), SamplesPerChannelPerPacket, PacketFlags.None);
                        }
                    }

                    EncodeAndSendFrame(
                        _accumBuffer.AsSpan(0, InterleavedShortsPerPacket),
                        SamplesPerChannelPerPacket,
                        PacketFlags.None
                    );
                    lastPacketSentTick = Environment.TickCount64;

                    int remaining = _accumCount - InterleavedShortsPerPacket;
                    if (remaining > 0)
                    {
                        _accumBuffer.AsSpan(InterleavedShortsPerPacket, remaining).CopyTo(_accumBuffer.AsSpan(0, remaining));
                    }
                    _accumCount = remaining;
                }

                // If PC is completely idle (no audio apps open), send a keep-alive every 150ms
                if (!capturedAny && (Environment.TickCount64 - lastPacketSentTick) >= 150 && _targetEndpoint != null)
                {
                    CurrentPeakLevel = 0f;
                    PeakLevelUpdated?.Invoke(0f);
                    lastPacketSentTick = Environment.TickCount64;
                    EncodeAndSendFrame(
                        silentBuf.AsSpan(),
                        SamplesPerChannelPerPacket,
                        PacketFlags.HeartbeatKeepAlive | PacketFlags.SilentFrame
                    );
                }
            }
            catch
            {
                // Ignore transient capture errors
            }
        }
    }

    /// <summary>
    /// Universal fallback for older Windows 10 PCs that do not support Windows 11 Process Loopback.
    /// Automatically resamples any sound card format (44.1kHz, 48kHz, 96kHz, 192kHz, Mono/Stereo/Surround) to 48kHz 16-bit Stereo.
    /// </summary>
    private void FallbackWasapiLoopbackThread(string? deviceId, CancellationToken token)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            MMDevice? device = null;
            if (!string.IsNullOrEmpty(deviceId) && deviceId != AudioDeviceItem.AutoDefaultId)
            {
                try { device = enumerator.GetDevice(deviceId); } catch { }
            }
            device ??= enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);

            using var capture = new WasapiLoopbackCapture(device);
            var bufferedProvider = new BufferedWaveProvider(capture.WaveFormat)
            {
                DiscardOnBufferOverflow = true,
                BufferDuration = TimeSpan.FromMilliseconds(500)
            };

            capture.DataAvailable += (_, e) =>
            {
                if (e.BytesRecorded > 0)
                {
                    bufferedProvider.AddSamples(e.Buffer, 0, e.BytesRecorded);
                }
            };

            var targetFormat = new WaveFormat(AudioPacketProtocol.SampleRate, 16, AudioPacketProtocol.Channels);
            using var resampler = new MediaFoundationResampler(bufferedProvider, targetFormat)
            {
                ResamplerQuality = 30
            };

            byte[] readBytes = new byte[InterleavedShortsPerPacket * sizeof(short)];
            short[] frameShorts = new short[InterleavedShortsPerPacket];
            short[] silentBuf = new short[InterleavedShortsPerPacket];
            long lastPacketSentTick = Environment.TickCount64;

            capture.StartRecording();
            while (!token.IsCancellationRequested && IsStreaming)
            {
                Thread.Sleep(3);
                while (bufferedProvider.BufferedBytes > 0 && !token.IsCancellationRequested)
                {
                    int bytesRead = resampler.Read(readBytes, 0, readBytes.Length);
                    if (bytesRead <= 0)
                        break;

                    int shortsCount = bytesRead / 2;
                    Buffer.BlockCopy(readBytes, 0, frameShorts, 0, shortsCount * 2);

                    float gain = VolumeGain;
                    float maxPeak = 0f;
                    int spaceLeft = _accumBuffer.Length - _accumCount;
                    int count = Math.Min(spaceLeft, shortsCount);
                    for (int i = 0; i < count; i++)
                    {
                        float s = (frameShorts[i] / 32768f) * gain;
                        float abs = Math.Abs(s);
                        if (abs > maxPeak) maxPeak = abs;
                        _accumBuffer[_accumCount + i] = (short)(Math.Clamp(s, -1f, 1f) * 32767f);
                    }
                    _accumCount += count;
                    CurrentPeakLevel = Math.Clamp(maxPeak, 0f, 1f);
                    PeakLevelUpdated?.Invoke(CurrentPeakLevel);

                    while (_accumCount >= InterleavedShortsPerPacket)
                    {
                        EncodeAndSendFrame(
                            _accumBuffer.AsSpan(0, InterleavedShortsPerPacket),
                            SamplesPerChannelPerPacket,
                            PacketFlags.None
                        );
                        lastPacketSentTick = Environment.TickCount64;
                        int rem = _accumCount - InterleavedShortsPerPacket;
                        if (rem > 0)
                        {
                            _accumBuffer.AsSpan(InterleavedShortsPerPacket, rem).CopyTo(_accumBuffer.AsSpan(0, rem));
                        }
                        _accumCount = rem;
                    }
                }

                if ((Environment.TickCount64 - lastPacketSentTick) >= 150 && _targetEndpoint != null)
                {
                    CurrentPeakLevel = 0f;
                    PeakLevelUpdated?.Invoke(0f);
                    lastPacketSentTick = Environment.TickCount64;
                    EncodeAndSendFrame(
                        silentBuf.AsSpan(),
                        SamplesPerChannelPerPacket,
                        PacketFlags.HeartbeatKeepAlive | PacketFlags.SilentFrame
                    );
                }
            }
            capture.StopRecording();
        }
        catch
        {
            // Ignore fallback termination errors
        }
    }

    private void ApplyPcSpeakerMuteState()
    {
        lock (_muteLock)
        {
            // Only mute PC speakers when an iPhone is actively connected AND the Mute checkbox is checked!
            bool shouldMute = IsStreaming && _mutePcSpeaker && _targetEndpoint != null;
            if (!shouldMute)
            {
                RestorePcSpeakerMuteState();
                return;
            }

            try
            {
                using var enumerator = new MMDeviceEnumerator();
                foreach (var dev in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
                {
                    try
                    {
                        if (!_savedDeviceStates.ContainsKey(dev.ID))
                        {
                            _savedDeviceStates[dev.ID] = (
                                dev.AudioEndpointVolume.Mute,
                                dev.AudioEndpointVolume.MasterVolumeLevelScalar
                            );
                        }

                        // Because we capture via Windows 11 Process Loopback (Pre-Mute!), we can safely
                        // set Mute = true on ALL speakers without affecting the iPhone audio stream at all!
                        if (!dev.AudioEndpointVolume.Mute)
                        {
                            dev.AudioEndpointVolume.Mute = true;
                        }

                        // For Bluetooth speakers (like EMBERTON II), also set MasterVolume = 0 so their amp is 100% silent
                        if (!dev.FriendlyName.Contains("Realtek", StringComparison.OrdinalIgnoreCase) &&
                            dev.AudioEndpointVolume.MasterVolumeLevelScalar > 0.0f)
                        {
                            dev.AudioEndpointVolume.MasterVolumeLevelScalar = 0.0f;
                        }
                    }
                    catch { }
                    finally
                    {
                        dev.Dispose();
                    }
                }
            }
            catch { }
        }
    }

    private void RestorePcSpeakerMuteState()
    {
        lock (_muteLock)
        {
            if (_savedDeviceStates.Count == 0)
                return;

            try
            {
                using var enumerator = new MMDeviceEnumerator();
                foreach (var dev in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
                {
                    try
                    {
                        if (_savedDeviceStates.TryGetValue(dev.ID, out var saved))
                        {
                            dev.AudioEndpointVolume.Mute = saved.OrigMute;
                            if (saved.OrigVol > 0.02f)
                            {
                                dev.AudioEndpointVolume.MasterVolumeLevelScalar = saved.OrigVol;
                            }
                        }
                        else
                        {
                            dev.AudioEndpointVolume.Mute = false;
                        }
                    }
                    catch { }
                    finally
                    {
                        dev.Dispose();
                    }
                }
            }
            catch { }
            finally
            {
                _savedDeviceStates.Clear();
            }
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
                    var text = data.Length > 2
                        ? Encoding.UTF8.GetString(data, 2, data.Length - 2).Trim()
                        : string.Empty;

                    // Explicit stop notification from iPhone ("AH_STOP")
                    if (text.StartsWith("_STOP", StringComparison.Ordinal))
                    {
                        HandleClientDisconnected();
                        continue;
                    }

                    // Reachability probe from iPhone ("AH_PING|<port>|<name>")
                    // Reply immediately with "AH_PONG|<PC_NAME>" so iPhone unlocks the Start Audio Stream button
                    // WITHOUT starting audio transmission or muting PC speakers yet!
                    if (text.StartsWith("_PING", StringComparison.Ordinal) || text.StartsWith("_DISCOVER", StringComparison.Ordinal))
                    {
                        int replyPort = result.RemoteEndPoint.Port;
                        var pingParts = text.Split('|');
                        if (pingParts.Length >= 2 && int.TryParse(pingParts[1], out int parsedPingPort) && parsedPingPort > 0)
                        {
                            replyPort = parsedPingPort;
                        }
                        var pongEndpoint = new IPEndPoint(result.RemoteEndPoint.Address, replyPort);
                        var pongBytes = Encoding.UTF8.GetBytes($"AH_PONG|{Environment.MachineName}");
                        await _udpSocket.SendAsync(pongBytes, pongBytes.Length, pongEndpoint);
                        continue;
                    }

                    int clientPort = result.RemoteEndPoint.Port;
                    string deviceLabel = "iPhone";
                    if (!string.IsNullOrEmpty(text))
                    {
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

                    var newEndpoint = new IPEndPoint(result.RemoteEndPoint.Address, clientPort);
                    bool isNewConnection = _targetEndpoint == null || !_targetEndpoint.Equals(newEndpoint);

                    _targetEndpoint = newEndpoint;
                    _consecutiveSendErrors = 0;

                    if (isNewConnection)
                    {
                        _needsPrebufferCushion = true;
                        ConnectedClientInfo = $"Connected: {deviceLabel} ({_targetEndpoint}) • PC Muted";
                        ClientConnected?.Invoke(ConnectedClientInfo);
                        ApplyPcSpeakerMuteState();
                    }

                    var ack = Encoding.UTF8.GetBytes($"AH_ACK|{Environment.MachineName}");
                    await _udpSocket.SendAsync(ack, ack.Length, _targetEndpoint);
                }
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (SocketException sockEx) when (sockEx.SocketErrorCode == SocketError.ConnectionReset)
            {
                // ICMP Port Unreachable from iPhone: the user tapped STOP AUDIO STREAM on iPhone!
                HandleClientDisconnected();
            }
            catch
            {
                // Ignore transient socket errors
            }
        }
    }

    private void HandleClientDisconnected()
    {
        if (_targetEndpoint == null)
            return;

        _targetEndpoint = null;
        _consecutiveSendErrors = 0;
        RestorePcSpeakerMuteState();
        ConnectedClientInfo = "iPhone Stopped Stream • PC Speakers Restored";
        ClientConnected?.Invoke(ConnectedClientInfo);
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
            packetBuffer = _reusablePcmPacketBuf;
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
            _consecutiveSendErrors = 0;
            Interlocked.Increment(ref _totalPacketsSent);
            Interlocked.Add(ref _totalBytesSent, totalPacketSize);
        }
        catch (SocketException sockEx) when (sockEx.SocketErrorCode == SocketError.ConnectionReset)
        {
            if (++_consecutiveSendErrors >= 3)
            {
                HandleClientDisconnected();
            }
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
        try { _processLoopbackClient?.Stop(); } catch { }
        try { _processLoopbackClient?.Dispose(); } catch { }
        try { _udpSocket?.Close(); } catch { }
        try { _udpSocket?.Dispose(); } catch { }

        _processLoopbackClient = null;
        _udpSocket = null;
        CurrentPeakLevel = 0f;
    }

    public void Dispose()
    {
        Stop();
    }
}
