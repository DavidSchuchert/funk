import Foundation
import os

// MARK: - Konstanten

enum Funk {
    static let bundleID = "de.schuchert.funk"
    static let bonjourType = "_dbefunk._udp"
    static let controlPort: UInt16 = 47811          // Stream-Deck-Plugin, nur localhost
    static let sampleRate: Double = 48_000
    static let packetFrames = 480                    // 10 ms pro UDP-Paket
    static let hangTime: TimeInterval = 1.5          // Engine läuft so lange nach der letzten Aktivität weiter
    static let peerTimeout: TimeInterval = 4
    static let receiveTimeout: TimeInterval = 0.3
}

/// Aller Audio- und Netzwerkzustand lebt auf dieser einen seriellen Queue.
/// Dadurch brauchen wir keine Locks, außer an der Grenze zum Audio-Tap.
let funkQueue = DispatchQueue(label: "de.schuchert.funk.core", qos: .userInteractive)

// MARK: - Logging (Console.app oder: log stream --predicate 'subsystem == "de.schuchert.funk"')

private let logger = Logger(subsystem: Funk.bundleID, category: "funk")
func note(_ s: String) { logger.notice("\(s, privacy: .public)") }
func warn(_ s: String) { logger.error("\(s, privacy: .public)") }

// MARK: - Typen

enum DuckingLevel: Int, CaseIterable, Identifiable {
    case light, medium, strong
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .light: "Leicht"
        case .medium: "Mittel"
        case .strong: "Stark"
        }
    }
}

struct FunkSettings: Equatable {
    var muted = false
    var volume: Float = 0.8
    var ducking: DuckingLevel = .medium
    var receiveBeep = true
}

struct FunkStatus: Equatable {
    var partnerName: String?
    var partnerMuted = false
    var sending = false
    var receiving = false
    var muted = false
    var pluginConnected = false

    var partnerOnline: Bool { partnerName != nil }

    /// Das JSON, das das Stream-Deck-Plugin bekommt.
    var pluginPayload: [String: Any] {
        ["peers": partnerOnline ? 1 : 0, "sending": sending, "receiving": receiving,
         "muted": muted, "partnerMuted": partnerMuted]
    }
}

/// Thread-sicherer Bool für die Grenze Audio-Tap-Thread <-> funkQueue.
final class AtomicFlag {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
