import Foundation
import os

/// Turns the HandFrame stream into terminal output and unified-log events.
/// Events (hand appeared/lost, pinch start/end, gestures) are always sent to os.Logger so a
/// second terminal can follow them with:
///   log stream --predicate 'subsystem == "com.airgestures"'
final class HandLogger: @unchecked Sendable {
    enum Mode {
        /// One status line redrawn in place, with events printed above it.
        case live
        /// One timestamped line per frame (throttled).
        case stream
        /// Only print when something changes.
        case events
    }

    static let streamInterval: TimeInterval = 1.0 / 15
    /// Frames a hand can go missing before it's reported lost.
    static let lostDebounceFrames = 5

    private let mode: Mode
    private let showJoints: Bool
    private let log = Logger(subsystem: "com.airgestures", category: "hands")

    private var fps = 0.0
    private var lastFrameTime: TimeInterval?
    private var lastStreamPrint: TimeInterval = 0
    private var streamShowedNoHands = false

    private struct TrackedHand {
        var pinching: Bool
        var missingFrames = 0
    }
    private var tracked: [Chirality: TrackedHand] = [:]

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    init(mode: Mode, showJoints: Bool) {
        self.mode = mode
        self.showJoints = showJoints
    }

    /// - Parameter extra: optional diagnostics (e.g. twirl spread) appended in --stream mode.
    func handle(_ frame: HandFrame, extra: String? = nil) {
        updateFPS(frame.timestamp)
        let events = detectEvents(in: frame)
        printEvents(events)

        switch mode {
        case .live:
            print("\r\u{1B}[2K" + liveLine(for: frame), terminator: "")
            fflush(stdout)
        case .stream:
            printStream(frame, extra: extra)
        case .events:
            break
        }
    }

    func handle(_ gesture: Gesture, performed: Bool) {
        printEvents([performed ? "\(gesture)" : "\(gesture) (dry run)"])
    }

    private func printEvents(_ events: [String]) {
        for event in events {
            log.notice("\(event, privacy: .public)")
            switch mode {
            case .live: print("\r\u{1B}[2K\(Self.clock()) \(event)")
            case .stream, .events: print("\(Self.clock()) \(event)")
            }
        }
    }

    /// Call on shutdown so the shell prompt doesn't land on the live line.
    func finish() {
        if mode == .live { print("") }
    }

    // MARK: - Output

    private func liveLine(for frame: HandFrame) -> String {
        let hands = frame.hands.isEmpty
            ? "no hands"
            : sorted(frame.hands).map(summary).joined(separator: "  |  ")
        return String(format: "%5.1f fps %3.0fms  ", fps, frame.processingTime * 1000) + hands
    }

    private func printStream(_ frame: HandFrame, extra: String?) {
        guard frame.timestamp - lastStreamPrint >= Self.streamInterval else { return }
        lastStreamPrint = frame.timestamp

        if frame.hands.isEmpty {
            if !streamShowedNoHands { print("\(Self.clock()) -- no hands --") }
            streamShowedNoHands = true
            return
        }
        streamShowedNoHands = false
        for hand in sorted(frame.hands) {
            print("\(Self.clock()) \(summary(hand))")
            if showJoints { print(jointDump(hand)) }
        }
        if let extra { print("    \(extra)") }
    }

    private func summary(_ hand: HandSnapshot) -> String {
        let fingers = Finger.allCases.map { hand.extendedFingers.contains($0) ? String($0.rawValue.prefix(1)).uppercased() : "·" }.joined()
        let fist = hand.isFist ? "fist" : hand.isBeak ? "beak" : "    "
        let spread = hand.tipSpread.map { String(format: "%.2f", $0) } ?? " -- "
        let pinch = hand.pinchDistance.map { String(format: "%.2f", $0) } ?? " -- "
        let palm = hand.palmCenter.map { String(format: "(%.2f,%.2f)", $0.x, $0.y) } ?? "(--,--)"
        let length = hand.indexLength.map { String(format: "%.3f", $0) } ?? " --  "
        let velocity = String(format: "(%+.2f,%+.2f)", hand.velocity.dx, hand.velocity.dy)
        return "\(hand.chirality.rawValue) \(fingers) \(fist) pinch=\(pinch) spread=\(spread) palm=\(palm) len=\(length) v=\(velocity)"
    }

    private func jointDump(_ hand: HandSnapshot) -> String {
        let groups: [[Joint]] = [
            [.wrist],
            [.thumbCMC, .thumbMP, .thumbIP, .thumbTip],
            [.indexMCP, .indexPIP, .indexDIP, .indexTip],
            [.middleMCP, .middlePIP, .middleDIP, .middleTip],
            [.ringMCP, .ringPIP, .ringDIP, .ringTip],
            [.littleMCP, .littlePIP, .littleDIP, .littleTip],
        ]
        return groups.map { group in
            "    " + group.map { joint in
                let point = hand.joints[joint].map { String(format: "(%.3f,%.3f)", $0.x, $0.y) } ?? "(  --  ,  --  )"
                return "\(joint.rawValue)=\(point)"
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    private func sorted(_ hands: [HandSnapshot]) -> [HandSnapshot] {
        hands.sorted { $0.chirality.rawValue < $1.chirality.rawValue }
    }

    private static func clock() -> String {
        clockFormatter.string(from: Date())
    }

    // MARK: - State tracking

    private func updateFPS(_ time: TimeInterval) {
        defer { lastFrameTime = time }
        guard let last = lastFrameTime, time > last else { return }
        let instant = 1 / (time - last)
        fps = fps == 0 ? instant : fps * 0.9 + instant * 0.1
    }

    private func detectEvents(in frame: HandFrame) -> [String] {
        var events: [String] = []
        var seen = Set<Chirality>()

        for hand in frame.hands {
            let side = hand.chirality
            guard seen.insert(side).inserted else { continue }
            let location = hand.palmCenter.map { String(format: " at (%.2f,%.2f)", $0.x, $0.y) } ?? ""

            guard var state = tracked[side] else {
                tracked[side] = TrackedHand(pinching: hand.isPinching)
                events.append("\(side.rawValue) hand appeared  fingers=\(hand.fingerCount)\(location)")
                continue
            }
            state.missingFrames = 0

            // Hysteresis: it takes a tighter pinch to start than to stay pinched.
            let threshold = state.pinching ? HandSnapshot.pinchReleaseThreshold : HandSnapshot.pinchThreshold
            let pinching = (hand.pinchDistance ?? .infinity) < threshold
            if pinching != state.pinching {
                state.pinching = pinching
                events.append("\(side.rawValue) pinch \(pinching ? "start" : "end")\(location)")
            }
            tracked[side] = state
        }

        for (side, var state) in tracked where !seen.contains(side) {
            state.missingFrames += 1
            if state.missingFrames >= Self.lostDebounceFrames {
                tracked[side] = nil
                events.append("\(side.rawValue) hand lost")
            } else {
                tracked[side] = state
            }
        }
        return events
    }
}
