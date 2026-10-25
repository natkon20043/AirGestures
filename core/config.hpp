#pragma once

namespace ag {

struct Config {
    // ---- Variables
    float smoothingAlpha = 0.35f;
    float minJointConfidence = 0.3f;
    float pinchEnterRatio = 0.25f;
    float pinchExitRatio = 0.40f;
};

// ---- Validation
Config sanitized(Config config);

}  // namespace ag
