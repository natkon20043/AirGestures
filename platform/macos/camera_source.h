#pragma once

#import <AVFoundation/AVFoundation.h>

#include <functional>

#include "interfaces.hpp"

namespace ag {

class CameraSource : public ICameraSource {
public:
    using FrameHandler = std::function<void(CVPixelBufferRef)>;

    // ---- Constructors
    CameraSource();
    CameraSource(const CameraSource&) = delete;
    CameraSource& operator=(const CameraSource&) = delete;

    // ---- Destructor
    ~CameraSource() override;

    // ---- Setters
    void setFrameHandler(FrameHandler handler);

    // ---- Control
    void start() override;
    void stop() override;

private:
    // ---- Session
    void startSession();
    bool configureSession();

    // ---- Variables
    FrameHandler frameHandler_;
    dispatch_queue_t queue_;
    AVCaptureSession* session_ = nil;
    id frameDelegate_ = nil;
};

}  // namespace ag
