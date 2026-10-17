import Darwin
import Foundation
import os
import SensorTrayCore

private let netLog = Logger(subsystem: "com.nuwan.sensor-tray", category: "philips")

/// Finds Philips purifiers on the LAN: a plaintext CoAP GET /sys/dev/info to
/// the CoAP multicast group and every interface's broadcast address.
/// (macOS 27 hides the ARP table, so a MAC → IP lookup isn't an option.)
enum PhilipsDiscovery {
    static func discover(timeout: TimeInterval = 4) async -> [PurifierInfo] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: discoverBlocking(timeout: timeout))
            }
        }
    }

    private static func discoverBlocking(timeout: TimeInterval) -> [PurifierInfo] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        let request = PhilipsProtocol.infoRequest(messageID: UInt16.random(in: 0...UInt16.max),
                                                  token: (0..<4).map { _ in UInt8.random(in: 0...255) })
        // Sent twice: a purifier in Wi-Fi power save easily misses one probe.
        let targets = [PhilipsProtocol.multicastGroup] + broadcastAddresses()
        func probe() {
            for target in targets { sendProbe(target) }
        }
        func sendProbe(_ target: String) {
            var addr = sockaddrIn(target, port: PhilipsProtocol.port)
            let sent = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, request, request.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if sent < 0 {
                // EHOSTUNREACH here usually means macOS Local Network access was denied.
                netLog.error("discovery send to \(target, privacy: .public) failed: \(String(cString: strerror(errno)), privacy: .public)")
            }
        }
        probe()
        var reprobed = false

        var found: [String: PurifierInfo] = [:]
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            if !reprobed, deadline.timeIntervalSinceNow < timeout / 2 {
                reprobed = true
                probe()
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let waitMs = Int32(max(1, min(250, deadline.timeIntervalSinceNow * 1000)))
            guard poll(&pfd, 1, waitMs) > 0 else { continue }
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &fromLength) }
            }
            guard n > 0, let message = PhilipsProtocol.decode(Array(buffer[0..<n])), message.isContent,
                  let json = String(bytes: message.payload, encoding: .utf8) else { continue }
            let host = String(cString: inet_ntoa(from.sin_addr))
            if let info = PhilipsProtocol.parseInfo(json, host: host) {
                found[info.deviceID] = info
            }
        }
        netLog.info("discovery found \(found.count, privacy: .public) purifier(s)")
        return Array(found.values)
    }

    /// Directed broadcast address of every up, non-loopback IPv4 interface.
    private static func broadcastAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: Set<String> = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_BROADCAST != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let broadcast = ifa.pointee.ifa_dstaddr else { continue }
            let address = broadcast.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { String(cString: inet_ntoa($0.pointee.sin_addr)) }
            result.insert(address)
        }
        return Array(result)
    }
}

func sockaddrIn(_ host: String, port: UInt16) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    inet_pton(AF_INET, host, &addr.sin_addr)
    return addr
}

/// A read-only session with one purifier.
///
/// Sync, then observe /sys/dev/status. The purifier answers only when a value
/// changes, so a quiet room can mean minutes without data; liveness is
/// tracked separately with empty CON pings, which it answers with a reset in
/// a few ms. After 3 missed pings the session re-syncs and reports itself
/// unreachable (the owner may rediscover a new IP). The observe registration
/// is renewed every 30 minutes. All socket work runs on a private queue;
/// callbacks arrive on the main queue.
final class PhilipsClient: @unchecked Sendable {
    enum Status: Equatable { case connecting, reachable, unreachable }

    var onReading: (@MainActor (AirReading) -> Void)?
    var onStatus: (@MainActor (Status) -> Void)?

    let host: String
    private let queue = DispatchQueue(label: "com.nuwan.sensor-tray.philips")
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var messageID = UInt16.random(in: 0...UInt16.max)
    private var syncToken: [UInt8] = []
    private var observeToken: [UInt8] = []
    private var observedAt: Date?
    private var pendingPing: UInt16?
    private var missedPings = 0
    private var status: Status = .connecting

    init(host: String) {
        self.host = host
    }

    deinit {
        // `stop()` normally ran already; this is the safety net.
        readSource?.cancel()
        timer?.cancel()
    }

    func start() {
        queue.async { [self] in
            guard openSocket() else { return setStatus(.unreachable) }
            register()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 30, repeating: 30)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            readSource?.cancel()   // its cancel handler closes the socket
            readSource = nil
            onReading = nil
            onStatus = nil
        }
    }

    // MARK: Queue-confined

    private func openSocket() -> Bool {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        var addr = sockaddrIn(host, port: PhilipsProtocol.port)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { close(fd); fd = -1; return false }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let socketFD = fd
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(socketFD) }
        source.resume()
        readSource = source
        return true
    }

    private func nextID() -> UInt16 {
        messageID &+= 1
        return messageID
    }

    private func randomToken() -> [UInt8] { (0..<4).map { _ in UInt8.random(in: 0...255) } }

    private func send(_ bytes: [UInt8]) {
        guard fd >= 0 else { return }
        _ = Darwin.send(fd, bytes, bytes.count, 0)
    }

    /// Sync; the sync reply triggers the observe registration.
    private func register() {
        syncToken = randomToken()
        let nonce = String(format: "%08X", UInt32.random(in: 0...UInt32.max))
        send(PhilipsProtocol.syncRequest(messageID: nextID(), token: syncToken, nonce: nonce))
    }

    private func observe() {
        observeToken = randomToken()
        observedAt = Date()
        send(PhilipsProtocol.observeStatusRequest(messageID: nextID(), token: observeToken))
        netLog.info("observing \(self.host, privacy: .public)")
    }

    private func tick() {
        if pendingPing != nil {
            missedPings += 1
            if missedPings >= 3 {
                setStatus(.unreachable)
                observedAt = nil
            }
        }
        if observedAt == nil || Date().timeIntervalSince(observedAt!) > 30 * 60 {
            register()
        }
        let id = nextID()
        pendingPing = id
        send(PhilipsProtocol.ping(messageID: id))
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            guard n > 0 else { break }   // EAGAIN, or ECONNREFUSED after an ICMP unreachable
            handle(Array(buffer[0..<n]))
        }
    }

    private func handle(_ bytes: [UInt8]) {
        guard let message = PhilipsProtocol.decode(bytes) else { return }
        if message.type == .confirmable { send(PhilipsProtocol.ack(messageID: message.messageID)) }

        if message.type == .reset, message.messageID == pendingPing {
            pendingPing = nil
            missedPings = 0
            setStatus(.reachable)
            return
        }
        guard message.isContent else { return }
        if message.token == syncToken {
            setStatus(.reachable)
            observe()
        } else if message.token == observeToken, let payload = String(bytes: message.payload, encoding: .utf8) {
            // Corrupt notifications have been seen in the wild; the digest check drops them.
            guard let json = try? PhilipsProtocol.decrypt(payload), let reading = PhilipsProtocol.parseStatus(json) else {
                netLog.error("dropped undecodable status from \(self.host, privacy: .public)")
                return
            }
            setStatus(.reachable)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onReading?(reading) }
            }
        }
    }

    private func setStatus(_ new: Status) {
        guard new != status else { return }
        status = new
        netLog.info("\(self.host, privacy: .public) is \(String(describing: new), privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onStatus?(new) }
        }
    }
}
