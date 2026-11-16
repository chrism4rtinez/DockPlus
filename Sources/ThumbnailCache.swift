import Cocoa
import ApplicationServices

// MARK: - Last-seen thumbnails

/// The last thumbnail captured of each window while it was on screen. A minimized window
/// can't be captured reliably, so the hover panel shows what it looked like when it was
/// last seen, ideally just before it was minimized. Main thread only; kept in memory only,
/// downscaled, one per window, limited in number, and dropped once older than the lifetime
/// the user chose ("thumbnailLifetime").
final class ThumbnailCache {
    private static let limit = 64
    private var entries: [CGWindowID: (pid: pid_t, image: CGImage, stamp: UInt64, captured: UInt64)] = [:]
    private var counter: UInt64 = 0

    /// Choices offered for how long a picture is kept, in seconds; 0 keeps it until the app
    /// quits (or DockPlus does).
    static let lifetimes: [(seconds: Int, title: String)] = [
        (5 * 60, "5 Minutes"),
        (15 * 60, "15 Minutes"),
        (60 * 60, "1 Hour"),
        (24 * 60 * 60, "1 Day"),
        (0, "Until the App Quits"),
    ]
    static let defaultLifetime = 0 // until the app quits

    /// Seconds since an arbitrary point, counting time asleep and unaffected by clock changes,
    /// so a picture expires on time even across sleep or a changed system clock.
    private static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000_000 }

    private var lifetime: UInt64 { UInt64(max(0, UserDefaults.standard.integer(forKey: "thumbnailLifetime"))) }

    func image(for id: CGWindowID) -> CGImage? {
        removeExpired()
        return entries[id]?.image
    }

    /// Drops pictures older than the chosen lifetime. Runs every 2 seconds, when the lifetime
    /// is changed, and before any picture is shown.
    func removeExpired() {
        let lifetime = self.lifetime
        guard lifetime > 0, !entries.isEmpty else { return }
        let now = Self.now()
        entries = entries.filter { now - $0.value.captured < lifetime }
    }

    func store(_ image: CGImage, for id: CGWindowID, pid: pid_t) {
        // A capture can finish after its app quit or previews were turned off; don't keep it then.
        guard id != 0, UserDefaults.standard.bool(forKey: "hoverPreviews"),
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        counter += 1
        entries[id] = (pid, image, counter, Self.now())
        if entries.count > Self.limit, let oldest = entries.min(by: { $0.value.stamp < $1.value.stamp }) {
            entries[oldest.key] = nil
        }
    }

    func forget(_ pid: pid_t) {
        entries = entries.filter { $0.value.pid != pid }
    }

    /// Drops every picture, e.g. when hover previews are turned off.
    func removeAll() {
        entries.removeAll()
        lastClickCapture = .distantPast
    }

    private var lastClickCapture = Date.distantPast

    /// Captures a window now, on the calling (main) thread. Used right before DockPlus itself
    /// minimizes a window, so the cached image is exactly what was on screen.
    func captureNow(_ window: AXUIElement) {
        var id: CGWindowID = 0
        _ = SPI.axGetWindow?(window, &id)
        guard id != 0, let image = captureWindow(id) else { return }
        store(downscaled(image), for: id, pid: axPID(window))
    }

    /// Captures the normal app window under a screen point (Quartz coordinates), off the main
    /// thread. Uses only the window server, never Accessibility, since it runs on every click.
    func refreshWindow(at point: CGPoint) {
        // At most one click capture per half second, so rapid clicking stays cheap.
        guard Date().timeIntervalSince(lastClickCapture) > 0.5 else { return }
        lastClickCapture = Date()
        let me = getpid()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                        kCGNullWindowID) as? [[String: Any]] else { return }
            // Front to back: the first window containing the point is the one clicked.
            guard let hit = list.first(where: { info in
                guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return false }
                return bounds.contains(point)
            }),
                  (hit[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (hit[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != me,
                  let number = hit[kCGWindowNumber as String] as? NSNumber else { return }
            let id = CGWindowID(number.uint32Value)
            guard let image = captureWindow(id).map({ downscaled($0) }) else { return }
            // Minimized while this was being captured: keep the earlier, clean image.
            let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
            guard (info?.first?[kCGWindowIsOnscreen as String] as? Bool) == true else { return }
            DispatchQueue.main.async { self?.store(image, for: id, pid: pid) }
        }
    }

    /// Captures a window that is on screen, off the main thread, and caches the result.
    func refresh(_ window: AXUIElement) {
        var id: CGWindowID = 0
        _ = SPI.axGetWindow?(window, &id)
        // Only standard windows: sheets, panels and dialogs would just use up cache slots.
        guard id != 0, CGPreflightScreenCaptureAccess(),
              axString(window, kAXSubroleAttribute) == kAXStandardWindowSubrole,
              axBool(window, kAXMinimizedAttribute) != true else { return }
        let pid = axPID(window)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let image = captureWindow(id).map({ downscaled($0) }) else { return }
            DispatchQueue.main.async {
                // Minimized while this was being captured: keep the earlier, clean image.
                guard axBool(window, kAXMinimizedAttribute) != true else { return }
                self?.store(image, for: id, pid: pid)
            }
        }
    }
}
