import Foundation
@preconcurrency import CoreBluetooth

private let DeviceInformation = CBUUID(string: "180A")
private let ManufacturerName = CBUUID(string: "2A29")
private let ModelName = CBUUID(string: "2A24")
private let ExposureNotification = CBUUID(string: "FD6F")

@MainActor
class Device: NSObject {
    let uuid: UUID
    var peripheral : CBPeripheral?
    var manufacture : String?
    var model : String?
    var advData: Data?
    var rssi: Int = 0
    fileprivate var lastSeenAt: TimeInterval = 0
    var macAddr: String?
    var blName: String?
    var localName: String?
    private(set) var isPaired = false

    fileprivate func refreshIdentity(using lookup: BluetoothDeviceLookup) {
        let info = lookup.info(for: uuid)
        isPaired = info.isPaired
        macAddr = info.macAddr
        blName = info.name
    }

    override var description: String {
        get {
            if let pName = peripheral?.name {
                if blName == nil || (blName == "iPhone" || blName == "iPad") {
                    blName = pName
                }
            }
            if let name = blName, name != "iPhone", name != "iPad" {
                return name
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
    func deviceDiscovered(_ device: Device)
    func monitoringDidChange()
    func deviceDidLeave(_ uuid: UUID, reason: String)
}

@MainActor
class BLE: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private enum ScanPhase: Equatable {
        case continuous
        case sampling(startedAt: TimeInterval, window: TimeInterval)
        case waiting(window: TimeInterval)
    }

    private static let sampledRounds = 3

    private struct AdvertisementTiming {
        private var gaps: [(second: TimeInterval, longest: TimeInterval)] = []

        mutating func record(gap: TimeInterval, at time: TimeInterval) {
            let second = floor(time)
            if let index = gaps.indices.last, gaps[index].second == second {
                gaps[index].longest = max(gaps[index].longest, gap)
            } else {
                gaps.removeAll { $0.second < second - 60 }
                gaps.append((second, gap))
            }
        }

        func window(at time: TimeInterval) -> TimeInterval {
            let longestGap = gaps.lazy.filter { $0.second >= time - 61 }.map(\.longest).max() ?? 0
            return max(2, 2 * longestGap)
        }

        func isCalibrated(at time: TimeInterval) -> Bool {
            gaps.count >= 5 && gaps[gaps.count - 5].second >= time - 61
        }
    }

    private struct Confirmation {
        let startedAt: TimeInterval
        let window: TimeInterval
        var failedSamples = 0
        var weakSince: TimeInterval?
    }

    let LOCK_DISABLED = -100
    private let discoveryLifetime = 60.0
    var centralMgr: CBCentralManager!
    private(set) var devices: [UUID: Device] = [:]
    private var discoveryExpiryTimer: Timer?
    private var deviceLookup = BluetoothDeviceLookup()
    weak var delegate: BLEDelegate?
    private var scanMode = false
    private(set) var monitoredUUIDs: Set<UUID> = []
    private(set) var nearbyUUIDs: Set<UUID> = []
    private(set) var monitoredRSSI: [UUID: Int] = [:]
    private(set) var suspended = false
    private(set) var screenLocked = false
    private(set) var isMonitoring = false
    var lockRSSI = -70 {
        didSet {
            guard lockRSSI != oldValue else { return }
            nearbyUUIDs.removeAll()
            monitoredRSSI.removeAll()
            latestRSSIs.removeAll()
            lastSignals.removeAll()
            confirmations.removeAll()
            clearSampling()
            refreshMonitoring()
        }
    }
    var confirmationTime = 10.0 {
        didSet {
            if confirmationTime != oldValue {
                resumeContinuousScanning()
            }
        }
    }
    private(set) var secondsUntilLock: Int?

    private var monitoredPeripherals: [UUID: CBPeripheral] = [:]
    private var lastSignals: [UUID: TimeInterval] = [:]
    private var confirmations: [UUID: Confirmation] = [:]
    private var confirmationTimer: Timer?
    private var latestRSSIs: [UUID: [Int]] = [:]
    private let latestN = 5
    private var activeModeTimers: [UUID: Timer] = [:]
    private var connectionTimers: [UUID: Timer] = [:]
    private var lastReadAtMap: [UUID: Double] = [:]
    private var noConnectUUIDs: Set<UUID> = []
    private var lastConnectAttemptAt: [UUID: Double] = [:]
    private var connectCooldownUntil: [UUID: Double] = [:]
    private var watchdogTimer: Timer?
    private var scanAllowsDuplicates = false
    private var scanPhase = ScanPhase.continuous
    private var scanPhaseTimer: Timer?
    private var scanStartedAt: TimeInterval?
    private var qualifiedInWindow: Set<UUID> = []
    private var advertisementTimings: [UUID: AdvertisementTiming] = [:]

    private var canScan: Bool {
        !suspended && !screenLocked && centralMgr.state == .poweredOn
    }

    private var shouldScan: Bool {
        if case .waiting = scanPhase { return canScan && scanMode }
        return canScan && (scanMode || isMonitoring)
    }

    private var advertisementTargets: Set<UUID> {
        monitoredUUIDs.filter { lastReadAtMap[$0] == nil }
    }

    private var nearbyThreshold: Int { lockRSSI + 15 }

    private func monitorAdvertisements(uuid: UUID, retryAfter: TimeInterval? = nil) {
        let switched = noConnectUUIDs.insert(uuid).inserted
        if switched || retryAfter == nil {
            connectCooldownUntil[uuid] = retryAfter.map { Date().timeIntervalSince1970 + $0 }
        }
        guard switched else { return }
        activeModeTimers.removeValue(forKey: uuid)?.invalidate()
        connectionTimers.removeValue(forKey: uuid)?.invalidate()
        lastReadAtMap.removeValue(forKey: uuid)
        if let peripheral = monitoredPeripherals[uuid], peripheral.state != .disconnected {
            centralMgr.cancelPeripheralConnection(peripheral)
        }
        resumeContinuousScanning()
    }

    private func updateScanning() {
        guard centralMgr.state == .poweredOn else {
            scanStartedAt = nil
            return
        }
        // Advertisements supply RSSI until every monitored device has an active reading.
        let allowDuplicates = scanMode || (isMonitoring && !advertisementTargets.isEmpty)
        if centralMgr.isScanning {
            guard !shouldScan || allowDuplicates != scanAllowsDuplicates else { return }
            centralMgr.stopScan()
        }
        scanStartedAt = nil
        guard shouldScan else { return }
        scanAllowsDuplicates = allowDuplicates
        centralMgr.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates])
        scanStartedAt = ProcessInfo.processInfo.systemUptime
    }

