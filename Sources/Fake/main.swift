import Foundation

// capture-ios-fake: the iOS app's real HTTP server + take bookkeeping (Sources/Shared) on macOS, with a fake camera.
// Chunks are a copy of --sample (a valid synthetic mp4 with --frames frames / --dur-ms ms). NOT a camera test.
//   capture-ios-fake --port 8092 --token abc --dir /tmp/x --sample s.mp4 --frames 60 --dur-ms 2000 [--clock-offset-ms 0]

var opt: [String: String] = ["port": "8092", "token": "faketoken", "dir": "/tmp/capture-ios-fake", "frames": "60", "dur-ms": "2000", "bind": "127.0.0.1"]
var a = Array(CommandLine.arguments.dropFirst())
while a.count >= 2 { if a[0].hasPrefix("--") { opt[String(a[0].dropFirst(2))] = a[1] }; a.removeFirst(2) }

final class FakeRecorder: RecorderBackend {
    weak var events: RecorderEvents?
    var live = LiveStats()
    let sample: URL?, frames: Int, durMs: Int
    private var dir: URL?, suffix = "", first: Int64 = 0, torch = "auto"
    init(sample: URL?, frames: Int, durMs: Int) { self.sample = sample; self.frames = frames; self.durMs = durMs; live.iso = 640; live.shutter = "1/500"; live.measuredFps = 60; live.locked = true }
    func start(dir: URL, config: Config, nameSuffix: String) throws {
        self.dir = dir; suffix = nameSuffix
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.18) { [self] in
            first = wallNowMs(); events?.firstFrame(wallMs: first)
            events?.chunkOpened(name: isoName(first) + suffix + ".mp4", wallMs: first)
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    func stop() {
        guard let dir, let sample else { return }
        let name = isoName(first) + suffix + ".mp4"
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        try? FileManager.default.copyItem(at: sample, to: dir.appendingPathComponent(name))
        events?.chunkClosed(name: name, frames: frames, durMs: durMs)
    }
    func setTorch(_ mode: String) { torch = mode }
    func previewJPEG() -> Data? { Data([0xFF, 0xD8, 0xFF, 0xD9]) }
    func previewWanted() {}
}

let dir = URL(fileURLWithPath: opt["dir"]!)
let rec = FakeRecorder(sample: opt["sample"].map { URL(fileURLWithPath: $0) }, frames: Int(opt["frames"]!)!, durMs: Int(opt["dur-ms"]!)!)
let take = TakeManager(dir: dir, token: opt["token"]!, backend: rec, deviceName: "fake-iphone") { DeviceInfo(battery: 87, plugged: true, tempC: 30, freeGB: 40) }
if let deny = opt["deny"] { take.permissionCheck = { _ in "camera/microphone not authorised (\(deny))" } }
// SIGUSR1 stands in for the iOS app leaving the foreground mid-take
signal(SIGUSR1, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
sigSrc.setEventHandler { take.interruptRecording(why: "app left the foreground") }
sigSrc.resume()
let port = UInt16(opt["port"]!)!
take.listen = { ["\(opt["bind"]!):\(port)"] }
let server = HttpServer(router: Router(take: take), port: port, bindHost: opt["bind"])
try server.start()
print("capture-ios-fake on \(opt["bind"]!):\(port)", terminator: "\n"); fflush(stdout)
dispatchMain()
