import Foundation

/// High level DDC/CI facade used by the rest of the app: switch input,
/// read back the current input. Talks to the first external display it
/// can find a transport for (the common single-external-monitor setup).
final class DDCController {
    private var transport: DDCTransport?

    /// Re-scans for a controllable external display. Call this at
    /// startup and whenever a write/read fails, in case the monitor was
    /// unplugged/replugged or woke from sleep.
    ///
    /// A Mac can expose several I2C-capable transports (e.g. one
    /// framebuffer per GPU output port, whether or not a real DDC/CI
    /// monitor is actually attached there), and the OS API happily
    /// reports success for all of them even when nothing real is on the
    /// other end. To find the one that's actually the monitor, probe
    /// each candidate with a real "Get VCP Feature" request and pick the
    /// first one that returns a structurally valid reply.
    @discardableResult
    func refreshTransport() -> DDCTransport? {
        let transports = DDCTransportFactory.makeTransports()
        NSLogInfo("refreshTransport: probing \(transports.count) candidate transport(s)")

        let request = DDCProtocol.getVCPRequestPacket(vcpCode: DDCProtocol.inputSourceVCPCode)
        for candidate in transports {
            guard let reply = candidate.writeAndRead(request, replyLength: 11),
                  DDCProtocol.parseVCPReply(reply) != nil else {
                continue
            }
            NSLogInfo("refreshTransport: \(candidate.displayName) responded with a valid DDC/CI reply, using it")
            transport = candidate
            return candidate
        }

        NSLogError("refreshTransport: no transport returned a valid DDC/CI reply; falling back to the first candidate")
        transport = transports.first
        if let transport {
            NSLogInfo("Using DDC transport for \(transport.displayName) (unvalidated)")
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
        // Input Source is a non-continuous (enumerated) VCP feature, so
        // the meaningful value fits in one byte - some monitors don't
        // zero the high byte for these, so mask it off rather than
        // trusting the full 16-bit value.
        return Int(parsed.currentValue & 0xFF)
    }
}
