import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings

        Form {
            Section {
                Toggle("Offline mode", isOn: $settings.offlineMode)

                Text(offlineSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Privacy")
            }

            Section {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Appearance")
            }

            Section {
                LabeledContent("Location") {
                    Text(store.settings.dataFolder.path(percentEncoded: false))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Button("Choose Folder…") { store.chooseDataFolder() }
                        .disabled(store.recorder.isRecording)
                    Button("Show in Finder") { NSWorkspace.shared.open(store.settings.dataFolder) }
                    Spacer()
                    if store.settings.dataFolder != AppSettings.defaultFolder {
                        Button("Use Default") { store.resetDataFolder() }
                            .disabled(store.recorder.isRecording)
                    }
                }

                Text("Meetings, audio, transcripts, notes, and the speech models are saved only inside this folder. Meetings in a previous folder stay there, and the models download again for a new folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Data folder")
            }

            Section {
                Picker("Delete audio", selection: $settings.audioRetention) {
                    ForEach(AudioRetention.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                Text(store.settings.audioRetention.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Cancel echo from speakers", isOn: $settings.echoCancellation)
                Text("Removes other people's voices from your microphone when you're not wearing headphones. It can lower the volume of other apps a little. Applies to online meetings only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("In-person microphone", selection: $settings.inPersonInput) {
                    Text("Automatic").tag(AudioInput.automatic)
                    Text("System default").tag(AudioInput.systemDefault)
                    ForEach(AudioInput.devices()) { device in
                        Text(device.isHeadset ? "\(device.name) (headset)" : device.name).tag(device.id)
                    }
                }
                Text("In-person meetings record only the microphone, with every voice in the room on it. Automatic uses the Mac's built-in microphone when a headset is connected, because a headset microphone mostly hears the person wearing it. Applies to the next meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Refine speakers after in-person meetings", isOn: $settings.refineSpeakers)
                Text("Speakers are separated live while you record. When the meeting ends, a careful pass over the whole recording corrects them word by word, joins any voice that was split in two, and numbers people in the order they first spoke, keeping any names you've set. Voice prints are only compared within one meeting and are never saved. Turn this off to keep the live labels as they were.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Suggest names people say", isOn: $settings.suggestSpeakerNames)
                Toggle("Tidy words at speaker changes", isOn: $settings.tidySpeakerChanges)
                Text(AppleIntelligence.problem.map { "Both use Apple Intelligence on this Mac. \($0)" }
                     ?? "Both use Apple Intelligence on this Mac, after in-person meetings. Suggested names, like someone saying \u{201C}I\u{2019}m Dana\u{201D}, appear in the speaker menu and are never applied for you. Tidying only moves a word or two to the other side of a speaker change when a sentence clearly continues; it never changes words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Audio")
            }

            Section {
                LabeledContent("Speech model", value: modelStatus)
                if let issue = store.models.speakerModelIssue {
                    Text("Speaker separation is unavailable: \(issue)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("In-person speaker models", value: liveSpeakerStatus)
                if store.models.state == .ready, !store.models.hasRoomModels || store.models.liveSpeakers == nil {
                    if let issue = store.models.liveSpeakerIssue {
                        Text("In-person speaker labels are unavailable: \(issue)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button(store.models.isDownloadingRoomModels ? "Downloading…" : "Download In-Person Speaker Models") {
                        store.models.downloadRoomModels()
                    }
                    .disabled(store.models.isDownloadingRoomModels)
                    .help("NVIDIA Nemotron 3 Diarization and CAM++ voice prints, about 430 MB")
                }
                if showsModelButton {
                    Button(store.models.state == .notDownloaded ? "Download Model" : "Repair (Download Again)") {
                        store.models.prepare()
                    }
                } else if store.models.state == .ready {
                    Button("Check Models Again") {
                        store.models.prepare()
                    }
                    .help("The app only goes online for the models when you press this")
                }
                Text("After the first download the models load from your data folder. The app doesn't contact Hugging Face again unless you press Download, Repair, or Check. Offline mode doesn't block these buttons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(ModelInfo.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Transcription")
            }

            Section {
                Picker("Provider", selection: $settings.aiProvider) {
                    ForEach(AIProviderKind.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }

                AIProviderFields(settings: settings)

                if settings.aiProvider != .off {
                    if let reason = store.aiBlockReason {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("\(store.aiDestination) AI notes are optional for each meeting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Turn on AI notes for new meetings", isOn: $settings.aiNotesByDefault)
                    .disabled(!store.aiReady)
            } header: {
                Text("AI notes")
            }

            Section {
                Toggle("Remind me a minute before meetings", isOn: $settings.meetingReminders)
                if store.settings.meetingReminders, store.remindersBlocked {
                    Label("Notifications are off for Meetings in System Settings.", systemImage: "bell.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent("Start or stop recording", value: "⌃⌥⌘M")
                LabeledContent("Pause or resume", value: "⌃⌥⌘P")
                Text("Reminders are off until you switch them on, which is when macOS asks for notification permission. The reminder has a Join & Record button, and nothing records until you press it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Shortcuts & reminders")
            }

            Section {
                LabeledContent("Access", value: calendarStatus)
                switch store.calendar.access {
                case .granted:
                    EmptyView()
                case .notDetermined:
                    Button("Connect Calendar") {
                        Task { await store.calendar.requestAccess() }
                    }
                case .denied, .writeOnly:
                    Button("Open Privacy Settings") {
                        store.calendar.openPrivacySettings()
                    }
                }
                if let error = store.calendar.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Calendar")
            }

            Section {
                Toggle("Automatically check for updates", isOn: $settings.automaticallyCheckForUpdates)
                HStack {
                    Button(store.updates.isChecking ? "Checking…" : "Check for Updates") {
                        Task { await store.updates.check(force: true) }
                    }
                    .disabled(store.updates.isChecking || settings.offlineMode)
                    Link("GitHub Releases", destination: UpdateService.releasesURL)
                }
                Text(settings.offlineMode ? "Update checks are paused in offline mode." : store.updates.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Checks GitHub once a day while Meetings is running. No meeting content is sent. New versions open in your browser; nothing installs automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Updates")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 680)
        .onChange(of: store.settings.audioRetention) { _, _ in
            store.applyRetention()
        }
    }

    private var offlineSummary: String {
        if store.settings.offlineMode {
            return "On. Nothing leaves this Mac. The only network use left is downloading the speech model when you press Download or Repair. AI runs only on this Mac or Apple's on-device model. Opening a meeting link still happens in your browser."
        }
        return "Off. AI notes can use the provider you choose, including cloud services."
    }

    private var calendarStatus: String {
        switch store.calendar.access {
        case .granted: "Allowed"
        case .notDetermined: "Not asked yet"
        case .denied: "Off"
        case .writeOnly: "Add-only (needs full access)"
        }
    }

    private var modelStatus: String {
        switch store.models.state {
        case .notDownloaded: "Not downloaded"
        case .working(_, let detail): detail
        case .loading: "Loading from your data folder…"
        case .ready: store.models.diarizer == nil ? "Ready (no speaker models)" : "Ready"
        case .failed: "Needs repair"
        }
    }

    private var liveSpeakerStatus: String {
        if store.models.liveSpeakers != nil, store.models.hasRoomModels { return "Ready (Nemotron 3)" }
        if store.models.isDownloadingRoomModels { return "Downloading…" }
        return store.models.state == .ready ? "Not downloaded" : "Waiting for the speech model"
    }

    private var showsModelButton: Bool {
        switch store.models.state {
        case .notDownloaded, .failed: true
        case .working, .loading, .ready: false
        }
    }
}

/// The fields that belong to whichever AI provider is selected.
private struct AIProviderFields: View {
    @Environment(AppStore.self) private var store
    @Bindable var settings: AppSettings

    @State private var openRouterKey = ""
    @State private var compatibleKey = ""
    @State private var browsing = false

    var body: some View {
        switch settings.aiProvider {
        case .off:
            EmptyView()

        case .appleIntelligence:
            LabeledContent("Status", value: AppleIntelligence.problem ?? "Ready")
            Text("Runs entirely on this Mac. Its context window is small, so long meetings are read in parts.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .ollama:
            TextField("Server address", text: $settings.ollamaURL)
            modelRow("Model, e.g. llama3.2", text: $settings.ollamaModel) {
                guard let url = URL(string: settings.ollamaURL) else { throw AIError.invalidResponse }
                return try await OllamaModel.listModels(baseURL: url)
            }
            Picker("Context window", selection: $settings.ollamaContextTokens) {
                Text("4K tokens").tag(4_096)
                Text("8K tokens").tag(8_192)
                Text("16K tokens").tag(16_384)
                Text("32K tokens").tag(32_768)
            }
            Text("Runs on this Mac or your network. Ollama's own default window is small and would cut off long transcripts, so Meetings sets it here. A bigger window uses more memory.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .openAICompatible:
            TextField("Endpoint, e.g. http://localhost:1234/v1", text: $settings.compatibleURL)
            keyRow("API key (optional)", text: $compatibleKey, stored: store.hasCompatibleKey) {
                store.saveAPIKey($0, account: KeychainStore.compatibleAccount)
            }
            modelRow("Model", text: $settings.compatibleModel) {
                guard let url = URL(string: settings.compatibleURL) else { throw AIError.invalidResponse }
                return try await OpenAICompatibleModel.listModels(
                    baseURL: url,
                    apiKey: KeychainStore.read(KeychainStore.compatibleAccount),
                    provider: "The endpoint"
                )
            }
            Text("Any server that speaks the OpenAI chat API, such as LM Studio, llama.cpp, or OpenAI itself. Use a localhost address to keep everything on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .openRouter:
            keyRow("OpenRouter API key", text: $openRouterKey, stored: store.hasOpenRouterKey) {
                store.saveAPIKey($0, account: KeychainStore.openRouterAccount)
            }
            modelRow("Model", text: $settings.openRouterModel) {
                try await OpenAICompatibleModel.listModels(
                    baseURL: AIEndpoints.openRouter,
                    apiKey: nil,
                    provider: "OpenRouter"
                )
            }
            Text("The key lives in your Keychain, not in the data folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func keyRow(_ title: String, text: Binding<String>, stored: Bool, save: @escaping (String) -> Void) -> some View {
        Group {
            HStack {
                SecureField(title, text: text)
                Button("Save") {
                    save(text.wrappedValue)
                    text.wrappedValue = ""
                }
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if stored {
                HStack {
                    Label("Key saved in your Keychain", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Remove") { save("") }
                }
                .font(.caption)
            }
        }
    }

    private func modelRow(_ placeholder: String, text: Binding<String>, load: @escaping () async throws -> [ModelOption]) -> some View {
        HStack {
            TextField(placeholder, text: text)
            Button("Browse…") { browsing = true }
                .popover(isPresented: $browsing) {
                    ModelPicker(selection: text, isPresented: $browsing, load: load)
                }
        }
    }
}

private struct ModelPicker: View {
    @Binding var selection: String
    @Binding var isPresented: Bool
    let load: () async throws -> [ModelOption]

    @State private var models: [ModelOption] = []
    @State private var query = ""
    @State private var loading = true
    @State private var failed = false

    private var filtered: [ModelOption] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return models }
        return models.filter { $0.id.lowercased().contains(text) || $0.name.lowercased().contains(text) }
    }

    var body: some View {
        VStack(spacing: 10) {
            TextField("Search models", text: $query)
                .textFieldStyle(.roundedBorder)

            if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else if failed {
                Text("Couldn't load the model list. Type a model name instead.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                List(filtered) { model in
                    Button {
                        selection = model.id
                        isPresented = false
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.name).lineLimit(1)
                            Text(model.id)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 300)
            }
        }
        .padding(14)
        .frame(width: 380)
        .task {
            do {
                models = try await load()
            } catch {
                failed = true
            }
            loading = false
        }
    }
}
