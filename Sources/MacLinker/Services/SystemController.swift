import Foundation
import CoreAudio
import CoreGraphics
import IOKit

/// Reads and changes this Mac's output volume and display brightness.
///
/// - Volume uses the public CoreAudio API.
/// - Brightness on a built-in display uses the system DisplayServices framework (private, loaded at
///   runtime, so a missing symbol just means "unsupported").
/// - Brightness on external monitors uses DDC/CI over IOAVService (Apple Silicon only, also private).
///   Intel Macs report no external brightness control.
/// Nothing here throws: unsupported features report themselves through `SystemStatePayload`.
final class SystemController {
    private var lastExternalBrightness: Float = -1

    // MARK: State

    func state() -> SystemStatePayload {
        let vol = volume()
        let builtIn = builtInBrightness()
        let external = !externalServices().isEmpty
        return SystemStatePayload(hasBrightness: builtIn != nil || external,
                                  hasVolume: vol != nil,
                                  brightness: builtIn ?? lastExternalBrightness,
                                  volume: vol ?? -1,
                                  muted: isMuted() ?? false)
    }

    // MARK: Volume (CoreAudio)

    private func outputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    /// 'vmvc': the device's virtual main volume, the one the system volume keys change.
    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: 0x766D_7663, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func volume() -> Float? {
        guard let dev = outputDevice() else { return nil }
        var addr = volumeAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    func setVolume(_ value: Float) -> Bool {
        guard let dev = outputDevice() else { return false }
        var addr = volumeAddress()
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(dev, &addr),
              AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return false }
        var v = Float32(min(max(value, 0), 1))
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    func isMuted() -> Bool? {
        guard let dev = outputDevice() else { return nil }
        var addr = muteAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m) == noErr ? m != 0 : nil
    }

    @discardableResult
    func setMuted(_ muted: Bool) -> Bool {
        guard let dev = outputDevice() else { return false }
        var addr = muteAddress()
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(dev, &addr),
              AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue else { return false }
        var m: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) == noErr
    }

    // MARK: Brightness

    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32

    private lazy var displayServices: (get: GetBrightness, set: SetBrightness)? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let g = dlsym(h, "DisplayServicesGetBrightness"), let s = dlsym(h, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(g, to: GetBrightness.self), unsafeBitCast(s, to: SetBrightness.self))
    }()

    private func builtInDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) != 0 }
    }

    func builtInBrightness() -> Float? {
        guard let ds = displayServices, let id = builtInDisplays().first else { return nil }
        var b: Float = 0
        return ds.get(id, &b) == 0 ? b : nil
    }

    /// Sets brightness on every built-in display and every DDC-capable external monitor.
    @discardableResult
    func setBrightness(_ value: Float) -> Bool {
        let v = min(max(value, 0), 1)
        var ok = false
        if let ds = displayServices {
            for id in builtInDisplays() where ds.set(id, v) == 0 { ok = true }
        }
        for service in externalServices() where Self.ddcSet(service, code: 0x10, value: UInt16((v * 100).rounded())) {
            ok = true
            lastExternalBrightness = v
        }
        return ok
    }

    // MARK: DDC/CI over IOAVService (Apple Silicon)

    private typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias WriteI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32

    private static let avFunctions: (create: CreateService, write: WriteI2C)? = {
        guard let c = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOAVServiceCreateWithService"),  // RTLD_DEFAULT
              let w = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOAVServiceWriteI2C") else { return nil }
        return (unsafeBitCast(c, to: CreateService.self), unsafeBitCast(w, to: WriteI2C.self))
    }()

    private func externalServices() -> [CFTypeRef] {
        guard let fn = Self.avFunctions else { return [] }
        var iterator = io_iterator_t()
        guard IORegistryCreateIterator(kIOMainPortDefault, "IOService", IOOptionBits(kIORegistryIterateRecursively),
                                       &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [CFTypeRef] = []
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &name)
            if String(cString: name) == "DCPAVServiceProxy",
               let loc = IORegistryEntrySearchCFProperty(entry, kIOServicePlane, "Location" as CFString,
                                                         kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively)) as? String,
               loc == "External", let svc = fn.create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                found.append(svc)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return found
    }

    /// DDC/CI "Set VCP Feature" packet. The checksum covers the destination (0x6E) and source (0x51)
    /// addresses plus every byte before it.
    static func ddcPacket(code: UInt8, value: UInt16) -> [UInt8] {
        var data: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF)]
        data.append(data.reduce(0x6E ^ 0x51, ^))
        return data
    }

    private static func ddcSet(_ service: CFTypeRef, code: UInt8, value: UInt16) -> Bool {
        guard let fn = avFunctions else { return false }
        for _ in 0..<3 {  // monitors drop packets now and then
            var data = ddcPacket(code: code, value: value)
            if fn.write(service, 0x37, 0x51, &data, UInt32(data.count)) == 0 { return true }
            usleep(10_000)
        }
        return false
    }
}
