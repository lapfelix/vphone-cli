import ArgumentParser
import Foundation
import VPhoneCoreKit
import VPhoneRestore

/// Uploads a patched guest's boot chain to Apple's signed Research Guests
/// launcher after its AP debugger has been armed. The launcher and debugger
/// lifecycle are deliberately outside this command: the bundle has no Xcode
/// runtime dependency and this command never changes host security policy.
struct VPhoneVirtualMachineResearchUploadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "research-upload",
        abstract: "Upload a prepared VM's boot chain to a Research Guest in DFU",
        discussion: "Start Apple's vrevm in DFU and arm its guest debugger before running this command. The installed Preboot ticket is cached by cfw install.",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "Prepared vphone machine name") var name: String?
    @Option(name: .customLong("vrevm-config"), help: "The Research Guest's config.plist", transform: URL.init(fileURLWithPath:))
    var vrevmConfig: URL
    @Option(name: .customLong("ticket"), help: "Installed Preboot apticket.der override", transform: URL.init(fileURLWithPath:))
    var ticketOverride: URL?
    @Option(name: .customLong("output-dir"), help: "Directory for personalized boot images", transform: URL.init(fileURLWithPath:))
    var outputDirectory: URL?
    @Flag(name: .customLong("prepare-only"), help: "Prepare and validate images without USB upload")
    var prepareOnly = false
    @Flag(name: .customLong("reuse-prepared"), help: "Validate and reuse saved ResearchBoot IMG4s after cfw install removes the restore tree")
    var reusePrepared = false

    func run() throws {
        let selected = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: selected)
        guard let plan = VPhonePatchPresetStore.plan(forVM: bundle.url),
              plan.isEnabled("avpbooter-boot-dgst_bypass")
        else {
            throw ValidationError("The machine's patch plan must enable avpbooter-boot-dgst_bypass before Research Guests upload.")
        }

        let ecid = try researchECID(from: vrevmConfig)
        let ticket = ticketOverride ?? bundle.url.appendingPathComponent("ResearchBootTicket.der")
        guard FileManager.default.isReadableFile(atPath: ticket.path) else {
            throw ValidationError("Installed Preboot ticket is missing at \(ticket.path). Run cfw install on the machine's disk, or pass --ticket with that disk's apticket.der.")
        }
        let output = outputDirectory ?? bundle.url.appendingPathComponent("ResearchBoot", isDirectory: true)
        let paths: Paths?
        if reusePrepared {
            paths = nil
        } else {
            paths = try researchPaths(in: VPhoneRestoreLayout.findRestoreDirectory(in: bundle.url))
        }

        func image(_ input: URL?, _ expected: String, _ boot: String? = nil, _ name: String) throws -> URL {
            let target = output.appendingPathComponent("\(name).img4")
            if reusePrepared {
                guard FileManager.default.isReadableFile(atPath: target.path) else {
                    throw ValidationError("Saved Research Guest image is missing: \(target.path). Prepare it from the restore tree before using --reuse-prepared.")
                }
                try VPhoneResearchIMG4.validatePrepared(
                    at: target, ticketAt: ticket, expectedType: boot ?? expected,
                )
            } else {
                guard let input else { throw ValidationError("Missing restore source for \(name).") }
                try VPhoneResearchIMG4.prepare(
                    componentAt: input, ticketAt: ticket,
                    expectedType: expected, bootType: boot, outputAt: target,
                )
            }
            return target
        }

        let ibss = try image(paths?.ibss, "ibss", nil, "iBSS")
        let ibec = try image(paths?.ibec, "ibec", nil, "iBEC")
        let boot = VPhoneResearchBootImages(
            restoreSPTM: try image(paths?.restoreSPTM, "sptm", "rspt", "RestoreSPTM"),
            researchTXM: try image(paths?.researchTXM, "trxm", "rtrx", "ResearchTXM"),
            restoreTrustCache: try image(paths?.restoreTrustCache, "rtsc", nil, "RestoreTrustCache"),
            staticTrustCache: try image(paths?.staticTrustCache, "trst", nil, "StaticTrustCache"),
            restoreDeviceTree: try image(paths?.restoreDeviceTree, "dtre", "rdtr", "RestoreDeviceTree"),
            restoreSEP: try image(paths?.restoreSEP, "sepi", "rsep", "RestoreSEP"),
            researchKernelCache: try image(paths?.researchKernelCache, "krnl", "rkrn", "ResearchKernelCache"),
        )
        print("[research] \(reusePrepared ? "Validated saved" : "Prepared") boot images for ECID \(VPhoneRestoreIdentity.formatECID(ecid)) using the installed Preboot ticket.")
        if prepareOnly {
            print("[research] Images: \(output.path)")
            return
        }

        print("[research] Uploading iBSS in DFU...")
        try VPhoneResearchUSB.uploadIBSS(ecid: ecid, image: ibss)
        let first = try VPhoneRecoveryProbe.probe(ecid: ecid, timeout: 45, isRecovery: true)
        guard first.mode == .recovery2 else {
            throw ValidationError("The guest entered \(first.mode), expected recovery mode 2 after iBSS.")
        }

        print("[research] Uploading iBEC...")
        try VPhoneResearchUSB.uploadIBEC(ecid: ecid, image: ibec)
        // iBEC's `go` returns before it has finished replacing the prior
        // recovery stage. Give the old USB connection time to disappear.
        Thread.sleep(forTimeInterval: 2)
        let second = try VPhoneRecoveryProbe.probe(ecid: ecid, timeout: 45, isRecovery: true)
        guard second.mode == .recovery2 else {
            throw ValidationError("The guest entered \(second.mode), expected recovery mode 2 after iBEC.")
        }

        print("[research] Uploading firmware and booting the installed system...")
        try VPhoneResearchUSB.boot(ecid: ecid, images: boot)
        print("[research] bootx sent. Watch the vrevm serial log for guest startup.")
    }

    private func researchECID(from config: URL) throws -> UInt64 {
        let outer = try PropertyListSerialization.propertyList(from: Data(contentsOf: config), format: nil)
        guard let values = outer as? [String: Any] else {
            throw ValidationError("Invalid Research Guests config: \(config.path)")
        }
        _ = try VPhoneResearchGuestNetwork.hostOnlyMAC(from: values, at: config)
        guard values["platformType"] as? Int == 3,
              let identifier = values["machineIdentifier"] as? Data,
              let romImages = values["romImages"] as? [String: Any],
              romImages["avpbooter"] == nil,
              let nested = try PropertyListSerialization.propertyList(from: identifier, format: nil) as? [String: Any],
              let ecid = nested["ECID"] as? NSNumber,
              ecid.uint64Value != 0
        else {
            throw ValidationError("Expected a Research Guests config with platformType 3, an ECID, and Apple's default AP ROM: \(config.path)")
        }
        return ecid.uint64Value
    }

    private struct Paths {
        let ibss: URL
        let ibec: URL
        let restoreSPTM: URL
        let researchTXM: URL
        let restoreTrustCache: URL
        let staticTrustCache: URL
        let restoreDeviceTree: URL
        let restoreSEP: URL
        let researchKernelCache: URL
    }

    private func researchPaths(in restore: URL) throws -> Paths {
        let manifestURL = restore.appendingPathComponent("BuildManifest.plist")
        let propertyList = try PropertyListSerialization.propertyList(from: Data(contentsOf: manifestURL), format: nil)
        guard let root = propertyList as? [String: Any],
              let identities = root["BuildIdentities"] as? [[String: Any]]
        else { throw ValidationError("Invalid BuildManifest: \(manifestURL.path)") }
        let matches = identities.filter {
            $0["ApChipID"] as? String == "0xFE01"
                && $0["ApBoardID"] as? String == "0x90"
                && $0["Ap,TargetType"] as? String == "vresearch101"
                && ($0["Info"] as? [String: Any])?["RestoreBehavior"] as? String == "Erase"
        }
        guard matches.count == 1, let components = matches[0]["Manifest"] as? [String: Any] else {
            throw ValidationError("Expected one FE01/90 erase identity in \(manifestURL.path).")
        }

        func path(_ key: String) throws -> URL {
            guard let component = components[key] as? [String: Any],
                  let info = component["Info"] as? [String: Any],
                  let relative = info["Path"] as? String,
                  !relative.isEmpty, !relative.hasPrefix("/"),
                  !relative.split(separator: "/").contains("..")
            else { throw ValidationError("BuildManifest has no safe path for \(key).") }
            let url = restore.appendingPathComponent(relative).standardizedFileURL
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw ValidationError("\(key) image is missing: \(url.path)")
            }
            return url
        }

        func researchSibling(_ url: URL, label: String) throws -> URL {
            let name = url.lastPathComponent
            guard name.contains(".release.") else {
                throw ValidationError("Cannot derive the patched research \(label) from \(name).")
            }
            let candidate = url.deletingLastPathComponent().appendingPathComponent(
                name.replacingOccurrences(of: ".release.", with: ".research."),
            )
            guard FileManager.default.isReadableFile(atPath: candidate.path) else {
                throw ValidationError("Patched research \(label) is missing: \(candidate.path)")
            }
            return candidate
        }

        return try Paths(
            ibss: path("iBSS"),
            ibec: path("iBEC"),
            restoreSPTM: path("Ap,RestoreSecurePageTableMonitor"),
            researchTXM: researchSibling(path("Ap,RestoreTrustedExecutionMonitor"), label: "TXM"),
            restoreTrustCache: path("RestoreTrustCache"),
            staticTrustCache: path("StaticTrustCache"),
            restoreDeviceTree: path("RestoreDeviceTree"),
            restoreSEP: path("RestoreSEP"),
            researchKernelCache: researchSibling(path("RestoreKernelCache"), label: "kernel cache"),
        )
    }
}

