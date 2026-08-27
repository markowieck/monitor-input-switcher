import Foundation

/// High level DDC/CI facade used by the rest of the app: switch input,
/// read back the current input. Talks to the first external display it
/// can find a transport for (the common single-external-monitor setup).
final class DDCController {
    private var transport: DDCTransport?

    /// Re-scans for a controllable external display. Call this at
    /// startup and whenever a write/read fails, in case the monitor was
    /// unplugged/replugged or woke from sleep.
    @discardableResult
    func refreshTransport() -> DDCTransport? {
        let transports = DDCTransportFactory.makeTransports()
        transport = transports.first
        if let transport {
            NSLogInfo("Using DDC transport for \(transport.displayName)")
        } else {
            NSLogError("No controllable external display found")
        }
        return transport
    }

    var currentDisplayName: String? { transport?.displayName }

    @discardableResult
    func setInput(vcpValue: Int) -> Bool {
        guard let transport = transport ?? refreshTransport() else { return false }
        let packet = DDCProtocol.setVCPPacket(vcpCode: DDCProtocol.inputSourceVCPCode, value: UInt16(clamping: vcpValue))
        let ok = transport.write(packet)
        if !ok {
            NSLogError("Failed to write VCP input source \(vcpValue), retrying after rescan")
            guard let retried = refreshTransport() else { return false }
            return retried.write(packet)
        }
        return ok
    }

    /// Reads back the monitor's current input source VCP value.
    func getCurrentInput() -> Int? {
        guard let transport = transport ?? refreshTransport() else { return nil }
        let request = DDCProtocol.getVCPRequestPacket(vcpCode: DDCProtocol.inputSourceVCPCode)
        guard let reply = transport.writeAndRead(request, replyLength: 11) else {
            NSLogError("getCurrentInput: writeAndRead failed")
            return nil
        }
        guard let parsed = DDCProtocol.parseVCPReply(reply) else {
            NSLogError("getCurrentInput: failed to parse reply \(reply.map { String(format: "%02X", $0) }.joined(separator: " "))")
            return nil
        }
        return Int(parsed.currentValue)
    }
}
