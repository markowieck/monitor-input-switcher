import Foundation

/// A low-level channel capable of writing/reading raw DDC/CI byte packets
/// to/from a single external display.
protocol DDCTransport {
    /// Human readable name of the underlying display, for logging/UI.
    var displayName: String { get }

    /// A hardware identity for this physical display derived from its
    /// EDID (vendor + serial), if one could be read. Unlike `displayName`
    /// - which for the Intel path is just a GPU-port bus label - this
    /// stays the same for the same physical monitor across reboots, GPU
    /// ports, and even different Macs, since it's a property of the
    /// monitor itself. nil when the EDID couldn't be read or didn't carry
    /// a serial number. Exact formatting is opaque/platform-specific -
    /// treat it as an id, not something to parse; see `edidSerialNumber`
    /// for a clean, display-ready value.
    var edidIdentity: String? { get }

    /// Just the serial component of `edidIdentity`, for display in the UI
    /// (e.g. Settings shows this under the monitor's name). nil under the
    /// same conditions as `edidIdentity`.
    var edidSerialNumber: String? { get }

    /// Write-only transaction (e.g. "Set VCP Feature" - no reply expected).
    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool

    /// Write followed by a read of `replyLength` bytes (e.g. "Get VCP
    /// Feature"), carried out as a single atomic I2C transaction where the
    /// underlying API supports that (Intel). Returns nil on failure.
    func writeAndRead(_ bytes: [UInt8], replyLength: Int) -> [UInt8]?
}

enum DDCTransportFactory {
    /// Picks the right transport implementation for the current Mac
    /// (Apple Silicon uses the private IOAVService I2C passthrough,
    /// Intel Macs use the public IOFramebuffer I2C API).
    static func makeTransports() -> [DDCTransport] {
        if isAppleSilicon {
            return AppleSiliconDDCTransport.discoverAll()
        } else {
            return IntelDDCTransport.discoverAll()
        }
    }

    static var isAppleSilicon: Bool {
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        guard size > 0 else { return false }
        var value: Int32 = 0
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return value == 1
    }
}
