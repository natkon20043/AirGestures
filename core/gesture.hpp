#pragma once

#include <optional>

#include "config.hpp"
#include "landmarks.hpp"
#include "smoothing.hpp"

namespace ag {

// hand landmarks -> what the hand is doing this frame
enum class GestureKind {
    None,
    Open,
    Pinch,
};

struct GestureState {
    // ---- Variables
    GestureKind kind = GestureKind::None;
    float x = 0.0f;
    float y = 0.0f;
};

class GestureEngine {
public:
    // ---- Constructors
    explicit GestureEngine(const Config& config);

    // ---- Update
    GestureState update(const std::optional<Hand>& hand);

private:
    // ---- Helpers
    bool hasConfidentJoints(const Hand& hand) const;
    void updatePinching(const Hand& hand);
    void resetTracking();

    // ---- Variables
    Config config_;
    ExponentialSmoother smootherX_;
    ExponentialSmoother smootherY_;
    bool pinching_ = false;
};

// ---- Names
const char* gestureName(GestureKind kind);

}  // namespace ag
