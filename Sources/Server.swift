import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
}

/// Writes one response on one connection, then closes it.
final class HTTPResponder {
    private let conn: NWConnection
    private(set) var isCancelled = false
    init(_ conn: NWConnection) { self.conn = conn }

    /// Stops an in-progress response (used for the Cancel button).
    func cancel() {
        isCancelled = true
        conn.cancel()
    }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 410: return "Gone"
        case 413: return "Payload Too Large"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        default: return "Error"
        }
    }

    func send(_ status: Int, _ body: Data = Data(), type: String = "text/plain; charset=utf-8", headers: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { [conn] _ in conn.cancel() })
    }

    func json(_ obj: Any, status: Int = 200) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        send(status, data, type: "application/json")
    }

    /// Streams part of a file from disk without loading it into memory.
    func streamFile(url: URL, start: Int64, length: Int64, total: Int64, partial: Bool, filename: String,
                    progress: @escaping (Int64) -> Void, finished: @escaping (Bool) -> Void) {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            send(404); finished(false); return
        }
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
        var head = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/octet-stream\r\n"
        head += "Content-Length: \(length)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        if partial { head += "Content-Range: bytes \(start)-\(start + length - 1)/\(total)\r\n" }
        head += "Content-Disposition: attachment; filename*=UTF-8''\(encoded)\r\n"
        head += "Connection: close\r\nCache-Control: no-store\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] err in
            guard let self = self, err == nil else { try? fh.close(); finished(false); return }
            do { try fh.seek(toOffset: UInt64(start)) } catch {
                try? fh.close(); self.conn.cancel(); finished(false); return
            }
            self.pump(fh, remaining: length, sent: 0, progress: progress, finished: finished)
        })
    }

    private func pump(_ fh: FileHandle, remaining: Int64, sent: Int64,
                      progress: @escaping (Int64) -> Void, finished: @escaping (Bool) -> Void) {
        if isCancelled { try? fh.close(); conn.cancel(); finished(false); return }
        if remaining <= 0 {
            try? fh.close()
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { [conn] _ in conn.cancel() })
            finished(true)
            return
        }
        let n = Int(min(remaining, 1024 * 1024))
        guard let chunk = try? fh.read(upToCount: n), !chunk.isEmpty else {
            try? fh.close(); conn.cancel(); finished(false); return
        }
        conn.send(content: chunk, completion: .contentProcessed { [weak self] err in
            guard let self = self else { try? fh.close(); finished(false); return }
            if err != nil { try? fh.close(); self.conn.cancel(); finished(false); return }
            let s = sent + Int64(chunk.count)
            progress(s)
            self.pump(fh, remaining: remaining - Int64(chunk.count), sent: s, progress: progress, finished: finished)
        })
    }
}

final class BodyBuffer {
    var data: Data
    init(_ d: Data) { data = d }
}

/// Minimal HTTP/1.1 server on Network.framework. One request per connection.
final class HTTPServer {
    private struct Head {
        let method: String
        let target: String
        let headers: [String: String]
    }

    private var listener: NWListener?
    /// Everything (parsing, handlers, file IO) runs on this serial queue.
    let queue = DispatchQueue(label: "hop.http", qos: .userInitiated)
    private let maxBody = 32 * 1024 * 1024
    private let handler: (HTTPRequest, HTTPResponder) -> Void
    var onState: ((Bool, String?) -> Void)?

    init(handler: @escaping (HTTPRequest, HTTPResponder) -> Void) {
        self.handler = handler
    }

    func start(port: UInt16) throws {
        stop()
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: p)
        // Advertising a Bonjour service is what makes iOS show the Local Network permission prompt.
        l.service = NWListener.Service(name: "Hop", type: "_http._tcp")
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onState?(true, nil)
            case .failed(let e): self?.onState?(false, e.localizedDescription)
            case .cancelled: self?.onState?(false, nil)
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveHead(conn, buffer: Data())
    }

    private func receiveHead(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil { conn.cancel(); return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let res = HTTPResponder(conn)
                guard let headStr = String(data: buf.subdata(in: 0..<r.lowerBound), encoding: .utf8),
                      let head = Self.parseHead(headStr) else { res.send(400); return }
                let length = Int(head.headers["content-length"] ?? "") ?? 0
                if length > self.maxBody { res.send(413); return }
                let body = BodyBuffer(buf.subdata(in: r.upperBound..<buf.count))
                if length > body.data.count { body.data.reserveCapacity(length) }
                self.receiveBody(conn, res, head, body, length)
            } else if isComplete || buf.count > 64 * 1024 {
                conn.cancel()
            } else {
                self.receiveHead(conn, buffer: buf)
            }
        }
    }

    private func receiveBody(_ conn: NWConnection, _ res: HTTPResponder, _ head: Head, _ buf: BodyBuffer, _ length: Int) {
        if buf.data.count >= length {
            dispatch(head, buf.data.count == length ? buf.data : Data(buf.data.prefix(length)), res)
            return
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4 << 20) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if error != nil { conn.cancel(); return }
            if let d = data { buf.data.append(d) }
            if isComplete && buf.data.count < length { conn.cancel(); return }
            self.receiveBody(conn, res, head, buf, length)
        }
    }

    private func dispatch(_ head: Head, _ body: Data, _ res: HTTPResponder) {
        let comps = URLComponents(string: head.target)
        let path = comps?.path ?? head.target
        var query: [String: String] = [:]
        comps?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        handler(HTTPRequest(method: head.method, path: path, query: query, headers: head.headers, body: body), res)
    }

    private static func parseHead(_ head: String) -> Head? {
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let idx = line.firstIndex(of: ":") {
                let k = line[..<idx].lowercased()
                let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }
        return Head(method: String(parts[0]), target: String(parts[1]), headers: headers)
    }
}
