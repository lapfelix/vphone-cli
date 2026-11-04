import Darwin
import Foundation

/// Prepares the already patched components used by a Research Guests recovery
/// boot. The ticket must come from the installed guest's Preboot volume: its
/// SHA-384 digest names the Preboot directory that iOS opens during boot.
public enum VPhoneResearchIMG4 {
    /// Wraps an IM4P in IMG4 with the installed guest's raw IM4M ticket.
    /// `bootType` changes the IM4P's four-character type when recovery iBoot
    /// expects a restore component (for example, `krnl` becomes `rkrn`).
    /// This changes no payload bytes and performs no firmware patching.
    @discardableResult
    public static func prepare(
        componentAt input: URL,
        ticketAt ticketURL: URL,
        expectedType: String,
        bootType: String? = nil,
        outputAt output: URL,
    ) throws -> URL {
        guard input.standardizedFileURL != output.standardizedFileURL else {
            throw Error.inputIsOutput
        }
        let original = try Data(contentsOf: input)
        let ticket = try Data(contentsOf: ticketURL)
        let image = try wrap(
            component: original,
            ticket: ticket,
            expectedType: expectedType,
            bootType: bootType ?? expectedType,
        )
        try FileManager.default.createDirectory(
            at: output.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o777],
        )
        try setArtifactMode(at: output.deletingLastPathComponent(), directory: true)
        try image.write(to: output, options: .atomic)
        try setArtifactMode(at: output, directory: false)
        return output
    }

    /// Checks a saved IMG4 before reuse after `cfw install` has removed its
    /// extracted restore tree. Re-encoding must reproduce every byte, so the
    /// component type and embedded IM4M exactly match the installed ticket.
    public static func validatePrepared(
        at imageURL: URL,
        ticketAt ticketURL: URL,
        expectedType: String,
    ) throws {
        let image = try Data(contentsOf: imageURL)
        let ticket = try Data(contentsOf: ticketURL)
        let root = try element(in: image, at: 0, limit: image.count)
        guard root.tag == 0x30, root.end == image.count else {
            throw Error.malformedPreparedIMG4
        }
        let marker = try element(in: image, at: root.content.lowerBound, limit: root.end)
        guard marker.tag == 0x16, image.subdata(in: marker.content) == Data("IMG4".utf8) else {
            throw Error.malformedPreparedIMG4
        }
        let componentStart = marker.end
        let component = try element(in: image, at: componentStart, limit: root.end)
        guard component.tag == 0x30 else { throw Error.malformedPreparedIMG4 }
        let reproduced = try wrap(
            component: image.subdata(in: componentStart ..< component.end),
            ticket: ticket,
            expectedType: expectedType,
            bootType: expectedType,
        )
        guard reproduced == image else { throw Error.preparedTicketMismatch }
    }

    /// Keep prepared host VM files writable across root and workstation runs.
    /// Open the leaf without following a symlink before changing its mode.
    private static func setArtifactMode(at url: URL, directory: Bool) throws {
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (directory ? O_DIRECTORY : 0)
        let descriptor = open(url.path, flags)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let kind = metadata.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(directory ? S_IFDIR : S_IFREG) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        guard fchmod(descriptor, 0o777) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    static func wrap(component: Data, ticket: Data, expectedType: String, bootType: String) throws -> Data {
        let expected = try fourCC(expectedType)
        let replacement = try fourCC(bootType)
        let imageRoot = try element(in: component, at: 0, limit: component.count)
        guard imageRoot.tag == 0x30, imageRoot.end == component.count else {
            throw Error.malformedIM4P
        }
        let marker = try element(in: component, at: imageRoot.content.lowerBound, limit: imageRoot.end)
        guard marker.tag == 0x16, component.subdata(in: marker.content) == Data("IM4P".utf8) else {
            throw Error.malformedIM4P
        }
        let type = try element(in: component, at: marker.end, limit: imageRoot.end)
        guard type.tag == 0x16, type.content.count == 4 else { throw Error.malformedIM4P }
        let found = component.subdata(in: type.content)
        guard found == Data(expected) else {
            throw Error.typeMismatch(expected: expectedType, found: String(decoding: found, as: UTF8.self))
        }
        let description = try element(in: component, at: type.end, limit: imageRoot.end)
        guard description.tag == 0x16 else { throw Error.malformedIM4P }
        let payload = try element(in: component, at: description.end, limit: imageRoot.end)
        guard payload.tag == 0x04, !payload.content.isEmpty else { throw Error.malformedIM4P }
        try checkRemainingElements(in: component, from: payload.end, to: imageRoot.end)

        do {
            let ticketRoot = try element(in: ticket, at: 0, limit: ticket.count)
            guard ticketRoot.tag == 0x30, ticketRoot.end == ticket.count else {
                throw Error.malformedTicket
            }
            let ticketMarker = try element(in: ticket, at: ticketRoot.content.lowerBound, limit: ticketRoot.end)
            guard ticketMarker.tag == 0x16,
                  ticket.subdata(in: ticketMarker.content) == Data("IM4M".utf8),
                  ticketMarker.end < ticketRoot.end
            else { throw Error.malformedTicket }
            try checkRemainingElements(in: ticket, from: ticketMarker.end, to: ticketRoot.end)
        } catch {
            throw Error.malformedTicket
        }

        var retagged = component
        retagged.replaceSubrange(type.content, with: replacement)
        let body = der(0x16, Data("IMG4".utf8)) + retagged + der(0xA0, ticket)
        return der(0x30, body)
    }

    public enum Error: Swift.Error, LocalizedError, Equatable {
        case invalidFourCC(String)
        case inputIsOutput
        case malformedIM4P
        case malformedTicket
        case malformedPreparedIMG4
        case preparedTicketMismatch
        case typeMismatch(expected: String, found: String)

        public var errorDescription: String? {
            switch self {
            case .invalidFourCC(let type): "Invalid IMG4 four-character type: \(type)"
            case .inputIsOutput: "The IMG4 output path must differ from its IM4P input path."
            case .malformedIM4P: "The component is not a complete DER IM4P."
            case .malformedTicket: "The installed Preboot ticket is not a complete DER IM4M."
            case .malformedPreparedIMG4: "The saved boot image is not a complete IMG4."
            case .preparedTicketMismatch: "The saved boot image does not embed the installed Preboot ticket."
            case .typeMismatch(let expected, let found):
                "Expected IM4P type \(expected), found \(found)."
            }
        }
    }

    private struct Element {
        let tag: UInt8
        let content: Range<Int>
        let end: Int
    }

    private static func fourCC(_ type: String) throws -> [UInt8] {
        let bytes = Array(type.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ (0x20 ... 0x7E).contains($0) }) else {
            throw Error.invalidFourCC(type)
        }
        return bytes
    }

    private static func element(in data: Data, at start: Int, limit: Int) throws -> Element {
        guard start >= 0, start < limit, limit <= data.count, start + 1 < limit else {
            throw Error.malformedIM4P
        }
        let tag = data[start]
        var cursor = start + 1
        let lengthByte = data[cursor]
        cursor += 1
        let length: Int
        if lengthByte & 0x80 == 0 {
            length = Int(lengthByte)
        } else {
            let width = Int(lengthByte & 0x7F)
            guard (1 ... MemoryLayout<Int>.size).contains(width), width <= limit - cursor,
                  data[cursor] != 0
            else { throw Error.malformedIM4P }
            var value = 0
            for byte in data[cursor ..< cursor + width] {
                guard value <= (Int.max - Int(byte)) / 256 else { throw Error.malformedIM4P }
                value = value * 256 + Int(byte)
            }
            guard value >= 0x80 else { throw Error.malformedIM4P }
            cursor += width
            length = value
        }
        guard length <= limit - cursor else { throw Error.malformedIM4P }
        return Element(tag: tag, content: cursor ..< cursor + length, end: cursor + length)
    }

    private static func checkRemainingElements(in data: Data, from start: Int, to end: Int) throws {
        var cursor = start
        while cursor < end {
            cursor = try element(in: data, at: cursor, limit: end).end
        }
    }

    private static func der(_ tag: UInt8, _ content: Data) -> Data {
        var result = Data([tag])
        if content.count < 0x80 {
            result.append(UInt8(content.count))
        } else {
            var length = content.count
            var bytes: [UInt8] = []
            repeat {
                bytes.insert(UInt8(length & 0xFF), at: 0)
                length >>= 8
            } while length != 0
            result.append(0x80 | UInt8(bytes.count))
            result.append(contentsOf: bytes)
        }
        result.append(content)
        return result
    }
}
