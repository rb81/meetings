import SwiftUI

enum ModelInfo {
    static let source = "Downloaded once from Hugging Face: FluidInference's Core ML build of NVIDIA Parakeet TDT 0.6B v3 (CC BY 4.0), plus voice-detection and speaker-separation models, including NVIDIA Nemotron 3 Diarization (OpenMDW) and CAM++ voice prints for in-person meetings. Everything runs on this Mac and is saved in your data folder."
}

struct ModelSetupCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        switch store.models.state {
        case .loading:
            EmptyView()
        case .ready:
            if let missing = store.models.missingSpeakerModels {
                let busy = store.models.isDownloadingRoomModels
                card {
                    header(
                        "Download \(missing)",
                        "Without \(missing), in-person meetings can't tell voices apart. It's a one-time download."
                    )
                    if let issue = store.models.liveSpeakerIssue ?? store.models.speakerModelIssue {
                        Text("The last attempt failed: \(issue)")
                            .font(Theme.caption)
                            .foregroundStyle(Theme.amber)
                    }
                    Button(busy ? "Downloading…" : "Download") { store.models.downloadMissingSpeakerModels() }
                        .buttonStyle(PrimaryButtonStyle(height: 38))
                        .disabled(busy)
                }
            }
        case .notDownloaded:
            card {
                header("Set up live transcription", "Download the speech model to transcribe meetings as you record.")
                Button("Download Model") { store.models.prepare() }
                    .buttonStyle(PrimaryButtonStyle(height: 38))
            }
        case .working(let progress, let detail):
            card {
                header("Getting the speech model ready", detail)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.blue)
            }
        case .failed(let message):
            card {
                header("The speech model isn't ready", message)
                Button("Repair (Download Again)") { store.models.prepare() }
                    .buttonStyle(PrimaryButtonStyle(height: 38))
            }
        }
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.heading)
            Text(subtitle)
                .font(Theme.body)
                .foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 14) {
                content()
                Text(ModelInfo.source)
                    .font(Theme.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .surface(padding: 20)
    }
}
