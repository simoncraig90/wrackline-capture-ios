# capture-ios: the iPhone SE as a third 1080p60 camera (TICKET-133, route B)

A native iOS app that speaks the same HTTP API as `tools/capture-android`, so `tools/capture-android/director.py` drives it **unchanged**
(`/status.json /time /start /stop /marker /torch /calibrated /config /chunks /chunk/<name> /preview.jpg /`, `?t=TOKEN` or `X-Token`).

**Status (19 Oct 2026): the iOS build is UNVERIFIED.** The Mac has no Xcode, so the app has never been compiled for iOS, never run on the
phone, and the camera code (`Sources/App/CameraRecorder.swift`) is untested. What *is* verified: the HTTP server, take/sidecar logic and config
(`Sources/Shared`) compile on macOS and the unchanged director runs a full take against them (see "Tests").

## What it does
- 1080p at 60 fps (config `fps`, default 60 here; Android's default is 30), H.264 high profile, bitrate 8 Mbps x fps/30 (cap 60), keyframe every 1 s,
  AAC mono 44.1 kHz 96 kbps in mp4 chunks (`chunkSeconds`, default 300), exactly as the Android app. Audio is for sync only; the audio session is
  record-only, the app never plays a sound.
- Fixed shutter (`1/500` outdoor, `1/200` indoor, or `shutterOverride`, always clamped to the frame time), ISO is steered toward `targetLuma`,
  shutter only ever shortened. Focus and white balance lock `lockAfterMs` after Start (waits for AF, max 4 s). Video stabilisation off, HDR off.
- Sidecar `<take>.json` with the same fields (`marker`, `firstFrame`, `chunks[].frames/dur_ms`, `stop`, `frameStats`), chunk names
  `<UTC first-frame time>_<label>.mp4`. The first-frame wall time comes from the frame's capture timestamp, not from when the callback ran.
- Files are served from the app's Documents folder with HTTP Range, same name rule, so the director's `pull` works.
- Screen stays on (`isIdleTimerDisabled`). **iOS cannot record in the background**: keep the app open, screen on, phone plugged in, mounted landscape.
  Going inactive/background mid-take finishes the current chunk (mp4 closed, sidecar written), sets `/status.json` `interrupted: true` (+ `interruptedWhy`,
  a warning) and does NOT resume; the next `/start` clears it. Camera and microphone are requested at launch; `/start` answers 409 `{"ok":false,"msg":"permission: ..."}`
  and creates no take until both are allowed (microphone only while config `audio` is on). All of this is iOS-unverified until the phone.
- Not on iOS: camera-moved detection (`/calibrated` answers 409, as Android does when it cannot calibrate; the sidecar says `motion.supported=false`),
  120/240 fps, `cameraId`, ntfy alerts. Temperature is derived from the thermal state (30/36/42/48 C), not measured. No Bonjour (Android has none either).
- iOS-only config key `rotate180` (POST `/config` or edit `config.json`): set `true` if the picture comes out upside down.
- Port 8080, Wi-Fi interface only. Token: generated on first launch, shown on screen and in `Documents/token.txt`.

## What Simon does (one-time)
1. Install **Xcode** from the Mac App Store (several GB; then open it once and accept the licence / let it install components).
2. Xcode > Settings > Accounts > **+** > Apple ID: sign in with the free Apple ID. A "Personal Team" appears. Note its 10-character Team ID
   (Accounts > select the team; or after step 6 it shows in the project's Signing tab).
3. Install XcodeGen: `brew install xcodegen` (this Mac has no Homebrew: install it from https://brew.sh first, per-user, or download the
   release zip from https://github.com/yonaskolb/XcodeGen/releases and use `./xcodegen/bin/xcodegen` in place of `xcodegen` below).
4. Plug the iPhone in with a **cable** once. Unlock it, tap **Trust This Computer**.
5. On the iPhone: Settings > Privacy & Security > **Developer Mode** > on (the switch appears after Xcode has seen the phone; it restarts the phone).
6. Build and install (from the repo):
   ```
   cd tools/capture-ios
   xcodegen generate                      # writes WracklineCapture.xcodeproj (git-ignored)
   xcodebuild -project WracklineCapture.xcodeproj -scheme Capture -configuration Release \
     -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates \
     DEVELOPMENT_TEAM=YOURTEAMID build
   xcrun devicectl list devices           # note the device name or identifier
   xcrun devicectl device install app --device "<name or id>" build/Build/Products/Release-iphoneos/Capture.app
   xcrun devicectl device process launch --device "<name or id>" com.wrackline.capture
   ```
   (Or put the team id in `project.yml` under `DEVELOPMENT_TEAM` once.) `devicectl` needs Xcode 15+ and drives phones on iOS 17+ best; if the
   SE is on an older iOS, open `WracklineCapture.xcodeproj` in Xcode and press Run with the phone selected.
7. First launch: on the iPhone Settings > General > **VPN & Device Management** > your Apple ID > **Trust**. Then open the app and allow Camera,
   Microphone and Local Network.
8. Wireless installs afterwards: Xcode > Window > Devices and Simulators > select the phone > tick **Connect via network**. With the phone on the
   same Wi-Fi, `xcrun devicectl list devices` shows it and steps 6's install/launch work without the cable.
9. **Free accounts expire the app after 7 days.** Re-run the xcodebuild + install lines (about a minute; settings and the token survive).
   SideStore could automate the refresh later. A free account also allows only 3 side-loaded apps at a time.
10. Director: add the phone to `cameras.json` using the address and token shown in the app:
    `{"name": "iphone", "host": "192.168.0.NN:8080", "token": "<from the app screen>"}`.

Orientation: mount the phone landscape. If clips are upside down, POST `{"rotate180": true}` to `/config` (or `config.json`) and Start again.

## Layout
- `Sources/Shared/` plain Swift (Foundation + Network only, builds on macOS): `Config`, `TakeManager` (take ids, sidecar, status), `Router` (the API),
  `HttpServer` (NWListener), `Backend` (the recorder protocol).
- `Sources/App/` iOS only: `CameraRecorder` (AVFoundation), `CaptureApp` (SwiftUI), `Device`.
- `Sources/Fake/main.swift` + `tests/` macOS test server and director test.
- `project.yml` XcodeGen definition (bundle id `com.wrackline.capture`, iOS 16, signing team is a build setting).

## Tests (Mac, no Xcode)
```
tools/capture-ios/tests/run.sh              # builds capture-ios-fake with the CLT swiftc, runs the unchanged director.py against it
```
Drives `/api/start /torch /stop /calibrated /pull` through the director and checks: clock sync, marker, sidecar fetched, closed chunk with frame
count, pull downloads and verifies the mp4 and sidecar. It uses a fake camera (a copy of a synthetic mp4), so it proves the protocol, not the camera.
Planted-fault check: `tests/run.sh <dir with Sources/Shared copied and Router.swift's "wall_ms" in /time renamed>` goes red (see ticket note).
Syntax check of the iOS-only files: `swiftc -parse Sources/App/*.swift Sources/Shared/*.swift`.

## First things to check on the phone (not yet verified)
1. Does the SE give 1080p60 (status `measuredFps` ~60, `cameraDrops` 0)? 2. Upright picture. 3. Chunk rotation at 300 s (set `chunkSeconds` 10 to test);
audio is dropped for under one buffer (~20 ms) at each chunk boundary. 4. Director `pull` verification of a real mp4. 5. Heat after 10 minutes in the sun.
