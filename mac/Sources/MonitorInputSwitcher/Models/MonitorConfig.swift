import Foundation

/// One physical external monitor's configuration: its own input mappings
/// (VCP values for the same physical port can differ between monitor
/// models - see `InputMapping`) plus a key used to re-match it to a DDC
/// transport across app restarts and rescans.
struct MonitorConfig: Codable, Identifiable, Equatable {
    var id: UUID
    /// Matches a `DDCTransport.displayName`. On Apple Silicon that's the
    /// monitor's real EDID product name (stable); on Intel Macs it's an
    /// IOFramebuffer/bus label (stable only as long as the monitor stays
    /// on the same GPU port - there's no public API left to derive a
    /// proper EDID-based identity there, see IntelDDCTransport).
    ///
    /// Empty means "unassigned": the first transport that isn't already
    /// claimed by another config adopts it and fills this in. This is how
    /// a pre-multi-monitor settings.json (a single flat `inputs` list)
    /// transparently upgrades - see `Settings.init(from:)`.
    var transportKey: String
    var name: String
    var inputs: [InputMapping]

    init(id: UUID = UUID(), transportKey: String = "", name: String, inputs: [InputMapping]) {
        self.id = id
        self.transportKey = transportKey
        self.name = name
        self.inputs = inputs
    }
}
