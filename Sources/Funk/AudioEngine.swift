import AVFoundation

/// Mikrofon und Lautsprecher über Apples Voice Processing.
///
/// Warum Voice Processing: Es liefert Echo Cancellation (Vollduplex über Lautsprecher),
/// Rauschunterdrückung und das Absenken anderer Apps (Ducking) als Systemfunktion.
/// Das Ducking wirkt, solange die Engine läuft. Deshalb läuft sie nur bei Aktivität
/// und geht nach `Funk.hangTime` Ruhe wieder aus.
///
/// Threading: alles auf `funkQueue`, außer `captured(_:)`, das im Tap-Thread läuft.
final class AudioEngine {
    private let engine = AVAudioEngine()
    private let voice = AVAudioPlayerNode()       // Stimme vom Partner
    private let effects = AVAudioPlayerNode()     // Piep und Test-Ton, getrennt vom Jitter-Puffer
    private let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Funk.sampleRate,
                                           channels: 1, interleaved: true)!
    private let playFormat = AVAudioFormat(standardFormatWithSampleRate: Funk.sampleRate, channels: 1)!

    private let leadInFrames: AVAudioFrameCount = 960       // 20 ms Stille vor jedem Sprachstoß = Jitter-Puffer
    private let maxQueuedFrames: AVAudioFrameCount = 9_600  // > 200 ms gepuffert: verwerfen, Latenz bleibt klein

    // Tap-Thread
    private var converter: AVAudioConverter?
    private var sendAccum = Data()
    let sendEnabled = AtomicFlag()

    // funkQueue
    private(set) var running = false
    private var queuedFrames: AVAudioFrameCount = 0
    private var lastActivity = Date.distantPast
    private var ducking: DuckingLevel = .medium
    var keepAlive: () -> Bool = { false }
    var onPacket: ((Data) -> Void)?

    init() {
        engine.attach(voice)
        engine.attach(effects)
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: engine, queue: nil) { [weak self] _ in
            funkQueue.async { self?.configurationChanged() }
        }
    }

    func setup() {
        do {
            let input = engine.inputNode
            if !input.isVoiceProcessingEnabled { try input.setVoiceProcessingEnabled(true) }
        } catch {
            warn("Voice Processing nicht verfügbar: \(error)")
        }
        applyDucking()
        wireGraph()
    }

    // MARK: Einstellungen

    var volume: Float {
        get { voice.volume }
        set { voice.volume = newValue; effects.volume = newValue }
    }

    func setDucking(_ level: DuckingLevel) {
        ducking = level
        applyDucking()
    }

    private func applyDucking() {
        var cfg = engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration
        cfg.enableAdvancedDucking = false
        switch ducking {
        case .light: cfg.duckingLevel = .min
        case .medium: cfg.duckingLevel = .mid
        case .strong: cfg.duckingLevel = .max
        }
        engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = cfg
    }

    // MARK: Graph

    /// Verbindungen und Tap (neu) aufbauen. Nötig nach jedem Gerätewechsel,
    /// weil sich das Eingangsformat ändern kann (z. B. Kopfhörer eingesteckt).
    private func wireGraph() {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.disconnectNodeOutput(voice)
        engine.disconnectNodeOutput(effects)
        engine.connect(voice, to: engine.mainMixerNode, format: playFormat)
        engine.connect(effects, to: engine.mainMixerNode, format: playFormat)

        let inFormat = input.outputFormat(forBus: 0)
        note("Eingang: \(inFormat)")
        converter = nil
        sendAccum.removeAll()
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            // Ohne Mikrofonfreigabe oder Eingabegerät. installTap würde hier abstürzen.
            warn("Kein nutzbares Eingabegerät, Senden nicht möglich")
            engine.prepare()
            return
        }
        converter = AVAudioConverter(from: inFormat, to: wireFormat)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(Funk.packetFrames), format: inFormat) { [weak self] buf, _ in
            self?.captured(buf)
        }
        engine.prepare()
    }

    private func configurationChanged() {
        note("Audiogeräte geändert, baue Engine neu auf")
        let wasRunning = running
        stop()
        wireGraph()
        if wasRunning || keepAlive() { touch() }
    }

    // MARK: Aufnahme (Tap-Thread)

    private func captured(_ buf: AVAudioPCMBuffer) {
        guard sendEnabled.value, let conv = converter else {
            if !sendAccum.isEmpty { sendAccum.removeAll() }
            return
        }
        let ratio = wireFormat.sampleRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: capacity) else { return }

        var fed = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true
            inStatus.pointee = .haveData
            return buf
        }
        guard status != .error, err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }

        sendAccum.append(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
        let packetBytes = Funk.packetFrames * 2
        while sendAccum.count >= packetBytes {
            let chunk = Data(sendAccum.prefix(packetBytes))
            sendAccum.removeFirst(packetBytes)
            funkQueue.async { [weak self] in
                self?.lastActivity = Date()
                self?.onPacket?(chunk)
            }
        }
    }

    // MARK: Lebenszyklus (funkQueue)

    func touch() {
        lastActivity = Date()
        guard !running else { return }
        do {
            try engine.start()
            voice.play()
            effects.play()
            running = true
            note("Engine an")
            scheduleIdleCheck()
        } catch {
            warn("Engine-Start fehlgeschlagen: \(error)")
        }
    }

    private func scheduleIdleCheck() {
        funkQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.running else { return }
            if !self.keepAlive() && Date().timeIntervalSince(self.lastActivity) > Funk.hangTime {
                self.stop()
                note("Engine aus")
            } else {
                self.scheduleIdleCheck()
            }
        }
    }

    private func stop() {
        voice.stop()
        effects.stop()
        engine.stop()
        running = false
        queuedFrames = 0
    }

    // MARK: Wiedergabe (funkQueue)

    func play(_ pcm: Data) {
        touch()
        guard running, queuedFrames <= maxQueuedFrames else { return }
        if queuedFrames == 0, let lead = silence(leadInFrames) { scheduleVoice(lead) }

        let n = pcm.count / 2
        guard n > 0, let b = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(n)),
              let dst = b.floatChannelData?[0] else { return }
        b.frameLength = AVAudioFrameCount(n)
        pcm.withUnsafeBytes { raw in
            for i in 0..<n {
                let s = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                dst[i] = Float(s) / 32768
            }
        }
        scheduleVoice(b)
    }

    func playEffect(_ samples: [Float]) {
        touch()
        guard running, !samples.isEmpty,
              let b = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = b.floatChannelData?[0] else { return }
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            if let base = src.baseAddress { dst.update(from: base, count: samples.count) }
        }
        effects.scheduleBuffer(b)
        lastActivity = Date().addingTimeInterval(Double(samples.count) / Funk.sampleRate)
    }

    private func silence(_ frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: frames) else { return nil }
        b.frameLength = frames
        b.floatChannelData?[0].update(repeating: 0, count: Int(frames))
        return b
    }

    private func scheduleVoice(_ b: AVAudioPCMBuffer) {
        let n = b.frameLength
        queuedFrames += n
        voice.scheduleBuffer(b) { [weak self] in
            funkQueue.async {
                guard let self else { return }
                self.queuedFrames -= min(self.queuedFrames, n)
            }
        }
    }
}
