import Foundation
import Network

/// Lokaler Steuerport für das Stream-Deck-Plugin: JSON-Zeilen über TCP auf 127.0.0.1.
///   Plugin -> App:  {"cmd":"talk","on":true}
///   App -> Plugin:  {"status":{...}}
///
/// Warum ein eigener Port statt Stream-Deck-Plugin mit eigenem Mikro: Das Mikrofonrecht
/// gehört dann dieser App, und das Plugin bleibt eine dünne Sprechtaste mit Anzeige.
final class ControlServer {
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var talkers = Set<ObjectIdentifier>()
    private var lastPayload: [String: Any] = [:]

    var onChange: (() -> Void)?
    var talking: Bool { !talkers.isEmpty }
    var connected: Bool { !clients.isEmpty }

    func start() {
        let p = NWParameters.tcp
        p.requiredInterfaceType = .loopback      // niemand im Netz kann die Sprechtaste "drücken"
        p.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: p, on: NWEndpoint.Port(rawValue: Funk.controlPort)!)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { note("Steuerport: \($0)") }
            l.start(queue: funkQueue)
            listener = l
        } catch {
            warn("Steuerport fehlgeschlagen: \(error)")
        }
    }

    func broadcast(_ payload: [String: Any]) {
        lastPayload = payload
        for c in clients.values { send(payload, to: c) }
    }

    private func accept(_ c: NWConnection) {
        let id = ObjectIdentifier(c)
        clients[id] = c
        buffers[id] = Data()
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.drop(id)
            default: break
            }
        }
        c.start(queue: funkQueue)
        note("Stream-Deck-Plugin verbunden")
        send(lastPayload, to: c)
        read(c, id)
        onChange?()
    }

    private func read(_ c: NWConnection, _ id: ObjectIdentifier) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self else { return }
            if let d = data { self.consume(d, id) }
            if done || error != nil { c.cancel(); self.drop(id) } else { self.read(c, id) }
        }
    }

    private func consume(_ d: Data, _ id: ObjectIdentifier) {
        var buf = (buffers[id] ?? Data()) + d
        while let nl = buf.firstIndex(of: 0x0A) {
            let line = Data(buf[buf.startIndex..<nl])
            buf = Data(buf[buf.index(after: nl)...])
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["cmd"] as? String == "talk" else { continue }
            if obj["on"] as? Bool == true { talkers.insert(id) } else { talkers.remove(id) }
            onChange?()
        }
        buffers[id] = buf
    }

    private func drop(_ id: ObjectIdentifier) {
        guard clients.removeValue(forKey: id) != nil else { return }
        buffers[id] = nil
        talkers.remove(id)                       // Plugin abgestürzt: nicht ewig weitersenden
        note("Stream-Deck-Plugin getrennt")
        onChange?()
    }

    private func send(_ payload: [String: Any], to c: NWConnection) {
        guard !payload.isEmpty,
              var d = try? JSONSerialization.data(withJSONObject: ["status": payload]) else { return }
        d.append(0x0A)
        c.send(content: d, completion: .idempotent)
    }
}
