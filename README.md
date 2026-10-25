# AirGestures — proposed macOS camera-control stack

Research and implementation plan, revised 11 October 2026. This is a separate proposed project; no camera capture or gesture injection is running yet.

## Decision: C++ core with thin Objective-C++ adapters

Use modern C++ (C++20) for the gesture engine, state, configuration and tests. Apple's frameworks (AVFoundation, Vision, AppKit, CoreGraphics, ApplicationServices) are Objective-C/C APIs, so the macOS adapters are written in Objective-C++ (`.mm` files), which calls them directly with no binding layer or FFI crates. This matches the language already used by Glasswork's core, so the same toolchain, debugger and habits apply.

The split keeps the platform-specific code small and the logic portable and testable:

- **`core/` — pure C++, no Apple headers.** Landmark types, smoothing, gesture state machine, config, action log. Builds and tests anywhere, with no camera needed.
- **`platform/macos/` — Objective-C++ (ARC on).** Camera capture, Vision requests, event injection, Accessibility, menu-bar UI. Keep each adapter behind a small C++ interface (`ICameraSource`, `IHandTracker`, `IActionSink`) so the core never sees an `NSObject`.

Memory-safety discipline is by convention and tooling, not by the language: RAII and `std::unique_ptr` for ownership, `std::span`/`std::string_view` for non-owning views, no raw `new`/`delete`, ARC for Objective-C objects, and care with block captures (use `__weak` or copy needed values to avoid retain cycles and dangling references). Enforce it with AddressSanitizer, UndefinedBehaviorSanitizer and ThreadSanitizer in CI-style local runs, plus `clang-tidy` and `-Wall -Wextra -Wconversion`.

