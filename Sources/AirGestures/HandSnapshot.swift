import CoreGraphics

enum Chirality: String, Sendable {
    case left = "L"
    case right = "R"
    case unknown = "?"
}

enum Finger: String, CaseIterable, Sendable {
    case thumb, index, middle, ring, little

    /// The finger's four joints from its base out to the tip. Each bone runs from one joint to the next.
    var chain: [Joint] {
        switch self {
        case .thumb: [.thumbCMC, .thumbMP, .thumbIP, .thumbTip]
        case .index: [.indexMCP, .indexPIP, .indexDIP, .indexTip]
        case .middle: [.middleMCP, .middlePIP, .middleDIP, .middleTip]
        case .ring: [.ringMCP, .ringPIP, .ringDIP, .ringTip]
        case .little: [.littleMCP, .littlePIP, .littleDIP, .littleTip]
        }
    }

    static let fourFingers: [Finger] = [.index, .middle, .ring, .little]
}

/// How bent one finger is.
enum FingerState: String, Sendable {
    case extended, bent, curled
}

/// The 21 hand joints Vision reports, kept Vision-free so later layers
/// (gesture recognizer, menu bar app) don't need to import Vision.
enum Joint: String, CaseIterable, Sendable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip

    static let tips: [Joint] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
}

/// Everything we know about one hand in one camera frame.
///
/// Nothing here uses the wrist: it's often out of frame or guessed when you hold a hand up to a
/// laptop camera. Each finger is measured from its own joints, and sizes are measured against the
/// knuckle span (index knuckle to little-finger knuckle), which doesn't change as fingers move.
struct HandSnapshot: Sendable {
    let chirality: Chirality
    let confidence: Float
    /// Normalized image coordinates (0...1), origin bottom-left, mirrored to match the user's view.
    let joints: [Joint: CGPoint]
    /// Vision's confidence for each joint in `joints`.
    let jointConfidence: [Joint: Float]
    /// Frame width / height. Multiply x differences by this so distances aren't squashed.
    let aspectRatio: Double
    /// For each finger whose four joints were all seen: the straight line from its base to its tip,
    /// divided by its three bones laid end to end. 1 is perfectly straight; curling folds the tip back
    /// and the number drops. Pointing at the camera shrinks the line and the bones alike, so it stays put.
    let straightness: [Finger: Double]
    /// Index, middle, ring and little from their straightness; the thumb from whether it sticks out
    /// from the palm. Fingers that weren't seen well enough are missing.
    let fingerStates: [Finger: FingerState]
    /// Index knuckle to little-finger knuckle, in aspect-corrected units. The ruler for every other size.
    let knuckleSpan: Double?
    /// Thumb tip to index tip, in knuckle spans. nil unless both tips are clearly seen.
    let pinchDistance: Double?
    /// Thumb and index working together (thumb out or touching the index, index not curled into the
    /// palm) while middle, ring and little are curled. The shape you hold a pinch-to-zoom in.
    let isPinchPose: Bool
    /// Middle of all detected finger joints.
    let palmCenter: CGPoint?
    /// Apparent index finger length (MCP→tip) in aspect-corrected units. Shrinks as the tip swings toward the camera.
    let indexLength: Double?
    /// Index, middle, ring and little all curled. (In a pinch the index is only bent, not curled.)
    let isFist: Bool
    /// Fingers hooked like holding a ball: none straight and at least three of the four bent, but
    /// not curled into a fist. Holding this still is what starts a whole-hand resize.
    let isClaw: Bool
    /// Average distance of the five fingertips from their middle, in knuckle spans; nil unless all five are seen.
    /// Small when the fingertips are bunched together, large with the hand spread open.
    let tipSpread: Double?
    /// How far the hand moved since the previous frame, in normalized image units (+x right, +y up).
    /// Measured only from joints seen in both frames, so a finger dropping in or out of view doesn't
    /// look like the hand moving. Filled in by MotionTracker.
    var step: CGVector = .zero
    /// Hand velocity in normalized image units per second (+x right, +y up): `step` over time, smoothed.
    /// Filled in by MotionTracker.
    var velocity: CGVector = .zero

    var extendedFingers: Set<Finger> {
        Set(fingerStates.filter { $0.value == .extended }.keys)
    }
    var fingerCount: Int { extendedFingers.count }

    /// The pinch pose with the index hooked over toward the thumb in a C. A pinch has to start in
    /// this shape, so pointing with the thumb out (an L) isn't mistaken for one.
    var isCPinch: Bool {
        isPinchPose && fingerStates[.index] == .bent
    }

    var speed: Double { hypot(velocity.dx, velocity.dy) }

    var isPinching: Bool {
        guard let pinchDistance else { return false }
        return pinchDistance < Self.pinchThreshold
    }

    /// All five fingertips bunched together like a bird's beak (and not curled into a fist).
    var isBeak: Bool {
        guard let tipSpread, !isFist else { return false }
        return tipSpread < Self.beakSpread
    }

