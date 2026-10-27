import CoreGraphics
import Testing
@testable import AirGestures

/// Hands drawn by hand: palm facing the camera, knuckles in a row at y = 0.40, no wrist anywhere.
/// Each finger is four points (knuckle, middle joint, top joint, tip). `offset` slides the whole
/// hand across the frame, so a hand can change shape mid-move and stay where it was.
struct DrawnHand {
    var offset = CGVector.zero
    var joints: [Joint: CGPoint] = [
        .indexMCP: CGPoint(x: 0.44, y: 0.40),
        .middleMCP: CGPoint(x: 0.48, y: 0.40),
        .ringMCP: CGPoint(x: 0.52, y: 0.40),
        .littleMCP: CGPoint(x: 0.56, y: 0.40),
        .thumbCMC: CGPoint(x: 0.42, y: 0.30),
        .thumbMP: CGPoint(x: 0.38, y: 0.33),
    ]

    mutating func straight(_ finger: Finger) {
        let base = joints[finger.chain[0]]!
        joints[finger.chain[1]] = CGPoint(x: base.x, y: base.y + 0.05)
        joints[finger.chain[2]] = CGPoint(x: base.x, y: base.y + 0.08)
        joints[finger.chain[3]] = CGPoint(x: base.x, y: base.y + 0.11)
    }

    /// Seen from the front, a curled finger goes up one bone, then folds back down toward the palm.
    mutating func curled(_ finger: Finger) {
        let base = joints[finger.chain[0]]!
        joints[finger.chain[1]] = CGPoint(x: base.x, y: base.y + 0.04)
        joints[finger.chain[2]] = CGPoint(x: base.x, y: base.y + 0.02)
        joints[finger.chain[3]] = CGPoint(x: base.x, y: base.y - 0.005)
    }

    /// The index bending over in a C toward the thumb, the way it does in a pinch.
    mutating func hookedIndex() {
        joints[.indexPIP] = CGPoint(x: 0.43, y: 0.45)
        joints[.indexDIP] = CGPoint(x: 0.40, y: 0.47)
        joints[.indexTip] = CGPoint(x: 0.37, y: 0.455)
    }

    mutating func thumbOut() {
        joints[.thumbIP] = CGPoint(x: 0.34, y: 0.36)
        joints[.thumbTip] = CGPoint(x: 0.30, y: 0.39)
    }

    mutating func thumbTouchingIndexTip() {
        joints[.thumbIP] = CGPoint(x: 0.36, y: 0.39)
        joints[.thumbTip] = CGPoint(x: 0.37, y: 0.445)
    }

    /// The thumb folded across the curled fingers.
    mutating func thumbTucked() {
        joints[.thumbIP] = CGPoint(x: 0.44, y: 0.37)
        joints[.thumbTip] = CGPoint(x: 0.49, y: 0.38)
    }

    var snapshot: HandSnapshot {
        let placed = joints.mapValues { CGPoint(x: $0.x + offset.dx, y: $0.y + offset.dy) }
        let confidence = placed.mapValues { _ in Float(0.9) }
        return HandSnapshot(chirality: .right, confidence: 0.9, joints: placed,
                            jointConfidence: confidence, aspectRatio: 1)
    }
}

@Test func openHandHasFiveFingersWithNoWristInSight() {
    var hand = DrawnHand()
    Finger.fourFingers.forEach { hand.straight($0) }
    hand.thumbOut()
    let snapshot = hand.snapshot
    #expect(snapshot.joints[.wrist] == nil)
    #expect(snapshot.fingerCount == 5)
    #expect(!snapshot.isPinchPose)
    #expect(!snapshot.isFist)
}

@Test func fourFingersUpThumbTucked() {
    var hand = DrawnHand()
    Finger.fourFingers.forEach { hand.straight($0) }
    hand.thumbTucked()
    let snapshot = hand.snapshot
    #expect(snapshot.extendedFingers == [.index, .middle, .ring, .little])
    #expect(!snapshot.isPinchPose)
}

@Test func fistIsAllFourCurledAndNotAPinch() {
    var hand = DrawnHand()
    Finger.fourFingers.forEach { hand.curled($0) }
    hand.thumbTucked()
    let snapshot = hand.snapshot
    #expect(snapshot.isFist)
    #expect(!snapshot.isPinchPose)
    #expect(snapshot.fingerCount == 0)
}

@Test func pinchIsABentIndexMeetingTheThumb() {
    var hand = DrawnHand()
    hand.hookedIndex()
    [Finger.middle, .ring, .little].forEach { hand.curled($0) }
    hand.thumbTouchingIndexTip()
    let snapshot = hand.snapshot
    #expect(snapshot.fingerStates[.index] == .bent)
    #expect(snapshot.isPinchPose)
    #expect(snapshot.isPinching)
    #expect(!snapshot.isFist)
}

@Test func pointingWithThumbTuckedIsOneFingerNotAPinch() {
    var hand = DrawnHand()
    hand.straight(.index)
    [Finger.middle, .ring, .little].forEach { hand.curled($0) }
    hand.thumbTucked()
    let snapshot = hand.snapshot
    #expect(snapshot.extendedFingers == [.index])
    #expect(!snapshot.isPinchPose)
}

@Test func fingersThatArentSeenAreNotCountedAsCurled() {
    // Only the knuckles: nothing is known about the fingers, so it must not look like a pinch or a fist.
    let snapshot = DrawnHand().snapshot
    #expect(snapshot.fingerStates.isEmpty)
    #expect(!snapshot.isPinchPose)
    #expect(!snapshot.isFist)
}

@Test func straightnessIgnoresPointingAtTheCamera() {
    // Foreshortened: the same straight finger, a third as long on screen.
    var hand = DrawnHand()
    hand.joints[.indexPIP] = CGPoint(x: 0.44, y: 0.4167)
    hand.joints[.indexDIP] = CGPoint(x: 0.44, y: 0.4267)
    hand.joints[.indexTip] = CGPoint(x: 0.44, y: 0.4367)
    #expect(hand.snapshot.fingerStates[.index] == .extended)
}
