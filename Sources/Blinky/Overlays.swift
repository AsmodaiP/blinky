import AppKit
import SwiftUI

// MARK: - Base windows

final class OverlayPanel: NSPanel {
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
}

/// Buttons in a non-activating panel must respond to the first click.
final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
func makePanel(frame: NSRect, clickThrough: Bool, key: Bool = false) -> OverlayPanel {
    let p = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.allowKey = key
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.level = .screenSaver
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    p.ignoresMouseEvents = clickThrough
    p.isReleasedWhenClosed = false
    p.hidesOnDeactivate = false
    return p
}

@MainActor
func screenUnderMouse() -> NSScreen {
    let m = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
}

@MainActor
func fade(_ w: NSWindow, to alpha: CGFloat, duration: TimeInterval, then: (() -> Void)? = nil) {
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = duration
        w.animator().alphaValue = alpha
    }, completionHandler: { MainActor.assumeIsolated { then?() } })
}

func mmss(_ s: Int) -> String { String(format: "%d:%02d", max(s, 0) / 60, max(s, 0) % 60) }

// MARK: - Models

final class BreakModel: ObservableObject {
    @Published var remaining = 0
    @Published var total = 1
    @Published var isLong = false
    @Published var canSkip = true
    @Published var canSnooze = true
    @Published var exercises = false
    @Published var posture: PostureAction?
    @Published var postureConfirmed = false
    @Published var standingNow = false
    @Published var deskEnabled = false
    @Published var exerciseText = ""
    var elapsed: Int { total - remaining }
}

/// Break screen background.
@MainActor
enum BreakBackground {
    static func image(for screen: NSScreen) -> NSImage? {
        switch Prefs.string(K.breakBackground) {
        case "wallpaper":
            return NSWorkspace.shared.desktopImageURL(for: screen).flatMap { NSImage(contentsOf: $0) }
        case "image":
            let p = Prefs.string(K.breakImagePath)
            return p.isEmpty ? nil : NSImage(contentsOfFile: p)
        default:
            return nil
        }
    }
}

final class HeadsUpModel: ObservableObject {
    @Published var remaining = 0
    @Published var posture: PostureAction?
    @Published var canSnooze = true
    @Published var canSkip = true
}

// MARK: - Controller for all overlays

@MainActor
enum Overlays {
    static let breakModel = BreakModel()
    static let headsUpModel = HeadsUpModel()
    private static var breakWindows: [NSWindow] = []
    private static var headsUp: NSWindow?
    private static var reminder: NSWindow?
    private static var toastWindow: NSWindow?
    private static var keyMonitor: Any?
    private static var appBeforeBreak: NSRunningApplication?

    // Full-screen break on all monitors

    static func showBreak(duration: Int, isLong: Bool, posture: PostureAction?, gentle: Bool, canSkip: Bool, canSnooze: Bool) {
        hideHeadsUp()
        hideReminder()
        breakModel.total = max(duration, 1)
        breakModel.remaining = duration
        breakModel.isLong = isLong
        breakModel.canSkip = canSkip
        breakModel.canSnooze = canSnooze
        breakModel.exercises = isLong && posture == nil && Prefs.bool(K.eyeExercises)
        breakModel.posture = posture
        breakModel.postureConfirmed = false
        breakModel.standingNow = Posture.standing
        breakModel.deskEnabled = Posture.enabled
        breakModel.exerciseText = posture.map { Posture.exercise(for: $0) } ?? ""
        if gentle { return showGentleBreak() }

        let front = NSWorkspace.shared.frontmostApplication
        appBeforeBreak = front?.processIdentifier == getpid() ? nil : front
        let mouseScreen = screenUnderMouse()
        for screen in NSScreen.screens {
            let w = makePanel(frame: screen.frame, clickThrough: false, key: screen == mouseScreen)
            let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
            blur.material = .fullScreenUI
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.autoresizingMask = [.width, .height]
            let host = FirstMouseHostingView(rootView: BreakView(model: breakModel, showControls: screen == mouseScreen,
                                                                 background: BreakBackground.image(for: screen)))
            host.frame = blur.bounds
            host.autoresizingMask = [.width, .height]
            blur.addSubview(host)
            w.contentView = blur
            w.alphaValue = 0
            w.setFrame(screen.frame, display: true)
            w.orderFrontRegardless()
            if screen == mouseScreen { w.makeKey() }
            fade(w, to: 1, duration: 0.6)
            breakWindows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53, breakModel.canSkip { Scheduler.shared.skipBreak(); return nil }   // Esc
            return e
        }
    }

