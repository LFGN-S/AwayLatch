import Cocoa
import IOBluetooth
import LocalAuthentication
import Quartz
import ServiceManagement
import UserNotifications

func t(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate, BLEDelegate {
    private struct ListedDevice {
        let name: String
        let address: String?
        let rssi: Int?
        let isPaired: Bool
    }

    private static let screenDidLock = Notification.Name("com.apple.screenIsLocked")
    private static let screenDidUnlock = Notification.Name("com.apple.screenIsUnlocked")
    private static let confirmationOptions = [10, 15, 20, 30, 45, 60, 90, 120, 180, 300, 600]
    private static let confirmationKey = "departureConfirmationTime"
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let ble = BLE()
    private let mainMenu = NSMenu()
    private let deviceMenu = NSMenu()
    private let lockRSSIMenu = NSMenu()
    private let confirmationMenu = NSMenu()
    private let prefs = UserDefaults.standard
    private lazy var monitoringIcon = loadStatusIcon("StatusBarConnected")
    private lazy var waitingIcon = loadStatusIcon("StatusBarDisconnected")
    private lazy var showAllButton = NSButton(checkboxWithTitle: t("show_all_nearby_devices"),
                                              target: self, action: #selector(toggleShowAllNearbyDevices(_:)))
    private lazy var showAllItem: NSMenuItem = {
        let button = showAllButton
        button.font = .menuFont(ofSize: 0)
        let size = button.fittingSize
        let height = max(24, size.height + 4)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 28, height: height))
        button.frame = NSRect(x: 12, y: (height - size.height) / 2, width: size.width, height: size.height)
        view.addSubview(button)

        let item = NSMenuItem(title: button.title, action: nil, keyEquivalent: "")
        item.view = view
        return item
    }()

    private var deviceMenuItems: [UUID: NSMenuItem] = [:]
    private var pairedMenuItems: [String: (name: String, item: NSMenuItem)] = [:]
    private var listedDevices: [UUID: ListedDevice] = [:]
    private var pairingRefreshTimer: Timer?
    private var deviceNames: [String: String] = [:]
    private var monitorMenuItem: NSMenuItem?
    private var isDeviceMenuOpen = false
    private var isQuittingValidated = false
    private var isSystemPoweringOff = false
    private var lockCheckTimer: Timer?
    private var lockFailed = false
    private var activityToken: NSObjectProtocol?

    static func main() {
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            migratePreferences(.standard, from: "com.shawnrain.BLELock", to: bundleIdentifier)
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    private var showAllNearbyDevices: Bool {
        prefs.bool(forKey: "showAllNearbyDevices")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === mainMenu {
            updateScreenState(isScreenLocked())
        } else if menu === deviceMenu {
            if !isDeviceMenuOpen {
                rebuildDeviceMenu()
            }
        } else {
            let selectedTag: Int
            if menu === lockRSSIMenu {
                selectedTag = ble.lockRSSI
            } else if menu === confirmationMenu {
                selectedTag = Int(ble.confirmationTime)
            } else {
                return
            }
            for item in menu.items {
                item.state = item.tag == selectedTag ? .on : .off
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === deviceMenu {
            isDeviceMenuOpen = true
            ble.startScanning()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === deviceMenu {
            isDeviceMenuOpen = false
            ble.stopScanning()
        }
    }

    private func normalizedAddress(_ address: String) -> String {
        address.replacingOccurrences(of: "-", with: ":").uppercased()
    }

    private func matchingName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "’", with: "'")
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private func pairedDeviceNames() -> [String: String] {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        var names: [String: String] = [:]
        for device in devices {
            guard let address = device.addressString else { continue }
            names[normalizedAddress(address)] = device.nameOrAddress ?? address
        }
        return names
    }

    private func name(for uuid: UUID) -> String {
        deviceNames[uuid.uuidString] ?? ble.devices[uuid]?.description ?? String(uuid.uuidString.prefix(8))
    }

    private func rebuildDeviceMenu() {
        deviceMenu.removeAllItems()
        deviceMenuItems.removeAll()
        pairedMenuItems.removeAll()
        listedDevices.removeAll()
        ble.refreshDeviceIdentities()

        let selected = ble.monitoredUUIDs.sorted {
            let comparison = name(for: $0).localizedStandardCompare(name(for: $1))
            return comparison == .orderedSame ? $0.uuidString < $1.uuidString : comparison == .orderedAscending
        }
        for uuid in selected {
            let discovered = ble.devices[uuid]
            let address = if let discovered { discovered.macAddr } else { ble.deviceInfo(for: uuid).macAddr }
            let device = ListedDevice(name: name(for: uuid), address: address.map(normalizedAddress),
                                      rssi: ble.monitoredRSSI[uuid], isPaired: discovered?.isPaired == true)
            let item = NSMenuItem()
            configureDeviceItem(item, uuid: uuid, name: device.name, rssi: device.rssi)
            item.state = .on
            listedDevices[uuid] = device
            deviceMenuItems[uuid] = item
            deviceMenu.addItem(item)
        }
        if !selected.isEmpty {
            deviceMenu.addItem(.separator())
        }

        showAllButton.state = showAllNearbyDevices ? .on : .off
        deviceMenu.addItem(showAllItem)

        let paired = pairedDeviceNames().sorted {
            let comparison = $0.value.localizedStandardCompare($1.value)
            return comparison == .orderedSame ? $0.key < $1.key : comparison == .orderedAscending
        }
        for (address, label) in paired {
            let item = NSMenuItem(title: deviceTitle(label, rssi: nil), action: nil, keyEquivalent: "")
            item.isEnabled = false
            pairedMenuItems[address] = (label, item)
            deviceMenu.addItem(item)
        }
        for device in ble.devices.values.sorted(by: { $0.rssi > $1.rssi }) where !ble.monitoredUUIDs.contains(device.uuid) {
            updateNearbyDevice(device, name: device.description)
        }
        updatePairingRows()
    }

    private func deviceTitle(_ name: String, rssi: Int?) -> String {
        let reading = rssi.map { "\($0) dBm" } ?? t("not_detected")
        return "\(name) · \(reading)"
    }

    private func configureDeviceItem(_ item: NSMenuItem, uuid: UUID, name: String, rssi: Int?) {
        let title = deviceTitle(name, rssi: rssi)
        if item.title != title { item.title = title }
        if item.representedObject as? String != uuid.uuidString {
            item.action = #selector(selectDevice(_:))
            item.target = self
            item.representedObject = uuid.uuidString
            item.isEnabled = true
        }
    }

    @discardableResult
    private func updateNearbyDevice(_ device: Device, name: String) -> Bool {
        let uuid = device.uuid
        let snapshot = ListedDevice(name: name, address: device.macAddr.map(normalizedAddress),
                                    rssi: device.rssi, isPaired: device.isPaired)
        if let previous = listedDevices[uuid], previous.name == snapshot.name, previous.address == snapshot.address,
           previous.isPaired == snapshot.isPaired, previous.rssi != nil {
            return false
        }
        listedDevices[uuid] = snapshot
        let existing = deviceMenuItems[uuid]
        let item = existing ?? NSMenuItem()
        configureDeviceItem(item, uuid: uuid, name: snapshot.name, rssi: snapshot.rssi)
        if existing == nil {
            item.isHidden = true
            deviceMenuItems[uuid] = item
            deviceMenu.addItem(item)
        }
        return true
    }

    private func updatePairingRows() {
        pairingRefreshTimer?.invalidate()
        pairingRefreshTimer = nil
        let selected = ble.monitoredUUIDs
        let devices = listedDevices.sorted {
            if selected.contains($0.key) != selected.contains($1.key) {
                return selected.contains($0.key)
            }
            return ($0.value.rssi ?? Int.min) > ($1.value.rssi ?? Int.min)
        }
        var matches: [String: UUID] = [:]
        for (uuid, device) in devices {
            if let address = device.address, pairedMenuItems[address] != nil, matches[address] == nil {
                matches[address] = uuid
            }
        }

        // A name match joins menu rows only. Selection always uses the discovered BLE UUID.
        let pairedByName = Dictionary(grouping: pairedMenuItems.filter { matches[$0.key] == nil }) {
            matchingName($0.value.name)
        }
        let devicesByName = Dictionary(grouping: devices.filter {
            $0.value.address.flatMap { pairedMenuItems[$0] } == nil
        }) {
            matchingName($0.value.name)
        }
        for (name, paired) in pairedByName where paired.count == 1 && !name.isEmpty {
            if let candidates = devicesByName[name], candidates.count == 1 {
                matches[paired[0].key] = candidates[0].key
            }
        }

        for (address, row) in pairedMenuItems {
            if let uuid = matches[address], let device = listedDevices[uuid] {
                configureDeviceItem(row.item, uuid: uuid, name: row.name, rssi: device.rssi)
                row.item.isHidden = selected.contains(uuid)
            } else {
                row.item.isHidden = false
                if row.item.representedObject != nil {
                    row.item.title = deviceTitle(row.name, rssi: nil)
                    row.item.action = nil
                    row.item.representedObject = nil
                    row.item.isEnabled = false
                }
            }
        }
        let matched = Set(matches.values)
        let showAll = showAllNearbyDevices
        for (uuid, item) in deviceMenuItems where !selected.contains(uuid) {
            guard let device = listedDevices[uuid] else { continue }
            let hasPairedAddress = device.address.map { pairedMenuItems[$0] != nil } ?? false
            item.isHidden = matched.contains(uuid) || hasPairedAddress || (!device.isPaired && !showAll)
        }
    }

    func deviceDiscovered(_ device: Device) {
        let isSelected = ble.monitoredUUIDs.contains(device.uuid)
        guard isSelected || isDeviceMenuOpen else { return }
        let label = device.description
        if isSelected {
            let identifier = device.uuid.uuidString
            if label != identifier, deviceNames[identifier] != label {
                deviceNames[identifier] = label
                prefs.set(deviceNames, forKey: "selectedDeviceNames")
            }
        }
        guard isDeviceMenuOpen, updateNearbyDevice(device, name: label), pairingRefreshTimer == nil else { return }
        // Nearby advertisements can arrive in bursts while AppKit is tracking the menu.
        let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pairingRefreshTimer = nil
                if self.isDeviceMenuOpen {
                    self.updatePairingRows()
                }
            }
        }
        pairingRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func toggleShowAllNearbyDevices(_ sender: NSButton) {
        prefs.set(sender.state == .on, forKey: "showAllNearbyDevices")
        updatePairingRows()
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String, let uuid = UUID(uuidString: identifier) else { return }
        var selected = ble.monitoredUUIDs
        if selected.remove(uuid) != nil {
            deviceNames.removeValue(forKey: identifier)
        } else {
            selected.insert(uuid)
            if let label = ble.devices[uuid]?.description, label != identifier {
                deviceNames[identifier] = label
            }
        }
        prefs.set(selected.map(\.uuidString).sorted(), forKey: "devices")
        prefs.set(deviceNames, forKey: "selectedDeviceNames")
        lockFailed = false
        ble.startMonitor(uuids: selected)
    }

    func monitoringDidChange() {
        updateMonitoringActivity()
        let title: String
        let symbol: String?
        let monitoring: Bool
        if ble.screenLocked {
            title = t("screen_locked")
            symbol = "lock.fill"
            monitoring = false
        } else if lockCheckTimer != nil {
            title = t("locking_screen")
            symbol = "clock"
            monitoring = false
        } else if ble.monitoredUUIDs.isEmpty {
            title = t("device_not_set")
            symbol = nil
            monitoring = false
        } else if ble.suspended {
            title = t("paused")
            symbol = nil
            monitoring = false
        } else if ble.centralMgr.state != .poweredOn {
            title = t("bluetooth_unavailable")
            symbol = nil
            monitoring = false
        } else if ble.lockRSSI == ble.LOCK_DISABLED {
            title = t("automatic_lock_disabled")
            symbol = nil
            monitoring = false
        } else if let seconds = ble.secondsUntilLock {
            title = String(format: t("locking_in_seconds"), seconds)
            symbol = "clock"
            monitoring = true
        } else if lockFailed {
            title = t("lock_not_confirmed")
            symbol = nil
            monitoring = false
        } else if ble.nearbyUUIDs.isEmpty {
            title = t("waiting_for_device")
            symbol = nil
            monitoring = false
        } else {
            title = t("monitoring_devices")
            symbol = nil
            monitoring = true
        }

        guard monitorMenuItem?.title != title else { return }
        monitorMenuItem?.title = title
        let button = statusItem.button
        button?.toolTip = title
        let statusImage = monitoring ? monitoringIcon : waitingIcon
        button?.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) } ?? statusImage
    }

    private func loadStatusIcon(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "pdf"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }

    func deviceDidLeave(_ uuid: UUID, reason: String) {
        requestLock(deviceName: name(for: uuid), reason: reason)
    }

    private func requestLock(deviceName: String? = nil, reason: String? = nil) {
        if isScreenLocked() {
            updateScreenState(true)
            return
        }
        guard lockCheckTimer == nil else { return }
        lockFailed = false

        if prefs.bool(forKey: "screensaver") {
            let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
            guard NSWorkspace.shared.open(url) else {
                lockFailed = true
                monitoringDidChange()
                return
            }
        } else {
            _ = SACLockScreenImmediate()
        }

        var attempts = 0
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                let locked = self.isScreenLocked()
                attempts += 1
                guard locked || attempts >= 8 else { return }
                timer.invalidate()
                self.lockCheckTimer = nil
                self.lockFailed = !locked
                if locked, let deviceName, let reason {
                    self.notifyLock(deviceName: deviceName, reason: reason)
                }
                self.updateScreenState(locked)
            }
        }
        lockCheckTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        monitoringDidChange()
    }

    private func isScreenLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Int == 1
    }

    private func notifyLock(deviceName: String, reason: String) {
        let content = UNMutableNotificationContent()
        content.title = t(reason == "lost" ? "notification_lost_signal" : "notification_device_away")
        content.body = String(format: t("notification_locked"), Host.current().localizedName ?? "Mac", deviceName)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "lock", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    @objc private func screenStateChanged(_ notification: Notification) {
        let locked = isScreenLocked()
        updateScreenState(locked)
        if notification.name == (locked ? Self.screenDidUnlock : Self.screenDidLock) {
            // The session state can lag behind the distributed notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                self.updateScreenState(self.isScreenLocked())
            }
        }
    }

    private func updateScreenState(_ locked: Bool) {
        if locked {
            lockFailed = false
            isDeviceMenuOpen = false
        }
        if ble.screenLocked == locked {
            monitoringDidChange()
        } else {
            ble.setScreenLocked(locked)
        }
    }

    private func updateMonitoringActivity() {
        let process = ProcessInfo.processInfo
        if ble.isMonitoring, activityToken == nil {
            activityToken = process.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "BLE device monitoring requires timely timer firing"
            )
        } else if !ble.isMonitoring, let activityToken {
            process.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    @objc private func onSystemWake(_ notification: Notification) {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                NSApp.setActivationPolicy(.accessory)
                if let self {
                    self.ble.setScreenLocked(self.isScreenLocked())
                    self.ble.setSuspended(false)
                }
            }
        }
    }

    @objc private func onSystemSleep(_ notification: Notification) {
        lockCheckTimer?.invalidate()
        lockCheckTimer = nil
        lockFailed = false
        isDeviceMenuOpen = false
        // Restore accessory mode after wake so Bluetooth can resume scanning.
        NSApp.setActivationPolicy(.regular)
        ble.setSuspended(true)
    }

    @objc private func setLockRSSI(_ item: NSMenuItem) {
        prefs.set(item.tag, forKey: "lockRSSI")
        lockFailed = false
        ble.lockRSSI = item.tag
    }

    @objc private func setConfirmationTime(_ item: NSMenuItem) {
        prefs.set(item.tag, forKey: Self.confirmationKey)
        ble.confirmationTime = Double(item.tag)
    }

    @objc private func toggleUseScreensaver(_ item: NSMenuItem) {
        let value = !prefs.bool(forKey: "screensaver")
        prefs.set(value, forKey: "screensaver")
        item.state = value ? .on : .off
    }

    @objc private func toggleLaunchAtLogin(_ item: NSMenuItem) {
        let enabled = !prefs.bool(forKey: "launchAtLogin")
        prefs.set(enabled, forKey: "launchAtLogin")
        item.state = enabled ? .on : .off
        syncLaunchAtLoginStatus()
    }

    private func syncLaunchAtLoginStatus() {
        let enabled = prefs.bool(forKey: "launchAtLogin")
        let service = SMAppService.mainApp
        let status = service.status
        do {
            if enabled, status != .enabled, status != .requiresApproval {
                try service.register()
            } else if !enabled, status == .enabled || status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            NSLog("AwayLatch: Failed to update launch at login: \(error.localizedDescription)")
        }
    }

    #if DEBUG
    @objc private func testLock() {
        requestLock()
    }
    #endif

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isQuittingValidated || isSystemPoweringOff {
            return .terminateNow
        }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .terminateNow
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: t("auth_to_quit")) { success, evaluateError in
            DispatchQueue.main.async {
                if success {
                    self.isQuittingValidated = true
                } else if let error = evaluateError as NSError?, error.code != LAError.userCancel.rawValue {
                    let alert = NSAlert(error: error)
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
                NSApplication.shared.reply(toApplicationShouldTerminate: success)
            }
        }
        return .terminateLater
    }

    @objc private func onSystemPowerOff(_ notification: Notification) {
        isSystemPoweringOff = true
    }

    private func addConfirmationOptions() {
        for seconds in Self.confirmationOptions {
            let label = "\(seconds) \(t("seconds"))"
            let item = confirmationMenu.addItem(withTitle: label, action: #selector(setConfirmationTime(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
        }
        confirmationMenu.delegate = self
    }

    private func constructMenu() {
        mainMenu.delegate = self
        monitorMenuItem = mainMenu.addItem(withTitle: "", action: nil, keyEquivalent: "")

        mainMenu.addItem(withTitle: t("device"), action: nil, keyEquivalent: "").submenu = deviceMenu
        deviceMenu.delegate = self
        deviceMenu.autoenablesItems = false

        mainMenu.addItem(withTitle: t("lock_rssi"), action: nil, keyEquivalent: "").submenu = lockRSSIMenu
        lockRSSIMenu.delegate = self
        for rssi in stride(from: -45, through: -90, by: -5) {
            let item = lockRSSIMenu.addItem(withTitle: "\(rssi) dBm", action: #selector(setLockRSSI(_:)), keyEquivalent: "")
            item.target = self
            item.tag = rssi
        }
        lockRSSIMenu.addItem(.separator())
        let disabled = lockRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setLockRSSI(_:)), keyEquivalent: "")
        disabled.target = self
        disabled.tag = ble.LOCK_DISABLED

        mainMenu.addItem(withTitle: t("departure_confirmation_time"), action: nil, keyEquivalent: "").submenu = confirmationMenu
        addConfirmationOptions()

        let screensaver = mainMenu.addItem(withTitle: t("use_screensaver_to_lock"), action: #selector(toggleUseScreensaver(_:)), keyEquivalent: "")
        screensaver.target = self
        screensaver.state = prefs.bool(forKey: "screensaver") ? .on : .off

        let login = mainMenu.addItem(withTitle: t("launch_at_login"), action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = prefs.bool(forKey: "launchAtLogin") ? .on : .off

        #if DEBUG
        mainMenu.addItem(.separator())
        mainMenu.addItem(withTitle: t("test_lock"), action: #selector(testLock), keyEquivalent: "").target = self
        #endif

        mainMenu.addItem(.separator())
        mainMenu.addItem(withTitle: t("quit"), action: #selector(quitApp), keyEquivalent: "q").target = self
        statusItem.menu = mainMenu
    }

    private static func migratePreferences(_ prefs: UserDefaults, from oldDomain: String, to newDomain: String) {
        let migrated = "didMigrateBLELockPreferences"
        let current = prefs.persistentDomain(forName: newDomain) ?? [:]
        guard current[migrated] as? Bool != true else { return }

        var previous = prefs.persistentDomain(forName: oldDomain) ?? [:]
        if previous["devices"] == nil, let device = previous["device"] as? String {
            previous["devices"] = [device]
        }
        previous[confirmationKey] = previous[confirmationKey] ?? previous["lockDelay"]
        let keys = ["devices", "selectedDeviceNames", "lockRSSI", confirmationKey,
                    "screensaver", "launchAtLogin", "showAllNearbyDevices"]
        for key in keys where current[key] == nil {
            if let value = previous[key] {
                prefs.set(value, forKey: key)
            }
        }
        prefs.set(true, forKey: migrated)
    }

    private func restoreMonitoringPreferences() {
        let lockRSSI = prefs.integer(forKey: "lockRSSI")
        if lockRSSI == ble.LOCK_DISABLED {
            ble.lockRSSI = lockRSSI
        } else if lockRSSI != 0 {
            let clamped = min(-45, max(-90, lockRSSI))
            ble.lockRSSI = Int((Double(clamped) / 5).rounded()) * 5
        }
        let saved = prefs.integer(forKey: Self.confirmationKey)
        let bounded = min(600, max(10, saved))
        ble.confirmationTime = Double(Self.confirmationOptions.min { abs($0 - bounded) < abs($1 - bounded) } ?? 10)
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        let currentApp = NSRunningApplication.current
        for app in NSWorkspace.shared.runningApplications
            where app != currentApp && app.bundleIdentifier == currentApp.bundleIdentifier {
            app.terminate()
        }

        NSApp.setActivationPolicy(.accessory)
        constructMenu()
        syncLaunchAtLoginStatus()
        restoreMonitoringPreferences()

        let savedDevices = prefs.stringArray(forKey: "devices") ?? []
        let selected = Set(savedDevices.compactMap(UUID.init(uuidString:)))
        let savedNames = prefs.dictionary(forKey: "selectedDeviceNames") as? [String: String] ?? [:]
        deviceNames = savedNames.filter { key, _ in UUID(uuidString: key).map(selected.contains) == true }
        for uuid in selected where deviceNames[uuid.uuidString] == nil {
            deviceNames[uuid.uuidString] = ble.deviceInfo(for: uuid).name
        }
        ble.setScreenLocked(isScreenLocked())
        ble.delegate = self
        ble.startMonitor(uuids: selected)

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(onSystemPowerOff(_:)), name: NSWorkspace.willPowerOffNotification, object: nil)
        workspace.addObserver(self, selector: #selector(onSystemSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(onSystemWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screenStateChanged(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil)
        if let distributed = DistributedNotificationCenter.default as? DistributedNotificationCenter {
            for event in [Self.screenDidLock, Self.screenDidUnlock] {
                distributed.addObserver(self, selector: #selector(screenStateChanged(_:)),
                                        name: event, object: nil, suspensionBehavior: .deliverImmediately)
            }
        }

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("AwayLatch: Notification permission error: \(error.localizedDescription)")
            }
        }
    }
}

@_silgen_name("SACLockScreenImmediate")
func SACLockScreenImmediate() -> Int32
