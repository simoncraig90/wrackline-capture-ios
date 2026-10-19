import Foundation

/// Same keys and defaults as the Android app's Config.kt (config.json, GET/POST /config), except fps defaults to 60 here.
/// Applied at the next Start. Keys the iOS app cannot honour (cameraId, ntfy*, sound) are kept so a shared config file round-trips.
public struct Config {
    public var v: [String: Any]

    public static let defaults: [String: Any] = [
        "scene": "outdoor", "shutterOutdoor": "1/500", "shutterIndoor": "1/200", "shutterOverride": "",
        "chunkSeconds": 300, "width": 1920, "height": 1080, "fps": 60, "bitrate": 8_000_000,
        "cameraId": "auto", "audio": true, "targetLuma": 0.42, "lockAfterMs": 1000, "darkSeconds": 3,
        "lowBattery": [20, 10], "stopBattery": 5, "tempWarnC": 42.0, "assumedDrainPctPerHour": 20.0,
        "ntfyServer": "https://ntfy.sh", "ntfyTopic": "", "port": 8080, "darkLuma": 0.15, "warmIdleMinutes": 10, "torch": "auto", "sound": false, "rotate180": false,   // rotate180 is iOS-only: set true if the picture comes out upside down
    ]

    public init() { v = Config.defaults }

    public func string(_ k: String) -> String { (v[k] as? String) ?? (Config.defaults[k] as? String) ?? "" }
    public func int(_ k: String) -> Int { (v[k] as? Int) ?? (Config.defaults[k] as? Int) ?? 0 }
    public func double(_ k: String) -> Double { (v[k] as? Double) ?? (v[k] as? Int).map(Double.init) ?? (Config.defaults[k] as? Double) ?? 0 }
    public func bool(_ k: String) -> Bool { (v[k] as? Bool) ?? (Config.defaults[k] as? Bool) ?? false }

    public var fps: Int { int("fps") }
    public var width: Int { int("width") }
    public var height: Int { int("height") }
    public var port: Int { int("port") }
    public var chunkSeconds: Int { max(5, int("chunkSeconds")) }
    public var shutterText: String {
        let o = string("shutterOverride")
        if !o.trimmingCharacters(in: .whitespaces).isEmpty { return o }
        return string("scene") == "indoor" ? string("shutterIndoor") : string("shutterOutdoor")
    }
    /// exposure time in seconds ("1/500" or "0.004")
    public var shutterSeconds: Double { Config.parseShutter(shutterText) }
    /// bitrate scaled by fps/30, capped at 60 Mbps (as on Android)
    public var videoBitrate: Int { min(60_000_000, int("bitrate") * max(1, fps) / 30) }

    public static func parseShutter(_ s: String) -> Double {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("1/"), let d = Double(t.dropFirst(2)), d > 0 { return 1.0 / d }
        return Double(t) ?? 0.002
    }

    /// Merge known keys from j, coercing numbers; unknown keys are dropped. Throws on a wrongly typed value.
    public func merging(_ j: [String: Any]) throws -> Config {
        var c = self
        for (k, dv) in Config.defaults {
            guard let nv = j[k] else { continue }
            if dv is String { guard let s = nv as? String else { throw ConfigError.bad(k) }; c.v[k] = s }
            else if dv is Bool { guard let b = nv as? Bool else { throw ConfigError.bad(k) }; c.v[k] = b }
            else if dv is Int { guard let n = nv as? NSNumber else { throw ConfigError.bad(k) }; c.v[k] = n.intValue }
            else if dv is Double { guard let n = nv as? NSNumber else { throw ConfigError.bad(k) }; c.v[k] = n.doubleValue }
            else if dv is [Int] { guard let a = nv as? [Any] else { throw ConfigError.bad(k) }; c.v[k] = a.compactMap { ($0 as? NSNumber)?.intValue } }
        }
        if let t = c.v["torch"] as? String { c.v["torch"] = t == "true" ? "on" : (t == "false" ? "off" : t) }
        return c
    }

    public func toJSON() -> [String: Any] { v }

    public static func load(_ url: URL) -> Config {
        guard let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let c = try? Config().merging(o) else {
            let c = Config(); try? c.save(url); return c
        }
        return c
    }

    public func save(_ url: URL) throws {
        let d = try JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])
        try d.write(to: url, options: .atomic)
    }
}

public enum ConfigError: Error { case bad(String) }
