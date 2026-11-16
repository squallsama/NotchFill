import AppKit

/// Starts games with NotchFillHook loaded (`Contents/MacOS/notchfill-run` in this bundle),
/// so native full screen covers the notch strip. No SIP change is needed. Games with the
/// hardened runtime load the hook only with both `allow-dyld-environment-variables` and
/// `disable-library-validation`.
enum GameLauncher {
    static var runnerPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/notchfill-run").path
    }

    // MARK: Resolution (Unity games: -screen-width / -screen-height)

    private static let resolutionKey = "gameResolution"

    /// Chosen resolution as "WxH", nil = the game's own setting.
    static var resolution: String? {
        get { UserDefaults.standard.string(forKey: resolutionKey) }
        set { UserDefaults.standard.set(newValue, forKey: resolutionKey) }
    }

    /// Sizes with the aspect of the whole display (notch strip included), in pixels.
    static func resolutionPresets() -> [(title: String, value: String)] {
        guard let t = NotchGeometry.notchedScreen() else { return [] }
        let scale = t.screen.backingScaleFactor
        let w = t.fullFrame.width * scale, h = t.fullFrame.height * scale
        return [(1.0, "Full"), (0.75, "75%"), (0.5, "50%")].map { factor, label in
            let pw = Int((w * factor).rounded()), ph = Int((h * factor).rounded())
            return ("\(label) – \(pw)×\(ph)", "\(pw)x\(ph)")
        }
    }

    private static var resolutionArgs: [String] { resolution.map { ["--resolution", $0] } ?? [] }

    /// Paste into Steam › game › Properties › Launch Options.
    static var steamLaunchOption: String {
        (["\"\(runnerPath)\""] + resolutionArgs + ["%command%"]).joined(separator: " ")
    }

    enum Check {
        case ok
        case hardened
        case notAnApp
    }

    /// Hardened-runtime games drop DYLD_INSERT_LIBRARIES unless they allow it, and their
    /// library validation refuses the hook (another signer) unless they turn it off. Wrapper
    /// apps (a small launcher that starts an inner .app) are checked with all their inner apps.
    static func check(_ app: URL) -> Check {
        guard let bundle = Bundle(url: app), let exe = bundle.executableURL else { return .notAnApp }
        if checkExecutable(exe) == .hardened { return .hardened }
        for inner in nestedApps(in: app) {
            if let innerExe = Bundle(url: inner)?.executableURL, checkExecutable(innerExe) == .hardened {
                return .hardened
            }
        }
        return .ok
    }

    private static func nestedApps(in app: URL) -> [URL] {
        let contents = app.appendingPathComponent("Contents")
        guard let e = FileManager.default.enumerator(at: contents, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        for case let url as URL in e {
            if e.level > 4 { e.skipDescendants(); continue }
            if url.pathExtension == "app" { result.append(url) }
        }
        return result
    }

    private static func checkExecutable(_ exe: URL) -> Check {
        // Patched with scripts/patch-game.py: the game loads the hook by itself.
        if let data = try? Data(contentsOf: exe, options: .mappedIfSafe),
           data.range(of: Data("NotchFill/libNotchFillHook.dylib".utf8)) != nil {
            return .ok
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(exe as CFURL, [], &code) == errSecSuccess, let code else { return .ok }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSDynamicInformation | kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return .ok }
        // Apple platform binaries never take DYLD_* variables.
        if dict[kSecCodeInfoPlatformIdentifier as String] != nil { return .hardened }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let runtime: UInt32 = 0x10000
        guard flags & runtime != 0 else { return .ok }
        // The hardened runtime needs two exceptions: one lets dyld read DYLD_INSERT_LIBRARIES,
        // the other lets a library from another team (the hook) load.
        let ents = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let takesDyldVariables = ents["com.apple.security.cs.allow-dyld-environment-variables"] as? Bool == true
        let takesOtherLibraries = ents["com.apple.security.cs.disable-library-validation"] as? Bool == true
        return takesDyldVariables && takesOtherLibraries ? .ok : .hardened
    }

    static func launch(_ app: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: runnerPath)
        p.arguments = resolutionArgs + [app.path]
        p.currentDirectoryURL = app.deletingLastPathComponent()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    /// Asks for a game app, then starts it with the hook.
    static func chooseAndLaunch(note: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose a game"
        panel.prompt = "Launch"
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let app = panel.url else { return }
        let name = app.deletingPathExtension().lastPathComponent
        switch check(app) {
        case .notAnApp:
            note("\(name) is not an app.")
            return
        case .hardened:
            note("\(name) uses the hardened runtime and blocks the hook. Notch fill will not work for it.")
            return
        case .ok:
            break
        }
        do {
            try launch(app)
            let res = resolution.map { " at \($0.replacingOccurrences(of: "x", with: "×")) (Unity games)" } ?? ""
            note("\(name) started with notch fill\(res). Enter full screen in the game.")
        } catch {
            note("Cannot start \(name): \(error.localizedDescription)")
        }
    }
}
