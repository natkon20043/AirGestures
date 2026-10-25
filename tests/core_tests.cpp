#include <cmath>
#include <cstdio>

#include "gesture.hpp"

namespace {

int failureCount = 0;

void check(bool condition, const char* description) {
    if (condition) {
        return;
    }
    std::printf("FAIL: %s\n", description);
    failureCount += 1;
}

bool isClose(float first, float second) {
    return std::fabs(first - second) < 0.0001f;
}

// wrist to middle tip is 0.4 long, so a gap of 0.05 is a ratio of 0.125
ag::Hand makeHand(float thumbIndexGap, float confidence) {
    ag::Hand hand;

    auto place = [&hand](ag::JointId id, float x, float y, float jointConfidence) {
        ag::Joint& joint = hand.joints[static_cast<std::size_t>(id)];
        joint.x = x;
        joint.y = y;
        joint.confidence = jointConfidence;
    };

    place(ag::JointId::Wrist, 0.5f, 0.2f, confidence);
    place(ag::JointId::ThumbTip, 0.5f, 0.5f, confidence);
    place(ag::JointId::IndexTip, 0.5f + thumbIndexGap, 0.5f, confidence);
    place(ag::JointId::MiddleTip, 0.5f, 0.6f, confidence);
    place(ag::JointId::RingTip, 0.4f, 0.55f, confidence);
    place(ag::JointId::LittleTip, 0.3f, 0.5f, confidence);
    return hand;
}

void testSmoother() {
    ag::ExponentialSmoother smoother(0.5f);
    check(isClose(smoother.add(1.0f), 1.0f), "first value passes through");
    check(isClose(smoother.add(0.0f), 0.5f), "second value is blended");

    smoother.reset();
    check(isClose(smoother.add(0.8f), 0.8f), "reset forgets history");
}

void testConfig() {
    ag::Config config;
    config.smoothingAlpha = 5.0f;
    config.pinchEnterRatio = 0.5f;
    config.pinchExitRatio = 0.1f;

    const ag::Config fixed = ag::sanitized(config);
    check(isClose(fixed.smoothingAlpha, 1.0f), "alpha is clamped");
    check(fixed.pinchExitRatio >= fixed.pinchEnterRatio, "exit is never below enter");
}

void testGestures() {
    ag::GestureEngine engine{ag::Config{}};

    check(engine.update(std::nullopt).kind == ag::GestureKind::None, "no hand gives none");
    check(engine.update(makeHand(0.2f, 1.0f)).kind == ag::GestureKind::Open, "wide gap is open");
    check(engine.update(makeHand(0.05f, 1.0f)).kind == ag::GestureKind::Pinch, "small gap is pinch");

    // ratio 0.35 sits between enter (0.25) and exit (0.40)
    check(engine.update(makeHand(0.14f, 1.0f)).kind == ag::GestureKind::Pinch, "pinch holds inside hysteresis");
    check(engine.update(makeHand(0.2f, 1.0f)).kind == ag::GestureKind::Open, "pinch releases past exit");
    check(engine.update(makeHand(0.14f, 1.0f)).kind == ag::GestureKind::Open, "open holds inside hysteresis");

    check(engine.update(makeHand(0.05f, 0.1f)).kind == ag::GestureKind::None, "low confidence gives none");
}

}  // namespace

int main() {
    testSmoother();
    testConfig();
    testGestures();

    if (failureCount == 0) {
        std::printf("all core tests passed\n");
    }
    return failureCount == 0 ? 0 : 1;
}
