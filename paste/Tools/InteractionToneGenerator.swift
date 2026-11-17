import AVFoundation

final class InteractionToneGenerator {
    static let shared = InteractionToneGenerator()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private let toneFormat: AVAudioFormat?

    private let queue = DispatchQueue(label: "com.clipen.tone")

    /// The engine used to be started for the first 50ms tone and then left
    /// running forever: an audio I/O thread rendering silence and the
    /// system's audio daemon kept busy for the rest of the session, after a
    /// single click sound. It now stops once the clicks have been quiet for
    /// a few seconds and restarts on the next one (a few ms).
    private var idleStop: DispatchWorkItem?
    private static let idleStopDelay: TimeInterval = 3

    private init() {
        toneFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)
        engine.attach(player)
        if let toneFormat {
            engine.connect(player, to: engine.mainMixerNode, format: toneFormat)
        }
        // Headphones/Bluetooth/sleep stop the engine and drop the player's
        // state. The next play() restarts it, but only once it knows it
        // stopped, and the player must be started again.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: nil) { [weak self] _ in
            self?.queue.async {
                self?.player.stop()
                self?.engine.stop()
            }
        }
    }

    func play(frequency: Double, duration: Double = 0.05, volume: Float = 0.45) {
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
            let envelope = 1.0 - Float(i) / total
            channel[i] = sinf(2.0 * .pi * Float(frequency) * t) * envelope * volume
        }

        queue.async { [self] in
            if !engine.isRunning {
                engine.prepare()
                do {
                    try engine.start()
                } catch {
                    return
                }
            }
            guard engine.isRunning else { return }

            player.scheduleBuffer(buffer, at: nil, options: .interrupts)
            // Not gated on isPlaying: after an output-device change the node
            // can still report playing while the restarted engine renders
            // nothing, which is how the tones went permanently silent.
            player.play()

            idleStop?.cancel()
            let stop = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.player.stop()
                self.engine.stop()
            }
            idleStop = stop
            queue.asyncAfter(deadline: .now() + Self.idleStopDelay, execute: stop)
        }
    }
}