    /// Soft break: a corner card plus an edge glow; does not interfere with work.
    private static func showGentleBreak() {
        appBeforeBreak = nil
        let screen = screenUnderMouse()
        let size = NSSize(width: 380, height: 168)
        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 12, width: size.width, height: size.height)
        let w = makePanel(frame: frame, clickThrough: false)
        w.level = .statusBar
        w.hasShadow = true
        w.contentView = FirstMouseHostingView(rootView: GentleBreakView(model: breakModel))
        w.alphaValue = 0
        w.orderFrontRegardless()
        fade(w, to: 1, duration: 0.3)
        breakWindows.append(w)
        show(reminder: AnyView(EdgeGlowView()), frame: screen.frame, seconds: 1.8)
    }

    static func hideBreak() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        let ws = breakWindows
        breakWindows = []
        for w in ws { fade(w, to: 0, duration: 0.5) { w.orderOut(nil) } }
        // Return focus to the app the user was working in (the settings window is not hidden).
        appBeforeBreak?.activate()
        appBeforeBreak = nil
    }

    // Warning before a break (top-right corner)

    static var headsUpVisible: Bool { headsUp != nil }

    static func showHeadsUp(remaining: Int, posture: PostureAction? = nil, canSnooze: Bool, canSkip: Bool) {
        headsUpModel.remaining = remaining
        headsUpModel.posture = posture
        headsUpModel.canSnooze = canSnooze
        headsUpModel.canSkip = canSkip
        guard headsUp == nil else { return }
        let size = NSSize(width: 340, height: 88)
        let vf = screenUnderMouse().visibleFrame
        let frame = NSRect(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 12, width: size.width, height: size.height)
        let w = makePanel(frame: frame, clickThrough: false)
        w.level = .statusBar
        w.hasShadow = true
        w.contentView = FirstMouseHostingView(rootView: HeadsUpView(model: headsUpModel))
        w.alphaValue = 0
        w.orderFrontRegardless()
        fade(w, to: 1, duration: 0.3)
        headsUp = w
    }

    static func hideHeadsUp() {
        guard let w = headsUp else { return }
        headsUp = nil
        fade(w, to: 0, duration: 0.25) { w.orderOut(nil) }
    }

    // Micro-reminders: blinking and posture (clicks pass through them)

    static func showBlink(quiet: Bool = false) {
        if quiet || Prefs.string(K.blinkStyle) == "edge" {
            let screen = screenUnderMouse()
            show(reminder: AnyView(EdgeGlowView()), frame: screen.frame, seconds: 1.8)
        } else {
            show(reminder: AnyView(BlinkView()), size: NSSize(width: 220, height: 170), seconds: 2.8)
        }
    }

    static func showPosture() {
        show(reminder: AnyView(PostureView()), size: NSSize(width: 280, height: 170), seconds: 4)
    }

    private static func show(reminder view: AnyView, size: NSSize, seconds: Double) {
        let f = screenUnderMouse().frame
        let frame = NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height)
        show(reminder: view, frame: frame, seconds: seconds)
    }

    private static func show(reminder view: AnyView, frame: NSRect, seconds: Double) {
        hideReminder()
        let w = makePanel(frame: frame, clickThrough: true)
        w.contentView = NSHostingView(rootView: view)
        w.alphaValue = 0
        w.orderFrontRegardless()
        reminder = w
        fade(w, to: 1, duration: 0.25)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard reminder === w else { return }
            hideReminder()
        }
    }

    static func hideReminder() {
        guard let w = reminder else { return }
        reminder = nil
        fade(w, to: 0, duration: 0.35) { w.orderOut(nil) }
    }

    // Toast: "break can wait"

    static func toast(_ title: String, _ subtitle: String) {
        toastWindow?.orderOut(nil)
        let size = NSSize(width: 320, height: 64)
        let vf = screenUnderMouse().visibleFrame
        let frame = NSRect(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 12, width: size.width, height: size.height)
        let w = makePanel(frame: frame, clickThrough: true)
        w.level = .statusBar
        w.contentView = NSHostingView(rootView: ToastView(title: title, subtitle: subtitle))
        w.alphaValue = 0
        w.orderFrontRegardless()
        toastWindow = w
        fade(w, to: 1, duration: 0.25)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard toastWindow === w else { return }
            toastWindow = nil
            fade(w, to: 0, duration: 0.4) { w.orderOut(nil) }
        }
    }
}

