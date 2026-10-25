#include "smoothing.hpp"

namespace ag {

ExponentialSmoother::ExponentialSmoother(float alpha) : alpha_(alpha) {}

float ExponentialSmoother::add(float value) {
    if (!hasValue_) {
        current_ = value;
        hasValue_ = true;
        return current_;
    }

    const float newPart = alpha_ * value;
    const float oldPart = (1.0f - alpha_) * current_;
    current_ = newPart + oldPart;
    return current_;
}

void ExponentialSmoother::reset() {
    hasValue_ = false;
}

}  // namespace ag
