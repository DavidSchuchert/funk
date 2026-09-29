import Foundation

/// Synthetische Signaltöne. Werden im Code erzeugt statt als Audiodateien mitgeliefert,
/// weil sie dann garantiert im Wiedergabeformat (48 kHz mono) vorliegen.
enum Tones {
    /// Kurzer Doppelpiep, bevor der Partner spricht.
    static let receiveBeep = render([(1200, 0.05), (1600, 0.07)], gain: 0.22)
    /// Aufsteigender Dreiklang zum Testen.
    static let test = render([(660, 0.15), (880, 0.15), (1320, 0.28)], gain: 0.3)

    static func render(_ notes: [(freq: Double, dur: Double)], gain: Float) -> [Float] {
        var out: [Float] = []
        for note in notes {
            let count = Int(note.dur * Funk.sampleRate)
            let fade = max(1, min(240, count / 4))     // 5 ms Ein- und Ausblenden gegen Knacksen
            out.reserveCapacity(out.count + count)
            for i in 0..<count {
                var s = Float(sin(2 * Double.pi * note.freq * Double(i) / Funk.sampleRate)) * gain
                if i < fade { s *= Float(i) / Float(fade) }
                else if i >= count - fade { s *= Float(count - i) / Float(fade) }
                out.append(s)
            }
        }
        return out
    }

    /// Float-Samples in Int16-LE-Pakete für das Netzwerk zerlegen.
    static func packets(_ samples: [Float]) -> [Data] {
        var result: [Data] = []
        var i = 0
        while i < samples.count {
            let end = min(i + Funk.packetFrames, samples.count)
            var d = Data(capacity: (end - i) * 2)
            for s in samples[i..<end] {
                let v = Int16(max(-1, min(1, s)) * 32767).littleEndian
                withUnsafeBytes(of: v) { d.append(contentsOf: $0) }
            }
            result.append(d)
            i = end
        }
        return result
    }
}
