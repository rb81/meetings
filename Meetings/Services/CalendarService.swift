import AppKit
import EventKit
import Observation

struct CalendarEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let joinURL: URL?
    let attendees: [String]
}

@MainActor
@Observable
final class CalendarService {
    enum Access: Equatable {
        case notDetermined
        case granted
        case denied
        case writeOnly
    }

    private static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com"]

    private let store = EKEventStore()
    private(set) var access = CalendarService.currentAccess()
    private(set) var events: [CalendarEvent] = []
    private(set) var lastError: String?

    var isAuthorized: Bool { access == .granted }

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Coming back from System Settings after changing the permission.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccess() }
        }
        refresh()
    }

    #if DEBUG
    func setPreview(events: [CalendarEvent]) {
        access = .granted
        self.events = events
    }
    #endif

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        case .writeOnly: .writeOnly
        default: .denied
        }
    }

    func refreshAccess() {
        let latest = Self.currentAccess()
        if latest != access { access = latest }
        refresh()
    }

    func requestAccess() async {
        lastError = nil
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            lastError = error.localizedDescription
        }
        refreshAccess()
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    func refresh() {
        guard isAuthorized else {
            if !events.isEmpty { events = [] }
            return
        }

        let now = Date.now
        let dayStart = Calendar.current.startOfDay(for: now)
        let windowEnd = Calendar.current.date(byAdding: .day, value: 2, to: dayStart) ?? now
        let predicate = store.predicateForEvents(withStart: dayStart, end: windowEnd, calendars: nil)

        events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .map { event in
                CalendarEvent(
                    id: "\(event.eventIdentifier ?? "event")-\(event.startDate.timeIntervalSince1970)",
                    title: event.title?.isEmpty == false ? event.title : "Untitled event",
                    start: event.startDate,
                    end: event.endDate,
                    joinURL: Self.joinURL(for: event),
                    attendees: (event.attendees ?? [])
                        .filter { !$0.isCurrentUser }
                        .compactMap { $0.name }
                )
            }
    }

    private static func joinURL(for event: EKEvent) -> URL? {
        let texts: [String?] = [event.location, event.notes, event.url?.absoluteString]
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

        var links: [URL] = []
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            detector?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                if let url = match?.url {
                    links.append(url)
                }
            }
        }

        return links.first { url in
            let host = url.host?.lowercased() ?? ""
            return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }
}
