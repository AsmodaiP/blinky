import AppKit

/// The heart of the app: decides once a second what to show.
///
/// Time model: `work` is seconds of active work since the last break.
/// A break is due when `work >= nextBreakAt`. During a call, video, etc.,
/// `work` is held at the "heads-up before the break" mark, so after
/// the activity ends (and any delay), the normal warning comes first.
@MainActor
final class Scheduler: ObservableObject {
    static let shared = Scheduler()

    enum Display: Equatable {
        case countdown(Int)
        case busy(String)
        case paused(String)
        case onBreak(Int)
    }

    /// Not @Published on purpose: it changes every second and only the menu bar
    /// reads it (through `onUpdate`). Publishing it re-rendered the settings window each tick.
    private(set) var display: Display = .countdown(0)
    @Published private(set) var snapshot = Snapshot()
    var onUpdate: (() -> Void)?

    private(set) var manualPauseUntil: Date?
    private(set) var manualMeetingUntil: Date?
    private var paused = false
    private var onBreak = false
    private var work = 0
    private var nextBreakAt = 0
    private var interval = 0
    private var breaksSinceLong = 0
    private var blinkWork = 0
    private var postureWork = 0
    private var activity: Activity?
    private var activityEndedAt: Date?
    private var deferToastShown = false
    private var quietWait = 0
    private var breakRemaining = 0
    private var ticks = 0
    private var activeSecs = 0
    private var sleptAt: Date?
    private var earlyForEvent: String?
    private var timer: Timer?

    var canSnooze: Bool {
        let limit = Prefs.int(K.snoozeLimit)
        return limit == 0 || Stats.get(.snoozed) < limit
    }
    var canSkip: Bool { !Prefs.bool(K.strictMode) }
    var currentActivity: Activity? { activity }
    var isManualMeeting: Bool { manualMeetingUntil.map { $0 > Date() } ?? false }

