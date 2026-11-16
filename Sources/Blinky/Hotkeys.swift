import AppKit
import Carbon.HIToolbox

/// Global hotkeys ⌃⌥⌘ + letter (Carbon, no permission prompt).
@MainActor
enum Hotkeys {
    struct Def {
        let id: UInt32; let key: Int; let combo: String; let title: String; let action: @MainActor () -> Void
        var label: String { "\(combo) — \(L(title))" }
    }

    static let defs: [Def] = [
        Def(id: 1, key: kVK_ANSI_B, combo: "⌃⌥⌘B", title: "Break now") { Scheduler.shared.breakNow() },
        Def(id: 2, key: kVK_ANSI_P, combo: "⌃⌥⌘P", title: "Pause 30 min / resume") { Scheduler.shared.togglePause() },
        Def(id: 3, key: kVK_ANSI_S, combo: "⌃⌥⌘S", title: "Snooze 15 min") { Scheduler.shared.snooze(minutes: 15) },
        Def(id: 4, key: kVK_ANSI_M, combo: "⌃⌥⌘M", title: "“I’m in a call”") { Scheduler.shared.toggleManualMeeting() },
        Def(id: 5, key: kVK_ANSI_Q, combo: "⌃⌥⌘Q", title: "Quiet mode") { Scheduler.shared.toggleQuiet() },
        Def(id: 6, key: kVK_ANSI_U, combo: "⌃⌥⌘U", title: "Stood up / sat down") { Scheduler.shared.togglePosture() },
    ]

    private static var refs: [EventHotKeyRef] = []
    private static var handlerInstalled = false

    static func apply() {
        unregister()
        guard Prefs.bool(K.hotkeysEnabled) else { return }
        if !handlerInstalled {
            handlerInstalled = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { Hotkeys.defs.first { $0.id == id }?.action() }
                }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let mods = UInt32(cmdKey | controlKey | optionKey)
        for d in defs {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x424C_4E4B), id: d.id)   // 'BLNK'
            if RegisterEventHotKey(UInt32(d.key), mods, hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
        Prefs.d.set(refs.count, forKey: "debug.hotkeysRegistered")
    }

    private static func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }
}
