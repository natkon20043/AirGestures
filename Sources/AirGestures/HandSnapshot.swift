import CoreGraphics

enum Chirality: String, Sendable {
    case left = "L"
    case right = "R"
    case unknown = "?"
}

enum Finger: String, CaseIterable, Sendable {
    case thumb, index, middle, ring, little
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
struct HandSnapshot: Sendable {
    let chirality: Chirality
    let confidence: Float
    /// Normalized image coordinates (0...1), origin bottom-left, mirrored to match the user's view.
    let joints: [Joint: CGPoint]
    /// Vision's confidence for each joint in `joints`.
    let jointConfidence: [Joint: Float]
    /// Frame width / height. Multiply x differences by this so distances aren't squashed.
    let aspectRatio: Double
    let extendedFingers: Set<Finger>
    /// Length of the line from thumb tip to index tip, in index-bone lengths (indexMCP→indexPIP).
    /// nil unless thumb and index are clearly seen, the thumb is out, and the other three fingers are curled.
    let pinchDistance: Double?
    /// Middle of all detected finger joints (wrist excluded).
    let palmCenter: CGPoint?
    /// Apparent index finger length (MCP→tip) in aspect-corrected units. Shrinks as the tip swings toward the camera.
    let indexLength: Double?
    /// No fingers out and every visible fingertip pulled in close to the palm point.
    let isFist: Bool
    /// Average distance of the five fingertips from their middle, in index-bone lengths; nil unless all five are seen.
    /// Small when the fingertips are bunched together, large with the hand spread open.
    let tipSpread: Double?
    /// Palm velocity in normalized image units per second (+x right, +y up). Filled in by HandTracker.
    var velocity: CGVector = .zero

    var fingerCount: Int { extendedFingers.count }
    var isPinching: Bool { (pinchDistance ?? .infinity) < Self.pinchThreshold }
    /// All five fingertips bunched together like a bird's beak (and not curled into a fist).
    var isBeak: Bool { !isFist && (tipSpread ?? .infinity) < Self.beakSpread }

    // Tunables — expect to adjust these once you see real numbers in the log.
    /// Pinch closes below this many index-bone lengths...
    static let pinchThreshold = 0.5
    /// ...and opens again above this (hysteresis so it doesn't flicker).
    static let pinchReleaseThreshold = 0.7
    /// Thumb and index joints need at least this confidence to count toward a pinch.
    /// Vision invents a low-confidence thumb next to a lone pointing finger.
    static let pinchJointConfidence: Float = 0.6
    /// A finger counts as extended when its tip is this much farther from the wrist than its PIP joint.
    static let fingerExtensionRatio = 1.15
    /// The thumb counts as extended when its tip is at least this far (in palm sizes) from the index knuckle.
    static let thumbExtensionDistance = 0.5
    /// In a fist every visible fingertip is within this many index-bone lengths of the palm point.
    static let fistTipRadius = 1.6
    /// A fist needs at least this many joints seen, so a hand half out of frame doesn't count.
    static let fistMinJoints = 10
    /// Fingertips count as a beak when their average distance from their middle is under this many index-bone lengths.
    static let beakSpread = 0.6

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
            return hypot((p.x - q.x) * aspectRatio, p.y - q.y)
        }
        func confident(_ joint: Joint) -> Bool {
            (jointConfidence[joint] ?? 0) >= Self.pinchJointConfidence
        }

        let palmSize = distance(.wrist, .middleMCP)
        // The index finger's first bone is the same length however the hand is posed, so it's our ruler.
        // If it's hidden (e.g. curled in a fist), half the palm is about the same length.
        let bone = distance(.indexMCP, .indexPIP) ?? palmSize.map { $0 / 2 }

        var extended = Set<Finger>()
        let fingerJoints: [(Finger, tip: Joint, pip: Joint)] = [
            (.index, .indexTip, .indexPIP),
            (.middle, .middleTip, .middlePIP),
            (.ring, .ringTip, .ringPIP),
            (.little, .littleTip, .littlePIP),
        ]
        for (finger, tip, pip) in fingerJoints {
            if let tipDist = distance(tip, .wrist), let pipDist = distance(pip, .wrist),
               tipDist > pipDist * Self.fingerExtensionRatio {
                extended.insert(finger)
            }
        }
        // Thumb doesn't curl toward the wrist, so check that it sticks out away from the palm instead.
        if let palmSize, palmSize > 0,
           let tipToIndex = distance(.thumbTip, .indexMCP),
           let tipToLittle = distance(.thumbTip, .littleMCP),
           let ipToLittle = distance(.thumbIP, .littleMCP),
           tipToLittle > ipToLittle,
           tipToIndex / palmSize > Self.thumbExtensionDistance {
            extended.insert(.thumb)
        }
        self.extendedFingers = extended

        // Pinch is just the thumb-tip → index-tip line. Only trust it when both digits are really there.
        let othersCurled = extended.isDisjoint(with: [.middle, .ring, .little])
        if othersCurled, extended.contains(.thumb),
           [Joint.thumbTip, .thumbIP, .indexTip, .indexPIP].allSatisfy(confident),
           let ruler = distance(.indexMCP, .indexPIP), ruler > 0,
           let line = distance(.thumbTip, .indexTip) {
            pinchDistance = line / ruler
        } else {
            pinchDistance = nil
        }

        let fingerPoints = joints.filter { $0.key != .wrist }.map(\.value)
        let center: CGPoint?
        if fingerPoints.isEmpty {
            center = nil
        } else {
            let n = CGFloat(fingerPoints.count)
            center = CGPoint(x: fingerPoints.map(\.x).reduce(0, +) / n,
                             y: fingerPoints.map(\.y).reduce(0, +) / n)
        }
        palmCenter = center

        indexLength = distance(.indexMCP, .indexTip)

        if extended.isEmpty, joints.count >= Self.fistMinJoints, let center, let bone, bone > 0 {
            isFist = Joint.tips.compactMap { joints[$0] }.allSatisfy {
                hypot(($0.x - center.x) * aspectRatio, $0.y - center.y) / bone < Self.fistTipRadius
            }
        } else {
            isFist = false
        }

        let tips = Joint.tips.compactMap { joints[$0] }
        if tips.count == Joint.tips.count, let bone, bone > 0 {
            let n = CGFloat(tips.count)
            let middle = CGPoint(x: tips.map(\.x).reduce(0, +) / n, y: tips.map(\.y).reduce(0, +) / n)
            let total = tips.map { hypot(($0.x - middle.x) * aspectRatio, $0.y - middle.y) }.reduce(0, +)
            tipSpread = total / Double(n) / bone
        } else {
            tipSpread = nil
        }
    }
}
