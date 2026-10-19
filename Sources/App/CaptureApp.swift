import AVFoundation
import SwiftUI
import UIKit

/// Owns the recorder, the take bookkeeping and the HTTP server for the life of the app.
final class AppModel: ObservableObject {
    @Published var url = "starting..."
    @Published var token = ""
    @Published var recording = false
    @Published var recSeconds = 0
    @Published var line = ""
    @Published var warning = ""

    let take: TakeManager
    private let recorder = CameraRecorder()
    private var server: HttpServer?
    private var timer: Timer?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let tokenFile = docs.appendingPathComponent("token.txt")
        var tok = (try? String(contentsOf: tokenFile))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if tok.isEmpty { tok = DeviceProbe.newToken(); try? tok.write(to: tokenFile, atomically: true, encoding: .utf8) }
        token = tok
        take = TakeManager(dir: docs, token: tok, backend: recorder, deviceName: "iPhone SE (2020)") { DeviceProbe.info() }
        take.listen = { [weak self] in self?.listenAddresses() ?? [] }
    }

    private func listenAddresses() -> [String] {
        guard let ip = DeviceProbe.wifiAddress() else { return [] }
        return ["\(ip):\(take.config.port)"]
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true      // the screen must stay on: iOS cannot record from the background
        take.permissionCheck = { cfg in AppModel.permissionProblem(audio: cfg.bool("audio")) }
        // ask for camera AND microphone now; /start is refused (409) until both are answered "allow"
        let g = DispatchGroup()
        for t in [AVMediaType.video, .audio] { g.enter(); AVCaptureDevice.requestAccess(for: t) { _ in g.leave() } }
        g.notify(queue: .main) { [weak self] in
            if let p = AppModel.permissionProblem(audio: true) { self?.warning = p }
            self?.appActive()
        }
        let port = UInt16(take.config.port)
        let router = Router(take: take)
        let s = HttpServer(router: router, port: port, wifiOnly: true)
        s.onState = { [weak self] st in DispatchQueue.main.async { if st.hasPrefix("failed") { self?.warning = "HTTP server \(st)" } } }
        do { try s.start(); server = s } catch { warning = "HTTP server failed: \(error)" }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    /// nil when allowed; the microphone is only required while the config has audio on (the default).
    static func permissionProblem(audio: Bool) -> String? {
        func why(_ s: AVAuthorizationStatus, _ n: String) -> String? {
            switch s {
            case .authorized: return nil
            case .notDetermined: return "\(n) permission not answered yet: tap Allow on the phone"
            default: return "\(n) permission denied: Settings > Capture > \(n)"
            }
        }
        return why(AVCaptureDevice.authorizationStatus(for: .video), "Camera") ?? (audio ? why(AVCaptureDevice.authorizationStatus(for: .audio), "Microphone") : nil)
    }

    /// Inactive or background mid-take: finish the current chunk (mp4 closed, sidecar written), mark the take interrupted, do NOT resume.
    /// Runs off the main thread under a background task so iOS lets the writer finish.
    func appInactive() {
        guard take.recording else { recorder.cooldown(); return }
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "finish-chunk") { UIApplication.shared.endBackgroundTask(bg) }
        DispatchQueue.global(qos: .userInitiated).async { [take] in
            take.interruptRecording(why: "app left the foreground")
            recorder.cooldown()    // the warm session stops with the foreground; interruptRecording has already ended the take
            DispatchQueue.main.async { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }
        }
    }

    /// Foreground again: bring the camera up now so the first /start finds it running (warm). Needs both permissions; otherwise /start's own check explains.
    func appActive() {
        guard AppModel.permissionProblem(audio: take.config.bool("audio")) == nil else { return }
        recorder.warmUp(config: take.config)
    }

    private func refresh() {
        let st = take.status()
        let ip = DeviceProbe.wifiAddress()
        url = ip.map { "http://\($0):\(take.config.port)" } ?? "no Wi-Fi address (join the rig's Wi-Fi)"
        recording = st["recording"] as? Bool ?? false
        recSeconds = st["recSeconds"] as? Int ?? 0
        let l = take.backend.live
        line = "ISO \(l.iso)  shutter \(l.shutter.isEmpty ? "-" : l.shutter)  \(String(format: "%.0f", l.measuredFps)) fps  drops \(l.camDrops)/\(l.encDrops)  \(l.locked ? "focus/WB locked" : "free")"
        warning = (st["warnings"] as? [String: String])?.values.sorted().joined(separator: "; ") ?? ""
    }
}

struct ContentView: View {
    @ObservedObject var m: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Wrackline Capture").font(.title2.bold())
            Text(m.recording ? "RECORDING  \(m.recSeconds / 60)m \(m.recSeconds % 60)s" : "Idle - waiting for the director")
                .font(.title).foregroundColor(m.recording ? .red : .green)
            Group {
                Text("Address").font(.caption).foregroundColor(.secondary)
                Text(m.url).font(.system(.body, design: .monospaced))
                Text("Token").font(.caption).foregroundColor(.secondary)
                Text(m.token).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text("Put host \"\(m.url.replacingOccurrences(of: "http://", with: ""))\" and this token in the director's cameras.json.").font(.footnote)
            }
            Text(m.line).font(.system(.footnote, design: .monospaced))
            if !m.warning.isEmpty { Text(m.warning).foregroundColor(.orange).font(.footnote) }
            Spacer()
            Text("Keep this app open in the foreground with the screen on. iOS cannot record in the background: if you switch apps or lock the phone, recording stops. Plug the phone in and mount it landscape.")
                .font(.footnote).foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@main
struct CaptureApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ContentView(m: model).onAppear { model.start() }
        }
        .onChange(of: phase) { p in if p == .active { model.appActive() } else { model.appInactive() } }
    }
}
