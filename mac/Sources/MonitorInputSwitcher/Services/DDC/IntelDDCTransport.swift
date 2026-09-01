import Foundation
import IOKit
import IOKit.i2c
import CoreGraphics

/// DDC/CI transport for Intel Macs, using Apple's public
/// `IOFBCopyI2CInterfaceForBus` / `IOI2CSendRequest` API (IOKit/i2c).
/// External monitors connected to a discrete/integrated GPU expose an
/// I2C bus per IOFramebuffer that this API can address directly.
final class IntelDDCTransport: DDCTransport {
    let displayName: String
    let edidIdentity: String?
    let edidSerialNumber: String?
    private let interface: io_service_t

    private init(displayName: String, edidIdentity: String?, edidSerialNumber: String?, interface: io_service_t) {
        self.displayName = displayName
        self.edidIdentity = edidIdentity
        self.edidSerialNumber = edidSerialNumber
        self.interface = interface
    }

    deinit {
        IOObjectRelease(interface)
    }

    /// Enumerates every `IOFramebuffer` in the IO Registry and keeps the
    /// ones that expose at least one I2C bus. `CGDisplayIOServicePort`,
    /// the API that used to map a `CGDirectDisplayID` straight to its
    /// framebuffer service, was removed from the SDK, so there is no
    /// public way left to tie a framebuffer back to a specific
    /// `CGDirectDisplayID`/display name. In practice a Mac's built-in
    /// panel does not expose a DDC/CI I2C bus this way, so this list
    /// ends up containing external monitors only.
    static func discoverAll() -> [DDCTransport] {
        var result: [DDCTransport] = []

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &iterator) == kIOReturnSuccess else {
            return result
        }
        defer { IOObjectRelease(iterator) }