    // Tunables — run with --stream to see each finger's straightness and adjust these.
    /// A finger at least this straight is extended...
    static let extendedStraightness = 0.85
    /// ...and one at most this straight is curled. In between it's bent (a pinching index sits there).
    static let curledStraightness = 0.55
    /// The thumb is out when its tip is at least this many knuckle spans from the index knuckle.
    static let thumbOutDistance = 0.6
    /// Pinch closes below this many knuckle spans...
    static let pinchThreshold = 0.3
    /// ...and opens again above this (hysteresis so it doesn't flicker).
    static let pinchReleaseThreshold = 0.4
    /// Thumb and index tips need at least this confidence to count toward a pinch.
    /// Vision invents a low-confidence thumb next to a lone pointing finger.
    static let pinchJointConfidence: Float = 0.6
    /// Fingertips count as a beak when their average distance from their middle is under this many knuckle spans.
    static let beakSpread = 0.35

    init(chirality: Chirality, confidence: Float, joints: [Joint: CGPoint],
         jointConfidence: [Joint: Float], aspectRatio: Double) {
        self.chirality = chirality
        self.confidence = confidence
        self.joints = joints
        self.jointConfidence = jointConfidence
        self.aspectRatio = aspectRatio

        // Normalized coords are squashed horizontally; scale x by the aspect ratio so distances are true.
        func distance(_ a: Joint, _ b: Joint) -> Double? {
            guard let p = joints[a], let q = joints[b] else { return nil }
            return Self.distance(p, q, aspectRatio: aspectRatio)
        }
        func confident(_ joint: Joint) -> Bool {
            guard let confidence = jointConfidence[joint] else { return false }
            return confidence >= Self.pinchJointConfidence
        }

        let span = distance(.indexMCP, .littleMCP)
        let ruler: Double?
        if let span, span > 0 {
            ruler = span
        } else {
            ruler = nil
        }
        knuckleSpan = ruler

        // Each finger on its own: how straight is the chain of its three bones?
        var straightness: [Finger: Double] = [:]
        for finger in Finger.allCases {
            let chain = finger.chain
            guard let base = distance(chain[0], chain[3]),
                  let firstBone = distance(chain[0], chain[1]),
                  let secondBone = distance(chain[1], chain[2]),
                  let thirdBone = distance(chain[2], chain[3]) else { continue }
            let boneLength = firstBone + secondBone + thirdBone
            guard boneLength > 0 else { continue }
            straightness[finger] = base / boneLength
        }
        self.straightness = straightness

        var states: [Finger: FingerState] = [:]
        for finger in Finger.fourFingers {
            guard let value = straightness[finger] else { continue }
            if value >= Self.extendedStraightness {
                states[finger] = .extended
            } else if value <= Self.curledStraightness {
                states[finger] = .curled
            } else {
                states[finger] = .bent
            }
        }

        // The thumb barely curls; what matters is whether it sticks out from the palm or lies across it.
        let thumbOut: Bool
        if let ruler,
           let tipToIndexKnuckle = distance(.thumbTip, .indexMCP),
           let tipToLittleKnuckle = distance(.thumbTip, .littleMCP),
           let ipToLittleKnuckle = distance(.thumbIP, .littleMCP) {
            let pointsAwayFromPalm = tipToLittleKnuckle > ipToLittleKnuckle
            let farFromIndexKnuckle = tipToIndexKnuckle / ruler > Self.thumbOutDistance
            thumbOut = pointsAwayFromPalm && farFromIndexKnuckle
            states[.thumb] = thumbOut ? .extended : .curled
        } else {
            thumbOut = false
        }
        fingerStates = states

        // Pinch is just the thumb-tip → index-tip line. Only trust it when both tips are really there.
        let pinch: Double?
        if let ruler, confident(.thumbTip), confident(.indexTip), let line = distance(.thumbTip, .indexTip) {
            pinch = line / ruler
        } else {
            pinch = nil
        }
        pinchDistance = pinch

        // Middle, ring and little have to be seen curled. Not seeing them proves nothing.
        let othersCurled = [Finger.middle, .ring, .little].allSatisfy { states[$0] == .curled }
        let indexFree = states[.index] == .extended || states[.index] == .bent
        let thumbTouchingIndex: Bool
        if let pinch {
            thumbTouchingIndex = pinch < Self.pinchReleaseThreshold
        } else {
            thumbTouchingIndex = false
        }
        isPinchPose = pinch != nil && othersCurled && indexFree && (thumbOut || thumbTouchingIndex)

        isFist = Finger.fourFingers.allSatisfy { states[$0] == .curled }

        let seenStates = Finger.fourFingers.compactMap { states[$0] }
        let bentCount = seenStates.filter { $0 == .bent }.count
        let anyStraight = seenStates.contains(.extended)
        isClaw = !anyStraight && bentCount >= 3

        let fingerPoints = joints.filter { $0.key != .wrist }.map(\.value)
        palmCenter = Self.middle(of: fingerPoints)

        indexLength = distance(.indexMCP, .indexTip)

        let tips = Joint.tips.compactMap { joints[$0] }
        if tips.count == Joint.tips.count, let ruler, let middle = Self.middle(of: tips) {
            let total = tips.map { Self.distance($0, middle, aspectRatio: aspectRatio) }.reduce(0, +)
            tipSpread = total / Double(tips.count) / ruler
        } else {
            tipSpread = nil
        }
    }

    private static func distance(_ p: CGPoint, _ q: CGPoint, aspectRatio: Double) -> Double {
        hypot((p.x - q.x) * aspectRatio, p.y - q.y)
    }

    private static func middle(of points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let count = CGFloat(points.count)
        let x = points.map(\.x).reduce(0, +) / count
        let y = points.map(\.y).reduce(0, +) / count
        return CGPoint(x: x, y: y)
    }
}
