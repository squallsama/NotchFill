# Research: full screen into the notch strip

Measured on a 16" MacBook Pro (Mac17,6, M5 Max), macOS 27.2.1, SIP on.
Screen: 1728×1117 pt (3456×2234 px). Notch: 185×32 pt (`safeAreaInsets.top = 32`).

## Findings

| # | Test | Result |
|---|------|--------|
| 1 | Native full screen (`toggleFullScreen`) | Window 1728×1084 at y=33. The strip is black. |
| 2 | Same, with AppKit defaults `NSFullScreenTileFillsScreen`, `NSApplicationSafeApertureCompatibilityModeAppFullScreen/SystemFullScreen`, `NSPrefersDisplaySafeAreaCompatibilityMode` (YES and NO) | No change. |
| 3 | App calls `setFrame(screen.frame)` while in native full screen | Stays 1084. The limit is outside the app: the Dock sizes the full screen Space. |
| 4 | App makes its own borderless window and calls `setFrame(screen.frame)` | 1728×1117 at y=0. Works with or without the menu bar visible. WindowServer allows it. |
| 5 | Another process moves/resizes that borderless window through Accessibility (`AXPosition`, `AXSize`) | Clamped to 1728×1085 at y=32, also with the menu bar on auto-hide. AppKit's AX setter keeps windows inside `visibleFrame`, and `visibleFrame` never includes the strip (1084 → 1085 with auto-hide). `AXFrame` is not settable. |
| 6 | ScreenCaptureKit capture of the notch rect | Works, includes the pointer. This is the mirror. |
| 7 | Minimal SDL program, `SDL_SetWindowFullscreen` (desktop), with SDL3 3.x (DuckStation build, arm64), SDL2 (CrossOver, arm64) and SDL2 (HoMM3 HD, x86_64 under Rosetta) | Without the variable: 1728×1084 at y=33. With `SDL_VIDEO_MAC_FULLSCREEN_SPACES=0`: 1728×1117 at y=0. Same for all three. |
| 8 | NotchFill sets the variable with `launchctl setenv`, test app started with `open` (LaunchServices) | Gets the variable, 1728×1117. After turning it off: 1084 again. |

Conclusion: without SIP changes, only the app itself can put a window into the strip
(test 4). Accessibility from outside cannot (test 5), and native full screen is sized by
the Dock (test 3).

## What this means for games

- **SDL2 / SDL3 games**: `SDL_VIDEO_MAC_FULLSCREEN_SPACES=0` makes SDL use its own
  borderless full screen at the display bounds (test 4 path). NotchFill sets it with
  `launchctl setenv` (tests 7, 8). Works when the game uses SDL's desktop full screen;
  a game that makes its own full screen window does not read this variable.
- **Games with their own borderless full screen at `NSScreen.frame`**: already use the strip.
- **Games in native full screen (green button, most Metal ports)**: need phase 2.

## Safe-aperture compatibility mode (no SIP) — tested, does not help

AppKit has per-app "safe aperture compatibility" modes (bit mask: 1 system full screen,
2 app full screen, 4 windowed), read from `APPLE_DISPLAY_SAFE_AREA_COMPATIBILITY_MODE`,
`_NS_SAFE_APERTURE_COMPATIBILITY_MODES`, the defaults keys
`NSApplicationSafeApertureCompatibilityMode{SystemFullScreen,AppFullScreen,Windowed}` and
LaunchServices keys (`LSSafeAperture*CompatPreferred`, Finder "Scale to fit below camera").

| # | Test | Result |
|---|------|--------|
| 9 | `APPLE_DISPLAY_SAFE_AREA_COMPATIBILITY_MODE=1` (AppKit rewrites it to `YES`, mode = 4) | Native full screen window is 1728×1117 at y=0, 3456×2234 px backing, `safeAreaInsets.top = 0` for the whole system while that Space is active. Display mode does not change. |
| 10 | Same, what the user sees | Black strip at the top: the display output is scaled below the notch. A ScreenCaptureKit screenshot does **not** show this scaling (it shows the full frame), so only the eye can verify it. |
| 11 | `SLSTransactionSetSafeApertureOverride(t, double)` and `SLSTransactionSetSafeApertureSpaceReveal(t, spaceID, double)` from a normal process (the Dock animates these 0…1) | Accepted without error, no visible change (0 and 1, both). WindowServer seems to take them only from the Dock. |

The other variables (`_NS_SAFE_APERTURE_COMPATIBILITY_MODES=0/7`, `…=0`, `-NSApplicationSafeApertureCompatibilityMode* NO/YES`) do not change the mode.

## Working method without SIP: hook inside the game

