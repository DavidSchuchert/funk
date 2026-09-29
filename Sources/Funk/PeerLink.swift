import Foundation
import Network

/// Verbindung zum Partner-Mac im LAN: Bonjour zum Finden, UDP für Audio und Status.
///
/// Paketformat:
///   0x01 | PCM Int16 LE ...                 Audio (10 ms)
///   0x02 | flags | Name (UTF-8)             Status, jede Sekunde und bei jeder Änderung
///          flags bit0 = spricht, bit1 = stumm (Nicht stören)
///
/// Warum UDP: Ein verlorenes 10-ms-Paket ist ein kaum hörbarer Knackser. Bei TCP würde
/// es neu gesendet und alles danach verzögert, das ist für Live-Audio schlechter.
final class PeerLink {
    private struct Seen { var at: Date; var flags: UInt8 }

    private(set) var myName: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var outgoing: [String: NWConnection] = [:]
    private var seen: [String: Seen] = [:]
    private var lastAudio = Date.distantPast

    var talking = false
    var muted = false
    var onAudio: ((Data) -> Void)?

    init() {
        myName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    func start() {
        do {
            let l = try NWListener(using: .udp)      // freier Port, Bonjour verteilt ihn
            l.service = NWListener.Service(name: myName, type: Funk.bonjourType)
            l.serviceRegistrationUpdateHandler = { [weak self] change in
                // Bonjour benennt bei Namenskollision um. Der Selbstfilter muss mitziehen.
                if case .add(let ep) = change, case .service(let name, _, _, _) = ep {
                    self?.myName = name
                    note("Angemeldet als \(name)")
                }
            }
            l.newConnectionHandler = { [weak self] c in
                c.start(queue: funkQueue)
                self?.receive(on: c)
            }
            l.stateUpdateHandler = { note("UDP-Listener: \($0)") }
            l.start(queue: funkQueue)
            listener = l
        } catch {
            warn("UDP-Listener fehlgeschlagen: \(error)")
        }

        let b = NWBrowser(for: .bonjour(type: Funk.bonjourType, domain: nil), using: NWParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        b.stateUpdateHandler = { note("Bonjour-Suche: \($0)") }
        b.start(queue: funkQueue)
        browser = b

        heartbeat()
    }

    // MARK: Partner

    var partner: (name: String, muted: Bool, talking: Bool)? {
        let now = Date()
        guard let best = seen.filter({ now.timeIntervalSince($0.value.at) < Funk.peerTimeout })
            .max(by: { $0.value.at < $1.value.at }) else { return nil }
        return (best.key, best.value.flags & 2 != 0, best.value.flags & 1 != 0)
    }

    var receiving: Bool { Date().timeIntervalSince(lastAudio) < Funk.receiveTimeout }

    private func update(_ results: Set<NWBrowser.Result>) {
        var found = Set<String>()
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint, name != myName else { continue }
            found.insert(name)
            if outgoing[name] == nil {
                let c = NWConnection(to: r.endpoint, using: .udp)
                c.stateUpdateHandler = { note("Verbindung zu \(name): \($0)") }
                c.start(queue: funkQueue)
                outgoing[name] = c
                sendStatus()
            }
        }
        for (name, c) in outgoing where !found.contains(name) {
            c.cancel()
            outgoing[name] = nil
            note("\(name) ist nicht mehr im Netz")
        }
    }

    // MARK: Empfangen

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let d = data, !d.isEmpty { self.handle(d) }
            if error == nil { self.receive(on: c) } else { c.cancel() }
        }
    }

    private func handle(_ d: Data) {
        let bytes = [UInt8](d)
        switch bytes[0] {
        case 0x01 where bytes.count > 1:
            lastAudio = Date()
            onAudio?(Data(bytes[1...]))
        case 0x02 where bytes.count > 2:
            let name = String(decoding: bytes[2...], as: UTF8.self)
            if name != myName { seen[name] = Seen(at: Date(), flags: bytes[1]) }
        default:
            break
        }
    }

    // MARK: Senden

    func sendAudio(_ pcm: Data) {
        guard !outgoing.isEmpty else { return }
        var p = Data([0x01])
        p.append(pcm)
        for c in outgoing.values { c.send(content: p, completion: .idempotent) }
    }

    func sendStatus() {
        let flags: UInt8 = (talking ? 1 : 0) | (muted ? 2 : 0)
        var p = Data([0x02, flags])
        p.append(contentsOf: Array(myName.utf8))
        for c in outgoing.values { c.send(content: p, completion: .idempotent) }
    }

    private func heartbeat() {
        sendStatus()
        funkQueue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.heartbeat() }
    }
}
