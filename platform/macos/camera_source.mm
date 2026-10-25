#import "camera_source.h"

#import <os/log.h>

static os_log_t cameraLog = os_log_create("com.nate.airgestures", "camera");

// Receives each frame from AVFoundation and passes it to the C++ handler.
@interface AGFrameDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
- (instancetype)initWithHandler:(ag::CameraSource::FrameHandler)handler;
@end

@implementation AGFrameDelegate {
    ag::CameraSource::FrameHandler _handler;
}

- (instancetype)initWithHandler:(ag::CameraSource::FrameHandler)handler {
    self = [super init];
    if (self) {
        _handler = std::move(handler);
    }
    return self;
}

- (void)captureOutput:(AVCaptureOutput*)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection*)connection {
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer == nullptr || !_handler) {
        return;
    }
    _handler(pixelBuffer);
}

@end

namespace ag {

CameraSource::CameraSource()
    : queue_(dispatch_queue_create("com.nate.airgestures.camera", DISPATCH_QUEUE_SERIAL)) {}

CameraSource::~CameraSource() {
    stop();
}

void CameraSource::setFrameHandler(FrameHandler handler) {
    frameHandler_ = std::move(handler);
}

void CameraSource::start() {
    const AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];

    switch (status) {
        case AVAuthorizationStatusAuthorized:
            startSession();
            break;

        case AVAuthorizationStatusNotDetermined:
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                     completionHandler:^(BOOL granted) {
                                         if (granted) {
                                             startSession();
                                         } else {
                                             os_log(cameraLog, "Camera access was not granted");
                                         }
                                     }];
            break;

        default:
            os_log(cameraLog, "Camera access is denied; enable it in System Settings > Privacy & Security");
            break;
    }
}

// Blocks until the session has stopped, so no frame arrives after this returns.
void CameraSource::stop() {
    dispatch_sync(queue_, ^{
        if (session_ != nil && session_.isRunning) {
            [session_ stopRunning];
            os_log(cameraLog, "Camera stopped");
        }
    });
}

void CameraSource::startSession() {
    dispatch_async(queue_, ^{
        if (session_ == nil && !configureSession()) {
            return;
        }
        [session_ startRunning];
        os_log(cameraLog, "Camera started");
    });
}

bool CameraSource::configureSession() {
    AVCaptureDevice* device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    if (device == nil) {
        os_log(cameraLog, "No camera found");
        return false;
    }

    NSError* error = nil;
    AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (input == nil) {
        os_log(cameraLog, "Could not open camera: %{public}@", error.localizedDescription);
        return false;
    }

    AVCaptureSession* session = [[AVCaptureSession alloc] init];
    if ([session canSetSessionPreset:AVCaptureSessionPreset640x480]) {
        session.sessionPreset = AVCaptureSessionPreset640x480;
    }

    frameDelegate_ = [[AGFrameDelegate alloc] initWithHandler:frameHandler_];

    AVCaptureVideoDataOutput* output = [[AVCaptureVideoDataOutput alloc] init];
    output.alwaysDiscardsLateVideoFrames = YES;
    [output setSampleBufferDelegate:frameDelegate_ queue:queue_];

    if (![session canAddInput:input] || ![session canAddOutput:output]) {
        os_log(cameraLog, "Could not attach camera input and output");
        return false;
    }
    [session addInput:input];
    [session addOutput:output];

    session_ = session;
    return true;
}

}  // namespace ag
