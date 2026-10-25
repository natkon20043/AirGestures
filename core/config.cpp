#include "config.hpp"

#include <algorithm>

namespace ag {

Config sanitized(Config config) {
    config.smoothingAlpha = std::clamp(config.smoothingAlpha, 0.01f, 1.0f);
    config.minJointConfidence = std::clamp(config.minJointConfidence, 0.0f, 1.0f);
    config.pinchEnterRatio = std::clamp(config.pinchEnterRatio, 0.05f, 1.0f);

    // exit must be at least as wide as enter, or a pinch would flicker
    config.pinchExitRatio = std::max(config.pinchExitRatio, config.pinchEnterRatio);
    return config;
}

}  // namespace ag
