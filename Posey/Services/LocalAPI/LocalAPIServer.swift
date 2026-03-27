import Foundation
import Network
import Security

// ========== BLOCK 01: CLASS, TOKEN, AND ADDRESS - START ==========

/// Local HTTP API server — lets Claude Code interact with Posey directly
/// over WiFi. Default OFF; toggled from the Library screen.
///
/// Port 8765. Auth via a Keychain-backed bearer token that persists across
/// launches. Pattern adapted from Hal Universal's LocalAPIServer (Block 32).
@MainActor
final class LocalAPIServer {

    static let port: UInt16 = 8765
    private var listener: NWListener?

    var isRunning: Bool { listener != nil }

    // Injected at start() — weak to avoid retain cycles, closures to avoid
    // crossing the MainActor boundary unsafely.
    private var commandHandler: (@Sendable (String) async -> String)?
    private var importHandler:  (@Sendable (String, Data) async -> String)?
    private var stateHandler:   (@Sendable () async -> String)?

    // MARK: — Keychain token

    private static let keychainService = "com.MarkFriedlander.Posey"
    private static let keychainAccount = "localAPIToken"

    static func loadOrCreateToken() -> String {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService as CFString,
            kSecAttrAccount: keychainAccount as CFString,
            kSecReturnData:  true
        ]
        var item: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let token = String(data: data, encoding: .utf8) { return token }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let add: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService as CFString,
            kSecAttrAccount: keychainAccount as CFString,
            kSecValueData:   Data(token.utf8) as CFData
        ]
        SecItemAdd(add as CFDictionary, nil)
        return token
    }

    static var apiToken: String { loadOrCreateToken() }

    // MARK: — LAN address

    static func localIPAddress() -> String {
        var best = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return best }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let iface = ptr?.pointee {
            defer { ptr = ptr?.pointee.ifa_next }
            guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: iface.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostname)
            if !ip.isEmpty && ip != "0.0.0.0" { best = ip }
        }
        return best
    }

    var connectionInfo: String {
        "http://\(Self.localIPAddress()):\(Self.port)  token: \(Self.apiToken)"
    }
}

// ========== BLOCK 01: CLASS, TOKEN, AND ADDRESS - END ==========

// ========== BLOCK 02: LIFECYCLE - START ==========

extension LocalAPIServer {

    func start(
        commandHandler: @escaping @Sendable (String) async -> String,
        importHandler:  @escaping @Sendable (String, Data) async -> String,
        stateHandler:   @escaping @Sendable () async -> String
    ) {
        guard !isRunning else { return }
        self.commandHandler = commandHandler
        self.importHandler  = importHandler
        self.stateHandler   = stateHandler

        do {
            // Capture before the closure to avoid crossing actor boundaries.
            let ip    = Self.localIPAddress()
            let port  = Self.port
            let token = Self.apiToken

            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params,
                                   on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .global(qos: .userInitiated))
                Task { await self?.handleConnection(conn) }
            }
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("PoseyAPI: Ready — \(ip):\(port)")
                    print("PoseyAPI: Token — \(token)")
                case .failed(let e):
                    print("PoseyAPI: Failed — \(e)")
                default: break
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            self.listener = l
        } catch {
            print("PoseyAPI: Could not start NWListener — \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        commandHandler = nil
        importHandler  = nil
        stateHandler   = nil
        print("PoseyAPI: Stopped")
    }
}

// ========== BLOCK 02: LIFECYCLE - END ==========

// ========== BLOCK 03: CONNECTION HANDLING AND HTTP PARSING - START ==========

extension LocalAPIServer {

