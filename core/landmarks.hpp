#pragma once

#include <array>
#include <cstddef>

namespace ag {

// Vision joint name -> slot in Hand::joints
enum class JointId : std::size_t {
    Wrist,
    ThumbTip,
    IndexTip,
    MiddleTip,
    RingTip,
    LittleTip,
    Count,
};

// x and y run 0..1 with the origin at the bottom left, already mirrored like a mirror
struct Joint {
    float x = 0.0f;
    float y = 0.0f;
    float confidence = 0.0f;
};

struct Hand {
    // ---- Getters
    const Joint& joint(JointId id) const { return joints[static_cast<std::size_t>(id)]; }

    // ---- Variables
    std::array<Joint, static_cast<std::size_t>(JointId::Count)> joints{};
};

}  // namespace ag
