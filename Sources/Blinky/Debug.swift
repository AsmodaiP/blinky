import AppKit
import SwiftUI

/// Debug: `Blinky --render <dir>` draws screens to PNG without showing windows.
@MainActor
enum DebugRender {
    /// `Blinky --render-icon <file.png>`: the 1024×1024 app icon.
    static func icon(to path: String) {
        let r = ImageRenderer(content: AppIconView().frame(width: 1024, height: 1024))
        r.scale = 1
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    static func run(dir: String) {
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bm = BreakModel()
        bm.total = 45; bm.remaining = 31
        let hm = HeadsUpModel()
        hm.remaining = 24
        save(BreakView(model: bm, showControls: true).frame(width: 1280, height: 800).background(Color.gray), url, "break")
        let lm = BreakModel()
        lm.total = 300; lm.remaining = 280; lm.isLong = true; lm.exercises = true
        save(BreakView(model: lm, showControls: true).frame(width: 1280, height: 800).background(Color.gray), url, "break-long")
        bm.deskEnabled = true
        save(GentleBreakView(model: bm).frame(width: 380, height: 168), url, "break-gentle")
        let pm = BreakModel()
        pm.total = 120; pm.remaining = 104; pm.deskEnabled = true; pm.posture = .stand
        pm.exerciseText = L("15 calf raises — a pump for your leg veins")
        save(BreakView(model: pm, showControls: true).frame(width: 1280, height: 800).background(Color.gray), url, "break-posture")
        save(GentleBreakView(model: pm).frame(width: 380, height: 168), url, "break-posture-gentle")
        appkit(StatsTab().frame(width: 560, height: 560), url, "tab-stats")
        appkit(ActionsTab().frame(width: 560, height: 700), url, "tab-actions")
        save(HeadsUpView(model: hm).frame(width: 340, height: 88), url, "headsup")
        save(BlinkView().frame(width: 220, height: 170), url, "blink")
        save(PostureView().frame(width: 280, height: 170), url, "posture")
        save(ToastView(title: L("Break will wait"), subtitle: L("Call") + ": zoom.us").frame(width: 320, height: 64), url, "toast")
        Scheduler.shared.refreshSnapshotForDebug()
        appkit(SettingsView(scheduler: Scheduler.shared), url, "settings")
        appkit(BreaksTab().frame(width: 560, height: 560), url, "tab-breaks")
        appkit(RemindersTab(scheduler: Scheduler.shared).frame(width: 560, height: 560), url, "tab-reminders")
        appkit(SmartPauseTab(scheduler: Scheduler.shared).frame(width: 560, height: 900), url, "tab-smart")
        appkit(ScheduleTab().frame(width: 560, height: 560), url, "tab-schedule")
    }

    private static func appkit<V: View>(_ v: V, _ dir: URL, _ name: String) {
        let host = NSHostingView(rootView: v)
        let size = host.fittingSize
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("fail", name); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
        print("ok", name, size)
    }

    private static func save<V: View>(_ v: V, _ dir: URL, _ name: String) {
        let r = ImageRenderer(content: v.environment(\.colorScheme, .dark))
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            print("fail", name); return
        }
        try? png.write(to: dir.appendingPathComponent(name + ".png"))
        print("ok", name)
    }
}


/// App icon: a white eye on a teal-to-indigo squircle, in the macOS icon grid (824 of 1024).
struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.10, green: 0.75, blue: 0.78), Color(red: 0.25, green: 0.30, blue: 0.85)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
            ZStack {
                EyeShape().fill(.white)
                Circle().fill(Color(red: 0.16, green: 0.45, blue: 0.85)).frame(width: 230, height: 230)
                Circle().fill(Color(red: 0.05, green: 0.08, blue: 0.20)).frame(width: 100, height: 100)
                Circle().fill(.white).frame(width: 38, height: 38).offset(x: 34, y: -34)
            }
            .frame(width: 600, height: 300)
            .mask(EyeShape())
        }
        .frame(width: 1024, height: 1024)
    }
}
