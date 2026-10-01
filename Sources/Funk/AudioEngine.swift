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
    private var monoFormat: AVAudioFormat?
    private var sendAccum = Data()
    let sendEnabled = AtomicFlag()

    // Diagnose (funkQueue): pro Sende- bzw. Empfangsphase gezählt, beim Ende geloggt
    private var sentPackets = 0
    private var sentPeak: Float = 0
    private var receivedPackets = 0

    /// Wie die Engine betrieben wird. Voice Processing scheitert unter macOS, wenn Ein- und
    /// Ausgabegerät nicht zusammenpassen (z. B. AirPods-Mikro + MacBook-Lautsprecher, Fehler -10875).
    /// Dann fallen wir stufenweise zurück, statt stumm zu bleiben.
    enum Mode: String {
        case voiceProcessing          // normal: Echo Cancellation + Ducking
        case voiceProcessingMatched   // VP, Ausgabeformat ans Eingangsformat angeglichen
        case plain                    // ohne VP: Ton geht, aber kein Echo-Schutz, kein Ducking
    }

    // funkQueue
    private(set) var mode: Mode = .voiceProcessing
    private(set) var failed = false               // auch der letzte Rückfall hat nicht geklappt
    private var ignoreConfigChangesUntil = Date.distantPast
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
        setVoiceProcessing(true)
        wireGraph()
    }

    /// VP an- oder ausschalten. Das löst selbst eine Konfigurationsänderung aus, die wir
    /// kurz ignorieren, sonst würde configurationChanged() den Rückfall gleich wieder zurücksetzen.
    private func setVoiceProcessing(_ on: Bool) {
        let input = engine.inputNode
        guard input.isVoiceProcessingEnabled != on else { if on { applyDucking() }; return }
        ignoreConfigChangesUntil = Date().addingTimeInterval(1)
        do {
            try input.setVoiceProcessingEnabled(on)
            note("Voice Processing \(on ? "an" : "aus")")
        } catch {
            warn("Voice Processing \(on ? "an" : "aus") fehlgeschlagen: \(error)")
        }
        if on { applyDucking() }
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
        guard engine.inputNode.isVoiceProcessingEnabled else { return }
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
        engine.disconnectNodeInput(engine.outputNode)
        if mode == .voiceProcessingMatched, inFormat.sampleRate > 0 {
            // VP verlangt gleiche Client-Formate für Ein- und Ausgabe.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: inFormat)
        } else {
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        }
        note("Modus \(mode.rawValue), Eingang: \(inFormat), Ausgang: \(engine.outputNode.outputFormat(forBus: 0))")
        converter = nil
        monoFormat = nil
        sendAccum.removeAll()
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            // Ohne Mikrofonfreigabe oder Eingabegerät. installTap würde hier abstürzen.
            warn("Kein nutzbares Eingabegerät, Senden nicht möglich")
            engine.prepare()
            return
        }
        // Mit Voice Processing meldet macOS teils ein Format mit den Kanälen ALLER Eingabegeräte
        // (z. B. 9 Kanäle). Welcher davon das Mikro ist, wissen wir nicht. Deshalb erst alle
        // Kanäle zu Mono summieren, dann resamplen. Ein Konverter N->1 nähme nur Kanal 0.
        let mono = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1)!
        monoFormat = mono
        converter = AVAudioConverter(from: mono, to: wireFormat)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(Funk.packetFrames), format: inFormat) { [weak self] buf, _ in
            self?.captured(buf)
        }
        engine.prepare()
    }

    private func configurationChanged() {
        guard Date() >= ignoreConfigChangesUntil else { return }
        note("Audiogeräte geändert, versuche es wieder mit Voice Processing")
        let wasRunning = running
        stop()
        mode = .voiceProcessing          // neue Geräte, neue Chance
        failed = false
        setVoiceProcessing(true)
        wireGraph()
        if wasRunning || keepAlive() { touch() }
    }

    // MARK: Aufnahme (Tap-Thread)

    private func captured(_ buf: AVAudioPCMBuffer) {
        guard sendEnabled.value, let conv = converter, let mono = downmix(buf) else {
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
            return mono.buffer
        }
        guard status != .error, err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }

        sendAccum.append(Data(bytes: ch[0], count: Int(out.frameLength) * 2))
        let packetBytes = Funk.packetFrames * 2
        let peak = mono.peak
        while sendAccum.count >= packetBytes {
            let chunk = Data(sendAccum.prefix(packetBytes))
            sendAccum.removeFirst(packetBytes)
            funkQueue.async { [weak self] in
                guard let self else { return }
                self.lastActivity = Date()
                self.sentPackets += 1
                self.sentPeak = max(self.sentPeak, peak)
                self.onPacket?(chunk)
            }
        }
    }

    /// Alle Kanäle zu Mono summieren (nicht mitteln: stille Kanäle sollen das Mikro nicht leiser machen).
    private func downmix(_ buf: AVAudioPCMBuffer) -> (buffer: AVAudioPCMBuffer, peak: Float)? {
        guard let mono = monoFormat, let src = buf.floatChannelData, buf.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buf.frameLength),
              let dst = out.floatChannelData?[0] else { return nil }
        let n = Int(buf.frameLength)
        let channels = Int(buf.format.channelCount)
        let stride = buf.format.isInterleaved ? channels : 1
        out.frameLength = buf.frameLength
        var peak: Float = 0
        for i in 0..<n {
            var s: Float = 0
            for c in 0..<channels {
                s += buf.format.isInterleaved ? src[0][i * stride + c] : src[c][i]
            }
            s = max(-1, min(1, s))
            dst[i] = s
            peak = max(peak, abs(s))
        }
        return (out, peak)
    }

    /// Diagnose nach einer Sendung: Pakete und Spitzenpegel seit dem letzten Aufruf.
    func sendReport() -> String {
        defer { sentPackets = 0; sentPeak = 0 }
        let db = sentPeak > 0 ? String(format: "%.0f dBFS", 20 * log10(sentPeak)) : "stumm"
        return "\(sentPackets) Pakete gesendet, Spitze \(db)"
    }

    // MARK: Lebenszyklus (funkQueue)

    func touch() {
        lastActivity = Date()
        guard !running else { return }
        if tryStart() { return }
        ignoreConfigChangesUntil = Date().addingTimeInterval(1)   // fehlgeschlagene Starts melden auch Änderungen

        // Rückfallkette. Ein Modus, der einmal geklappt hat, bleibt bis zum nächsten Gerätewechsel.
        if mode == .voiceProcessing {
            mode = .voiceProcessingMatched
            wireGraph()
            if tryStart() { return }
        }
        if mode == .voiceProcessingMatched {
            mode = .plain
            setVoiceProcessing(false)
            wireGraph()
            if tryStart() { return }
        }
        failed = true
    }

    private func tryStart() -> Bool {
        do {
            try engine.start()
            voice.play()
            effects.play()
            running = true
            failed = false
            note("Engine an (Modus \(mode.rawValue))")
            scheduleIdleCheck()
            return true
        } catch {
            warn("Engine-Start fehlgeschlagen (Modus \(mode.rawValue)): \(error)")
            engine.stop()
            return false
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
        if receivedPackets > 0 {
            note("\(receivedPackets) Pakete empfangen und abgespielt")
            receivedPackets = 0
        }
    }

    // MARK: Wiedergabe (funkQueue)

    func play(_ pcm: Data) {
        touch()
        guard running, queuedFrames <= maxQueuedFrames else { return }
        receivedPackets += 1
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
