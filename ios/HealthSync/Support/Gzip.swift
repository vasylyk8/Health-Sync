import Compression
import Foundation

/// Minimal gzip (RFC 1952) encoder built on Apple's raw DEFLATE, so batches can be read by any
/// standard gzip reader on the server.
enum Gzip {
    static func compress(_ data: Data) -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
        out.append(deflate(data))
        var crc = CRC32.checksum(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        return out
    }

    /// Decompresses gzip produced by `compress` (used by tests).
    static func decompress(_ gz: Data) -> Data? {
        guard gz.count >= 18, gz[0] == 0x1f, gz[1] == 0x8b else { return nil }
        return inflate(gz.subdata(in: 10..<(gz.count - 8)))
    }

    private static func deflate(_ data: Data) -> Data {
        process(data, operation: COMPRESSION_STREAM_ENCODE) ?? Data()
    }

    private static func inflate(_ data: Data) -> Data? {
        process(data, operation: COMPRESSION_STREAM_DECODE)
    }

    /// Returns nil if the stream reports an error; empty output is a valid result.
    private static func process(_ input: Data, operation: compression_stream_operation) -> Data? {
        let bufferSize = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: bufferSize, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        var output = Data()
        var failed = false
        var ran = false
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else {
                stream.src_size = 0
                return
            }
            stream.src_ptr = base
            stream.src_size = input.count
            ran = true
            while true {
                stream.dst_ptr = dst
                stream.dst_size = bufferSize
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(dst, count: bufferSize - stream.dst_size)
                if status == COMPRESSION_STATUS_END { break }
                if status != COMPRESSION_STATUS_OK {
                    failed = true
                    break
                }
            }
        }
        // Empty Data may have no base address; then the stream still needs finalizing once.
        if !ran {
            stream.dst_ptr = dst
            stream.dst_size = bufferSize
            if compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue)) == COMPRESSION_STATUS_ERROR { failed = true }
            output.append(dst, count: bufferSize - stream.dst_size)
        }
        return failed ? nil : output
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
