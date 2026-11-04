import Foundation
import Testing
@testable import VPhoneRestore

struct VPhoneResearchIMG4Tests {
    private func der(_ tag: UInt8, _ body: Data) -> Data {
        var result = Data([tag])
        if body.count < 128 {
            result.append(UInt8(body.count))
        } else {
            var size = body.count
            var length: [UInt8] = []
            repeat {
                length.insert(UInt8(size & 0xFF), at: 0)
                size >>= 8
            } while size != 0
            result.append(0x80 | UInt8(length.count))
            result.append(contentsOf: length)
        }
        result.append(body)
        return result
    }

    private func ia5(_ value: String) -> Data { der(0x16, Data(value.utf8)) }

    private func component(type: String) -> Data {
        der(0x30, ia5("IM4P") + ia5(type) + ia5("test") + der(0x04, Data([0xAA, 0xBB])))
    }

    private var ticket: Data {
        der(0x30, ia5("IM4M") + der(0x02, Data([0])))
    }

    @Test func `retagged component is wrapped with the raw installed ticket`() throws {
        let input = component(type: "krnl")
        let result = try VPhoneResearchIMG4.wrap(
            component: input,
            ticket: ticket,
            expectedType: "krnl",
            bootType: "rkrn",
        )
        let retagged = component(type: "rkrn")
        #expect(result == der(0x30, ia5("IMG4") + retagged + der(0xA0, ticket)))
        #expect(input == component(type: "krnl"))
    }

    @Test func `wrong component type and malformed DER are refused`() {
        #expect(throws: VPhoneResearchIMG4.Error.typeMismatch(expected: "krnl", found: "trxm")) {
            try VPhoneResearchIMG4.wrap(
                component: component(type: "trxm"), ticket: ticket,
                expectedType: "krnl", bootType: "rkrn",
            )
        }
        #expect(throws: VPhoneResearchIMG4.Error.malformedIM4P) {
            try VPhoneResearchIMG4.wrap(
                component: Data([0x30, 0x82, 0x01, 0x00]), ticket: ticket,
                expectedType: "krnl", bootType: "rkrn",
            )
        }
        #expect(throws: VPhoneResearchIMG4.Error.malformedTicket) {
            try VPhoneResearchIMG4.wrap(
                component: component(type: "krnl"), ticket: Data([0x30, 0x03, 0x16]),
                expectedType: "krnl", bootType: "rkrn",
            )
        }
    }

    @Test func `prepare writes an IMG4 without replacing the source`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("kernel.im4p")
        let ticketURL = folder.appendingPathComponent("apticket.der")
        let output = folder.appendingPathComponent("boot/kernel.img4")
        let original = component(type: "krnl")
        try original.write(to: source)
        try ticket.write(to: ticketURL)

        try VPhoneResearchIMG4.prepare(
            componentAt: source, ticketAt: ticketURL,
            expectedType: "krnl", bootType: "rkrn", outputAt: output,
        )
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: output) == der(0x30, ia5("IMG4") + component(type: "rkrn") + der(0xA0, ticket)))
        #expect(throws: VPhoneResearchIMG4.Error.inputIsOutput) {
            try VPhoneResearchIMG4.prepare(
                componentAt: source, ticketAt: ticketURL,
                expectedType: "krnl", outputAt: source,
            )
        }
    }

    @Test func `saved image reuse requires the installed ticket and boot type`() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("kernel.img4")
        let ticketURL = folder.appendingPathComponent("apticket.der")
        let image = try VPhoneResearchIMG4.wrap(
            component: component(type: "rkrn"), ticket: ticket,
            expectedType: "rkrn", bootType: "rkrn",
        )
        try image.write(to: imageURL)
        try ticket.write(to: ticketURL)
        try VPhoneResearchIMG4.validatePrepared(at: imageURL, ticketAt: ticketURL, expectedType: "rkrn")

        #expect(throws: VPhoneResearchIMG4.Error.typeMismatch(expected: "krnl", found: "rkrn")) {
            try VPhoneResearchIMG4.validatePrepared(at: imageURL, ticketAt: ticketURL, expectedType: "krnl")
        }
        try der(0x30, ia5("IM4M") + der(0x02, Data([1]))).write(to: ticketURL)
        #expect(throws: VPhoneResearchIMG4.Error.preparedTicketMismatch) {
            try VPhoneResearchIMG4.validatePrepared(at: imageURL, ticketAt: ticketURL, expectedType: "rkrn")
        }
    }
}
