import Foundation
import MobileRecoveryCore

// MARK: - VPhoneResearchBootImages

/// Personalized IMG4 files for the recovery-mode portion of a research guest boot.
/// The order here is the order required by the virtual research board's iBEC.
public struct VPhoneResearchBootImages {
    public let restoreSPTM: URL
    public let researchTXM: URL
    public let restoreTrustCache: URL
    public let staticTrustCache: URL
    public let restoreDeviceTree: URL
    public let restoreSEP: URL
    public let researchKernelCache: URL

    public init(
        restoreSPTM: URL,
        researchTXM: URL,
        restoreTrustCache: URL,
        staticTrustCache: URL,
        restoreDeviceTree: URL,
        restoreSEP: URL,
        researchKernelCache: URL,
    ) {
        self.restoreSPTM = restoreSPTM
        self.researchTXM = researchTXM
        self.restoreTrustCache = restoreTrustCache
        self.staticTrustCache = staticTrustCache
        self.restoreDeviceTree = restoreDeviceTree
        self.restoreSEP = restoreSEP
        self.researchKernelCache = researchKernelCache
    }
}

// MARK: - VPhoneResearchUSBError

public enum VPhoneResearchUSBError: Error, LocalizedError {
    case invalidECID
    case imageUnreadable(URL)
    case openFailed(stage: String, reason: String)
    case identityMismatch(stage: String, ecid: UInt64, chipID: UInt32, boardID: UInt32, mode: Int32)
    case deviceUnreadable(stage: String)
    case transferFailed(stage: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidECID:
            "An explicit nonzero research guest ECID is required."
        case let .imageUnreadable(url):
            "The boot image cannot be read: \(url.path)"
        case let .openFailed(stage, reason):
            "Could not open the research guest for \(stage): \(reason)"
        case let .identityMismatch(stage, ecid, chipID, boardID, mode):
            "Refusing \(stage): USB device ECID \(String(ecid, radix: 16)), CPID \(String(chipID, radix: 16)), BDID \(String(boardID, radix: 16)), mode \(String(mode, radix: 16)) is not the expected virtual research board in the required mode."
        case let .deviceUnreadable(stage):
            "The research guest disconnected while checking its identity for \(stage)."
        case let .transferFailed(stage, reason):
            "Research guest \(stage) failed: \(reason)"
        }
    }
}

// MARK: - VPhoneResearchUSB

/// The proven USB upload sequence for a virtual research guest. The caller
/// prepares and personalizes the IMG4s, starts the guest in DFU, and handles
/// the guest debugger before calling `uploadIBSS`.
public enum VPhoneResearchUSB {
    public static func uploadIBSS(ecid: UInt64, image: URL) throws {
        try requireImage(image)
        try withClient(ecid: ecid, stage: "iBSS", mode: .dfu) { client in
            try sendFile(client, image, options: UInt32(IRECV_SEND_OPT_DFU_NOTIFY_FINISH), stage: "iBSS upload")
        }
    }

    public static func uploadIBEC(ecid: UInt64, image: URL) throws {
        try requireImage(image)
        try withClient(ecid: ecid, stage: "iBEC", mode: .recovery2) { client in
            try sendFile(client, image, options: 0, stage: "iBEC upload")
            try requireSuccess(irecv_send_command_breq(client, "go", 1), stage: "iBEC go")
        }
    }

    public static func boot(ecid: UInt64, images: VPhoneResearchBootImages) throws {
        let files = [
            images.restoreSPTM,
            images.researchTXM,
            images.restoreTrustCache,
            images.staticTrustCache,
            images.restoreDeviceTree,
            images.restoreSEP,
            images.researchKernelCache,
        ]
        for image in files { try requireImage(image) }

        try withClient(ecid: ecid, stage: "firmware boot", mode: .recovery2) { client in
            try sendFirmware(client, images.restoreSPTM, stage: "restore SPTM")
            try sendFirmware(client, images.researchTXM, stage: "research TXM")
            try sendFirmware(client, images.restoreTrustCache, stage: "restore trust cache")
            try sendFirmware(client, images.staticTrustCache, stage: "static trust cache")
            try sendFile(client, images.restoreDeviceTree, options: 0, stage: "DeviceTree upload")
            try requireSuccess(irecv_send_command(client, "devicetree"), stage: "DeviceTree command")
            try sendFile(client, images.restoreSEP, options: 0, stage: "SEP upload")
            try requireSuccess(irecv_send_command(client, "rsepfirmware"), stage: "SEP command")
            try sendFile(client, images.researchKernelCache, options: 0, stage: "kernel cache upload")

            // idevicerestore sends this control transfer after the kernel and
            // ignores its return value. The virtual guest returns PIPE (-10)
            // while still accepting the following bootx command.
            _ = irecv_usb_control_transfer(client, 0x21, 1, 0, 0, nil, 0, 5000)
            try requireSuccess(irecv_send_command_breq(client, "bootx", 1), stage: "bootx")
        }
    }

    // MARK: USB helpers

    private static func requireImage(_ image: URL) throws {
        guard image.isFileURL, FileManager.default.isReadableFile(atPath: image.path) else {
            throw VPhoneResearchUSBError.imageUnreadable(image)
        }
    }

    private static func withClient<T>(
        ecid: UInt64,
        stage: String,
        mode: VPhoneRecoveryMode,
        body: (irecv_client_t) throws -> T,
    ) throws -> T {
        guard ecid != 0 else { throw VPhoneResearchUSBError.invalidECID }
        var client: irecv_client_t?
        let open = irecv_open_with_ecid_and_attempts(&client, ecid, 1)
        guard open == IRECV_E_SUCCESS, let client else {
            throw VPhoneResearchUSBError.openFailed(stage: stage, reason: reason(open))
        }
        defer { irecv_close(client) }

        var observedMode: Int32 = 0
        guard irecv_get_mode(client, &observedMode) == IRECV_E_SUCCESS,
              let info = irecv_get_device_info(client)
        else {
            throw VPhoneResearchUSBError.deviceUnreadable(stage: stage)
        }
        guard info.pointee.ecid == ecid,
              info.pointee.cpid == 0xFE01,
              info.pointee.bdid == 0x90,
              observedMode == mode.rawValue
        else {
            throw VPhoneResearchUSBError.identityMismatch(
                stage: stage,
                ecid: info.pointee.ecid,
                chipID: info.pointee.cpid,
                boardID: info.pointee.bdid,
                mode: observedMode,
            )
        }
        return try body(client)
    }

    private static func sendFirmware(_ client: irecv_client_t, _ image: URL, stage: String) throws {
        try sendFile(client, image, options: 0, stage: "\(stage) upload")
        try requireSuccess(irecv_send_command(client, "firmware"), stage: "\(stage) command")
    }

    private static func sendFile(
        _ client: irecv_client_t,
        _ image: URL,
        options: UInt32,
        stage: String,
    ) throws {
        try requireSuccess(irecv_send_file(client, image.path, options), stage: stage)
    }

    private static func requireSuccess(_ result: irecv_error_t, stage: String) throws {
        guard result == IRECV_E_SUCCESS else {
            throw VPhoneResearchUSBError.transferFailed(stage: stage, reason: reason(result))
        }
    }

    private static func reason(_ result: irecv_error_t) -> String {
        guard let detail = irecv_strerror(result) else { return "USB error \(result.rawValue)" }
        return "\(String(cString: detail)) (\(result.rawValue))"
    }
}
