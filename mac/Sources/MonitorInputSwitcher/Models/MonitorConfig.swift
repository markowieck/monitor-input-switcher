import Foundation

/// One physical external monitor's configuration: its own input mappings
/// (VCP values for the same physical port can differ between monitor
/// models - see `InputMapping`) plus the keys used to re-match it to a
/// DDC transport across app restarts and rescans.
struct MonitorConfig: Codable, Identifiable, Equatable {
    var id: UUID
    /// Matches a `DDCTransport.displayName` or `edidIdentity` (preferred
    /// when available - see below). Empty means "unassigned": the first
    /// transport that isn't already claimed by another config adopts it
    /// and fills this in. This is how a pre-multi-monitor settings.json
    /// (a single flat `inputs` list) transparently upgrades - see
    /// `Settings.init(from:)`.
    var transportKey: String
    /// The monitor's EDID-derived hardware identity ("vvvv-pppp-ssssssss"
    /// hex - see `DDCTransport.edidIdentity`), when it was available at
    /// match time. Unlike `transportKey` (which can be a GPU-port bus
    /// label with no EDID data behind it), this is a property of the
    /// physical monitor itself - stable across GPU ports, reboots, and
    /// even different Macs. Used as the Home Assistant discovery
    /// unique_id when present, so the same physical monitor is
    /// recognized as the same device regardless of which Mac happens to
    /// be driving it (see AppDelegate.uniqueId(for:in:)).
    var edidIdentity: String?
    var name: String
    var inputs: [InputMapping]

    init(id: UUID = UUID(), transportKey: String = "", edidIdentity: String? = nil, name: String, inputs: [InputMapping]) {
        self.id = id
        self.transportKey = transportKey
        self.edidIdentity = edidIdentity
        self.name = name
        self.inputs = inputs
    }
}
