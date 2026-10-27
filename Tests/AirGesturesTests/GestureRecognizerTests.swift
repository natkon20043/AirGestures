import CoreGraphics
import Testing
@testable import AirGestures

extension DrawnHand {
    /// Hooked like holding a ball: up one bone, over toward the thumb, then the tip turning back down.
    mutating func bent(_ finger: Finger) {
        let base = joints[finger.chain[0]]!
        joints[finger.chain[1]] = CGPoint(x: base.x, y: base.y + 0.04)
        joints[finger.chain[2]] = CGPoint(x: base.x - 0.02, y: base.y + 0.055)
        joints[finger.chain[3]] = CGPoint(x: base.x - 0.03, y: base.y + 0.045)
    }

    /// Every finger straight, all leaning in so the five tips nearly meet: a beak.
    mutating func beak() {
        let point = CGPoint(x: 0.50, y: 0.52)
        for (index, finger) in Finger.fourFingers.enumerated() {
            let base = joints[finger.chain[0]]!
            let tip = CGPoint(x: point.x + Double(index) * 0.004, y: point.y)
            for step in 1...3 {
                let along = Double(step) / 3
                joints[finger.chain[step]] = CGPoint(x: base.x + (tip.x - base.x) * along,
                                                     y: base.y + (tip.y - base.y) * along)
            }
        }
        joints[.thumbIP] = CGPoint(x: 0.44, y: 0.42)
        joints[.thumbTip] = CGPoint(x: 0.49, y: 0.51)
    }

    static var fourUp: DrawnHand {
        var hand = DrawnHand()
        Finger.fourFingers.forEach { hand.straight($0) }
        hand.thumbTucked()
        return hand
    }

    static var openHand: DrawnHand {
        var hand = DrawnHand()
        Finger.fourFingers.forEach { hand.straight($0) }
        hand.thumbOut()
        return hand
    }

    /// Fingers hooked and cupped in, the thumb curled up to meet them.
    static var claw: DrawnHand {
        var hand = DrawnHand()
        Finger.fourFingers.forEach { hand.bent($0) }
        hand.thumbTouchingIndexTip()
        return hand
    }

    /// Thumb and hooked index in a C, the other three curled.
    static var cPinch: DrawnHand {
        var hand = DrawnHand()
        hand.hookedIndex()
        [Finger.middle, .ring, .little].forEach { hand.curled($0) }
        hand.thumbTouchingIndexTip()
        return hand
    }

    /// Pointing with the thumb sticking out: an L.
    static var lShape: DrawnHand {
        var hand = DrawnHand()
        hand.straight(.index)
        [Finger.middle, .ring, .little].forEach { hand.curled($0) }
        hand.thumbOut()
        return hand
    }
}

/// Plays drawn hands through MotionTracker and GestureRecognizer at 30 frames a second,
/// the same way HandTracker and main.swift do with the camera.
private struct Player {
    var motion = MotionTracker()
    let recognizer = GestureRecognizer()
    var time = 0.0
    var position = CGVector.zero
    var seen: [String] = []

    /// Shows `shape` for `frames` frames, sliding it by `step` each frame.
    mutating func play(_ shape: DrawnHand, frames: Int, step: CGVector = .zero) {
        for _ in 0..<frames {
            position.dx += step.dx
            position.dy += step.dy
            var hand = shape
            hand.offset = position
            var snapshot = hand.snapshot
            motion.update(&snapshot, at: time)
            let frame = HandFrame(timestamp: time, hands: [snapshot], processingTime: 0)
            seen += recognizer.process(frame).map(\.description)
            time += 1.0 / 30
        }
    }

    func saw(_ text: String) -> Bool {
        seen.contains { $0.contains(text) }
    }
}

@Test func clawShapeIsBentFingersNotAFist() {
    let claw = DrawnHand.claw.snapshot
    #expect(claw.isClaw)
    #expect(!claw.isFist)
    #expect(!DrawnHand.openHand.snapshot.isClaw)
    #expect(!DrawnHand.cPinch.snapshot.isClaw)
}

@Test func losingFingersMidSwipeDoesNotTurnIntoAPinch() {
    // Four fingers up and still, then a fast move right. Halfway through, motion blur makes the
    // hand look exactly like a C pinch for four frames. It must still be one swipe right, no zoom.
    var player = Player()
    let right = CGVector(dx: 0.02, dy: 0)
    player.play(.fourUp, frames: 6)
    player.play(.fourUp, frames: 4, step: right)
    player.play(.cPinch, frames: 4, step: right)
    player.play(.fourUp, frames: 2, step: right)
    player.play(.fourUp, frames: 10)
    #expect(player.seen == ["gesture: 4-finger swipe right"])
}

@Test func swipeDirectionComesFromTheWholePathNotOneFrame() {
    // Mostly left, drifting a little up: left.
    var left = Player()
    left.play(.fourUp, frames: 6)
    left.play(.fourUp, frames: 10, step: CGVector(dx: -0.02, dy: 0.005))
    left.play(.fourUp, frames: 10)
    #expect(left.seen == ["gesture: 4-finger swipe left"])

    // A diagonal is too close to call, so it does nothing.
    var diagonal = Player()
    diagonal.play(.fourUp, frames: 6)
    diagonal.play(.fourUp, frames: 10, step: CGVector(dx: -0.02, dy: -0.018))
    diagonal.play(.fourUp, frames: 10)
    #expect(diagonal.seen.isEmpty)
}

@Test func swipeIgnoresAJointThatJumps() {
    // Vision misplaces one fingertip far away for a frame mid-swipe; the median step ignores it.
    var before = DrawnHand.fourUp.snapshot.joints
    var after = before.mapValues { CGPoint(x: $0.x + 0.02, y: $0.y) }
    after[.littleTip] = CGPoint(x: 0.9, y: 0.9)
    before[.wrist] = nil
    let step = MotionTracker.step(from: before, to: after)
    #expect(step != nil)
    #expect(abs(step!.dx - 0.02) < 1e-9)
    #expect(abs(step!.dy) < 1e-9)
}

@Test func pinchStartsFromACNotAnL() {
    var pointing = Player()
    pointing.play(.lShape, frames: 10)
    #expect(!pointing.saw("zoom"))

    var pinching = Player()
    pinching.play(.cPinch, frames: 10)
    #expect(pinching.seen.first == "gesture: zoom began")
}

@Test func openHandBunchingUpDoesNotResize() {
    var player = Player()
    player.play(.openHand, frames: 6)
    var beak = DrawnHand()
    beak.beak()
    #expect(beak.snapshot.isBeak)
    player.play(beak, frames: 10)
    #expect(!player.saw("resize"))
}

@Test func clawHeldStillStartsAResizeAndOpeningGrows() {
    var player = Player()
    player.play(.claw, frames: 5)
    #expect(player.seen == ["gesture: resize began"])
    player.play(.openHand, frames: 3)
    let grew = player.seen.contains { $0.hasPrefix("gesture: resize scale") && !$0.hasSuffix("scale 1.00") }
    #expect(grew, "\(player.seen)")
}

@Test func movingClawDoesNotStartAResize() {
    var player = Player()
    player.play(.claw, frames: 1)
    player.play(.claw, frames: 8, step: CGVector(dx: 0.03, dy: 0))
    #expect(!player.saw("resize"))
}
