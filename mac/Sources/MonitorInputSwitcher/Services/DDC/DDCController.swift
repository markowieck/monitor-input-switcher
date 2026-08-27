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
            guard Self.getVCPReplyWithRetries(transport: candidate, request: request) != nil else {
                continue
            }
            NSLogInfo("refreshTransport: \(candidate.displayName) responded with a valid DDC/CI reply, using it")
            transport = candidate
            return candidate
        }

        // None of the candidates validated - this can happen when the
        // monitor is just temporarily busy. Guessing at an unvalidated
        // candidate here has been observed to silently pick the wrong
        // one (writes "succeed" against a port with nothing attached),
        // so keep whatever was previously validated rather than
        // downgrading to a guess. Only guess if we've never had a
        // working transport at all.
        if let transport {
            NSLogError("refreshTransport: no transport validated this time; keeping the previously validated \(transport.displayName)")
            return transport
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

    /// DDC/CI monitors are notoriously flaky about responding to any
    /// single request (bus contention, the monitor's own firmware being
    /// slow, etc.) - established DDC/CI tools all retry a few times
    /// before giving up on a feature read, so we do the same here.
    private static func getVCPReplyWithRetries(transport: DDCTransport, request: [UInt8], attempts: Int = 4) -> DDCProtocol.VCPReply? {
        for attempt in 1...attempts {
            if let reply = transport.writeAndRead(request, replyLength: 11),
               let parsed = DDCProtocol.parseVCPReply(reply) {
                return parsed
            }
            if attempt < attempts {
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
        return nil
    }

    var currentDisplayName: String? { transport?.displayName }

    @discardableResult
    func setInput(vcpValue: Int) -> Bool {
        guard let transport = transport ?? refreshTransport() else { return false }
        let packet = DDCProtocol.setVCPPacket(vcpCode: DDCProtocol.inputSourceVCPCode, value: UInt16(clamping: vcpValue))

        // Switching away from this Mac's own input to a source with
        // nothing on it can put the monitor into standby; a monitor in
        // standby often won't act on further VCP writes. Sending a
        // "Power On" (VCP 0xD6 = 1) first is the standard DDC/CI way to
        // wake it before the actual input switch, giving it a moment to
        // come back before the switch itself.
        transport.write(DDCProtocol.powerOnPacket())
        Thread.sleep(forTimeInterval: 0.3)

        for attempt in 1...3 {
            if transport.write(packet) { return true }
            if attempt < 3 { Thread.sleep(forTimeInterval: 0.3) }
        }

        NSLogError("Failed to write VCP input source \(vcpValue) after retries, rescanning for a different transport")
        guard let retried = refreshTransport() else { return false }
        retried.write(DDCProtocol.powerOnPacket())
        Thread.sleep(forTimeInterval: 0.3)
        return retried.write(packet)
    }

    /// Reads back the monitor's current input source VCP value. Keeps
    /// using the already-validated cached transport rather than
    /// rescanning on every transient failure - rescanning re-probes every
    /// candidate transport, which is itself extra DDC/CI bus traffic and
    /// was observed to make a temporarily-busy monitor even less
    /// responsive rather than more.
    func getCurrentInput() -> Int? {
        guard let transport = transport ?? refreshTransport() else { return nil }
        let request = DDCProtocol.getVCPRequestPacket(vcpCode: DDCProtocol.inputSourceVCPCode)
        guard let parsed = Self.getVCPReplyWithRetries(transport: transport, request: request) else {
            NSLogError("getCurrentInput: no valid reply from \(transport.displayName)")
            return nil
        }
        // Input Source is a non-continuous (enumerated) VCP feature, so
        // the meaningful value fits in one byte - some monitors don't
        // zero the high byte for these, so mask it off rather than
        // trusting the full 16-bit value.
        return Int(parsed.currentValue & 0xFF)
    }
}
