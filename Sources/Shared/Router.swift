import Foundation

public struct Request {
    public var method: String, path: String, query: [String: String], headers: [String: String], body: Data, ip: String
    public init(method: String, path: String, query: [String: String], headers: [String: String], body: Data, ip: String) {
        self.method = method; self.path = path; self.query = query; self.headers = headers; self.body = body; self.ip = ip
    }
}

public enum Response {
    case bytes(code: Int, type: String, body: Data, extra: [String: String])
    case file(code: Int, url: URL, type: String, start: Int64, length: Int64, extra: [String: String])
}

/// The Android app's HTTP API (Http.kt), request in, response out. No sockets here, so it compiles and runs on macOS.
public final class Router {
    public let take: TakeManager
    private let lock = NSLock()
    private var fails: [String: [Date]] = [:]
    private let lockMax = 10, lockWindow: TimeInterval = 300
    public var onPreviewWanted: () -> Void = {}

    public init(take: TakeManager) { self.take = take }

    static func json(_ o: Any, _ code: Int = 200) -> Response {
        let d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("{}".utf8)
        return .bytes(code: code, type: "application/json", body: d, extra: [:])
    }
    static func text(_ s: String, _ code: Int, extra: [String: String] = [:]) -> Response {
        .bytes(code: code, type: "text/plain", body: Data(s.utf8), extra: extra)
    }

    private func locked(_ ip: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let cut = Date().addingTimeInterval(-lockWindow)
        var d = (fails[ip] ?? []).filter { $0 > cut }
        if d.isEmpty { fails[ip] = nil; return false }
        d = Array(d); fails[ip] = d
        return d.count >= lockMax
    }
    private func badToken(_ ip: String) {
        lock.lock(); defer { lock.unlock() }
        if fails.count > 500 { fails = [:] }
        fails[ip, default: []].append(Date())
    }
    static func constEq(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var r = x.count == y.count ? 0 : 1
        for i in 0..<min(x.count, y.count) { r |= Int(x[i] ^ y[i]) }
        return r == 0
    }

    public func handle(_ r: Request) -> Response {
        let given = r.query["t"] ?? r.headers["x-token"] ?? ""
        if locked(r.ip) { return Router.text("too many bad tokens, locked out for 5 minutes", 429, extra: ["Retry-After": "300"]) }
        if !Router.constEq(given, take.token) {
            if !given.isEmpty { badToken(r.ip) }
            return Router.text("token required (X-Token header or ?t=)", 401)
        }
        return route(r)
    }

    private func route(_ r: Request) -> Response {
        let q = r.query, p = r.path, post = r.method == "POST"
        switch true {
        case p == "/":
            return .bytes(code: 200, type: "text/html; charset=utf-8", body: Data(Router.page.utf8), extra: [:])
        case p == "/status.json":
            return Router.json(take.status())
        case p == "/preview.jpg":
            take.backend.previewWanted(); onPreviewWanted()
            if let d = take.backend.previewJPEG() { return .bytes(code: 200, type: "image/jpeg", body: d, extra: [:]) }
            return Router.text("no frame yet", 404)
        case p == "/start" && post:
            let msg = take.startRecording(label: q["label"] ?? "", session: q["session"] ?? "", camera: q["camera"] ?? "")
            var info = take.takeInfo(); info["ok"] = msg == "started" || msg == "already recording"; info["msg"] = msg
            // permission refusal: same shape as the other errors ({"ok":false,"msg":...}, 409) and no take is created
            if msg.hasPrefix("permission:") { return Router.json(["ok": false, "msg": msg], 409) }
            return Router.json(info)
        case p == "/stop" && post:
            take.stopRecording(why: q["why"] ?? "remote stop")
            var info = take.takeInfo(); info["ok"] = true
            return Router.json(info)
        case p == "/marker" && post:
            var m = take.marker(); m["ok"] = true
            return Router.json(m)
        case p == "/torch" && post:
            let m = q["mode"] ?? ""
            if !["auto", "on", "off"].contains(m) { return Router.json(["ok": false, "msg": "mode=auto|on|off"], 409) }
            var c = take.config; c.v["torch"] = m; try? take.saveConfig(c)
            take.backend.setTorch(m)
            return Router.json(["ok": true, "torchMode": m])
        case p == "/calibrated" && post:
            // camera-moved detection is Android-only; the director only reads "ok", and Android answers 409 when it cannot calibrate
            return Router.json(["ok": false, "msg": "camera-moved detection is not available on iOS"], 409)
        case p == "/time":
            return Router.json(["wall_ms": wallNowMs(), "mono_ns": monoNowNs()])
        case p == "/config" && r.method == "GET":
            return Router.json(take.config.toJSON())
        case p == "/config" && post:
            do {
                guard let o = try JSONSerialization.jsonObject(with: r.body) as? [String: Any] else { throw ConfigError.bad("body") }
                let merged = try take.config.merging(o)
                try take.saveConfig(merged)
                return Router.json(["ok": true, "note": "applies at next Start", "config": merged.toJSON()])
            } catch { return Router.json(["ok": false, "msg": "\(error)"], 409) }
        case p == "/chunks":
            return Router.json(take.chunkList())
        case p.hasPrefix("/chunk/"):
            return sendFile(String(p.dropFirst("/chunk/".count)), range: r.headers["range"])
        default:
            return Router.text("not found", 404)
        }
    }

