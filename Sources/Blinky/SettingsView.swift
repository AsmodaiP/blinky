import AppKit
import Charts
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let scheduler: Scheduler
    @AppStorage(K.blinkEnabled) var blink = true
    @AppStorage(K.postureEnabled) var posture = false
    @AppStorage(K.smartPause) var smartPause = true
    @AppStorage(K.statsEnabled) var stats = true

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            BreaksTab().tabItem { Label("Breaks", systemImage: "eye") }
            if blink || posture {
                RemindersTab(scheduler: scheduler).tabItem { Label("Reminders", systemImage: "sparkles") }
            }
            if smartPause {
                SmartPauseTab(scheduler: scheduler).tabItem { Label("Smart Pause", systemImage: "pause.circle") }
            }
            ActionsTab().tabItem { Label("Look & Sound", systemImage: "paintpalette") }
            ScheduleTab().tabItem { Label("Schedule", systemImage: "calendar") }
            if stats {
                StatsTab().tabItem { Label("Statistics", systemImage: "chart.bar") }
            }
        }
        .padding(12)
        .frame(width: 640, height: 640)
    }
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

// MARK: - General: language, modules, system

struct GeneralTab: View {
    @AppStorage(K.blinkEnabled) var blink = true
    @AppStorage(K.postureEnabled) var posture = false
    @AppStorage(K.deskEnabled) var desk = false
    @AppStorage(K.smartPause) var smartPause = true
    @AppStorage(K.calendarEnabled) var calendar = false
    @AppStorage(K.eyeExercises) var exercises = true
    @AppStorage(K.pauseMusic) var music = false
    @AppStorage(K.statsEnabled) var stats = true
    @State private var language = AppLanguage.current
    @State private var languageChanged = false
    @State private var calendarDenied = false
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Language") {
                Picker("Language", selection: Binding(get: { language }, set: {
                    language = $0
                    AppLanguage.set($0)
                    languageChanged = true
                })) {
                    ForEach(AppLanguage.options, id: \.code) { o in
                        Text(o.code.isEmpty ? L("System default") : o.title).tag(o.code)
                    }
                }
                if languageChanged {
                    HStack {
                        Text("Restart Blinky to apply the language.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart") { relaunch() }
                    }
                }
            }
            Section {
                ModuleToggle("Blink reminders", "An animated eye in the middle of the screen every few minutes.", $blink)
                ModuleToggle("Posture reminders", "A short “straighten your back” nudge.", $posture)
                ModuleToggle("Standing desk", "Alternate sitting and standing; switching is part of a break.", $desk)
                ModuleToggle("Smart pause", "Hold breaks during calls, screen sharing, video and games.", $smartPause)
                ModuleToggle("Calendar", "Move a break before upcoming meetings.", Binding(
                    get: { calendar },
                    set: { on in
                        if on && !CalendarWatch.authorized {
                            CalendarWatch.requestAccess { ok in calendar = ok; calendarDenied = !ok }
                        } else { calendar = on }
                    }))
                if calendarDenied {
                    Text("No access to Calendar. Allow it in System Settings → Privacy & Security → Calendars.")
                        .font(.caption).foregroundStyle(.red)
                }
                ModuleToggle("Eye exercises", "Follow-the-dot exercises at the start of long breaks.", $exercises)
                ModuleToggle("Pause music", "Pause what’s playing during a break and resume afterwards.", $music)
                ModuleToggle("Statistics", "Daily and weekly break statistics.", $stats)
                ModuleToggle("Global hotkeys", "⌃⌥⌘ shortcuts for the most common actions.", Binding(
                    get: { Prefs.bool(K.hotkeysEnabled) },
                    set: { Prefs.d.set($0, forKey: K.hotkeysEnabled); Hotkeys.apply() }))
            } header: {
                Text("Modules")
            } footer: {
                Text("Turned-off modules disappear from the menu and settings.")
            }
            Section("System") {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginItem },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            NSSound.beep()
                        }
                        loginItem = SMAppService.mainApp.status == .enabled
                    }))
            }
        }
        .formStyle(.grouped)
    }

    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.5; open \"$0\" --args --settings", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

struct ModuleToggle: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let isOn: Binding<Bool>

    init(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self.isOn = isOn
    }

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Breaks

