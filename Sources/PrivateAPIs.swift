import Cocoa
import ApplicationServices

// MARK: - Private APIs

/// ProcessSerialNumber layout (two UInt32s), declared locally to avoid SDK availability issues.
struct PSN {
    var high: UInt32 = 0
    var low: UInt32 = 0
}

enum SPI {
    typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias MainConnection = @convention(c) () -> UInt32
    typealias CaptureWindows = @convention(c) (UInt32, UnsafePointer<UInt32>, UInt32, UInt32) -> UnsafeMutableRawPointer?
    typealias GetPSN = @convention(c) (pid_t, UnsafeMutableRawPointer) -> OSStatus
    typealias SetFrontProcess = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> CGError
    typealias PostEventRecord = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> CGError

    /// macOS major versions where these private signatures are known to work (AltTab and
    /// DockDoor ship them). On any other version nothing private is called, so a changed ABI
    /// can't corrupt memory in this highly privileged process. Widen after testing a new release.
    static let knownVersions = 14...27
    static let enabled = knownVersions.contains(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)

    static let skyLight = enabled ? dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) : nil
    static let anyImage = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT

    static func load<T>(_ handle: UnsafeMutableRawPointer?, _ names: String...) -> T? {
        guard enabled, let handle else { return nil }
        for name in names {
            if let symbol = dlsym(handle, name) { return unsafeBitCast(symbol, to: T.self) }
        }
        return nil
    }

    static let axGetWindow: AXGetWindow? = load(anyImage, "_AXUIElementGetWindow")
    static let getPSN: GetPSN? = load(anyImage, "GetProcessForPID")
    static let mainConnection: MainConnection? = load(skyLight, "SLSMainConnectionID", "CGSMainConnectionID")
    static let captureWindows: CaptureWindows? = load(skyLight, "SLSHWCaptureWindowList", "CGSHWCaptureWindowList")
    static let setFrontProcess: SetFrontProcess? = load(skyLight, "_SLPSSetFrontProcessWithOptions")
    static let postEventRecord: PostEventRecord? = load(skyLight, "SLPSPostEventRecordTo")
}
