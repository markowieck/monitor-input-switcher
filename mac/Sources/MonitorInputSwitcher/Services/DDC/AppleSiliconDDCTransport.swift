import Foundation
import IOKit
import CoreGraphics

/// DDC/CI transport for Apple Silicon Macs.
///
/// Apple Silicon Macs don't expose external displays as classic
/// IOFramebuffer devices, so the public `IOFBCopyI2CInterfaceForBus` API
/// (used by `IntelDDCTransport`) never finds a bus there. Instead, the
/// display co-processor exposes an "AVService" per external display that
/// supports raw I2C passthrough. The entry points (`IOAVServiceCreate`,
/// `IOAVServiceCreateWithService`, `IOAVServiceReadI2C`,
/// `IOAVServiceWriteI2C`) are undocumented but are ordinary exported
/// symbols in the system's IOKit.framework, so they're resolved here at
/// runtime via dlsym rather than linked at compile time. This mirrors the
/// well-known technique used by several open-source DDC/CI utilities for
/// Apple Silicon.
final class AppleSiliconDDCTransport: DDCTransport {
    let displayName: String
    let edidIdentity: String?
    let edidSerialNumber: String?
    private let service: AnyObject

    private typealias ReadFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias WriteFn = @convention(c) (AnyObject, UInt32, UInt32, UnsafeRawPointer, UInt32) -> IOReturn
    private typealias CreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    private static let readFn: ReadFn? = symbol("IOAVServiceReadI2C")
    private static let writeFn: WriteFn? = symbol("IOAVServiceWriteI2C")
    private static let createWithServiceFn: CreateWithServiceFn? = symbol("IOAVServiceCreateWithService")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    private init(displayName: String, edidIdentity: String?, edidSerialNumber: String?, service: AnyObject) {
        self.displayName = displayName
        self.edidIdentity = edidIdentity
        self.edidSerialNumber = edidSerialNumber
        self.service = service
    }

    /// Whether this build is even capable of using the Apple Silicon path
    /// (i.e. the private symbols resolved successfully).
    static var isAvailable: Bool {
        readFn != nil && writeFn != nil && createWithServiceFn != nil
    }

    /// Finding a display's EDID data takes two passes, because it doesn't
    /// live on the "DCPAVServiceProxy" node this transport is actually
    /// built from (that one only carries `Location` and is what
    /// `IOAVServiceCreateWithService` needs) - it's on a separate
    /// "AppleCLCD2"/"IOMobileFramebufferShim" node with no parent/child
    /// relationship to its DCPAVServiceProxy counterpart. The two are
    /// just positioned next to each other in registry iteration order,
    /// so this walks the *entire* IOService plane once and carries
    /// forward the most recently seen framebuffer node's attributes,
    /// pairing them with the very next DCPAVServiceProxy found - the
    /// same approach the reference implementation this is based on
    /// (waydabber/AppleSiliconDDC) uses, verified against its source.
    static func discoverAll() -> [DDCTransport] {
        guard isAvailable, let createWithServiceFn else {
            NSLogError("Apple Silicon DDC symbols unavailable on this system")
            return []
        }

        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            NSLogError("AppleSiliconDDC: IORegistryEntryCreateIterator failed")
            return []
        }
        defer { IOObjectRelease(iterator) }

        var result: [AppleSiliconDDCTransport] = []
        var pendingProductAttrs: [String: Any]?
        var index = 0

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard let name = ioRegistryEntryName(entry) else { continue }

            if name.contains("AppleCLCD2") || name.contains("IOMobileFramebufferShim") {
                pendingProductAttrs = readProductAttributes(entry)
                continue
            }
            guard name.contains("DCPAVServiceProxy") else { continue }
            index += 1

            // Consumed either way - an unrelated framebuffer node's
            // attributes must not leak onto a later, different proxy.
            let productAttrs = pendingProductAttrs
            pendingProductAttrs = nil

            let location = ioRegistryString(entry, "Location")
            guard location == "External" else {
                NSLogInfo("AppleSiliconDDC: service #\(index) skipped, Location=\(location ?? "nil")")
                continue
            }
            guard let unmanaged = createWithServiceFn(nil, entry) else {
                NSLogError("AppleSiliconDDC: service #\(index) IOAVServiceCreateWithService failed, Location=\(location ?? "nil")")
                continue
            }
            let avService = unmanaged.takeRetainedValue()

