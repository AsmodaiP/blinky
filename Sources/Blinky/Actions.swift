import AppKit

/// What to do at the start and end of a break: music, sounds, Shortcuts.
@MainActor
enum BreakActions {
    private typealias SendFn = @convention(c) (UInt32, CFDictionary?) -> Bool
    private static let send: SendFn? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let sym = dlsym(h, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(sym, to: SendFn.self)
    }()
    private static var pausedMusic = false

    static func breakStarted() {
        play(Prefs.string(K.startSound))
        pausedMusic = false
        // MediaRemote sends the command to the system's "now playing" app, which is not always the app
        // that is actually producing sound (a silent app may start playing instead).
        // So send "play" at the end only if something actually went silent after "pause".
        let before = Set(Detector.audioPlayers().map(\.bundleID))
        if Prefs.bool(K.pauseMusic), !before.isEmpty, send?(1, nil) == true {   // kMRPause
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let after = Set(Detector.audioPlayers().map(\.bundleID))
                pausedMusic = !before.subtracting(after).isEmpty
            }
        }
        runShortcut(Prefs.string(K.shortcutStart))
    }

    static func breakEnded(completed: Bool) {
        if completed { play(Prefs.string(K.endSound)) }
        if pausedMusic {
            pausedMusic = false
            _ = send?(0, nil)                      // kMRPlay
        }
        runShortcut(Prefs.string(K.shortcutEnd))
    }

    static func play(_ name: String) {
        guard !name.isEmpty else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }

    static let systemSounds: [String] = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? []
        return files.map { ($0 as NSString).deletingPathExtension }.sorted()
    }()

    static func runShortcut(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = ["run", n]
        try? p.run()
    }
}
