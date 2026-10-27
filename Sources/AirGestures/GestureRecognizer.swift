import Foundation

enum SwipeDirection: String, Sendable {
    case left, right, up, down
}

enum PinchPhase: Sendable, CustomStringConvertible {
    case began
    /// How much bigger (>1) or smaller (<1) the pinch is than when it began.
    case changed(scale: Double)
    case ended

    var description: String {
        switch self {
        case .began: "began"
        case .changed(let scale): String(format: "scale %.2f", scale)
        case .ended: "ended"
        }
    }
}

enum Gesture: Sendable, CustomStringConvertible {
    case swipe(fingers: Int, direction: SwipeDirection)
    case twirl(clockwise: Bool)
    /// Thumb–index pinch: zoom the content.
    case zoom(PinchPhase)
    /// Whole-hand pinch: resize the window.
    case resize(PinchPhase)
    case fistClose

    var description: String {
        switch self {
        case .swipe(let fingers, let direction): "gesture: \(fingers)-finger swipe \(direction.rawValue)"
        case .twirl(let clockwise): "gesture: twirl \(clockwise ? "clockwise" : "counter-clockwise")"
        case .zoom(let phase): "gesture: zoom \(phase)"
        case .resize(let phase): "gesture: resize \(phase)"
        case .fistClose: "gesture: open hand → fist"
        }
    }
}

/// Turns the HandFrame stream into discrete gestures. One hand drives it at a time, and only one
/// finger posture is active at a time, so gestures can't overlap.
final class GestureRecognizer: @unchecked Sendable {
    // Tunables — expect to adjust these once you see real numbers in the log.
    /// Frames a new finger posture must hold before it counts.
    static let postureFrames = 3
    /// Frames the driving hand can go missing before we let go of it.
    static let lostFrames = 5

    /// Hand travel (aspect-corrected normalized units) needed for a swipe.
    static let minSwipeDistance = 0.15
    /// Hand speed above which the hand counts as moving, and below which a moving hand counts as stopped.
    /// While it's moving faster than `swipeMoveSpeed` the posture is left alone: motion blur makes
    /// Vision lose fingers, and a swipe would otherwise turn into a pinch halfway through.
    static let swipeMoveSpeed = 0.4
    static let swipeStopSpeed = 0.15
    static let swipeCooldown: TimeInterval = 0.6
    /// The swipe's longer axis has to be this many times its shorter one. A diagonal is too
    /// ambiguous to guess, so it does nothing.
    static let swipeDominance = 1.4

    /// How much index-tip history the twirl looks at.
    static let twirlWindow: TimeInterval = 1.0
    /// Side-to-side spread of the index tip needed before a twirl is considered.
    static let twirlMinWidth = 0.015
    /// The small axis must spread at least this many times Vision's jitter, or it's just noise.
    static let twirlJitterMultiple = 3.0
    static let yJitter = 0.003
    static let depthJitter = 0.004
    /// A genuine twirl moves only a fraction of a turn per frame; bigger jumps are noise crossing the center.
    static let twirlMaxStep = 1.5
    /// Points this close to the loop's center (in stretched units) have unreliable angles.
    static let twirlMinRadius = 0.5
    static let twirlStallTimeout: TimeInterval = 1.5

    /// Zoom/resize updates are sent at most this often, and only when the scale moved by at least `pinchMinChange`.
    static let pinchInterval: TimeInterval = 1.0 / 30
    static let pinchMinChange = 0.02
    /// Smoothing for the pinch line (0 = frozen, 1 = raw).
    static let pinchSmoothing = 0.4

    /// Added to both spreads before dividing, so a beak (tiny spread) doesn't make the scale explode.
    static let resizeSoftening = 1.0
    /// The resize ends once the fingertip spread hasn't changed by `resizeStillChange` for this long.
    static let resizeStillTime: TimeInterval = 0.6
    static let resizeStillChange = 0.08

    /// Open hand must be held this long, this still, before a fist closes the window.
    static let fistArmTime: TimeInterval = 0.3
    static let fistStillSpeed = 0.2
    /// Time allowed between letting go of the open hand and the fist appearing.
    static let fistWindow: TimeInterval = 0.6
    static let fistFrames = 3
    static let fistCooldown: TimeInterval = 1.5

    private enum Posture: Equatable {
        case fourFingers, twoFingers, oneFinger, pinch, other
    }

    private var activeSide: Chirality?
    private var missingFrames = 0

    private var posture: Posture = .other
    private var candidate: Posture?
    private var candidateFrames = 0