    private func handleConnection(_ conn: NWConnection) async {
        guard let data = await receiveRequest(conn),
              let req  = parseRequest(data) else {
            respond(conn, status: 400, body: #"{"error":"Bad request"}"#)
            return
        }
        guard req.token == Self.apiToken else {
            respond(conn, status: 401, body: #"{"error":"Unauthorized"}"#)
            return
        }
        let (status, body) = await route(req)
        respond(conn, status: status, body: body)
    }

    /// Accumulates TCP chunks until the full HTTP request (headers + body) arrives.
    /// Uses raw Data throughout so binary import bodies are handled correctly.
    private func receiveRequest(_ conn: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            var buf = Data()
            let sep = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n

            func next() {
                conn.receive(minimumIncompleteLength: 1,
                             maximumLength: 65_536) { chunk, _, done, err in
                    if let chunk { buf.append(chunk) }
                    if let sepRange = buf.range(of: sep) {
                        let headerData = Data(buf[..<sepRange.lowerBound])
                        if let hdrStr = String(data: headerData, encoding: .utf8),
                           let clLine = hdrStr.components(separatedBy: "\r\n")
                               .first(where: { $0.lowercased().hasPrefix("content-length:") }),
                           let cl = Int(clLine.components(separatedBy: ":")
                               .last?.trimmingCharacters(in: .whitespaces) ?? "") {
                            let received = buf.count - sepRange.upperBound
                            if received >= cl { cont.resume(returning: buf); return }
                        } else {
                            // No body (e.g. GET)
                            cont.resume(returning: buf); return
                        }
                    }
                    if done || err != nil {
                        cont.resume(returning: buf.isEmpty ? nil : buf)
                    } else { next() }
                }
            }
            next()
        }
    }

    private struct ParsedRequest {
        let method:  String
        let path:    String
        let token:   String?
        let headers: [String: String]
        let bodyData: Data?
    }

    private func parseRequest(_ data: Data) -> ParsedRequest? {
        let sep = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let sepRange = data.range(of: sep) else { return nil }

        let headerData = Data(data[..<sepRange.lowerBound])
        guard let hdrStr = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = hdrStr.components(separatedBy: "\r\n")
        guard let reqLine = lines.first else { return nil }
        let rp = reqLine.components(separatedBy: " ")
        guard rp.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let ci = line.firstIndex(of: ":") {
                let key = String(line[..<ci]).lowercased().trimmingCharacters(in: .whitespaces)
                let val = String(line[line.index(after: ci)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }

        let token: String? = {
            guard let auth = headers["authorization"],
                  auth.lowercased().hasPrefix("bearer ") else { return nil }
            return String(auth.dropFirst(7))
        }()

        let bodySlice = data[sepRange.upperBound...]
        let bodyData  = bodySlice.isEmpty ? nil : Data(bodySlice)

        return ParsedRequest(method: rp[0], path: rp[1],
                             token: token, headers: headers, bodyData: bodyData)
    }
}

// ========== BLOCK 03: CONNECTION HANDLING AND HTTP PARSING - END ==========

// ========== BLOCK 04: ROUTING - START ==========

extension LocalAPIServer {

    private func route(_ req: ParsedRequest) async -> (Int, String) {
        switch (req.method, req.path) {
        case ("POST", "/command"): return await handleCommand(req)
        case ("POST", "/import"):  return await handleImport(req)
        case ("GET",  "/state"):   return await handleState()
        default: return (404, #"{"error":"Not found"}"#)
        }
    }

    // POST /command {"command": "LIST_DOCUMENTS"}
    private func handleCommand(_ req: ParsedRequest) async -> (Int, String) {
        guard let bodyData = req.bodyData,
              let json     = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let cmd      = json["command"] as? String, !cmd.isEmpty else {
            return (400, #"{"error":"Missing 'command'"}"#)
        }
        guard let handler = commandHandler else {
            return (503, #"{"error":"Command handler unavailable"}"#)
        }
        let result = await handler(cmd)
        return (200, result)
    }

    // POST /import — raw file bytes in body, X-Filename header carries filename
    private func handleImport(_ req: ParsedRequest) async -> (Int, String) {
        guard let filename = req.headers["x-filename"], !filename.isEmpty else {
            return (400, #"{"error":"Missing X-Filename header"}"#)
        }
        guard let data = req.bodyData, !data.isEmpty else {
            return (400, #"{"error":"Empty body"}"#)
        }
        guard let handler = importHandler else {
            return (503, #"{"error":"Import handler unavailable"}"#)
        }
        let result = await handler(filename, data)
        return (200, result)
    }

    // GET /state
    private func handleState() async -> (Int, String) {
        guard let handler = stateHandler else {
            return (503, #"{"error":"State handler unavailable"}"#)
        }
        let result = await handler()
        return (200, result)
    }
}

// ========== BLOCK 04: ROUTING - END ==========

// ========== BLOCK 05: HTTP RESPONSE - START ==========

extension LocalAPIServer {

    private func respond(_ conn: NWConnection, status: Int, body: String) {
        let phrase: String
        switch status {
        case 200: phrase = "OK"
        case 400: phrase = "Bad Request"
        case 401: phrase = "Unauthorized"
        case 404: phrase = "Not Found"
        case 503: phrase = "Service Unavailable"
        default:  phrase = "Internal Server Error"
        }
        let bodyData = body.data(using: .utf8) ?? Data()
        let header   = "HTTP/1.1 \(status) \(phrase)\r\n" +
                       "Content-Type: application/json\r\n" +
                       "Content-Length: \(bodyData.count)\r\n" +
                       "Connection: close\r\n\r\n"
        var resp = header.data(using: .utf8)!
        resp.append(bodyData)
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// ========== BLOCK 05: HTTP RESPONSE - END ==========
