// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AndroidFileTransferApp",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AndroidFileTransferApp", targets: ["AndroidFileTransferApp"])
    ],
    targets: [
        .executableTarget(
            name: "AndroidFileTransferApp",
            path: "Source"
        )
    ]
)
