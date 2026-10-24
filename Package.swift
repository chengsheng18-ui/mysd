// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Mirage",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "Mirage", targets: ["Mirage"]),
    ],
    targets: [
        // Prebuilt sd.cpp + ggml + Metal + C wrapper.
        .binaryTarget(
            name: "sdcpp",
            path: "Frameworks/sdcpp.xcframework"
        ),
        // Local modulemap over the header mirrored out of the xcframework,
        // so `import CMirage` works without depending on the xcframework's
        // internal modulemap (which SwiftPM does not re-export).
        .target(
            name: "CMirage",
            path: "Sources/CMirage"
        ),
        .target(
            name: "Mirage",
            dependencies: ["sdcpp", "CMirage"],
            path: "Sources/Mirage"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
