import AppKit
import CoreAudio
import CoreMediaIO
import Intents
import IOKit.pwr_mgt

/// An activity that causes a break to be postponed.
struct Activity: Equatable {
    enum Kind {
        case meeting, screen, video, game, focus
        var title: String {
            switch self {
            case .meeting: L("Call")
            case .screen: L("Screen sharing")
            case .video: L("Video")
            case .game: L("Game")
            case .focus: L("Focus app")
            }
        }
    }
    let kind: Kind
    let app: String
    var label: String { app.isEmpty ? kind.title : "\(kind.title): \(app)" }
}

/// Snapshot of detector state (plus raw data for debugging in settings).
struct Snapshot {
    var activities: [Activity] = []
    var micUsers: [ProcOwner] = []       // everything recording the mic, including excluded apps
    var cameraOn = false
    var videoHolders: [ProcOwner] = []   // everything holding a display assertion
    var screenWatched = false
    var calendarEvent: String?
}

/// Process owner: the app whose bundle contains the executable.
struct ProcOwner: Hashable {
    let pid: pid_t
    let bundleID: String     // owner app's bundle ID or the process name
    let name: String
}

enum ProcInfo {
    static func path(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    private typealias RespFn = @convention(c) (pid_t) -> pid_t
    private static let respFn: RespFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: RespFn.self)
    }()

    /// The process macOS attributes this one to (Safari's WebKit.GPU, Chrome helpers, etc.).
    static func responsible(_ pid: pid_t) -> pid_t {
        guard let f = respFn else { return pid }
        let r = f(pid)
        return r > 0 ? r : pid
    }

    /// Map helpers (Chrome Helper, WebKit, etc.) to the outer .app.
    nonisolated(unsafe) private static var cache: [pid_t: (String, ProcOwner)] = [:]

    /// Cache keyed by pid + path (guards against pid reuse).
    static func owner(_ rawPid: pid_t, fallbackBundleID: String? = nil) -> ProcOwner {
        let p = path(rawPid) ?? ""
        if let (cp, o) = cache[rawPid], cp == p { return o }
        let o = resolveOwner(rawPid, fallbackBundleID: fallbackBundleID)
        if cache.count > 500 { cache.removeAll() }
        cache[rawPid] = (p, o)
        return o
    }

    private static func resolveOwner(_ rawPid: pid_t, fallbackBundleID: String? = nil) -> ProcOwner {
        // A process inside an .app (including a game launched by Steam) owns itself;
        // XPC services and daemons (Safari's WebKit.GPU) map to the responsible app.
        let inApp = path(rawPid)?.contains(".app/") ?? false
        let pid = inApp ? rawPid : responsible(rawPid)
        if let p = path(pid), let r = p.range(of: ".app/") {
            let appPath = String(p[..<r.lowerBound]) + ".app"
            let b = Bundle(path: appPath)
            let id = b?.bundleIdentifier ?? fallbackBundleID ?? appPath
            let name = FileManager.default.displayName(atPath: appPath)
                .replacingOccurrences(of: ".app", with: "")
            return ProcOwner(pid: pid, bundleID: id, name: name)
        }
        if let app = NSRunningApplication(processIdentifier: pid), let id = app.bundleIdentifier {
            return ProcOwner(pid: pid, bundleID: id, name: app.localizedName ?? id)
        }
        let proc = path(pid).map { ($0 as NSString).lastPathComponent } ?? "pid \(pid)"
        let id = (fallbackBundleID?.isEmpty == false) ? fallbackBundleID! : proc
        return ProcOwner(pid: pid, bundleID: id, name: proc)
    }

    static func appName(bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}

enum Idle {
    static var seconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

enum Detector {
    // MARK: Microphone (per process, macOS 14.4+)

