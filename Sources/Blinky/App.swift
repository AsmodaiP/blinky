import AppKit
import SwiftUI

@main
@MainActor
struct BlinkyMain {
    static func main() {
        Prefs.migrateLegacyDomain()
        Prefs.register()
        if CommandLine.arguments.contains("--dump") {
            Detector.dump()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), i + 1 < CommandLine.arguments.count {
            DebugRender.icon(to: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
            DebugRender.run(dir: CommandLine.arguments[i + 1])
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var lastSymbol = ""
    private let scheduler = Scheduler.shared

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        scheduler.onUpdate = { [weak self] in self?.refreshButton() }
        scheduler.start()
        Hotkeys.apply()
        if CommandLine.arguments.contains("--settings") { openSettings() }
    }

    /// blinky://break, blinky://pause?min=30, blinky://resume, blinky://snooze?min=15,
    /// blinky://quiet/on|off, blinky://meeting/on|off — for Shortcuts and Focus automations.
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { handle(u) }
    }

    private func handle(_ u: URL) {
        let arg = u.pathComponents.dropFirst().first
        let min = URLComponents(url: u, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "min" }?.value.flatMap(Int.init)
        switch u.host {
        case "break": scheduler.breakNow()
        case "pause": scheduler.pauseFor(minutes: min ?? 30)
        case "resume": scheduler.resume()
        case "snooze": scheduler.snooze(minutes: min ?? 15)
        case "quiet": scheduler.setQuiet(arg != "off")
        case "stand": scheduler.confirmPosture(standing: true)
        case "sit": scheduler.confirmPosture(standing: false)
        case "meeting":
            if (arg != "off") != scheduler.isManualMeeting { scheduler.toggleManualMeeting() }
        default: NSSound.beep()
        }
    }

    private func refreshButton() {
        guard let b = item.button else { return }
        let symbol: String
        let title: String
        switch scheduler.display {
        case .countdown(let s):
            symbol = "eye"
            title = mmss(s)
        case .busy:
            symbol = "pause.circle"
            title = ""
        case .paused:
            symbol = "eye.slash"
            title = ""
        case .onBreak(let s):
            symbol = "eye.fill"
            title = mmss(s)
        }
        // Update only what changed: recreating the image every second costs noticeable CPU.
        if symbol != lastSymbol {
            lastSymbol = symbol
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Blinky")
        }
        let t = title.isEmpty ? "" : " " + title
        if t != b.title { b.title = t }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status: String
        switch scheduler.display {
        case .countdown(let s): status = L("Next break in %@", mmss(s))
        case .busy(let why): status = L("Postponed — %@", why)
        case .paused(let why): status = why
        case .onBreak(let s): status = L("Break — %@ left", mmss(s))
        }
        menu.addItem(disabled(status))
        if Prefs.bool(K.statsEnabled) {
            menu.addItem(disabled(L("Today: %d done · %d skipped · %d snoozed",
                                    Stats.get(.done), Stats.get(.skipped), Stats.get(.snoozed))))
        }
        menu.addItem(.separator())

        if let e = scheduler.snapshot.calendarEvent { menu.addItem(disabled("📅 \(e)")) }
        if Posture.enabled {
            let left = max(Posture.secondsUntilDue, 0) / 60
            menu.addItem(disabled(L("%@ · switch in %d min", Posture.statusText, left)))
            menu.addItem(action(L(Posture.standing ? "I sat down" : "I stood up"), #selector(togglePosture)))
        }
        menu.addItem(.separator())

        menu.addItem(action(L("Break now"), #selector(breakNow), key: "b"))
        let snooze = action(L("Snooze 15 minutes"), #selector(snooze15))
        snooze.isEnabled = scheduler.canSnooze
        menu.addItem(snooze)
        menu.addItem(action(L("Skip next break"), #selector(skipNext)))
        let meeting = action(L("I’m in a call"), #selector(toggleMeeting))
        meeting.state = scheduler.isManualMeeting ? .on : .off
        menu.addItem(meeting)
        let quiet = action(L("Quiet mode"), #selector(toggleQuiet))
        quiet.state = Prefs.bool(K.quietMode) ? .on : .off
        menu.addItem(quiet)
        if scheduler.manualPauseUntil != nil {
            menu.addItem(action(L("Resume"), #selector(resume)))
        } else {
            let pause = NSMenuItem(title: L("Pause"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (t, m) in [(L("30 minutes"), 30), (L("1 hour"), 60), (L("2 hours"), 120)] {
                let i = action(t, #selector(pauseFor(_:)))
                i.tag = m
                sub.addItem(i)
            }
            let tomorrow = action(L("Until tomorrow"), #selector(pauseFor(_:)))
            tomorrow.tag = -1
            sub.addItem(tomorrow)
            pause.submenu = sub
            menu.addItem(pause)
        }
        menu.addItem(.separator())
        if Prefs.bool(K.blinkEnabled) { menu.addItem(action(L("Show blink reminder"), #selector(testBlink))) }
        if Prefs.bool(K.postureEnabled) { menu.addItem(action(L("Show posture reminder"), #selector(testPosture))) }
        menu.addItem(.separator())
        menu.addItem(action(L("Settings…"), #selector(openSettings), key: ","))
        menu.addItem(action(L("Quit Blinky"), #selector(quit), key: "q"))
    }

    private func disabled(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ t: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func breakNow() { scheduler.breakNow() }
    @objc private func skipNext() { scheduler.skipBreak() }
    @objc private func snooze15() { scheduler.snooze(minutes: 15) }
    @objc private func toggleMeeting() { scheduler.toggleManualMeeting() }
    @objc private func toggleQuiet() { scheduler.toggleQuiet() }
    @objc private func togglePosture() { scheduler.togglePosture() }
    @objc private func resume() { scheduler.resume() }
    @objc private func pauseFor(_ sender: NSMenuItem) { scheduler.pauseFor(minutes: sender.tag < 0 ? nil : sender.tag) }
    @objc private func testBlink() { scheduler.testBlink() }
    @objc private func testPosture() { scheduler.testPosture() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = L("Blinky Settings")
            w.contentViewController = NSHostingController(rootView: SettingsView(scheduler: scheduler))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
