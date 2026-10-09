// SPDX-FileCopyrightText: 2026 wckdboy and Omnie-dev contributors
// SPDX-License-Identifier: Apache-2.0

import Compression
import Foundation

/// npm tarballs: gzip around ustar (with pax and GNU long names). Only regular files come out;
/// links, devices and anything that would land outside the target are skipped.
enum Tarball {
    struct Entry { let path: String; let data: Data }

    enum Failure: Error, LocalizedError {
        case notGzip, corrupt, tooLarge
        var errorDescription: String? {
            switch self {
            case .notGzip: "The package isn't a gzip file."
            case .corrupt: "The package archive is damaged."
            case .tooLarge: "The package unpacks to more than 200 MB."
            }
        }
    }

    static let maxSize = 200 << 20

    static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw Failure.notGzip }
        let flags = bytes[3]
        var offset = 10
        if flags & 4 != 0 { guard offset + 2 <= bytes.count else { throw Failure.corrupt }; offset += 2 + Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        if flags & 8 != 0 { while offset < bytes.count, bytes[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 16 != 0 { while offset < bytes.count, bytes[offset] != 0 { offset += 1 }; offset += 1 }
        if flags & 2 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { throw Failure.corrupt }
        // The trailer's ISIZE is the size mod 2^32: a hint for the buffer, not a limit.
        let hint = Int(bytes[bytes.count - 4]) | Int(bytes[bytes.count - 3]) << 8 | Int(bytes[bytes.count - 2]) << 16 | Int(bytes[bytes.count - 1]) << 24
        return try inflate(bytes[offset..<(bytes.count - 8)], hint: hint)
    }

    /// Raw deflate (COMPRESSION_ZLIB is raw deflate, without the zlib header).
    private static func inflate(_ input: ArraySlice<UInt8>, hint: Int) throws -> Data {
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw Failure.corrupt }
        defer { compression_stream_destroy(&stream) }
        var output = Data(capacity: min(max(hint, 64 << 10), maxSize))
        let chunk = 256 << 10
        var buffer = [UInt8](repeating: 0, count: chunk)
        return try input.withUnsafeBufferPointer { source in
            stream.src_ptr = source.baseAddress!
            stream.src_size = source.count
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { out -> compression_status in
                    stream.dst_ptr = out.baseAddress!
                    stream.dst_size = chunk
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                output.append(buffer, count: chunk - stream.dst_size)
                guard output.count <= maxSize else { throw Failure.tooLarge }
                switch status {
                case COMPRESSION_STATUS_END: return output
                case COMPRESSION_STATUS_OK: continue
                default: throw Failure.corrupt
                }
            }
        }
    }

    /// The regular files in a tar archive, with npm's leading "package/" directory removed.
    static func files(_ tar: Data) throws -> [Entry] {
        let bytes = [UInt8](tar)
        var entries: [Entry] = []
        var offset = 0
        var longName: String?
        func field(_ start: Int, _ length: Int) -> String {
            let slice = bytes[(offset + start)..<(offset + start + length)]
            return String(decoding: slice.prefix { $0 != 0 }, as: UTF8.self)
        }
        while offset + 512 <= bytes.count {
            if bytes[offset..<(offset + 512)].allSatisfy({ $0 == 0 }) { break }
            let sizeText = field(124, 12).trimmingCharacters(in: .whitespaces)
            guard let size = Int(sizeText.isEmpty ? "0" : sizeText, radix: 8), size >= 0 else { throw Failure.corrupt }
            let type = bytes[offset + 156]
            let start = offset + 512
            guard start + size <= bytes.count else { throw Failure.corrupt }
            let body = Data(bytes[start..<(start + size)])
            var name = field(0, 100)
            if field(257, 5) == "ustar" { let prefix = field(345, 155); if !prefix.isEmpty { name = prefix + "/" + name } }
            switch type {
            case UInt8(ascii: "L"):
                longName = String(decoding: body.prefix { $0 != 0 }, as: UTF8.self)
            case UInt8(ascii: "x"):
                // pax: "len key=value\n" records; only the path matters here.
                for record in String(decoding: body, as: UTF8.self).split(separator: "\n") {
                    if let space = record.firstIndex(of: " "), record[record.index(after: space)...].hasPrefix("path=") {
                        longName = String(record[record.index(after: space)...].dropFirst(5))
                    }
                }
            case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
                let path = longName ?? name
                longName = nil
                if let clean = sanitize(path) { entries.append(Entry(path: clean, data: body)) }
            default:
                longName = nil
            }
            offset = start + (size + 511) / 512 * 512
        }
        return entries
    }

    /// "package/lib/a.js" → "lib/a.js"; nil for absolute paths or any ".." component.
    static func sanitize(_ path: String) -> String? {
        var parts = path.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
        guard !path.hasPrefix("/"), !parts.contains(".."), parts.count > 1 else { return nil }
        parts.removeFirst()
        return parts.joined(separator: "/")
    }
}
