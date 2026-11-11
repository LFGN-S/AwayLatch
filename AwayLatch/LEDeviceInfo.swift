import Foundation
import SQLite3

struct LEDeviceInfo {
    let name: String?
    let macAddr: String?
    let isPaired: Bool
}

@MainActor private let pairedDatabase = openReadOnlyDatabase("paired")
@MainActor private let otherDatabase = openReadOnlyDatabase("other")

private func openReadOnlyDatabase(_ kind: String) -> OpaquePointer? {
    let path = "/Library/Bluetooth/com.apple.MobileBluetooth.ledevices.\(kind).db"
    var database: OpaquePointer?
    guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(database)
        return nil
    }
    return database
}

private func stringFromColumn(_ statement: OpaquePointer?, _ index: Int32) -> String? {
    guard let text = sqlite3_column_text(statement, index) else { return nil }
    let value = String(cString: text).trimmingCharacters(in: .whitespaces)
    return value.isEmpty ? nil : value
}

private func deviceInfo(in database: OpaquePointer?, uuid: UUID, paired: Bool) -> LEDeviceInfo? {
    guard let database else { return nil }
    let columns = paired ? "Name, Address, ResolvedAddress FROM PairedDevices" : "Name, Address FROM OtherDevices"
    let sql = "SELECT \(columns) WHERE Uuid = '\(uuid.uuidString)' COLLATE NOCASE"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

    let resolvedAddress = paired ? stringFromColumn(statement, 2) : nil
    let address = resolvedAddress ?? stringFromColumn(statement, 1)
    let mac = address?.split(separator: " ").last.map(String.init)
    return LEDeviceInfo(name: stringFromColumn(statement, 0), macAddr: mac, isPaired: paired)
}

@MainActor
final class BluetoothDeviceLookup {
    private lazy var legacyCache = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.Bluetooth.plist")
    private lazy var peripherals = legacyCache?["CoreBluetoothCache"] as? NSDictionary
    private lazy var devices = legacyCache?["DeviceCache"] as? NSDictionary

    func info(for uuid: UUID) -> LEDeviceInfo {
        let info = deviceInfo(in: pairedDatabase, uuid: uuid, paired: true) ??
            deviceInfo(in: otherDatabase, uuid: uuid, paired: false)
        let address = info?.macAddr ?? legacyAddress(for: uuid)
        let name = info?.name ?? address.flatMap(legacyName(for:))
        return LEDeviceInfo(name: name, macAddr: address, isPaired: info?.isPaired == true)
    }

    private func legacyAddress(for uuid: UUID) -> String? {
        let peripheral = peripherals?[uuid.uuidString] as? NSDictionary
        return peripheral?["DeviceAddress"] as? String
    }

    private func legacyName(for address: String) -> String? {
        let device = devices?[address] as? NSDictionary
        let name = (device?["Name"] as? String)?.trimmingCharacters(in: .whitespaces)
        return name?.isEmpty == false ? name : nil
    }
}
