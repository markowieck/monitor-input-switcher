import Foundation

/// High level DDC/CI facade used by the rest of the app: switch input,
/// read back the current input. Talks to every controllable external
/// display it can find a transport for.
final class DDCController {
    /// All currently validated transports, one per controllable external
    /// display. AppDelegate matches these to `MonitorConfig`s by
    /// `displayName` (see `MonitorConfig.transportKey`).
    private(set) var transports: [DDCTransport] = []

    /// Re-scans for controllable external displays. Call this at startup
    /// and whenever a write/read fails, in case a monitor was
    /// unplugged/replugged or woke from sleep.
    ///
    /// A Mac can expose several I2C-capable transports (e.g. one
    /// framebuffer per GPU output port, whether or not a real DDC/CI
    /// monitor is actually attached there), and the OS API happily
    /// reports success for all of them even when nothing real is on the
    /// other end. To find the ones that are actually monitors, probe each
    /// candidate with a real "Get VCP Feature" request and keep only the
    /// ones that return a structurally valid reply.
    @discardableResult
    func refreshTransports() -> [DDCTransport] {
        let candidates = DDCTransportFactory.makeTransports()
        NSLogInfo("refreshTransports: probing \(candidates.count) candidate transport(s)")

        let request = DDCProtocol.getVCPRequestPacket(vcpCode: DDCProtocol.inputSourceVCPCode)
        var validated: [DDCTransport] = []
        for candidate in candidates {
            guard Self.getVCPReplyWithRetries(transport: candidate, request: request) != nil else {
                continue
            }
            NSLogInfo("refreshTransports: \(candidate.displayName) responded with a valid DDC/CI reply, using it")
            validated.append(candidate)
        }

        guard validated.isEmpty else {
            transports = validated
            return validated
        }

        // None of the candidates validated this time - this can happen
        // when a monitor is just temporarily busy. Keep whatever was
        // previously validated rather than dropping every monitor from
        // the menu/settings over a transient hiccup.
        if !transports.isEmpty {
            NSLogError("refreshTransports: no transport validated this time; keeping the \(transports.count) previously validated transport(s)")
            return transports
        }

        NSLogError("refreshTransports: no transport returned a valid DDC/CI reply")
        return transports
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

    @discardableResult
    func setInput(on transport: DDCTransport, vcpValue: Int) -> Bool {
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

        NSLogError("Failed to write VCP input source \(vcpValue) to \(transport.displayName) after retries")
        return false
    }

    /// Reads back an arbitrary VCP feature (current, max), unmasked. Handy
    /// for diagnostics, e.g. checking VCP 0xD6 (Power Mode) to see
    /// whether the monitor reports itself as on/standby/suspended.
    func getVCPValue(from transport: DDCTransport, code: UInt8) -> (current: Int, max: Int)? {
        let request = DDCProtocol.getVCPRequestPacket(vcpCode: code)
        guard let parsed = Self.getVCPReplyWithRetries(transport: transport, request: request) else {
            NSLogError("getVCPValue(0x\(String(code, radix: 16))): no valid reply from \(transport.displayName)")
            return nil
        }
        return (Int(parsed.currentValue), Int(parsed.maxValue))
    }

    /// Reads back a monitor's current input source VCP value.
    func getCurrentInput(from transport: DDCTransport) -> Int? {
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
