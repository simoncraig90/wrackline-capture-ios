import Foundation

/// Live numbers the recorder reports; surfaced in /status.json.
public struct LiveStats {
    public var iso = 0, camDrops = 0, encDrops = 0
    public var shutter = ""
    public var expNs: Int64 = 0
    public var luma = 0.0, flicker = 0.0, measuredFps = 0.0
    public var locked = false, torchOn = false
    public var torchReason = ""
    public var rotation = 0
    public init() {}
}

public struct DeviceInfo {
    public var battery = -1, plugged = false, tempC = 0.0, freeGB = 0.0
    public init(battery: Int = -1, plugged: Bool = false, tempC: Double = 0, freeGB: Double = 0) {
        self.battery = battery; self.plugged = plugged; self.tempC = tempC; self.freeGB = freeGB
    }
}

/// What the recorder tells the take bookkeeping (sidecar json). Called from any thread.
public protocol RecorderEvents: AnyObject {
    func firstFrame(wallMs: Int64)
    func chunkOpened(name: String, wallMs: Int64)
    func chunkClosed(name: String, frames: Int, durMs: Int)
    func recorderError(_ msg: String)
}

/// The camera side. The iOS app implements it with AVFoundation; the macOS test server with a fake.
public protocol RecorderBackend: AnyObject {
    var events: RecorderEvents? { get set }
    /// Open camera + audio and start writing chunk files into dir. Chunk names are isoName(firstFrameWallMs) + nameSuffix + ".mp4".
    func start(dir: URL, config: Config, nameSuffix: String) throws
    /// Finish and close every file; returns after chunkClosed has been reported for each.
    func stop()
    func setTorch(_ mode: String)
    func previewJPEG() -> Data?
    func previewWanted()
    var live: LiveStats { get }
}

public let isoFormatter: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS'Z'"; return f
}()

public func isoName(_ wallMs: Int64) -> String { isoFormatter.string(from: Date(timeIntervalSince1970: Double(wallMs) / 1000)) }
public func wallNowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
public func monoNowNs() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds) }