    static let nameRE = try! NSRegularExpression(pattern: "^[0-9A-Za-z._\\-]+\\.(mp4|json)$")
    static let rangeRE = try! NSRegularExpression(pattern: "^\\s*bytes=(\\d*)-(\\d*)\\s*$")

    private func sendFile(_ name: String, range: String?) -> Response {
        let ns = NSRange(name.startIndex..., in: name)
        if Router.nameRE.firstMatch(in: name, range: ns) == nil || name == "config.json" { return Router.text("bad name", 404) }
        let url = take.dir.appendingPathComponent(name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), let szn = attrs[.size] as? NSNumber
        else { return Router.text("no such chunk", 404) }
        let sz = szn.int64Value
        var start: Int64 = 0, end = sz - 1, code = 200
        if let range, let m = Router.rangeRE.firstMatch(in: range, range: NSRange(range.startIndex..., in: range)) {
            let a = String(range[Range(m.range(at: 1), in: range)!]), b = String(range[Range(m.range(at: 2), in: range)!])
            if !(a.isEmpty && b.isEmpty) {
                let av = Int64(a), bv = Int64(b)
                if (!a.isEmpty && av == nil) || (!b.isEmpty && bv == nil) { /* absurd number: ignore the header */ }
                else {
                    if a.isEmpty { start = max(0, sz - bv!); end = sz - 1; if bv! == 0 { start = sz } }   // suffix range
                    else { start = av!; end = bv == nil ? sz - 1 : min(bv!, sz - 1) }                       // end past the file is clamped
                    if start >= sz || end < start { return Router.text("range not satisfiable", 416, extra: ["Content-Range": "bytes */\(sz)"]) }
                    code = 206
                }
            }
        }
        var extra = ["Accept-Ranges": "bytes"]
        if code == 206 { extra["Content-Range"] = "bytes \(start)-\(end)/\(sz)" }
        return .file(code: code, url: url, type: name.hasSuffix(".json") ? "application/json" : "video/mp4", start: start, length: end - start + 1, extra: extra)
    }

    static let page = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Capture (iOS)</title>
    <style>body{font-family:system-ui,sans-serif;margin:0;background:#15171a;color:#e8e8e8}main{max-width:760px;margin:0 auto;padding:12px}
    #pv{width:100%;background:#000;aspect-ratio:16/9;object-fit:contain;display:block;border-radius:6px}
    button{font-size:1.3em;padding:14px 22px;border:0;border-radius:8px;margin:6px 6px 6px 0}#go{background:#2e9d4f;color:#fff}#no{background:#c0392b;color:#fff}
    pre{white-space:pre-wrap;font-size:.8em}a{color:#7cc4ff}</style></head><body><main>
    <h2>Capture <small id="st"></small></h2><img id="pv" alt="preview">
    <div><button id="go">Start</button><button id="no">Stop</button></div><pre id="s"></pre><h3>Chunks</h3><div id="chunks">...</div>
    </main><script>
    const T=new URLSearchParams(location.search).get('t')||'';const u=p=>p+(p.includes('?')?'&':'?')+'t='+encodeURIComponent(T);
    const api=(p,o)=>fetch(u(p),o).then(r=>r.json());
    go.onclick=()=>api('/start',{method:'POST'}).then(j=>alert(j.msg||'ok'));no.onclick=()=>{if(confirm('Stop recording?'))api('/stop',{method:'POST'})};
    function refresh(){api('/status.json').then(s=>{st.textContent=s.recording?'REC '+s.recSeconds+' s':'idle';
     s_.textContent=JSON.stringify({battery:s.battery,tempC:s.tempC,iso:s.iso,shutter:s.shutter,luma:s.luma,measuredFps:s.measuredFps,drops:s.cameraDrops,freeGB:s.freeGB,warnings:s.warnings},null,1)})}
    const s_=document.getElementById('s');
    function chunks(){api('/chunks').then(a=>{chunks_.innerHTML=a.slice().reverse().map(c=>(c.open?'<i>'+c.name+' (recording)</i>':'<a href="'+u('/chunk/'+c.name)+'">'+c.name+'</a>')+' <small>'+(c.bytes/1048576).toFixed(1)+' MB</small>').join('<br>')||'none'})}
    const chunks_=document.getElementById('chunks');
    refresh();chunks();setInterval(refresh,2000);setInterval(chunks,10000);setInterval(()=>{pv.src=u('/preview.jpg')+'&n='+Date.now()},800);
    </script></body></html>
    """
}
