import AppKit

/// Settings NotchFill applies by itself when a given app starts.
///
/// Stored as a plist dictionary in NotchFill's defaults (`profiles` → key → fields), so
/// the hook library and `notchfill-run` (C) can read them with CFPreferences too:
/// `unityResolution` and `fullScreen` are also used there.
struct GameProfile {
    /// Bundle identifier, or "exe:<executable name>" for apps without one (e.g. Wine).
    let key: String
    var name: String
    var path: String?
    var isUnity = false
    /// DisplayMode key, e.g. "1496x967@60". nil: leave the display alone.
    var displayMode: String?
    var fullScreen = false
    var hideChrome = false
    /// "WxH" for Unity games. nil: NotchFill's global Game Resolution.
    var unityResolution: String?

    init(key: String, name: String, path: String?, isUnity: Bool) {
        self.key = key
        self.name = name
        self.path = path
        self.isUnity = isUnity
    }

    init?(key: String, plist: [String: Any]) {
        guard let name = plist["name"] as? String else { return nil }
        self.key = key
        self.name = name
        path = plist["path"] as? String
        isUnity = plist["isUnity"] as? Bool ?? false
        displayMode = plist["displayMode"] as? String
        fullScreen = plist["fullScreen"] as? Bool ?? false
        hideChrome = plist["hideChrome"] as? Bool ?? false
        unityResolution = plist["unityResolution"] as? String
    }

    var plist: [String: Any] {
        var d: [String: Any] = ["name": name, "isUnity": isUnity, "fullScreen": fullScreen, "hideChrome": hideChrome]
        d["path"] = path
        d["displayMode"] = displayMode
        d["unityResolution"] = unityResolution
        return d
    }

    /// One line for the menu, e.g. "1496×967 · 60 Hz, full screen".
    var summary: String {
        var parts: [String] = []
        if let displayMode { parts.append(DisplayModes.title(of: displayMode)) }
        if fullScreen { parts.append("full screen") }
        if hideChrome { parts.append("no menu bar/Dock") }
        if let unityResolution { parts.append("Unity \(unityResolution.replacingOccurrences(of: "x", with: "×"))") }
        return parts.isEmpty ? "no changes" : parts.joined(separator: ", ")
    }
}

enum GameProfiles {
    private static let defaultsKey = "profiles"
    private static let defaults = UserDefaults.standard

    static var all: [GameProfile] {
        let dict = defaults.dictionary(forKey: defaultsKey) ?? [:]
        return dict.compactMap { key, value in (value as? [String: Any]).flatMap { GameProfile(key: key, plist: $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func get(_ key: String) -> GameProfile? {
        (defaults.dictionary(forKey: defaultsKey)?[key] as? [String: Any]).flatMap { GameProfile(key: key, plist: $0) }
    }

    static func save(_ profile: GameProfile) {
        var dict = defaults.dictionary(forKey: defaultsKey) ?? [:]
        dict[profile.key] = profile.plist
        defaults.set(dict, forKey: defaultsKey)
    }

    static func remove(_ key: String) {
        var dict = defaults.dictionary(forKey: defaultsKey) ?? [:]
        dict[key] = nil
        defaults.set(dict, forKey: defaultsKey)
    }

    /// Changes one profile in place.
    static func update(_ key: String, _ change: (inout GameProfile) -> Void) {
        guard var p = get(key) else { return }
        change(&p)
        save(p)
    }

    // MARK: Matching apps

    /// The same key the hook and `notchfill-run` compute for a process.
    static func key(for app: NSRunningApplication) -> String? {
        if let id = app.bundleIdentifier { return id }
        return app.executableURL.map { "exe:" + $0.lastPathComponent }
    }

    /// A new profile for an app bundle (from the open panel) or a running app.
    static func newProfile(appAt url: URL) -> GameProfile? {
        guard let bundle = Bundle(url: url) else { return nil }
        let key = bundle.bundleIdentifier ?? bundle.executableURL.map { "exe:" + $0.lastPathComponent }
        guard let key else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return GameProfile(key: key, name: name, path: url.path, isUnity: isUnity(url))
    }

    static func newProfile(for app: NSRunningApplication) -> GameProfile? {
        if let url = app.bundleURL, app.bundleIdentifier != nil { return newProfile(appAt: url) }
        guard let key = key(for: app) else { return nil }
        return GameProfile(key: key, name: app.localizedName ?? key, path: app.executableURL?.path, isUnity: false)
    }

    /// UnityPlayer.dylib anywhere in the bundle (also in nested wrapper apps), like notchfill-run.
    static func isUnity(_ url: URL) -> Bool {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return false }
        for case let file as URL in e {
            if e.level > 8 { e.skipDescendants() }
            if file.lastPathComponent == "UnityPlayer.dylib" { return true }
        }
        return false
    }
}

/// Applies profiles when their apps start and undoes the changes when the last one quits.
final class ProfileWatcher {
    private let chrome: SystemChrome
    private let note: (String) -> Void
    /// Running apps with a profile: pid → profile key.
    private var running: [pid_t: String] = [:]
    private var displayChanged = false
    private var chromeHidden = false

    init(chrome: SystemChrome, note: @escaping (String) -> Void) {
        self.chrome = chrome
        self.note = note
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.launched(app) }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.terminated(app) }
        }
    }

