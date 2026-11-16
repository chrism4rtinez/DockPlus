# DockPlus

DockPlus is a small menu bar app that adds two Dock behaviors macOS doesn't have:

- **Double-click to minimize and restore.** Double-click a running app's Dock icon to minimize its most recent window. Double-click again to bring back the window you minimized last. Once an app has no windows left on screen, the next window in front gets focus, so you're not left in an app with nothing showing.
- **Hover for window previews.** Rest the pointer on a running app's Dock icon to see a panel with a thumbnail of each of its windows on the current Space, minimized ones included.
  - Click a thumbnail to switch to that window (it's restored if it was minimized).
  - ⌥-click a thumbnail to minimize or restore just that window.
  - Right-click or Control-click the icon to close the panel and open the Dock's usual menu.

Both behaviors can be turned on and off from the DockPlus menu in the menu bar.

## Requirements

- A Mac with **Apple silicon** (M1 or later). Intel Macs aren't supported.
- **macOS 14 Sonoma** or later.
- To build it yourself: Xcode or the Xcode Command Line Tools (`xcode-select --install`).

DockPlus uses a few private macOS APIs for window thumbnails and for focusing one specific window of another app. It only calls them on macOS versions where they're known to work (14 through 27). On any other version it runs in **limited mode**, shown at the top of its menu: no thumbnails, and switching to a window activates its app instead.

## Install

There's no prebuilt download yet, so build it from source:

```sh
git clone https://github.com/chrism4rtinez/Dockplus.git
cd Dockplus
./build.sh
```

This makes `DockPlus.app` in the same folder. Then:

1. Move `DockPlus.app` to `/Applications`.
2. Open it from Finder (or with `open /Applications/DockPlus.app`). Don't run the binary inside the app from Terminal, or macOS will ask to give Terminal the permissions instead of DockPlus.
3. Allow the permissions described below.
4. To start it automatically, choose **Open at Login** from the DockPlus menu.

DockPlus has no Dock icon or windows of its own. Look for its icon in the menu bar.

To uninstall, choose **Quit DockPlus** from its menu, delete the app, and remove its entries from System Settings › Privacy & Security (Accessibility and Screen Recording) and, if you used Open at Login, System Settings › General › Login Items.

## Permissions

| Permission | Needed? | What it's for |
| --- | --- | --- |
| **Accessibility** | Required | Seeing which Dock icon is under the pointer, noticing double-clicks on it, and minimizing, restoring and focusing other apps' windows. |
| **Screen Recording** | Optional | Taking the window thumbnails shown in the hover panel. |

macOS asks for Accessibility the first time you open DockPlus, and DockPlus starts working as soon as you allow it. Without Screen Recording everything else still works, and the hover panel shows window titles and app icons instead of pictures.

You can review or remove either permission at any time in System Settings › Privacy & Security. **Privacy & Security Settings…** in the DockPlus menu takes you there.

macOS ties these permissions to the app's code signature. With the default ad-hoc signature, each rebuild looks like a new app to macOS, so you may have to allow them again after rebuilding. Signing with a stable identity avoids that (see [Signing and distribution](#signing-and-distribution)).

## Privacy and security

- **No network access.** DockPlus never connects to the internet and contains no third-party code.
- **Thumbnails stay in memory.** Window pictures are never written to disk or logged. To show what a minimized window looked like, DockPlus keeps a small, downscaled copy of recently seen windows (at most 64), only while hover previews are on. They're dropped when an app quits, when you turn hover previews off, and when DockPlus quits.
- **Only two settings are saved:** whether double-click and hover previews are on.
- The hover panel is excluded from screen sharing where macOS allows it, and DockPlus never captures the windows of hidden apps.
- The app is always signed with **Hardened Runtime**, so other programs can't inject code into it to borrow its Accessibility and Screen Recording access.

## Building

`build.sh` compiles `DockPlus.swift` with `swiftc` and assembles the app bundle, including its icon from `Icon/AppIcon-1024.png`. It accepts a few environment variables:

| Variable | Default | Effect |
| --- | --- | --- |
| `SIGN_ID` | `-` (ad-hoc) | Code signing identity. |
| `NOTARY_PROFILE` | none | Notarizes and staples the app. Needs a `Developer ID Application` identity in `SIGN_ID`. |
| `VERSION` | `1.0` | Version shown in Finder. |
| `BUILD_NUMBER` | `1` | Build number. |

The build always targets arm64, even on an Intel Mac.

### Signing and distribution

```sh
# Personal use: a stable identity, so permissions survive rebuilds
SIGN_ID="Apple Development: Your Name (TEAMID)" ./build.sh

# For other Macs: Developer ID signed, notarized and stapled
xcrun notarytool store-credentials dockplus   # once
SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=dockplus ./build.sh

# A drag-to-Applications disk image (DockPlus-<version>.dmg)
SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=dockplus ./make-dmg.sh
```

`make-dmg.sh` runs `build.sh` for you and takes the same variables. Run without them, it makes an unsigned DMG around an ad-hoc signed app, which is fine for testing only.

Every pull request and push to `main` is built on Apple silicon by GitHub Actions (`.github/workflows/build.yml`).

## How it works

DockPlus is a single Swift file, `DockPlus.swift`, with no dependencies.

- It watches the Dock's Accessibility tree, which marks the icon under the pointer as selected, to know which app you're hovering over.
- A system-wide event tap sees mouse clicks before the Dock does. On the second click of a double-click on a running app's icon, it swallows that click and minimizes or restores a window. The tap only reads state recorded on hover and never calls into other apps, so a hung app can't stall your mouse.
- Window thumbnails and focusing a specific window use private SkyLight APIs (the same ones [AltTab](https://github.com/lwouis/alt-tab-macos) and [DockDoor](https://github.com/ejbills/DockDoor) use), loaded at runtime and only on known macOS versions.

See the comments at the top of `DockPlus.swift` for details.

## Changes

See [CHANGELOG.md](CHANGELOG.md).

## License

DockPlus is licensed under the [GNU General Public License v3.0](LICENSE).
