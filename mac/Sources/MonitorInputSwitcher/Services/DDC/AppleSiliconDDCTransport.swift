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

    private init(displayName: String, service: AnyObject) {
        self.displayName = displayName
        self.service = service
    }

    /// Whether this build is even capable of using the Apple Silicon path
    /// (i.e. the private symbols resolved successfully).
    static var isAvailable: Bool {
        readFn != nil && writeFn != nil && createWithServiceFn != nil
    }

    static func discoverAll() -> [DDCTransport] {
        guard isAvailable, let createWithServiceFn else {
            NSLogError("Apple Silicon DDC symbols unavailable on this system")
            return []
        }

        var result: [(transport: AppleSiliconDDCTransport, vendor: UInt32, product: UInt32)] = []

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == kIOReturnSuccess else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var ioService = IOIteratorNext(iterator)
        while ioService != 0 {
            defer {
                IOObjectRelease(ioService)
                ioService = IOIteratorNext(iterator)
            }

            guard ioRegistryString(ioService, "Location") == "External" else { continue }
            guard let unmanaged = createWithServiceFn(nil, ioService) else { continue }
            let avService = unmanaged.takeRetainedValue()

            let (vendor, product) = productAttributes(ioService)
            let name = "External Display" + (vendor != 0 ? " (vendor \(vendor))" : "")
            result.append((AppleSiliconDDCTransport(displayName: name, service: avService), vendor, product))
        }

        return result.map { $0.transport }
    }

    private static func productAttributes(_ service: io_service_t) -> (vendor: UInt32, product: UInt32) {
        guard let attrs = IORegistryEntryCreateCFProperty(service, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any],
            let productAttrs = attrs["ProductAttributes"] as? [String: Any] else {
            return (0, 0)
        }
        let vendor = (productAttrs["LegacyManufacturerID"] as? UInt32) ?? 0
        let product = (productAttrs["ProductID"] as? UInt32) ?? 0
        return (vendor, product)
    }

    func write(_ bytes: [UInt8]) -> Bool {
        guard let writeFn = Self.writeFn else { return false }
        let result = bytes.withUnsafeBytes { rawBuffer -> IOReturn in
            guard let baseAddress = rawBuffer.baseAddress else { return kIOReturnError }
            return writeFn(service, DDCProtocol.slaveAddress, 0x51, baseAddress, UInt32(bytes.count))
        }
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
        guard result == kIOReturnSuccess else { return nil }
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