| Layer | Choice | Purpose |
| --- | --- | --- |
| Language/build | C++20 (Apple Clang), Objective-C++ for adapters, CMake + Ninja | Typed state machine, application logic, native frameworks |
| Camera | AVFoundation: `AVCaptureSession`, `AVCaptureVideoDataOutput` | Built-in or selected external camera; sample buffers delivered on a dedicated queue |
| Hand landmarks | Vision: `VNDetectHumanHandPoseRequest` | On-device hand pose observations, joint confidence and positions |
| UI | AppKit + Foundation from Objective-C++ | Native menu-bar app, settings window, Liquid Glass on macOS 26+ |
| Output | CoreGraphics events and ApplicationServices Accessibility | Scrolling, keys, pointer actions, supported window actions |
| Settings | [toml++](https://github.com/marzer/tomlplusplus) (header-only) | Gesture mappings, calibration |
| Logging | `os_log` / `os_signpost` | Local timing and counters; signposts show up in Instruments |
| Tests | Catch2 or GoogleTest via CTest, recorded landmark fixtures, Google Benchmark later | Deterministic gestures, false-trigger tests, latency measurements |

Vendor or pin third-party libraries (toml++, the test framework) at specific versions rather than floating on latest. Start with GCD serial queues and a bounded latest-frame slot (a mutex-protected single-element buffer); no async framework and no webview are needed for the first prototype.

## Suggested layout

```
AirGestures/
├── CMakeLists.txt
├── core/                 # pure C++20, no Apple headers
│   ├── landmarks.hpp     # Hand, Joint, confidence, normalized coordinates
│   ├── smoothing.{hpp,cpp}
│   ├── gesture_engine.{hpp,cpp}
│   ├── config.{hpp,cpp}
│   └── interfaces.hpp    # ICameraSource, IHandTracker, IActionSink
├── platform/macos/       # Objective-C++ (.mm), ARC enabled
│   ├── camera_source.mm
│   ├── vision_tracker.mm
│   ├── event_sink.mm     # CGEvent + Accessibility
│   └── menu_app.mm
├── tests/                # fixtures + engine tests, run on core only
└── fixtures/             # recorded landmark sequences (no images)
```

## Processing path

AVCapture video output → latest frame only → Vision hand landmarks → coordinate normalization and smoothing → gesture state machine → configurable action → macOS adapter.

Capture and Vision inference must stay off the main thread. Permit at most one inference at a time and drop stale frames rather than accumulating latency. Normalize mirrored camera coordinates once, at the Vision adapter boundary, so the core only ever sees one convention. Test hand identity changes, loss of tracking, low confidence, occlusion and poor lighting. Disable action output immediately when tracking is lost. Record timing and counters, not images or hand histories, by default.

A visible clutch gesture arms control, so ordinary talking and hand movement do not issue commands. Use confidence thresholds, minimum dwell, displacement thresholds and hysteresis. Every discrete swipe requires release/reset before another action; use a cooldown to prevent switching across several desktops accidentally. Continuous scroll uses a dead zone and capped velocity. A menu toggle and keyboard escape mechanism stop output immediately.

## What can be controlled

| Air gesture (initial proposal) | macOS action | Limits |
| --- | --- | --- |
| Armed two-finger vertical movement | Smooth pixel scroll | Start without synthetic momentum; tune against multiple apps |
| Armed open-palm swipe left/right | Configurable previous/next Space shortcut | User's Mission Control shortcuts must be enabled; test full-screen spaces and multiple displays |
| Armed upward swipe | Mission Control shortcut | Standard default is Control–Up Arrow |
| Pinch and hold while moving | Pointer drag, after an explicit drag mode is enabled | Must release mouse button on lost tracking, pause or shutdown |
| Pinch distance change | Application zoom shortcut or supported Accessibility action | Not equivalent to universally injecting native trackpad magnification |
| Deliberate held gesture | Minimize focused window using Accessibility | Only supported/settable attributes; fallback to a configured shortcut |

Most requested outcomes are feasible. An exact replacement for **every** trackpad gesture is not promised: public event creation APIs do not provide one general API for reproducing every native multi-touch gesture with its interactive animation. Prefer documented scroll/mouse/keyboard events and Accessibility. Do not rely on private multitouch/Spaces APIs or disable system protections. App-specific zoom adapters are likely necessary.

## Camera power and permission model

- **Off:** stop the capture session; camera is unavailable to our detector. A menu action or keyboard shortcut starts it.
- **Standby:** camera is still capturing, with low-rate inference (initial target 3–5 Hz). Detect the deliberate arming pose before enabling output. This is not camera-off standby.
- **Active:** initial target 24–30 Hz tracking, with inference limited by actual measured device performance. Return to standby after no hand is visible for a configurable interval.
- Camera modes and frame rates are targets to validate, not measured power/latency claims. Configure only frame durations supported by the selected camera; reduce inference frequency independently when capture cannot run that slowly.
- The system camera indicator remains visible whenever the camera is in use. Do not try to hide or bypass it.
- Ask for Camera access only on first Start, with `NSCameraUsageDescription`. Request Accessibility when the user enables system control. No microphone or Screen Recording permission is needed for this design.
- Process frames locally and do not record/upload video. Pause capture on lock/sleep; handle camera disconnects, contention, revoked permissions and wake without surprise activation. Auto-start is opt-in.

## Build order and acceptance checks

1. **Skeleton and menu app.** CMake project, Objective-C++ menu-bar app with Start/Stop and camera selection; preview plus Vision landmark overlay. Measure camera-to-result latency, CPU and energy usage on this Mac.
2. **C++ gesture engine.** Feed synthetic and recorded landmark fixtures; test jitter, weak confidence, mirrored coordinates, hand loss and false activations. Produce a local action log without controlling the Mac. Run under ASan/UBSan/TSan.
3. **Scrolling and desktop switching** behind an explicit output toggle. Verify one action per gesture and reliable disarming in ordinary movement.
4. **Window minimize and per-app zoom.** Add pointer/drag only after reliable release-on-loss behaviour.
5. **Calibration, profiles, signed and notarized packaging**, and real-world multi-display/full-screen testing. Set performance targets based on measurements, not assumptions about Vision's hardware backend.

## Sources

- [Apple: camera capture setup](https://developer.apple.com/documentation/avfoundation/capture-setup)
- [Apple: requesting camera authorization](https://developer.apple.com/documentation/AVFoundation/requesting-authorization-to-capture-and-save-media)
- [Apple: Vision hand-pose request](https://developer.apple.com/documentation/vision/vndetecthumanhandposerequest)
- [Apple: Mission Control](https://support.apple.com/en-mn/guide/mac-help/mh35798/mac)
- [Apple: posting CoreGraphics events](https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:))
- [Apple: scroll wheel events](https://developer.apple.com/documentation/coregraphics/cgeventcreatescrollwheelevent?language=objc)
- [Apple: Accessibility trust](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- [Apple: minimized-window attribute](https://developer.apple.com/documentation/applicationservices/kaxminimizedattribute)
- [toml++](https://github.com/marzer/tomlplusplus)
