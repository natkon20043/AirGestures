#pragma once

namespace ag {

class ExponentialSmoother {
public:
    // ---- Constructors
    explicit ExponentialSmoother(float alpha);

    // ---- Filtering
    float add(float value);

    // ---- Reset
    void reset();

private:
    // ---- Variables
    float alpha_;
    float current_ = 0.0f;
    bool hasValue_ = false;
};

}  // namespace ag
