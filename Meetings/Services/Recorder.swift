import AVFoundation
import CoreAudio
import CoreMedia
import Observation
import os
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case microphoneDenied
    case noInputDevice
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
        case .noInputDevice:
            "No microphone is available."
        case .noDisplay:
            "No display is available for system audio capture."
        }
    }
}

typealias AudioHandler = @Sendable (AudioTrack, [Float]) -> Void

/// Time spent recording, not counting pauses. Transcript times, flags, and the audio files all use this clock,
/// so they stay lined up however often a meeting is paused.
final class RecordingClock: @unchecked Sendable {
    private struct State {
        var startedAt: Date?
        var pausedAt: Date?
        var pausedTotal: TimeInterval = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func start() {
        state.withLock { $0 = State(startedAt: .now) }
    }

    func reset() {
        state.withLock { $0 = State() }
    }

    func pause() {
        state.withLock { value in
            if value.startedAt != nil, value.pausedAt == nil { value.pausedAt = .now }
        }
    }

    func resume() {
        state.withLock { value in
            if let pausedAt = value.pausedAt {
                value.pausedTotal += Date.now.timeIntervalSince(pausedAt)
                value.pausedAt = nil
            }
        }
    }

    func elapsed(at date: Date = .now) -> TimeInterval {
        state.withLock { value in
            guard let startedAt = value.startedAt else { return 0 }
            let end = value.pausedAt ?? date
            return max(0, end.timeIntervalSince(startedAt) - value.pausedTotal)
        }
    }
}

/// Tells the audio threads to drop audio while a meeting is paused.
final class CaptureGate: @unchecked Sendable {
    private let paused = OSAllocatedUnfairLock(initialState: false)

    var isPaused: Bool {
        get { paused.withLock { $0 } }
        set { paused.withLock { $0 = newValue } }
    }
}

@MainActor
@Observable
final class Recorder {
    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var startedAt: Date?
    private(set) var warning: String?

    let clock = RecordingClock()
    private let session = CaptureSession()

    /// Seconds recorded so far, not counting pauses.
    func elapsed(at date: Date = .now) -> TimeInterval {
        clock.elapsed(at: date)
    }

    /// `onAudio` receives 16 kHz mono samples for each track while recording.
    func start(
        into folder: URL,
        echoCancellation: Bool,
        microphone: AudioInput.Selection = AudioInput.Selection(),
        captureSystemAudio: Bool = true,
        onAudio: AudioHandler?
    ) async throws {
        clock.start()
        do {
            warning = try await session.start(
                into: folder,
                echoCancellation: echoCancellation,
                microphone: microphone,
                captureSystemAudio: captureSystemAudio,
                onAudio: onAudio
            )
        } catch {
            clock.reset()
            throw error
        }
        startedAt = .now
        isPaused = false
        isRecording = true
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        session.setPaused(true)
        clock.pause()
        isPaused = true
    }

    func resume() {
        guard isRecording, isPaused else { return }
        clock.resume()
        session.setPaused(false)
        isPaused = false
    }

    func stop() async {
        await session.stop()
        clock.reset()
        isRecording = false
        isPaused = false
        startedAt = nil
        warning = nil
    }

    #if DEBUG
    func setPreviewRecording() {
        isRecording = true
        startedAt = .now.addingTimeInterval(-754)
        clock.start()
    }
    #endif
}

/// Owns the audio engine and ScreenCaptureKit stream. Runs off the main actor.
final class CaptureSession: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var stream: SCStream?
    private var micWriter: AudioFileWriter?
    private var systemWriter: SystemAudioWriter?
    private let gate = CaptureGate()
    private let log = Logger(subsystem: "com.rakan.Meetings", category: "recording")

    func setPaused(_ paused: Bool) {
        gate.isPaused = paused
    }

