import AVFoundation

/// Verdrahtet Audio, Netzwerk und Steuerport. Läuft komplett auf `funkQueue`.
/// Nach außen gibt es nur Einstellungen rein und Status raus.
final class FunkCore {
    private let audio = AudioEngine()
    private let link = PeerLink()
    private let control = ControlServer()

    private var settings = FunkSettings()
    private var hotkeyDown = false
    private var talking = false
    private var status = FunkStatus()
    private var partnerWasTalking = false
    private var testTimer: DispatchSourceTimer?

    /// Wird auf der Main-Queue aufgerufen.
    var onStatus: ((FunkStatus) -> Void)?

    func start(with initial: FunkSettings) {
        funkQueue.async { [self] in
            audio.setup()
            audio.keepAlive = { [weak self] in self?.talking ?? false }
            audio.onPacket = { [weak self] pcm in self?.link.sendAudio(pcm) }
            link.onAudio = { [weak self] pcm in
                guard let self, !self.settings.muted else { return }
                self.audio.play(pcm)
            }
            control.onChange = { [weak self] in self?.updateTalking() }
            applyOnQueue(initial)

            link.start()
            control.start()
            tick()
            note("Funk läuft als \(link.myName)")
        }
    }

    // MARK: Eingaben

    func apply(_ s: FunkSettings) {
        funkQueue.async { self.applyOnQueue(s) }
    }

    func setHotkey(down: Bool) {
        funkQueue.async {
            self.hotkeyDown = down
            self.updateTalking()
        }
    }

    func playTestLocally() {
        funkQueue.async { self.audio.playEffect(Tones.test) }
    }

    /// Schickt den Test-Ton in Echtzeit (10-ms-Takt) an den Partner.
    /// Alles auf einmal zu senden würde dessen Jitter-Puffer überlaufen lassen.
    func sendTestToPartner() {
        funkQueue.async { [self] in
            testTimer?.cancel()
            var packets = Tones.packets(Tones.test)[...]
            let t = DispatchSource.makeTimerSource(queue: funkQueue)
            t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in
                guard let self, let p = packets.popFirst() else {
                    self?.testTimer?.cancel()
                    self?.testTimer = nil
                    return
                }
                self.link.sendAudio(p)
            }
            testTimer = t
            t.resume()
        }
    }

    // MARK: Intern (funkQueue)

    private func applyOnQueue(_ s: FunkSettings) {
        settings = s
        audio.volume = s.volume
        audio.setDucking(s.ducking)
        if link.muted != s.muted {
            link.muted = s.muted
            link.sendStatus()
        }
        tick(reschedule: false)
    }

    private func updateTalking() {
        let on = control.talking || hotkeyDown
        if on != talking {
            talking = on
            note(on ? "Sende" : "Senden beendet")
            link.talking = on
            link.sendStatus()                   // sofort, damit der Piep drüben vor der Stimme kommt
            audio.sendEnabled.value = on
            if on { audio.touch() }
        }
        tick(reschedule: false)
    }

    private func tick(reschedule: Bool = true) {
        let partner = link.partner
        var s = FunkStatus()
        s.partnerName = partner?.name
        s.partnerMuted = partner?.muted ?? false
        s.sending = talking
        s.receiving = link.receiving
        s.muted = settings.muted
        s.pluginConnected = control.connected

        // Funk-Piep, sobald der Partner die Taste drückt (Statuspaket kommt vor dem Audio).
        let partnerTalking = partner?.talking ?? false
        if partnerTalking && !partnerWasTalking && settings.receiveBeep && !settings.muted {
            audio.playEffect(Tones.receiveBeep)
        }
        partnerWasTalking = partnerTalking

        if s != status {
            status = s
            control.broadcast(s.pluginPayload)
            DispatchQueue.main.async { [weak self] in self?.onStatus?(s) }
        }
        if reschedule {
            funkQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.tick() }
        }
    }
}
