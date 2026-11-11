import Foundation
@preconcurrency import CoreBluetooth
import Accelerate

let DeviceInformation = CBUUID(string:"180A")
let ManufacturerName = CBUUID(string:"2A29")
let ModelName = CBUUID(string:"2A24")
let ExposureNotification = CBUUID(string:"FD6F")

func getMACFromUUID(_ uuid: String) -> String? {
    guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist") else { return nil }
    guard let cbcache = plist["CoreBluetoothCache"] as? NSDictionary else { return nil }
    guard let device = cbcache[uuid] as? NSDictionary else { return nil }
    return device["DeviceAddress"] as? String
}

func getNameFromMAC(_ mac: String) -> String? {
    guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist") else { return nil }
    guard let devcache = plist["DeviceCache"] as? NSDictionary else { return nil }
    guard let device = devcache[mac] as? NSDictionary else { return nil }
    if let name = device["Name"] as? String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed == "" { return nil }
        return trimmed
    }
    return nil
}

@MainActor
class Device: NSObject {
    let uuid : UUID!
    var peripheral : CBPeripheral?
    var manufacture : String?
    var model : String?
    var advData: Data?
    var rssi: Int = 0
    var scanTimer: Timer?
    var macAddr: String?
    var blName: String?
    var localName: String?
    
    override var description: String {
        get {
            if macAddr == nil || blName == nil {
                if let info = getLEDeviceInfoFromUUID(uuid.description) {
                    if let name = info.name { blName = name }
                    if let mac = info.macAddr { macAddr = mac }
                }
            }
            if let pName = peripheral?.name {
                if blName == nil || (blName == "iPhone" || blName == "iPad") {
                    blName = pName
                }
            }
            if macAddr == nil {
                macAddr = getMACFromUUID(uuid.description)
            }
            if let mac = macAddr {
                if blName == nil {
                    blName = getNameFromMAC(mac)
                }
                if let name = blName {
                    if name != "iPhone" && name != "iPad" {
                        return name
                    }
                }
            }
            if let name = localName, name.count > 0, name != "iPhone" && name != "iPad" {
                return name
            }
            if let pName = peripheral?.name, pName.count > 0, pName != "iPhone" && pName != "iPad" {
                return pName
            }
            if let manu = manufacture {
                if let mod = model {
                    if manu == "Apple Inc." && appleDeviceNames[mod] != nil {
                        return appleDeviceNames[mod]!
                    }
                    return String(format: "%@/%@", manu, mod)
                } else {
                    return manu
                }
            }
            if let name = peripheral?.name, name.count > 0 {
                return name
            }
            if let mod = model {
                return mod
            }
            // iBeacon
            if let adv = advData {
                if adv.count >= 25 {
                    var iBeaconPrefix : [uint16] = [0x004c, 0x01502]
                    if adv[0...3] == Data(bytes: &iBeaconPrefix, count: 4) {
                        let major = uint16(adv[20]) << 8 | uint16(adv[21])
                        let minor = uint16(adv[22]) << 8 | uint16(adv[23])
                        let tx = Int8(bitPattern: adv[24])
                        let distance = pow(10, Double(Int(tx) - rssi)/20.0)
                        let d = String(format:"%.1f", distance)
                        return "iBeacon [\(major), \(minor)] \(d)m"
                    }
                }
            }
            if let name = blName {
                return name
            }
            if let mac = macAddr {
                return mac // better than uuid
            }
            return uuid.description
        }
    }

    init(uuid _uuid: UUID) {
        uuid = _uuid
    }
}

@MainActor
protocol BLEDelegate: AnyObject {
    func newDevice(device: Device)
    func updateDevice(device: Device)
    func removeDevice(device: Device)
    func updateRSSI(rssi: Int?, active: Bool, uuid: UUID)
    func updatePresence(presence: Bool, reason: String, deviceUUID: UUID?)
    func updateCountdown(seconds: Int, reason: String)
    func cancelCountdown(reason: String)
    func bluetoothPowerWarn()
}