    func shouldAvoidConnecting(peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        if advertisementData[CBAdvertisementDataIsConnectable] as? Bool == false {
            return true
        }
        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mfgData.count >= 2 {
            let b0 = mfgData[mfgData.startIndex]
            let b1 = mfgData[mfgData.startIndex + 1]
            // Apple company identifier: 0x004C (little-endian in advertisement payload)
            if (b0 == 0x4c && b1 == 0x00) || (b0 == 0x00 && b1 == 0x4c) {
                return true
            }
        }
        let candidateNames: [String] = [
            peripheral.name,
            advertisementData[CBAdvertisementDataLocalNameKey] as? String
        ].compactMap { $0 }
        for name in candidateNames {
            let normalized = name.lowercased()
            if normalized.contains("iphone") || normalized.contains("ipad") {
                return true
            }
        }
        return false
    }

    func startScanning() {
        scanMode = true
        resumeContinuousScanning()
    }

    func refreshDeviceIdentities() {
        deviceLookup = BluetoothDeviceLookup()
        for device in devices.values {
            device.refreshIdentity(using: deviceLookup)
        }
    }

    func deviceInfo(for uuid: UUID) -> LEDeviceInfo {
        deviceLookup.info(for: uuid)
    }

    func stopScanning() {
        scanMode = false
        updateScanning()
        checkConfirmations()
    }

    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        if value { scanMode = false }
        refreshMonitoring()
    }

    func setScreenLocked(_ value: Bool) {
        guard screenLocked != value else { return }
        screenLocked = value
        if value { scanMode = false }
        refreshMonitoring()
    }

    func startMonitor(uuids: Set<UUID>) {
        let removed = monitoredUUIDs.subtracting(uuids)
        monitoredUUIDs = uuids
        for uuid in removed {
            resetMonitoring(for: uuid)
        }
        refreshMonitoring(restartScan: true)
    }

    private func refreshMonitoring(restartScan: Bool = false) {
        let shouldMonitor = canScan && lockRSSI != LOCK_DISABLED && !monitoredUUIDs.isEmpty
        if isMonitoring != shouldMonitor {
            isMonitoring = shouldMonitor
            if shouldMonitor {
                startWatchdog()
            } else {
                clearSampling()
                scheduleConfirmationCheck(at: nil)
                secondsUntilLock = nil
                watchdogTimer?.invalidate()
                watchdogTimer = nil
                for uuid in monitoredUUIDs {
                    resetMonitoring(for: uuid)
                }
            }
        }
        if !canScan {
            discoveryExpiryTimer?.invalidate()
            discoveryExpiryTimer = nil
            devices.removeAll()
        }
        if restartScan, isMonitoring {
            resumeContinuousScanning()
        } else {
            updateScanning()
        }
        checkConfirmations()
        delegate?.monitoringDidChange()
    }

    private func resetMonitoring(for uuid: UUID) {
        confirmations.removeValue(forKey: uuid)
        lastSignals.removeValue(forKey: uuid)
        activeModeTimers.removeValue(forKey: uuid)?.invalidate()
        connectionTimers.removeValue(forKey: uuid)?.invalidate()
        if let peripheral = monitoredPeripherals.removeValue(forKey: uuid), centralMgr.state == .poweredOn {
            centralMgr.cancelPeripheralConnection(peripheral)
        }
        nearbyUUIDs.remove(uuid)
        monitoredRSSI.removeValue(forKey: uuid)
        latestRSSIs.removeValue(forKey: uuid)
        lastReadAtMap.removeValue(forKey: uuid)
        advertisementTimings.removeValue(forKey: uuid)
        noConnectUUIDs.remove(uuid)
        lastConnectAttemptAt.removeValue(forKey: uuid)
        connectCooldownUntil.removeValue(forKey: uuid)
    }

    private func clearSampling() {
        scanPhaseTimer?.invalidate()
        scanPhaseTimer = nil
        scanPhase = .continuous
        qualifiedInWindow.removeAll()
    }

    private func resumeContinuousScanning() {
        let previousPhase = scanPhase
        clearSampling()
        updateScanning()
        if case .sampling = previousPhase, centralMgr.isScanning {
            // The uninterrupted confirmation starts when we leave the sampled phase.
            scanStartedAt = ProcessInfo.processInfo.systemUptime
        }
        if previousPhase != .continuous {
            for uuid in advertisementTargets {
                latestRSSIs.removeValue(forKey: uuid)
            }
            NSLog("AwayLatch: Resumed continuous scanning")
        }
        // Re-evaluate after the current Bluetooth callback finishes processing its reading.
        scheduleConfirmationCheck(at: ProcessInfo.processInfo.systemUptime)
    }

    private func isStableNearby(_ uuid: UUID) -> Bool {
        guard nearbyUUIDs.contains(uuid), let rssi = monitoredRSSI[uuid] else { return false }
        return rssi >= nearbyThreshold
    }

    private func windowLength(for uuid: UUID, at time: TimeInterval) -> TimeInterval {
        advertisementTimings[uuid]?.window(at: time) ?? 2
    }

    private var samplingInterval: TimeInterval {
        confirmationTime / Double(Self.sampledRounds + 1)
    }

    private func considerSampling(at now: TimeInterval) {
        guard !scanMode, scanPhase == .continuous, let scanStartedAt,
              now - scanStartedAt >= 15, confirmations.isEmpty else { return }
        let targets = advertisementTargets
        guard !targets.isEmpty, targets.isSubset(of: noConnectUUIDs), monitoredUUIDs.allSatisfy(isStableNearby),
              targets.allSatisfy({ advertisementTimings[$0]?.isCalibrated(at: now) == true }) else { return }
        let window = targets.map { windowLength(for: $0, at: now) }.max() ?? 2
        // The last two segments must fit the third sample and two windows of continuous listening.
        guard samplingInterval - window >= 2, 3 * window <= 2 * samplingInterval else { return }

        NSLog("AwayLatch: Sampling for up to %.1f seconds every %.1f seconds", window, samplingInterval)
        startSample(at: now, window: window)
    }

    private func startSample(at now: TimeInterval, window: TimeInterval) {
        scanPhase = .sampling(startedAt: now, window: window)
        qualifiedInWindow.removeAll()
        for uuid in advertisementTargets {
            latestRSSIs.removeValue(forKey: uuid)
        }
        updateScanning()
        scheduleScanPhase(at: now + window)
    }

    private func scheduleScanPhase(at time: TimeInterval) {
        scanPhaseTimer?.invalidate()
        let delay = max(0, time - ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.advanceScanPhase(at: ProcessInfo.processInfo.systemUptime)
                self?.checkConfirmations()
            }
        }
        scanPhaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceScanPhase(at now: TimeInterval) {
        switch scanPhase {
        case .continuous:
            return
        case let .sampling(startedAt, window):
            guard centralMgr.isScanning else {
                restartInterruptedScan()
                return
            }
            let unconfirmed = advertisementTargets.intersection(nearbyUUIDs).subtracting(qualifiedInWindow)
            if !unconfirmed.isEmpty, now < startedAt + window {
                scheduleScanPhase(at: startedAt + window)
                return
            }
            for uuid in unconfirmed {
                var confirmation = confirmations[uuid] ?? Confirmation(startedAt: startedAt, window: window)
                confirmation.failedSamples += 1
                confirmations[uuid] = confirmation
            }
            let nextSampleAt = startedAt + samplingInterval
            if now >= nextSampleAt || confirmations.values.contains(where: { $0.failedSamples >= Self.sampledRounds }) {
                resumeContinuousScanning()
                return
            }

            scanPhase = .waiting(window: window)
            updateScanning()
            scheduleScanPhase(at: nextSampleAt)
        case let .waiting(window):
            startSample(at: now, window: window)
        }
    }

    private func scheduleConfirmationCheck(at time: TimeInterval?) {
        guard isMonitoring, let time else {
            confirmationTimer?.invalidate()
            confirmationTimer = nil
            return
        }
        let fireDate = Date(timeIntervalSinceNow: max(0, time - ProcessInfo.processInfo.systemUptime))
        if let timer = confirmationTimer, timer.fireDate <= fireDate { return }
        confirmationTimer?.invalidate()
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.confirmationTimer = nil
                self?.checkConfirmations()
            }
        }
        confirmationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            refreshMonitoring()
        }
    }

    private func getEstimatedRSSI(uuid: UUID, rssi: Int) -> Int {
        var samples = latestRSSIs[uuid, default: []]
        if samples.count == latestN {
            samples.removeFirst()
        }
        samples.append(rssi)
        latestRSSIs[uuid] = samples
        return samples.reduce(0, +) / samples.count
    }

    private func recordDeparture(_ uuid: UUID, reason: String) {
        confirmations.removeValue(forKey: uuid)
        advertisementTimings.removeValue(forKey: uuid)
        if reason == "lost" {
            lastSignals.removeValue(forKey: uuid)
            monitoredRSSI.removeValue(forKey: uuid)
            latestRSSIs.removeValue(forKey: uuid)
        }
        // Only a device that was confirmed nearby can generate a departure.
        if nearbyUUIDs.remove(uuid) != nil, isMonitoring, canScan {
            if scanPhase != .continuous {
                resumeContinuousScanning()
            }
            delegate?.deviceDidLeave(uuid, reason: reason)
        }
    }

    private func listeningSince(_ lastSignal: TimeInterval, for uuid: UUID) -> TimeInterval? {
        if lastReadAtMap[uuid] != nil { return lastSignal }
        guard scanPhase == .continuous, centralMgr.isScanning, let scanStartedAt else { return nil }
        return max(lastSignal, scanStartedAt)
    }

    private func checkConfirmations(at now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                                    statusChanged: Bool = false) {
        guard isMonitoring, canScan else {
            scheduleConfirmationCheck(at: nil)
            return
        }
        var nextCheck: TimeInterval?
        var countdown: Int?
        var departures: [(UUID, String)] = []
        func checkAgain(at time: TimeInterval) {
            nextCheck = min(nextCheck ?? time, time)
        }

        for (uuid, lastSignal) in lastSignals {
            guard nearbyUUIDs.contains(uuid) else {
                if now >= lastSignal + discoveryLifetime {
                    lastSignals.removeValue(forKey: uuid)
                    monitoredRSSI.removeValue(forKey: uuid)
                    latestRSSIs.removeValue(forKey: uuid)
                } else {
                    checkAgain(at: lastSignal + discoveryLifetime)
                }
                continue
            }
            let deadline: TimeInterval
            let silent: Bool
            if let confirmation = confirmations[uuid], confirmation.failedSamples > 0 {
                guard let continuousSince = listeningSince(confirmation.startedAt, for: uuid) else { continue }
                silent = now >= max(lastSignal, continuousSince) + confirmation.window
                // Weak packets do not reset a sampled departure. A qualifying reading clears it.
                deadline = max(confirmation.startedAt + confirmationTime, continuousSince + 2 * confirmation.window)
            } else {
                guard let listeningSince = listeningSince(lastSignal, for: uuid) else { continue }
                let window = confirmations[uuid]?.window ?? windowLength(for: uuid, at: lastSignal)
                let silenceAt = listeningSince + window
                silent = now >= silenceAt
                if silent {
                    var confirmation = confirmations[uuid] ?? Confirmation(startedAt: silenceAt, window: window)
                    confirmation.weakSince = nil
                    confirmations[uuid] = confirmation
                }
                guard let confirmation = confirmations[uuid], silent || confirmation.weakSince != nil else {
                    checkAgain(at: silenceAt)
                    continue
                }

                // The same deadline covers the transition from a weak signal to complete silence.
                let evidenceAt = silent ? listeningSince + 2 * window
                    : (confirmation.weakSince ?? now) + min(window, confirmationTime)
                deadline = max(confirmation.startedAt + confirmationTime, evidenceAt)
                if !silent, now < deadline { checkAgain(at: silenceAt) }
            }
            if now >= deadline {
                departures.append((uuid, silent ? "lost" : "away"))
            } else {
                let remaining = Int(ceil(deadline - now))
                countdown = min(countdown ?? remaining, remaining)
                checkAgain(at: min(deadline, now + 1))
            }
        }

        let countdownChanged = secondsUntilLock != countdown
        secondsUntilLock = countdown
        scheduleConfirmationCheck(at: nextCheck)
        for (uuid, reason) in departures {
            recordDeparture(uuid, reason: reason)
        }
        if statusChanged || countdownChanged || !departures.isEmpty {
            delegate?.monitoringDidChange()
        }
    }

    func updateMonitoredPeripheral(uuid: UUID, rssi: Int) {
        guard isMonitoring, monitoredUUIDs.contains(uuid) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let previousSignal = lastSignals.updateValue(now, forKey: uuid)
        // A stronger signal is required to arm monitoring than to cancel a countdown.
        let becameNearby = rssi >= nearbyThreshold && nearbyUUIDs.insert(uuid).inserted
        if becameNearby {
            latestRSSIs.removeValue(forKey: uuid)
        }

        let estimatedRSSI = getEstimatedRSSI(uuid: uuid, rssi: rssi)
        monitoredRSSI[uuid] = estimatedRSSI
        // Learn broadcast intervals while scanning continuously. An early stop only measures
        // the wait for the first qualifying reading, so keep the calibrated window for sampling.
        if scanPhase == .continuous, noConnectUUIDs.contains(uuid), rssi >= nearbyThreshold, let scanStartedAt {
            let gap = now - max(previousSignal ?? scanStartedAt, scanStartedAt)
            advertisementTimings[uuid, default: AdvertisementTiming()].record(gap: gap, at: now)
        }
        if nearbyUUIDs.contains(uuid) {
            let isSamplingAdvertisement = if case .sampling = scanPhase { lastReadAtMap[uuid] == nil } else { false }
            let checkingSample = isSamplingAdvertisement || (confirmations[uuid]?.failedSamples ?? 0) > 0
            let qualifiesByAverage = estimatedRSSI >= lockRSSI && (!checkingSample || (latestRSSIs[uuid]?.count ?? 0) >= 2)
            if rssi >= nearbyThreshold || qualifiesByAverage {
                confirmations.removeValue(forKey: uuid)
                if isSamplingAdvertisement, qualifiedInWindow.insert(uuid).inserted,
                   advertisementTargets.intersection(nearbyUUIDs).isSubset(of: qualifiedInWindow) {
                    advanceScanPhase(at: now)
                }
            } else if !checkingSample {
                var confirmation = confirmations[uuid] ?? Confirmation(startedAt: now, window: windowLength(for: uuid, at: now))
                if confirmation.weakSince == nil || now - (previousSignal ?? now) >= confirmation.window {
                    confirmation.weakSince = now
                }
                confirmations[uuid] = confirmation
            }
        }
        checkConfirmations(at: now, statusChanged: becameNearby)
        considerSampling(at: now)
    }

    private func recordDiscovery(_ device: Device, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        device.lastSeenAt = now
        if discoveryExpiryTimer == nil {
            scheduleDiscoveryExpiry(after: discoveryLifetime)
        }
    }

    private func scheduleDiscoveryExpiry(after delay: TimeInterval) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pruneDiscoveries()
            }
        }
        timer.tolerance = 1
        discoveryExpiryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pruneDiscoveries(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        discoveryExpiryTimer?.invalidate()
        discoveryExpiryTimer = nil
        let expiredBefore = now - discoveryLifetime
        devices = devices.filter { $0.value.lastSeenAt > expiredBefore }
        if let oldest = devices.values.lazy.map(\.lastSeenAt).min() {
            scheduleDiscoveryExpiry(after: oldest - expiredBefore)
        }
    }

    func connectMonitoredPeripheral(uuid: UUID) {
        guard isMonitoring else { return }
        guard !noConnectUUIDs.contains(uuid) else { return }
        guard let p = monitoredPeripherals[uuid] else { return }
        let now = Date().timeIntervalSince1970
        if let lastAttempt = lastConnectAttemptAt[uuid], now < lastAttempt + 6 {
            return
        }

        guard p.state == .disconnected && centralMgr.state == .poweredOn else { return }
        lastConnectAttemptAt[uuid] = now
        print("Connecting \(uuid)")
        centralMgr.connect(p, options: nil)
        connectionTimers[uuid]?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.connectionTimers.removeValue(forKey: uuid)
                guard self.monitoredPeripherals[uuid]?.state == .connecting else { return }
                print("Connection timeout \(uuid)")
                self.monitorAdvertisements(uuid: uuid, retryAfter: 300)
            }
        }
        connectionTimers[uuid] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    //MARK:- CBCentralManagerDelegate start

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber)
    {
        MainActor.assumeIsolated {
            guard shouldScan, RSSI.intValue != 127 else { return }
            let rssi = min(RSSI.intValue, 0)
            if isMonitoring, monitoredUUIDs.contains(peripheral.identifier) {
                let uuid = peripheral.identifier
                monitoredPeripherals[uuid] = peripheral

                let avoidConnect = shouldAvoidConnecting(peripheral: peripheral, advertisementData: advertisementData)
                if avoidConnect {
                    monitorAdvertisements(uuid: uuid)
                } else if let cooldown = connectCooldownUntil[uuid],
                          cooldown <= Date().timeIntervalSince1970,
                          noConnectUUIDs.remove(uuid) != nil {
                    connectCooldownUntil.removeValue(forKey: uuid)
                    resumeContinuousScanning()
                }

                if lastReadAtMap[uuid] == nil {
                    updateMonitoredPeripheral(uuid: uuid, rssi: rssi)
                }
                if activeModeTimers[uuid] == nil {
                    connectMonitoredPeripheral(uuid: uuid)
                }
            }

            guard scanMode else { return }
            let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
            guard services?.contains(ExposureNotification) != true else { return }

            let uuid = peripheral.identifier
            let device: Device
            if let discovered = devices[uuid] {
                device = discovered
            } else {
                device = Device(uuid: uuid)
                device.refreshIdentity(using: deviceLookup)
                devices[uuid] = device
            }
            device.peripheral = peripheral
            device.rssi = rssi
            device.advData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
            if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String {
                device.localName = localName
            }
            recordDiscovery(device)
            delegate?.deviceDiscovered(device)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral)
    {
        MainActor.assumeIsolated {
            let uuid = peripheral.identifier
            guard isMonitoring, monitoredPeripherals[uuid] === peripheral,
                  !noConnectUUIDs.contains(uuid) else {
                centralMgr.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.delegate = self
            if scanMode {
                peripheral.discoverServices([DeviceInformation])
            }
            connectionTimers.removeValue(forKey: uuid)?.invalidate()
            peripheral.readRSSI()
            startActiveReads(uuid)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?)
    {
        MainActor.assumeIsolated {
            guard isMonitoring, monitoredPeripherals[peripheral.identifier] === peripheral else { return }
            print("Failed to connect \(peripheral.identifier): \(error?.localizedDescription ?? "unknown")")
            monitorAdvertisements(uuid: peripheral.identifier, retryAfter: 300)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?)
    {
        MainActor.assumeIsolated {
            guard isMonitoring, monitoredPeripherals[peripheral.identifier] === peripheral else { return }
            monitorAdvertisements(uuid: peripheral.identifier, retryAfter: error == nil ? 8 : 300)
        }
    }

    //MARK:CBCentralManagerDelegate end -

    //MARK:- CBPeripheralDelegate start

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated {
            let uuid = peripheral.identifier
            guard isMonitoring, monitoredPeripherals[uuid] === peripheral,
                  !noConnectUUIDs.contains(uuid),
                  error == nil, RSSI.intValue != 127 else { return }
            let firstActiveRead = lastReadAtMap.updateValue(Date().timeIntervalSince1970, forKey: uuid) == nil
            updateMonitoredPeripheral(uuid: uuid, rssi: min(RSSI.intValue, 0))
            if firstActiveRead {
                updateScanning()
            }
        }
    }

    private func startActiveReads(_ uuid: UUID) {
        activeModeTimers[uuid]?.invalidate()
        let startedAt = Date().timeIntervalSince1970
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, let peripheral = self.monitoredPeripherals[uuid] else {
                    timer.invalidate()
                    return
                }
                let lastRead = self.lastReadAtMap[uuid] ?? startedAt
                let readTimeout = min(10, self.confirmationTime / 2)
                if Date().timeIntervalSince1970 > lastRead + readTimeout {
                    print("Falling back to advertisement monitoring \(uuid)")
                    self.monitorAdvertisements(uuid: uuid, retryAfter: 300)
                } else if peripheral.state == .connected {
                    peripheral.readRSSI()
                }
            }
        }
        activeModeTimers[uuid] = timer
        RunLoop.main.add(timer, forMode: .common)
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
            let uuid = peripheral.identifier
            guard monitoredUUIDs.contains(uuid), let device = devices[uuid],
                  let value = characteristic.value, let name = String(data: value, encoding: .utf8) else { return }
            switch characteristic.uuid {
            case ManufacturerName:
                device.manufacture = name
            case ModelName:
                device.model = name
            default:
                return
            }
            delegate?.deviceDiscovered(device)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didModifyServices invalidatedServices: [CBService])
    {
        MainActor.assumeIsolated {
            guard scanMode, devices[peripheral.identifier] != nil else { return }
            peripheral.discoverServices([DeviceInformation])
        }
    }
    //MARK:CBPeripheralDelegate end -

    // MARK: - Watchdog

    private func startWatchdog() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.watchdogCheck()
            }
        }
        timer.tolerance = 3
        watchdogTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func watchdogCheck() {
        guard shouldScan, !centralMgr.isScanning else { return }
        print("[Watchdog] Scan not running, restarting...")
        restartInterruptedScan()
    }

    private func restartInterruptedScan() {
        for uuid in advertisementTargets {
            confirmations.removeValue(forKey: uuid)
        }
        scanStartedAt = nil
        resumeContinuousScanning()
    }

    override init() {
        super.init()
        centralMgr = CBCentralManager(delegate: self, queue: nil)
    }
}
