import Foundation
#if canImport(Compression)
import Compression
#endif

/// gzip, because `POST /v1/crash` requires it.
///
/// The route refuses an uncompressed body and caps what it reads **decompressed**: a dump is mostly
/// repeated addresses and image paths, so it compresses by roughly an order of magnitude, and a
/// content-length ceiling on a compressed body bounds nothing at all.
///
/// `Compression` produces a raw DEFLATE stream (RFC 1951), so the gzip container — ten-byte header,
/// CRC-32 and the length of the original — is assembled here. Written out rather than pulled from
/// zlib so the SDK keeps having no dependencies.
enum Gzip {
    enum Failure: Error { case unavailable, encodeFailed }

    static func compress(_ data: Data) throws -> Data {
        #if canImport(Compression)
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        out.append(try deflate(data))
        var crc = crc32(data).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        // ISIZE is the original size modulo 2^32, which is what the format specifies — not a cap.
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
        #else
        throw Failure.unavailable
        #endif
    }

    #if canImport(Compression)
    private static func deflate(_ data: Data) throws -> Data {
        // Empty input still has to produce a valid empty DEFLATE block; the encoder handles it, but
        // a zero-length source buffer is undefined, so it is answered directly.
        if data.isEmpty { return Data([0x03, 0x00]) }
        // Deflate can expand incompressible input, so the destination is sized with headroom rather
        // than hopefully.
        let capacity = data.count + (data.count / 2) + 128
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { outBytes -> Int in
            data.withUnsafeBytes { inBytes -> Int in
                compression_encode_buffer(
                    outBytes.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    inBytes.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw Failure.encodeFailed }
        return output.prefix(written)
    }
    #endif

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) == 1 ? 0xedb8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffff_ffff
    }
}