    /// Returns a warning when something couldn't be set up but recording can continue.
    func start(
        into folder: URL,
        echoCancellation: Bool,
        microphone: AudioInput.Selection,
        captureSystemAudio: Bool,
        onAudio: AudioHandler?
    ) async throws -> String? {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw RecorderError.microphoneDenied
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // A fresh engine each time, so a microphone or echo-cancellation choice never carries over to the next meeting.
        engine = AVAudioEngine()
        gate.isPaused = false

        var warnings: [String] = []
        if let note = microphone.note { warnings.append(note) }
        let micURL = folder.appendingPathComponent(MeetingStore.micFileName)

        let useEchoCancellation = echoCancellation && !AudioOutput.isHeadphones
        if echoCancellation, !useEchoCancellation {
            log.info("Headphones detected, skipping echo cancellation")
        }

        if useEchoCancellation {
            do {
                try startMic(into: micURL, voiceProcessing: true, deviceUID: nil, onAudio: onAudio)
            } catch {
                log.error("Echo cancellation unavailable: \(error.localizedDescription)")
                stopMic()
                engine = AVAudioEngine()
                try startMic(into: micURL, voiceProcessing: false, deviceUID: nil, onAudio: onAudio)
                warnings.append("Echo cancellation couldn't start, so headphones work best.")
            }
        } else {
            do {
                try startMic(into: micURL, voiceProcessing: false, deviceUID: microphone.uid, onAudio: onAudio)
            } catch RecorderError.noInputDevice where microphone.uid != nil {
                log.error("The chosen microphone couldn't be used, falling back to the system default")
                stopMic()
                engine = AVAudioEngine()
                try startMic(into: micURL, voiceProcessing: false, deviceUID: nil, onAudio: onAudio)
                warnings.append("The microphone you chose couldn't be used, so the system default is recording instead.")
            }
        }

        if captureSystemAudio {
            do {
                try await startSystemAudio(
                    into: folder.appendingPathComponent(MeetingStore.systemFileName),
                    onAudio: onAudio
                )
            } catch {
                warnings.append("Other participants aren't being captured. Allow Screen & System Audio Recording for Meetings in System Settings.")
            }
        }

        return warnings.isEmpty ? nil : warnings.joined(separator: " ")
    }

    func stop() async {
        stopMic()
        try? await stream?.stopCapture()
        stream = nil

        micWriter?.close()
        systemWriter?.close()
        micWriter = nil
        systemWriter = nil
        gate.isPaused = false
    }

    private func startMic(into url: URL, voiceProcessing: Bool, deviceUID: String?, onAudio: AudioHandler?) throws {
        if let deviceUID, !voiceProcessing {
            try AudioInput.select(deviceUID, on: engine)
        }

        let input = engine.inputNode

        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: true,
                duckingLevel: .min
            )
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw RecorderError.noInputDevice }

        let mic = AudioFileWriter(url: url)
        let resampler = StreamResampler()
        let gate = gate
        micWriter = mic

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if gate.isPaused { return }
            guard let source = voiceProcessing ? buffer.firstChannelCopy() : buffer.stereoCopy() else { return }
            mic.write(source)
            if let onAudio {
                onAudio(.mic, resampler.convert(source))
            }
        }
        engine.prepare()
        try engine.start()
    }

    private func stopMic() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }

    private func startSystemAudio(into url: URL, onAudio: AudioHandler?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let writer = SystemAudioWriter(url: url, gate: gate, onAudio: onAudio)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: DispatchQueue(label: "system-audio"))
        try await stream.startCapture()

        self.stream = stream
        systemWriter = writer
    }
}

/// Writes PCM buffers to an AAC `.m4a` file. The file is created from the first buffer's format.
final class AudioFileWriter: @unchecked Sendable {
    private let url: URL
    private var file: AVAudioFile?
    private var reportedFailure = false
    private let log = Logger(subsystem: "com.rakan.Meetings", category: "recording")

