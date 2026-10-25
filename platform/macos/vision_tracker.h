#pragma once

#import <Vision/Vision.h>

#include "camera_source.h"
#include "interfaces.hpp"

namespace ag {

class VisionTracker : public IHandTracker {
public:
    // ---- Constructors
    explicit VisionTracker(CameraSource& camera);
    VisionTracker(const VisionTracker&) = delete;
    VisionTracker& operator=(const VisionTracker&) = delete;

    // ---- Destructor
    ~VisionTracker() override;

    // ---- Setters
    void setHandCallback(HandCallback callback) override;

    // ---- Control
    void start() override;
    void stop() override;

private:
    // ---- Detection
    void handleFrame(CVPixelBufferRef pixelBuffer);
    std::optional<Hand> detectHand(CVPixelBufferRef pixelBuffer);

    // ---- Variables
    CameraSource& camera_;
    HandCallback handCallback_;
    VNDetectHumanHandPoseRequest* request_ = nil;
};

}  // namespace ag