// MARK: - Views

struct BreakView: View {
    @ObservedObject var model: BreakModel
    let showControls: Bool
    var background: NSImage? = nil

    var progress: Double { 1 - Double(model.remaining) / Double(model.total) }
    var exercising: Bool { model.exercises && model.elapsed < EyeExerciseView.duration }

    var body: some View {
        ZStack {
            if let background {
                GeometryReader { g in
                    Image(nsImage: background).resizable().scaledToFill()
                        .frame(width: g.size.width, height: g.size.height).clipped()
                        .blur(radius: 18)
                }
                .ignoresSafeArea()
                Color.black.opacity(0.45).ignoresSafeArea()
            } else {
                LinearGradient(colors: [Color(red: 0.05, green: 0.09, blue: 0.16).opacity(0.78),
                                        Color(red: 0.03, green: 0.18, blue: 0.20).opacity(0.78)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            }
            VStack(spacing: 26) {
                if let p = model.posture {
                    Image(systemName: p == .stand ? "figure.walk" : "chair.lounge")
                        .font(.system(size: 54, weight: .light))
                    Text(p == .stand ? "Stand up and move" : "Sit down — but stretch first")
                        .font(.system(size: 38, weight: .semibold))
                    Text(model.exerciseText)
                        .font(.system(size: 21))
                        .opacity(0.85)
                } else if exercising {
                    EyeExerciseView(elapsed: model.elapsed)
                } else {
                    Image(systemName: model.isLong ? "figure.walk" : "eye")
                        .font(.system(size: 54, weight: .light))
                    Text(model.isLong ? "Long break — get up and stretch" : "Eye break")
                        .font(.system(size: 38, weight: .semibold))
                    Text(Prefs.string(K.breakMessage).ifEmpty(L("Look at something about 20 feet (6 m) away")))
                        .font(.system(size: 19))
                        .opacity(0.8)
                }
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 6)
                    Circle().trim(from: 0, to: progress)
                        .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: progress)
                    Text(mmss(model.remaining))
                        .font(.system(size: 34, weight: .medium).monospacedDigit())
                }
                .frame(width: 150, height: 150)
                if showControls {
                    PostureControls(model: model, big: true)
                    HStack(spacing: 14) {
                        if model.canSnooze {
                            Button("+1 min") { Scheduler.shared.snooze(minutes: 1) }
                            Button("+5 min") { Scheduler.shared.snooze(minutes: 5) }
                        }
                        if model.canSkip {
                            Button("Skip (Esc)") { Scheduler.shared.skipBreak() }
                        }
                    }
                    .buttonStyle(GlassButton())
                }
            }
            .foregroundStyle(.white)
        }
    }
}

struct GlassButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.3 : 0.16)))
            .foregroundStyle(.white)
    }
}

