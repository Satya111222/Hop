import SwiftUI
import UIKit
import Network

enum Dir { case up, down }
enum TState { case live, done, failed, cancelled }

struct Transfer: Identifiable {
    let id: String
    var name: String
    var dir: Dir
    var total: Int64
    var done: Int64
    var state: TState
    var speed: Double = 0
    var lastTick = Date()
    var lastSeen = Date()
    var lastBytes: Int64 = 0
}

struct FileItem: Identifiable {
    var id: String { name }
    let name: String
    let size: Int64
    let modified: Date
    let url: URL
}

final class Core: ObservableObject {
    let port: UInt16 = 8080

    @Published var running = false
    @Published var address = "not running"
    @Published var error: String?
    @Published var toast: String?
    @Published var transfers: [Transfer] = []
    @Published var files: [FileItem] = []
    @Published var pinEnabled = UserDefaults.standard.bool(forKey: "pinEnabled") {
        didSet { UserDefaults.standard.set(pinEnabled, forKey: "pinEnabled"); syncPin() }
    }
    @Published var pin = UserDefaults.standard.string(forKey: "pin") ?? Core.randomPin() {
        didSet { UserDefaults.standard.set(pin, forKey: "pin"); syncPin() }
    }

    private(set) var wantRunning = false
    private var server: HTTPServer!
    private let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private lazy var parts: URL = docs.appendingPathComponent(".parts", isDirectory: true)
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var pinSnapshot: String?
    private var lastUI: [String: Date] = [:]   // server queue only
    private var cancelledUploads = Set<String>()          // server queue only
    private var downloads: [String: HTTPResponder] = [:]  // server queue only