struct BreaksTab: View {
    @AppStorage(K.breakEveryMin) var every = 20
    @AppStorage(K.breakDurationSec) var duration = 20
    @AppStorage(K.longEvery) var longEvery = 4
    @AppStorage(K.longDurationMin) var longDuration = 5
    @AppStorage(K.headsUpSec) var headsUp = 30
    @AppStorage(K.strictMode) var strict = false
    @AppStorage(K.snoozeLimit) var snoozeLimit = 6
    @AppStorage(K.breakMessage) var message = ""
    @AppStorage(K.waitForQuiet) var waitForQuiet = true
    @AppStorage(K.deskEnabled) var desk = false

    var body: some View {
        Form {
            Section("Short break") {
                Stepper("Every \(every) min", value: $every, in: 1...120)
                Stepper("Lasts \(duration) s", value: $duration, in: 5...600, step: 5)
                TextField("Message", text: $message, prompt: Text("Look at something about 20 feet (6 m) away"))
            }
            if desk { DeskSection() }
            Section("Long break") {
                Stepper(longEvery == 0 ? "Off" : "Every \(longEvery) breaks", value: $longEvery, in: 0...12)
                Stepper("Lasts \(longDuration) min", value: $longDuration, in: 1...30)
                    .disabled(longEvery == 0)
            }
            Section("Less annoying") {
                Stepper(headsUp == 0 ? "No heads-up" : "Heads-up \(headsUp) s before", value: $headsUp, in: 0...300, step: 10)
                Toggle("Wait for a pause in typing (up to 20 s)", isOn: $waitForQuiet)
                Stepper(snoozeLimit == 0 ? "Unlimited snoozes" : "Up to \(snoozeLimit) snoozes a day", value: $snoozeLimit, in: 0...30)
                Toggle("Strict mode: breaks can’t be skipped", isOn: $strict)
            }
        }
        .formStyle(.grouped)
    }
}

struct DeskSection: View {
    @AppStorage(K.sitLimitMin) var sit = 30
    @AppStorage(K.standLimitMin) var stand = 20
    @AppStorage(K.moveSec) var move = 120
    @AppStorage(K.postureStanding) var standing = false

    var body: some View {
        Section {
            Stepper("Stand up after \(sit) min sitting", value: $sit, in: 10...120, step: 5)
            Stepper("Sit down after \(stand) min standing", value: $stand, in: 5...90, step: 5)
            Stepper("Movement when switching: \(mmss(move))", value: $move, in: 30...300, step: 30)
            Picker("Now", selection: Binding(get: { standing }, set: { Posture.set(standing: $0); standing = $0 })) {
                Text("sitting").tag(false)
                Text("standing").tag(true)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Standing desk")
        } footer: {
            Text("Switching posture comes as a break: press “I stood up ✓” or “I sat down ✓”. If an eye break is close, they are merged. ⌃⌥⌘U switches posture manually.")
        }
    }
}

// MARK: - Blink and posture reminders

struct RemindersTab: View {
    let scheduler: Scheduler
    @AppStorage(K.blinkEnabled) var blink = true
    @AppStorage(K.blinkEveryMin) var blinkEvery = 5
    @AppStorage(K.blinkStyle) var blinkStyle = "center"
    @AppStorage(K.postureEnabled) var posture = false
    @AppStorage(K.postureEveryMin) var postureEvery = 30

