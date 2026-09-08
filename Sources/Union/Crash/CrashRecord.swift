import Foundation

/// The binary record the C handler wrote while the process was dying, read back on the next launch.
///
/// The layout is documented once, at the top of `union_crash.c`, and the two sides are held together
/// by `version`: a record from a newer format is dropped rather than reinterpreted, because a
/// misread stack would produce a fingerprint that groups unrelated crashes together — and that is
/// worse than one lost report.
struct CrashRecord: Sendable, Equatable {
    enum Cause: UInt16, Sendable {
        case signal = 1, mach = 2, exception = 3
    }

    struct Thread: Sendable, Equatable {
        var index: Int
        var crashed: Bool
        var framesTruncated: Bool
        var name: String?
        var frames: [UInt64]
    }

    struct Crumb: Sendable, Equatable {
        var ts: Int64
        var kind: UInt8
        var name: String
    }

    var cause: Cause
    var crashedAt: Int64
    var uptimeMs: Int64
    var signum: Int32
    var sigcode: Int32
    var machException: UInt32
    var machCode: UInt64
    var machSubcode: UInt64
    var faultAddr: UInt64
    /// `nil` = the app never told the handler which state it was in. Never defaulted to background.
    var foreground: Bool?
    var threads: [Thread]
    var crumbs: [Crumb]

    static let magic: [UInt8] = Array("UCR1".utf8)
    static let currentVersion: UInt16 = 1
    static let threadNameBytes = 64

    /// `nil` for an empty file — which is the ordinary case, and means the process exited cleanly.
    init?(data: Data) {
        var reader = ByteReader(data)
        guard data.count >= 8, reader.take(4).map(Array.init) == CrashRecord.magic else { return nil }
        guard let version: UInt16 = reader.read(), version == CrashRecord.currentVersion else { return nil }
        guard let rawCause: UInt16 = reader.read(), let cause = Cause(rawValue: rawCause) else { return nil }
        guard let crashedAt: Int64 = reader.read(),
              let uptime: Int64 = reader.read(),
              let signum: UInt32 = reader.read(),
              let sigcode: UInt32 = reader.read(),
              let machException: UInt32 = reader.read(),
              let machCode: UInt64 = reader.read(),
              let machSubcode: UInt64 = reader.read(),
              let faultAddr: UInt64 = reader.read(),
              let foregroundByte: UInt8 = reader.read(),
              let threadCount: UInt16 = reader.read(),
              let crashedThread: UInt16 = reader.read(),
              let crumbCount: UInt16 = reader.read()
        else { return nil }

        self.cause = cause
        self.crashedAt = crashedAt
        self.uptimeMs = uptime
        self.signum = Int32(bitPattern: signum)
        self.sigcode = Int32(bitPattern: sigcode)
        self.machException = machException
        self.machCode = machCode
        self.machSubcode = machSubcode
        self.faultAddr = faultAddr
        self.foreground = Int8(bitPattern: foregroundByte) < 0 ? nil : foregroundByte == 1

        var threads: [Thread] = []
        for _ in 0..<Int(threadCount) {
            guard let index: UInt32 = reader.read(),
                  let crashed: UInt8 = reader.read(),
                  let truncated: UInt8 = reader.read(),
                  let frameCount: UInt16 = reader.read(),
                  let nameBytes = reader.take(CrashRecord.threadNameBytes)
            else { break }
            var frames: [UInt64] = []
            frames.reserveCapacity(Int(frameCount))
            for _ in 0..<Int(frameCount) {
                guard let frame: UInt64 = reader.read() else { break }
                frames.append(frame)
            }
            let name = String(cString: Array(nameBytes) + [0])
            threads.append(Thread(index: Int(index),
                                  crashed: crashed == 1,
                                  framesTruncated: truncated == 1,
                                  name: name.isEmpty ? nil : name,
                                  frames: frames))
        }
        /*
         * The handler marks the crashed thread by identity, and 0xffff means it could not find it in
         * the thread list. That is left as "no crashed thread" rather than assumed to be thread 0:
         * the contract rejects a fatal report without exactly one crashed thread, and guessing which
         * stack killed the process is precisely the guess the fingerprint must not be built on.
         */
        if crashedThread != 0xffff, threads.indices.contains(Int(crashedThread)) {
            for i in threads.indices { threads[i].crashed = i == Int(crashedThread) }
        }
        self.threads = threads

        var crumbs: [Crumb] = []
        for _ in 0..<Int(crumbCount) {
            guard let ts: Int64 = reader.read(),
                  let kind: UInt8 = reader.read(),
                  let length: UInt8 = reader.read(),
                  let bytes = reader.take(Int(length))
            else { break }
            guard let name = String(data: bytes, encoding: .utf8), !name.isEmpty else { continue }
            crumbs.append(Crumb(ts: ts, kind: kind, name: name))
        }
        self.crumbs = crumbs
    }
}

/// Little-endian cursor. The record is written by `memcpy` on the same device that reads it, so there
/// is no byte-order conversion to do — only bounds checking, which a truncated record needs.
private struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func take(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.endIndex else { return nil }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }

    mutating func read<T: FixedWidthInteger>() -> T? {
        guard let bytes = take(MemoryLayout<T>.size) else { return nil }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }
}
