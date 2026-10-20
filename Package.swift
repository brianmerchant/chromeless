// swift-tools-version:5.9
// Chromeless — the browser that isn't there — built with FullPanelKit so its
// native fullscreen Space covers the whole MacBook display, beside the camera
// housing. build.sh packages the executable into an .app bundle.
import PackageDescription

let package = Package(
    name: "Chromeless",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Chromeless", targets: ["Chromeless"])
    ],
    dependencies: [
        // Pinned to the published 0.1.0 release (git tag v0.1.0); see Package.resolved.
        .package(url: "https://github.com/brianmerchant/FullPanelKit.git", exact: "0.1.0")
    ],
    targets: [
        .executableTarget(
            name: "Chromeless",
            dependencies: [
                .product(name: "FullPanelKit", package: "FullPanelKit")
            ]
        )
    ]
)
