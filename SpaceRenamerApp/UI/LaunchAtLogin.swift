import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue, SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                } else if !newValue, SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Workspace++: LaunchAtLogin toggle failed: \(error)")
            }
        }
    }
}
