import Foundation
import zlib

/// Minimal ZIP extractor for .mlmodelc bundles. Uses platform zlib (no dependencies).
enum ZipExtractor {
    enum Error: Swift.Error {
        case invalidZip
        case decompressionFailed
    }

    /// Extract a ZIP archive to a destination directory.
    static func extract(zipURL: URL, to destinationDir: URL) throws {
        let data = try Data(contentsOf: zipURL)
        let fm = FileManager.default
        var offset = 0

        while offset + 30 <= data.count {
            // Local file header signature: PK\x03\x04
            guard data[offset] == 0x50, data[offset+1] == 0x4B,
                  data[offset+2] == 0x03, data[offset+3] == 0x04 else { break }

            let compressionMethod = readUInt16(data, at: offset + 8)
            let compressedSize = Int(readUInt32(data, at: offset + 18))
            let uncompressedSize = Int(readUInt32(data, at: offset + 22))
            let nameLength = Int(readUInt16(data, at: offset + 26))
            let extraLength = Int(readUInt16(data, at: offset + 28))

            let nameStart = offset + 30
            let nameEnd = nameStart + nameLength
            guard nameEnd <= data.count else { throw Error.invalidZip }

            let fileName = String(data: data[nameStart..<nameEnd], encoding: .utf8) ?? ""
            let dataStart = nameEnd + extraLength
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= data.count else { throw Error.invalidZip }

            let filePath = destinationDir.appendingPathComponent(fileName)

            if fileName.hasSuffix("/") {
                try fm.createDirectory(at: filePath, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: filePath.deletingLastPathComponent(), withIntermediateDirectories: true)

                if compressionMethod == 0 {
                    // Stored (no compression)
                    try data[dataStart..<dataEnd].write(to: filePath)
                } else if compressionMethod == 8 {
                    // Deflated
                    let compressed = data[dataStart..<dataEnd]
                    let decompressed = try inflate(compressed, expectedSize: uncompressedSize)
                    try decompressed.write(to: filePath)
                }
            }

            offset = dataEnd
        }
    }

    /// Inflate raw deflate data using zlib.
    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        var stream = z_stream()
        // -MAX_WBITS for raw deflate (no zlib/gzip header)
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Error.decompressionFailed
        }
        defer { inflateEnd(&stream) }

        var output = Data(count: expectedSize)
        try data.withUnsafeBytes { srcPtr in
            try output.withUnsafeMutableBytes { dstPtr in
                stream.next_in = UnsafeMutablePointer(mutating: srcPtr.bindMemory(to: Bytef.self).baseAddress!)
                stream.avail_in = uInt(data.count)
                stream.next_out = dstPtr.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(expectedSize)

                let result = zlib.inflate(&stream, Z_FINISH)
                guard result == Z_STREAM_END || result == Z_OK else {
                    throw Error.decompressionFailed
                }
            }
        }

        output.count = Int(stream.total_out)
        return output
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}
