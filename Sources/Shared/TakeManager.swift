import Foundation

/// Take bookkeeping and the sidecar json (same shape as the Android app's), independent of the camera implementation.
public final class TakeManager: RecorderEvents {
    public let dir: URL
    public let token: String
    public let configURL: URL
    public let backend: RecorderBackend
    public var device: () -> DeviceInfo
    public var deviceName: String
    public var listen: () -> [String] = { [] }
    /// nil = camera (and, when config audio is on, microphone) are authorised; else the reason /start is refused. The iOS app sets it.
    public var permissionCheck: (Config) -> String? = { _ in nil }
    /// Set when the app left the foreground mid-take (the take was closed cleanly and is NOT resumed); cleared by the next /start.
    public private(set) var interrupted = false
    public private(set) var interruptedWhy = ""

    private let lock = NSRecursiveLock()
    private var sidecar: [String: Any] = [:]
    private var openChunks = Set<String>()
    public private(set) var takeId = ""
    public private(set) var recording = false
    private var recStartMs: Int64 = 0
    private var chunksDone = 0
    private var currentChunk = ""
    public var warnings: [String: String] = [:]
    public var alertLog: [String] = []

    public init(dir: URL, token: String, backend: RecorderBackend, deviceName: String, device: @escaping () -> DeviceInfo) {
        self.dir = dir; self.token = token; self.backend = backend; self.deviceName = deviceName; self.device = device
        configURL = dir.appendingPathComponent("config.json")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        backend.events = self
    }

    public var config: Config { Config.load(configURL) }
    public func saveConfig(_ c: Config) throws { try c.save(configURL) }

    public func stamp() -> [String: Any] { ["mono_ns": monoNowNs(), "wall_ms": wallNowMs(), "flashed": false] }

