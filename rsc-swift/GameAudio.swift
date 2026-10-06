import AVFoundation

/// Plays the client's 8kHz mono sound effects. Like the SDL client, a new
/// sound interrupts whatever is currently playing.
final class GameAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "rsc.audio")
    private var format: AVAudioFormat?

    func play(_ samples: [Int16], sampleRate: Double) {
        queue.async { [self] in
            guard prepare(sampleRate: sampleRate), let format,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
            else { return }

            buffer.frameLength = buffer.frameCapacity

            let channel = buffer.floatChannelData![0]
            for (i, sample) in samples.enumerated() {
                channel[i] = Float(sample) / Float(Int16.max)
            }

            player.scheduleBuffer(buffer, at: nil, options: .interrupts)

            if !player.isPlaying {
                player.play()
            }
        }
    }

    private func prepare(sampleRate: Double) -> Bool {
        if format == nil {
            // mix with music from other apps rather than stopping it, and
            // respect the silent switch
            try? AVAudioSession.sharedInstance().setCategory(.ambient)

            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }

        // the engine stops after interruptions such as phone calls
        if !engine.isRunning {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
            } catch {
                return false
            }
        }

        return true
    }
}
