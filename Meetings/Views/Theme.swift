import AppKit
import SwiftUI

// MARK: - Colour helpers

extension Color {
    init(light: Color, dark: Color) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
    }

    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Design tokens

enum Theme {
    static let windowSize = CGSize(width: 1120, height: 740)
    static let sidebarWidth: CGFloat = 268
    static let pad: CGFloat = 32
    static let radius: CGFloat = 14
    static let controlRadius: CGFloat = 10

    static let canvas = Color(light: Color(hex: 0xF7F2ED), dark: Color(hex: 0x161427))
    static let sidebar = Color(light: Color(hex: 0xEDE5DD), dark: Color(hex: 0x1D1A30))
    static let surface = Color(light: Color(hex: 0xFFFCF8), dark: Color(hex: 0x242137))
    static let raised = Color(light: Color(hex: 0xE8DED4), dark: Color(hex: 0x302C45))
    static let stroke = Color(light: Color.black.opacity(0.08), dark: Color.white.opacity(0.08))

    // Sampled from the icon, with lighter dark-mode accents for readable text.
    static let blue = Color(light: Color(hex: 0x3034EA), dark: Color(hex: 0x9396FF))
    static let violet = Color(light: Color(hex: 0x4338F6), dark: Color(hex: 0xAB9FFF))
    static let green = Color(light: Color(hex: 0x5C645A), dark: Color(hex: 0xA5B29F))
    static let amber = Color(light: Color(hex: 0x8C581F), dark: Color(hex: 0xD59954))
    static let sand = Color(light: Color(hex: 0x7E5E52), dark: Color(hex: 0xD0B39B))
    static let red = Color(light: Color(hex: 0xB33F42), dark: Color(hex: 0xEF8C87))

    static let brand = LinearGradient(
        colors: [Color(hex: 0x3034EA), Color(hex: 0x4338F6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let title = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let heading = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 14)
    static let caption = Font.system(size: 12)
}

enum Palette {
    private static let speakers: [Color] = [
        Theme.blue, Theme.amber, Theme.green, Theme.violet, Theme.sand,
        Color(light: Color(hex: 0x475F62), dark: Color(hex: 0x9BBABD)),
        Color(light: Color(hex: 0x795E82), dark: Color(hex: 0xC5A8CE)),
        Color(light: Color(hex: 0x715D38), dark: Color(hex: 0xC4B082)),
    ]

    static func color(for segment: TranscriptSegment) -> Color {
        if let number = segment.speakerID.flatMap({ Int($0.dropFirst()) }) {
            return speakers[(number - 1) % speakers.count]
        }
        return segment.track == .mic ? Theme.green : .gray
    }

    /// A stable colour for a person, so the same name always gets the same colour.
    static func color(forName name: String) -> Color {
        let sum = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return speakers[sum % speakers.count]
    }
}

// MARK: - Formatting

enum Format {
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    static func dayTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func range(_ start: Date, _ end: Date) -> String {
        "\(time(start)) – \(time(end))"
    }

    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    static func untitled(_ date: Date = .now) -> String {
        "Meeting · \(dayTime(date))"
    }

    static func countdown(to date: Date, now: Date = .now) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "Starting now" }
        if minutes < 60 { return "Starts in \(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "Starts in \(hours) h" : "Starts in \(hours) h \(rest) min"
    }
}

// MARK: - Surfaces and labels

private struct SurfaceModifier: ViewModifier {
    let padding: CGFloat
    let fill: Color

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.stroke)
            )
    }
}

extension View {
    func surface(padding: CGFloat = 20, fill: Color = Theme.surface) -> some View {
        modifier(SurfaceModifier(padding: padding, fill: fill))
    }
}

struct SectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(.secondary)
    }
}

struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

extension View {
    /// Applied to the root of every window: no keyboard focus rings, and the UI is kept out of the accessibility tree.
    func appChrome() -> some View {
        self
            .focusEffectDisabled()
            .accessibilityHidden(true)
    }
}

struct Avatar: View {
    let name: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.16), in: Circle())
            .overlay(Circle().strokeBorder(color.opacity(0.25)))
    }

    private var initials: String {
        if name.hasPrefix("Speaker "), let number = name.split(separator: " ").last { return String(number) }
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }
}

struct LevelBar: View {
    let label: String
    let meter: LevelMeter
    let track: AudioTrack
    var width: CGFloat = 64

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { _ in
                let level = CGFloat(meter.read(track))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule()
                        .fill(level > 0.9 ? Theme.amber : Theme.green)
                        .frame(width: max(4, width * level))
                }
                .frame(width: width, height: 5)
            }
        }
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var height: CGFloat = 40
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: height)
            .background(Theme.brand, in: RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var height: CGFloat = 34
    var tint: Color = .primary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration, height: height, tint: tint, enabled: isEnabled)
    }

    private struct SecondaryBody: View {
        let configuration: Configuration
        let height: CGFloat
        let tint: Color
        let enabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .padding(.horizontal, 14)
                .frame(height: height)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .fill(hovering ? Theme.raised.opacity(1) : Theme.raised.opacity(0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .strokeBorder(Theme.stroke)
                )
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 32
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, size: size, enabled: isEnabled)
    }

    private struct IconBody: View {
        let configuration: Configuration
        let size: CGFloat
        let enabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering || configuration.isPressed ? Theme.raised : .clear)
                )
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

struct SidebarRowStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, selected: selected)
    }

    private struct RowBody: View {
        let configuration: Configuration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .fill(selected ? Theme.blue.opacity(0.18) : (hovering ? Theme.raised.opacity(0.7) : .clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous)
                        .strokeBorder(selected ? Theme.blue.opacity(0.35) : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.controlRadius, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Tabs

/// An underline tab bar whose first tab starts exactly at the leading edge of its container,
/// so it lines up with the title above it.
struct TabBar<Tab: Identifiable & Hashable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    let symbol: (Tab) -> String

    @Namespace private var underline

    var body: some View {
        HStack(spacing: 28) {
            ForEach(tabs) { tab in
                let selected = selection == tab
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = tab }
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 7) {
                            Image(systemName: symbol(tab))
                                .font(.system(size: 13, weight: .medium))
                            Text(title(tab))
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(selected ? Color.primary : Color.secondary)

                        ZStack {
                            Rectangle().fill(Color.clear)
                            if selected {
                                Rectangle()
                                    .fill(Theme.brand)
                                    .matchedGeometryEffect(id: "underline", in: underline)
                            }
                        }
                        .frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Window

/// Locks the window to a fixed size and blends the title bar into the content.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.remove(.resizable)
            window.styleMask.insert(.fullSizeContentView)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(Theme.canvas)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
