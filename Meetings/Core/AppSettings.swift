import Foundation
import Observation
import SwiftUI

enum AudioRetention: String, CaseIterable, Identifiable {
    case never
    case afterTranscription
    case afterOneDay
    case afterSevenDays
    case afterThirtyDays

    var id: String { rawValue }

    var label: String {
        switch self {
        case .never: "Keep audio"
        case .afterTranscription: "After transcription"
        case .afterOneDay: "After 1 day"
        case .afterSevenDays: "After 7 days"
        case .afterThirtyDays: "After 30 days"
        }
    }

    var detail: String {
        switch self {
        case .never: "Audio is kept until you delete it."
        case .afterTranscription: "Audio is removed once the transcript and speaker labels are saved."
        case .afterOneDay: "Audio is removed one day after the meeting ends."
        case .afterSevenDays: "Audio is removed seven days after the meeting ends."
        case .afterThirtyDays: "Audio is removed thirty days after the meeting ends."
        }
    }

    var maxAge: TimeInterval? {
        switch self {
        case .afterOneDay: 1 * 86_400
        case .afterSevenDays: 7 * 86_400
        case .afterThirtyDays: 30 * 86_400
        case .never, .afterTranscription: nil
        }
    }
}

enum AIProviderKind: String, CaseIterable, Identifiable {
    case off
    case appleIntelligence
    case ollama
    case openAICompatible
    case openRouter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: "Off"
        case .appleIntelligence: "Apple Intelligence"
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI-compatible endpoint"
        case .openRouter: "OpenRouter"
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case dark
    case light
    case system

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "Match system"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    static let defaultModel = "anthropic/claude-haiku-5.5"

    private enum Key {
        static let folder = "dataFolderPath"
        static let retention = "audioRetention"
        static let echo = "echoCancellation"
        static let inPersonInput = "inPersonInput"
        static let refineSpeakers = "refineSpeakers"
        static let suggestSpeakerNames = "suggestSpeakerNames"
        static let tidySpeakerChanges = "tidySpeakerChanges"
        static let model = "openRouterModel"
        static let aiByDefault = "aiNotesByDefault"
        static let reminders = "meetingReminders"
        static let appearance = "appearance"
        static let offline = NetworkPolicy.offlineKey
        static let provider = "aiProvider"
        static let ollamaURL = "ollamaURL"
        static let ollamaModel = "ollamaModel"
        static let ollamaContext = "ollamaContextTokens"
        static let compatibleURL = "compatibleURL"
        static let compatibleModel = "compatibleModel"
        static let automaticUpdates = UpdateService.automaticKey
    }

    var dataFolder: URL {
        didSet { UserDefaults.standard.set(dataFolder.path(percentEncoded: false), forKey: Key.folder) }
    }

    var audioRetention: AudioRetention {
        didSet { UserDefaults.standard.set(audioRetention.rawValue, forKey: Key.retention) }
    }

    var echoCancellation: Bool {
        didSet { UserDefaults.standard.set(echoCancellation, forKey: Key.echo) }
    }

    /// Which microphone in-person meetings use: `AudioInput.automatic`, `AudioInput.systemDefault`, or a device UID.
    var inPersonInput: String {
        didSet { UserDefaults.standard.set(inPersonInput, forKey: Key.inPersonInput) }
    }

    /// After an in-person meeting, run the slower, more careful speaker pass over the whole recording.
    var refineSpeakers: Bool {
        didSet { UserDefaults.standard.set(refineSpeakers, forKey: Key.refineSpeakers) }
    }

    /// Use Apple Intelligence to offer names people said in an in-person meeting. Never applied without the user.
    var suggestSpeakerNames: Bool {
        didSet { UserDefaults.standard.set(suggestSpeakerNames, forKey: Key.suggestSpeakerNames) }
    }

    /// Use Apple Intelligence to move a word or two across speaker changes when a sentence clearly continues.
    var tidySpeakerChanges: Bool {
        didSet { UserDefaults.standard.set(tidySpeakerChanges, forKey: Key.tidySpeakerChanges) }
    }

