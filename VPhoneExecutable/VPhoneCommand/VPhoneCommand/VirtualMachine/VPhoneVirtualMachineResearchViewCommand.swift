import ArgumentParser
import Darwin
import Foundation
import VPhoneCoreKit

struct VPhoneVirtualMachineResearchViewCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "research-view",
        abstract: "View and control a booted Research Guest over its host-only network",
    )

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "CFW-installed vphone machine name") var name: String?
    @Option(name: .customLong("vrevm-config"), help: "Research Guest config.plist (validates its host-only network and discovers its address)", transform: URL.init(fileURLWithPath:))
    var vrevmConfig: URL

    func run() throws {
        let host = try guestHost()

        let selected = try VPhoneVirtualMachineSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: selected)
        let tokenFile = bundle.url.appendingPathComponent("ResearchAPIToken")
        let descriptor = tokenFile.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw ValidationError("Cannot open ResearchAPIToken. Run cfw install with the current bundle to provision it.")
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0,
              metadata.st_size == 64
        else {
            throw ValidationError("ResearchAPIToken must be a regular, single-link file owned by this user with no group or other permissions. Run cfw install with the current bundle to provision it.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let bytes = try handle.read(upToCount: 65) ?? Data()
        let trailing = try handle.read(upToCount: 1) ?? Data()
        guard bytes.count == 64,
              trailing.isEmpty,
              bytes.allSatisfy({ (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) }),
              let token = String(data: bytes, encoding: .ascii)
        else { throw ValidationError("ResearchAPIToken has an invalid format. Run cfw install to replace it.") }

        try MainActor.assumeIsolated {
            try VPhoneResearchGuestViewer.run(host: host, token: token)
        }
    }

    private func guestHost() throws -> String {
        let outer = try PropertyListSerialization.propertyList(from: Data(contentsOf: vrevmConfig), format: nil)
        guard let config = outer as? [String: Any] else {
            throw ValidationError("Invalid Research Guests config: \(vrevmConfig.path)")
        }
        let configuredMAC = try VPhoneResearchGuestNetwork.hostOnlyMAC(from: config, at: vrevmConfig)
        guard let mac = canonicalMAC(configuredMAC) else {
            throw ValidationError("Invalid Research Guest MAC address in \(vrevmConfig.path).")
        }
        let leases = try String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8)
        let now = UInt64(Date().timeIntervalSince1970)
        var active: [(ip: String, mac: String, expiry: UInt64)] = []
        for block in leases.components(separatedBy: "}") {
            let lines = block.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let ip = lines.first(where: { $0.hasPrefix("ip_address=") }).map({ String($0.dropFirst("ip_address=".count)) }),
                  let hardwareText = lines.first(where: { $0.hasPrefix("hw_address=1,") }).map({ String($0.dropFirst("hw_address=1,".count)) }),
                  let hardware = canonicalMAC(hardwareText),
                  let lease = lines.first(where: { $0.hasPrefix("lease=0x") }).map({ String($0.dropFirst("lease=0x".count)) }),
                  let expiry = UInt64(lease, radix: 16), expiry > now
            else { continue }
            active.append((ip, hardware, expiry))
        }
        guard let selected = active.filter({ $0.mac == mac }).max(by: { $0.expiry < $1.expiry }) else {
            throw ValidationError("No current DHCP lease matches Research Guest MAC \(mac). Boot the VM first and check its hostOnly network.")
        }
        let candidate = selected.ip
        guard !active.contains(where: { $0.ip == candidate && $0.mac != mac && $0.expiry >= selected.expiry }) else {
            throw ValidationError("The Research Guest DHCP address has been reassigned to another MAC. Restart the VM to renew its lease.")
        }

        var address = in_addr(s_addr: 0)
        guard candidate.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            throw ValidationError("The Research Guest address must be numeric IPv4: \(candidate)")
        }
        let bridge = try hostOnlyBridge(for: address)
        guard unauthenticatedHealthProbe(address: address, host: candidate) else {
            throw ValidationError("The Research Guest at \(candidate) did not answer the unauthenticated health probe. Check that its guest API is running.")
        }
        guard try bridgeHasExclusiveGuestMAC(bridge, mac: mac) else {
            throw ValidationError("The host-only bridge must have only the Research Guest's vmenet interface and MAC \(mac). Refusing to send its API token to \(candidate).")
        }
        return candidate
    }

    /// A VRE host-only NIC is attached to a Mac bridge. Require the candidate
    /// address to be on exactly one active bridge subnet before probing it.
    private func hostOnlyBridge(for address: in_addr) throws -> String {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else {
            throw ValidationError("Could not inspect the Mac's host-only network interfaces.")
        }
        defer { freeifaddrs(first) }
        var matches: Set<String> = []
        var cursor = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let entry = item.pointee
            guard let namePointer = entry.ifa_name,
                  let local = entry.ifa_addr,
                  let mask = entry.ifa_netmask,
                  local.pointee.sa_family == sa_family_t(AF_INET),
                  mask.pointee.sa_family == sa_family_t(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0
            else { continue }
            let name = String(cString: namePointer)
            guard name.hasPrefix("bridge"),
                  !name.dropFirst("bridge".count).isEmpty,
                  name.dropFirst("bridge".count).allSatisfy(\.isNumber)
            else { continue }
            let localAddress = UnsafeRawPointer(local).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            if address.s_addr & netmask == localAddress & netmask { matches.insert(name) }
        }
        guard matches.count == 1, let bridge = matches.first else {
            throw ValidationError("Research Guest DHCP address is not on one active host-only bridge. Refusing to send its API token.")
        }
        return bridge
    }

    /// A token-free request forces a live network exchange before reading the
    /// bridge's forwarding cache. The expected response is vphoned's 401.
    private func unauthenticatedHealthProbe(address: in_addr, host: String) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(1339).bigEndian
        destination.sin_addr = address
        let result = withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { return false }
            var ready = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            guard poll(&ready, 1, 3_000) == 1 else { return false }
            var connectionError: Int32 = 0
            var errorSize = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &connectionError, &errorSize) == 0,
                  connectionError == 0
            else { return false }
        }
        guard fcntl(descriptor, F_SETFL, flags) == 0 else { return false }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                         socklen_t(MemoryLayout<timeval>.size)) == 0 else { return false }
        let request = Data("GET /v1/health HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8)
        let written = request.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        guard written == request.count else { return false }
        var response = [UInt8](repeating: 0, count: 128)
        let count = Darwin.recv(descriptor, &response, response.count, 0)
        guard count > 0 else { return false }
        return String(decoding: response.prefix(count), as: UTF8.self).hasPrefix("HTTP/1.1 401 ")
    }

    /// vmnet does not populate macOS's ARP table for this guest. Limit the
    /// candidate address to a bridge with one possible VM peer, then confirm
    /// that peer's source MAC in the bridge cache after the token-free probe.
    private func bridgeHasExclusiveGuestMAC(_ bridge: String, mac: String) throws -> Bool {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/sbin/ifconfig")
        command.arguments = [bridge]
        let output = Pipe()
        command.standardOutput = output
        command.standardError = Pipe()
        try command.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        guard command.terminationStatus == 0,
              let text = String(data: bytes, encoding: .utf8)
        else { return false }

        var member: String?
        var memberCount = 0
        var inCache = false
        var guestMACFound = false
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("member: ") {
                let columns = trimmed.split(whereSeparator: \.isWhitespace)
                guard columns.count >= 2 else { return false }
                member = String(columns[1])
                memberCount += 1
                continue
            }
            if trimmed == "Address cache:" {
                inCache = true
                continue
            }
            guard inCache else { continue }
            guard line.hasPrefix("\t\t") else { break }
            let columns = trimmed.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 4,
                  let cachedMAC = canonicalMAC(String(columns[0]))
            else { return false }
            if columns[1].hasPrefix("Vlan"),
               String(columns[2]) == member,
               (Int(columns[3]) ?? 0) > 0 {
                guard cachedMAC == mac else { return false }
                guestMACFound = true
            }
        }
        guard memberCount == 1, let member, member.hasPrefix("vmenet"),
              !member.dropFirst("vmenet".count).isEmpty,
              member.dropFirst("vmenet".count).allSatisfy(\.isNumber)
        else { return false }
        return guestMACFound
    }

    /// bootpd and ifconfig may omit a leading zero from individual MAC octets.
    /// Compare six parsed bytes, while rejecting malformed or extra octets.
    private func canonicalMAC(_ raw: String) -> String? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard (1 ... 2).contains(part.utf8.count),
                  part.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 70).contains($0) || (97 ... 102).contains($0) }),
                  let octet = UInt8(part, radix: 16)
            else { return nil }
            octets.append(octet)
        }
        return octets.map { String(format: "%02x", Int($0)) }.joined(separator: ":")
    }
}