    init() {
        try? FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        cleanOldParts()
        syncPin()
        server = HTTPServer { [weak self] req, res in self?.handle(req, res) }
        server.onState = { [weak self] ok, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.running = ok
                self.error = err
                UIApplication.shared.isIdleTimerDisabled = ok
                self.refreshAddress()
            }
        }
        monitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refreshAddress() }
        }
        monitor.start(queue: DispatchQueue(label: "hop.path"))
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.sweep() }
        refreshAddress()
        refreshFiles()
    }

    static func randomPin() -> String { String(format: "%04d", Int.random(in: 0...9999)) }

    func newPin() { pin = Core.randomPin() }

    private func syncPin() {
        lock.lock(); pinSnapshot = pinEnabled ? pin : nil; lock.unlock()
    }

    private func currentPin() -> String? {
        lock.lock(); defer { lock.unlock() }
        return pinSnapshot
    }

    // MARK: lifecycle

    func start() {
        wantRunning = true
        do { try server.start(port: port) } catch { self.error = error.localizedDescription }
    }

    func stop() {
        wantRunning = false
        server.stop()
        running = false
        UIApplication.shared.isIdleTimerDisabled = false
        refreshAddress()
    }

    func becameActive() {
        refreshAddress()
        refreshFiles()
        if wantRunning && !running { start() }
    }

    func refreshAddress() {
        guard running else { address = "not running"; return }
        if let ip = Core.localIPs().first { address = "http://\(ip):\(port)" } else { address = "no network" }
    }

    static func localIPs() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let i = p.pointee
            if let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let flags = Int32(i.ifa_flags)
                let name = String(cString: i.ifa_name)
                if (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0, name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    let ip = String(cString: host)
                    if !ip.hasPrefix("169.254") { result.append(ip) }
                }
            }
            ptr = i.ifa_next
        }
        return result
    }

    // MARK: files

    func listFiles() -> [FileItem] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: docs, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { u -> FileItem? in
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true { return nil }
            return FileItem(name: u.lastPathComponent, size: Int64(v?.fileSize ?? 0),
                            modified: v?.contentModificationDate ?? Date(), url: u)
        }.sorted { $0.modified > $1.modified }
    }

    func refreshFiles() { files = listFiles() }

    func delete(_ f: FileItem) {
        try? FileManager.default.removeItem(at: f.url)
        refreshFiles()
    }

    func importFiles(_ urls: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async {
            var n = 0
            for u in urls {
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                let dest = self.uniqueURL(u.lastPathComponent)
                if (try? FileManager.default.moveItem(at: u, to: dest)) != nil { n += 1 }
                else if (try? FileManager.default.copyItem(at: u, to: dest)) != nil { n += 1 }
            }
            DispatchQueue.main.async {
                self.refreshFiles()
                self.say(n == 1 ? "Added 1 file. Download it from the PC page." : "Added \(n) files. Download them from the PC page.")
            }
        }
    }

    func say(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.toast == s { self?.toast = nil }
        }
    }

    func uniqueURL(_ name: String) -> URL {
        var url = docs.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 1
        while FileManager.default.fileExists(atPath: url.path) {
            let n = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            url = docs.appendingPathComponent(n)
            i += 1
        }
        return url
    }

    private func cleanOldParts() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: parts, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for u in urls {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if Date().timeIntervalSince(d) > 3 * 86400 { try? FileManager.default.removeItem(at: u) }
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (a?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: transfers (UI side)

    func clearFinished() { transfers.removeAll { $0.state != .live } }

    /// Cancel button on the iPad.
    func cancel(_ id: String) {
        if let i = transfers.firstIndex(where: { $0.id == id }) {
            transfers[i].state = .cancelled
            transfers[i].speed = 0
        }
        server.queue.async { [weak self] in
            guard let self = self else { return }
            if let r = self.downloads[id] {
                r.cancel()
                self.downloads[id] = nil
            } else {
                self.cancelledUploads.insert(id)
                try? FileManager.default.removeItem(at: self.parts.appendingPathComponent(id + ".part"))
            }
        }
    }

    /// A cancelled upload that starts again (same file) should show up as live again.
    private func revive(_ id: String) {
        if let i = transfers.firstIndex(where: { $0.id == id }), transfers[i].state == .cancelled {
            transfers[i].state = .failed
        }
    }

    private func sweep() {
        let now = Date()
        for i in transfers.indices where transfers[i].state == .live && now.timeIntervalSince(transfers[i].lastSeen) > 25 {
            transfers[i].state = .failed
            transfers[i].speed = 0
        }
    }

    /// Called from the server queue. Throttles UI updates for live progress.
    private func report(_ id: String, _ name: String, _ dir: Dir, total: Int64, done: Int64, _ state: TState) {
        let now = Date()
        if state == .live {
            if let last = lastUI[id], now.timeIntervalSince(last) < 0.15 { return }
            lastUI[id] = now
        } else {
            lastUI[id] = nil
        }
        DispatchQueue.main.async { [weak self] in
            self?.apply(id, name, dir, total, done, state)
        }
    }

    private func apply(_ id: String, _ name: String, _ dir: Dir, _ total: Int64, _ done: Int64, _ state: TState) {
        if state == .cancelled {
            if let i = transfers.firstIndex(where: { $0.id == id }) { transfers[i].state = .cancelled; transfers[i].speed = 0 }
            return
        }
        if let i = transfers.firstIndex(where: { $0.id == id }), transfers[i].state == .cancelled { return }
        let now = Date()
        if let i = transfers.firstIndex(where: { $0.id == id }) {
            var t = transfers[i]
            let dt = now.timeIntervalSince(t.lastTick)
            if dt > 0.4 || state != .live {
                let inst = Double(done - t.lastBytes) / max(dt, 0.001)
                t.speed = t.speed == 0 ? max(inst, 0) : t.speed * 0.6 + max(inst, 0) * 0.4
                t.lastTick = now
                t.lastBytes = done
            }
            t.done = done
            t.total = total
            t.state = state
            t.lastSeen = now
            if state != .live { t.speed = 0 }
            transfers[i] = t
        } else {
            var t = Transfer(id: id, name: name, dir: dir, total: total, done: done, state: state)
            t.lastBytes = done
            transfers.insert(t, at: 0)
        }
        if state == .done { refreshFiles() }
    }

    // MARK: HTTP routes (server queue)

    private func authorized(_ req: HTTPRequest) -> Bool {
        guard let pin = currentPin() else { return true }
        return req.query["pin"] == pin || req.headers["x-pin"] == pin
    }

    private func safeName(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let n = ((raw.replacingOccurrences(of: "\\", with: "/")) as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || n.hasPrefix(".") { return nil }
        return n
    }

    private func safeID(_ raw: String?) -> String? {
        guard let r = raw, !r.isEmpty, r.count <= 80,
              r.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return r
    }

    private func handle(_ req: HTTPRequest, _ res: HTTPResponder) {
        if req.method == "GET", req.path == "/" || req.path == "/index.html" {
            if let u = Bundle.main.url(forResource: "index", withExtension: "html"), let d = try? Data(contentsOf: u) {
                res.send(200, d, type: "text/html; charset=utf-8")
            } else { res.send(404) }
            return
        }
        if req.method == "GET", req.path == "/api/ping" {
            res.json(["ok": true, "pin": currentPin() != nil])
            return
        }
        guard authorized(req) else { res.json(["error": "pin"], status: 401); return }

        switch (req.method, req.path) {
        case ("GET", "/api/files"):
            let list = listFiles().map { ["name": $0.name, "size": $0.size, "modified": Int($0.modified.timeIntervalSince1970)] as [String: Any] }
            res.json(list)
        case ("GET", "/api/upload/status"):
            guard let id = safeID(req.query["id"]) else { res.json(["error": "bad id"], status: 400); return }
            cancelledUploads.remove(id)
            DispatchQueue.main.async { self.revive(id) }
            res.json(["received": fileSize(parts.appendingPathComponent(id + ".part"))])
        case ("PUT", "/api/upload"):
            uploadChunk(req, res)
        case ("POST", "/api/upload/cancel"):
            guard let id = safeID(req.query["id"]) else { res.json(["error": "bad id"], status: 400); return }
            cancelledUploads.insert(id)
            try? FileManager.default.removeItem(at: parts.appendingPathComponent(id + ".part"))
            report(id, "", .up, total: 0, done: 0, .cancelled)
            res.json(["ok": true])
        case ("POST", "/api/upload/finish"):
            uploadFinish(req, res)
        case ("DELETE", "/api/files"):
            guard let name = safeName(req.query["name"]) else { res.json(["error": "bad name"], status: 400); return }
            try? FileManager.default.removeItem(at: docs.appendingPathComponent(name))
            DispatchQueue.main.async { self.refreshFiles() }
            res.json(["ok": true])
        default:
            if req.method == "GET", req.path.hasPrefix("/files/") { download(req, res) } else { res.send(404) }
        }
    }

    private func uploadChunk(_ req: HTTPRequest, _ res: HTTPResponder) {
        guard let id = safeID(req.query["id"]), let name = safeName(req.query["name"]),
              let offset = Int64(req.query["offset"] ?? ""), let total = Int64(req.query["total"] ?? ""),
              offset >= 0 else { res.json(["error": "bad params"], status: 400); return }
        if cancelledUploads.contains(id) { res.json(["error": "cancelled"], status: 410); return }
        let part = parts.appendingPathComponent(id + ".part")
        let fm = FileManager.default
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }
        let size = fileSize(part)
        if offset > size { res.json(["received": size], status: 409); return }
        do {
            let fh = try FileHandle(forWritingTo: part)
            defer { try? fh.close() }
            try fh.seek(toOffset: UInt64(offset))
            try fh.write(contentsOf: req.body)
        } catch {
            report(id, name, .up, total: total, done: offset, .failed)
            res.json(["error": "disk write failed"], status: 500)
            return
        }
        let received = offset + Int64(req.body.count)
        report(id, name, .up, total: total, done: received, .live)
        res.json(["received": received])
    }

    private func uploadFinish(_ req: HTTPRequest, _ res: HTTPResponder) {
        guard let id = safeID(req.query["id"]), let name = safeName(req.query["name"]),
              let total = Int64(req.query["total"] ?? "") else { res.json(["error": "bad params"], status: 400); return }
        if cancelledUploads.contains(id) { res.json(["error": "cancelled"], status: 410); return }
        let part = parts.appendingPathComponent(id + ".part")
        let fm = FileManager.default
        if !fm.fileExists(atPath: part.path) {
            if total == 0 { fm.createFile(atPath: part.path, contents: nil) }
            else { res.json(["received": 0], status: 409); return }
        }
        var size = fileSize(part)
        if size > total {
            if let fh = try? FileHandle(forWritingTo: part) {
                try? fh.truncate(atOffset: UInt64(total))
                try? fh.close()
            }
            size = fileSize(part)
        }
        guard size == total else { res.json(["received": size], status: 409); return }
        let dest = uniqueURL(name)
        do { try fm.moveItem(at: part, to: dest) } catch {
            report(id, name, .up, total: total, done: size, .failed)
            res.json(["error": "could not save"], status: 500)
            return
        }
        report(id, name, .up, total: total, done: total, .done)
        res.json(["name": dest.lastPathComponent])
    }

    private func download(_ req: HTTPRequest, _ res: HTTPResponder) {
        guard let name = safeName(String(req.path.dropFirst("/files/".count))) else { res.send(404); return }
        let url = docs.appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { res.send(404); return }
        let total = fileSize(url)
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "file"
        if total == 0 {
            res.send(200, Data(), type: "application/octet-stream",
                     headers: ["Content-Disposition": "attachment; filename*=UTF-8''\(encoded)"])
            return
        }
        var start: Int64 = 0
        var end: Int64 = total - 1
        var partial = false
        if let r = req.headers["range"], r.hasPrefix("bytes=") {
            let spec = r.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if spec.count == 2 {
                if spec[0].isEmpty, let n = Int64(spec[1]) {
                    start = max(0, total - n)
                } else if let s = Int64(spec[0]) {
                    start = s
                    if let e = Int64(spec[1]) { end = min(e, total - 1) }
                }
                partial = true
            }
            if start > end || start >= total {
                res.send(416, Data(), headers: ["Content-Range": "bytes */\(total)"])
                return
            }
        }
        let length = end - start + 1
        let id = UUID().uuidString
        var last: Int64 = 0
        downloads[id] = res
        report(id, name, .down, total: length, done: 0, .live)
        res.streamFile(url: url, start: start, length: length, total: total, partial: partial, filename: name,
                       progress: { [weak self] sent in
                           last = sent
                           self?.report(id, name, .down, total: length, done: sent, .live)
                       },
                       finished: { [weak self] ok in
                           self?.downloads[id] = nil
                           self?.report(id, name, .down, total: length, done: ok ? length : last, ok ? .done : .failed)
                       })
    }
}
