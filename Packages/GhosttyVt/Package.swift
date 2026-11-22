// swift-tools-version: 5.9
import PackageDescription

// libghostty-vt, the terminal emulation half of Ghostty without a renderer or a
// window, as the prebuilt xcframework the Ghostty project publishes.
//
// This package holds no source. It exists so the binary enters the build the way
// GhosttyKit does, as a package product, with nothing vendored in the repository.
//
// The checksum is the pin. The C ABI is stable from 1.0, but the snapshot byte
// format is versioned separately and is not covered by that promise, so a new
// release is a deliberate change here and never a range. See the comment on the
// package in project.yml.
//
// The xcframework holds static libraries (macOS universal, iOS, iOS simulator), so
// a target that depends on this links it and embeds nothing.
let package = Package(
    name: "GhosttyVt",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GhosttyVt", targets: ["GhosttyVt"]),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyVt",
            url: "https://release.files.ghostty.org/libghostty-vt/1.0.1/ghostty-vt-1.0.1.xcframework.zip",
            checksum: "c0f9631277f726154c8f521954d17cdc41aac4626fc0df8cf925a19ee58e829b"
        ),
    ]
)
