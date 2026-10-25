#include "gesture.hpp"

#include <cmath>

namespace ag {

namespace {

float distanceBetween(const Joint& first, const Joint& second) {
    const float deltaX = first.x - second.x;
    const float deltaY = first.y - second.y;
    return std::sqrt(deltaX * deltaX + deltaY * deltaY);
}

}  // namespace

GestureEngine::GestureEngine(const Config& config)
    : config_(config),
      smootherX_(config.smoothingAlpha),
      smootherY_(config.smoothingAlpha) {}

GestureState GestureEngine::update(const std::optional<Hand>& hand) {
    if (!hand.has_value() || !hasConfidentJoints(*hand)) {
        resetTracking();
        return GestureState{};
    }

    updatePinching(*hand);

    const Joint& indexTip = hand->joint(JointId::IndexTip);

    GestureState state;
    state.kind = pinching_ ? GestureKind::Pinch : GestureKind::Open;
    state.x = smootherX_.add(indexTip.x);
    state.y = smootherY_.add(indexTip.y);
    return state;
}

bool GestureEngine::hasConfidentJoints(const Hand& hand) const {
    for (const Joint& joint : hand.joints) {
        if (joint.confidence < config_.minJointConfidence) {
            return false;
        }
    }
    return true;
}

void GestureEngine::updatePinching(const Hand& hand) {
    const float handSize = distanceBetween(hand.joint(JointId::Wrist), hand.joint(JointId::MiddleTip));
    if (handSize < 0.001f) {
        pinching_ = false;
        return;
    }

    const float gap = distanceBetween(hand.joint(JointId::ThumbTip), hand.joint(JointId::IndexTip));
    const float ratio = gap / handSize;

    // two thresholds (hysteresis) so a hand hovering at the edge does not flicker
    if (pinching_) {
        pinching_ = ratio < config_.pinchExitRatio;
    } else {
        pinching_ = ratio < config_.pinchEnterRatio;
    }
}

void GestureEngine::resetTracking() {
    pinching_ = false;
    smootherX_.reset();
    smootherY_.reset();
}

const char* gestureName(GestureKind kind) {
    switch (kind) {
        case GestureKind::None:
            return "none";
        case GestureKind::Open:
            return "open";
        case GestureKind::Pinch:
            return "pinch";
    }
    return "unknown";
}

}  // namespace ag