struct HeadsUpView: View {
    @ObservedObject var model: HeadsUpModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: model.posture == nil ? "eye" : "figure.stand")
                Text(model.posture == .stand ? "Stand up and move in \(model.remaining) s"
                     : model.posture == .sit ? "Sit down and stretch in \(model.remaining) s"
                     : "Break in \(model.remaining) s")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                Spacer()
            }
            HStack(spacing: 6) {
                Button("Now") { Scheduler.shared.breakNow() }
                if model.canSnooze {
                    Button("+1") { Scheduler.shared.snooze(minutes: 1) }
                    Button("+5") { Scheduler.shared.snooze(minutes: 5) }
                    Button("+15") { Scheduler.shared.snooze(minutes: 15) }
                }
                if model.canSkip {
                    Button("Skip") { Scheduler.shared.skipBreak() }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
    }
}

struct ToastView: View {
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle").font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Almond-shaped eye.
struct EyeShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.midY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.5))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.midY), control: CGPoint(x: r.midX, y: r.maxY + r.height * 0.5))
        p.closeSubpath()
        return p
    }
}

struct BlinkView: View {
    @State private var lid: CGFloat = 1

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                EyeShape().fill(.white)
                Circle().fill(Color(red: 0.22, green: 0.52, blue: 0.85)).frame(width: 36, height: 36)
                Circle().fill(.black).frame(width: 15, height: 15)
                Circle().fill(.white).frame(width: 5, height: 5).offset(x: 5, y: -5)
            }
            .frame(width: 112, height: 58)
            .mask(EyeShape().scaleEffect(x: 1, y: lid))
            .overlay(EyeShape().stroke(.white, lineWidth: 2.5).scaleEffect(x: 1, y: max(lid, 0.04)))
            Text("Blink").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 26).fill(.black.opacity(0.55)))
        .task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            for _ in 0..<2 {
                withAnimation(.easeIn(duration: 0.11)) { lid = 0.04 }
                try? await Task.sleep(nanoseconds: 160_000_000)
                withAnimation(.easeOut(duration: 0.2)) { lid = 1 }
                try? await Task.sleep(nanoseconds: 520_000_000)
            }
        }
    }
}

/// Quiet blink mode: a soft glow along the screen edge, twice.
struct EdgeGlowView: View {
    @State private var on = false
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(LinearGradient(colors: [.cyan, .blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 10)
            .blur(radius: 8)
            .opacity(on ? 0.85 : 0)
            .ignoresSafeArea()
            .task {
                for _ in 0..<2 {
                    withAnimation(.easeInOut(duration: 0.3)) { on = true }
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    withAnimation(.easeInOut(duration: 0.4)) { on = false }
                    try? await Task.sleep(nanoseconds: 450_000_000)
                }
            }
    }
}

struct PostureView: View {
    @State private var up = false
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "figure.stand")
                .font(.system(size: 46))
                .scaleEffect(y: up ? 1.0 : 0.88, anchor: .bottom)
                .animation(.spring(response: 0.5, dampingFraction: 0.5).delay(0.3), value: up)
            Text("Straighten your back").font(.system(size: 17, weight: .semibold))
            Text("Shoulders down, screen at eye level").font(.system(size: 12)).opacity(0.75)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 26).fill(.black.opacity(0.55)))
        .onAppear { up = true }
    }
}


/// Soft break in a screen corner.
struct GentleBreakView: View {
    @ObservedObject var model: BreakModel
    var progress: Double { 1 - Double(model.remaining) / Double(model.total) }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(.primary.opacity(0.15), lineWidth: 4)
                Circle().trim(from: 0, to: progress)
                    .stroke(.cyan, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
                Text(mmss(model.remaining)).font(.system(size: 14, weight: .medium).monospacedDigit())
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.posture == .stand ? "Time to stand up" : model.posture == .sit ? "Time to sit down"
                     : model.isLong ? "Long break" : "Eye break").font(.system(size: 14, weight: .semibold))
                Text(model.posture == .stand ? "Stand up: \(model.exerciseText)"
                     : model.posture == .sit ? "Sit down: \(model.exerciseText)"
                     : "Look away from the screen")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                PostureControls(model: model, big: false)
                HStack(spacing: 6) {
                    if model.canSnooze { Button("+5") { Scheduler.shared.snooze(minutes: 5) } }
                    if model.canSkip { Button("Skip") { Scheduler.shared.skipBreak() } }
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.12)))
    }
}

