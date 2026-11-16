import AppKit

/// One mode of the built-in display, in the form NotchFill stores and shows.
struct DisplayMode: Equatable {
    /// Size in points (what apps and games see as the desktop).
    let width: Int
    let height: Int
    /// Size in pixels: twice the points for Retina (HiDPI) modes.
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double

    init(_ mode: CGDisplayMode) {
        width = mode.width
        height = mode.height
        pixelWidth = mode.pixelWidth
        pixelHeight = mode.pixelHeight
        refreshRate = (mode.refreshRate * 100).rounded() / 100
    }

    var isHiDPI: Bool { pixelWidth > width }

    /// Text form stored in UserDefaults, e.g. "1728x1117@120" or "2336x1510/1x@60".
    var key: String { "\(sizeKey)@\(rateText)" }

    /// Same size and kind, any refresh rate.
    var sizeKey: String { "\(width)x\(height)\(isHiDPI ? "" : "/1x")" }

    var rateText: String { String(format: "%g", refreshRate) }

    var sizeTitle: String { "\(width)×\(height)\(isHiDPI ? "" : " (1x)")" }
    var rateTitle: String { "\(rateText) Hz" }
    var title: String { "\(sizeTitle) · \(rateTitle)" }
}

/// Lists and switches the modes of the built-in display, keeps favorites, and puts back
/// the user's own mode. Public CoreGraphics calls: no SIP change, no permission.
///
/// Changes last for the login session only (`.forSession`). The user's own mode is
/// stored in UserDefaults before the first change, so NotchFill can put it back when it
/// quits, and on the next launch after a crash.
enum DisplayModes {
    struct Entry {
        let mode: DisplayMode
        let cgMode: CGDisplayMode
        /// The mode covers the strip beside the notch (e.g. 1728×1117, not 1728×1080).
        let withStrip: Bool
    }

    private enum Key {
        static let saved = "display.savedMode"      // the user's own mode before our first change
        static let applied = "display.appliedMode"  // the mode NotchFill set last
        static let favorites = "display.favorites"  // [String], at most `maxFavorites`
    }

    static let maxFavorites = 4
    private static let defaults = UserDefaults.standard

    // MARK: Display and modes

    /// The built-in display, if it is on (not with the lid closed).
    static var builtInDisplay: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static var current: DisplayMode? {
        builtInDisplay.flatMap { CGDisplayCopyDisplayMode($0) }.map(DisplayMode.init)
    }

    /// All desktop modes, one per key, largest first, faster refresh first.
    static func all() -> [Entry] {
        guard let display = builtInDisplay else { return [] }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let cgModes = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
        var seen = Set<String>()
        var unique: [(DisplayMode, CGDisplayMode)] = []
        for m in cgModes where m.isUsableForDesktopGUI() {
            let mode = DisplayMode(m)
            if seen.insert(mode.key).inserted { unique.append((mode, m)) }
        }
        // A mode reaches the top edge (beside the notch) when it has the aspect of the whole
        // panel, i.e. of the mode with the most pixels (3456×2234 on a 16" MacBook Pro).
        // 16:10 modes (1728×1080, 1280×800…) leave the strip black.
        let panel = unique.map(\.0).max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
        let panelAspect = panel.map { Double($0.pixelHeight) / Double($0.pixelWidth) } ?? 0
        return unique
            .map { mode, cg in
                let aspect = Double(mode.height) / Double(mode.width)
                return Entry(mode: mode, cgMode: cg, withStrip: abs(aspect - panelAspect) < 0.005)
            }
            .sorted {
                ($0.mode.width, $0.mode.height, $0.mode.refreshRate) > ($1.mode.width, $1.mode.height, $1.mode.refreshRate)
            }
    }

    /// One entry per size (the fastest refresh rate), for size lists in the menu.
    static func sizes(_ entries: [Entry]) -> [Entry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.mode.sizeKey).inserted }
    }

    /// The best mode of `sizeKey`: the current refresh rate if that size has it, else the fastest.
    static func best(sizeKey: String, in entries: [Entry]) -> Entry? {
        let same = entries.filter { $0.mode.sizeKey == sizeKey }
        return same.first { $0.mode.refreshRate == current?.refreshRate } ?? same.first
    }

    /// The current size at another refresh rate.
    static func withRate(_ rate: Double, in entries: [Entry]) -> Entry? {
        guard let cur = current else { return nil }
        return entries.first { $0.mode.sizeKey == cur.sizeKey && $0.mode.refreshRate == rate }
    }

    // MARK: Switching

    /// Whether NotchFill changed the mode and can put the user's own one back.
    static var savedMode: String? { defaults.string(forKey: Key.saved) }

    /// Switches to `key`. Returns a short message for the user.
    @discardableResult
    static func switchTo(_ key: String) -> String {
        guard let display = builtInDisplay, let cur = current else {
            return "The built-in display is off."
        }
        guard let entry = all().first(where: { $0.mode.key == key }) else {
            return "This display has no mode \(key)."
        }
        if key == cur.key { return "The display already uses \(entry.mode.title)." }
        if savedMode == nil { defaults.set(cur.key, forKey: Key.saved) }
        guard apply(entry.cgMode, to: display) else { return "macOS did not switch to \(entry.mode.title)." }

        if key == savedMode {
            forgetSaved()
            return "Display: \(entry.mode.title), your usual mode."
        }
        defaults.set(key, forKey: Key.applied)
        return "Display: \(entry.mode.title). ⌃⌥⌘0 puts back \(savedTitle ?? "your mode")."
    }

    /// Puts back the user's own mode. Does nothing if the user picked another mode in
    /// System Settings meanwhile (then that one is theirs). Returns a message, or nil if
    /// there was nothing to do.
    @discardableResult
    static func restore() -> String? {
        guard let saved = savedMode else { return nil }
        guard let display = builtInDisplay, let cur = current else { return nil } // lid closed: later
        if cur.key != defaults.string(forKey: Key.applied) || cur.key == saved {
            forgetSaved()
            return nil
        }
        guard let entry = all().first(where: { $0.mode.key == saved }) else {
            forgetSaved()
            return nil
        }
        let ok = apply(entry.cgMode, to: display)
        forgetSaved()
        return ok ? "Display: \(entry.mode.title), your usual mode." : "macOS did not switch back to \(entry.mode.title)."
    }

    /// Call on launch: if the last run ended without putting the mode back, do it now.
    static func restoreIfNeeded() { restore() }

    private static var savedTitle: String? {
        savedMode.flatMap { key in all().first { $0.mode.key == key }?.mode.title }
    }

    private static func forgetSaved() {
        defaults.removeObject(forKey: Key.saved)
        defaults.removeObject(forKey: Key.applied)
    }

    private static func apply(_ mode: CGDisplayMode, to display: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, display, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    // MARK: Favorites (⌃⌥⌘1…4)

    static var favorites: [String] {
        get { defaults.stringArray(forKey: Key.favorites) ?? [] }
        set { defaults.set(Array(newValue.prefix(maxFavorites)), forKey: Key.favorites) }
    }

    static func title(of key: String) -> String {
        all().first { $0.mode.key == key }?.mode.title ?? key.replacingOccurrences(of: "x", with: "×")
    }
}