    private func launched(_ app: NSRunningApplication) {
        guard let key = GameProfiles.key(for: app), let p = GameProfiles.get(key) else { return }
        running[app.processIdentifier] = key
        var done: [String] = []
        if let mode = p.displayMode, mode != DisplayModes.current?.key {
            DisplayModes.switchTo(mode)
            if DisplayModes.current?.key == mode {
                displayChanged = true
                done.append(DisplayModes.title(of: mode))
            }
        }
        if p.hideChrome, !chrome.isHidden {
            chrome.hide()
            chromeHidden = true
            done.append("menu bar and Dock hidden")
        }
        // Unity games get -screen-fullscreen from notchfill-run; Accessibility would fight them.
        if p.fullScreen, !p.isUnity {
            FullScreenStarter.enter(pid: app.processIdentifier, note: note)
        }
        if !done.isEmpty { note("\(p.name): \(done.joined(separator: ", ")).") }
    }

    private func terminated(_ app: NSRunningApplication) {
        guard running.removeValue(forKey: app.processIdentifier) != nil else { return }
        let others = running.values.compactMap(GameProfiles.get)
        var done: [String] = []
        if displayChanged, !others.contains(where: { $0.displayMode != nil }) {
            displayChanged = false
            if let msg = DisplayModes.restore() { done.append(msg) }
        }
        if chromeHidden, !others.contains(where: { $0.hideChrome }) {
            chromeHidden = false
            chrome.restore()
            done.append("Menu bar and Dock are back.")
        }
        if !done.isEmpty { note(done.joined(separator: " ")) }
    }
}

/// Puts an app's first window into native full screen through Accessibility, for apps
/// that do not run NotchFill's hook (hardened games, apps not started through NotchFill).
/// Apps started with the hook do it themselves; then the window is already in full screen.
enum FullScreenStarter {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to System Settings › Accessibility.
    static func askForPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private static var warned = false

    static func enter(pid: pid_t, note: @escaping (String) -> Void) {
        guard isTrusted else {
            if !warned {
                warned = true
                note("Full Screen at Start needs Accessibility for apps started without NotchFill: Game Profiles › Accessibility.")
            }
            return
        }
        wait(pid: pid, deadline: Date().addingTimeInterval(60))
    }

    /// Waits for a window that can go full screen, gives the app (or the hook) 2 s to do it
    /// itself, then sets AXFullScreen.
    private static func wait(pid: pid_t, deadline: Date) {
        guard Date() < deadline, NSRunningApplication(processIdentifier: pid) != nil else { return }
        if let window = fullScreenCapableWindow(pid: pid) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value)
                if (value as? Bool) != true {
                    AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue)
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { wait(pid: pid, deadline: deadline) }
    }

    private static func fullScreenCapableWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for w in windows {
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(w, "AXFullScreen" as CFString, &settable) == .success, settable.boolValue {
                return w
            }
        }
        return nil
    }
}
