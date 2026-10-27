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
    /// Smoothing for palm velocity (0 = frozen, 1 = raw per-frame value).
    static let velocitySmoothing = 0.5
    /// Forget a hand's motion history if it hasn't been seen for this long.
    static let velocityResetInterval: TimeInterval = 0.3

    private let continuation: AsyncStream<HandFrame>.Continuation
    private let request: VNDetectHumanHandPoseRequest
    private let sequenceHandler = VNSequenceRequestHandler()
    private let swapHands: Bool
    private var previous: [Chirality: (center: CGPoint, time: TimeInterval, velocity: CGVector)] = [:]

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
            hand.velocity = updateVelocity(for: hand, at: timestamp)
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

    private func updateVelocity(for hand: HandSnapshot, at time: TimeInterval) -> CGVector {
        guard let center = hand.palmCenter else { return .zero }
        defer { previous[hand.chirality]?.center = center; previous[hand.chirality]?.time = time }

        guard let last = previous[hand.chirality],
              time - last.time < Self.velocityResetInterval,
              time > last.time else {
            previous[hand.chirality] = (center, time, .zero)
            return .zero
        }
        let dt = time - last.time
        let raw = CGVector(dx: (center.x - last.center.x) / dt, dy: (center.y - last.center.y) / dt)
        let a = Self.velocitySmoothing
        let smoothed = CGVector(dx: a * raw.dx + (1 - a) * last.velocity.dx,
                                dy: a * raw.dy + (1 - a) * last.velocity.dy)
        previous[hand.chirality]?.velocity = smoothed
        return smoothed
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
