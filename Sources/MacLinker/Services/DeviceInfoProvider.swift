import Foundation
import IOKit
import IOKit.ps
import CoreAudio
import Network

/// Reads this Mac's attached keyboards and mice, audio output, network link and kind.
/// Everything is read from the IORegistry and CoreAudio, so it needs no permission and doesn't open any device.
enum DeviceInfoProvider {
    static func snapshot(link: NWInterface?) -> DeviceInfoPayload {
        let (keyboards, pointers) = peripherals()
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceInfoPayload(kind: isLaptop() ? "laptop" : "desktop", model: hardwareModel(),
                                 osVersion: "macOS \(v.majorVersion).\(v.minorVersion)",
                                 keyboards: keyboards, pointers: pointers,
                                 audioOutput: audioOutputName(), network: linkName(link))
    }

    // MARK: Keyboards and mice

    static func peripherals() -> ([DeviceInfoPayload.Peripheral], [DeviceInfoPayload.Peripheral]) {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) == KERN_SUCCESS else {
            return ([], [])
        }
        defer { IOObjectRelease(iterator) }
        var keyboards: [DeviceInfoPayload.Peripheral] = []
        var pointers: [DeviceInfoPayload.Peripheral] = []
        let batteries = batteryByAddress()
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
            guard let info = classify(dict, batteries: batteries) else { continue }
            if info.isKeyboard { insert(info.peripheral, into: &keyboards) }
            if info.isPointer { insert(info.peripheral, into: &pointers) }
        }
        return (keyboards, pointers)
    }

    /// Pure function so it can be tested with sample registry dictionaries.
    static func classify(_ dict: [String: Any], batteries: [String: Int] = [:])
        -> (peripheral: DeviceInfoPayload.Peripheral, isKeyboard: Bool, isPointer: Bool)? {
        guard let name = (dict["Product"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        let transport = dict["Transport"] as? String ?? ""
        if transport == "Virtual" { return nil }          // software devices (remapping tools, remote desktop)
        var pairs: [(Int, Int)] = []
        for p in (dict["DeviceUsagePairs"] as? [[String: Any]]) ?? [] {
            if let page = p["DeviceUsagePage"] as? Int, let usage = p["DeviceUsage"] as? Int { pairs.append((page, usage)) }
        }
        if let page = dict["PrimaryUsagePage"] as? Int, let usage = dict["PrimaryUsage"] as? Int { pairs.append((page, usage)) }
        // Generic Desktop: keyboard 6, mouse 2, pointer 1. Digitizer page 0x0D: touch pad 5.
        let isKeyboard = pairs.contains { $0.0 == 1 && $0.1 == 6 }
        let hasPointerUsage = pairs.contains { ($0.0 == 1 && ($0.1 == 2 || $0.1 == 1)) || ($0.0 == 0x0D && $0.1 == 5) }
        // Many keyboards expose an extra mouse interface; only count it as a pointer if it really is one.
        let lower = name.lowercased()
        let isPointer = hasPointerUsage && (!isKeyboard || lower.contains("trackpad") || lower.contains("mouse"))
        guard isKeyboard || isPointer else { return nil }
        let byAddress = (dict["DeviceAddress"] as? String).flatMap { batteries[normalized($0)] }
        let byModel = (dict["VendorID"] as? Int).flatMap { v in (dict["ProductID"] as? Int).flatMap { batteries["\(v):\($0)"] } }
        let reported = (dict["BatteryPercent"] as? Int) ?? byAddress ?? byModel
        let battery = reported.flatMap { (0...100).contains($0) ? $0 : nil }
        return (.init(name: name, transport: transportName(transport, name: name), battery: battery), isKeyboard, isPointer)
    }

    /// Apple's Bluetooth devices report their battery on a separate registry entry, matched by Bluetooth address.
    static func batteryByAddress() -> [String: Int] {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var result: [String: Int] = [:]
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer { IOObjectRelease(entry); entry = IOIteratorNext(iterator) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let level = dict["BatteryPercent"] as? Int else { continue }
            if let address = dict["DeviceAddress"] as? String { result[normalized(address)] = level }
            // The HID entry for the same device doesn't always carry the address, but shares vendor and product IDs.
            if let v = dict["VendorID"] as? Int, let p = dict["ProductID"] as? Int { result["\(v):\(p)"] = level }
        }
        return result
    }

    static func normalized(_ address: String) -> String { address.lowercased().replacingOccurrences(of: ":", with: "-") }

    static func transportName(_ raw: String, name: String) -> String {
        switch raw {
        case "USB": return "USB"
        case "Bluetooth", "Bluetooth Low Energy": return "Bluetooth"
        case "SPI", "FIFO", "I2C", "Apple Internal": return "Built-in"
        default: return name.lowercased().contains("internal") ? "Built-in" : (raw.isEmpty ? "Wired" : raw)
        }
    }

    private static func insert(_ p: DeviceInfoPayload.Peripheral, into list: inout [DeviceInfoPayload.Peripheral]) {
        // One physical device often appears as several HID interfaces; keep the one that reports a battery.
        if let i = list.firstIndex(where: { $0.name == p.name && $0.transport == p.transport }) {
            if list[i].battery == nil, p.battery != nil { list[i] = p }
        } else {
            list.append(p)
        }
    }

    // MARK: Everything else

    static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }

    /// A Mac with an internal battery is a laptop.
    static func isLaptop() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            (IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any])?[kIOPSTypeKey] as? String
                == kIOPSInternalBatteryType
        }
    }

    static func audioOutputName() -> String? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &nameAddr, 0, nil, &nameSize, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    static func linkName(_ interface: NWInterface?) -> String? {
        guard let i = interface else { return nil }
        if i.name.hasPrefix("bridge") { return "USB-C cable" }
        switch i.type {
        case .wiredEthernet: return "Ethernet"
        case .wifi: return "Wi-Fi"
        default: return "Other"
        }
    }
}
