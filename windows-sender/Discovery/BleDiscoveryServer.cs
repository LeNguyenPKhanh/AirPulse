using System;
using System.Buffers.Binary;
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

/// <summary>
/// Advertises the Windows 11 PC's IP address and UDP port over Bluetooth Low Energy (BLE)
/// using both BLE Advertisement packets and a BLE GATT Service Characteristic so the iPhone
/// CoreBluetooth client can discover and pair in one tap without typing an IP address.
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
        LocalIpAddress = GetBestLocalIpv4Address();

        await StartBleAdvertisingAsync();
        StartLanBroadcastBeacon();
    }

    private async Task StartBleAdvertisingAsync()
    {
        try
        {
            var ipBytes = IPAddress.Parse(LocalIpAddress).GetAddressBytes();
            if (ipBytes.Length != 4)
            {
                UpdateStatus($"LAN Discovery Ready ({LocalIpAddress}:{UdpPort})");
                return;
            }

            // 1. Start BLE Manufacturer Data + Service UUID Advertiser
            _publisher = new BluetoothLEAdvertisementPublisher();
            _publisher.Advertisement.ServiceUuids.Add(AudioPacketProtocol.BleServiceUuid);

            // Payload format: [Magic 'A','S' (2B)] [IPv4 (4B)] [Port uint16 BE (2B)] = 8 bytes
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

            _publisher.StatusChanged += (sender, args) =>
            {
                IsBleAdvertising = args.Status == BluetoothLEAdvertisementPublisherStatus.Started;
                UpdateStatus(IsBleAdvertising
                    ? $"BLE Active • Broadcasting {LocalIpAddress}:{UdpPort}"
                    : $"BLE Status: {args.Status} ({LocalIpAddress}:{UdpPort})");
            };

            _publisher.Start();

            // 2. Also publish a GATT Service + Characteristic so iOS background CoreBluetooth
            // scans filtering by Service UUID can read the full endpoint JSON/text string
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
            }

            IsBleAdvertising = true;
            UpdateStatus($"BLE Active • {LocalIpAddress}:{UdpPort}");
        }
        catch (Exception ex)
        {
            IsBleAdvertising = false;
            UpdateStatus($"BLE Unavailable ({ex.Message}) • Using Wi-Fi Discovery ({LocalIpAddress}:{UdpPort})");
        }
    }

    private void StartLanBroadcastBeacon()
    {
        _lanBroadcastCts?.Cancel();
        _lanBroadcastCts = new CancellationTokenSource();
        var token = _lanBroadcastCts.Token;

        _ = Task.Run(async () =>
        {
            using var udp = new UdpClient { EnableBroadcast = true };
            var broadcastEndpoint = new IPEndPoint(IPAddress.Broadcast, AudioPacketProtocol.DefaultUdpPort + 1);
            while (!token.IsCancellationRequested)
            {
                try
                {
                    LocalIpAddress = GetBestLocalIpv4Address();
                    var beacon = Encoding.UTF8.GetBytes($"AS_BEACON|{LocalIpAddress}|{UdpPort}|{Environment.MachineName}");
                    await udp.SendAsync(beacon, beacon.Length, broadcastEndpoint);
                }
                catch
                {
                    // Ignore transient network broadcast errors
                }

                await Task.Delay(2000, token);
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

    public static string GetBestLocalIpv4Address()
    {
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up ||
                    ni.NetworkInterfaceType == NetworkInterfaceType.Loopback ||
                    ni.Description.Contains("Virtual", StringComparison.OrdinalIgnoreCase) ||
                    ni.Description.Contains("WSL", StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                var props = ni.GetIPProperties();
                if (props.GatewayAddresses.Count == 0)
                    continue;

                foreach (var ua in props.UnicastAddresses)
                {
                    if (ua.Address.AddressFamily == AddressFamily.InterNetwork)
                    {
                        return ua.Address.ToString();
                    }
                }
            }

            using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, 0);
            socket.Connect("8.8.8.8", 65530);
            if (socket.LocalEndPoint is IPEndPoint endPoint)
            {
                return endPoint.Address.ToString();
            }
        }
        catch
        {
            // Fallback below
        }

        return "127.0.0.1";
    }

    public void Dispose()
    {
        Stop();
    }
}
