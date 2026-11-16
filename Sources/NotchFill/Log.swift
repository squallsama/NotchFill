import os

/// Unified log: `log show --predicate 'subsystem == "dev.notchfill.NotchFill"' --last 10m`
enum Log {
    static let app = Logger(subsystem: "dev.notchfill.NotchFill", category: "app")
}
