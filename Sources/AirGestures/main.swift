import AVFoundation
import Foundation

let usage = """
Usage: AirGestures [options]

Watches the camera, recognizes hand gestures, and turns them into Mac actions.

Gestures:
  4 fingers swipe left/right   Previous/next desktop (wraps around at the ends)
  4 fingers swipe up/down      Mission Control / App Exposé
  2 fingers swipe left/right   Previous/next window on this desktop
  1 finger twirl               Cycle windows on this desktop
  Thumb–index pinch            Spread/close to zoom what's under the pointer
  Whole-hand pinch             Open hand closing to a beak shrinks the window; beak opening grows it
  Open hand → fist             Close the focused window

Output modes (default: live status line):
  --stream          One timestamped line per hand, ~15 per second
  --events          Only print changes (hand appeared/lost, pinch start/end, gestures)
  --joints          Also dump raw joint coordinates (implies --stream)

Other options:
  --dry-run         Recognize and log gestures but don't act on them
  --zoom-keys       Zoom with ⌘+ / ⌘− everywhere instead of trackpad-style pinch
  --camera <name>   Use the first camera whose name contains <name>
  --list-cameras    List available cameras and exit
  --swap-hands      Swap left/right if hands are still reported backwards
  -h, --help        Show this help

Acting on gestures needs Accessibility permission for your terminal app:
  System Settings → Privacy & Security → Accessibility

Follow events from another terminal:
  log stream --predicate 'subsystem == "com.airgestures"'
"""

let args = Array(CommandLine.arguments.dropFirst())

if args.contains("-h") || args.contains("--help") {
    print(usage)
    exit(0)
}

if args.contains("--list-cameras") {
    for device in CameraCapture.availableDevices() {
        print("• \(device.localizedName)")
    }
    exit(0)
}

let showJoints = args.contains("--joints")
let dryRun = args.contains("--dry-run")
let mode: HandLogger.Mode =
    args.contains("--events") ? .events
    : (args.contains("--stream") || showJoints) ? .stream
    : .live
let cameraQuery = args.firstIndex(of: "--camera").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }

// Line-buffer stdout so output shows up immediately even when piped (e.g. into tee).
setvbuf(stdout, nil, _IOLBF, 0)

let camera = CameraCapture()
let tracker = HandTracker(swapHands: args.contains("--swap-hands"))
let logger = HandLogger(mode: mode, showJoints: showJoints)
let recognizer = GestureRecognizer()
let actions = SystemActions()
actions.alwaysKeyboardZoom = args.contains("--zoom-keys")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func startCapture() {
    do {
        try camera.configure(cameraMatching: cameraQuery)
    } catch {
        fail("\(error)")
    }
    camera.onFrame = { pixelBuffer, time in
        tracker.process(pixelBuffer, timestamp: time, orientation: camera.orientation)
    }
    camera.start()
    print("AirGestures: watching \"\(camera.deviceName)\" — Ctrl-C to quit")
    if dryRun {
        print("Dry run: gestures are logged but not acted on.")
    } else if !SystemActions.ensureAccessibility() {
        print("""
        Gestures won't do anything until your terminal app has Accessibility permission:
        System Settings → Privacy & Security → Accessibility. Then restart AirGestures.
        """)
    }
}

// Consume hand frames as they arrive.
Task.detached {
    for await frame in tracker.frames {
        let gestures = recognizer.process(frame)
        logger.handle(frame, extra: recognizer.twirlStats)
        for gesture in gestures {
            logger.handle(gesture, performed: !dryRun)
            if !dryRun { actions.perform(gesture) }
        }
    }
}

// Clean shutdown on Ctrl-C so the camera light turns off.
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    camera.stop()
    tracker.finish()
    logger.finish()
    exit(0)
}
sigint.resume()

switch AVCaptureDevice.authorizationStatus(for: .video) {
case .authorized:
    startCapture()
case .notDetermined:
    AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
            if granted { startCapture() } else { fail("Camera access denied.") }
        }
    }
default:
    fail("""
    Camera access is blocked. Enable it for the app running this terminal in
    System Settings → Privacy & Security → Camera, then run again.
    """)
}

dispatchMain()
