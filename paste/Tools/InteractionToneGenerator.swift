import AVFoundation

final class InteractionToneGenerator {
    static let shared = InteractionToneGenerator()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

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
            let envelope = 1.0 - Float(i) / total
            channel[i] = sinf(2.0 * .pi * Float(frequency) * t) * envelope * volume
        }

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
