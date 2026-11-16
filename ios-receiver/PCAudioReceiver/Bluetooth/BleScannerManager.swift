import Foundation
import CoreBluetooth
import Darwin

struct DiscoveredPcEndpoint: Identifiable, Equatable {
    var id: String { "\(ipAddress):\(port)" }
    let name: String
    let ipAddress: String
    let port: UInt16
    let source: String // "BLE", "Wi-Fi Beacon", or "UDP Probe"
}

/// Passively and actively scans for any Windows 10/11 PC running AirPulse via
/// Bluetooth Low Energy (CoreBluetooth) and UDP LAN Broadcast Beacons,
/// and automatically prunes offline PCs after 4 seconds of silence.
final class BleScannerManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let serviceUuid = CBUUID(string: "A1B2C3D4-E5F6-4789-ABCD-EF0123456789")
    static let endpointCharacteristicUuid = CBUUID(string: "A1B2C3D4-E5F6-4789-ABCD-EF012345678A")

    @Published private(set) var discoveredEndpoints: [DiscoveredPcEndpoint] = []
    @Published private(set) var bluetoothStateText: String = "Searching for PC on Local Network..."

    var onEndpointSeen: ((DiscoveredPcEndpoint) -> Void)?

    private var centralManager: CBCentralManager!
    private var activePeripherals: [UUID: CBPeripheral] = [:]
    private var beaconSocketFd: Int32 = -1
    private var isBeaconListening = false
    private var lastSeenTimestamps: [String: TimeInterval] = [:]
    private var pruneTimer: DispatchSourceTimer?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.global(qos: .userInitiated))
        startLanBeaconListener()
        startStaleEndpointPruneTimer()
    }

    deinit {
        pruneTimer?.cancel()
        stopLanBeaconListener()
    }

    func startScanning() {
        DispatchQueue.main.async {
            self.discoveredEndpoints.removeAll()
            self.lastSeenTimestamps.removeAll()
            self.bluetoothStateText = "Scanning for PC via BLE & Wi-Fi..."
        }
        if centralManager.state == .poweredOn {
            centralManager.scanForPeripherals(
                withServices: [Self.serviceUuid],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
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
                self.bluetoothStateText = "Wi-Fi Auto-Discovery Active"
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
        let pcName = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Windows PC"

        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfgData.count >= 10 {
            let bytes = [UInt8](mfgData)
            if bytes[2] == 0x41 && bytes[3] == 0x53 {
                let ip = "\(bytes[4]).\(bytes[5]).\(bytes[6]).\(bytes[7])"
                let port = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
                registerEndpoint(DiscoveredPcEndpoint(name: pcName, ipAddress: ip, port: port, source: "BLE"))
                return
            }
        }

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

        let parts = text.split(separator: ":")
        if parts.count >= 2, let port = UInt16(parts[1]) {
            let ip = String(parts[0])
            let host = parts.count >= 3 ? String(parts[2]) : (peripheral.name ?? "Windows PC")
            registerEndpoint(DiscoveredPcEndpoint(name: host, ipAddress: ip, port: port, source: "BLE GATT"))
        }

        centralManager.cancelPeripheralConnection(peripheral)
        activePeripherals.removeValue(forKey: peripheral.identifier)
    }

    func registerEndpoint(_ endpoint: DiscoveredPcEndpoint) {
        let now = CFAbsoluteTimeGetCurrent()
        onEndpointSeen?(endpoint)

        DispatchQueue.main.async {
            self.lastSeenTimestamps[endpoint.id] = now

            func score(_ ep: DiscoveredPcEndpoint) -> Int {
                switch ep.source {
                case "UDP Probe": return 4
                case "Wi-Fi Beacon": return 3
                case "BLE GATT": return 2
                case "BLE": return 1
                default: return 0
                }
            }

            // Update exact same endpoint (same IP:port)
            if let idx = self.discoveredEndpoints.firstIndex(where: { $0.id == endpoint.id }) {
                self.discoveredEndpoints[idx] = endpoint
                self.collapseEndpointsForSamePc(preferredId: endpoint.id)
                return
            }

            // If same PC (by name) already listed with a different interface/IP, keep only the best one
            let samePcIdx = self.discoveredEndpoints.firstIndex {
                $0.name.caseInsensitiveCompare(endpoint.name) == .orderedSame && $0.port == endpoint.port
            }
            if let idx = samePcIdx {
                let existing = self.discoveredEndpoints[idx]
                if score(endpoint) >= score(existing) {
                    self.lastSeenTimestamps.removeValue(forKey: existing.id)
                    self.discoveredEndpoints[idx] = endpoint
                }
                self.collapseEndpointsForSamePc(preferredId: self.discoveredEndpoints[idx].id)
            } else {
                self.discoveredEndpoints.append(endpoint)
                self.bluetoothStateText = "Discovered \(endpoint.name) on Local Network"
                self.collapseEndpointsForSamePc(preferredId: endpoint.id)
            }
        }
    }

    private func collapseEndpointsForSamePc(preferredId: String? = nil) {
        func score(_ ep: DiscoveredPcEndpoint) -> Int {
            switch ep.source {
            case "UDP Probe": return 4
            case "Wi-Fi Beacon": return 3
            case "BLE GATT": return 2
            case "BLE": return 1
            default: return 0
            }
        }
        var bestByKey: [String: DiscoveredPcEndpoint] = [:]
        for ep in discoveredEndpoints {
            let key = "\(ep.name.lowercased())|\(ep.port)"
            if let cur = bestByKey[key] {
                let better = score(ep) > score(cur) || (score(ep) == score(cur) && ep.id == preferredId)
                if better {
                    lastSeenTimestamps.removeValue(forKey: cur.id)
                    bestByKey[key] = ep
                } else {
                    lastSeenTimestamps.removeValue(forKey: ep.id)
                }
            } else {
                bestByKey[key] = ep
            }
        }
        discoveredEndpoints = Array(bestByKey.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func startStaleEndpointPruneTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let beforeCount = self.discoveredEndpoints.count
            self.discoveredEndpoints.removeAll { ep in
                guard let last = self.lastSeenTimestamps[ep.id] else { return true }
                return (now - last) > 4.2
            }
            if beforeCount > 0 && self.discoveredEndpoints.isEmpty {
                self.bluetoothStateText = "Searching for PC on Local Network..."
            }
        }
        pruneTimer = timer
        timer.resume()
    }

    // MARK: - UDP LAN Broadcast Beacon Listener (Port 49153)

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
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

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
                var senderAddr = sockaddr_in()
                var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let bytesRead = withUnsafeMutablePointer(to: &senderAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                        recvfrom(fd, &buffer, buffer.count, 0, addrPtr, &senderLen)
                    }
                }
                if bytesRead > 0 {
                    let data = Data(bytes: buffer, count: bytesRead)
                    if let message = String(data: data, encoding: .utf8),
                       message.hasPrefix("AS_BEACON|") {
                        let comps = message.split(separator: "|")
                        if comps.count >= 4, let port = UInt16(comps[2]) {
                            var ip = String(comps[1])
                            let name = String(comps[3])

                            // Prefer packet source IP if valid private IPv4
                            var ipCString = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                            var addrCopy = senderAddr.sin_addr
                            if inet_ntop(AF_INET, &addrCopy, &ipCString, socklen_t(INET_ADDRSTRLEN)) != nil {
                                let pktIp = String(cString: ipCString)
                                if !pktIp.isEmpty && pktIp != "0.0.0.0" && pktIp != "127.0.0.1" {
                                    ip = pktIp
                                }
                            }

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
