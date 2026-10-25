#pragma once

#include <functional>

#include "interfaces.hpp"

namespace ag {

// Echoes each gesture back to the user instead of controlling the Mac.
// Swap this for a CGEvent sink once the gestures feel right.
class EchoSink : public IActionSink {
public:
    using DisplayHandler = std::function<void(const GestureState&)>;

    // ---- Constructors
    explicit EchoSink(DisplayHandler display);

    // ---- Output
    void onGesture(const GestureState& state) override;

private:
    // ---- Variables
    DisplayHandler display_;
    GestureKind lastKind_ = GestureKind::None;
};

}  // namespace ag