            let displayName = productName(from: productAttrs) ?? "External Display"
            let edidSerialNumber = edidSerialNumber(from: productAttrs)
            let edidIdentity = edidIdentity(from: productAttrs, serial: edidSerialNumber)
            NSLogInfo("AppleSiliconDDC: service #\(index) accepted as \(displayName), Location=\(location ?? "nil") edidIdentity=\(edidIdentity ?? "nil")")
            result.append(AppleSiliconDDCTransport(displayName: displayName, edidIdentity: edidIdentity, edidSerialNumber: edidSerialNumber, service: avService))
        }

        return result
    }

    private static func ioRegistryEntryName(_ entry: io_service_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return nil }
        return String(cString: buffer)
    }

    private static func readProductAttributes(_ entry: io_service_t) -> [String: Any]? {
        guard let attrs = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return attrs["ProductAttributes"] as? [String: Any]
    }

    /// The serial component of `edidIdentity` - see `DDCTransport.
    /// edidSerialNumber`. Prefers the more human-readable
    /// `AlphanumericSerialNumber` when a monitor provides one, else the
    /// numeric `SerialNumber` as hex; nil when the EDID carries neither
    /// (not every monitor fills these in).
    private static func edidSerialNumber(from productAttrs: [String: Any]?) -> String? {
        guard let productAttrs else { return nil }
        if let alphanumericSerial = (productAttrs["AlphanumericSerialNumber"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !alphanumericSerial.isEmpty {
            return alphanumericSerial
        }
        if let numericSerial = (productAttrs["SerialNumber"] as? NSNumber)?.uint32Value, numericSerial != 0 {
            return String(format: "%08x", numericSerial)
        }
        return nil
    }

    /// Hardware identity for this display, from its EDID manufacturer ID
    /// and serial - see `DDCTransport.edidIdentity`. Requires an actual
    /// serial - without one there's nothing here that's unique to this
    /// specific physical unit rather than just its model, so this returns
    /// nil rather than a manufacturer-only id that would collide with
    /// every other unit of the same monitor model.
    private static func edidIdentity(from productAttrs: [String: Any]?, serial: String?) -> String? {
        guard let productAttrs, let serial else { return nil }
        let manufacturerID = (productAttrs["ManufacturerID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(manufacturerID ?? "unknown")-\(serial)"
    }

    /// The monitor's real product name, as encoded in its EDID (the
    /// "Monitor Name" descriptor block). Surfaced either as a plain
    /// string or as a locale-keyed dictionary (e.g.
    /// `["en_US": "LG UltraFine"]`) depending on macOS version - not
    /// every monitor's EDID carries one either way, so this can be nil.
    private static func productName(from productAttrs: [String: Any]?) -> String? {
        guard let productAttrs else { return nil }
        if let name = productAttrs["ProductName"] as? String {
            return name
        }
        if let localized = productAttrs["ProductName"] as? [String: String] {
            return localized["en_US"] ?? localized.values.first
        }
        return nil
    }

    /// `DDCProtocol` builds packets as `[0x51] + body + [checksum]`, framed
    /// for transports (like `IntelDDCTransport`) that send the whole thing
    /// as one continuous I2C payload. `IOAVServiceWriteI2C`/`ReadI2C` instead
    /// take that `0x51` "data address" as its own parameter (passed
    /// separately below) - re-including it as the packet's first byte shifts
    /// every following byte by one and invalidates the checksum, so the
    /// monitor silently discards the whole packet. This re-frames the packet
    /// to what the private API actually expects: the body alone, with the
    /// checksum recomputed over just the body (seed `0x6E` for a single-byte
    /// "Get VCP" command, `0x6E ^ 0x51` for a multi-byte "Set VCP"/write
    /// command) - matching the reverse-engineered reference implementation
    /// this API is based on (waydabber/AppleSiliconDDC).
    private func reframeForIOAVService(_ ddcProtocolPacket: [UInt8]) -> [UInt8] {
        let body = Array(ddcProtocolPacket.dropFirst().dropLast())
        let seed: UInt8 = body.first == 0x82 ? 0x6E : 0x6E ^ 0x51
        let checksum = body.reduce(seed) { $0 ^ $1 }
        return body + [checksum]
    }

    func write(_ bytes: [UInt8]) -> Bool {
        guard let writeFn = Self.writeFn else { return false }
        let packet = reframeForIOAVService(bytes)
        let result = packet.withUnsafeBytes { rawBuffer -> IOReturn in
            guard let baseAddress = rawBuffer.baseAddress else { return kIOReturnError }
            return writeFn(service, DDCProtocol.slaveAddress, 0x51, baseAddress, UInt32(packet.count))
        }
        NSLogInfo("AppleSiliconDDC: write bytes=\(packet.map { String(format: "%02X", $0) }.joined(separator: " ")) ioReturn=\(result)")
        return result == kIOReturnSuccess
    }

    /// IOAVService has no combined atomic transaction; this issues the
    /// write, waits briefly for the monitor to prepare its reply, then
    /// issues a separate read - the same approach used elsewhere for
    /// this private API.
    func writeAndRead(_ bytes: [UInt8], replyLength: Int) -> [UInt8]? {
        guard write(bytes), let readFn = Self.readFn else { return nil }
        Thread.sleep(forTimeInterval: 0.05)
        var buffer = [UInt8](repeating: 0, count: replyLength)
        let result = buffer.withUnsafeMutableBytes { rawBuffer -> IOReturn in
            guard let baseAddress = rawBuffer.baseAddress else { return kIOReturnError }
            return readFn(service, DDCProtocol.slaveAddress, 0x51, baseAddress, UInt32(replyLength))
        }
        let hex = buffer.map { String(format: "%02X", $0) }.joined(separator: " ")
        guard result == kIOReturnSuccess else {
            NSLogError("AppleSiliconDDC: read failed ioReturn=\(result) partialBytes=\(hex)")
            return nil
        }
        NSLogInfo("AppleSiliconDDC: read ioReturn=\(result) bytes=\(hex)")
        return buffer
    }
}

func ioRegistryString(_ service: io_service_t, _ key: String) -> String? {
    guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? String else {
        return nil
    }
    return value
}
