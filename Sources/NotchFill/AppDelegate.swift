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
        DisplayModes.restoreIfNeeded()

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
        // Lid closed with an external display: keep the setting, start when the notch is back.
        if defaults.bool(forKey: Pref.mirror) { mirror.start(waitForScreen: true) }

        let mods = cmdKey | optionKey | controlKey
        if let hk = HotKey(id: 1, keyCode: kVK_ANSI_M, modifiers: mods, handler: { [weak self] in self?.toggleMirror() }) {
            hotKeys.append(hk)
        }
        // ⌃⌥⌘0: the user's own display mode; ⌃⌥⌘1…4: favorite display modes.
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4]
        for (slot, keyCode) in digits.enumerated() {
            if let hk = HotKey(id: UInt32(10 + slot), keyCode: keyCode, modifiers: mods, handler: { [weak self] in
                self?.displayHotKey(slot)
            }) {
                hotKeys.append(hk)
            }
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
        DisplayModes.restore()
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
        if mirror.isOn {
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

    @objc func setDisplayMode(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        note(DisplayModes.switchTo(key))
    }

    @objc func restoreDisplayMode() {
        note(DisplayModes.restore() ?? "The display already uses your usual mode.")
    }

    @objc func addFavoriteDisplayMode() {
        guard let cur = DisplayModes.current else { return }
        var favs = DisplayModes.favorites
        guard !favs.contains(cur.key) else { return }
        guard favs.count < DisplayModes.maxFavorites else {
            note("You have \(DisplayModes.maxFavorites) favorites. Remove one first.")
            return
        }
        favs.append(cur.key)
        DisplayModes.favorites = favs
        note("Favorite \(favs.count): \(cur.title). Hot key ⌃⌥⌘\(favs.count).")
    }

    @objc func removeFavoriteDisplayMode(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        DisplayModes.favorites.removeAll { $0 == key }
        note("Removed \(DisplayModes.title(of: key)) from favorites.")
    }

    /// Slot 0: the user's own mode; 1…4: favorites.
    private func displayHotKey(_ slot: Int) {
        if slot == 0 {
            restoreDisplayMode()
            return
        }
        let favs = DisplayModes.favorites
        guard slot <= favs.count else {
            note("No favorite display mode \(slot). Add one in Display Mode › Add Current Mode to Favorites.")
            return
        }
        note(DisplayModes.switchTo(favs[slot - 1]))
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

        if let displayItem = displayModeMenuItem() { menu.addItem(displayItem) }
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
            .state = mirror.isOn ? .on : .off
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

    /// Display Mode submenu: sizes with the notch strip, refresh rates, favorites (⌃⌥⌘1…4),
    /// the user's own mode (⌃⌥⌘0), and the other sizes under More.
    private func displayModeMenuItem() -> NSMenuItem? {
        let entries = DisplayModes.all()
        guard let cur = DisplayModes.current, !entries.isEmpty else { return nil }
        let top = NSMenuItem(title: "Display Mode: \(cur.title)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        top.submenu = sub
        let hotMods: NSEvent.ModifierFlags = [.control, .option, .command]

        func modeItem(_ title: String, _ key: String, on: Bool, in menu: NSMenu) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = key
            i.state = on ? .on : .off
            menu.addItem(i)
            return i
        }

        // Favorites
        sub.addItem(.sectionHeader(title: "Favorites"))
        let favs = DisplayModes.favorites
        for (n, key) in favs.enumerated() {
            let i = modeItem(DisplayModes.title(of: key), key, on: key == cur.key, in: sub)
            i.keyEquivalent = "\(n + 1)"
            i.keyEquivalentModifierMask = hotMods
        }
        if favs.contains(cur.key) {
            let remove = item(sub, "Remove Current Mode from Favorites", #selector(removeFavoriteDisplayMode(_:)))
            remove.representedObject = cur.key
        } else {
            let add = item(sub, "Add Current Mode to Favorites", #selector(addFavoriteDisplayMode))
            add.isEnabled = favs.count < DisplayModes.maxFavorites
        }
        let usual = item(sub, DisplayModes.savedMode.map { "Usual Mode: \(DisplayModes.title(of: $0))" } ?? "Usual Mode",
                         #selector(restoreDisplayMode), key: "0", mods: hotMods)
        usual.isEnabled = DisplayModes.savedMode != nil

        // Sizes that reach the top edge, Retina first.
        sub.addItem(.separator())
        sub.addItem(.sectionHeader(title: "With Notch Strip"))
        let sizes = DisplayModes.sizes(entries)
        for e in sizes where e.withStrip && e.mode.isHiDPI {
            if let best = DisplayModes.best(sizeKey: e.mode.sizeKey, in: entries) {
                _ = modeItem(e.mode.sizeTitle, best.mode.key, on: e.mode.sizeKey == cur.sizeKey, in: sub)
            }
        }

        // Refresh rates of the current size.
        sub.addItem(.separator())
        sub.addItem(.sectionHeader(title: "Refresh Rate"))
        for e in entries where e.mode.sizeKey == cur.sizeKey {
            _ = modeItem(e.mode.rateTitle, e.mode.key, on: e.mode.refreshRate == cur.refreshRate, in: sub)
        }

        // Everything else.
        sub.addItem(.separator())
        let more = NSMenuItem(title: "More Sizes", action: nil, keyEquivalent: "")
        let moreMenu = NSMenu()
        more.submenu = moreMenu
        moreMenu.addItem(.sectionHeader(title: "With Notch Strip, 1x (fewer pixels, scaled up)"))
        for e in sizes where e.withStrip && !e.mode.isHiDPI {
            if let best = DisplayModes.best(sizeKey: e.mode.sizeKey, in: entries) {
                _ = modeItem(e.mode.sizeTitle, best.mode.key, on: e.mode.sizeKey == cur.sizeKey, in: moreMenu)
            }
        }
        moreMenu.addItem(.separator())
        moreMenu.addItem(.sectionHeader(title: "Without Notch Strip (16:10, the notch stays black)"))
        for e in sizes where !e.withStrip {
            if let best = DisplayModes.best(sizeKey: e.mode.sizeKey, in: entries) {
                _ = modeItem(e.mode.sizeTitle, best.mode.key, on: e.mode.sizeKey == cur.sizeKey, in: moreMenu)
            }
        }
        sub.addItem(more)
        return top
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
