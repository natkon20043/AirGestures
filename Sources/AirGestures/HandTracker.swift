import CoreVideo
import Foundation
import Vision

/// The result of running hand detection on one camera frame (empty `hands` = nothing seen).
struct HandFrame: Sendable {
    /// Capture time in seconds (monotonic camera clock).
    let timestamp: TimeInterval
    let hands: [HandSnapshot]
    /// How long Vision took on this frame.
    let processingTime: TimeInterval
}

/// Runs Vision hand-pose detection on frames and publishes results on `frames`.
/// Anything that wants live hand data (logger now, gesture recognizer / menu bar later) iterates `frames`.
final class HandTracker: @unchecked Sendable {
    let frames: AsyncStream<HandFrame>

    static let minJointConfidence: Float = 0.3

    private let continuation: AsyncStream<HandFrame>.Continuation
    private let request: VNDetectHumanHandPoseRequest
    private let sequenceHandler = VNSequenceRequestHandler()
    private let swapHands: Bool
    private var motion = MotionTracker()

    init(swapHands: Bool = false) {
        (frames, continuation) = AsyncStream.makeStream(of: HandFrame.self, bufferingPolicy: .bufferingNewest(8))
        request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        self.swapHands = swapHands
    }

    /// Called on the camera queue for every frame.
    func process(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval, orientation: CGImagePropertyOrientation) {
        let start = ProcessInfo.processInfo.systemUptime
        do {
            try sequenceHandler.perform([request], on: pixelBuffer, orientation: orientation)
        } catch {
            return
        }
        let aspectRatio = Double(CVPixelBufferGetWidth(pixelBuffer)) / Double(CVPixelBufferGetHeight(pixelBuffer))

        var hands: [HandSnapshot] = []
        for observation in request.results ?? [] {
            guard var hand = snapshot(from: observation, aspectRatio: aspectRatio) else { continue }
            motion.update(&hand, at: timestamp)
            hands.append(hand)
        }

        continuation.yield(HandFrame(
            timestamp: timestamp,
            hands: hands,
            processingTime: ProcessInfo.processInfo.systemUptime - start
        ))
    }

    func finish() {
        continuation.finish()
    }

    private func snapshot(from observation: VNHumanHandPoseObservation, aspectRatio: Double) -> HandSnapshot? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        var joints: [Joint: CGPoint] = [:]
        var confidence: [Joint: Float] = [:]
        for joint in Joint.allCases {
            if let point = points[joint.visionName], point.confidence >= Self.minJointConfidence {
                joints[joint] = point.location
                confidence[joint] = point.confidence
            }
        }
        guard !joints.isEmpty else { return nil }
        return HandSnapshot(
            chirality: chirality(of: observation),
            confidence: observation.confidence,
            joints: joints,
            jointConfidence: confidence,
            aspectRatio: aspectRatio
        )
    }

    /// The camera mirrors frames before Vision sees them, so Vision's left/right comes out backwards.
    private func chirality(of observation: VNHumanHandPoseObservation) -> Chirality {
        switch observation.chirality {
        case .left: swapHands ? .left : .right
        case .right: swapHands ? .right : .left
        default: .unknown
        }
    }

}

/// Follows each hand from frame to frame and fills in its `step` and `velocity`.
///
/// The step is how far the joints seen in both frames moved, not how far their middle moved.
/// The middle of whatever is visible jumps whenever Vision drops or finds a finger mid-swipe;
/// a joint seen twice only moves when the hand does. The median of those moves is used, so one
/// joint Vision misplaces can't drag the result.
struct MotionTracker {
    /// Smoothing for velocity (0 = frozen, 1 = raw per-frame value).
    static let velocitySmoothing = 0.5
    /// Forget a hand's motion history if it hasn't been seen for this long.
    static let resetInterval: TimeInterval = 0.3
    /// Fewer joints than this in common between two frames and the step isn't trusted.
    static let minSharedJoints = 3

    private var previous: [Chirality: (joints: [Joint: CGPoint], time: TimeInterval, velocity: CGVector)] = [:]

    mutating func update(_ hand: inout HandSnapshot, at time: TimeInterval) {
        let last = previous[hand.chirality]
        var velocity = CGVector.zero
        var step = CGVector.zero

        if let last, time > last.time, time - last.time < Self.resetInterval {
            velocity = last.velocity
            if let measured = Self.step(from: last.joints, to: hand.joints) {
                step = measured
                let dt = time - last.time
                let a = Self.velocitySmoothing
                velocity = CGVector(dx: a * step.dx / dt + (1 - a) * last.velocity.dx,
                                    dy: a * step.dy / dt + (1 - a) * last.velocity.dy)
            }
        }

        hand.step = step
        hand.velocity = velocity
        previous[hand.chirality] = (hand.joints, time, velocity)
    }

    /// Median movement of the finger joints seen in both frames, or nil if too few were.
    static func step(from before: [Joint: CGPoint], to after: [Joint: CGPoint]) -> CGVector? {
        var xMoves: [Double] = []
        var yMoves: [Double] = []
        for (joint, point) in after where joint != .wrist {
            guard let earlier = before[joint] else { continue }
            xMoves.append(point.x - earlier.x)
            yMoves.append(point.y - earlier.y)
        }
        guard xMoves.count >= minSharedJoints else { return nil }
        return CGVector(dx: median(xMoves), dy: median(yMoves))
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[middle]
        }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}

extension Joint {
    var visionName: VNHumanHandPoseObservation.JointName {
        switch self {
        case .wrist: .wrist
        case .thumbCMC: .thumbCMC
        case .thumbMP: .thumbMP
        case .thumbIP: .thumbIP
        case .thumbTip: .thumbTip
        case .indexMCP: .indexMCP
        case .indexPIP: .indexPIP
        case .indexDIP: .indexDIP
        case .indexTip: .indexTip
        case .middleMCP: .middleMCP
        case .middlePIP: .middlePIP
        case .middleDIP: .middleDIP
        case .middleTip: .middleTip
        case .ringMCP: .ringMCP
        case .ringPIP: .ringPIP
        case .ringDIP: .ringDIP
        case .ringTip: .ringTip
        case .littleMCP: .littleMCP
        case .littlePIP: .littlePIP
        case .littleDIP: .littleDIP
        case .littleTip: .littleTip
        }
    }
}