    init(url: URL) {
        self.url = url
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: Self.settings(for: buffer.format))
            }
            try file?.write(from: buffer)
        } catch {
            guard !reportedFailure else { return }
            reportedFailure = true
            log.error("Writing \(self.url.lastPathComponent) failed: \(error.localizedDescription)")
        }
    }

    func close() {
        file = nil
    }

    private static func settings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: min(format.channelCount, 2),
            AVEncoderBitRateKey: 96_000,
        ]
    }
}

final class SystemAudioWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: AudioFileWriter
    private let gate: CaptureGate
    private let onAudio: AudioHandler?
    private let resampler = StreamResampler()

    init(url: URL, gate: CaptureGate, onAudio: AudioHandler?) {
        writer = AudioFileWriter(url: url)
        self.gate = gate
        self.onAudio = onAudio
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, !gate.isPaused, let buffer = sampleBuffer.pcmBuffer() else { return }
        writer.write(buffer)
        if let onAudio {
            onAudio(.system, resampler.convert(buffer))
        }
    }

    func close() {
        writer.close()
    }
}

/// Converts audio buffers to 16 kHz mono Float32, the format the speech models expect.
/// Keeps one converter alive so consecutive buffers join without clicks. Use from a single thread.
final class StreamResampler: @unchecked Sendable {
    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        if converter == nil || sourceFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            sourceFormat = buffer.format
        }
        guard let converter else { return [] }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}

/// Reads whether the default output is headphones or a headset. When it is, the speakers can't reach the mic,
/// so echo cancellation isn't needed.
enum AudioOutput {
    private static let headphonesSource: UInt32 = 0x6864_706E // 'hdpn'

    static var isHeadphones: Bool {
        guard let device = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceID.self),
              device != kAudioObjectUnknown
        else { return false }

        if read(device, kAudioDevicePropertyTransportType, UInt32.self) == kAudioDeviceTransportTypeBuiltIn {
            let source = read(device, kAudioDevicePropertyDataSource, UInt32.self, scope: kAudioObjectPropertyScopeOutput)
            return source == headphonesSource
        }

        // Bluetooth and USB outputs with a mic input are headsets. Speakers, HDMI, and AirPlay have no input.
        return hasInputStreams(device)
    }

    private static func read<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _: T.Type,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer) == noErr else { return nil }
        return buffer.load(as: T.self)
    }

    private static func hasInputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }
}

private extension AVAudioPCMBuffer {
    /// Mixes more than two channels down to stereo, averaging the left and right groups. Two or fewer are returned as-is.
    func stereoCopy() -> AVAudioPCMBuffer? {
        guard format.channelCount > 2, let source = floatChannelData else { return self }
        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2),
              let copy = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: frameLength),
              let destination = copy.floatChannelData
        else { return nil }

        let channels = Int(format.channelCount)
        let leftCount = Float((channels + 1) / 2)
        let rightCount = Float(channels / 2)
        copy.frameLength = frameLength

        for frame in 0..<Int(frameLength) {
            var left: Float = 0
            var right: Float = 0
            for channel in 0..<channels {
                if channel % 2 == 0 {
                    left += source[channel][frame]
                } else {
                    right += source[channel][frame]
                }
            }
            destination[0][frame] = left / leftCount
            destination[1][frame] = right / rightCount
        }
        return copy
    }

    /// Voice processing can report several input channels. The first one carries the cleaned microphone signal.
    func firstChannelCopy() -> AVAudioPCMBuffer? {
        guard format.channelCount > 1, let source = floatChannelData else { return self }
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 1),
              let copy = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameLength),
              let destination = copy.floatChannelData
        else { return nil }

        copy.frameLength = frameLength
        memcpy(destination[0], source[0], Int(frameLength) * MemoryLayout<Float>.size)
        return copy
    }
}

private extension CMSampleBuffer {
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard
            let description = CMSampleBufferGetFormatDescription(self),
            let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
            let format = AVAudioFormat(streamDescription: streamDescription)
        else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
