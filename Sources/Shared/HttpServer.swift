import Foundation
import Network

/// Minimal HTTP/1.1 server on Network.framework (NWListener). One request per connection, "Connection: close", like the Android server.
public final class HttpServer {
    private let router: Router
    private let port: UInt16
    private let bindHost: String?     // nil = all interfaces (restricted by wifiOnly)
    private let wifiOnly: Bool
    private let q = DispatchQueue(label: "wrk.http", qos: .userInitiated, attributes: .concurrent)
    private var listener: NWListener?
    public var onState: (String) -> Void = { _ in }

    public init(router: Router, port: UInt16, bindHost: String? = nil, wifiOnly: Bool = false) {
        self.router = router; self.port = port; self.bindHost = bindHost; self.wifiOnly = wifiOnly
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let p = NWEndpoint.Port(rawValue: port)!
        if let h = bindHost { params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(h), port: p) }
        if wifiOnly { params.requiredInterfaceType = .wifi }
        let l = bindHost != nil ? try NWListener(using: params) : try NWListener(using: params, on: p)
        l.stateUpdateHandler = { [weak self] s in self?.onState("\(s)") }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: q)
        listener = l
    }

    public func stop() { listener?.cancel(); listener = nil }

    private func accept(_ c: NWConnection) {
        c.start(queue: q)
        let ip: String = { if case let .hostPort(h, _) = c.endpoint { return "\(h)".split(separator: "%").first.map(String.init) ?? "?" }; return "?" }()
        var buf = Data()
        var gotRequest = false
        // the request (head + body) must arrive within 10 s; once handled, a long file send is not cut off
        q.asyncAfter(deadline: .now() + 10) { if !gotRequest { c.cancel() } }
        func more() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
                guard let self else { c.cancel(); return }
                if let data { buf.append(data) }
                if err != nil || buf.count > 200_000 { c.cancel(); return }
                if let req = self.parse(buf, ip: ip) { gotRequest = true; self.respond(c, self.router.handle(req)); return }
                if done { c.cancel(); return }
                more()
            }
        }
        more()
    }

    /// nil = need more bytes (or unparseable and will time out when the peer closes)
    private func parse(_ buf: Data, ip: String) -> Request? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buf[buf.startIndex..<sep.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() { if let k = l.firstIndex(of: ":") { headers[l[..<k].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: k)...].trimmingCharacters(in: .whitespaces) } }
        let len = min(Int(headers["content-length"] ?? "") ?? 0, 65536)
        let bodyStart = sep.upperBound
        if buf.count - (bodyStart - buf.startIndex) < len { return nil }
        let body = len > 0 ? Data(buf[bodyStart..<(bodyStart + len)]) : Data()
        let target = parts[1]
        var path = target; var query: [String: String] = [:]
        if let qi = target.firstIndex(of: "?") {
            path = String(target[..<qi])
            for kv in target[target.index(after: qi)...].split(separator: "&") {
                let e = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if e.count == 2 { query[String(e[0])] = String(e[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(e[1]) }
            }
        }
        return Request(method: parts[0], path: path, query: query, headers: headers, body: body, ip: ip)
    }

    private static func reason(_ c: Int) -> String {
        switch c { case 200: return "OK"; case 206: return "Partial Content"; case 401: return "Unauthorized"; case 404: return "Not Found"; case 409: return "Conflict"
        case 416: return "Range Not Satisfiable"; case 429: return "Too Many Requests"; default: return "Error" }
    }

    private func head(_ code: Int, _ type: String, _ len: Int64, _ extra: [String: String]) -> Data {
        var s = "HTTP/1.1 \(code) \(HttpServer.reason(code))\r\nContent-Type: \(type)\r\nContent-Length: \(len)\r\nCache-Control: no-store\r\nConnection: close\r\n"
        for (k, v) in extra { s += "\(k): \(v)\r\n" }
        return Data((s + "\r\n").utf8)
    }

    private func respond(_ c: NWConnection, _ r: Response) {
        let finish: () -> Void = { c.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() }) }
        switch r {
        case let .bytes(code, type, body, extra):
            c.send(content: head(code, type, Int64(body.count), extra) + body, completion: .contentProcessed { _ in finish() })
        case let .file(code, url, type, start, length, extra):
            guard let fh = try? FileHandle(forReadingFrom: url) else { c.cancel(); return }
            c.send(content: head(code, type, length, extra), completion: .contentProcessed { [weak self] err in
                if err != nil { try? fh.close(); c.cancel(); return }
                var left = length
                func next() {
                    if left <= 0 { try? fh.close(); finish(); return }
                    let n = Int(min(Int64(262_144), left))
                    guard let d = try? fh.read(upToCount: n), !d.isEmpty else { try? fh.close(); c.cancel(); return }
                    left -= Int64(d.count)
                    c.send(content: d, completion: .contentProcessed { e in if e != nil { try? fh.close(); c.cancel() } else { next() } })
                }
                try? fh.seek(toOffset: UInt64(start))
                _ = self
                next()
            })
        }
    }
}