/// The guest API's TCP fallback is safe to use only on a single host-only VRE
/// interface. Reject a second interface even when the legacy primary one is
/// host-only, since the guest daemon binds all guest interfaces.
enum VPhoneResearchGuestNetwork {
    static func hostOnlyMAC(from values: [String: Any], at config: URL) throws -> String {
        guard let legacy = values["networkConfig"] as? [String: Any],
              legacy["mode"] as? String == "hostOnly",
              let mac = legacy["macAddr"] as? String,
              isMACAddress(mac)
        else {
            throw ValidationError("Research Guest requires one hostOnly network with a MAC address in \(config.path).")
        }

        if let additional = values["networkConfigs"] {
            guard let interfaces = additional as? [[String: Any]],
                  interfaces.count == 1,
                  interfaces[0]["mode"] as? String == "hostOnly",
                  let additionalMAC = interfaces[0]["macAddr"] as? String,
                  additionalMAC.caseInsensitiveCompare(mac) == .orderedSame
            else {
                throw ValidationError("Research Guest networkConfigs must contain only the same hostOnly interface as networkConfig: \(config.path).")
            }
        }
        return mac.lowercased()
    }

    private static func isMACAddress(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 6 && parts.allSatisfy { part in
            part.utf8.count == 2 && part.utf8.allSatisfy { byte in
                (0x30 ... 0x39).contains(byte) || (0x41 ... 0x46).contains(byte) || (0x61 ... 0x66).contains(byte)
            }
        }
    }
}
