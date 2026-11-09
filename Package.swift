// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FileShift",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FileShift", targets: ["FileShift"]),
        .executable(name: "fileshift-cli", targets: ["fileshift-cli"]),
        .library(name: "FileShiftCore", targets: ["FileShiftCore"]),
    ],
    targets: [
        .target(name: "FileShiftCore"),
        .executableTarget(name: "FileShift", dependencies: ["FileShiftCore"]),
        .executableTarget(name: "fileshift-cli", dependencies: ["FileShiftCore"]),
        .testTarget(name: "FileShiftCoreTests", dependencies: ["FileShiftCore", "fileshift-cli"]),
    ]
)
