// IM4PHandler.swift — Wrapper around Img4tool for IM4P firmware container handling.

import Foundation
import Img4tool

@_silgen_name("vphone_boot_lzfse_encode_buffer")
private func vphoneBootLZFSEEncode(
    _ destination: UnsafeMutablePointer<UInt8>,
    _ destinationSize: Int,
    _ source: UnsafePointer<UInt8>,
    _ sourceSize: Int,
) -> Int

/// Handles loading, extracting, and re-packaging IM4P firmware containers.
public enum IM4PHandler {
    /// Their `PAYP` properties (`arms`/`tz0s` for the SEP) describe how the
    /// image is loaded, so a rebuilt container keeps them.
    private static let paypPreservingFourCCs: Set<String> = ["trxm", "krnl", "sepi"]
    /// Load a firmware file as IM4P or raw data.
    ///
    /// - Parameter url: Path to the firmware file.
    /// - Returns: Tuple of (extracted payload data, original IM4P if applicable).
    public static func load(contentsOf url: URL) throws -> (payload: Data, im4p: IM4P?) {
        // READ, not mapped, and the asymmetry is deliberate. `save` writes the
        // patched container back over the same path this loaded from — see
        // `FirmwarePipeline.ContainerFirmwareLoader`, whose `save` re-loads the
        // original to keep its metadata and then writes to that very url. A
        // mapping of a file being replaced is a SIGBUS on the next fault; see
        // InPlaceRewrite.swift.
        let fileData = try Data(contentsOfFileToRewrite: url)

        // Try to parse as IM4P first
        if let im4p = try? IM4P(fileData) {
            let payload = try im4p.payload()
            return (payload, im4p)
        }

        // Fall back to raw data
        return (fileData, nil)
    }

    /// Save patched data back to an IM4P container or as raw data.
    ///
    /// If the original was IM4P, re-packages with the same fourcc. iBSS is
    /// LZFSE-compressed for the boot ROM. Otherwise, writes raw bytes.
    ///
    /// - Parameters:
    ///   - patchedData: The patched payload bytes.
    ///   - originalIM4P: The original IM4P container (nil for raw files).
    ///   - url: Output file path.
    public static func save(
        patchedData: Data,
        originalIM4P: IM4P?,
        to url: URL,
    ) throws {
        if let original = originalIM4P {
            // iBSS is decoded by the boot ROM. Its LZFSE encoder uses a
            // 3,750-match block limit; macOS Compression uses 10,000 and
            // produces a valid stream that AVPBooter rejects.
            let rebuilt: Data = if original.fourcc == "ibss" {
                try makeBootIM4P(payload: patchedData, description: original.description)
            } else {
                try IM4P(
                    fourcc: original.fourcc,
                    description: original.description,
                    payload: patchedData,
                ).data
            }
            let output: Data = if paypPreservingFourCCs.contains(original.fourcc) {
                try appendPAYPIfPresent(from: original.data, to: rebuilt)
            } else {
                rebuilt
            }
            try output.write(to: url)
        } else {
            try patchedData.write(to: url)
        }
    }

    private static func makeBootIM4P(payload: Data, description: String) throws -> Data {
        guard !payload.isEmpty, payload.count <= Int(UInt32.max), payload.count <= Int.max - 1024 else {
            throw Img4Error.operationFailed("iBSS payload size cannot be LZFSE-encoded")
        }

        let capacity = payload.count + 1024
        var compressed = Data(count: capacity)
        let compressedCount = compressed.withUnsafeMutableBytes { output in
            payload.withUnsafeBytes { input in
                vphoneBootLZFSEEncode(
                    output.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    capacity,
                    input.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    payload.count,
                )
            }
        }
        guard compressedCount > 0, compressedCount <= capacity else {
            throw Img4Error.operationFailed("iBSS LZFSE compression failed")
        }
        compressed.count = compressedCount

        let compressionInfo = derElement(
            0x30,
            derUnsignedInteger(1) + derUnsignedInteger(payload.count),
        )
        return derElement(
            0x30,
            derIA5("IM4P")
                + derIA5("ibss")
                + derIA5(description)
                + derElement(0x04, compressed)
                + compressionInfo,
        )
    }

    private static func derIA5(_ value: String) -> Data {
        derElement(0x16, Data(value.utf8))
    }

    private static func derUnsignedInteger(_ value: Int) -> Data {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        } while remaining > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return derElement(0x02, Data(bytes))
    }

    private static func derElement(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        result.append(derLengthBytes(content.count))
        result.append(content)
        return result
    }

    private static func appendPAYPIfPresent(from original: Data, to rebuilt: Data) throws -> Data {
        guard let start = paypStart(in: original) else {
            return rebuilt
        }

        let payp = original[start ..< original.endIndex]
        var output = rebuilt
        try updateTopLevelDERLength(of: &output, adding: payp.count)
        output.append(payp)
        return output
    }

    /// Where the `[0]` element carrying the `PAYP` properties starts: the one
    /// whose DER length runs exactly to the end of the container. Its headers
    /// (`A0 len`, `30 len`, `16 04`) take 10 bytes with two-byte lengths (TXM,
    /// kernel) and 6 with short ones (SEP).
    static func paypStart(in data: Data) -> Int? {
        guard let marker = data.range(of: Data("PAYP".utf8), options: .backwards) else { return nil }
        for start in stride(from: marker.lowerBound - 6, through: max(data.startIndex, marker.lowerBound - 16), by: -1) {
            guard data[start] == 0xA0,
                  let (length, size) = derLength(in: data, at: start + 1),
                  start + 1 + size + length == data.endIndex
            else { continue }
            return start
        }
        return nil
    }

    /// A DER length at `index`, and how many bytes it takes.
    private static func derLength(in data: Data, at index: Int) -> (length: Int, size: Int)? {
        guard index < data.endIndex else { return nil }
        let first = data[index]
        if first & 0x80 == 0 {
            return (Int(first), 1)
        }
        let count = Int(first & 0x7F)
        guard (1 ... 4).contains(count), index + count < data.endIndex else { return nil }
        return (data[index + 1 ... index + count].reduce(0) { ($0 << 8) | Int($1) }, 1 + count)
    }

    private static func updateTopLevelDERLength(of data: inout Data, adding extraBytes: Int) throws {
        guard data.count >= 2, data[0] == 0x30 else {
            throw Img4Error.invalidFormat("rebuilt IM4P missing top-level DER sequence")
        }

        let lengthByte = data[1]
        let headerRange: Range<Int>
        let currentLength: Int

        if lengthByte & 0x80 == 0 {
            headerRange = 1 ..< 2
            currentLength = Int(lengthByte)
        } else {
            let lengthOfLength = Int(lengthByte & 0x7F)
            let start = 2
            let end = start + lengthOfLength
            guard end <= data.count else {
                throw Img4Error.invalidFormat("invalid DER length field")
            }
            headerRange = 1 ..< end
            currentLength = data[start ..< end].reduce(0) { ($0 << 8) | Int($1) }
        }

        let replacement = derLengthBytes(currentLength + extraBytes)
        data.replaceSubrange(headerRange, with: replacement)
    }

    private static func derLengthBytes(_ length: Int) -> Data {
        precondition(length >= 0)
        if length < 0x80 {
            return Data([UInt8(length)])
        }

        var value = length
        var encoded: [UInt8] = []
        while value > 0 {
            encoded.append(UInt8(value & 0xFF))
            value >>= 8
        }
        encoded.reverse()
        return Data([0x80 | UInt8(encoded.count)] + encoded)
    }
}
