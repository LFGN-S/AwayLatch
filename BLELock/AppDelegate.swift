import Cocoa
import Quartz
import ServiceManagement
import UserNotifications
import IOKit.pwr_mgt
import IOKit
import IOKit.ps
import LocalAuthentication

func t(_ key: String) -> String {
    return NSLocalizedString(key, comment: "")
}

private func powerSourceChangedCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context = context else { return }
    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in
        appDelegate.applyPauseOnBatteryPolicy()
    }
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, UNUserNotificationCenterDelegate, BLEDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let ble = BLE()
    let mainMenu = NSMenu()
    let deviceMenu = NSMenu()
    let lockRSSIMenu = NSMenu()
    let lockDelayMenu = NSMenu()
    let timeoutMenu = NSMenu()
    let shortcutMenu = NSMenu()
    var deviceDict: [UUID: NSMenuItem] = [:]
    var monitorMenuItem : NSMenuItem?
    var monitorDetailMenu = NSMenu()
    let prefs = UserDefaults.standard
    var displaySleep = false
    var systemSleep = false
    var connected = false
    var rssiMap: [UUID: Int?] = [:]
    var deviceNameMap: [UUID: String] = [:]
    var nowPlayingWasPlaying = false
    var aboutBox: AboutBox? = nil
    var inScreensaver = false
    var lastRSSI: Int? = nil
    var isDeviceMenuOpen = false
    var isQuittingValidated = false
    var isSystemPoweringOff = false
    var lastHeaderText: String?
    var lastHeaderUpdate: TimeInterval = 0
    var lastDisplayedRSSI: [UUID: Int?] = [:]
    var shortcutName: String?
    var powerSourceRunLoopSource: CFRunLoopSource?
    var activityToken: NSObjectProtocol?

    func menuWillOpen(_ menu: NSMenu) {
        if menu == deviceMenu {
            isDeviceMenuOpen = true
            ble.startScanning()
        } else if menu == lockRSSIMenu {
            for item in menu.items {
                if item.tag == ble.lockRSSI {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == timeoutMenu {
            for item in menu.items {
                if item.tag == Int(ble.signalTimeout) {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == lockDelayMenu {
            for item in menu.items {
                if item.tag == Int(ble.proximityTimeout) {
                    item.state = .on
                } else {
                    item.state = .off
                }
            }
        } else if menu == shortcutMenu {
            refreshShortcutMenu()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        return true
    }
    
    func menuDidClose(_ menu: NSMenu) {
        if menu == deviceMenu {
            isDeviceMenuOpen = false
            ble.stopScanning()
        }
    }
    
    func menuItemTitle(device: Device) -> String {
        var desc : String!
        if let mac = device.macAddr {
            let prettifiedMac = mac.replacingOccurrences(of: "-", with: ":").uppercased()
            desc = String(format: "%@ (%@)", device.description, prettifiedMac)
        } else {
            desc = device.description
        }
        return String(format: "%@ (%ddBm)", desc, device.rssi)
    }

    func updateMonitorMenuTitle() {
        if ble.monitoredUUIDs.isEmpty {
            monitorMenuItem?.attributedTitle = nil
            monitorMenuItem?.title = t("device_not_set")
            monitorDetailMenu.removeAllItems()
        } else if ble.suspended {
            monitorMenuItem?.attributedTitle = nil
            monitorMenuItem?.title = t("paused")
        } else {
            monitorMenuItem?.attributedTitle = nil
            monitorMenuItem?.title = String(format: t("device_count"), ble.monitoredUUIDs.count)
        }
    }

    func updateMonitorDetailList() {
        let ids = ble.monitoredUUIDs.sorted { lhs, rhs in
            let lName = deviceNameMap[lhs] ?? lhs.uuidString
            let rName = deviceNameMap[rhs] ?? rhs.uuidString
            if lName == rName { return lhs.uuidString < rhs.uuidString }
            return lName.localizedCaseInsensitiveCompare(rName) == .orderedAscending
        }
        guard !ids.isEmpty else {
            monitorDetailMenu.removeAllItems()
            return
        }

        if monitorDetailMenu.items.count != ids.count {
            monitorDetailMenu.removeAllItems()
            for _ in ids {
                let item = monitorDetailMenu.addItem(withTitle: "", action: nil, keyEquivalent: "")
                item.isEnabled = false
            }
        }

        for (index, id) in ids.enumerated() {
            let name = deviceNameMap[id] ?? String(id.uuidString.prefix(8)) + "…"
            let title: String
            if !ble.suspended, let val = rssiMap[id] ?? nil {
                title = "\(name) \(val)dBm"
            } else {
                title = "\(name) --"
            }
            let item = monitorDetailMenu.items[index]
            if item.title != title {
                item.title = title
            }
            if item.isEnabled {
                item.isEnabled = false
            }
        }
    }

    func refreshStatusIcon() {
        guard let button = statusItem.button else { return }
        let hasSelectedDevice = !ble.monitoredUUIDs.isEmpty
        let isPaused = ble.suspended
        let hasSeenSelectedDevice = ble.monitoredUUIDs.contains { ble.seenDevices.contains($0) }
        let isConnectedState = hasSelectedDevice && !isPaused && hasSeenSelectedDevice
        connected = isConnectedState
        button.image = NSImage(named: isConnectedState ? "StatusBarConnected" : "StatusBarDisconnected")
    }
    
    func newDevice(device: Device) {
        let menuItem = deviceMenu.addItem(withTitle: menuItemTitle(device: device), action:#selector(selectDevice(_:)), keyEquivalent: "")
        deviceDict[device.uuid] = menuItem
        deviceNameMap[device.uuid] = device.description
        if ble.monitoredUUIDs.contains(device.uuid) {
            menuItem.state = .on
        }
    }
    
    func updateDevice(device: Device) {
        deviceNameMap[device.uuid] = device.description
        if let menu = deviceDict[device.uuid] {
            // Only update title if menu is NOT open to avoid "wrong item" AppKit warnings
            if !isDeviceMenuOpen {
                menu.title = menuItemTitle(device: device)
            }
        }
    }
    
    func removeDevice(device: Device) {
        if let menuItem = deviceDict[device.uuid] {
            menuItem.menu?.removeItem(menuItem)
        }
        deviceDict.removeValue(forKey: device.uuid)
        // 保留已选设备，即使暂时不在扫描列表里
        updateMonitorMenuTitle()
    }

    func updateRSSI(rssi: Int?, active: Bool, uuid: UUID) {
        // Debounce: only redraw header when RSSI meaningfully changes
        let prev = lastDisplayedRSSI[uuid] ?? nil
        if let old = prev, let new = rssi, abs(old - new) < 2, Date().timeIntervalSince1970 - lastHeaderUpdate < 3 {
            rssiMap[uuid] = rssi
        } else {
            rssiMap[uuid] = rssi
            lastDisplayedRSSI[uuid] = rssi
        }

        // Compose status title: show all selected devices' RSSI
        if ble.monitoredUUIDs.isEmpty {
            lastHeaderText = nil
            monitorMenuItem?.attributedTitle = nil
            monitorMenuItem?.title = t("device_not_set")
            monitorDetailMenu.removeAllItems()
        } else if ble.suspended {
            lastHeaderText = t("paused")
            monitorMenuItem?.attributedTitle = nil
            monitorMenuItem?.title = t("paused")
            updateMonitorDetailList()
        } else {
            let now = Date().timeIntervalSince1970
            let header = String(format: t("device_count"), ble.monitoredUUIDs.count)
            if header != lastHeaderText && (!isDeviceMenuOpen || now - lastHeaderUpdate > 0.8) {
                lastHeaderText = header
                lastHeaderUpdate = now
                monitorMenuItem?.attributedTitle = nil
                monitorMenuItem?.title = header
            }
            updateMonitorDetailList()
        }

        if let r = rssi {
            lastRSSI = r
        }
        refreshStatusIcon()
    }

    func bluetoothPowerWarn() {
        errorModal(t("bluetooth_power_warn"))
    }

    func notifyUser(_ reason: String, deviceName: String? = nil) {
        let content = UNMutableNotificationContent()
        if reason == "lost" {
            content.title = t("notification_lost_signal")
        } else if reason == "away" {
            content.title = t("notification_device_away")
        } else {
            content.title = "BLELock"
        }

        let computerName = Host.current().localizedName ?? "Mac"
        let device = deviceName ?? t("unknown_device")
        content.body = String(format: t("notification_locked"), computerName, device)
        
        let request = UNNotificationRequest(identifier: "lock", content: content, trigger: nil) // Immediate
        UNUserNotificationCenter.current().add(request)
    }

    func updateCountdown(seconds: Int, reason: String) {
        let content = UNMutableNotificationContent()
        if reason == "lost" {
            content.title = t("notification_lost_signal")
        } else if reason == "away" {
            content.title = t("notification_device_away")
        } else {
            content.title = "BLELock"
        }

        content.body = String(format: t("locking_in_seconds"), seconds)
        
        // Use a persistent identifier for countdown so we update the same notification
        let request = UNNotificationRequest(identifier: "countdown", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    func cancelCountdown(reason: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["countdown"])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Do not play sound for countdown updates to avoid spamming
        if notification.request.identifier == "countdown" {
            completionHandler([.banner]) // No sound
        } else {
            completionHandler([.banner, .sound])
        }
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == "update" {
            NSWorkspace.shared.open(URL(string: "https://github.com/ShawnRn/BLEUnlock/releases")!)
        }
        completionHandler()
    }


    func runScript(_ arg: String) {
        guard let directory = try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let file = directory.appendingPathComponent("event")
        let process = Process()
        process.executableURL = file
        if let r = lastRSSI {
            process.arguments = [arg, String(r)]
        } else {
            process.arguments = [arg]
        }
        try? process.run()
    }

    func pauseNowPlaying() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        MRMediaRemoteGetNowPlayingApplicationIsPlaying(
            DispatchQueue.main,
            { (playing) in
                Task { @MainActor in
                    self.nowPlayingWasPlaying = playing
                    if self.nowPlayingWasPlaying {
                        print("pause")
                        MRMediaRemoteSendCommand(MRCommandPause, nil)
                    }
                }
            }
        )
    }
    
    func playNowPlaying() {
        guard prefs.bool(forKey: "pauseItunes") else { return }
        if nowPlayingWasPlaying {
            print("play")
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false, block: { _ in
                Task { @MainActor in
                    MRMediaRemoteSendCommand(MRCommandPlay, nil)
                    self.nowPlayingWasPlaying = false
                }
            })
        }
    }

    func lockOrSaveScreen() {
        // Clear countdown notification when locking
        cancelCountdown(reason: "")
        
        if prefs.bool(forKey: "screensaver") {
            if let url = URL(string: "file:///System/Library/CoreServices/ScreenSaverEngine.app") {
                NSWorkspace.shared.open(url)
            }
        } else {
            if SACLockScreenImmediate() != 0 {
                print("Failed to lock screen (likely permission issue). Please use 'screensaver' option as a fallback.")
            }
            if prefs.bool(forKey: "sleepDisplay") {
                print("sleep display")
                sleepDisplay()
            }
        }
    }

    func runShortcutIfNeeded(reason: String) {
        guard let name = shortcutName, !name.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            print("Failed to launch shortcuts: \(error)")
            return
        }
        process.terminationHandler = { _ in
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("Shortcuts error (\(reason)): \(output)")
            }
        }
    }

    func updatePresence(presence: Bool, reason: String, deviceUUID: UUID?) {
        if !presence {
            if (!isScreenLocked() && ble.lockRSSI != ble.LOCK_DISABLED) {
                pauseNowPlaying()
                lockOrSaveScreen()
                let deviceName = deviceUUID.flatMap { deviceNameMap[$0] } ?? deviceUUID?.uuidString ?? "Unknown Device"
                notifyUser(reason, deviceName: deviceName)
                runScript(reason)
                runShortcutIfNeeded(reason: reason)
            }
        }
    }

    func isScreenLocked() -> Bool {
        if let dict = CGSessionCopyCurrentDictionary() as? [String : Any] {
            if let locked = dict["CGSSessionScreenIsLocked"] as? Int {
                return locked == 1
            }
        }
        return false
    }

    @objc func onDisplayWake() {
        print("display wake")
        displaySleep = false
    }

    @objc func onDisplaySleep() {
        print("display sleep")
        displaySleep = true
    }

    @objc func onSystemWake() {
        print("system wake")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false, block: { _ in
            MainActor.assumeIsolated {
                print("delayed system wake job")
                if self.prefs.bool(forKey: "showDockIcon") {
                    NSApp.setActivationPolicy(.regular)
                } else {
                    NSApp.setActivationPolicy(.accessory) // Hide Dock icon again
                }
                self.systemSleep = false
                self.ble.scanForPeripherals()
            }
        })
    }
    
    @objc func onSystemSleep() {
        print("system sleep")
        systemSleep = true
        // Set activation policy to regular, so the CBCentralManager can scan for peripherals
        // when the Bluetooth will become on again.
        // This enables Dock icon but the screen is off anyway.
        NSApp.setActivationPolicy(.regular)
        // Pause scanning to avoid影响休眠
        ble.stopScanning()
    }


    @objc func onScreensaverStart() {
        print("screensaver start")
        inScreensaver = true
    }

    @objc func onScreensaverStop() {
        print("screensaver stop")
        inScreensaver = false
    }

    @objc func selectDevice(_ sender: NSMenuItem) {
        for (uuid, menuItem) in deviceDict {
            if menuItem == sender {
                let nowOn = menuItem.state == .off
                menuItem.state = nowOn ? .on : .off
                if nowOn {
                    ble.monitoredUUIDs.insert(uuid)
                } else {
                    ble.monitoredUUIDs.remove(uuid)
                }
            }
        }
        persistMonitoredDevices()
        monitorDevice(uuids: ble.monitoredUUIDs)
        updateMonitorMenuTitle()
    }

    func persistMonitoredDevices() {
        let ids = ble.monitoredUUIDs.map { $0.uuidString }
        prefs.set(ids, forKey: "devices")
    }

    func monitorDevice(uuids: Set<UUID>) {
        monitorMenuItem?.title = t("not_detected")
        ble.startMonitor(uuids: uuids)
        refreshStatusIcon()
    }

    func errorModal(_ msg: String, info: String? = nil) {
        let alert = NSAlert()
        alert.messageText = msg
        alert.informativeText = info ?? ""
        alert.window.title = "BLELock"
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    
    
    @objc func setRSSIThreshold() {
        let msg = NSAlert()
        msg.addButton(withTitle: t("ok"))
        msg.addButton(withTitle: t("cancel"))
        msg.messageText = t("enter_rssi_threshold")
        msg.informativeText = t("enter_rssi_threshold_info")
        msg.window.title = "BLELock"
        
        let txt = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 20))
        txt.placeholderString = String(ble.thresholdRSSI)
        msg.accessoryView = txt
        txt.becomeFirstResponder()
        NSApp.activate(ignoringOtherApps: true)
        let response = msg.runModal()
        
        if (response == .alertFirstButtonReturn) {
            let val = txt.intValue
            ble.thresholdRSSI = Int(val)
            prefs.set(val, forKey: "thresholdRSSI")
        }
    }

    @objc func toggleWakeOnProximity(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "wakeOnProximity")
        menuItem.state = value ? .on : .off
        prefs.set(value, forKey: "wakeOnProximity")
    }

    @objc func setLockRSSI(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "lockRSSI")
        ble.lockRSSI = value
    }
    

    @objc func setTimeout(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "timeout")
        ble.signalTimeout = Double(value)
    }

    @objc func setLockDelay(_ menuItem: NSMenuItem) {
        let value = menuItem.tag
        prefs.set(value, forKey: "lockDelay")
        ble.proximityTimeout = Double(value)
    }

    @objc func toggleLaunchAtLogin(_ menuItem: NSMenuItem) {
        let launchAtLogin = !prefs.bool(forKey: "launchAtLogin")
        prefs.set(launchAtLogin, forKey: "launchAtLogin")
        menuItem.state = launchAtLogin ? .on : .off
        
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                try service.register()
                NSLog("BLELock: SMAppService registered successfully via toggle")
            } else {
                try service.unregister()
                NSLog("BLELock: SMAppService unregistered successfully via toggle")
            }
        } catch {
            NSLog("BLELock: Failed to update launch at login: \(error.localizedDescription)")
        }
    }

    func syncLaunchAtLoginStatus() {
        let launchAtLogin = prefs.bool(forKey: "launchAtLogin")
        let service = SMAppService.mainApp
        let status = service.status
        NSLog("BLELock: syncLaunchAtLoginStatus: launchAtLogin is \(launchAtLogin), SMAppService status is \(status.rawValue)")
        
        if launchAtLogin {
            if status != .enabled {
                do {
                    try service.register()
                    NSLog("BLELock: SMAppService registered successfully on launch")
                } catch {
                    NSLog("BLELock: Failed to register SMAppService on launch: \(error.localizedDescription)")
                }
            }
        } else {
            if status == .enabled {
                do {
                    try service.unregister()
                    NSLog("BLELock: SMAppService unregistered successfully on launch")
                } catch {
                    NSLog("BLELock: Failed to unregister SMAppService on launch: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc func togglePauseNowPlaying(_ menuItem: NSMenuItem) {
        let pauseNowPlaying = !prefs.bool(forKey: "pauseItunes")
        prefs.set(pauseNowPlaying, forKey: "pauseItunes")
        menuItem.state = pauseNowPlaying ? .on : .off
    }
    
    @objc func toggleUseScreensaver(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "screensaver")
        prefs.set(value, forKey: "screensaver")
        menuItem.state = value ? .on : .off
    }

    @objc func toggleSleepDisplay(_ menuItem: NSMenuItem) {
        let value = !prefs.bool(forKey: "sleepDisplay")
        prefs.set(value, forKey: "sleepDisplay")
        menuItem.state = value ? .on : .off
    }

    func loadShortcutList() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var list = text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        list.insert(t("shortcut_none"), at: 0)
        return list
    }

    func refreshShortcutMenu() {
        shortcutMenu.removeAllItems()
        let shortcuts = loadShortcutList()
        for name in shortcuts {
            let item = shortcutMenu.addItem(withTitle: name, action: #selector(selectShortcut(_:)), keyEquivalent: "")
            item.target = self
            let selectedName = shortcutName ?? t("shortcut_none")
            item.state = (name == selectedName) ? .on : .off
        }
    }

    @objc func selectShortcut(_ menuItem: NSMenuItem) {
        if menuItem.title == t("shortcut_none") {
            shortcutName = nil
        } else {
            shortcutName = menuItem.title
        }
        prefs.set(shortcutName, forKey: "shortcutName")
        refreshShortcutMenu()
    }
    
    @objc func togglePassiveMode(_ menuItem: NSMenuItem) {
        let passiveMode = !prefs.bool(forKey: "passiveMode")
        prefs.set(passiveMode, forKey: "passiveMode")
        menuItem.state = passiveMode ? .on : .off
        ble.setPassiveMode(passiveMode)
    }

    @objc func togglePauseOnBattery(_ menuItem: NSMenuItem) {
        let enabled = !prefs.bool(forKey: "pauseOnBattery")
        prefs.set(enabled, forKey: "pauseOnBattery")
        menuItem.state = enabled ? .on : .off
        applyPauseOnBatteryPolicy()
    }

    func isRunningOnBattery() -> Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        if let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            return source == kIOPSBatteryPowerValue
        }
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let state = desc[kIOPSPowerSourceStateKey as String] as? String, state == kIOPSBatteryPowerValue {
                return true
            }
        }
        return false
    }

    func setupPowerSourceMonitoring() {
        guard powerSourceRunLoopSource == nil else { return }
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let source = IOPSNotificationCreateRunLoopSource(powerSourceChangedCallback, context)?.takeRetainedValue() else { return }
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func applyPauseOnBatteryPolicy() {
        let onBattery = isRunningOnBattery()
        let enabled = prefs.bool(forKey: "pauseOnBattery")
        let shouldPause = enabled && onBattery
        print("PauseOnBattery: enabled=\(enabled) onBattery=\(onBattery) suspended=\(shouldPause)")
        ble.setSuspended(shouldPause)
        updateMonitorMenuTitle()
        updateMonitorDetailList()
        refreshStatusIcon()
    }


    @objc func toggleShowDockIcon(_ menuItem: NSMenuItem) {
        let show = !prefs.bool(forKey: "showDockIcon")
        prefs.set(show, forKey: "showDockIcon")
        menuItem.state = show ? .on : .off
        
        Task { @MainActor in
            if show {
                NSApp.setActivationPolicy(.regular)
                // Bring to front several times to ensure Dock icon appears
                NSApp.activate(ignoringOtherApps: true)
                for i in 0..<3 {
                    try? await Task.sleep(nanoseconds: 100_000_000 * UInt64(i + 1))
                    NSApp.activate(ignoringOtherApps: true)
                }
            } else {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    @objc func lockNow() {
        guard !isScreenLocked() else { return }
        pauseNowPlaying()
        lockOrSaveScreen()
        runShortcutIfNeeded(reason: "manual")
    }
    
    @objc func showAboutBox() {
        AboutBox.showAboutBox()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isQuittingValidated || isSystemPoweringOff {
            return .terminateNow
        }

        let context = LAContext()
        var error: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) {
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: t("auth_to_quit")) { success, evaluateError in
                DispatchQueue.main.async {
                    if success {
                        self.isQuittingValidated = true
                        NSApplication.shared.reply(toApplicationShouldTerminate: true)
                    } else {
                        if let error = evaluateError as NSError?, error.code != LAError.userCancel.rawValue {
                            self.errorModal(t("error"), info: error.localizedDescription)
                        }
                        NSApplication.shared.reply(toApplicationShouldTerminate: false)
                    }
                }
            }
            return .terminateLater
        } else {
            // Biometric or password auth not available, just quit
            return .terminateNow
        }
    }

    @objc func onSystemPowerOff() {
        print("System power off")
        isSystemPoweringOff = true
    }

    func constructRSSIMenu(_ menu: NSMenu, _ action: Selector) {
        menu.addItem(withTitle: t("closer"), action: nil, keyEquivalent: "")
        for proximity in stride(from: -30, to: -100, by: -5) {
            let item = menu.addItem(withTitle: String(format: "%ddBm", proximity), action: action, keyEquivalent: "")
            item.tag = proximity
        }
        menu.addItem(withTitle: t("farther"), action: nil, keyEquivalent: "")
        menu.delegate = self
    }
    
    func constructMenu() {
        monitorMenuItem = mainMenu.addItem(withTitle: t("device_not_set"), action: nil, keyEquivalent: "")
        monitorMenuItem?.submenu = monitorDetailMenu
        monitorDetailMenu.autoenablesItems = false
        
        var item: NSMenuItem

        item = mainMenu.addItem(withTitle: t("lock_now"), action: #selector(lockNow), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())

        item = mainMenu.addItem(withTitle: t("device"), action: nil, keyEquivalent: "")
        item.submenu = deviceMenu
        deviceMenu.delegate = self
        deviceMenu.addItem(withTitle: t("scanning"), action: nil, keyEquivalent: "")


        let lockRSSIItem = mainMenu.addItem(withTitle: t("lock_rssi"), action: nil, keyEquivalent: "")
        lockRSSIItem.submenu = lockRSSIMenu
        constructRSSIMenu(lockRSSIMenu, #selector(setLockRSSI))
        item = lockRSSIMenu.addItem(withTitle: t("disabled"), action: #selector(setLockRSSI), keyEquivalent: "")
        item.tag = ble.LOCK_DISABLED

        let lockDelayItem = mainMenu.addItem(withTitle: t("lock_delay"), action: nil, keyEquivalent: "")
        lockDelayItem.submenu = lockDelayMenu
        lockDelayMenu.addItem(withTitle: "2 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 2
        lockDelayMenu.addItem(withTitle: "5 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 5
        lockDelayMenu.addItem(withTitle: "15 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 15
        lockDelayMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setLockDelay), keyEquivalent: "").tag = 30
        lockDelayMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setLockDelay), keyEquivalent: "").tag = 60
        lockDelayMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 120
        lockDelayMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setLockDelay), keyEquivalent: "").tag = 300
        lockDelayMenu.delegate = self

        let timeoutItem = mainMenu.addItem(withTitle: t("timeout"), action: nil, keyEquivalent: "")
        timeoutItem.submenu = timeoutMenu
        timeoutMenu.addItem(withTitle: "10 " + t("seconds"), action: #selector(setTimeout), keyEquivalent: "").tag = 10
        timeoutMenu.addItem(withTitle: "30 " + t("seconds"), action: #selector(setTimeout), keyEquivalent: "").tag = 30
        timeoutMenu.addItem(withTitle: "1 " + t("minute"), action: #selector(setTimeout), keyEquivalent: "").tag = 60
        timeoutMenu.addItem(withTitle: "2 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 120
        timeoutMenu.addItem(withTitle: "5 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 300
        timeoutMenu.addItem(withTitle: "10 " + t("minutes"), action: #selector(setTimeout), keyEquivalent: "").tag = 600
        timeoutMenu.delegate = self

        item = mainMenu.addItem(withTitle: t("wake_on_proximity"), action: #selector(toggleWakeOnProximity), keyEquivalent: "")
        if prefs.bool(forKey: "wakeOnProximity") {
            item.state = .on
        }


        item = mainMenu.addItem(withTitle: t("pause_now_playing"), action: #selector(togglePauseNowPlaying), keyEquivalent: "")
        if prefs.bool(forKey: "pauseItunes") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("use_screensaver_to_lock"), action: #selector(toggleUseScreensaver), keyEquivalent: "")
        if prefs.bool(forKey: "screensaver") {
            item.state = .on
        }

        item = mainMenu.addItem(withTitle: t("sleep_display"), action: #selector(toggleSleepDisplay), keyEquivalent: "")
        if prefs.bool(forKey: "sleepDisplay") {
            item.state = .on
        }
        
        item = mainMenu.addItem(withTitle: t("run_shortcut_on_lock"), action: nil, keyEquivalent: "")
        item.submenu = shortcutMenu
        shortcutMenu.delegate = self
        refreshShortcutMenu()


        item = mainMenu.addItem(withTitle: t("passive_mode"), action: #selector(togglePassiveMode), keyEquivalent: "")
        item.state = prefs.bool(forKey: "passiveMode") ? .on : .off

        item = mainMenu.addItem(withTitle: t("pause_on_battery"), action: #selector(togglePauseOnBattery), keyEquivalent: "")
        item.state = prefs.bool(forKey: "pauseOnBattery") ? .on : .off
        
        item = mainMenu.addItem(withTitle: t("launch_at_login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        item.state = prefs.bool(forKey: "launchAtLogin") ? .on : .off
        
        item = mainMenu.addItem(withTitle: t("show_dock_icon"), action: #selector(toggleShowDockIcon), keyEquivalent: "")
        item.state = prefs.bool(forKey: "showDockIcon") ? .on : .off

        mainMenu.addItem(withTitle: t("set_rssi_threshold"), action: #selector(setRSSIThreshold),
                         keyEquivalent: "")

        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("about"), action: #selector(showAboutBox), keyEquivalent: "")
        mainMenu.addItem(NSMenuItem.separator())
        mainMenu.addItem(withTitle: t("quit"), action: #selector(quitApp), keyEquivalent: "q")
        statusItem.menu = mainMenu
    }


    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Enforce single instance: kill other instances of BLELock or BLEUnlock
        let runningApps = NSWorkspace.shared.runningApplications
        let currentApp = NSRunningApplication.current
        for app in runningApps {
            if app != currentApp {
                if app.bundleIdentifier == "com.shawnrain.BLELock" || 
                   app.bundleIdentifier == "com.shawnrain.BLEUnlock" {
                    print("Terminating existing instance: \(app.bundleIdentifier ?? "unknown")")
                    app.terminate()
                }
            }
        }

        if let button = statusItem.button {
            button.image = NSImage(named: "StatusBarDisconnected")
            constructMenu()
        }
        syncLaunchAtLoginStatus()
        ble.delegate = self
        var initialUUIDs: Set<UUID> = []
        if let arr = prefs.array(forKey: "devices") as? [String] {
            for s in arr {
                if let u = UUID(uuidString: s) {
                    initialUUIDs.insert(u)
                }
            }
        } else if let str = prefs.string(forKey: "device"), let uuid = UUID(uuidString: str) {
            initialUUIDs.insert(uuid)
        }
        ble.monitoredUUIDs = initialUUIDs
        updateMonitorMenuTitle()
        // Start scanning immediately to populate names/RSSI without menu open
        ble.startScanning()
        monitorDevice(uuids: initialUUIDs)
        updateMonitorDetailList()
        refreshStatusIcon()
        let lockRSSI = prefs.integer(forKey: "lockRSSI")
        if lockRSSI != 0 {
            ble.lockRSSI = lockRSSI
        }
        if prefs.object(forKey: "timeout") != nil {
            ble.signalTimeout = Double(prefs.integer(forKey: "timeout"))
        }
        ble.setPassiveMode(prefs.bool(forKey: "passiveMode"))
        setupPowerSourceMonitoring()
        applyPauseOnBatteryPolicy()
        if let sc = prefs.string(forKey: "shortcutName") {
            shortcutName = sc
        }
        let thresholdRSSI = prefs.integer(forKey: "thresholdRSSI")
        if thresholdRSSI != 0 {
            ble.thresholdRSSI = thresholdRSSI
        }

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(onSystemPowerOff), 
                                                          name: NSWorkspace.willPowerOffNotification, object: nil)

        let lockDelay = prefs.integer(forKey: "lockDelay")
        if lockDelay != 0 {
            ble.proximityTimeout = Double(lockDelay)
        }

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }

        let nc = NSWorkspace.shared.notificationCenter;
        nc.addObserver(self, selector: #selector(onDisplaySleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onDisplayWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemSleep), name: NSWorkspace.willSleepNotification, object: nil)
        nc.addObserver(self, selector: #selector(onSystemWake), name: NSWorkspace.didWakeNotification, object: nil)

        let dnc = DistributedNotificationCenter.default
        dnc.addObserver(self, selector: #selector(onScreensaverStart), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstart"), object: nil)
        dnc.addObserver(self, selector: #selector(onScreensaverStop), name: NSNotification.Name(rawValue: "com.apple.screensaver.didstop"), object: nil)

        checkUpdate()

        // 禁用 App Nap：确保 BLE 扫描回调和 Timer 在后台不被系统节能机制暂停
        ProcessInfo.processInfo.disableAutomaticTermination("BLE monitoring active")
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "BLE device monitoring requires timely timer firing"
        )

        // Hide dock icon.
        // This is required because we can't have LSUIElement set to true in Info.plist,
        // otherwise CBCentralManager.scanForPeripherals won't work.
        if prefs.bool(forKey: "showDockIcon") {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSourceRunLoopSource = nil
        }
    }
}

@_silgen_name("SACLockScreenImmediate")
func SACLockScreenImmediate() -> Int32

/// Wakes the display by declaring user activity.
@MainActor
func wakeDisplay() {
    var assertionID: IOPMAssertionID = 0
    let result = IOPMAssertionDeclareUserActivity("BLELock" as CFString, kIOPMUserActiveLocal, &assertionID)
    if result != kIOReturnSuccess {
        print("Failed to wake display: \(result)")
    }
}

/// Sleeps the display by communicating with the IODisplayWrangler.
@MainActor
func sleepDisplay() {
    let reg = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/IOResources/IODisplayWrangler")
    if reg != 0 {
        IORegistryEntrySetCFProperty(reg, "IORequestIdle" as CFString, kCFBooleanTrue)
        IOObjectRelease(reg)
    } else {
        print("Failed to get IODisplayWrangler registry entry")
    }
}
