import Foundation

/// Raw byte-level encoding/decoding for the VESA DDC/CI protocol carried
/// over I2C. This is transport-agnostic - see `DDCTransport` for the two
/// concrete ways bytes actually reach the monitor (classic IOFramebuffer
/// I2C on Intel Macs, and the private IOAVService API on Apple Silicon).
enum DDCProtocol {
    /// 7-bit DDC/CI slave address, as used by the transports (they apply
    /// the read/write bit themselves).
    static let slaveAddress: UInt32 = 0x37
    /// The address byte as embedded in the checksum / packet body -
    /// conventionally the slave address shifted with the write bit set.
    private static let writeAddressByte: UInt8 = 0x6E

    private static func xor(_ start: UInt8, _ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(start) { $0 ^ $1 }
    }

    /// Builds a "Set VCP Feature" packet (VESA MCCS) for the given VCP
    /// opcode (e.g. 0x60 = Input Source) and 16-bit value.
    static func setVCPPacket(vcpCode: UInt8, value: UInt16) -> [UInt8] {
        var body: [UInt8] = [0x51, 0x84, 0x03, vcpCode, UInt8(value >> 8), UInt8(value & 0xFF)]
        body.append(xor(writeAddressByte, body))
        return body
    }

    /// Builds a "Get VCP Feature" request packet for the given VCP opcode.
    static func getVCPRequestPacket(vcpCode: UInt8) -> [UInt8] {
        var body: [UInt8] = [0x51, 0x82, 0x01, vcpCode]
        body.append(xor(writeAddressByte, body))
        return body
    }

    struct VCPReply {
        let vcpCode: UInt8
        let currentValue: UInt16
        let maxValue: UInt16
    }

    /// Parses the ~11 byte reply to a "Get VCP Feature" request.
    static func parseVCPReply(_ bytes: [UInt8]) -> VCPReply? {
        guard bytes.count >= 10 else { return nil }
        // bytes[0] source addr, [1] length, [2] reply opcode (0x02),
        // [3] result code, [4] vcp opcode, [5] type, [6..7] max, [8..9] current
        guard bytes[2] == 0x02, bytes[3] == 0x00 else { return nil }
        let vcp = bytes[4]
        let maxValue = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let currentValue = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        return VCPReply(vcpCode: vcp, currentValue: currentValue, maxValue: maxValue)
    }

    /// VCP feature code for "Input Source Select".
    static let inputSourceVCPCode: UInt8 = 0x60
}