    // Swipe
    /// Every step the hand took since it last rested, added up (aspect-corrected). The sum of the
    /// steps is the whole path's net travel, so a few noisy frames barely change it.
    private var swipeTravel = CGVector.zero
    private var swipeMoved = false
    private var lastSwipeTime: TimeInterval = -.infinity

    // Twirl
    private struct TipSample { let time: TimeInterval; let x: Double; let y: Double; let depth: Double }
    private var tipSamples: [TipSample] = []
    private var twirlAngle = 0.0
    private var lastTwirlProgress: TimeInterval = 0
    /// Spread of the index tip while twirling, for tuning (shown in --stream).
    private(set) var twirlStats: String?

    // Pinch
    private var pinchReference: Double?
    private var pinchSmoothed = 0.0
    private var lastPinchScale = 1.0
    private var lastPinchTime: TimeInterval = 0

    // Whole-hand resize
    private var resizeReference: Double?
    private var resizeMissing = 0
    private var resizeLastMove: (spread: Double, time: TimeInterval) = (0, 0)
    private var lastResizeScale = 1.0
    private var lastResizeTime: TimeInterval = 0
    private var clawFrames = 0
    /// After a resize ends, the hand has to leave the claw shape before another can start.
    private var resizeNeedsRelease = false

    // Fist
    private var openSince: TimeInterval?
    private var openArmedAt: TimeInterval?
    private var fistCount = 0
    private var lastFistTime: TimeInterval = -.infinity

    func process(_ frame: HandFrame) -> [Gesture] {
        var gestures: [Gesture] = []
        let t = frame.timestamp

        if activeSide == nil {
            activeSide = (frame.hands.first { $0.chirality == .right } ?? frame.hands.first)?.chirality
        }
        guard let hand = frame.hands.first(where: { $0.chirality == activeSide }) else {
            missingFrames += 1
            if missingFrames >= Self.lostFrames {
                gestures += endPosture(at: t, fire: false)
                gestures += endResize()
                reset()
            }
            return gestures
        }
        missingFrames = 0

        // A whole-hand resize takes over the hand while it lasts.
        gestures += trackResize(hand, at: t)
        if resizeReference != nil {
            gestures += trackFist(hand, at: t)
            return gestures
        }

        // A fast-moving hand is blurred and Vision drops fingers, so its shape isn't trusted:
        // the posture only changes while the hand is fairly still and no swipe is in flight.
        let steady = !swipeMoved && hand.speed < Self.swipeMoveSpeed
        if steady {
            gestures += updatePosture(Self.posture(of: hand, current: posture), at: t)
        }
        switch posture {
        case .fourFingers, .twoFingers: gestures += trackSwipe(hand, at: t)
        case .oneFinger: gestures += trackTwirl(hand, at: t)
        case .pinch: gestures += trackPinch(hand, at: t)
        case .other: break
        }
        gestures += trackFist(hand, at: t)
        return gestures
    }

    private static func posture(of hand: HandSnapshot, current: Posture) -> Posture {
        // A pinch starts as a C. Once pinching, the index may straighten as the pinch opens up.
        if hand.isCPinch { return .pinch }
        if current == .pinch, hand.isPinchPose { return .pinch }
        // The thumb is ignored for swipes — Vision misses it too often.
        switch hand.extendedFingers.subtracting([.thumb]) {
        case [.index, .middle, .ring, .little]: return .fourFingers
        case [.index, .middle]: return .twoFingers
        case [.index]: return .oneFinger
        default: return .other
        }
    }

    private func updatePosture(_ seen: Posture, at t: TimeInterval) -> [Gesture] {
        guard seen != posture else {
            candidate = nil
            candidateFrames = 0
            return []
        }
        if candidate != seen {
            candidate = seen
            candidateFrames = 0
        }
        candidateFrames += 1
        guard candidateFrames >= Self.postureFrames else { return [] }

        let ended = endPosture(at: t, fire: true)
        posture = seen
        candidate = nil
        candidateFrames = 0
        return ended
    }

    /// Wraps up whatever the current posture was doing. A swipe in flight fires if `fire` is set.
    private func endPosture(at t: TimeInterval, fire: Bool) -> [Gesture] {
        var gestures: [Gesture] = []
        if fire, let swipe = finishSwipe(at: t) { gestures.append(swipe) }
        if pinchReference != nil { gestures.append(.zoom(.ended)) }
        swipeTravel = .zero
        swipeMoved = false
        tipSamples = []
        twirlAngle = 0
        twirlStats = nil
        pinchReference = nil
        return gestures
    }

