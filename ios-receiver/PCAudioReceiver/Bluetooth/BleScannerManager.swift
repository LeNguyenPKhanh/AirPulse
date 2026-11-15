import Foundation
import CoreBluetooth
import Darwin

struct DiscoveredPcEndpoint: Identifiable, Equatable {
    var id: String { "\(ipAddress):\(port)" }
    let name: String
    let ipAddress: String
    let port: UInt16
    let source: String // "BLE" or "Wi-Fi Beacon"
}

/// Passively scans for the Windows 11 PC via Bluetooth Low Energy (CoreBluetooth)
/// and UDP LAN Broadcast Beacons so the user can pair in one tap without entering an IP.
final class BleScannerManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let serviceUuid = CBUUID(string: "A1B2C3D4-E5F6-4789-ABCD-EF0123456789")
    static let endpointCharacteristicUuid = CBUUID(string: "A1B2C3D4-E5F6-4789-ABCD-EF012345678A")

    @Published private(set) var discoveredEndpoints: [DiscoveredPcEndpoint] = []
    @Published private(set) var bluetoothStateText: String = "Initializing Bluetooth..."

    private var centralManager: CBCentralManager!
    private var activePeripherals: [UUID: CBPeripheral] = [:]
    private var beaconSocketFd: Int32 = -1
    private var isBeaconListening = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.global(qos: .userInitiated))
        startLanBeaconListener()
    }

    deinit {
        stopLanBeaconListener()
    }

    func startScanning() {
        if centralManager.state == .poweredOn {
            centralManager.scanForPeripherals(
                withServices: [Self.serviceUuid],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
            DispatchQueue.main.async {
                self.bluetoothStateText = "Scanning for Windows 11 PC via BLE & Wi-Fi..."
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanning()
        case .poweredOff:
            DispatchQueue.main.async {
                self.bluetoothStateText = "Bluetooth Off (Wi-Fi Auto-Discovery Active)"
            }
        case .unauthorized:
            DispatchQueue.main.async {
                self.bluetoothStateText = "Bluetooth Permission Needed (Wi-Fi Active)"
            }
        default:
            DispatchQueue.main.async {
                self.bluetoothStateText = "Wi-Fi Auto-Discovery Active"
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let pcName = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Windows 11 PC"

        // 1. Check Manufacturer Data for fast zero-connection payload: [CompanyID 2B][0x41, 0x53][IPv4 4B][Port 2B BE]
        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfgData.count >= 10 {
            let bytes = [UInt8](mfgData)
            if bytes[2] == 0x41 && bytes[3] == 0x53 {
                let ip = "\(bytes[4]).\(bytes[5]).\(bytes[6]).\(bytes[7])"
                let port = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
                registerEndpoint(DiscoveredPcEndpoint(name: pcName, ipAddress: ip, port: port, source: "BLE"))
                return
            }
        }

        // 2. Also connect to read GATT Endpoint Characteristic if Manufacturer Data wasn't included
        activePeripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUuid])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == Self.serviceUuid {
            peripheral.discoverCharacteristics([Self.endpointCharacteristicUuid], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics where characteristic.uuid == Self.endpointCharacteristicUuid {
            peripheral.readValue(for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.endpointCharacteristicUuid,
              let data = characteristic.value,
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        // Format: "192.168.1.100:49152:DESKTOP-PC"
        let parts = text.split(separator: ":")
        if parts.count >= 2, let port = UInt16(parts[1]) {
            let ip = String(parts[0])
            let host = parts.count >= 3 ? String(parts[2]) : (peripheral.name ?? "Windows 11 PC")
            registerEndpoint(DiscoveredPcEndpoint(name: host, ipAddress: ip, port: port, source: "BLE GATT"))
        }

        centralManager.cancelPeripheralConnection(peripheral)
        activePeripherals.removeValue(forKey: peripheral.identifier)
    }

    private func registerEndpoint(_ endpoint: DiscoveredPcEndpoint) {
        DispatchQueue.main.async {
            if let idx = self.discoveredEndpoints.firstIndex(where: { $0.id == endpoint.id }) {
                self.discoveredEndpoints[idx] = endpoint
            } else {
                self.discoveredEndpoints.append(endpoint)
            }
        }
    }

    // MARK: - UDP LAN Broadcast Beacon Fallback (Port 49153)

    private func startLanBeaconListener() {
        guard !isBeaconListening else { return }
        isBeaconListening = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return }
            self.beaconSocketFd = fd

            var reuse: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(49153).bigEndian
            addr.sin_addr.s_addr = INADDR_ANY

            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                close(fd)
                return
            }

            var buffer = [UInt8](repeating: 0, count: 256)
            while self.isBeaconListening {
                let bytesRead = recv(fd, &buffer, buffer.count, 0)
                if bytesRead > 0 {
                    let data = Data(bytes: buffer, count: bytesRead)
                    if let message = String(data: data, encoding: .utf8),
                       message.hasPrefix("AS_BEACON|") {
                        let comps = message.split(separator: "|")
                        if comps.count >= 4, let port = UInt16(comps[2]) {
                            let ip = String(comps[1])
                            let name = String(comps[3])
                            self.registerEndpoint(
                                DiscoveredPcEndpoint(name: name, ipAddress: ip, port: port, source: "Wi-Fi Beacon")
                            )
                        }
                    }
                } else {
                    break
                }
            }
        }
    }

    private func stopLanBeaconListener() {
        isBeaconListening = false
        if beaconSocketFd >= 0 {
            close(beaconSocketFd)
            beaconSocketFd = -1
        }
    }
}
