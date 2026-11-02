import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

enum AudioLevel {
    static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// Lifts quiet, distant voices to a level the speech models handle well, which matters in a room where nobody
/// is close to the microphone. One instance per track, used from one thread.
///
/// The gain follows the level of speech slowly, so voices aren't pumped up and down within a sentence, and loud
/// peaks are rounded off instead of clipped. Both matter to the speaker model, which compares how voices sound.
/// Room noise and silence are never counted, so they are never amplified either.
final class AutoGain: @unchecked Sendable {
    static let targetLevel: Float = 0.06
    static let maxGain: Float = 12
    /// Used to judge a whole recording. Anything quieter is treated as silence.
    static let noiseFloor: Float = 0.0015
    /// Live audio must be at least this loud to count as speech when setting the gain.
    static let speechFloor: Float = 0.004

    private static let ceiling: Float = 0.8

    private var level: Float = 0
    private var gain: Float = 1

    func apply(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }

        let rms = AudioLevel.rms(samples)
        if rms > Self.speechFloor {
            if level == 0 {
                level = rms
                gain = Self.gain(for: rms)
            } else {
                level += (rms - level) * (rms > level ? 0.15 : 0.01)
                gain += (Self.gain(for: level) - gain) * 0.1
            }
        }
        guard gain > 1.05 else { return samples }
        return samples.map { Self.soften($0 * gain) }
    }

    private static func gain(for level: Float) -> Float {
        min(maxGain, max(1, targetLevel / level))
    }

    /// Keeps peaks under 1 with a gentle curve rather than a hard clip.
    private static func soften(_ value: Float) -> Float {
        let size = abs(value)
        guard size > ceiling else { return value }
        let headroom = 1 - ceiling
        let softened = ceiling + headroom * tanh((size - ceiling) / headroom)
        return value < 0 ? -softened : softened
    }
}

enum AudioNormalizer {
    /// Scales a whole recording so its speech sits at a healthy level. Used before the final speaker pass.
    static func normalized(_ samples: [Float]) -> [Float] {
        let window = 1_600
        var levels: [Float] = []
        var index = 0
        while index < samples.count {
            let end = min(index + window, samples.count)
            levels.append(AudioLevel.rms(samples[index..<end]))
            index = end
        }

        let speech = levels.filter { $0 > AutoGain.noiseFloor }.sorted()
        guard speech.count >= 10 else { return samples }

        let reference = speech[Int(Double(speech.count - 1) * 0.9)]
        let gain = min(AutoGain.maxGain, max(1, AutoGain.targetLevel / reference))
        guard gain > 1.05 else { return samples }
        return samples.map { max(-1, min(1, $0 * gain)) }
    }
}

enum AudioFileSamples {
    /// Reads a recording as 16 kHz mono samples.
    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let resampler = StreamResampler()
        let chunkFrames = AVAudioFrameCount(format.sampleRate)

        var result: [Float] = []
        result.reserveCapacity(Int(Double(file.length) / format.sampleRate * 16_000))

        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            try file.read(into: buffer, frameCount: chunkFrames)
            if buffer.frameLength == 0 { break }
            result.append(contentsOf: resampler.convert(buffer))
        }
        return result
    }
}

// MARK: - Microphones

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    /// The CoreAudio device UID, which stays the same between launches.
    let id: String
    let name: String
    let isBuiltIn: Bool
    /// Bluetooth microphones sit next to one person's mouth, so they miss everyone else in a room.
    let isHeadset: Bool
}

enum AudioInput {
    struct Selection {
        var uid: String?
        var note: String?
    }

    static let automatic = "auto"
    static let systemDefault = "default"

    static func devices() -> [AudioInputDevice] {
        deviceIDs().compactMap(device)
    }

    static var defaultDevice: AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return device(id)
    }

    /// Picks the microphone for an in-person meeting. Automatic avoids a headset's microphone.
    static func resolveInPerson(_ choice: String) -> Selection {
        let all = devices()
        if choice != automatic, choice != systemDefault, all.contains(where: { $0.id == choice }) {
            return Selection(uid: choice, note: nil)
        }

        let current = defaultDevice
        if choice == systemDefault {
            guard let current, current.isHeadset else { return Selection() }
            return Selection(
                uid: nil,
                note: "The microphone in use is a headset (\(current.name)). It mostly hears the person wearing it, so other people in the room may be missing. Choose the built-in microphone in Settings."
            )
        }

        if current?.isHeadset == true, let builtIn = all.first(where: \.isBuiltIn) {
            return Selection(uid: builtIn.id, note: nil)
        }
        return Selection()
    }

    /// Points the engine's input at a specific device. Call before reading the input format.
    static func select(_ uid: String, on engine: AVAudioEngine) throws {
        guard var id = deviceID(forUID: uid), let unit = engine.inputNode.audioUnit else {
            throw RecorderError.noInputDevice
        }
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw RecorderError.noInputDevice }
    }

    // MARK: Core Audio

    private static func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func device(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }

        let transport = uint32(id, kAudioDevicePropertyTransportType)
        if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual {
            return nil
        }

        return AudioInputDevice(
            id: uid,
            name: string(id, kAudioObjectPropertyName) ?? "Microphone",
            isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
            isHeadset: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        )
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
