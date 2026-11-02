import SwiftUI

struct UpcomingView: View {
    @Environment(AppStore.self) private var store

    private var hero: CalendarEvent? {
        guard let first = store.calendar.events.first else { return nil }
        return first.start <= .now.addingTimeInterval(3600) ? first : nil
    }

    private var others: [CalendarEvent] {
        let events = store.calendar.events
        return hero == nil ? events : Array(events.dropFirst())
    }

    private var todayEvents: [CalendarEvent] {
        others.filter { Calendar.current.isDateInToday($0.start) }
    }

    private var laterEvents: [CalendarEvent] {
        others.filter { !Calendar.current.isDateInToday($0.start) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Upcoming")
                        .font(Theme.title)
                    Text(Format.day(.now))
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                }

                ModelSetupCard()

                if !store.calendar.isAuthorized {
                    connectCard
                } else if store.calendar.events.isEmpty {
                    emptyState
                } else {
                    if let hero {
                        HeroEventCard(event: hero)
                    }
                    section("Today", todayEvents)
                    section("Tomorrow & later", laterEvents)
                }
            }
            .padding(Theme.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .overlay(alignment: .topTrailing) {
            Button {
                store.calendar.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(IconButtonStyle())
            .help("Refresh calendar")
            .padding(.top, Theme.pad)
            .padding(.trailing, Theme.pad)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ events: [CalendarEvent]) -> some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title)
                ForEach(events) { event in
                    EventCard(event: event)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.blue)
                .frame(width: 64, height: 64)
                .background(Theme.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("Nothing on the calendar")
                .font(Theme.heading)
            Text("Meetings in the next two days show up here. You can still start a recording any time.")
                .font(Theme.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .surface(padding: 40)
    }

    private var connectCard: some View {
        let blocked = store.calendar.access == .denied || store.calendar.access == .writeOnly

        return VStack(spacing: 16) {
            Image(systemName: blocked ? "calendar.badge.exclamationmark" : "calendar.badge.clock")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(blocked ? Theme.amber : Theme.blue)
                .frame(width: 64, height: 64)
                .background((blocked ? Theme.amber : Theme.blue).opacity(0.14), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(spacing: 6) {
                Text(blocked ? "Calendar access is off" : "Connect your calendar")
                    .font(Theme.heading)
                Text(blocked
                     ? "Allow Meetings full access under Privacy & Security › Calendars. This page updates when you come back."
                     : "See your upcoming meetings and join them from here. Calendar data stays on this Mac.")
                    .font(Theme.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            if blocked {
                Button("Open Privacy Settings") { store.calendar.openPrivacySettings() }
                    .buttonStyle(PrimaryButtonStyle())
            } else {
                Button("Connect Calendar") {
                    Task { await store.calendar.requestAccess() }
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            if let error = store.calendar.lastError {
                Text(error)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
        }
        .frame(maxWidth: .infinity)
        .surface(padding: 36)
    }
}

struct AttendeeStack: View {
    let names: [String]
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: -7) {
                ForEach(Array(names.prefix(4).enumerated()), id: \.offset) { _, name in
                    Avatar(name: name, color: Palette.color(forName: name), size: size)
                        .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: 2))
                }
            }
            if names.count > 4 {
                Text("+\(names.count - 4)")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct HeroEventCard: View {
    @Environment(AppStore.self) private var store
    let event: CalendarEvent

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 14) {
                TimelineView(.periodic(from: .now, by: 20)) { context in
                    let started = event.start <= context.date
                    Chip(
                        text: started ? "In progress" : Format.countdown(to: event.start, now: context.date),
                        symbol: started ? "dot.radiowaves.left.and.right" : "clock",
                        tint: Theme.blue
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .lineLimit(2)
                    Text(Format.range(event.start, event.end))
                        .font(Theme.body)
                        .foregroundStyle(.secondary)
                }

                if !event.attendees.isEmpty {
                    AttendeeStack(names: event.attendees)
                }
            }

            Spacer(minLength: 0)

            Button {
                Task { await store.record(event) }
            } label: {
                Label(
                    event.joinURL == nil ? "Record In Person" : "Join & Record",
                    systemImage: event.joinURL == nil ? "person.2.fill" : "video.fill"
                )
            }
            .buttonStyle(PrimaryButtonStyle(height: 44))
            .disabled(store.recorder.isRecording)
            .contextMenu {
                Button("Record as In-Person Meeting") { Task { await store.record(event, inPerson: true) } }
                Button("Record as Online Meeting") { Task { await store.record(event, inPerson: false) } }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Theme.surface
                LinearGradient(
                    colors: [Theme.blue.opacity(0.22), Theme.violet.opacity(0.10), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.blue.opacity(0.30))
        )
    }
}

struct EventCard: View {
    @Environment(AppStore.self) private var store
    let event: CalendarEvent

    private var minutes: Int {
        max(1, Int(event.end.timeIntervalSince(event.start) / 60))
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Format.time(event.start))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                Text("\(minutes) min")
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 76, alignment: .leading)

            Rectangle()
                .fill(Theme.stroke)
                .frame(width: 1, height: 36)

            VStack(alignment: .leading, spacing: 5) {
                Text(event.title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                if !event.attendees.isEmpty {
                    Text(attendeeSummary)
                        .font(Theme.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            Button {
                Task { await store.record(event) }
            } label: {
                Label(
                    event.joinURL == nil ? "Record In Person" : "Join & Record",
                    systemImage: event.joinURL == nil ? "person.2.fill" : "video.fill"
                )
            }
            .buttonStyle(SecondaryButtonStyle(height: 34))
            .disabled(store.recorder.isRecording)
            .contextMenu {
                Button("Record as In-Person Meeting") { Task { await store.record(event, inPerson: true) } }
                Button("Record as Online Meeting") { Task { await store.record(event, inPerson: false) } }
            }
        }
        .surface(padding: 16)
    }

    private var attendeeSummary: String {
        let names = event.attendees.prefix(3).joined(separator: ", ")
        let extra = event.attendees.count - 3
        return extra > 0 ? "\(names) +\(extra)" : names
    }
}
