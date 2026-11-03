# README screenshots

Updated on November 4, 2026, from the application sources included in the
refreshed Sessions 1.0.0 release.

- `timer.png` and `cycle-settings.png` are macOS screenshots of the real
  `NSPopover` created by the production `StatusBarController`. Only empty
  transparent margins were cropped; the interface was not resized or redrawn.
  Both use the compact 288 × 440 pt content layout, English, the light theme,
  default cycle durations, and isolated sample progress of 3 out of 8 sessions.
- `menu-bar-full.png` is a native bitmap capture of the real `NSStatusItem`
  button, composited on a neutral dark background without resizing its text
  or symbol.

The capture helper uses isolated preferences and a silent notification backend.
For capture only, it keeps its own popover open and opens Cycle settings
directly. The user's timer, application settings, and system preferences are
not changed.
