# Architecture

Menu bar app (`LSUIElement`), Swift, SwiftPM, macOS 14+. No Xcode project:
`scripts/build-app.sh` builds the `.app` bundle and signs it.

CI (GitHub Actions, `macos-latest`): `build.yml` builds and checks every push and pull request;
`release.yml` runs `scripts/release.sh <next patch version> --publish` on every push to `main`
that touches the app, so each merge produces a GitHub release with the ad-hoc signed zip.

## Modules (`Sources/NotchFill`)

| File | Role |
|------|------|
| `main.swift`, `AppDelegate.swift` | App start, status menu, settings (UserDefaults), diagnostics args. |
| `NotchGeometry.swift` | Finds the notched screen; notch rect from `safeAreaInsets` + `auxiliaryTopLeft/RightArea` widths; coordinate conversion. |
| `SDLMode.swift` | `launchctl setenv/unsetenv SDL_VIDEO_MAC_FULLSCREEN_SPACES`. |
| `SystemChrome.swift` | Menu bar auto-hide (`_HIHideMenuBar` + `AppleInterfaceMenuBarHidingChangedNotification`), Dock auto-hide (private `CoreDockSet/GetAutoHideEnabled`). Saves originals in UserDefaults; restores on quit and on next launch. |
| `NotchMirror.swift` | ScreenCaptureKit stream of the notch rect (+16 pt each side, pointer on), shown 2× in a click-through panel below the notch while the pointer is in the notch. Panel level: shielding level + 1. |
| `HotKey.swift` | Carbon global hot keys (no permission). |
| `Toast.swift` | Short on-screen messages. |
| `DisplayModes.swift` | Built-in display modes through `CGDisplayCopyAllDisplayModes` (with low-resolution duplicates) and `CGConfigureDisplayWithDisplayMode` (`.forSession`). "With notch strip" = same aspect as the panel's largest mode. Saves the user's mode before the first change, puts it back on quit / next launch unless the user changed the mode meanwhile. Favorites (max 4) in UserDefaults; hot keys ⌃⌥⌘0…4 in `AppDelegate`. |
| `GameProfiles.swift` | Per-app profiles in defaults `profiles` (plist dict: key = bundle id, or `exe:<executable name>`; fields `name`, `path`, `isUnity`, `displayMode`, `fullScreen`, `hideChrome`, `unityResolution`). `ProfileWatcher` applies display mode / menu bar+Dock hiding on `NSWorkspace.didLaunchApplication` and undoes them when the last profiled app quits. `FullScreenStarter`: AX `AXFullScreen = true` on the first settable window, 2 s after it appears (not for Unity). The hook and `notchfill-run` read the same dictionary through CFPreferences. |
| `LoginItem.swift` | Open at Login through `SMAppService.mainApp` (no helper app). |
| `GameLauncher.swift` | Launch a game through `notchfill-run`; Steam launch option text; hardened-runtime / platform check. |
| `DisplaySnapshot.swift` | Diagnostics: ScreenCaptureKit screenshot of the display. |

## Game hook (`Hook/`)

| File | Role |
|------|------|
| `NotchFillHook.m` | Universal (arm64 + x86_64) dylib. Swizzles `-[NSWindow _frameForFullScreenMode]` / `_frameForFullScreenModeInRect:` to reach the screen top; on full screen enter puts the window at `kCGMainMenuWindowLevel + 1`, restores the level on exit. Reports `-[NSScreen safeAreaInsets].top = 0` (engines with their own full screen, e.g. Unity). With `NOTCHFILL_RESOLUTION` (else the profile's `unityResolution`, else the global setting) and `UnityPlayer.dylib` in the main bundle, writes Unity's `Screenmanager Resolution Width/Height`. Profile `fullScreen` (not Unity): the first full-screen-capable window calls `toggleFullScreen:` when it becomes key. `NOTCHFILL_DISABLE=1` turns it off. |
| `notchfill-run.c` | `--resolution WxH`: if the bundle (also nested wrapper apps) has `UnityPlayer.dylib`, appends `-screen-width W -screen-height H`; sets `NOTCHFILL_RESOLUTION`. The app's profile wins: its `unityResolution` replaces `--resolution`, and `fullScreen` adds `-screen-fullscreen 1` for Unity. Sets `DYLD_INSERT_LIBRARIES` to the bundled hook and `execv`s the game (.app or executable). Needed because `/bin/sh` strips `DYLD_*`. |
| `scripts/patch-game.py` | For hardened games: backup → add `LC_LOAD_WEAK_DYLIB` to the hook in `~/Library/Application Support/NotchFill/` → ad-hoc re-sign with own entitlements; `restore` puts the originals back. |

Bundle layout: `Contents/MacOS/{NotchFill,notchfill-run}`, `Contents/Resources/libNotchFillHook.dylib`. Hook and launcher are signed without hardened runtime.

## Permissions

- Screen Recording: mirror only.
- Accessibility: Full Screen at Start for apps started without the hook only.
- Stable code signature (`scripts/create-dev-cert.sh`) so TCC grants survive rebuilds.

## Technical constraints (measured, see RESEARCH.md)

- The Dock gives the full screen tile the whole display; AppKit cuts it in `_frameForFullScreenMode` (in-process, so a hook can undo it).
- In full screen, WindowServer's black `Menubar` window (level 24) covers the strip; a window at level 25 is above it.
- AppKit clamps Accessibility position/size to `visibleFrame`, which excludes the strip.
- A borderless window that the app itself sizes to `screen.frame` covers the strip.
