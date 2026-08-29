import Foundation

/// RFC 9562 UUIDv7: 48-bit unix ms, version nibble, 12 random bits (monotonic within the same ms), variant, 62 random bits.
/// Time-ordered ids keep `events`/`sessions` inserts append-friendly on the server.
enum UUIDv7 {
    private static let lock = NSLock()
    // Guarded by `lock`; the compiler cannot see that, hence nonisolated(unsafe).
    nonisolated(unsafe) private static var lastMs: UInt64 = 0
    nonisolated(unsafe) private static var lastRandA: UInt16 = 0

    static func generate(now: Date = Date()) -> String {
        let ms = UInt64(max(0, now.timeIntervalSince1970) * 1000)
        var randA: UInt16
        lock.lock()
        if ms == lastMs {
            lastRandA = (lastRandA &+ 1) & 0x0FFF
            randA = lastRandA
        } else {
            lastMs = ms
            randA = UInt16.random(in: 0...0x0FFF)
            lastRandA = randA
        }
        lock.unlock()

        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * UInt64(5 - i))) & 0xFF) }
        bytes[6] = 0x70 | UInt8((randA >> 8) & 0x0F)
        bytes[7] = UInt8(randA & 0xFF)
        var randB = UInt64.random(in: 0...UInt64.max)
        for i in (8..<16).reversed() { bytes[i] = UInt8(randB & 0xFF); randB >>= 8 }
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }
}
