import Foundation
import os

/// Thread-safe peak levels for the two tracks. Written from audio threads, read by the UI.
final class LevelMeter: @unchecked Sendable {
    private let mic = OSAllocatedUnfairLock(initialState: Float(0))
    private let system = OSAllocatedUnfairLock(initialState: Float(0))

    func update(_ track: AudioTrack, samples: [Float]) {
        guard !samples.isEmpty else { return }

        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        let decibels = 20 * log10(max(rms, 1e-6))
        let level = max(0, min(1, (decibels + 55) / 55))

        lock(for: track).withLock { $0 = max($0, level) }
    }

    /// Returns the current level, then lets it fall so the meter eases back down.
    func read(_ track: AudioTrack) -> Float {
        lock(for: track).withLock { value in
            let current = value
            value *= 0.8
            return current
        }
    }

    func reset() {
        mic.withLock { $0 = 0 }
        system.withLock { $0 = 0 }
    }

    private func lock(for track: AudioTrack) -> OSAllocatedUnfairLock<Float> {
        track == .mic ? mic : system
    }
}
