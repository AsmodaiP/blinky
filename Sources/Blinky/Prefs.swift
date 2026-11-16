import Foundation

/// All settings live in UserDefaults (domain local.blinky).
/// The settings window writes to the same keys via @AppStorage.
enum K {
    static let breakEveryMin = "breakEveryMin"
    static let breakDurationSec = "breakDurationSec"
    static let longEvery = "longEvery"
    static let longDurationMin = "longDurationMin"
    static let headsUpSec = "headsUpSec"
    static let strictMode = "strictMode"
    static let snoozeLimit = "snoozeLimit"
    static let breakMessage = "breakMessage"
    static let breakSound = "breakSound"
    static let waitForQuiet = "waitForQuiet"

    static let blinkEnabled = "blinkEnabled"
    static let blinkEveryMin = "blinkEveryMin"
    static let blinkStyle = "blinkStyle"        // center | edge
    static let postureEnabled = "postureEnabled"
    static let postureEveryMin = "postureEveryMin"

    static let detectMic = "detectMic"
    static let detectCamera = "detectCamera"
    static let detectVideo = "detectVideo"
    static let videoFrontmostOnly = "videoFrontmostOnly"
    static let detectGames = "detectGames"
    static let micExcluded = "micExcluded"
    static let videoExcluded = "videoExcluded"
    static let focusApps = "focusApps"          // strings "bundleID|mode", mode: fgfs | fg | open
    static let delayAfterActivityMin = "delayAfterActivityMin"
    static let deferToast = "deferToast"
    static let idleResetMin = "idleResetMin"

    static let officeHoursEnabled = "officeHoursEnabled"
    static let workStartMin = "workStartMin"
    static let workEndMin = "workEndMin"
    static let workDays = "workDays"            // "2,3,4,5,6" (Calendar.weekday, 1 = Sunday)

    static let hotkeysEnabled = "hotkeysEnabled"
    static let calendarEnabled = "calendarEnabled"
    static let calendarEarlyMin = "calendarEarlyMin"
    static let calendarAsMeeting = "calendarAsMeeting"
    static let detectScreenShare = "detectScreenShare"
    static let breakStyle = "breakStyle"        // full | gentle
    static let focusGentle = "focusGentle"
    static let quietMode = "quietMode"
    static let pauseMusic = "pauseMusic"
    static let shortcutStart = "shortcutStart"
    static let shortcutEnd = "shortcutEnd"
    static let breakBackground = "breakBackground"   // gradient | wallpaper | image
    static let breakImagePath = "breakImagePath"
    static let endSound = "endSound"
    static let startSound = "startSound"
    static let eyeExercises = "eyeExercises"

    static let deskEnabled = "deskEnabled"
    static let sitLimitMin = "sitLimitMin"
    static let standLimitMin = "standLimitMin"
    static let moveSec = "moveSec"
    static let postureStanding = "postureStanding"
    static let postureSince = "postureSince"

    static let smartPause = "smartPause"
    static let statsEnabled = "statsEnabled"
}

enum Prefs {
    static let d = UserDefaults.standard

    static func register() {
        d.register(defaults: [
            K.breakEveryMin: 20,
            K.breakDurationSec: 20,
            K.longEvery: 4,
            K.longDurationMin: 5,
            K.headsUpSec: 30,
            K.strictMode: false,
            K.snoozeLimit: 6,
            K.breakMessage: "",   // empty = localized default
            K.breakSound: true,
            K.waitForQuiet: true,

            K.blinkEnabled: true,
            K.blinkEveryMin: 5,
            K.blinkStyle: "center",
            K.postureEnabled: false,
            K.postureEveryMin: 30,

            K.detectMic: true,
            K.detectCamera: true,
            K.detectVideo: true,
            K.videoFrontmostOnly: true,
            K.detectGames: true,
            K.micExcluded: [
                "com.goodsnooze.MacWhisper",
                "com.superduper.superwhisper",
                "com.apple.CoreSpeech",
                "corespeechd",
            ].joined(separator: "\n"),
            K.videoExcluded: [
                "com.blackmagic-design.DaVinciResolve",
                "com.if.Amphetamine",
                "caffeinate",
            ].joined(separator: "\n"),
            K.focusApps: "com.apple.iWork.Keynote|fgfs",
            K.delayAfterActivityMin: 1,
            K.deferToast: true,
            K.idleResetMin: 3,

            K.officeHoursEnabled: false,
            K.workStartMin: 10 * 60,
            K.workEndMin: 19 * 60,
            K.workDays: "2,3,4,5,6",

            K.hotkeysEnabled: true,
            K.calendarEnabled: false,
            K.calendarEarlyMin: 5,
            K.calendarAsMeeting: false,
            K.detectScreenShare: true,
            K.breakStyle: "full",
            K.focusGentle: true,
            K.quietMode: false,
            K.pauseMusic: false,
            K.shortcutStart: "",
            K.shortcutEnd: "",
            K.breakBackground: "gradient",
            K.breakImagePath: "",
            K.endSound: "Glass",
            K.startSound: "",
            K.eyeExercises: true,

            K.deskEnabled: false,
            K.sitLimitMin: 30,
            K.standLimitMin: 20,
            K.moveSec: 120,
            K.postureStanding: false,

            K.smartPause: true,
            K.statsEnabled: true,
        ])
    }