| # | Test (inside the full screen app) | Result |
|---|------|--------|
| 12 | `ConnectionSafeApertureCompatibility` connection property = 1/4/7 at launch (`SLSSetConnectionProperty`) | Same as the env var: 1117 pt but scaled output. Resetting it later does not clear `SLSGetSpaceNeedsSafeAperture` for the Space (set when the Space is made). |
| 13 | Private getters: `_tileFrameForFullScreen`, `_fullScreenTileFrame` | Already 1728×1117: the Dock gives the whole display. |
| 14 | `-[NSWindow _frameForFullScreenMode]`, `_visibleTileFrameForFullScreen` | 1728×1084: **AppKit** cuts the tile below the notch. |
| 15 | Swizzle `_frameForFullScreenMode` and `_frameForFullScreenModeInRect:` to reach the top edge | Window 1728×1117 at y=0, `needsSafeAperture` false (no scaling), backing 3456×2234 px. But the strip still looks black: WindowServer's `Menubar` window (level 24, 1728×33) is on top. `presentationOptions`, `_agent_setFullScreenAutohideHeight:0`, and rewriting/dropping `+[NSCGSSpace setMenuBarSettings:globalSettings:]` do not remove it. |
| 16 | 15 + window level `kCGMainMenuWindowLevel + 1` (25) while in full screen | **Strip filled.** Confirmed by eye on the 16" MacBook Pro and by a display snapshot. Same with an x86_64 build under Rosetta. |

Product: `Hook/NotchFillHook.m` (universal dylib) does 15 + 16; it is loaded with
`DYLD_INSERT_LIBRARIES` through `notchfill-run` (Steam launch option or the NotchFill menu).
Limits: games with the hardened runtime load it only when they have both
`allow-dyld-environment-variables` and `disable-library-validation`; Apple platform apps
never do. While a game is in full screen its window is
above the menu bar, so the menu bar does not reveal at the top edge.

Real games:

- An SDL-based game in native full screen: fills the strip.
- A Unity 6 game (il2cpp) with its own borderless full screen: Unity sizes that window from
  `NSScreen.safeAreaInsets` (1728×1084 at y=33), so the hook also reports
  `safeAreaInsets.top = 0` in-process. Its app was a wrapper (`Contents/MacOS/load` execs an
  inner `.app` and drops all arguments), and only the inner binary had the hardened runtime
  (with `disable-library-validation`, without `allow-dyld-environment-variables`), so dyld
  ignored `DYLD_INSERT_LIBRARIES`. NotchFill now checks nested apps too. With
  `scripts/patch-game.py` the hook loaded and the window covered the strip, but the game kept
  its own resolution in its own settings file (over Unity's PlayerPrefs) and letterboxed the
  picture to a fixed wide aspect itself. Lesson: some games fill only a fixed aspect; notch
  fill cannot change that from outside.

Gotcha: a signed binary must be replaced by a new file (rename), not rewritten in place,
or the kernel's cached signature kills the next launch (SIGKILL, exit 137).

## Phase 2 options

### A. Dock add-on (the ProMax way, needs SIP partly off) — not done: the project avoids SIP changes

ProMax setup (from its site): in Recovery, `csrutil enable --without fs --without debug`.
It then loads add-ons into the Dock, the window manager and the menu bar, with a root
helper that reloads them when the Dock restarts.

Leads in the Dock binary (`strings`):

- `initWithIdentifier:screenBoundsIncludingMenuBar:screenBoundsExcludingMenuBar:menuBarBounds:notchBounds:scaleFactor:supportsHDR:`
- `notchBounds`, `notchHeight`, `notchHeightForDisplay:`

Hypothesis: the Dock builds the full screen Space from `screenBoundsExcludingMenuBar`
(or subtracts `notchHeight`). Making it use `screenBoundsIncludingMenuBar` for full screen
Spaces would give the full 1117 pt. AppKit talks to the Dock through
`_NSFullScreenDockConnection*` (create / enter / update space).

Open questions:
- Injecting into the arm64e Dock: yabai needs `-arm64e_preview_abi` in boot-args for its
  loader; ProMax does not ask for it, so it may use another technique (for example data
  patches through `task_for_pid`, allowed with `--without debug`).
- `WindowManager.app` has `notchRect` and `initWithFrame:safeArea:style:`; it may also take
  part in tiling / full screen on macOS 26+.

### B. Inject into the game (no SIP change)

A dylib loaded with `DYLD_INSERT_LIBRARIES` (Steam launch option) replaces native full
screen with a borderless window at `screen.frame` from inside the game (test 4).
Works only for games without hardened runtime / library validation. Risk: anti-cheat may
treat it as cheating. ProMax avoids this on purpose.

Most games sold outside the Mac App Store are ad-hoc signed or have no hardened runtime and
take `DYLD_INSERT_LIBRARIES`; a game with the hardened runtime needs
`com.apple.security.cs.allow-dyld-environment-variables` and, because the hook has another
signer, `com.apple.security.cs.disable-library-validation` (check also apps nested inside a
wrapper app).
The variable must be per game (Steam launch option or a NotchFill launcher), never global
through `launchctl setenv`.
