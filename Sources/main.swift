import Cocoa

// MARK: - Entry point

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = DockPlus.shared
application.run()
