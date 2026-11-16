NotchFill @VERSION@ — full screen games use the strip beside the notch on MacBooks with a notch. No SIP changes.

## Install

1. Download `NotchFill-@VERSION@.zip` and unzip it.
2. Move `NotchFill.app` to `/Applications` (the Steam launch option points to the app's location).
3. The app is **not signed with an Apple Developer ID and not notarized**, so macOS blocks the first launch. Do one of these:
   - Open it once, then go to **System Settings › Privacy & Security** and click **Open Anyway**.
   - Or in Terminal: `xattr -dr com.apple.quarantine /Applications/NotchFill.app`
4. NotchFill shows a laptop icon in the menu bar.

Requirements: MacBook with a notch (Apple silicon), macOS 14 or later.

## Use

- **Launch Game with Notch Fill…** — start a game; then enter full screen in the game.
- **Copy Steam Launch Option** — paste it in Steam › game › Properties › Launch Options.
- **Game Resolution** — Unity games start with the aspect of the whole screen.
- **Display Mode** — sizes with the notch strip, refresh rate, favorites on ⌃⌥⌘1…4, ⌃⌥⌘0 back to your mode.
- **Game Profiles** — per app: display mode, full screen at start, hide menu bar and Dock, Unity resolution.
- **SDL Games Use Notch Area**, **Rear-View Mirror** (Screen Recording permission), **Hide Menu Bar and Dock**.

NotchFill loads a small library into the game you start with it. Do not use it with online games that have anti-cheat. Games with the hardened runtime cannot load it (NotchFill tells you).

SHA-256 of the zip: see `NotchFill-@VERSION@.zip.sha256`.
