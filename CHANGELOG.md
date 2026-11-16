# Changelog

## Unreleased

## 1.0 (2026-11-16)

The first public release, as a signed and notarized disk image. The notes below are for anyone who ran an earlier build from source.

- **Bundle ID changed** from `local.dockplus` to `com.chrism4rtinez.dockplus`. Your double-click and hover settings carry over automatically. macOS ties the rest to the bundle ID, so after updating:
  - Allow **Accessibility** and **Screen Recording** again when asked. Remove the old DockPlus entries from System Settings › Privacy & Security.
  - If you used **Open at Login**, turn it on again from the DockPlus menu, and remove the old entry from System Settings › General › Login Items.
- DockPlus runs on **Apple silicon Macs only**.
- When you minimize an app's last window on screen (with DockPlus, the yellow button or ⌘M), the next window in front gets focus instead of the empty app.
- When that was the last window of any app on screen, so every window is minimized, focus goes to Finder.
- DockPlus has its own app icon in Finder, Launchpad and System Settings.
- The menu bar icon now matches the app icon.
- **Setup guide.** On first launch (and once after updating), DockPlus shows two short screens: a welcome that sums up what it does and how it protects you, then one screen to allow permissions and choose your settings. It explains why it needs each permission before macOS asks. Screen Recording is optional: skip it and the hover preview shows titles and app icons instead of window pictures. DockPlus starts working once you finish setup and allow Accessibility.
- **Permission status in the menu.** The DockPlus menu shows whether Accessibility and Screen Recording are allowed, and each line opens the right page of System Settings. The menu bar icon turns into a warning sign while DockPlus can't work.
- If you turn off Accessibility for DockPlus while it's running, it stops watching clicks and the Dock right away, and picks up again when you turn it back on. Turning off Screen Recording drops any window pictures it kept in memory.
- DockPlus no longer asks for Screen Recording the first time you hover over the Dock.
- **Choose how long preview thumbnails are kept.** The pictures DockPlus keeps to show minimized windows in the hover preview are kept until their app quits, as before. To delete them sooner, choose 5 minutes, 15 minutes, 1 hour or 1 day under **Keep preview thumbnails for…** in the DockPlus menu, or in the setup guide.
- If Open at Login needs your approval in System Settings, DockPlus opens that page. If it fails, DockPlus tells you instead of failing silently.
- The source is now split into several files in `Sources/` instead of one `DockPlus.swift`. Nothing changes in how DockPlus behaves or how you build it.