    public func marker() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let m = stamp()
        if !takeId.isEmpty { var a = (sidecar["markers"] as? [Any]) ?? []; a.append(m); sidecar["markers"] = a; writeSidecar() }
        return m
    }

    public func takeInfo() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["take": takeId, "sidecar": takeId.isEmpty ? "" : "\(takeId).json",
                "marker": sidecar["marker"] ?? NSNull(), "firstFrame": sidecar["firstFrame"] ?? NSNull(), "chunks": sidecar["chunks"] ?? [Any]()]
    }

    static func slug(_ label: String) -> String {
        var out = ""
        for ch in label.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) { out.append(ch) } else if out.last != "-" { out.append("-") }
        }
        return String(String(out.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-")))
    }

    /// Returns "started", "already recording" or an error text.
    public func startRecording(label: String, session: String, camera: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if recording { return "already recording" }
        let cfg = config
        if let p = permissionCheck(cfg) { return "permission: \(p)" }
        interrupted = false; interruptedWhy = ""
        let bat = device()
        if !bat.plugged, bat.battery >= 0, bat.battery <= cfg.int("stopBattery") { return "battery too low" }
        let mark = stamp()
        let slug = TakeManager.slug(label)
        takeId = isoName(mark["wall_ms"] as! Int64) + (slug.isEmpty ? "" : "_" + slug)
        sidecar = ["take": takeId, "label": label, "session": session, "camera": camera, "device": deviceName, "marker": mark,
                   "markers": [Any](), "chunks": [Any](), "shutter": cfg.shutterText, "fps": cfg.fps, "chunkSeconds": cfg.chunkSeconds, "platform": "ios"]
        writeSidecar()
        chunksDone = 0; currentChunk = ""; openChunks = []; warnings = [:]
        do { try backend.start(dir: dir, config: cfg, nameSuffix: slug.isEmpty ? "" : "_" + slug) }
        catch {
            sidecar["stop"] = ["mono_ns": monoNowNs(), "wall_ms": wallNowMs(), "why": "start failed: \(error)"]; writeSidecar()
            return "camera error: \(error)"
        }
        recording = true; recStartMs = wallNowMs()
        return "started"
    }

    /// The app went inactive/background mid-take: finish the chunk cleanly (stop closes the mp4, sidecar written), flag the take, never resume.
    public func interruptRecording(why: String) {
        lock.lock(); defer { lock.unlock() }
        guard recording else { return }
        interrupted = true; interruptedWhy = why
        warnings["interrupted"] = why
        alertLog.append("take interrupted: \(why)")
        sidecar["interrupted"] = ["wall_ms": wallNowMs(), "why": why]
        stopRecording(why: "interrupted: \(why)")
    }

    public func stopRecording(why: String) {
        lock.lock(); defer { lock.unlock() }
        if recording {
            backend.stop()
            sidecar["stop"] = ["mono_ns": monoNowNs(), "wall_ms": wallNowMs(), "why": why]
            let l = backend.live
            sidecar["frameStats"] = ["measuredFps": l.measuredFps, "cameraDrops": l.camDrops, "encoderDrops": l.encDrops]
            sidecar["motion"] = ["supported": false, "note": "camera-moved detection is not implemented on iOS"]
            writeSidecar()
        }
        recording = false; currentChunk = ""
    }

    // MARK: RecorderEvents
    public func firstFrame(wallMs: Int64) {
        lock.lock(); defer { lock.unlock() }
        if sidecar["firstFrame"] == nil { sidecar["firstFrame"] = ["wall_ms": wallMs]; writeSidecar() }
    }
    public func chunkOpened(name: String, wallMs: Int64) {
        lock.lock(); defer { lock.unlock() }
        var a = (sidecar["chunks"] as? [[String: Any]]) ?? []
        a.append(["name": name, "wall_ms": wallMs, "open": true]); sidecar["chunks"] = a
        openChunks.insert(name); currentChunk = name; writeSidecar()
    }
    public func chunkClosed(name: String, frames: Int, durMs: Int) {
        lock.lock(); defer { lock.unlock() }
        var a = (sidecar["chunks"] as? [[String: Any]]) ?? []
        for i in a.indices where (a[i]["name"] as? String) == name { a[i]["open"] = false; a[i]["frames"] = frames; a[i]["dur_ms"] = durMs }
        sidecar["chunks"] = a; openChunks.remove(name); chunksDone += 1; writeSidecar()
    }
    public func recorderError(_ msg: String) {
        lock.lock(); defer { lock.unlock() }
        warnings["camera"] = msg; alertLog.append(msg)
    }

    private func writeSidecar() {
        guard !takeId.isEmpty, let d = try? JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys]) else { return }
        let dst = dir.appendingPathComponent(takeId + ".json")
        try? d.write(to: dst, options: .atomic)
    }

    public func chunkList() -> [[String: Any]] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { ($0.hasSuffix(".mp4") || $0.hasSuffix(".part") || $0.hasSuffix(".json")) && $0 != "config.json" }.sorted()
        lock.lock(); let open = openChunks; lock.unlock()
        return names.map { n in
            let sz = ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n).path))?[.size] as? Int) ?? 0
            return ["name": n, "bytes": sz, "open": open.contains(n) || n.hasSuffix(".part")]
        }
    }

    public func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let cfg = config, l = backend.live, d = device()
        let rec: Int64 = recording ? (wallNowMs() - recStartMs) / 1000 : 0
        let status: [String: Any] = [
            "armed": true, "recording": recording, "torch": l.torchOn, "torchMode": cfg.string("torch"), "torchReason": l.torchReason, "take": takeId,
            "wall_ms": wallNowMs(), "mono_ns": monoNowNs(), "listen": listen(),
            "recSeconds": rec, "interrupted": interrupted, "interruptedWhy": interruptedWhy, "chunk": currentChunk, "chunksDone": chunksDone,
            "battery": d.battery, "plugged": d.plugged, "tempC": d.tempC, "remainingMin": -1,
            "mode": "ios \(cfg.width)x\(cfg.height)", "fps": cfg.fps, "measuredFps": l.measuredFps,
            "cameraDrops": l.camDrops, "encoderDrops": l.encDrops, "expNs": l.expNs,
            "iso": l.iso, "shutter": l.shutter.isEmpty ? cfg.shutterText : l.shutter, "exposureUs": l.expNs / 1000, "shortened": false,
            "luma": (l.luma * 1000).rounded() / 1000, "flicker": (l.flicker * 1000).rounded() / 1000,
            "focusAwbLocked": l.locked, "rotation": l.rotation,
            "motion": ["active": false] as [String: Any],
            "warnings": warnings, "alerts": Array(alertLog.suffix(8)), "freeGB": d.freeGB,
        ]
        return status
    }
}
