using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using PcAudioStreamer.Protocol;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;

namespace PcAudioStreamer.Discovery;

public sealed record LanInterfaceInfo(IPAddress Address, IPAddress BroadcastAddress, string Name, bool IsWifi);

/// <summary>
/// Advertises the Windows 11 PC's IP address and UDP port over Bluetooth Low Energy (BLE GATT)
/// and Directed Subnet UDP Broadcasts across all physical Wi-Fi/Ethernet interfaces.
/// </summary>
public sealed class BleDiscoveryServer : IDisposable
{
    public static readonly Guid EndpointCharacteristicUuid = new("A1B2C3D4-E5F6-4789-ABCD-EF012345678A");

    private BluetoothLEAdvertisementPublisher? _publisher;
    private GattServiceProvider? _gattServiceProvider;
    private CancellationTokenSource? _lanBroadcastCts;

    public string LocalIpAddress { get; private set; } = "127.0.0.1";
    public int UdpPort { get; private set; } = AudioPacketProtocol.DefaultUdpPort;
    public bool IsBleAdvertising { get; private set; }
    public string StatusMessage { get; private set; } = "Idle";

    public event Action<string>? StatusChanged;

    public async Task StartAsync(int udpPort)
    {
        UdpPort = udpPort;
        var lanInterfaces = GetAllLanInterfaces();
        LocalIpAddress = lanInterfaces.FirstOrDefault()?.Address.ToString() ?? GetBestLocalIpv4Address();

        await StartBleAdvertisingAsync();
        StartLanBroadcastBeacon();
    }

    private async Task StartBleAdvertisingAsync()
    {
        bool gattOk = false;
        string allIpsSummary = string.Join(", ", GetAllLanInterfaces().Select(i => i.Address.ToString()));
        if (string.IsNullOrWhiteSpace(allIpsSummary))
            allIpsSummary = LocalIpAddress;

        // 1. Publish BLE GATT Service + Characteristic (Primary mechanism for iOS CoreBluetooth scanForPeripherals(withServices:))
        try
        {
            var gattResult = await GattServiceProvider.CreateAsync(AudioPacketProtocol.BleServiceUuid);
            if (gattResult.Error == BluetoothError.Success)
            {
                _gattServiceProvider = gattResult.ServiceProvider;
                var endpointText = $"{LocalIpAddress}:{UdpPort}:{Environment.MachineName}";
                var endpointBytes = Encoding.UTF8.GetBytes(endpointText);

                var charParams = new GattLocalCharacteristicParameters
                {
                    CharacteristicProperties = GattCharacteristicProperties.Read | GattCharacteristicProperties.Notify,
                    ReadProtectionLevel = GattProtectionLevel.Plain,
                    StaticValue = endpointBytes.AsBuffer()
                };

                await _gattServiceProvider.Service.CreateCharacteristicAsync(EndpointCharacteristicUuid, charParams);
                _gattServiceProvider.StartAdvertising(new GattServiceProviderAdvertisingParameters
                {
                    IsConnectable = true,
                    IsDiscoverable = true
                });
                gattOk = true;
            }
        }
        catch
        {
            // Ignore if GATT Peripheral role is unsupported by adapter
        }

        // 2. Also publish compact ManufacturerData beacon (< 31 bytes limit, so do NOT combine with 128-bit UUID in same packet)
        try
        {
            var ipBytes = IPAddress.Parse(LocalIpAddress).GetAddressBytes();
            if (ipBytes.Length == 4)
            {
                _publisher = new BluetoothLEAdvertisementPublisher();
                byte[] payload = new byte[8];
                payload[0] = AudioPacketProtocol.MagicByte0;
                payload[1] = AudioPacketProtocol.MagicByte1;
                System.Buffer.BlockCopy(ipBytes, 0, payload, 2, 4);
                BinaryPrimitives.WriteUInt16BigEndian(payload.AsSpan(6, 2), (ushort)UdpPort);

                var writer = new DataWriter();
                writer.WriteBytes(payload);

                var manufacturerData = new BluetoothLEManufacturerData(
                    AudioPacketProtocol.BleManufacturerCompanyId,
                    writer.DetachBuffer()
                );
                _publisher.Advertisement.ManufacturerData.Add(manufacturerData);
                _publisher.Start();
                gattOk = true;
            }
        }
        catch
        {
            // Ignore if BLE advertisement publisher fails
        }

        IsBleAdvertising = gattOk;
        UpdateStatus(gattOk
            ? $"BLE & Wi-Fi Active • PC IP: {allIpsSummary} (Port {UdpPort})"
            : $"Wi-Fi Active • PC IP: {allIpsSummary} (Port {UdpPort})");
    }