    /// One-time copy of settings from the pre-release bundle ID (`local.blinky`).
    static func migrateLegacyDomain() {
        guard !d.bool(forKey: "migratedLegacyDomain") else { return }
        d.set(true, forKey: "migratedLegacyDomain")
        guard Bundle.main.bundleIdentifier != "local.blinky",
              let old = d.persistentDomain(forName: "local.blinky") else { return }
        for (k, v) in old where d.object(forKey: k) == nil && !k.hasPrefix("NSStatusItem") {
            d.set(v, forKey: k)
        }
    }

    static func int(_ k: String) -> Int { d.integer(forKey: k) }
    static func bool(_ k: String) -> Bool { d.bool(forKey: k) }
    static func string(_ k: String) -> String { d.string(forKey: k) ?? "" }

    static func lines(_ k: String) -> [String] {
        string(k).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func setLines(_ k: String, _ v: [String]) {
        d.set(v.joined(separator: "\n"), forKey: k)
    }

    static var workDays: Set<Int> {
        Set(string(K.workDays).split(separator: ",").compactMap { Int($0) })
    }
}

enum OfficeHours {
    static func isNow(_ date: Date = Date()) -> Bool {
        let c = Calendar.current
        let wd = c.component(.weekday, from: date)
        let m = c.component(.hour, from: date) * 60 + c.component(.minute, from: date)
        return Prefs.workDays.contains(wd)
            && m >= Prefs.int(K.workStartMin)
            && m < Prefs.int(K.workEndMin)
    }
}

/// Simple daily stats: done / skipped / postponed / natural breaks.
enum Stats {
    enum Kind: String { case done, skipped, snoozed, natural, activeMin, standMin, postureChanges }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func key(_ k: Kind, _ date: Date = Date()) -> String {
        "stats.\(fmt.string(from: date)).\(k.rawValue)"
    }

    static func inc(_ k: Kind) { Prefs.d.set(get(k) + 1, forKey: key(k)) }
    static func get(_ k: Kind, _ date: Date = Date()) -> Int { Prefs.d.integer(forKey: key(k, date)) }

    struct Day: Identifiable {
        let date: Date
        let done, skipped, snoozed, natural, activeMin, standMin, postureChanges: Int
        var id: Date { date }
        var isEmpty: Bool { done + skipped == 0 && activeMin < 30 }
        /// A "good" day: at least 80% of breaks done.
        var isGood: Bool { done > 0 && Double(done) >= 0.8 * Double(done + skipped) }
    }

    static func day(_ date: Date) -> Day {
        Day(date: date, done: get(.done, date), skipped: get(.skipped, date), snoozed: get(.snoozed, date),
            natural: get(.natural, date), activeMin: get(.activeMin, date),
            standMin: get(.standMin, date), postureChanges: get(.postureChanges, date))
    }

    static func lastDays(_ n: Int) -> [Day] {
        let c = Calendar.current
        let today = c.startOfDay(for: Date())
        return (0..<n).reversed().map { day(c.date(byAdding: .day, value: -$0, to: today)!) }
    }

    /// Streak of consecutive good days. Empty days (weekends, vacation) do not break the streak.
    /// Today counts only if it is already good.
    static func streak() -> Int {
        let c = Calendar.current
        var d = c.startOfDay(for: Date())
        var n = 0
        let today = day(d)
        if today.isGood { n += 1 }
        for _ in 0..<365 {
            d = c.date(byAdding: .day, value: -1, to: d)!
            let x = day(d)
            if x.isEmpty { continue }
            if !x.isGood { break }
            n += 1
        }
        return n
    }
}
