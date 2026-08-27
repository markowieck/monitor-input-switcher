import Foundation
import ServiceManagement

/// Registers/unregisters the app as a login item using the modern
/// `SMAppService` API. Requires the built binary to live inside a proper
/// `.app` bundle (see Scripts/build_app.sh).
enum LoginItemService {
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled { return }
                try SMAppService.mainApp.register()
            } else {
                switch SMAppService.mainApp.status {
                case .notRegistered, .notFound:
                    return
                default:
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLogError("Failed to update login item: \(error)")
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