@MainActor
class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let LOCK_DISABLED = -100
    var centralMgr : CBCentralManager!
    var devices : [UUID : Device] = [:]
    weak var delegate: BLEDelegate?
    var scanMode = false
    var monitoredUUIDs: Set<UUID> = []
    var monitoredPeripherals: [UUID: CBPeripheral] = [:]
    var proximityTimers : [UUID: Timer] = [:]
    var signalTimers: [UUID: Timer] = [:]
    var presenceMap: [UUID: Bool] = [:]
    var lockRSSI = -80
    var proximityTimeout = 5.0
    var signalTimeout = 60.0
    var powerWarn = true
    var passiveMode = false
    var thresholdRSSI = -70
    var latestRSSIs: [UUID: [Double]] = [:]
    var latestN: Int = 5
    var activeModeTimers : [UUID: Timer] = [:]
    var connectionTimers : [UUID: Timer] = [:]
    var lastReadAtMap: [UUID: Double] = [:]
    var seenDevices: Set<UUID> = []
    var noConnectUUIDs: Set<UUID> = []
    var suspended = false
    var lastConnectAttemptAt: [UUID: Double] = [:]
    var connectCooldownUntil: [UUID: Double] = [:]
    var watchdogTimer: Timer?

    func shouldAllowDuplicateAdvertisements() -> Bool {
        return scanMode || passiveMode || !noConnectUUIDs.isEmpty
    }

    func markAsNoConnect(uuid: UUID, reason: String) {
        if noConnectUUIDs.insert(uuid).inserted {
            print("Disable active connect for \(uuid): \(reason)")
            restartScanningIfNeeded()
        }
        connectCooldownUntil[uuid] = Date().timeIntervalSince1970 + 300
        if let timer = activeModeTimers[uuid] {
            timer.invalidate()
            activeModeTimers.removeValue(forKey: uuid)
        }
        if let timer = connectionTimers[uuid] {
            timer.invalidate()
            connectionTimers.removeValue(forKey: uuid)
        }
    }

    func restartScanningIfNeeded() {
        guard centralMgr.state == .poweredOn else { return }
        if centralMgr.isScanning {
            centralMgr.stopScan()
        }
        let allowDuplicates = shouldAllowDuplicateAdvertisements()
        centralMgr.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates])
    }

    func shouldAvoidConnecting(peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        if let mfgData = advertisementData["kCBAdvDataManufacturerData"] as? Data, mfgData.count >= 2 {
            let b0 = mfgData[mfgData.startIndex]
            let b1 = mfgData[mfgData.startIndex + 1]
            // Apple company identifier: 0x004C (little-endian in advertisement payload)
            if (b0 == 0x4c && b1 == 0x00) || (b0 == 0x00 && b1 == 0x4c) {
                return true
            }
        }
        let candidateNames: [String] = [
            peripheral.name,
            advertisementData["kCBAdvDataLocalName"] as? String
        ].compactMap { $0 }
        for name in candidateNames {
            let normalized = name.lowercased()
            if normalized.contains("iphone") || normalized.contains("ipad") {
                return true
            }
        }
        return false
    }

    func scanForPeripherals() {
        guard !suspended else { return }
        guard centralMgr.state == .poweredOn else { return }
        guard !centralMgr.isScanning else { return }
        let allowDuplicates = shouldAllowDuplicateAdvertisements()
        centralMgr.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates])
    }

    func startScanning() {
        scanMode = true
        scanForPeripherals()
    }

    func stopScanning() {
        scanMode = false
        if !monitoredUUIDs.isEmpty && !suspended {
            // 仅关闭扫描模式，但保持监控扫描运行
            restartScanningIfNeeded()
        } else {
            centralMgr.stopScan()
        }
    }

    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        if suspended {
            centralMgr.stopScan()
            watchdogTimer?.invalidate()
            watchdogTimer = nil
            for timer in proximityTimers.values { timer.invalidate() }
            for timer in signalTimers.values { timer.invalidate() }
            for timer in activeModeTimers.values { timer.invalidate() }
            for timer in connectionTimers.values { timer.invalidate() }
            proximityTimers.removeAll()
            signalTimers.removeAll()
            activeModeTimers.removeAll()
            connectionTimers.removeAll()
            for (_, p) in monitoredPeripherals { centralMgr.cancelPeripheralConnection(p) }
            delegate?.cancelCountdown(reason: "lost")
        } else {
            scanForPeripherals()
            startWatchdog()
            if !monitoredUUIDs.isEmpty {
                startMonitor(uuids: monitoredUUIDs)
            }
        }
    }

    func setPassiveMode(_ mode: Bool) {
        passiveMode = mode
        if passiveMode {
            for (_, timer) in activeModeTimers { timer.invalidate() }
            activeModeTimers.removeAll()
            for (_, p) in monitoredPeripherals { centralMgr.cancelPeripheralConnection(p) }
            for (_, timer) in connectionTimers { timer.invalidate() }
            connectionTimers.removeAll()
            monitoredPeripherals.removeAll()
            // Passive 模式下不启用掉线计时，避免频繁锁定
            for (_, timer) in signalTimers { timer.invalidate() }
            signalTimers.removeAll()
            for uuid in monitoredUUIDs {
                presenceMap[uuid] = true
            }
        }
        restartScanningIfNeeded()
    }

    func startMonitor(uuids: Set<UUID>) {
        // Cancel connections and timers for devices no longer monitored
        let removed = monitoredUUIDs.subtracting(uuids)
        for uuid in removed {
            if let p = monitoredPeripherals[uuid] {
                centralMgr.cancelPeripheralConnection(p)
            }
            activeModeTimers[uuid]?.invalidate()
            proximityTimers[uuid]?.invalidate()
            signalTimers[uuid]?.invalidate()
            connectionTimers[uuid]?.invalidate()
            activeModeTimers.removeValue(forKey: uuid)
            proximityTimers.removeValue(forKey: uuid)
            signalTimers.removeValue(forKey: uuid)
            connectionTimers.removeValue(forKey: uuid)
            presenceMap.removeValue(forKey: uuid)
            latestRSSIs.removeValue(forKey: uuid)
            lastReadAtMap.removeValue(forKey: uuid)
            noConnectUUIDs.remove(uuid)
            lastConnectAttemptAt.removeValue(forKey: uuid)
            connectCooldownUntil.removeValue(forKey: uuid)
        }

        monitoredUUIDs = uuids
        noConnectUUIDs = noConnectUUIDs.intersection(uuids)

        // Initialize state for newly added devices
        for uuid in monitoredUUIDs {
            presenceMap[uuid] = presenceMap[uuid] ?? false
            seenDevices.remove(uuid)
        }

        restartScanningIfNeeded()
    }

    func resetSignalTimer(uuid: UUID) {
        guard !passiveMode else { return }
        guard seenDevices.contains(uuid) else { return }
        signalTimers[uuid]?.invalidate()
        var counter: Double = 0
        signalTimers[uuid] = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true, block: { [weak self] timer in
            guard let self = self else { return }
            MainActor.assumeIsolated {
                counter += 1.0
                let remaining = self.signalTimeout - counter
                
                if remaining <= 0 {
                    print("Device is lost: \(uuid)")
                    self.delegate?.updateRSSI(rssi: nil, active: false, uuid: uuid)
                    timer.invalidate()
                    self.signalTimers.removeValue(forKey: uuid)
                    let wasPresent = self.presenceMap.updateValue(false, forKey: uuid) == true
                    self.evaluatePresence(reason: "lost", lostUUID: uuid, wasPresent: wasPresent)
                }
            }
        })
        if let timer = signalTimers[uuid] {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                print("Bluetooth powered on")
                if suspended {
                    break
                }
                scanForPeripherals()
                if !monitoredUUIDs.isEmpty {
                    startMonitor(uuids: monitoredUUIDs)
                }
                powerWarn = false
            case .poweredOff:
                print("Bluetooth powered off")
                for timer in proximityTimers.values { timer.invalidate() }
                for timer in signalTimers.values { timer.invalidate() }
                for timer in activeModeTimers.values { timer.invalidate() }
                for timer in connectionTimers.values { timer.invalidate() }
                proximityTimers.removeAll()
                signalTimers.removeAll()
                activeModeTimers.removeAll()
                connectionTimers.removeAll()
                for (_, p) in monitoredPeripherals { centralMgr.cancelPeripheralConnection(p) }
                presenceMap = monitoredUUIDs.reduce(into: [:]) { $0[$1] = false }
                delegate?.cancelCountdown(reason: "lost")
                evaluatePresence(reason: "lost", lostUUID: nil)
                if powerWarn {
                    powerWarn = false
                    delegate?.bluetoothPowerWarn()
                }
            default:
                break
            }
        }
    }
    
    func getEstimatedRSSI(uuid: UUID, rssi: Int) -> Int {
        if latestRSSIs[uuid] == nil {
            latestRSSIs[uuid] = []
        }
        if latestRSSIs[uuid]!.count >= latestN {
            latestRSSIs[uuid]!.removeFirst()
        }
        latestRSSIs[uuid]!.append(Double(rssi))
        var mean: Double = 0.0
        var sddev: Double = 0.0
        vDSP_normalizeD(latestRSSIs[uuid]!, 1, nil, 1, &mean, &sddev, vDSP_Length(latestRSSIs[uuid]!.count))
        return Int(mean)
    }

    func evaluatePresence(reason: String, lostUUID: UUID?, wasPresent: Bool = false) {
        guard !passiveMode else { return }
        // The device that just left can be the only one we had confirmed nearby.
        let lostDeviceWasPresent = lostUUID.map { monitoredUUIDs.contains($0) && wasPresent } ?? false
        let anySeenPresent = monitoredUUIDs.contains { seenDevices.contains($0) && presenceMap[$0] == true }
        let allPresent = monitoredUUIDs.allSatisfy { uuid in
            if !seenDevices.contains(uuid) { return true }
            return presenceMap[uuid] == true
        }
        let lost = lostUUID ?? monitoredUUIDs.first(where: { seenDevices.contains($0) && presenceMap[$0] != true })
        let hadPresentDevice = lostDeviceWasPresent || anySeenPresent
        delegate?.updatePresence(presence: allPresent || !hadPresentDevice, reason: reason, deviceUUID: lost)
    }

    func updateMonitoredPeripheral(uuid: UUID, rssi: Int) {
        // print(String(format: "rssi: %d", rssi))
        // Use lockRSSI + 15 as hysteresis for presence detection
        let presenceThreshold = lockRSSI == LOCK_DISABLED ? -65 : (lockRSSI + 15)

        if !seenDevices.contains(uuid) {
            seenDevices.insert(uuid)
            resetSignalTimer(uuid: uuid)
        }

        if passiveMode {
            presenceMap[uuid] = true
            delegate?.updateRSSI(rssi: getEstimatedRSSI(uuid: uuid, rssi: rssi), active: false, uuid: uuid)
            return
        }

        if rssi >= presenceThreshold && presenceMap[uuid] != true {
            print("Device is close: \(uuid)")
            presenceMap[uuid] = true
            latestRSSIs[uuid]?.removeAll()
            evaluatePresence(reason: "close", lostUUID: nil)
        }

        let estimatedRSSI = getEstimatedRSSI(uuid: uuid, rssi: rssi)
        delegate?.updateRSSI(rssi: estimatedRSSI, active: activeModeTimers[uuid] != nil, uuid: uuid)

        if estimatedRSSI >= presenceThreshold {
            if let timer = proximityTimers[uuid] {
                timer.invalidate()
                proximityTimers.removeValue(forKey: uuid)
                print("Proximity timer canceled: \(uuid)")
                delegate?.cancelCountdown(reason: "away")
            }
        } else if presenceMap[uuid] == true && proximityTimers[uuid] == nil && estimatedRSSI < lockRSSI {
            var proximityCounter: Double = 0
            proximityTimers[uuid] = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true, block: { [weak self] timer in
                guard let self = self else { return }
                MainActor.assumeIsolated {
                    proximityCounter += 1.0
                    let remaining = self.proximityTimeout - proximityCounter
                    
                    if remaining <= 0 {
                        print("Device is away: \(uuid)")
                        let wasPresent = self.presenceMap.updateValue(false, forKey: uuid) == true
                        self.proximityTimers.removeValue(forKey: uuid)
                        timer.invalidate()
                        self.evaluatePresence(reason: "away", lostUUID: uuid, wasPresent: wasPresent)
                    } else {
                        // Start notification only after 5 seconds of being away
                        if proximityCounter >= 5.0 {
                            self.delegate?.updateCountdown(seconds: Int(remaining), reason: "away")
                        }
                    }
                }
            })
            if let timer = proximityTimers[uuid] {
                RunLoop.main.add(timer, forMode: .common)
            }
            print("Proximity timer started: \(uuid)")
        }
        resetSignalTimer(uuid: uuid)
    }

    func resetScanTimer(device: Device) {
        device.scanTimer?.invalidate()
        device.scanTimer = Timer.scheduledTimer(withTimeInterval: signalTimeout, repeats: false, block: { _ in
            MainActor.assumeIsolated {
                // 在被动模式下，不移除设备以便列表保持可见
                if self.passiveMode { return }
                self.delegate?.removeDevice(device: device)
                if let p = device.peripheral {
                    self.centralMgr.cancelPeripheralConnection(p)
                }
                self.devices.removeValue(forKey: device.uuid)
            }
        })
        if let timer = device.scanTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func connectMonitoredPeripheral(uuid: UUID) {
        guard !passiveMode else { return }
        guard !suspended else { return }
        guard !noConnectUUIDs.contains(uuid) else { return }
        guard let p = monitoredPeripherals[uuid] else { return }
        let now = Date().timeIntervalSince1970
        if let cooldown = connectCooldownUntil[uuid], now < cooldown {
            return
        }
        if let lastAttempt = lastConnectAttemptAt[uuid], now < lastAttempt + 6 {
            return
        }

        guard p.state == .disconnected && centralMgr.state == .poweredOn else { return }
        lastConnectAttemptAt[uuid] = now
        print("Connecting \(uuid)")
        centralMgr.connect(p, options: nil)
        connectionTimers[uuid]?.invalidate()
        connectionTimers[uuid] = Timer.scheduledTimer(withTimeInterval: 60, repeats: false, block: { _ in
            MainActor.assumeIsolated {
                if let p = self.centralMgr.retrievePeripherals(withIdentifiers: [uuid]).first {
                    if p.state == .connecting {
                        print("Connection timeout \(uuid)")
                        self.centralMgr.cancelPeripheralConnection(p)
                    }
                }
            }
        })
        if let timer = connectionTimers[uuid] {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    //MARK:- CBCentralManagerDelegate start

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber)
    {
        MainActor.assumeIsolated {
            guard !suspended else { return }
            let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
            if monitoredUUIDs.contains(peripheral.identifier) {
                let uuid = peripheral.identifier
                monitoredPeripherals[uuid] = peripheral

                let avoidConnect = shouldAvoidConnecting(peripheral: peripheral, advertisementData: advertisementData)
                if avoidConnect {
                    markAsNoConnect(uuid: uuid, reason: "iPhone/iPad")
                } else if noConnectUUIDs.remove(uuid) != nil {
                    restartScanningIfNeeded()
                }

                if activeModeTimers[uuid] == nil {
                    updateMonitoredPeripheral(uuid: uuid, rssi: rssi)
                    if !passiveMode {
                        connectMonitoredPeripheral(uuid: uuid)
                    }
                }
            }

            if (scanMode) {
                if let uuids = advertisementData["kCBAdvDataServiceUUIDs"] as? [CBUUID] {
                    for uuid in uuids {
                        if uuid == ExposureNotification {
                            //print("Device \(peripheral.identifier) Exposure Notification")
                            return
                        }
                    }
                }
                let dev = devices[peripheral.identifier]
                var device: Device
                if (dev == nil) {
                    device = Device(uuid: peripheral.identifier)
                    if (rssi >= thresholdRSSI) {
                        device.peripheral = peripheral
                        device.rssi = rssi
                        device.advData = advertisementData["kCBAdvDataManufacturerData"] as? Data
                        if let lName = advertisementData["kCBAdvDataLocalName"] as? String {
                            device.localName = lName
                        }
                        devices[peripheral.identifier] = device
                        delegate?.newDevice(device: device)
                    }
                } else {
                    device = dev!
                    device.rssi = rssi
                    delegate?.updateDevice(device: device)
                }
                resetScanTimer(device: device)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral)
    {
        MainActor.assumeIsolated {
            peripheral.delegate = self
            if scanMode {
                peripheral.discoverServices([DeviceInformation])
            }
            if monitoredUUIDs.contains(peripheral.identifier) {
                if passiveMode {
                    centralMgr.cancelPeripheralConnection(peripheral)
                } else {
                    print("Connected \(peripheral.identifier)")
                    connectionTimers[peripheral.identifier]?.invalidate()
                    connectionTimers[peripheral.identifier] = nil
                    connectCooldownUntil[peripheral.identifier] = Date().timeIntervalSince1970 + 4
                    peripheral.readRSSI()
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?)
    {
        MainActor.assumeIsolated {
            guard monitoredUUIDs.contains(peripheral.identifier) else { return }
            print("Failed to connect \(peripheral.identifier): \(error?.localizedDescription ?? "unknown")")
            markAsNoConnect(uuid: peripheral.identifier, reason: "connect-failed")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?)
    {
        MainActor.assumeIsolated {
            guard monitoredUUIDs.contains(peripheral.identifier) else { return }
            if error != nil {
                markAsNoConnect(uuid: peripheral.identifier, reason: "disconnect-error")
            } else {
                connectCooldownUntil[peripheral.identifier] = Date().timeIntervalSince1970 + 8
            }
        }
    }

    //MARK:CBCentralManagerDelegate end -
    
    //MARK:- CBPeripheralDelegate start

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated {
            guard monitoredUUIDs.contains(peripheral.identifier) else { return }
            let rssi = RSSI.intValue > 0 ? 0 : RSSI.intValue
            //print("readRSSI \(rssi)dBm")
            updateMonitoredPeripheral(uuid: peripheral.identifier, rssi: rssi)
            lastReadAtMap[peripheral.identifier] = Date().timeIntervalSince1970

            if activeModeTimers[peripheral.identifier] == nil && !passiveMode {
                print("Entering active mode \(peripheral.identifier)")
                if !scanMode {
                    centralMgr.stopScan()
                }
                let uuid = peripheral.identifier
                activeModeTimers[uuid] = Timer.scheduledTimer(withTimeInterval: 2, repeats: true, block: { _ in
                    MainActor.assumeIsolated {
                        guard let peripheral = self.centralMgr.retrievePeripherals(withIdentifiers: [uuid]).first else { return }
                        if let lastRead = self.lastReadAtMap[uuid], Date().timeIntervalSince1970 > lastRead + 10 {
                            print("Falling back to passive mode \(uuid)")
                            self.centralMgr.cancelPeripheralConnection(peripheral)
                            self.activeModeTimers[uuid]?.invalidate()
                            self.activeModeTimers.removeValue(forKey: uuid)
                            self.scanForPeripherals()
                        } else if peripheral.state == .connected {
                            peripheral.readRSSI()
                        } else {
                            self.connectMonitoredPeripheral(uuid: uuid)
                        }
                    }
                })
                if let timer = activeModeTimers[uuid] {
                    RunLoop.main.add(timer, forMode: .common)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let services = peripheral.services {
                for service in services {
                    if service.uuid == DeviceInformation {
                        peripheral.discoverCharacteristics([ManufacturerName, ModelName], for: service)
                    }
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?)
    {
        MainActor.assumeIsolated {
            if let chars = service.characteristics {
                for chara in chars {
                    if chara.uuid == ManufacturerName || chara.uuid == ModelName {
                        peripheral.readValue(for:chara)
                    }
                }
            }
        }
    }
    
    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?)
    {
        MainActor.assumeIsolated {
            if let value = characteristic.value {
                let str: String? = String(data: value, encoding: .utf8)
                if let s = str {
                    if let device = devices[peripheral.identifier] {
                        if characteristic.uuid == ManufacturerName {
                            device.manufacture = s
                            delegate?.updateDevice(device: device)
                        }
                        if characteristic.uuid == ModelName {
                            device.model = s
                            delegate?.updateDevice(device: device)
                        }
                        if device.model != nil && !monitoredUUIDs.contains(peripheral.identifier) {
                            centralMgr.cancelPeripheralConnection(peripheral)
                        }
                    }
                }
            }
        }
    }
    
    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didModifyServices invalidatedServices: [CBService])
    {
        MainActor.assumeIsolated {
            peripheral.discoverServices([DeviceInformation])
        }
    }
    //MARK:CBPeripheralDelegate end -

    // MARK: - Watchdog

    func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true, block: { [weak self] _ in
            guard let self = self else { return }
            MainActor.assumeIsolated {
                self.watchdogCheck()
            }
        })
        if let timer = watchdogTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func watchdogCheck() {
        guard !suspended else { return }
        guard centralMgr.state == .poweredOn else { return }
        guard !monitoredUUIDs.isEmpty else { return }

        if !centralMgr.isScanning {
            print("[Watchdog] Scan not running, restarting...")
            let allowDuplicates = shouldAllowDuplicateAdvertisements()
            centralMgr.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates])
        }
    }

    override init() {
        super.init()
        centralMgr = CBCentralManager(delegate: self, queue: nil)
        startWatchdog()
    }
}
