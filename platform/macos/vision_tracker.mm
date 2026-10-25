#import "vision_tracker.h"

#import <os/log.h>

static os_log_t visionLog = os_log_create("com.nate.airgestures", "vision");

namespace ag {

namespace {

// Vision's x runs left to right in the raw camera image; flip it once here so the core sees a mirror.
void storeJoint(Hand& hand,
                JointId id,
                VNHumanHandPoseObservation* observation,
                VNHumanHandPoseObservationJointName name) {
    NSError* error = nil;
    VNRecognizedPoint* point = [observation recognizedPointForJointName:name error:&error];

    Joint joint;
    if (point != nil) {
        joint.x = 1.0f - static_cast<float>(point.location.x);
        joint.y = static_cast<float>(point.location.y);
        joint.confidence = point.confidence;
    }
    hand.joints[static_cast<std::size_t>(id)] = joint;
}

}  // namespace

VisionTracker::VisionTracker(CameraSource& camera) : camera_(camera) {
    request_ = [[VNDetectHumanHandPoseRequest alloc] init];
    request_.maximumHandCount = 1;

    camera_.setFrameHandler([this](CVPixelBufferRef pixelBuffer) { handleFrame(pixelBuffer); });
}

// Stopping the camera blocks until in-flight frames finish, so handleFrame never sees a dead tracker.
VisionTracker::~VisionTracker() {
    camera_.stop();
}

void VisionTracker::setHandCallback(HandCallback callback) {
    handCallback_ = std::move(callback);
}

void VisionTracker::start() {
    camera_.start();
}

void VisionTracker::stop() {
    camera_.stop();
}

void VisionTracker::handleFrame(CVPixelBufferRef pixelBuffer) {
    @autoreleasepool {
        const std::optional<Hand> hand = detectHand(pixelBuffer);
        if (handCallback_) {
            handCallback_(hand);
        }
    }
}

std::optional<Hand> VisionTracker::detectHand(CVPixelBufferRef pixelBuffer) {
    VNImageRequestHandler* handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBuffer options:@{}];

    NSError* error = nil;
    if (![handler performRequests:@[ request_ ] error:&error]) {
        os_log(visionLog, "Hand pose request failed: %{public}@", error.localizedDescription);
        return std::nullopt;
    }

    VNHumanHandPoseObservation* observation = request_.results.firstObject;
    if (observation == nil) {
        return std::nullopt;
    }

    Hand hand;
    storeJoint(hand, JointId::Wrist, observation, VNHumanHandPoseObservationJointNameWrist);
    storeJoint(hand, JointId::ThumbTip, observation, VNHumanHandPoseObservationJointNameThumbTip);
    storeJoint(hand, JointId::IndexTip, observation, VNHumanHandPoseObservationJointNameIndexTip);
    storeJoint(hand, JointId::MiddleTip, observation, VNHumanHandPoseObservationJointNameMiddleTip);
    storeJoint(hand, JointId::RingTip, observation, VNHumanHandPoseObservationJointNameRingTip);
    storeJoint(hand, JointId::LittleTip, observation, VNHumanHandPoseObservationJointNameLittleTip);
    return hand;
}

}  // namespace ag