    private void StartLanBroadcastBeacon()
    {
        _lanBroadcastCts?.Cancel();
        _lanBroadcastCts = new CancellationTokenSource();
        var token = _lanBroadcastCts.Token;

        _ = Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                try
                {
                    var interfaces = GetAllLanInterfaces();
                    if (interfaces.Count > 0)
                    {
                        // Broadcast ONLY the primary LAN interface (Wi-Fi preferred) so the iPhone only shows 1 PC entry
                        var primary = interfaces[0];
                        LocalIpAddress = primary.Address.ToString();

                        try
                        {
                            using var udp = new UdpClient(new IPEndPoint(primary.Address, 0))
                            {
                                EnableBroadcast = true
                            };

                            var beacon = Encoding.UTF8.GetBytes($"AS_BEACON|{primary.Address}|{UdpPort}|{Environment.MachineName}");

                            var directedEndpoint = new IPEndPoint(primary.BroadcastAddress, AudioPacketProtocol.DefaultUdpPort + 1);
                            await udp.SendAsync(beacon, beacon.Length, directedEndpoint);

                            var globalEndpoint = new IPEndPoint(IPAddress.Broadcast, AudioPacketProtocol.DefaultUdpPort + 1);
                            await udp.SendAsync(beacon, beacon.Length, globalEndpoint);
                        }
                        catch
                        {
                            // Ignore per-interface send errors
                        }
                    }
                }
                catch
                {
                    // Ignore transient errors
                }

                await Task.Delay(1000, token);
            }
        }, token);
    }

    public void Stop()
    {
        try
        {
            _lanBroadcastCts?.Cancel();
            if (_publisher != null && _publisher.Status == BluetoothLEAdvertisementPublisherStatus.Started)
            {
                _publisher.Stop();
            }
            _gattServiceProvider?.StopAdvertising();
        }
        catch
        {
            // Ignore shutdown exceptions
        }
        finally
        {
            IsBleAdvertising = false;
            UpdateStatus("Stopped");
        }
    }

    private void UpdateStatus(string message)
    {
        StatusMessage = message;
        StatusChanged?.Invoke(message);
    }

    public static List<LanInterfaceInfo> GetAllLanInterfaces()
    {
        var results = new List<LanInterfaceInfo>();
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up ||
                    ni.NetworkInterfaceType == NetworkInterfaceType.Loopback ||
                    ni.NetworkInterfaceType == NetworkInterfaceType.Tunnel)
                {
                    continue;
                }

                string nameAndDesc = $"{ni.Name} {ni.Description}";
                if (nameAndDesc.Contains("Radmin", StringComparison.OrdinalIgnoreCase) ||
                    nameAndDesc.Contains("VPN", StringComparison.OrdinalIgnoreCase) ||
                    nameAndDesc.Contains("Virtual", StringComparison.OrdinalIgnoreCase) ||
                    nameAndDesc.Contains("vEthernet", StringComparison.OrdinalIgnoreCase) ||
                    nameAndDesc.Contains("WSL", StringComparison.OrdinalIgnoreCase) ||
                    nameAndDesc.Contains("Hyper-V", StringComparison.OrdinalIgnoreCase) ||
                    nameAndDesc.Contains("Tailscale", StringComparison.OrdinalIgnoreCase) ||
                    nameAndDesc.Contains("ZeroTier", StringComparison.OrdinalIgnoreCase) ||
                    nameAndDesc.Contains("VMware", StringComparison.OrdinalIgnoreCase) ||
                    nameAndDesc.Contains("VirtualBox", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var props = ni.GetIPProperties();
                foreach (var ua in props.UnicastAddresses)
                {
                    if (ua.Address.AddressFamily != AddressFamily.InterNetwork)
                        continue;

                    byte[] ipBytes = ua.Address.GetAddressBytes();
                    // Only include private LAN IPv4 ranges (192.168.x.x, 10.x.x.x, 172.16-31.x.x)
                    bool isPrivateLan =
                        (ipBytes[0] == 192 && ipBytes[1] == 168) ||
                        (ipBytes[0] == 10) ||
                        (ipBytes[0] == 172 && ipBytes[1] >= 16 && ipBytes[1] <= 31);

                    if (!isPrivateLan)
                        continue;

                    byte[] maskBytes = ua.IPv4Mask?.GetAddressBytes() ?? new byte[] { 255, 255, 255, 0 };
                    byte[] broadcastBytes = new byte[4];
                    for (int i = 0; i < 4; i++)
                    {
                        broadcastBytes[i] = (byte)(ipBytes[i] | ~maskBytes[i]);
                    }

                    bool isWifi = ni.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ||
                                  ni.Name.Contains("Wi-Fi", StringComparison.OrdinalIgnoreCase);

                    results.Add(new LanInterfaceInfo(
                        ua.Address,
                        new IPAddress(broadcastBytes),
                        ni.Name,
                        isWifi
                    ));
                }
            }
        }
        catch
        {
            // Ignore enumeration errors
        }

        // Prioritize Wi-Fi first (since iPhone connects over Wi-Fi), then Ethernet
        return results
            .OrderByDescending(r => r.IsWifi)
            .ToList();
    }

    public static string GetBestLocalIpv4Address()
    {
        var first = GetAllLanInterfaces().FirstOrDefault();
        return first?.Address.ToString() ?? "127.0.0.1";
    }

    public void Dispose()
    {
        Stop();
    }
}
