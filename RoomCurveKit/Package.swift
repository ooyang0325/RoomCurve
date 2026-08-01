// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RoomCurveKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RoomCurveKit", targets: ["RoomCurveKit"])
    ],
    targets: [
        .target(name: "RoomCurveKit"),
        .testTarget(name: "RoomCurveKitTests", dependencies: ["RoomCurveKit"])
    ]
)
