import AVFoundation
import CoreImage
import UIKit

enum CameraError: Error, CustomStringConvertible {
    case denied(String), noDevice(String), config(String)
    var description: String {
        switch self { case .denied(let s): return "permission denied: \(s)"; case .noDevice(let s): return "no device: \(s)"; case .config(let s): return s }
    }
}

/// AVFoundation recorder: 1080p at the configured fps (60), H.264 + AAC mono in mp4 chunks, exposure/focus/white balance locked like the Android app.
/// Everything the sample-buffer callbacks touch lives on `q` (video and audio share one serial queue), so no locks are needed there.
final class CameraRecorder: NSObject, RecorderBackend, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    weak var events: RecorderEvents?
    var live: LiveStats { statLock.lock(); defer { statLock.unlock() }; return _live }

    private let q = DispatchQueue(label: "wrk.capture", qos: .userInteractive)
    /// Session configuration + startRunning/stopRunning live here, NEVER on `q` and never waited on under TakeManager's lock: both calls randomly take 9 s on the SE
    /// (TICKET-133), and on `q` that gapped the frames. Nothing that holds TakeManager's lock ever does sessionQ.sync.
    private let sessionQ = DispatchQueue(label: "wrk.capture.session", qos: .userInitiated)
    /// EVERY event to TakeManager goes through here, in order: its handlers take TakeManager's lock, and the callers of start()/stop() hold that lock while
    /// waiting on q (q.sync), so a handler called directly from q or sessionQ could deadlock against them.
    private let eventQ = DispatchQueue(label: "wrk.capture.events")
    private func emit(_ f: @escaping (RecorderEvents) -> Void) { eventQ.async { [weak self] in if let e = self?.events { f(e) } } }
    private func report(_ msg: String) { emit { $0.recorderError(msg) } }
    private let statLock = NSLock()
    private var _live = LiveStats()
    private func updateLive(_ f: (inout LiveStats) -> Void) { statLock.lock(); f(&_live); statLock.unlock() }

    /// Session state is shared between sessionQ, q and the HTTP threads: all of it behind stateLock (never held across a blocking call).
    private let stateLock = NSLock()
    private var _session: AVCaptureSession?
    private var _device: AVCaptureDevice?
    private var _running = false      // a take is active (start() .. stop())
    private var _accepting = false    // sample buffers are written: a take is active AND the session for it is up
    private var gen = 0               // one per start(); stale sessionQ closures compare it
    private var warmKey = ""
    private var lastConfig = Config()
    private var idleItem: DispatchWorkItem?
    private var session: AVCaptureSession? { stateLock.lock(); defer { stateLock.unlock() }; return _session }
    private var device: AVCaptureDevice? { stateLock.lock(); defer { stateLock.unlock() }; return _device }
    private var isRunning: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _running }
    private var accepting: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _accepting }
    private var cfg = Config()
    private var dir: URL!
    private var suffix = ""

    // writer state (q only)
    private var writer: AVAssetWriter?
    private var vIn: AVAssetWriterInput?
    private var aIn: AVAssetWriterInput?
    private var chunkName = ""
    private var chunkFirstPTS = CMTime.invalid
    private var chunkLastPTS = CMTime.invalid
    private var chunkFrames = 0
    private var gotFirstFrame = false
    private let finishGroup = DispatchGroup()

    // exposure loop (q only)
    private var curISO: Float = 400
    private var curDur = CMTime(value: 1, timescale: 500)
    private var frameCount = 0
    private var darkSince: CFAbsoluteTime = 0
    private var lockedAF = false
    private var fpsWindowStart = CMTime.invalid
    private var fpsWindowFrames = 0
    private var torchMode = "auto"
    private var frameDuration = CMTime.invalid

    // preview
    private var previewUntil: CFAbsoluteTime = 0
    private var lastPreview: CFAbsoluteTime = 0
    private var previewData: Data?
    private let previewLock = NSLock()
    private let ci = CIContext()

    func previewWanted() { previewUntil = CFAbsoluteTimeGetCurrent() + 10 }
    func previewJPEG() -> Data? { previewLock.lock(); defer { previewLock.unlock() }; return previewData }

    // MARK: start / stop

    /// TICKET-133 diagnosis: some /start and /stop calls stall ~9 s on the SE. Every start/stop step reports itself when it takes > 0.5 s.
    @discardableResult private func timed<T>(_ step: String, _ f: () throws -> T) rethrows -> T {
        let t0 = CACurrentMediaTime()
        defer { let d = CACurrentMediaTime() - t0; if d > 0.5 { report("slow step \(step): \(String(format: "%.1f", d)) s") } }
        return try f()
    }

    /// Warm session (TICKET-133): startRunning/stopRunning randomly take 9 s on the SE, so the session is kept RUNNING between takes.
    /// /start only arms the writer (flag + q state) and returns at once; /stop only finishes the chunk and turns the torch off.
    /// The session itself starts when the app becomes active (warmUp), stops when the app leaves the foreground (cooldown) or after
    /// `warmIdleMinutes` without a take (0 = never). Changing resolution, fps or audio rebuilds the session on sessionQ; /start never waits for it.
    func warmUp(config: Config) {
        stateLock.lock(); lastConfig = config; stateLock.unlock()
        sessionQ.async { [weak self] in
            guard let self else { return }
            do { try self.ensureSession(config) } catch { self.report("warm-up failed: \(error)") }
            self.scheduleIdleStop()
        }
    }

    /// App inactive/background: stop the camera (unless a take is somehow still active, which the caller has already stopped).
    func cooldown() {
        sessionQ.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.teardownSession()
            self.timed("audio deactivate") { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        }
    }

    private func sessionKey(_ c: Config) -> String { "\(c.width)x\(c.height)@\(c.fps) audio=\(c.bool("audio"))" }

    func start(dir: URL, config: Config, nameSuffix: String) throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { throw CameraError.denied("camera (Settings > Capture > Camera)") }
        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil else { throw CameraError.noDevice("back camera") }
        // q-owned state is reset on q (short; q never waits on a session call, and callbacks ignore frames until `accepting`)
        q.sync {
            self.dir = dir; cfg = config; suffix = nameSuffix; torchMode = config.string("torch")
            gotFirstFrame = false; writer = nil; chunkName = ""; frameCount = 0; lockedAF = false; darkSince = 0; fpsWindowStart = .invalid; fpsWindowFrames = 0
        }
        updateLive { $0 = LiveStats() }
        let key = sessionKey(config)
        stateLock.lock()
        idleItem?.cancel(); idleItem = nil
        gen += 1; let g = gen
        lastConfig = config
        let warm = _session?.isRunning == true && warmKey == key
        _running = true; _accepting = warm      // warm: the next sample buffer opens the chunk. Not warm: sessionQ flips it once the session is up.
        stateLock.unlock()
        let queuedAt = CACurrentMediaTime()
        sessionQ.async { [weak self] in
            guard let self else { return }
            let waited = CACurrentMediaTime() - queuedAt
            if waited > 0.5 { self.report("slow step start: session queue busy (startRunning/stopRunning in flight): \(String(format: "%.1f", waited)) s") }
            self.beginTake(config, gen: g)
        }
    }

    /// sessionQ: make sure the right session is running, re-arm exposure/focus for this take, then let frames through.
    private func beginTake(_ config: Config, gen g: Int) {
        stateLock.lock(); let current = (gen == g && _running); stateLock.unlock()
        guard current else { return }   // /stop (or a newer /start) already happened
        do {
            try timed("ensure session") { try ensureSession(config) }
            let lockMs = max(200, min(config.int("lockAfterMs"), 4000))
            try timed("arm exposure") { try armExposure(config, lockMs: lockMs) }
        } catch {
            report("camera error: \(error)")
            return
        }
        stateLock.lock(); if gen == g && _running { _accepting = true }; stateLock.unlock()
    }

    /// sessionQ only. Builds + starts the session if there is none, or the stored one was built for a different resolution/fps/audio.
    private func ensureSession(_ config: Config) throws {
        let key = sessionKey(config)
        if let s = session, warmKey == key {
            if !s.isRunning { timed("startRunning") { s.startRunning() }; timed("reassert after start") { reassertFrameDuration(reason: "after restart") } }
            return
        }
        if session != nil { teardownSession() }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw CameraError.noDevice("back camera") }
        let s = AVCaptureSession()
        s.beginConfiguration()
        // inputPriority: the session must not pick its own preset/format/frame rate over ours (a preset can silently reset activeFormat + durations)
        s.sessionPreset = .inputPriority
        let vin = try timed("video input") { try AVCaptureDeviceInput(device: dev) }
        guard s.canAddInput(vin) else { throw CameraError.config("cannot add camera input") }
        s.addInput(vin)

        let vout = AVCaptureVideoDataOutput()
        vout.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        vout.alwaysDiscardsLateVideoFrames = false
        vout.setSampleBufferDelegate(self, queue: q)
        guard s.canAddOutput(vout) else { throw CameraError.config("cannot add video output") }
        s.addOutput(vout)

        if config.bool("audio") {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, let mic = AVCaptureDevice.default(for: .audio),
               let ain = try? AVCaptureDeviceInput(device: mic) {
                // record-only audio session: the app never plays a sound
                s.automaticallyConfiguresApplicationAudioSession = false
                timed("audio category") { try? AVAudioSession.sharedInstance().setCategory(.record, mode: .videoRecording, options: []) }
                timed("audio setActive") { try? AVAudioSession.sharedInstance().setActive(true) }
                let aout = AVCaptureAudioDataOutput()
                aout.setSampleBufferDelegate(self, queue: q)
                if s.canAddInput(ain), s.canAddOutput(aout) { s.addInput(ain); s.addOutput(aout) } else { report("audio unavailable: cannot add") }
            } else { report("audio unavailable: microphone permission or device missing") }
        }

        // format + frame durations INSIDE begin/commitConfiguration (Apple's documented order), so startRunning does not reset them
        let fd = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        try timed("device lock 1") { try dev.lockForConfiguration() }
        do {
            try selectFormat(dev, config)
            dev.activeVideoMinFrameDuration = fd; dev.activeVideoMaxFrameDuration = fd
            if dev.activeFormat.isVideoHDRSupported { dev.automaticallyAdjustsVideoHDREnabled = false; dev.isVideoHDREnabled = false }
            // low-light boost lowers the frame rate in dim rooms (the 16.5 fps indoor take)
            if dev.isLowLightBoostSupported { dev.automaticallyEnablesLowLightBoostWhenAvailable = false }
        } catch { dev.unlockForConfiguration(); throw error }
        dev.unlockForConfiguration()
        if let conn = vout.connection(with: .video), conn.isVideoStabilizationSupported { conn.preferredVideoStabilizationMode = .off }
        timed("commitConfiguration") { s.commitConfiguration() }

        stateLock.lock(); _session = s; _device = dev; warmKey = key; frameDuration = fd; stateLock.unlock()
        // the device lock is NOT held across startRunning (it stalled it 9.0 s on ~1 start in 3, SE 19 Oct)
        timed("startRunning") { s.startRunning() }
        timed("reassert after start") { reassertFrameDuration(reason: "after startRunning") }
    }

    /// sessionQ only. Stops the camera and forgets the session (warm state gone; the next take rebuilds it).
    private func teardownSession() {
        stateLock.lock(); let s = _session; _session = nil; _device = nil; warmKey = ""; stateLock.unlock()
        timed("stopRunning") { s?.stopRunning() }
    }

    /// sessionQ only. Per take: fixed shutter (clamped to the frame time), ISO from the metering loop, continuous AF/WB until the focus lock.
    private func armExposure(_ config: Config, lockMs: Int) throws {
        guard let dev = device else { throw CameraError.noDevice("camera session gone") }
        try timed("device lock 2") { try dev.lockForConfiguration() }
        let want = config.shutterSeconds
        let dur = min(max(want, dev.activeFormat.minExposureDuration.seconds), min(dev.activeFormat.maxExposureDuration.seconds, 1.0 / Double(config.fps)))
        let cd = CMTime(seconds: dur, preferredTimescale: 1_000_000)
        let iso = min(max(400, dev.activeFormat.minISO), dev.activeFormat.maxISO)
        dev.setExposureModeCustom(duration: cd, iso: iso, completionHandler: nil)
        if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
        if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
        dev.isSubjectAreaChangeMonitoringEnabled = false
        dev.unlockForConfiguration()
        updateLive { $0.shutter = "1/\(Int((1.0 / dur).rounded()))" }
        q.async { [weak self] in
            self?.curDur = cd; self?.curISO = iso
            self?.q.asyncAfter(deadline: .now() + .milliseconds(lockMs)) { [weak self] in self?.lockFocusAndWB(retries: 6) }
        }
    }

    /// sessionQ: after a take, stop the camera once `warmIdleMinutes` pass without another one (0 = never).
    private func scheduleIdleStop() {
        stateLock.lock()
        idleItem?.cancel(); idleItem = nil
        let minutes = lastConfig.int("warmIdleMinutes")
        guard minutes > 0, _session != nil, !_running else { stateLock.unlock(); return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isRunning else { return }
            self.report("camera idle \(minutes) min: stopping the warm session")
            self.teardownSession()
            self.timed("audio deactivate") { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        }
        idleItem = item
        stateLock.unlock()
        sessionQ.asyncAfter(deadline: .now() + .seconds(minutes * 60), execute: item)
    }

    /// Re-set min/max frame duration (lock, set, unlock). Called once after startRunning and again at the focus lock; reports if the device had moved off the target.
    private func reassertFrameDuration(reason: String) {
        stateLock.lock(); let fd = frameDuration; stateLock.unlock()
        guard let dev = device, fd.isValid else { return }
        let off = CMTimeCompare(dev.activeVideoMinFrameDuration, fd) != 0 || CMTimeCompare(dev.activeVideoMaxFrameDuration, fd) != 0
        do {
            try dev.lockForConfiguration()
            dev.activeVideoMinFrameDuration = fd; dev.activeVideoMaxFrameDuration = fd
            dev.unlockForConfiguration()
            if off { report("frame duration was reset (\(reason)); re-set to 1/\(fd.timescale)") }
        } catch { report("frame duration re-set failed (\(reason)): \(error)") }
    }

    private func selectFormat(_ dev: AVCaptureDevice, _ config: Config) throws {
        let w = Int32(config.width), h = Int32(config.height), fps = Double(config.fps)
        let sized = dev.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == w && d.height == h && CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        // prefer: a range that reaches the fps, non-HDR, the one with the least headroom above fps
        let ok = sized.filter { f in f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps && $0.minFrameRate <= fps } }
        guard let best = ok.sorted(by: { a, b in
            if a.isVideoHDRSupported != b.isVideoHDRSupported { return !a.isVideoHDRSupported }
            return (a.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0) < (b.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }).first else {
            let maxs = sized.flatMap { $0.videoSupportedFrameRateRanges.map(\.maxFrameRate) }.max() ?? 0
            throw CameraError.config("no \(w)x\(h) format reaches \(Int(fps)) fps (best \(Int(maxs)) fps)")
        }
        dev.activeFormat = best
    }

    private func lockFocusAndWB(retries: Int) {
        guard accepting, !lockedAF, let dev = device else { return }
        if retries == 6 { reassertFrameDuration(reason: "at focus lock") }
        if dev.isAdjustingFocus && retries > 0 { q.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in self?.lockFocusAndWB(retries: retries - 1) }; return }
        do {
            try dev.lockForConfiguration(); defer { dev.unlockForConfiguration() }
            if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
            if dev.isWhiteBalanceModeSupported(.locked) {
                var g = dev.deviceWhiteBalanceGains
                let m = dev.maxWhiteBalanceGain
                g.redGain = min(max(1, g.redGain), m); g.greenGain = min(max(1, g.greenGain), m); g.blueGain = min(max(1, g.blueGain), m)
                dev.setWhiteBalanceModeLocked(with: g, completionHandler: nil)
            }
            lockedAF = true; updateLive { $0.locked = true }
        } catch { report("focus/WB lock failed: \(error)") }
    }

    /// Finishes the chunk and turns the torch off. The session keeps running (warm); the idle timer is armed.
    func stop() {
        stateLock.lock()
        guard _running else { stateLock.unlock(); return }
        _running = false; _accepting = false; gen += 1
        stateLock.unlock()
        // accepting=false makes the sample callbacks ignore frames; q.sync then waits out any callback already inside, so nothing can turn the torch back on
        timed("stop finishChunk on q") { q.sync { self.finishChunk() } }
        timed("stop torch off") { setTorchRaw(false, reason: "stopped") }
        timed("stop finishWriting wait") { _ = finishGroup.wait(timeout: .now() + 20) }
        sessionQ.async { [weak self] in self?.scheduleIdleStop() }
    }

    // MARK: sample buffers (q)

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard accepting, CMSampleBufferDataIsReady(sb) else { return }
        if output is AVCaptureVideoDataOutput { video(sb) } else { audio(sb) }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput { updateLive { $0.camDrops += 1 } }
    }

    private func wallMs(forPTS pts: CMTime) -> Int64 {
        let ageS = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), pts))
        return wallNowMs() - Int64((ageS * 1000).rounded())
    }

    private func video(_ sb: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if !gotFirstFrame { gotFirstFrame = true; let wm = wallMs(forPTS: pts); emit { $0.firstFrame(wallMs: wm) } }
        if writer != nil, CMTimeGetSeconds(CMTimeSubtract(pts, chunkFirstPTS)) >= Double(cfg.chunkSeconds) { finishChunk() }
        if writer == nil { openChunk(first: sb, pts: pts) }
        if let w = writer, w.status == .writing, let vIn {
            if vIn.isReadyForMoreMediaData, vIn.append(sb) { chunkFrames += 1; chunkLastPTS = pts; measureFps(pts) } else { updateLive { $0.encDrops += 1 } }
        } else if let w = writer, w.status == .failed { report("writer failed: \(w.error?.localizedDescription ?? "?")") }
        frameCount += 1
        if frameCount % 6 == 0, let px = CMSampleBufferGetImageBuffer(sb) { meter(px) }
        let now = CFAbsoluteTimeGetCurrent()
        if now < previewUntil, now - lastPreview > 0.5, let px = CMSampleBufferGetImageBuffer(sb) { lastPreview = now; makePreview(px) }
    }

    private func audio(_ sb: CMSampleBuffer) {
        guard let w = writer, w.status == .writing, let aIn, aIn.isReadyForMoreMediaData else { return }
        if CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb), chunkFirstPTS) < 0 { return }   // before this chunk's first video frame
        aIn.append(sb)
    }

    private func openChunk(first sb: CMSampleBuffer, pts: CMTime) {
        let firstWall = wallMs(forPTS: pts)
        let name = isoName(firstWall) + suffix + ".mp4"
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let vs: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: cfg.width, AVVideoHeightKey: cfg.height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: cfg.videoBitrate, AVVideoMaxKeyFrameIntervalKey: cfg.fps,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel, AVVideoAllowFrameReorderingKey: false,
                    AVVideoExpectedSourceFrameRateKey: cfg.fps,
                ] as [String: Any],
            ]
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: vs, sourceFormatHint: CMSampleBufferGetFormatDescription(sb))
            v.expectsMediaDataInRealTime = true
            if cfg.bool("rotate180") { v.transform = CGAffineTransform(rotationAngle: .pi) }
            guard w.canAdd(v) else { throw CameraError.config("writer rejects video input") }
            w.add(v)
            if cfg.bool("audio") {
                let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
                ])
                a.expectsMediaDataInRealTime = true
                if w.canAdd(a) { w.add(a); aIn = a } else { aIn = nil }
            } else { aIn = nil }
            guard w.startWriting() else { throw CameraError.config("startWriting: \(w.error?.localizedDescription ?? "?")") }
            w.startSession(atSourceTime: pts)
            writer = w; vIn = v; chunkName = name; chunkFirstPTS = pts; chunkLastPTS = pts; chunkFrames = 0
            emit { $0.chunkOpened(name: name, wallMs: firstWall) }
        } catch {
            writer = nil; report("cannot open chunk: \(error)")
        }
    }

    private func finishChunk() {
        guard let w = writer else { return }
        let name = chunkName, frames = chunkFrames
        // truth check: frames actually appended over their PTS span (n frames span n-1 intervals)
        let spanS = CMTimeGetSeconds(CMTimeSubtract(chunkLastPTS, chunkFirstPTS))
        let writtenFps = frames >= 2 && spanS > 0 ? Double(frames - 1) / spanS : 0
        let fdur = 1.0 / Double(max(1, cfg.fps))
        let durMs = Int(((CMTimeGetSeconds(CMTimeSubtract(chunkLastPTS, chunkFirstPTS)) + fdur) * 1000).rounded())
        vIn?.markAsFinished(); aIn?.markAsFinished()
        writer = nil; vIn = nil; aIn = nil
        finishGroup.enter()
        w.finishWriting { [weak self] in
            // leave BEFORE reporting: stop() waits on finishGroup while TakeManager.stopRecording holds its lock, and the events below
            // take that lock, so reporting first stalled every /stop for the full 20 s wait timeout (measured 20.3 s on the SE, 19 Oct)
            self?.finishGroup.leave()
            if w.status == .completed { self?.emit { $0.chunkClosed(name: name, frames: frames, durMs: durMs, writtenFps: writtenFps) } }
            else { self?.report("chunk \(name) failed: \(w.error?.localizedDescription ?? "?")") }
        }
    }

    // MARK: metering, fps, torch, preview

    private func measureFps(_ pts: CMTime) {
        if !fpsWindowStart.isValid { fpsWindowStart = pts; fpsWindowFrames = 0 }
        fpsWindowFrames += 1
        let dt = CMTimeGetSeconds(CMTimeSubtract(pts, fpsWindowStart))
        if dt >= 1.0 { let f = Double(fpsWindowFrames) / dt; updateLive { $0.measuredFps = (f * 10).rounded() / 10 }; fpsWindowStart = pts; fpsWindowFrames = 0 }
    }

    /// mean luma of a subsampled centre region (gamma-encoded, 0...1); then a gentle ISO step toward targetLuma. The shutter is only ever shortened.
    private func meter(_ px: CVPixelBuffer) {
        guard let dev = device else { return }
        CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(px, 0) else { return }
        let w = CVPixelBufferGetWidthOfPlane(px, 0), h = CVPixelBufferGetHeightOfPlane(px, 0), bpr = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        var sum = 0, n = 0
        for y in stride(from: h / 8, to: h * 7 / 8, by: 24) {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: w / 8, to: w * 7 / 8, by: 24) { sum += Int(row[x]); n += 1 }
        }
        guard n > 0 else { return }
        let luma = (Double(sum) / Double(n) - 16) / 219
        let target = cfg.double("targetLuma"), f = dev.activeFormat
        var iso = curISO, dur = curDur, shortened = false
        if abs(luma - target) > 0.04 {
            let ratio = Float(min(1.6, max(0.6, pow(target / max(luma, 0.03), 0.5))))
            iso = min(max(curISO * ratio, f.minISO), f.maxISO)
            if luma > target * 1.5 && curISO <= f.minISO * 1.05 {   // too bright even at base ISO: shorten the shutter, never lengthen
                dur = CMTime(seconds: max(dur.seconds * 0.7, f.minExposureDuration.seconds), preferredTimescale: 1_000_000); shortened = true
            }
            if abs(iso - curISO) > 1 || shortened {
                do { try dev.lockForConfiguration(); dev.setExposureModeCustom(duration: dur, iso: iso, completionHandler: nil); dev.unlockForConfiguration(); curISO = iso; curDur = dur }
                catch { report("exposure: \(error)") }
            }
        }
        let atCeiling = curISO >= f.maxISO * 0.95
        let now = CFAbsoluteTimeGetCurrent()
        if atCeiling && luma < cfg.double("darkLuma") {
            if darkSince == 0 { darkSince = now }
            if now - darkSince > Double(cfg.int("darkSeconds")) { report("too dark - add light"); darkSince = now }
        } else { darkSince = 0 }
        if torchMode == "on" { setTorchRaw(true, reason: "on (config)") }
        else if torchMode == "auto" { setTorchRaw(atCeiling, reason: atCeiling ? "auto: ISO at ceiling" : "auto: not needed (ISO \(Int(curISO)))") }
        else { setTorchRaw(false, reason: "off (config)") }
        updateLive { $0.luma = luma; $0.iso = Int(self.curISO); $0.expNs = Int64(self.curDur.seconds * 1e9); $0.shutter = "1/\(Int((1.0 / max(self.curDur.seconds, 1e-6)).rounded()))" }
    }

    func setTorch(_ mode: String) {
        q.async { [self] in
            torchMode = mode
            if mode == "off" { setTorchRaw(false, reason: "off (config)") } else if mode == "on" && accepting { setTorchRaw(true, reason: "on (config)") }
        }
    }

    private func setTorchRaw(_ on: Bool, reason: String) {
        guard let dev = device, dev.hasTorch else { return }
        updateLive { $0.torchReason = reason }
        guard dev.isTorchActive != on else { updateLive { $0.torchOn = on }; return }
        do {
            try dev.lockForConfiguration(); defer { dev.unlockForConfiguration() }
            if on { try dev.setTorchModeOn(level: 1.0) } else { dev.torchMode = .off }
            updateLive { $0.torchOn = on }
        } catch { report("torch: \(error)") }
    }

    private func makePreview(_ px: CVPixelBuffer) {
        let img = CIImage(cvPixelBuffer: px)
        let scale = 640.0 / img.extent.width
        let small = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        if let d = ci.jpegRepresentation(of: small, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [:]) {
            previewLock.lock(); previewData = d; previewLock.unlock()
        }
    }
}
