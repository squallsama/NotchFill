import ServiceManagement

/// Open NotchFill at login (System Settings › General › Login Items).
///
/// The SDL setting (`launchctl setenv`) is gone after a restart until NotchFill sets it
/// again, and the mirror only works while NotchFill runs. With this on, both are back
/// after a restart without opening the app by hand.
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// Registered, but the user has not allowed it in System Settings yet.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Turns it on or off. Returns a short message for the user.
    static func set(_ on: Bool) -> String {
        let app = SMAppService.mainApp
        do {
            if on {
                try app.register()
                if app.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                    return "Allow NotchFill in System Settings › General › Login Items."
                }
                return "NotchFill opens at login."
            } else {
                try app.unregister()
                return "NotchFill no longer opens at login."
            }
        } catch {
            return "Cannot change Open at Login: \(error.localizedDescription)"
        }
    }
}
