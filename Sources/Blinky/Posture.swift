import Foundation

enum PostureAction { case stand, sit }

/// Desk posture, sitting/standing. Determined by confirmation during a break
/// (or ⌃⌥⌘U / menu). Stored in UserDefaults.
@MainActor
enum Posture {
    private static let d = UserDefaults.standard

    static var enabled: Bool { Prefs.bool(K.deskEnabled) }
    static var standing: Bool { d.bool(forKey: K.postureStanding) }

    static var since: Date {
        let t = d.double(forKey: K.postureSince)
        return t > 0 ? Date(timeIntervalSince1970: t) : Date()
    }

    private static func setSince(_ x: Date) { d.set(x.timeIntervalSince1970, forKey: K.postureSince) }

    static func set(standing s: Bool) {
        if s != standing { Stats.inc(.postureChanges) }
        d.set(s, forKey: K.postureStanding)
        setSince(Date())
    }

    /// Restart the timer for the current posture (launch, or back after being away).
    static func restart() { setSince(Date()) }

    static var limit: Int { (standing ? Prefs.int(K.standLimitMin) : Prefs.int(K.sitLimitMin)) * 60 }
    static var elapsed: Int { Int(Date().timeIntervalSince(since)) }
    static var secondsUntilDue: Int { enabled ? limit - elapsed : Int.max / 2 }
    static var dueAction: PostureAction { standing ? .sit : .stand }

    /// Postpone the reminder: it fires after `seconds`.
    static func postpone(_ seconds: Int) {
        setSince(Date().addingTimeInterval(Double(seconds - limit)))
    }

    static var statusText: String { L(standing ? "Standing %d min" : "Sitting %d min", max(elapsed, 0) / 60) }

    private static let toStand = [
        "Walk around the room for a couple of minutes",
        "15 calf raises — a pump for your leg veins",
        "10 slow squats",
        "Roll your shoulders back, then forward",
        "Go get some water",
    ]
    private static let toSit = [
        "Calf stretch: step back, heel down, 20 s per leg",
        "Tilt your head to each shoulder, slowly",
        "Standing torso twists, hands on hips",
        "Reach up on your toes, then lower down",
        "Walk for a minute before sitting down",
    ]

    static func exercise(for a: PostureAction) -> String {
        L((a == .stand ? toStand : toSit).randomElement()!)
    }
}
