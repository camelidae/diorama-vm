// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "microvm",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "microvm", targets: ["microvm"]),
    ],
    targets: [
        .executableTarget(
            name: "microvm",
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
    ]
)