    private func reset() {
        activeSide = nil
        missingFrames = 0
        posture = .other
        candidate = nil
        candidateFrames = 0
        openSince = nil
        openArmedAt = nil
        fistCount = 0
        clawFrames = 0
        resizeNeedsRelease = false
    }

    // MARK: - Swipe

    private func trackSwipe(_ hand: HandSnapshot, at t: TimeInterval) -> [Gesture] {
        // Corrected for aspect ratio so left/right and up/down need the same real travel.
        swipeTravel.dx += hand.step.dx * hand.aspectRatio
        swipeTravel.dy += hand.step.dy

        if !swipeMoved {
            if hand.speed > Self.swipeMoveSpeed {
                // Took off. The travel already includes the frames it spent speeding up.
                swipeMoved = true
            } else if hand.speed < Self.swipeStopSpeed {
                swipeTravel = .zero  // resting: the next swipe starts from here
            }
            return []
        }
        guard hand.speed < Self.swipeStopSpeed else { return [] }

        // Hand came to rest: that's the end of this swipe, and the next starts here.
        let swipe = finishSwipe(at: t)
        swipeTravel = .zero
        swipeMoved = false
        return swipe.map { [$0] } ?? []
    }

    private func finishSwipe(at t: TimeInterval) -> Gesture? {
        guard swipeMoved, t - lastSwipeTime >= Self.swipeCooldown else { return nil }
        let fingers: Int
        switch posture {
        case .fourFingers: fingers = 4
        case .twoFingers: fingers = 2
        default: return nil
        }
        let sideways = abs(swipeTravel.dx)
        let upDown = abs(swipeTravel.dy)
        let longer = max(sideways, upDown)
        let shorter = min(sideways, upDown)
        guard longer >= Self.minSwipeDistance else { return nil }
        guard longer >= shorter * Self.swipeDominance else { return nil }

        let direction: SwipeDirection
        if sideways > upDown {
            direction = swipeTravel.dx > 0 ? .right : .left
        } else {
            direction = swipeTravel.dy > 0 ? .up : .down
        }
        // Two-finger swipes only go left/right.
        if fingers == 2, direction == .up || direction == .down { return nil }

        lastSwipeTime = t
        return .swipe(fingers: fingers, direction: direction)
    }

    // MARK: - Twirl

    private func trackTwirl(_ hand: HandSnapshot, at t: TimeInterval) -> [Gesture] {
        guard let tip = hand.joints[.indexTip], let depth = hand.indexLength else { return [] }
        tipSamples.append(TipSample(time: t, x: tip.x * hand.aspectRatio, y: tip.y, depth: depth))
        tipSamples.removeAll { t - $0.time > Self.twirlWindow }
        guard tipSamples.count >= 8 else { return [] }

        func spread(_ values: [Double]) -> (mean: Double, sd: Double) {
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
            return (mean, variance.squareRoot())
        }
        let x = spread(tipSamples.map(\.x))
        let y = spread(tipSamples.map(\.y))
        let d = spread(tipSamples.map(\.depth))
        twirlStats = String(format: "twirl spread x=%.3f y=%.3f depth=%.3f angle=%+.0f°",
                            x.sd, y.sd, d.sd, twirlAngle * 180 / .pi)

        // Seen from the front, a horizontal loop is a flat ellipse: wide in x, short in y.
        // Pick whichever of y or the finger's apparent length (depth) clearly moves as the second axis,
        // then divide each axis by its spread so the ellipse becomes a circle.
        let yScore = y.sd / Self.yJitter
        let dScore = d.sd / Self.depthJitter
        guard x.sd >= Self.twirlMinWidth, max(yScore, dScore) >= Self.twirlJitterMultiple else { return [] }
        let useY = yScore >= dScore

        func angle(_ s: TipSample) -> (angle: Double, radius: Double) {
            let u = (s.x - x.mean) / x.sd
            let v = useY ? (s.y - y.mean) / y.sd : (s.depth - d.mean) / d.sd
            return (atan2(v, u), hypot(u, v))
        }
        let current = angle(tipSamples[tipSamples.count - 1])
        let previous = angle(tipSamples[tipSamples.count - 2])
        guard current.radius >= Self.twirlMinRadius, previous.radius >= Self.twirlMinRadius else { return [] }

        var step = current.angle - previous.angle
        if step > .pi { step -= 2 * .pi }
        if step < -.pi { step += 2 * .pi }
        guard abs(step) <= Self.twirlMaxStep else { return [] }

        if t - lastTwirlProgress > Self.twirlStallTimeout { twirlAngle = 0 }
        if step * twirlAngle >= 0 || twirlAngle == 0 { lastTwirlProgress = t }
        twirlAngle += step

        guard abs(twirlAngle) >= 2 * .pi else { return [] }
        let clockwise = twirlAngle < 0
        twirlAngle = 0
        return [.twirl(clockwise: clockwise)]
    }

