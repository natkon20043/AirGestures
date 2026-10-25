#pragma once

#include <functional>
#include <optional>

#include "gesture.hpp"
#include "landmarks.hpp"

namespace ag {

// nullopt means no hand was found in the frame
using HandCallback = std::function<void(const std::optional<Hand>&)>;

class ICameraSource {
public:
    // ---- Destructor
    virtual ~ICameraSource() = default;

    // ---- Control
    virtual void start() = 0;
    virtual void stop() = 0;
};

class IHandTracker {
public:
    // ---- Destructor
    virtual ~IHandTracker() = default;

    // ---- Setters
    virtual void setHandCallback(HandCallback callback) = 0;

    // ---- Control
    virtual void start() = 0;
    virtual void stop() = 0;
};

class IActionSink {
public:
    // ---- Destructor
    virtual ~IActionSink() = default;

    // ---- Output
    virtual void onGesture(const GestureState& state) = 0;
};

}  // namespace ag
