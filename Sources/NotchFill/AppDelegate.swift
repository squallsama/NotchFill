import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Pref {
        static let mirror = "mirrorEnabled"
        static let sdl = "sdlEnabled"
    }

    private let defaults = UserDefaults.standard
    private let chrome = SystemChrome()
    private let mirror = NotchMirror()
    private var statusItem: NSStatusItem!
    private var hotKeys: [HotKey] = []
    private var lastMessage: String?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        chrome.restoreIfNeeded()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "macbook", accessibilityDescription: "NotchFill")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        mirror.onError = { [weak self] message in
            self?.note(message)
            self?.defaults.set(false, forKey: Pref.mirror)
        }
        if defaults.bool(forKey: Pref.sdl) { SDLMode.set(true) }
        if defaults.bool(forKey: Pref.mirror) { mirror.start() }

        let mods = cmdKey | optionKey | controlKey
        if let hk = HotKey(id: 1, keyCode: kVK_ANSI_M, modifiers: mods, handler: { [weak self] in self?.toggleMirror() }) {
            hotKeys.append(hk)
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.mirror.screensChanged()
        }

        if NotchGeometry.notchedScreen() == nil {
            note("No screen with a notch was found. NotchFill has nothing to do on this Mac.")
        }
        runDiagnosticsIfAsked()
    }

    func applicationWillTerminate(_ notification: Notification) {
        mirror.stop()
        chrome.restore()
    }

    // MARK: Actions

    @objc func toggleChrome() {
        if chrome.isHidden {
            chrome.restore()
        } else {
            chrome.hide()
        }
    }

    @objc func toggleMirror() {
        if mirror.isRunning {
            mirror.stop()
            defaults.set(false, forKey: Pref.mirror)
            note("Rear-view mirror is off.")
        } else {
            defaults.set(true, forKey: Pref.mirror)
            mirror.start()
            if mirror.isRunning { note("Rear-view mirror is on. Move the pointer behind the notch.") }
        }
    }

    @objc func toggleSDL() {
        let on = !defaults.bool(forKey: Pref.sdl)
        defaults.set(on, forKey: Pref.sdl)
        SDLMode.set(on)
        note(on ? "SDL games will use the notch area. Restart Steam and the game."
                : "SDL games use the normal full screen again. Restart Steam and the game.")
    }

    @objc func launchGame() {
        GameLauncher.chooseAndLaunch { [weak self] in self?.note($0) }
    }

    @objc func setResolution(_ sender: NSMenuItem) {
        GameLauncher.resolution = sender.representedObject as? String
        if let r = GameLauncher.resolution {
            note("Unity games will start at \(r.replacingOccurrences(of: "x", with: "×")). For Steam, copy the launch option again.")
        } else {
            note("Games use their own resolution setting.")
        }
    }

    @objc func copySteamOption() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(GameLauncher.steamLaunchOption, forType: .string)
        note("Copied. Paste it in Steam › game › Properties › Launch Options.")
    }

    @objc func openScreenRecordingSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func toggleLoginItem() {
        note(LoginItem.set(!LoginItem.isOn))
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: Helpers

    private func note(_ message: String) {
        lastMessage = message
        NSLog("NotchFill: %@", message)
        Toast.show(message)
    }

    /// Diagnostics for development and bug reports (single dash: NSArgumentDomain):
    /// `open NotchFill.app --args -mirror-snapshot <png> [-report <file>] [-quit-after <seconds>]`
    /// starts the mirror, moves the pointer behind the notch and saves what the mirror shows.
    private func runDiagnosticsIfAsked() {
        let args = UserDefaults.standard
        let quitAfter = args.double(forKey: "quit-after")

        // `-display-snapshot <png>`: save the whole built-in display as it is shown now.
        if let path = args.string(forKey: "display-snapshot") {
            Task { @MainActor in
                let ok = await DisplaySnapshot.write(to: path)
                NSLog("NotchFill diagnostics: display snapshot saved=%d", ok ? 1 : 0)
                if quitAfter > 0 { NSApp.terminate(nil) }
            }
            return
        }

        guard let snapshot = args.string(forKey: "mirror-snapshot") else { return }
        let reportPath = args.string(forKey: "report")

        func write(_ text: String) {
            NSLog("NotchFill diagnostics: %@", text)
            if let reportPath { try? (text + "\n").write(toFile: reportPath, atomically: true, encoding: .utf8) }
        }

        mirror.start()
        guard mirror.isRunning, let t = NotchGeometry.notchedScreen() else {
            write("MIRROR FAILED running=\(mirror.isRunning) permission=\(NotchMirror.hasPermission)")
            return
        }
        let p = Coordinates.toTopLeft(CGRect(x: t.notchRect.midX, y: t.notchRect.midY, width: 0, height: 0)).origin
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            CGWarpMouseCursorPosition(p)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let saved = self.mirror.writeSnapshot(to: snapshot)
                write("MIRROR panelVisible=\(self.mirror.isPanelVisible) snapshotSaved=\(saved)")
                if quitAfter > 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + quitAfter) { NSApp.terminate(nil) }
                }
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let t = NotchGeometry.notchedScreen() {
            info(menu, "Notch \(Int(t.notchRect.width))×\(Int(t.notchRect.height)) pt · screen \(Int(t.fullFrame.width))×\(Int(t.fullFrame.height)) pt")
        } else {
            info(menu, "No screen with a notch")
        }
        menu.addItem(.separator())

        item(menu, "Launch Game with Notch Fill…", #selector(launchGame))
        item(menu, "Copy Steam Launch Option", #selector(copySteamOption)).toolTip = GameLauncher.steamLaunchOption
        let resItem = NSMenuItem(title: "Game Resolution", action: nil, keyEquivalent: "")
        let resMenu = NSMenu()
        let current = GameLauncher.resolution
        let own = NSMenuItem(title: "Game's Own Setting", action: #selector(setResolution(_:)), keyEquivalent: "")
        own.target = self
        own.state = current == nil ? .on : .off
        resMenu.addItem(own)
        resMenu.addItem(.separator())
        for preset in GameLauncher.resolutionPresets() {
            let i = NSMenuItem(title: preset.title, action: #selector(setResolution(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = preset.value
            i.state = current == preset.value ? .on : .off
            resMenu.addItem(i)
        }
        resMenu.addItem(.separator())
        let hint = NSMenuItem(title: "Unity games only. Copy the Steam option again after a change.", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        resMenu.addItem(hint)
        resItem.submenu = resMenu
        menu.addItem(resItem)
        let sdl = item(menu, "SDL Games Use Notch Area", #selector(toggleSDL))
        sdl.state = defaults.bool(forKey: Pref.sdl) ? .on : .off
        sdl.toolTip = "Sets \(SDLMode.variable)=0 for apps started from now on. Restart Steam and the game."
        item(menu, "Rear-View Mirror", #selector(toggleMirror), key: "m", mods: [.control, .option, .command])
            .state = mirror.isRunning ? .on : .off
        item(menu, "Hide Menu Bar and Dock", #selector(toggleChrome)).state = chrome.isHidden ? .on : .off
        menu.addItem(.separator())

        let sr = NotchMirror.hasPermission
        item(menu, "Screen Recording: \(sr ? "Allowed" : "Not allowed – Open Settings…")", #selector(openScreenRecordingSettings))

        if let lastMessage {
            menu.addItem(.separator())
            info(menu, lastMessage).toolTip = lastMessage
        }
        menu.addItem(.separator())
        let login = item(menu, "Open at Login", #selector(toggleLoginItem))
        login.state = LoginItem.isOn ? .on : (LoginItem.needsApproval ? .mixed : .off)
        if LoginItem.needsApproval {
            login.toolTip = "Waiting for you to allow it in System Settings › General › Login Items."
        }
        item(menu, "Quit NotchFill", #selector(quit), key: "q", mods: [.command])
    }

    @discardableResult
    private func item(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "",
                      mods: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        menu.addItem(i)
        return i
    }

    @discardableResult
    private func info(_ menu: NSMenu, _ title: String) -> NSMenuItem {
        let short = title.count > 70 ? String(title.prefix(67)) + "…" : title
        let i = NSMenuItem(title: short, action: nil, keyEquivalent: "")
        i.isEnabled = false
        menu.addItem(i)
        return i
    }
}
