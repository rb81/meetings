import AppKit
import AVFoundation
import Carbon.HIToolbox
import EventKit
import Observation
import UserNotifications

// MARK: - Reminders

enum RemindersService {
    enum Failure: LocalizedError {
        case denied
        case noList

        var errorDescription: String? {
            switch self {
            case .denied: "Reminders access is off. Turn it on in System Settings › Privacy & Security › Reminders."
            case .noList: "There's no Reminders list to add to."
            }
        }
    }

    @MainActor
    static func add(_ items: [ActionItem], meetingTitle: String) async throws -> Int {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { throw Failure.denied }
        guard let list = store.defaultCalendarForNewReminders() else { throw Failure.noList }

        for item in items {
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = list
            reminder.title = item.task

            var details = ["From meeting: \(meetingTitle)"]
            if let owner = item.owner, !owner.isEmpty { details.append("Owner: \(owner)") }
            if let due = item.due, !due.isEmpty { details.append("Due: \(due)") }
            reminder.notes = details.joined(separator: "\n")

            try store.save(reminder, commit: false)
        }
        try store.commit()
        return items.count
    }
}

// MARK: - Playback

@MainActor
@Observable
final class AudioPlayback {
    private var players: [AVAudioPlayer] = []

    private(set) var meetingID: UUID?
    private(set) var duration: TimeInterval = 0

    var isPlaying: Bool { players.contains { $0.isPlaying } }
    var currentTime: TimeInterval { players.first?.currentTime ?? 0 }
    var isLoaded: Bool { !players.isEmpty }

    func load(_ meeting: Meeting, dataFolder: URL) {
        guard meetingID != meeting.id else { return }
        stop()
        meetingID = meeting.id

        players = [AudioTrack.mic, .system].compactMap { track in
            let url = MeetingStore.audioURL(track, for: meeting, in: dataFolder)
            guard FileManager.default.fileExists(atPath: url.path),
                  let player = try? AVAudioPlayer(contentsOf: url)
            else { return nil }
            player.prepareToPlay()
            return player
        }
        duration = players.map(\.duration).max() ?? 0
    }

    func play(from time: TimeInterval? = nil) {
        guard let first = players.first else { return }
        let target = time ?? first.currentTime
        let startAt = first.deviceCurrentTime + 0.1
        for player in players {
            player.currentTime = min(target, player.duration)
            player.play(atTime: startAt)
        }
    }

    func pause() {
        players.forEach { $0.pause() }
    }

    func stop() {
        players.forEach { $0.stop() }
        players = []
        meetingID = nil
        duration = 0
    }

    func seek(to time: TimeInterval) {
        let wasPlaying = isPlaying
        for player in players {
            player.currentTime = min(max(0, time), player.duration)
        }
        if wasPlaying { play(from: time) }
    }
}

// MARK: - Global hotkey

/// A system-wide keyboard shortcut. Registered through Carbon, which needs no extra permission.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private let id: UInt32

    /// Each shortcut needs its own `id`. Every handler hears every shortcut, so it checks the id before acting.
    init?(keyCode: Int, modifiers: Int, id: UInt32 = 1, action: @escaping () -> Void) {
        self.action = action
        self.id = id

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }

                var pressed = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressed
                )
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                guard status == noErr, pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }

                hotKey.action()
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installed == noErr else { return nil }

        let identifier = EventHotKeyID(signature: OSType(0x4D544E47), id: id)
        let registered = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registered == noErr else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

// MARK: - Meeting reminders

struct JoinRequest: Sendable {
    let title: String
    let joinURL: URL?
    let attendees: [String]
}

/// Schedules a notification a minute before each meeting, with a Join & Record button.
/// Tapping the banner only opens the app. Recording starts only from the button.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private static let category = "MEETING"
    private static let joinAction = "JOIN_AND_RECORD"
    private static let prefix = "meeting-"

    var onJoin: (@MainActor @Sendable (JoinRequest) -> Void)?

    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let join = UNNotificationAction(identifier: Self.joinAction, title: "Join & Record", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [join], intentIdentifiers: [])
        ])
    }

    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Checks the current permission without ever showing a prompt.
    func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func clear() {
        Task {
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            let ids = pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    func schedule(_ events: [CalendarEvent]) {
        let center = UNUserNotificationCenter.current()
        Task {
            let pending = await center.pendingNotificationRequests()
            center.removePendingNotificationRequests(
                withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            )

            for event in events.prefix(20) {
                let fireDate = event.start.addingTimeInterval(-60)
                guard fireDate > .now else { continue }

                let content = UNMutableNotificationContent()
                content.title = event.title
                content.body = "Starts in 1 minute"
                content.sound = .default
                content.categoryIdentifier = Self.category
                content.userInfo = [
                    "title": event.title,
                    "url": event.joinURL?.absoluteString ?? "",
                    "attendees": event.attendees,
                ]

                let components = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second],
                    from: fireDate
                )
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                try? await center.add(UNNotificationRequest(
                    identifier: Self.prefix + event.id,
                    content: content,
                    trigger: trigger
                ))
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.joinAction else { return }

        let info = response.notification.request.content.userInfo
        let request = JoinRequest(
            title: info["title"] as? String ?? "Meeting",
            joinURL: (info["url"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) },
            attendees: info["attendees"] as? [String] ?? []
        )
        await MainActor.run { onJoin?(request) }
    }
}
