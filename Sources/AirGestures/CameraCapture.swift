import AVFoundation

enum CameraError: Error, CustomStringConvertible {
    case noCamera(query: String?)
    case cannotAddInput
    case cannotAddOutput

    var description: String {
        switch self {
        case .noCamera(let query?): "No camera matching \"\(query)\". Try --list-cameras."
        case .noCamera(nil): "No camera found."
        case .cannotAddInput: "Could not attach the camera to the capture session."
        case .cannotAddOutput: "Could not add a video output to the capture session."
        }
    }
}

/// Owns the AVCaptureSession. AVFoundation calls `captureOutput(_:didOutput:from:)` for every
/// frame on `queue` — that delegate callback is the real-time "listener" that drives everything.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Called on the camera queue with each frame and its capture time in seconds.
    var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?
    /// Orientation to hand to Vision so coordinates match what the user sees (mirror view).
    private(set) var orientation: CGImagePropertyOrientation = .up
    private(set) var deviceName = ""

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.airgestures.camera")

    static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// - Parameter query: optional case-insensitive substring of the camera name.
    func configure(cameraMatching query: String?) throws {
        let device: AVCaptureDevice?
        if let query {
            device = Self.availableDevices().first { $0.localizedName.localizedCaseInsensitiveContains(query) }
        } else {
            device = AVCaptureDevice.default(for: .video)
        }
        guard let device else { throw CameraError.noCamera(query: query) }
        deviceName = device.localizedName

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Vision doesn't need much resolution for hands, and smaller frames mean lower latency.
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        // If Vision falls behind, drop stale frames rather than queueing them up.
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
        session.addOutput(output)

        // Mirror like FaceTime so "move hand right" means +x.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
            orientation = .up
        } else {
            orientation = .upMirrored
        }
    }

    func start() {
        queue.async { self.session.startRunning() }
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        onFrame?(pixelBuffer, time)
    }
}
