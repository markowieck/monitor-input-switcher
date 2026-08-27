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
    private let interface: io_service_t

    private init(displayName: String, interface: io_service_t) {
        self.displayName = displayName
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
        var index = 0
        while framebuffer != 0 {
            defer {
                IOObjectRelease(framebuffer)
                framebuffer = IOIteratorNext(iterator)
            }

            var busCount: IOItemCount = 0
            guard IOFBGetI2CInterfaceCount(framebuffer, &busCount) == kIOReturnSuccess, busCount > 0 else {
                continue
            }

            var interface: io_service_t = 0
            var found = false
            for bus in 0..<busCount {
                if IOFBCopyI2CInterfaceForBus(framebuffer, IOOptionBits(bus), &interface) == kIOReturnSuccess {
                    found = true
                    break
                }
            }
            guard found, interface != 0 else { continue }

            index += 1
            result.append(IntelDDCTransport(displayName: "External Display \(index)", interface: interface))
        }
        return result
    }

    func write(_ bytes: [UInt8]) -> Bool {
        var connect: IOI2CConnectRef?
        guard IOI2CInterfaceOpen(interface, 0, &connect) == kIOReturnSuccess, let connect else { return false }
        defer { IOI2CInterfaceClose(connect, 0) }

        var sendBuffer = bytes
        var request = IOI2CRequest()
        request.commFlags = 0
        request.sendAddress = DDCProtocol.slaveAddress << 1
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.sendBytes = UInt32(sendBuffer.count)
        request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
        request.replyBytes = 0

        let ok: Bool = sendBuffer.withUnsafeMutableBytes { raw -> Bool in
            request.sendBuffer = UInt(bitPattern: raw.baseAddress)
            return IOI2CSendRequest(connect, 0, &request) == kIOReturnSuccess && request.result == kIOReturnSuccess
        }
        return ok
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
