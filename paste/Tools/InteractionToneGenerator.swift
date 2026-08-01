import AVFoundation

/// Plays a short synthesized sine-wave tone — a true single "ping" with a
/// hard linear fade-out and no resonant tail, unlike every stock macOS
/// system sound (all of which ring down after the initial hit). Distinct
/// interaction gestures get distinct pitches from the same clean waveform.
final class InteractionToneGenerator {
    static let shared = InteractionToneGenerator()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// The player is connected with this exact format (not `nil`) so there's
    /// never a format mismatch between the connection and the buffers we
    /// schedule into it — that ambiguity is what crashed
    /// `scheduleBuffer(...)` with an NSException in practice.
    private let toneFormat: AVAudioFormat?

    private init() {
        toneFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        engine.attach(player)
        if let toneFormat {
            engine.connect(player, to: engine.mainMixerNode, format: toneFormat)
        }
    }

    func play(frequency: Double, duration: Double = 0.05, volume: Float = 0.3) {
        guard let toneFormat else { return }
        let frameCount = AVAudioFrameCount(toneFormat.sampleRate * duration)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: toneFormat, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount

        let sampleRate = Float(toneFormat.sampleRate)
        let channel = buffer.floatChannelData![0]
        let total = Float(frameCount)
        for i in 0..<Int(frameCount) {
            let t = Float(i) / sampleRate
            let envelope = 1.0 - Float(i) / total   // straight fade-out, no ring
            channel[i] = sinf(2.0 * .pi * Float(frequency) * t) * envelope * volume
        }

        // Only ever schedule/play once the engine has actually confirmed it's
        // running — `try?` on its own discards a thrown startup failure
        // (missing/changed audio route, sandbox hiccup, etc.) while letting
        // execution continue as if it succeeded, which is exactly what led
        // to scheduleBuffer being called on a non-running engine and crashing.
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                return
            }
        }
        guard engine.isRunning else { return }

        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }
}