    var openRouterModel: String {
        didSet { UserDefaults.standard.set(openRouterModel, forKey: Key.model) }
    }

    var aiNotesByDefault: Bool {
        didSet { UserDefaults.standard.set(aiNotesByDefault, forKey: Key.aiByDefault) }
    }

    var meetingReminders: Bool {
        didSet { UserDefaults.standard.set(meetingReminders, forKey: Key.reminders) }
    }

    var appearance: AppAppearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Key.appearance) }
    }

    var automaticallyCheckForUpdates: Bool {
        didSet { UserDefaults.standard.set(automaticallyCheckForUpdates, forKey: Key.automaticUpdates) }
    }

    /// When on, nothing leaves this Mac except the speech model download. See `NetworkPolicy`.
    var offlineMode: Bool {
        didSet { UserDefaults.standard.set(offlineMode, forKey: Key.offline) }
    }

    var aiProvider: AIProviderKind {
        didSet { UserDefaults.standard.set(aiProvider.rawValue, forKey: Key.provider) }
    }

    var ollamaURL: String {
        didSet { UserDefaults.standard.set(ollamaURL, forKey: Key.ollamaURL) }
    }

    var ollamaModel: String {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: Key.ollamaModel) }
    }

    var ollamaContextTokens: Int {
        didSet { UserDefaults.standard.set(ollamaContextTokens, forKey: Key.ollamaContext) }
    }

    var compatibleURL: String {
        didSet { UserDefaults.standard.set(compatibleURL, forKey: Key.compatibleURL) }
    }

    var compatibleModel: String {
        didSet { UserDefaults.standard.set(compatibleModel, forKey: Key.compatibleModel) }
    }

    init() {
        let defaults = UserDefaults.standard
        dataFolder = defaults.string(forKey: Key.folder)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? AppSettings.defaultFolder
        audioRetention = defaults.string(forKey: Key.retention)
            .flatMap(AudioRetention.init(rawValue:)) ?? .never
        echoCancellation = defaults.object(forKey: Key.echo) as? Bool ?? true
        inPersonInput = defaults.string(forKey: Key.inPersonInput) ?? AudioInput.automatic
        refineSpeakers = defaults.object(forKey: Key.refineSpeakers) as? Bool ?? true
        suggestSpeakerNames = defaults.object(forKey: Key.suggestSpeakerNames) as? Bool ?? true
        tidySpeakerChanges = defaults.object(forKey: Key.tidySpeakerChanges) as? Bool ?? false
        openRouterModel = defaults.string(forKey: Key.model) ?? AppSettings.defaultModel
        aiNotesByDefault = defaults.object(forKey: Key.aiByDefault) as? Bool ?? false
        meetingReminders = defaults.object(forKey: Key.reminders) as? Bool ?? false
        appearance = defaults.string(forKey: Key.appearance).flatMap(AppAppearance.init(rawValue:)) ?? .dark
        automaticallyCheckForUpdates = defaults.object(forKey: Key.automaticUpdates) as? Bool ?? true
        offlineMode = defaults.bool(forKey: Key.offline)

        // Existing installs already have an OpenRouter key, so keep them on OpenRouter.
        aiProvider = defaults.string(forKey: Key.provider).flatMap(AIProviderKind.init(rawValue:))
            ?? (KeychainStore.exists(KeychainStore.openRouterAccount) ? .openRouter : .off)
        ollamaURL = defaults.string(forKey: Key.ollamaURL) ?? "http://localhost:11434"
        ollamaModel = defaults.string(forKey: Key.ollamaModel) ?? ""
        ollamaContextTokens = defaults.object(forKey: Key.ollamaContext) as? Int ?? 8_192
        compatibleURL = defaults.string(forKey: Key.compatibleURL) ?? ""
        compatibleModel = defaults.string(forKey: Key.compatibleModel) ?? ""
    }

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meetings", isDirectory: true)
    }
}