    var body: some View {
        Form {
            if blink {
                Section("Blinking") {
                    Stepper("Every \(blinkEvery) min", value: $blinkEvery, in: 1...60)
                    Picker("Style", selection: $blinkStyle) {
                        Text("Eye in the center").tag("center")
                        Text("Soft glow around the edges").tag("edge")
                    }
                    Button("Preview") { scheduler.testBlink() }
                }
            }
            if posture {
                Section("Posture") {
                    Stepper("Every \(postureEvery) min", value: $postureEvery, in: 5...120, step: 5)
                    Button("Preview") { scheduler.testPosture() }
                }
            }
            Section {
                Text("Reminders are not shown during calls, video, games or right before a break. You can click through them.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Smart pause

struct SmartPauseTab: View {
    @ObservedObject var scheduler: Scheduler
    @AppStorage(K.detectMic) var mic = true
    @AppStorage(K.detectCamera) var camera = true
    @AppStorage(K.detectVideo) var video = true
    @AppStorage(K.videoFrontmostOnly) var frontOnly = true
    @AppStorage(K.detectGames) var games = true
    @AppStorage(K.delayAfterActivityMin) var delay = 1
    @AppStorage(K.deferToast) var toast = true
    @AppStorage(K.idleResetMin) var idleReset = 3
    @AppStorage(K.detectScreenShare) var screenShare = true
    @AppStorage(K.focusGentle) var focusGentle = true
    @AppStorage(K.quietMode) var quiet = false
    @State private var focusAuthorized = Detector.focusAuthorized

    private let none = "—"

    var body: some View {
        Form {
            Section("Right now") {
                LabeledContent("Microphone", value: scheduler.snapshot.micUsers.map(\.name).joined(separator: ", ").ifEmpty(none))
                LabeledContent("Camera", value: scheduler.snapshot.cameraOn ? L("on") : none)
                LabeledContent("Keeping the display awake", value: scheduler.snapshot.videoHolders.map(\.name).joined(separator: ", ").ifEmpty(none))
                LabeledContent("Screen sharing", value: scheduler.snapshot.screenWatched ? L("active") : none)
                LabeledContent("Paused because of", value: scheduler.currentActivity?.label ?? none)
            }
            Section("Calls") {
                Toggle("An app is using the microphone", isOn: $mic)
                Toggle("The camera is on", isOn: $camera)
                BundleListEditor(key: K.micExcluded, title: "Not a call (dictation and similar apps)",
                                 suggestions: scheduler.snapshot.micUsers.map(\.bundleID))
            }
            Section("Screen sharing and recording") {
                Toggle("Don’t interrupt while the screen is shared or recorded", isOn: $screenShare)
            }
            Section("Video") {
                Toggle("Video and media players", isOn: $video)
                Toggle("Only when the player is in front", isOn: $frontOnly).disabled(!video)
                BundleListEditor(key: K.videoExcluded, title: "Ignore",
                                 suggestions: scheduler.snapshot.videoHolders.map(\.bundleID))
            }
            Section("Games and focus") {
                Toggle("Full-screen games", isOn: $games)
                FocusAppsEditor()
            }
            Section {
                Toggle("Quiet mode now (gentle breaks)", isOn: $quiet)
                Toggle("Gentle breaks while a Focus is on", isOn: $focusGentle)
                if !focusAuthorized {
                    Button("Allow reading Focus status") {
                        Detector.requestFocusAccess()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { focusAuthorized = Detector.focusAuthorized }
                    }
                }
            } header: {
                Text("Focus and quiet mode")
            } footer: {
                Text("If macOS doesn’t share Focus status, create a Shortcuts automation: when a Focus turns on, open the URL blinky://quiet/on; when it turns off, blinky://quiet/off.")
            }
            Section("After an activity") {
                Stepper(delay == 0 ? "Break right away" : "Wait \(delay) min", value: $delay, in: 0...15)
                Toggle("Show “break will wait”", isOn: $toast)
                Stepper("Away for \(idleReset) min counts as a break", value: $idleReset, in: 1...30)
            }
        }
        .formStyle(.grouped)
    }
}

struct RunningApp: Hashable {
    let id: String
    let name: String
    static func all() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { a in a.bundleIdentifier.map { RunningApp(id: $0, name: a.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Editable list of bundle IDs stored as newline-separated text in UserDefaults.
struct BundleListEditor: View {
    @AppStorage var raw: String
    let title: LocalizedStringKey
    let suggestions: [String]

    init(key: String, title: LocalizedStringKey, suggestions: [String]) {
        _raw = AppStorage(wrappedValue: "", key)
        self.title = title
        self.suggestions = suggestions
    }

    var items: [String] {
        raw.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    func add(_ id: String) {
        guard !items.contains(id) else { return }
        raw = (items + [id]).joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout)
            ForEach(items, id: \.self) { id in
                HStack {
                    Text(ProcInfo.appName(bundleID: id))
                    Text(id).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { raw = items.filter { $0 != id }.joined(separator: "\n") } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Menu("Add…") {
                let fresh = suggestions.filter { !items.contains($0) }
                if !fresh.isEmpty {
                    Section("Active now") {
                        ForEach(fresh, id: \.self) { id in Button(ProcInfo.appName(bundleID: id)) { add(id) } }
                    }
                }
                Section("Running apps") {
                    ForEach(RunningApp.all(), id: \.self) { a in Button(a.name) { add(a.id) } }
                }
            }
            .fixedSize()
        }
    }
}

/// Apps that hold breaks, each with its own mode: full screen / in front / just open.
struct FocusAppsEditor: View {
    @AppStorage(K.focusApps) var raw = ""

    struct Row: Hashable { var id: String; var mode: String }

    var rows: [Row] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let p = line.split(separator: "|").map(String.init)
            guard let id = p.first, !id.isEmpty else { return nil }
            return Row(id: id, mode: p.count > 1 ? p[1] : "fg")
        }
    }

    func save(_ rows: [Row]) { raw = rows.map { "\($0.id)|\($0.mode)" }.joined(separator: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Focus apps").font(.callout)
            ForEach(rows, id: \.id) { row in
                HStack {
                    Text(ProcInfo.appName(bundleID: row.id))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { row.mode },
                        set: { m in save(rows.map { $0.id == row.id ? Row(id: $0.id, mode: m) : $0 }) })) {
                        Text("Full screen").tag("fgfs")
                        Text("In front").tag("fg")
                        Text("Just open").tag("open")
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button { save(rows.filter { $0.id != row.id }) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Menu("Add…") {
                ForEach(RunningApp.all(), id: \.self) { a in
                    Button(a.name) { if !rows.contains(where: { $0.id == a.id }) { save(rows + [Row(id: a.id, mode: "fg")]) } }
                }
            }
            .fixedSize()
        }
    }
}

// MARK: - Schedule: working hours, calendar, hotkeys

struct ScheduleTab: View {
    @AppStorage(K.officeHoursEnabled) var enabled = false
    @AppStorage(K.workStartMin) var start = 600
    @AppStorage(K.workEndMin) var end = 1140
    @AppStorage(K.workDays) var days = "2,3,4,5,6"
    @AppStorage(K.calendarEnabled) var calendar = false
    @AppStorage(K.calendarEarlyMin) var calendarEarly = 5
    @AppStorage(K.calendarAsMeeting) var calendarAsMeeting = false
    @AppStorage(K.hotkeysEnabled) var hotkeys = true

    /// Weekdays in the user's locale order, Calendar numbering (1 = Sunday).
    private var weekdays: [(Int, String)] {
        let c = Calendar.current
        let symbols = c.shortStandaloneWeekdaySymbols
        return (0..<7).map { i in
            let wd = (c.firstWeekday - 1 + i) % 7 + 1
            return (wd, symbols[wd - 1])
        }
    }

    func time(_ m: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: m.wrappedValue / 60, minute: m.wrappedValue % 60, second: 0, of: Date())! },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                m.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            })
    }

    var daySet: Set<Int> { Set(days.split(separator: ",").compactMap { Int($0) }) }

    var body: some View {
        Form {
            Section("Working hours") {
                Toggle("Only during working hours", isOn: $enabled)
                DatePicker("Start", selection: time($start), displayedComponents: .hourAndMinute).disabled(!enabled)
                DatePicker("End", selection: time($end), displayedComponents: .hourAndMinute).disabled(!enabled)
                HStack {
                    ForEach(weekdays, id: \.0) { d in
                        Toggle(d.1, isOn: Binding(
                            get: { daySet.contains(d.0) },
                            set: { on in
                                var s = daySet
                                if on { s.insert(d.0) } else { s.remove(d.0) }
                                days = s.sorted().map(String.init).joined(separator: ",")
                            }))
                            .toggleStyle(.button)
                    }
                }
                .disabled(!enabled)
            }
            if calendar {
                Section("Calendar") {
                    Stepper("Take the break early if a meeting starts within \(calendarEarly) min", value: $calendarEarly, in: 1...30)
                    Toggle("A meeting with attendees counts as a call, even without the mic", isOn: $calendarAsMeeting)
                }
            }
            if hotkeys {
                Section("Global hotkeys") {
                    ForEach(Hotkeys.defs, id: \.id) { d in Text(d.label).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Look & sound

struct ActionsTab: View {
    @AppStorage(K.breakStyle) var style = "full"
    @AppStorage(K.breakBackground) var background = "gradient"
    @AppStorage(K.breakImagePath) var imagePath = ""
    @AppStorage(K.startSound) var startSound = ""
    @AppStorage(K.endSound) var endSound = "Glass"
    @AppStorage(K.shortcutStart) var shortcutStart = ""
    @AppStorage(K.shortcutEnd) var shortcutEnd = ""

    var body: some View {
        Form {
            Section("Break window") {
                Picker("Style", selection: $style) {
                    Text("Full screen").tag("full")
                    Text("Gentle — a card in the corner").tag("gentle")
                }
                Picker("Background", selection: $background) {
                    Text("Gradient").tag("gradient")
                    Text("Desktop wallpaper").tag("wallpaper")
                    Text("Custom image").tag("image")
                }
                if background == "image" {
                    HStack {
                        Text(imagePath.isEmpty ? L("Not selected") : (imagePath as NSString).lastPathComponent)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") {
                            let p = NSOpenPanel()
                            p.allowedContentTypes = [.image]
                            if p.runModal() == .OK, let u = p.url { imagePath = u.path }
                        }
                    }
                }
            }
            Section("Sounds") {
                soundPicker("At the start", $startSound)
                soundPicker("At the end", $endSound)
            }
            Section {
                TextField("Shortcut at the start", text: $shortcutStart, prompt: Text("Shortcut name"))
                TextField("Shortcut at the end", text: $shortcutEnd, prompt: Text("Shortcut name"))
            } header: {
                Text("Automation")
            } footer: {
                Text("Runs a shortcut from the Shortcuts app, e.g. to dim the lights or turn on Do Not Disturb.")
            }
        }
        .formStyle(.grouped)
    }

    func soundPicker(_ title: LocalizedStringKey, _ value: Binding<String>) -> some View {
        HStack {
            Picker(title, selection: value) {
                Text("None").tag("")
                ForEach(BreakActions.systemSounds, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            Button { BreakActions.play(value.wrappedValue) } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless)
                .disabled(value.wrappedValue.isEmpty)
        }
    }
}

// MARK: - Statistics

struct StatsTab: View {
    @State private var days = Stats.lastDays(7)
    @State private var streak = Stats.streak()

    struct Bar: Identifiable { let id = UUID(); let day: String; let kind: String; let n: Int }

    var bars: [Bar] {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEd")
        return days.flatMap { d in [
            Bar(day: f.string(from: d.date), kind: L("Done"), n: d.done),
            Bar(day: f.string(from: d.date), kind: L("Skipped"), n: d.skipped),
        ] }
    }

    var today: Stats.Day { days.last! }

    func hm(_ minutes: Int) -> String { L("%d h %02d min", minutes / 60, minutes % 60) }

    var body: some View {
        Form {
            Section("Today") {
                LabeledContent("Breaks taken", value: "\(today.done)")
                LabeledContent("Skipped / snoozed", value: "\(today.skipped) / \(today.snoozed)")
                LabeledContent("Stepped away on your own", value: "\(today.natural)")
                LabeledContent("Screen time", value: hm(today.activeMin))
                if Posture.enabled {
                    LabeledContent("Standing", value: hm(today.standMin))
                    LabeledContent("Posture switches", value: "\(today.postureChanges)")
                }
            }
            Section {
                Chart(bars) { b in
                    BarMark(x: .value("Day", b.day), y: .value("Breaks", b.n))
                        .foregroundStyle(by: .value("Type", b.kind))
                }
                .chartForegroundStyleScale([L("Done"): Color.teal, L("Skipped"): Color.orange])
                .frame(height: 180)
                LabeledContent("Good-day streak", value: streak == 0 ? "—" : "\(streak) 🔥")
                let worked = days.filter { $0.activeMin > 0 }
                if !worked.isEmpty {
                    LabeledContent("Average screen time",
                                   value: L("%d h a day", worked.map(\.activeMin).reduce(0, +) / worked.count / 60))
                    if Posture.enabled {
                        LabeledContent("Average standing",
                                       value: L("%d min a day", worked.map(\.standMin).reduce(0, +) / worked.count))
                    }
                }
            } header: {
                Text("This week")
            } footer: {
                Text("A good day means at least 80% of breaks taken. Days without work don’t break the streak.")
            }
        }
        .formStyle(.grouped)
        .onAppear { days = Stats.lastDays(7); streak = Stats.streak() }
    }
}
