import EventKit
import Foundation

/// macOS calendar: upcoming meetings (cached for a minute).
@MainActor
enum CalendarWatch {
    static let store = EKEventStore()
    private static var cache: [EKEvent] = []
    private static var cachedAt = Date.distantPast
    private static var observing = false

    static var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    static func requestAccess(_ done: @escaping @MainActor (Bool) -> Void) {
        store.requestFullAccessToEvents { ok, _ in
            Task { @MainActor in done(ok) }
        }
    }

    private static func events() -> [EKEvent] {
        guard Prefs.bool(K.calendarEnabled), authorized else { return [] }
        if !observing {
            observing = true
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
                MainActor.assumeIsolated { cachedAt = .distantPast }
            }
        }
        let now = Date()
        if now.timeIntervalSince(cachedAt) > 60 {
            let pred = store.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600), end: now.addingTimeInterval(3 * 3600), calendars: nil)
            cache = store.events(matching: pred).filter { e in
                !e.isAllDay && e.status != .canceled && e.availability != .free
                    && e.attendees?.first(where: { $0.isCurrentUser })?.participantStatus != .declined
            }
            cachedAt = now
        }
        return cache
    }

    /// A meeting that starts within the next `within` seconds.
    static func upcoming(within: TimeInterval) -> EKEvent? {
        let now = Date()
        return events().filter { $0.startDate > now && $0.startDate.timeIntervalSince(now) <= within }
            .min { $0.startDate < $1.startDate }
    }

    /// A meeting in progress that has other participants.
    static func current() -> EKEvent? {
        let now = Date()
        return events().first { $0.startDate <= now && $0.endDate > now && ($0.attendees?.count ?? 0) > 1 }
    }

    static func nextEventText() -> String? {
        guard let e = upcoming(within: 3 * 3600) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: e.startDate)) \(e.title ?? L("Meeting"))"
    }
}