        var framebuffer = IOIteratorNext(iterator)
        var fbIndex = 0
        while framebuffer != 0 {
            defer {
                IOObjectRelease(framebuffer)
                framebuffer = IOIteratorNext(iterator)
            }
            fbIndex += 1

            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(framebuffer, &name)
            let fbName = String(cString: name)

            var busCount: IOItemCount = 0
            let busCountResult = IOFBGetI2CInterfaceCount(framebuffer, &busCount)
            NSLogInfo("IntelDDC: framebuffer #\(fbIndex) name=\(fbName) busCountResult=\(busCountResult) busCount=\(busCount)")
            guard busCountResult == kIOReturnSuccess, busCount > 0 else {
                continue
            }

            // The framebuffer's EDID-derived vendor/product/serial lives
            // on a descendant node (typically framebuffer -> "displayN"
            // (IODisplayConnect) -> "AppleDisplay"), not on the
            // framebuffer itself - same identity for every I2C bus this
            // framebuffer exposes.
            let edidInfo = Self.lookupEdidInfo(descendantOf: framebuffer)
            NSLogInfo("IntelDDC: framebuffer #\(fbIndex) edidIdentity=\(edidInfo?.identity ?? "nil")")

            for bus in 0..<busCount {
                var interface: io_service_t = 0
                guard IOFBCopyI2CInterfaceForBus(framebuffer, IOOptionBits(bus), &interface) == kIOReturnSuccess, interface != 0 else {
                    continue
                }
                result.append(IntelDDCTransport(displayName: "\(fbName) bus \(bus)", edidIdentity: edidInfo?.identity, edidSerialNumber: edidInfo?.serial, interface: interface))
            }
        }
        NSLogInfo("IntelDDC: discovered \(result.count) transport(s): \(result.map { $0.displayName })")
        return result
    }

    /// Walks down from an `IOFramebuffer` to find its EDID vendor/product/
    /// serial. In the IORegistry this lives two levels down - typically
    /// framebuffer -> "displayN" (class IODisplayConnect) -> "AppleDisplay"
    /// - so this checks every child and grandchild for the relevant
    /// properties rather than assuming an exact class name (that nesting
    /// is what's actually observed, not documented API).
    private static func lookupEdidInfo(descendantOf service: io_service_t) -> (identity: String, serial: String?)? {
        var childIterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(childIterator) }

        var child = IOIteratorNext(childIterator)
        while child != 0 {
            defer {
                IOObjectRelease(child)
                child = IOIteratorNext(childIterator)
            }
            if let info = edidInfo(fromDisplayNode: child) {
                return info
            }
            if let info = lookupEdidInfo(descendantOf: child) {
                return info
            }
        }
        return nil
    }

    private static func edidInfo(fromDisplayNode node: io_service_t) -> (identity: String, serial: String?)? {
        guard let vendor = ioRegistryUInt32(node, "DisplayVendorID"),
            let product = ioRegistryUInt32(node, "DisplayProductID")
        else { return nil }
        let serialValue = ioRegistryUInt32(node, "DisplaySerialNumber") ?? 0

        // That numeric field is frequently a manufacturer-wide constant
        // rather than a real per-unit value - confirmed on a Dell
        // P2725QE, which reports the same 32-bit "serial" regardless of
        // the actual unit. The EDID's own alphanumeric serial descriptor
        // (when a monitor bothers to fill one in) is the real per-unit
        // value, so prefer that when present - same policy already used
        // on the Apple Silicon path's `AlphanumericSerialNumber`.
        let alphanumericSerial = edidData(node).flatMap(Self.alphanumericSerial(fromEDID:))
        let serial = alphanumericSerial ?? (serialValue != 0 ? String(format: "%08x", serialValue) : nil)
        let identity = "\(String(format: "%04x-%04x", vendor, product))-\(serial ?? String(format: "%08x", serialValue))"
        return (identity, serial)
    }

    private static func edidData(_ node: io_service_t) -> Data? {
        IORegistryEntryCreateCFProperty(node, "IODisplayEDID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data
    }

    /// Parses the raw EDID's monitor descriptor blocks (4 x 18 bytes,
    /// starting at byte 54) looking for the tag-0xFF "Display Serial
    /// Number" text descriptor. Returns nil if the EDID is too short/not
    /// well-formed, or doesn't carry one - many monitors don't.
    private static func alphanumericSerial(fromEDID edid: Data) -> String? {
        guard edid.count >= 126 else { return nil }
        let bytes = [UInt8](edid)
        for blockStart in stride(from: 54, to: 126, by: 18) {
            let block = bytes[blockStart..<(blockStart + 18)]
            let base = block.startIndex
            guard block[base] == 0, block[base + 1] == 0, block[base + 2] == 0, block[base + 3] == 0xFF else {
                continue
            }
            let text = String(decoding: block[(base + 5)..<(base + 18)], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func ioRegistryUInt32(_ service: io_service_t, _ key: String) -> UInt32? {
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else {
            return nil
        }
        return value.uint32Value
    }

    func write(_ bytes: [UInt8]) -> Bool {
        var connect: IOI2CConnectRef?
        guard IOI2CInterfaceOpen(interface, 0, &connect) == kIOReturnSuccess, let connect else {
            NSLogError("IntelDDC: IOI2CInterfaceOpen failed")
            return false
        }
        defer { IOI2CInterfaceClose(connect, 0) }

        let sendPtr = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, 1), alignment: 1)
        defer { sendPtr.deallocate() }
        sendPtr.copyMemory(from: bytes, byteCount: bytes.count)

        var request = IOI2CRequest()
        request.commFlags = 0
        request.sendAddress = DDCProtocol.slaveAddress << 1
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.sendBuffer = UInt(bitPattern: sendPtr)
        request.sendBytes = UInt32(bytes.count)
        request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
        request.replyBytes = 0

        let sendResult = IOI2CSendRequest(connect, 0, &request)
        NSLogInfo("IntelDDC: write bytes=\(bytes.map { String(format: "%02X", $0) }.joined(separator: " ")) ioReturn=\(sendResult) request.result=\(request.result)")
        return sendResult == kIOReturnSuccess && request.result == kIOReturnSuccess
    }

    /// Performs the write and the reply read as a single atomic
    /// `IOI2CRequest`, as documented by `IOI2CInterface.h` - this is the
    /// intended way to do a "Get VCP Feature" round trip (the driver
    /// handles the inter-transaction delay).
    func writeAndRead(_ bytes: [UInt8], replyLength: Int) -> [UInt8]? {
        var connect: IOI2CConnectRef?
        guard IOI2CInterfaceOpen(interface, 0, &connect) == kIOReturnSuccess, let connect else {
            NSLogError("IntelDDC: IOI2CInterfaceOpen failed")
            return nil
        }
        defer { IOI2CInterfaceClose(connect, 0) }

        let sendPtr = UnsafeMutableRawPointer.allocate(byteCount: max(bytes.count, 1), alignment: 1)
        let replyPtr = UnsafeMutableRawPointer.allocate(byteCount: max(replyLength, 1), alignment: 1)
        defer {
            sendPtr.deallocate()
            replyPtr.deallocate()
        }
        sendPtr.copyMemory(from: bytes, byteCount: bytes.count)
        replyPtr.initializeMemory(as: UInt8.self, repeating: 0, count: replyLength)

        var request = IOI2CRequest()
        request.commFlags = 0
        request.sendAddress = DDCProtocol.slaveAddress << 1
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.sendBuffer = UInt(bitPattern: sendPtr)
        request.sendBytes = UInt32(bytes.count)
        request.replyAddress = DDCProtocol.slaveAddress << 1
        request.replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
        request.replyBuffer = UInt(bitPattern: replyPtr)
        request.replyBytes = UInt32(replyLength)

        let sendResult = IOI2CSendRequest(connect, 0, &request)
        guard sendResult == kIOReturnSuccess, request.result == kIOReturnSuccess else {
            NSLogError("IntelDDC: writeAndRead failed, ioReturn=\(sendResult), request.result=\(request.result)")
            return nil
        }
        return Array(UnsafeRawBufferPointer(start: replyPtr, count: replyLength))
    }
}
