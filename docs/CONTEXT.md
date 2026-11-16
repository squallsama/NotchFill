# Context

## Goal

Open source alternative to ProMax Display: full screen games on notched MacBooks use the
whole display, including the strip beside the notch (14" 3024×1898 → 3024×1964 px).

## Users

Mac gamers with a notched MacBook Pro / Air.

## Scope

- Phase 1 (done, no SIP changes): SDL games use the notch area; rear-view mirror;
  hide menu bar and Dock with safe restore.
- Phase 2 (works, no SIP): native full screen games cover the strip through a hook library
  loaded into the game (opt-in per game: menu launcher or Steam launch option).
  Project rule: no SIP changes, so no Dock add-on.
- Display mode switching (no SIP): sizes with the notch strip, refresh rate, favorites on hot keys;
  the user's own mode comes back on quit.
- Later: trackpad gestures for Dock / menu bar / Control Center.

## Rules

- Never change user settings without saving the original and restoring it.
- No code goes into games unless the user opts in per game.
