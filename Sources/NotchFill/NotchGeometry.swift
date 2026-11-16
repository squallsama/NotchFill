import AppKit

/// Geometry of a screen that has a camera housing (notch) at the top edge.
struct NotchScreen {
    let screen: NSScreen
    /// Whole screen, Cocoa global coordinates (bottom-left origin), includes the notch strip.
    let fullFrame: CGRect
    /// The notch itself, Cocoa global coordinates.
    let notchRect: CGRect
    /// Height of the strip beside the notch that full screen apps normally leave black.
    var stripHeight: CGFloat { notchRect.height }

    var displayID: CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// Notch rect in display-local points with a top-left origin (what ScreenCaptureKit wants).
    func notchRectDisplayLocal(expandedBy dx: CGFloat = 0) -> CGRect {
        CGRect(x: notchRect.minX - fullFrame.minX - dx,
               y: 0,
               width: notchRect.width + 2 * dx,
               height: notchRect.height)
    }
}

enum NotchGeometry {
    /// Last notch seen per display. While an app in safe-area compatibility mode is in
    /// full screen, macOS reports `safeAreaInsets.top == 0` for the whole display.
    /// Kept with the screen frame it was measured on: after a display mode change (or in a
    /// mode without the strip, e.g. 1728×1080) the old rect is wrong, so it is not used.
    private static var lastKnown: [CGDirectDisplayID: (notch: CGRect, frame: CGRect)] = [:]

    /// The first screen with a notch (on a MacBook that is the built-in display).
    static func notchedScreen() -> NotchScreen? {
        for screen in NSScreen.screens {
            if let info = describe(screen) {
                lastKnown[info.displayID] = (info.notchRect, info.fullFrame)
                return info
            }
        }
        for screen in NSScreen.screens {
            let probe = NotchScreen(screen: screen, fullFrame: screen.frame, notchRect: .zero)
            if let known = lastKnown[probe.displayID], known.frame == screen.frame {
                return NotchScreen(screen: screen, fullFrame: screen.frame, notchRect: known.notch)
            }
        }
        return nil
    }

    static func describe(_ screen: NSScreen) -> NotchScreen? {
        let top = screen.safeAreaInsets.top
        guard top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let frame = screen.frame
        // Use widths only: the auxiliary rects are documented in "screen coordinates",
        // and widths do not depend on which origin macOS uses for them.
        let notchWidth = frame.width - left.width - right.width
        guard notchWidth > 0 else { return nil }
        let notch = CGRect(x: frame.minX + left.width,
                           y: frame.maxY - top,
                           width: notchWidth,
                           height: top)
        return NotchScreen(screen: screen, fullFrame: frame, notchRect: notch)
    }
}

enum Coordinates {
    /// Height of the primary screen (the one that holds the global origin).
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    /// Cocoa (bottom-left origin) -> Quartz (top-left origin).
    static func toTopLeft(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