    func start() {
        interval = Prefs.int(K.breakEveryMin)
        nextBreakAt = interval * 60
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.sleptAt == nil { self?.sleptAt = Date() } }
            }
        }
        for n in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.woke() }
            }
        }
        Posture.restart()
        refreshSnapshot()
        tick()
    }

    private func woke() {
        guard let s = sleptAt else { return }
        sleptAt = nil
        if Date().timeIntervalSince(s) >= Double(Prefs.int(K.idleResetMin) * 60) {
            if work > 60 { Stats.inc(.natural) }
            resetCycle()
            Posture.restart()
        }
    }

    private func refreshSnapshot() {
        var s = Detector.snapshot()
        if isManualMeeting {
            s.activities.insert(Activity(kind: .meeting, app: L("manual")), at: 0)
        }
        if Prefs.bool(K.calendarAsMeeting), let e = CalendarWatch.current() {
            s.activities.append(Activity(kind: .meeting, app: e.title ?? L("calendar")))
        }
        s.calendarEvent = CalendarWatch.nextEventText()
        if s != snapshot { snapshot = s }
    }

    // MARK: Tick

    private func tick() {
        ticks += 1

        if onBreak {
            breakRemaining -= 1
            Overlays.breakModel.remaining = breakRemaining
            if breakRemaining <= 0 { return finishBreak(completed: true) }
            return publish(.onBreak(breakRemaining))
        }

        let now = Date()
        if let u = manualMeetingUntil, u <= now { manualMeetingUntil = nil }
        if let u = manualPauseUntil {
            if now < u { return pause(L("Paused until %@", hhmm(u))) }
            manualPauseUntil = nil
        }
        if Prefs.bool(K.officeHoursEnabled), !OfficeHours.isNow(now) { return pause(L("Outside working hours")) }
        if paused { paused = false; resetCycle(); Posture.restart() }

        // Interval changed in settings — recompute the next break.
        let newInterval = Prefs.int(K.breakEveryMin)
        if newInterval != interval {
            interval = newInterval
            nextBreakAt = max(interval * 60, work + 60)
        }

        // Stepped away from the computer — that counts as a break.
        let idle = Idle.seconds
        if idle >= Double(Prefs.int(K.idleResetMin) * 60) {
            if work > 60 { Stats.inc(.natural) }
            resetCycle()
            Posture.restart()
            return publish(.paused(L("You were away — timer reset")))
        }
        work += 1
        activeSecs += 1
        if activeSecs >= 60 {
            activeSecs = 0
            Stats.inc(.activeMin)
            if Posture.enabled, Posture.standing { Stats.inc(.standMin) }
        }

        let lead = Prefs.int(K.headsUpSec)

        // Detectors: every 5 s, or every 2 s near a break and during an activity.
        let near = nextBreakAt - work <= lead + 10
        if ticks % 5 == 0 || ((near || activity != nil || activityEndedAt != nil) && ticks % 2 == 0) {
            refreshSnapshot()
        }

        // Activities
        let act = snapshot.activities.first
        if let act {
            activity = act
            activityEndedAt = nil
        } else if activity != nil {
            activity = nil
            activityEndedAt = now
        }
        var cooling = false
        if let ended = activityEndedAt {
            cooling = now.timeIntervalSince(ended) < Double(Prefs.int(K.delayAfterActivityMin) * 60)
            if !cooling { activityEndedAt = nil }
        }
        let busy = act != nil || cooling

        // Calendar meeting coming up: move the break before it (if more than half of the interval has been worked).
        if !busy, Prefs.bool(K.calendarEnabled),
           let e = CalendarWatch.upcoming(within: Double(Prefs.int(K.calendarEarlyMin) * 60)),
           earlyForEvent != e.eventIdentifier, work >= interval * 30, nextBreakAt - work > lead {
            earlyForEvent = e.eventIdentifier
            nextBreakAt = work + lead
            if Prefs.bool(K.deferToast) { Overlays.toast(L("Break a bit early"), L("“%@” starts soon", e.title ?? L("Meeting"))) }
        }

        // Whichever comes first: an eye break or a posture change.
        let remaining = min(nextBreakAt - work, Posture.secondsUntilDue)

        // Blink and posture reminders — only when not busy and no break is imminent.
        if !busy {
            blinkWork += 1
            postureWork += 1
            let soon = remaining <= lead + 30
            if Prefs.bool(K.blinkEnabled), blinkWork >= Prefs.int(K.blinkEveryMin) * 60 {
                blinkWork = 0
                if !soon { Overlays.showBlink(quiet: Detector.quiet) }
            }
            if Prefs.bool(K.postureEnabled), postureWork >= Prefs.int(K.postureEveryMin) * 60 {
                postureWork = 0
                if !soon { Overlays.showPosture() }
            }
        }

        if busy {
            if remaining <= lead {
                if nextBreakAt - work <= lead { work = nextBreakAt - lead }
                if Posture.secondsUntilDue <= lead { Posture.postpone(lead) }
                Overlays.hideHeadsUp()
                if !deferToastShown, Prefs.bool(K.deferToast) {
                    deferToastShown = true
                    Overlays.toast(L("Break will wait"), act?.label ?? L("a short delay after the activity"))
                }
            }
            return publish(.busy(act?.label ?? L("Delay after activity")))
        }
        deferToastShown = false

        if remaining <= 0 {
            // Wait for a pause in typing, but no longer than 20 seconds.
            if Prefs.bool(K.waitForQuiet), idle < 1.5, quietWait < 20 {
                quietWait += 1
                return publish(.countdown(0))
            }
            return startBreak()
        }
        if lead > 0, remaining <= lead {
            let pa: PostureAction? = Posture.secondsUntilDue <= lead ? Posture.dueAction : nil
            Overlays.showHeadsUp(remaining: remaining, posture: pa, canSnooze: canSnooze, canSkip: canSkip)
        }
        publish(.countdown(remaining))
    }

    private static let log = ProcessInfo.processInfo.environment["BLINKY_LOG"] != nil

    private func publish(_ d: Display) {
        if Self.log, d != display, !(isCountdown(d) && isCountdown(display)) {
            print(Date().formatted(date: .omitted, time: .standard), d, "work=\(work) next=\(nextBreakAt) posture=\(Posture.standing ? "stand" : "sit") due=\(Posture.secondsUntilDue)")
            fflush(stdout)
        }
        display = d
        onUpdate?()
    }

    private func isCountdown(_ d: Display) -> Bool { if case .countdown = d { return true }; return false }

    private func pause(_ reason: String) {
        paused = true
        Overlays.hideHeadsUp()
        publish(.paused(reason))
    }

    private func resetCycle() {
        work = 0
        nextBreakAt = Prefs.int(K.breakEveryMin) * 60
        blinkWork = 0
        postureWork = 0
        quietWait = 0
        Overlays.hideHeadsUp()
    }

    // MARK: Actions

    func breakNow() { startBreak() }

    private func startBreak() {
        guard !onBreak else { return }
        let every = Prefs.int(K.longEvery)
        let isLong = every > 0 && breaksSinceLong + 1 >= every
        // If a posture change is due within 5 minutes, merge it with this break.
        let posture: PostureAction? = Posture.enabled && Posture.secondsUntilDue <= 5 * 60 ? Posture.dueAction : nil
        var duration = isLong ? Prefs.int(K.longDurationMin) * 60 : Prefs.int(K.breakDurationSec)
        if posture != nil { duration = max(duration, Prefs.int(K.moveSec)) }
        let gentle = Prefs.string(K.breakStyle) == "gentle" || Detector.quiet
        onBreak = true
        breakRemaining = duration
        Overlays.showBreak(duration: duration, isLong: isLong, posture: posture, gentle: gentle, canSkip: canSkip, canSnooze: canSnooze)
        BreakActions.breakStarted()
        publish(.onBreak(duration))
    }

    private func finishBreak(completed: Bool) {
        let wasLong = Overlays.breakModel.isLong
        // Posture change not confirmed — remind at the next eye break rather than immediately.
        if onBreak, Overlays.breakModel.posture != nil, !Overlays.breakModel.postureConfirmed {
            Posture.postpone(Prefs.int(K.breakEveryMin) * 60)
        }
        if onBreak {
            onBreak = false
            Overlays.hideBreak()
            BreakActions.breakEnded(completed: completed)
        }
        Stats.inc(completed ? .done : .skipped)
        breaksSinceLong = wasLong ? 0 : breaksSinceLong + 1
        resetCycle()
        publish(.countdown(nextBreakAt))
    }

    func skipBreak() {
        if !onBreak, Posture.secondsUntilDue < interval * 60 { Posture.postpone(interval * 60) }
        if onBreak || Overlays.headsUpVisible {
            finishBreak(completed: false)
        } else {
            // "Skip next" from the menu
            Stats.inc(.skipped)
            nextBreakAt = work + interval * 60
            if Posture.secondsUntilDue < interval * 60 { Posture.postpone(interval * 60) }
        }
    }

    func snooze(minutes: Int) {
        guard canSnooze else { NSSound.beep(); return }
        Stats.inc(.snoozed)
        if onBreak {
            onBreak = false
            Overlays.hideBreak()
            BreakActions.breakEnded(completed: false)
        }
        Overlays.hideHeadsUp()
        quietWait = 0
        nextBreakAt = work + minutes * 60
        if Posture.secondsUntilDue < minutes * 60 { Posture.postpone(minutes * 60) }
        publish(.countdown(minutes * 60))
    }

    func pauseFor(minutes: Int?) {
        if let minutes {
            manualPauseUntil = Date().addingTimeInterval(Double(minutes * 60))
        } else {
            // until tomorrow, 06:00
            let c = Calendar.current
            let tomorrow = c.date(byAdding: .day, value: 1, to: c.startOfDay(for: Date()))!
            manualPauseUntil = c.date(bySettingHour: 6, minute: 0, second: 0, of: tomorrow)
        }
        tick()
    }

    func resume() {
        manualPauseUntil = nil
        tick()
    }

    func togglePause() {
        if manualPauseUntil != nil { resume() } else { pauseFor(minutes: 30) }
    }

    /// "I'm on a call": treat as busy until turned off (3 hours max).
    func toggleManualMeeting() {
        manualMeetingUntil = isManualMeeting ? nil : Date().addingTimeInterval(3 * 3600)
        refreshSnapshot()
        Overlays.toast(L(isManualMeeting ? "In a call" : "Call ended"),
                       L(isManualMeeting ? "Breaks and reminders are on hold" : "Breaks are back on schedule"))
    }

    func setQuiet(_ on: Bool) {
        Prefs.d.set(on, forKey: K.quietMode)
        Overlays.toast(L(on ? "Quiet mode" : "Normal mode"),
                       L(on ? "Gentle breaks, no full screen" : "Full-screen breaks are back"))
    }

    func toggleQuiet() { setQuiet(!Prefs.bool(K.quietMode)) }

    /// Posture confirmation (break button, menu, ⌃⌥⌘U).
    func confirmPosture(standing: Bool) {
        Posture.set(standing: standing)
        Overlays.breakModel.standingNow = standing
        Overlays.breakModel.postureConfirmed = true
        onUpdate?()
    }

    /// "Staying": posture is not changed — remind at the next break, and shorten this break to a regular one.
    func keepPosture() {
        Overlays.breakModel.postureConfirmed = true
        Overlays.breakModel.posture = nil
        Posture.postpone(Prefs.int(K.breakEveryMin) * 60)
        if onBreak {
            let normal = Prefs.int(K.breakDurationSec) - Overlays.breakModel.elapsed
            breakRemaining = min(breakRemaining, max(normal, 5))
            Overlays.breakModel.total = Overlays.breakModel.elapsed + breakRemaining
            Overlays.breakModel.remaining = breakRemaining
        }
    }

    func togglePosture() {
        confirmPosture(standing: !Posture.standing)
        Overlays.toast(L(Posture.standing ? "You’re standing" : "You’re sitting"),
                       L("I’ll remind you to switch in %d min", Posture.limit / 60))
    }

    func refreshSnapshotForDebug() { refreshSnapshot() }

    func testBlink() { Overlays.showBlink(quiet: Detector.quiet) }
    func testPosture() { Overlays.showPosture() }

    private func hhmm(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