    private static func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ def: T) -> T {
        var a = addr(sel)
        var v = def
        var size = UInt32(MemoryLayout<T>.size)
        let st = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0) }
        return st == noErr ? v : def
    }

    private static func stringProp(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = addr(sel)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ref) == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }

    static func micUsers() -> [ProcOwner] { audioProcesses(kAudioProcessPropertyIsRunningInput) }

    /// Apps (.app) currently producing audio — used to pause music.
    static func audioPlayers() -> [ProcOwner] {
        audioProcesses(kAudioProcessPropertyIsRunningOutput).filter { $0.bundleID.contains(".") && !$0.bundleID.hasPrefix("com.apple.") || $0.bundleID == "com.apple.Music" }
    }

    private static func audioProcesses(_ sel: AudioObjectPropertySelector) -> [ProcOwner] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }

        var out: [ProcOwner] = []
        for id in ids where prop(id, sel, UInt32(0)) != 0 {
            let pid: pid_t = prop(id, kAudioProcessPropertyPID, pid_t(-1))
            guard pid > 0, pid != getpid() else { continue }
            out.append(ProcInfo.owner(pid, fallbackBundleID: stringProp(id, kAudioProcessPropertyBundleID)))
        }
        return Array(Set(out))
    }

    // MARK: Camera

    static func cameraInUse() -> Bool {
        let sys = CMIOObjectID(kCMIOObjectSystemObject)
        var a = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == 0, size > 0 else { return false }
        var devs = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.stride)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(sys, &a, 0, nil, size, &used, &devs) == 0 else { return false }

        for dev in devs {
            var da = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var v: UInt32 = 0
            var u: UInt32 = 0
            if CMIOObjectGetPropertyData(dev, &da, 0, nil, UInt32(MemoryLayout<UInt32>.size), &u, &v) == 0, v != 0 {
                return true
            }
        }
        return false
    }

    // MARK: Video — who prevents the display from sleeping (players and browsers playing video do this)

    static func displayAssertionHolders() -> [ProcOwner] {
        var ref: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&ref) == kIOReturnSuccess, let ref else { return [] }
        let dict = ref.takeRetainedValue() as NSDictionary
        var out: Set<ProcOwner> = []
        for (k, v) in dict {
            guard let pid = (k as? NSNumber)?.int32Value, pid != getpid(),
                  let list = v as? [[String: Any]] else { continue }
            let holdsDisplay = list.contains {
                let t = $0["AssertType"] as? String ?? ""
                return t == "PreventUserIdleDisplaySleep" || t == "NoDisplaySleepAssertion"
            }
            if holdsDisplay { out.insert(ProcInfo.owner(pid)) }
        }
        return Array(out)
    }

    // MARK: Screen sharing / recording (SkyLight: whether the screen currently has an "observer")

    private typealias WatcherFn = @convention(c) () -> Bool
    private static let watcherFn: WatcherFn? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let sym = dlsym(h, "SLSIsScreenWatcherPresent") else { return nil }
        return unsafeBitCast(sym, to: WatcherFn.self)
    }()

    static func screenWatched() -> Bool { watcherFn?() ?? false }

    // MARK: Focus mode (if macOS allows) or manual quiet mode

    static var focusAuthorized: Bool { INFocusStatusCenter.default.authorizationStatus == .authorized }
    static var systemFocusOn: Bool { focusAuthorized && INFocusStatusCenter.default.focusStatus.isFocused == true }
    static var quiet: Bool { Prefs.bool(K.quietMode) || (Prefs.bool(K.focusGentle) && systemFocusOn) }

    static func requestFocusAccess() {
        INFocusStatusCenter.default.requestAuthorization { _ in }
    }

    // MARK: Full-screen window

    static func hasFullscreenWindow(pid: pid_t) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let sizes = NSScreen.screens.map { $0.frame.size }
        for w in info {
            guard (w[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            if sizes.contains(where: { abs($0.width - r.width) < 2 && abs($0.height - r.height) < 2 }) { return true }
        }
        return false
    }

    static func isGame(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL, let cat = Bundle(url: url)?.infoDictionary?["LSApplicationCategoryType"] as? String else { return false }
        return cat.contains("games")
    }

    // MARK: Summary

    static func snapshot() -> Snapshot {
        var s = Snapshot()
        let front = NSWorkspace.shared.frontmostApplication
        let frontID = front?.bundleIdentifier

        // Call: microphone (minus exclusions) or camera
        s.micUsers = micUsers()
        if Prefs.bool(K.detectMic) {
            let excluded = Set(Prefs.lines(K.micExcluded))
            if let m = s.micUsers.first(where: { !excluded.contains($0.bundleID) && !excluded.contains($0.name) }) {
                s.activities.append(Activity(kind: .meeting, app: m.name))
            }
        }
        s.cameraOn = cameraInUse()
        if Prefs.bool(K.detectCamera), s.cameraOn, !s.activities.contains(where: { $0.kind == .meeting }) {
            s.activities.append(Activity(kind: .meeting, app: L("camera")))
        }

        // Screen sharing
        s.screenWatched = screenWatched()
        if Prefs.bool(K.detectScreenShare), s.screenWatched {
            s.activities.append(Activity(kind: .screen, app: ""))
        }

        // Video
        s.videoHolders = displayAssertionHolders()
        if Prefs.bool(K.detectVideo) {
            let excluded = Set(Prefs.lines(K.videoExcluded))
            let frontOnly = Prefs.bool(K.videoFrontmostOnly)
            if let v = s.videoHolders.first(where: {
                !excluded.contains($0.bundleID) && !excluded.contains($0.name) && (!frontOnly || $0.bundleID == frontID)
            }) {
                s.activities.append(Activity(kind: .video, app: v.name))
            }
        }

        // Full-screen game
        if Prefs.bool(K.detectGames), let front, isGame(front), hasFullscreenWindow(pid: front.processIdentifier) {
            s.activities.append(Activity(kind: .game, app: front.localizedName ?? ""))
        }

        // Deep-work apps
        for line in Prefs.lines(K.focusApps) {
            let parts = line.split(separator: "|").map(String.init)
            guard let id = parts.first else { continue }
            let mode = parts.count > 1 ? parts[1] : "fg"
            let hit: Bool
            switch mode {
            case "open":
                hit = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
            case "fgfs":
                hit = frontID == id && front.map { hasFullscreenWindow(pid: $0.processIdentifier) } == true
            default:
                hit = frontID == id
            }
            if hit { s.activities.append(Activity(kind: .focus, app: ProcInfo.appName(bundleID: id))); break }
        }
        // Smart pause module off: keep the raw data for diagnostics, but nothing holds breaks.
        if !Prefs.bool(K.smartPause) { s.activities = [] }
        return s
    }

    /// `Blinky --dump`: print what the detectors see right now.
    static func dump() {
        Prefs.register()
        let s = snapshot()
        print("Microphone:", s.micUsers.map { "\($0.name) [\($0.bundleID)]" })
        print("Camera:", s.cameraOn)
        print("Keeping display awake:", s.videoHolders.map { "\($0.name) [\($0.bundleID)]" })
        print("Frontmost:", NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")
        print("Idle, s:", Int(Idle.seconds))
        print("Screen watched:", s.screenWatched)
        print("Focus: authorized", focusAuthorized, "on", systemFocusOn)
        print("Playing audio:", audioPlayers().map(\.name))
        print("Activities:", s.activities.map(\.label))
    }
}
