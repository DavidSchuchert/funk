import SwiftUI

@main
struct FunkApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            Image(systemName: model.menuSymbol)
        }
        .menuBarExtraStyle(.window)
    }
}

extension AppModel {
    var menuSymbol: String {
        if status.sending { return "mic.fill" }
        if status.receiving { return muted ? "speaker.slash.fill" : "waveform" }
        if muted { return "speaker.slash" }
        return status.partnerOnline ? "antenna.radiowaves.left.and.right"
                                    : "antenna.radiowaves.left.and.right.slash"
    }
}

struct MenuView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.micDenied { micWarning }
            Divider()
            receiveSection
            Divider()
            talkSection
            Divider()
            systemSection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: Abschnitte

    private var header: some View {
        HStack(spacing: 12) {
            Circle().fill(stateColor).frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(stateText).font(.headline)
                Text(model.status.partnerName.map { "Partner: \($0)" } ?? "Kein Partner im Netzwerk gefunden")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if model.status.partnerMuted {
                    Text("Partner hat Nicht stören an").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var micWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Kein Zugriff aufs Mikrofon", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Ohne Freigabe kannst du empfangen, aber nicht senden.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Mikrofon-Einstellungen öffnen") { model.openMicrophoneSettings() }
        }
    }

    private var receiveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Nicht stören", isOn: $model.muted).toggleStyle(.switch)
            Toggle("Piep bei Empfang", isOn: $model.receiveBeep).toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 4) {
                Text("Lautstärke").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $model.volume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Andere Apps beim Funken absenken").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $model.ducking) {
                    ForEach(DuckingLevel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var talkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Sprechtaste (Tastatur)", selection: $model.hotkey) {
                ForEach(HotKeyChoice.allCases) { Text($0.label).tag($0) }
            }
            HStack {
                Text("Test-Ton")
                Spacer()
                Button("Hier") { model.playTestLocally() }
                Button("Beim Partner") { model.sendTestToPartner() }
                    .disabled(!model.status.partnerOnline)
            }
        }
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.status.pluginConnected ? "Stream Deck verbunden" : "Stream Deck nicht verbunden",
                      systemImage: model.status.pluginConnected ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(model.status.pluginConnected ? Color.green : Color.secondary)
                Spacer()
                Button("Plugin installieren") { model.installStreamDeckPlugin() }
            }
            Toggle("Beim Login starten", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
        }
    }

    private var footer: some View {
        HStack {
            Text("Funk \(model.version)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Beenden") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    // MARK: Zustand

    private var stateText: String {
        let s = model.status
        if s.sending && s.receiving { return "Ihr sprecht beide" }
        if s.sending { return "Du sendest" }
        if s.receiving { return s.muted ? "Partner spricht (stumm)" : "Partner spricht" }
        if !s.partnerOnline { return "Warte auf Partner" }
        return s.muted ? "Bereit, Empfang stumm" : "Bereit"
    }

    private var stateColor: Color {
        let s = model.status
        if s.sending && s.receiving { return .orange }
        if s.sending { return .red }
        if s.receiving { return s.muted ? .purple : .green }
        if !s.partnerOnline { return .gray }
        return s.muted ? .purple : .blue
    }
}
