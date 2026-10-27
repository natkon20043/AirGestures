// swift-tools-version:6.0
import Foundation
import PackageDescription

// A command-line binary needs an embedded Info.plist (with NSCameraUsageDescription)
// or macOS will kill it the moment it touches the camera.
let infoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Support/Info.plist")
    .path

let package = Package(
    name: "AirGestures",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AirGestures",
            path: "Sources/AirGestures",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlist,
                ])
            ]
        ),
        .testTarget(
            name: "AirGesturesTests",
            dependencies: ["AirGestures"],
            path: "Tests/AirGesturesTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
