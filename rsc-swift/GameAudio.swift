import AVFoundation

/// Plays the client's 8kHz mono sound effects. Like the SDL client, a new
/// sound interrupts whatever is currently playing.
///
/// It can also keep the app running in the background (Settings > RSC >
/// Stay connected in the background) by playing silence, which iOS allows
/// for apps with the audio background mode. The silence mixes with other
/// apps, so music and picture in picture videos carry on as normal.
final class GameAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let silencePlayer = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "rsc.audio")
    private var format: AVAudioFormat?
    private var isSilenceAttached = false

    // only touched on `queue`
    private var isBackground = false
    private var isKeepingAlive = false

    init() {
        // calls, Siri and alarms stop all audio, including the silence
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self = self,
                  let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: value) == .ended
            else { return }

            self.queue.async {
                if self.isKeepingAlive {
                    self.startSilence()
                }
            }
        }

        // the engine stops itself when the audio route or the session's
        // category changes; the silence has to be started again
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }

            self.queue.async {
                if self.isKeepingAlive {
                    self.startSilence()
                }
            }
        }
    }

    func play(_ samples: [Int16], sampleRate: Double) {
        queue.async { [self] in
            // nobody's looking, and it would play over other apps' audio
            guard !isBackground else { return }

            guard prepare(sampleRate: sampleRate), let format = format,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
            else { return }

            buffer.frameLength = buffer.frameCapacity

            let channel = buffer.floatChannelData![0]
            for (i, sample) in samples.enumerated() {
                channel[i] = Float(sample) / Float(Int16.max)
            }

            player.scheduleBuffer(buffer, at: nil, options: .interrupts)

            if !player.isPlaying && engine.isRunning {
                player.play()
            }
        }
    }

    /// Mutes the game in the background and, if `keepAlive`, plays silence
    /// so iOS keeps the app (and the game's connection) running.
    func setBackground(_ background: Bool, keepAlive: Bool) {
        queue.async { [self] in
            isBackground = background

            if background && keepAlive {
                isKeepingAlive = true
                startSilence()
            } else if isKeepingAlive {
                isKeepingAlive = false
                stopSilence()
            }
        }
    }

    /// Lets iOS suspend the app again, e.g. once the player is logged out.
    func stopKeepingAlive() {
        setBackground(true, keepAlive: false)
    }

    // MARK: - Engine

    private func prepare(sampleRate: Double) -> Bool {
        if format == nil {
            // mix with music from other apps rather than stopping it, and
            // respect the silent switch
            if !isKeepingAlive {
                setCategory(.ambient)
            }

            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }

        return startEngine()
    }

    /// Changing the category under a running engine makes it stop a moment
    /// later, while still saying it's running, and a player started in
    /// between throws "player did not see an IO cycle" (an exception Swift
    /// can't catch). So the engine is stopped first, to be started again.
    private func setCategory(
        _ category: AVAudioSession.Category, options: AVAudioSession.CategoryOptions = []
    ) {
        let session = AVAudioSession.sharedInstance()
        guard session.category != category || session.categoryOptions != options else { return }

        engine.stop()
        try? session.setCategory(category, options: options)
    }

    /// The engine stops after interruptions such as phone calls.
    private func startEngine() -> Bool {
        guard !engine.isRunning else { return true }

        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Keeping alive

    private func startSilence() {
        // .ambient doesn't play in the background; .playback does, and
        // mixing keeps it from interrupting other apps or showing as Now
        // Playing. (It ignores the silent switch, but the game is muted.)
        setCategory(.playback, options: [.mixWithOthers])

        guard let silenceFormat = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1),
              let silence = AVAudioPCMBuffer(pcmFormat: silenceFormat, frameCapacity: 8000)
        else { return }

        // one second of zeros, looped
        silence.frameLength = silence.frameCapacity

        if !isSilenceAttached {
            engine.attach(silencePlayer)
            engine.connect(silencePlayer, to: engine.mainMixerNode, format: silenceFormat)
            isSilenceAttached = true
        }

        guard startEngine(), engine.isRunning else { return }

        silencePlayer.stop()
        silencePlayer.scheduleBuffer(silence, at: nil, options: .loops)
        silencePlayer.play()
    }

    private func stopSilence() {
        silencePlayer.stop()
        setCategory(.ambient)
    }
}
