import Cocoa
import ApplicationServices

// MARK: - Windows

struct WindowRef {
    let element: AXUIElement
    let id: CGWindowID
    let title: String
    let minimized: Bool
}

func isUserWindow(_ window: AXUIElement) -> Bool {
    let subrole = axString(window, kAXSubroleAttribute)
    return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
}

/// The app's windows on the current Space (including minimized ones), front to back.
func appWindows(_ app: NSRunningApplication) -> [WindowRef] {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    return axElements(axApp, kAXWindowsAttribute).compactMap { (window: AXUIElement) -> WindowRef? in
        guard isUserWindow(window) else { return nil }
        var id: CGWindowID = 0 // stays 0 when the private API is off: listed, but no thumbnail
        if let getWindow = SPI.axGetWindow {
            _ = getWindow(window, &id)
            guard id != 0 else { return nil }
        }
        let title = axString(window, kAXTitleAttribute) ?? ""
        return WindowRef(element: window,
                         id: id,
                         title: title.isEmpty ? (app.localizedName ?? "Window") : title,
                         minimized: axBool(window, kAXMinimizedAttribute) ?? false)
    }
}

/// The window the user was last working in, if it is currently on screen.
func visibleFocusedWindow(of app: NSRunningApplication) -> AXUIElement? {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        if let window = axElement(axApp, attribute), axBool(window, kAXMinimizedAttribute) != true {
            return window
        }
    }
    return axElements(axApp, kAXWindowsAttribute).first {
        isUserWindow($0) && axBool($0, kAXMinimizedAttribute) != true
    }
}

/// Brings one specific window of another app to the front and makes it key.
/// Uses SkyLight directly because NSRunningApplication.activate() can't pick a window
/// and is often refused for background agents under cooperative activation.
func focusWindow(_ window: AXUIElement, of app: NSRunningApplication) {
    var windowID: CGWindowID = 0
    _ = SPI.axGetWindow?(window, &windowID)
    var psn = PSN()
    if windowID != 0,
       let getPSN = SPI.getPSN,
       let setFront = SPI.setFrontProcess,
       getPSN(app.processIdentifier, &psn) == 0 {
        _ = setFront(&psn, windowID, 0x200) // kCPSUserGenerated
        makeKeyWindow(&psn, windowID)
    } else {
        _ = app.activate(options: [])
    }
    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    axSet(window, kAXMainAttribute, true)
    // Also tell the app itself which window is focused. Without this, an app that is already
    // frontmost can keep its previous window key when switching between its own windows.
    AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                 kAXFocusedWindowAttribute as CFString, window)
}

/// If the frontmost app has no windows left on this Space, focuses the frontmost window of
/// the next app in z-order, so focus doesn't stay on an app with nothing on screen. If no
/// app has a window on screen any more, Finder (the desktop) gets focus instead.
func focusNextWindowIfNoneLeft(in app: NSRunningApplication) {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
          !app.isHidden,
          !appWindows(app).contains(where: { !$0.minimized }) else { return }
    guard let found = frontmostWindow(excluding: app.processIdentifier) else {
        // Every window is minimized. Activating Finder this way doesn't open a new window.
        if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
           finder.processIdentifier != app.processIdentifier {
            _ = finder.activate(options: [])
        }
        return
    }
    let (next, window) = found
    if let window {
        focusWindow(window, of: next)
    } else {
        _ = next.activate(options: [])
    }
}

/// The frontmost on-screen app window not owned by `pid` (or DockPlus), as its app and,
/// when it can be matched, its Accessibility element.
func frontmostWindow(excluding pid: pid_t) -> (NSRunningApplication, AXUIElement?)? {
    let ownPID = ProcessInfo.processInfo.processIdentifier
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return nil }
    for info in list { // front to back
        guard (info[kCGWindowLayer as String] as? Int) == 0,
              let owner = info[kCGWindowOwnerPID as String] as? pid_t,
              owner != pid, owner != ownPID,
              (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict),
              bounds.width >= 50, bounds.height >= 50,
              let app = NSRunningApplication(processIdentifier: owner),
              app.activationPolicy != .prohibited, !app.isHidden else { continue }
        let id = info[kCGWindowNumber as String] as? CGWindowID ?? 0
        let match = appWindows(app).first { $0.id == id && !$0.minimized }?.element
        guard match != nil || SPI.axGetWindow == nil else { continue } // not a user window
        return (app, match)
    }
    return nil
}

/// Posts the synthetic window-server event record that makes a window key
/// (ported via DockDoor/AltTab from Hammerspoon issue #370).
func makeKeyWindow(_ psn: inout PSN, _ windowID: CGWindowID) {
    guard let post = SPI.postEventRecord else { return }
    var bytes = [UInt8](repeating: 0, count: 0xF8)
    bytes[0x04] = 0xF8
    bytes[0x3A] = 0x10
    withUnsafeBytes(of: UInt32(windowID)) { bytes.replaceSubrange(0x3C..<0x40, with: $0) }
    // The location field must be all 0xFF bytes, as in Hammerspoon and AltTab. Writing
    // CGPoint(-1, -1) stores the doubles -1.0 instead, which the window server reads as a real
    // position, so the window was only sometimes made key.
    bytes.replaceSubrange(0x20..<0x30, with: repeatElement(0xFF, count: 0x10))
    bytes[0x08] = 0x01
    _ = post(&psn, &bytes)
    bytes[0x08] = 0x02
    _ = post(&psn, &bytes)
}

/// Thumbnail of one window via SkyLight; nil without Screen Recording permission.
func captureWindow(_ id: CGWindowID) -> CGImage? {
    guard id != 0,
          CGPreflightScreenCaptureAccess(),
          let capture = SPI.captureWindows,
          let connection = SPI.mainConnection else { return nil }
    var windowID = UInt32(id)
    let options: UInt32 = (1 << 11) | (1 << 9) // ignoreGlobalClipShape | nominalResolution
    guard let raw = capture(connection(), &windowID, 1, options) else { return nil }
    let images = Unmanaged<CFArray>.fromOpaque(raw).takeRetainedValue() as NSArray
    guard let first = images.firstObject,
          CFGetTypeID(first as CFTypeRef) == CGImage.typeID else { return nil }
    return (first as! CGImage)
}

/// A copy of `image` no larger than a hover tile needs (at 2x), so cached thumbnails stay small.
func downscaled(_ image: CGImage, maxSize: CGSize = CGSize(width: 440, height: 320)) -> CGImage {
    let scale = min(1, maxSize.width / CGFloat(image.width), maxSize.height / CGFloat(image.height))
    guard scale < 1 else { return image }
    let width = max(1, Int(CGFloat(image.width) * scale))
    let height = max(1, Int(CGFloat(image.height) * scale))
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return image }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage() ?? image
}
