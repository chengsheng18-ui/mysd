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
        // `import CMirage` resolves through the modulemap shipped INSIDE
        // sdcpp.xcframework. Do not add a local C target with the same module
        // name: clang fails with "Build a shadowed submodule 'CMirage'".
        .target(
            name: "Mirage",
            dependencies: ["sdcpp"],
            path: "Sources/Mirage"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