/// Eye exercises: a dot moves along shapes; follow it with your eyes only.
struct EyeExerciseView: View {
    static let duration = 60
    let elapsed: Int

    private static let phases: [(String, (Double) -> CGPoint)] = [
        ("Follow the dot around the circle", { t in CGPoint(x: cos(t), y: sin(t)) }),
        ("Now a figure eight", { t in CGPoint(x: sin(t), y: sin(2 * t) / 2) }),
        ("Left — right", { t in CGPoint(x: sin(t * 1.4), y: 0) }),
        ("Up — down", { t in CGPoint(x: 0, y: sin(t * 1.4)) }),
    ]

    var body: some View {
        let phase = min(elapsed / (Self.duration / Self.phases.count), Self.phases.count - 1)
        VStack(spacing: 18) {
            Text(L(Self.phases[phase].0)).font(.system(size: 32, weight: .semibold))
            Text("Keep your head still, move only your eyes").font(.system(size: 17)).opacity(0.75)
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * 1.3
                let p = Self.phases[phase].1(t)
                Canvas { gc, size in
                    let c = CGPoint(x: size.width / 2 + p.x * (size.width / 2 - 20),
                                    y: size.height / 2 + p.y * (size.height / 2 - 20))
                    gc.fill(Path(ellipseIn: CGRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)), with: .color(.cyan))
                    gc.fill(Path(ellipseIn: CGRect(x: c.x - 26, y: c.y - 26, width: 52, height: 52)), with: .color(.cyan.opacity(0.18)))
                }
            }
            .frame(width: 560, height: 260)
        }
    }
}


/// Posture buttons during a break: confirm the change ("Stood up ✓") or a sitting/standing toggle.
struct PostureControls: View {
    @ObservedObject var model: BreakModel
    let big: Bool

    var body: some View {
        if !model.deskEnabled {
            EmptyView()
        } else if let p = model.posture, !model.postureConfirmed {
            HStack(spacing: 10) {
                Button(p == .stand ? "I stood up ✓" : "I sat down ✓") { Scheduler.shared.confirmPosture(standing: p == .stand) }
                    .modifier(PrimaryStyle(big: big))
                Button(p == .stand ? "Keep sitting" : "Keep standing") { Scheduler.shared.keepPosture() }
                    .modifier(SecondaryStyle(big: big))
            }
        } else if model.posture != nil {
            Text(model.standingNow ? "✓ Standing. Nice work" : "✓ Sitting. Nice work")
                .font(.system(size: big ? 17 : 12, weight: .medium))
                .foregroundStyle(big ? Color.white : Color.green)
        } else {
            HStack(spacing: 8) {
                Text("I’m now:").font(.system(size: big ? 14 : 11)).opacity(0.7)
                Picker("", selection: Binding(get: { model.standingNow },
                                              set: { Scheduler.shared.confirmPosture(standing: $0) })) {
                    Text("sitting").tag(false)
                    Text("standing").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(big ? .regular : .small)
            }
        }
    }
}

private struct PrimaryStyle: ViewModifier {
    let big: Bool
    func body(content: Content) -> some View {
        if big {
            content.buttonStyle(FilledGlassButton())
        } else {
            content.buttonStyle(.borderedProminent).controlSize(.small)
        }
    }
}

private struct SecondaryStyle: ViewModifier {
    let big: Bool
    func body(content: Content) -> some View {
        if big { content.buttonStyle(GlassButton()) } else { content.buttonStyle(.bordered).controlSize(.small) }
    }
}

struct FilledGlassButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .padding(.horizontal, 24).padding(.vertical, 11)
            .background(Capsule().fill(Color.teal.opacity(configuration.isPressed ? 0.7 : 0.9)))
            .foregroundStyle(.white)
    }
}
