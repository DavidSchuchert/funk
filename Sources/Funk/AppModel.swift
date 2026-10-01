import AppKit
import AVFoundation
import ServiceManagement

/// Brücke zwischen SwiftUI und dem Kern. Hält die Einstellungen (UserDefaults)
/// und den zuletzt gemeldeten Status.
@MainActor
final class AppModel: ObservableObject {
    private enum Key {
        static let muted = "muted", volume = "volume", ducking = "ducking"
        static let receiveBeep = "receiveBeep", hotkey = "hotkey", didFirstRun = "didFirstRun"
    }

    @Published private(set) var status = FunkStatus()
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var micDenied = false

    @Published var muted: Bool { didSet { save(muted, Key.muted); push() } }
    @Published var volume: Double { didSet { save(volume, Key.volume); push() } }
    @Published var ducking: DuckingLevel { didSet { save(ducking.rawValue, Key.ducking); push() } }
    @Published var receiveBeep: Bool { didSet { save(receiveBeep, Key.receiveBeep); push() } }
    @Published var hotkey: HotKeyChoice { didSet { save(hotkey.rawValue, Key.hotkey); hotKey.register(hotkey) } }

    private let core = FunkCore()
    private let hotKey = HotKey()
    private let defaults = UserDefaults.standard
    private var activity: NSObjectProtocol?

    init() {
        let defaults = UserDefaults.standard   // lokal: self ist hier noch nicht vollständig initialisiert
        defaults.register(defaults: [
            Key.volume: 0.8, Key.ducking: DuckingLevel.medium.rawValue,
            Key.receiveBeep: true, Key.hotkey: HotKeyChoice.off.rawValue,
        ])
        muted = defaults.bool(forKey: Key.muted)
        volume = defaults.double(forKey: Key.volume)
        ducking = DuckingLevel(rawValue: defaults.integer(forKey: Key.ducking)) ?? .medium
        receiveBeep = defaults.bool(forKey: Key.receiveBeep)
        hotkey = HotKeyChoice(rawValue: defaults.string(forKey: Key.hotkey) ?? "") ?? .off

        // App Nap würde Timer und Netzwerk einer unsichtbaren App drosseln. Für ein
        // Funkgerät ist das tödlich, deshalb melden wir dauerhaft Aktivität an.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Funk wartet auf Durchsagen")

        core.onStatus = { [weak self] s in
            MainActor.assumeIsolated { self?.status = s }
        }
        hotKey.onChange = { [weak self] down in self?.core.setHotkey(down: down) }
        hotKey.register(hotkey)

        firstRunSetup()
        requestMicrophone()
    }

    // MARK: Aktionen

    func playTestLocally() { core.playTestLocally() }
    func sendTestToPartner() { core.sendTestToPartner() }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            warn("Login-Objekt: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func installStreamDeckPlugin() {
        guard let url = Bundle.main.url(forResource: "Funk", withExtension: "streamDeckPlugin") else {
            warn("Plugin nicht im App-Bundle gefunden")
            return
        }
        NSWorkspace.shared.open(url)          // Stream Deck übernimmt die Installation
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Außerhalb von /Applications (direkt aus dem DMG oder aus Downloads gestartet) verschiebt
    /// macOS die App in einen zufälligen Pfad (App Translocation). Dann klappt das Login-Objekt nicht.
    var isInApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: Intern

    private var settings: FunkSettings {
        FunkSettings(muted: muted, volume: Float(volume), ducking: ducking, receiveBeep: receiveBeep)
    }

    private func push() { core.apply(settings) }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }

    private func firstRunSetup() {
        guard !defaults.bool(forKey: Key.didFirstRun) else { return }
        defaults.set(true, forKey: Key.didFirstRun)
        setLaunchAtLogin(true)                // gewünscht: startet automatisch beim Login
    }

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.micDenied = !granted
                if !granted { warn("Mikrofon nicht freigegeben") }
                // Erst nach der Antwort starten: Ohne Freigabe liefert der Eingang ein leeres Format.
                self.core.start(with: self.settings)
            }
        }
    }
}