    // MARK: - Pinch

    private func trackPinch(_ hand: HandSnapshot, at t: TimeInterval) -> [Gesture] {
        // A frame or two where Vision loses confidence shouldn't end the pinch; just skip it.
        guard let distance = hand.pinchDistance, distance > 0 else { return [] }
        guard let reference = pinchReference else {
            pinchReference = distance
            pinchSmoothed = distance
            lastPinchScale = 1
            lastPinchTime = t
            return [.zoom(.began)]
        }
        let a = Self.pinchSmoothing
        pinchSmoothed = a * distance + (1 - a) * pinchSmoothed
        let scale = pinchSmoothed / reference
        guard t - lastPinchTime >= Self.pinchInterval,
              abs(scale - lastPinchScale) >= Self.pinchMinChange else { return [] }
        lastPinchScale = scale
        lastPinchTime = t
        return [.zoom(.changed(scale: scale))]
    }

    // MARK: - Whole-hand resize

    /// Works like a trackpad pinch with the whole hand, once a claw has started it: opening the hand
    /// grows the window, closing it toward a beak shrinks it. Ends when the hand holds still, curls
    /// into a fist, or leaves.
    private func trackResize(_ hand: HandSnapshot, at t: TimeInterval) -> [Gesture] {
        guard let reference = resizeReference else { return startResize(hand, at: t) }

        if hand.isFist { return endResize() }
        guard let spread = hand.tipSpread else {
            resizeMissing += 1
            return resizeMissing >= Self.lostFrames ? endResize() : []
        }
        resizeMissing = 0

        if abs(spread - resizeLastMove.spread) > Self.resizeStillChange {
            resizeLastMove = (spread, t)
        } else if t - resizeLastMove.time > Self.resizeStillTime {
            return endResize()
        }

        let k = Self.resizeSoftening
        let scale = (spread + k) / (reference + k)
        guard t - lastResizeTime >= Self.pinchInterval,
              abs(scale - lastResizeScale) >= Self.pinchMinChange else { return [] }
        lastResizeScale = scale
        lastResizeTime = t
        return [.resize(.changed(scale: scale))]
    }

    /// A resize only starts on purpose: the fingers curled into a claw and held still for a few frames.
    private func startResize(_ hand: HandSnapshot, at t: TimeInterval) -> [Gesture] {
        guard hand.isClaw else {
            clawFrames = 0
            resizeNeedsRelease = false
            return []
        }
        let steady = !swipeMoved && hand.speed < Self.swipeMoveSpeed
        guard steady, !resizeNeedsRelease, let spread = hand.tipSpread else {
            clawFrames = 0
            return []
        }
        clawFrames += 1
        guard clawFrames >= Self.postureFrames else { return [] }

        var gestures = endPosture(at: t, fire: false)
        resizeReference = spread
        resizeMissing = 0
        resizeLastMove = (spread, t)
        lastResizeScale = 1
        lastResizeTime = 0
        gestures.append(.resize(.began))
        gestures += trackResize(hand, at: t)
        return gestures
    }

    private func endResize() -> [Gesture] {
        guard resizeReference != nil else { return [] }
        resizeReference = nil
        clawFrames = 0
        resizeNeedsRelease = true
        return [.resize(.ended)]
    }

    // MARK: - Fist

    private func trackFist(_ hand: HandSnapshot, at t: TimeInterval) -> [Gesture] {
        let speed = hypot(hand.velocity.dx, hand.velocity.dy)
        if hand.fingerCount == 5 {
            fistCount = 0
            if speed < Self.fistStillSpeed {
                let since = openSince ?? t
                openSince = since
                if t - since >= Self.fistArmTime { openArmedAt = t }
            } else {
                openSince = nil
            }
            return []
        }
        openSince = nil

        guard hand.isFist, let armed = openArmedAt else {
            fistCount = 0
            if let armed = openArmedAt, t - armed > Self.fistWindow { openArmedAt = nil }
            return []
        }
        if fistCount == 0, t - armed > Self.fistWindow {
            openArmedAt = nil
            return []
        }
        fistCount += 1
        guard fistCount >= Self.fistFrames, t - lastFistTime >= Self.fistCooldown else { return [] }
        fistCount = 0
        openArmedAt = nil
        lastFistTime = t
        return [.fistClose]
    }
}
