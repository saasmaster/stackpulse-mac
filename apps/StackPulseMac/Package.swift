// swift-tools-version:6.0
import PackageDescription

// StackPulse macOS app.
//
// The Rust portable core is linked in as a static library produced by
// `cargo build -p stackpulse-ffi --release` (see scripts/build-core.sh). The
// `-L` path is RELATIVE to this package directory so it survives a repo path
// that contains spaces; run `swift build` from this directory (the build
// scripts do). The `CStackPulseCore` system-library target exposes the C ABI
// header; the static archive is linked via the executable's linker settings.
let package = Package(
    name: "StackPulseMac",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .systemLibrary(
            name: "CStackPulseCore",
            path: "Sources/CStackPulseCore"
        ),
        .executableTarget(
            name: "StackPulseApp",
            dependencies: ["CStackPulseCore"],
            path: "Sources/StackPulseApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                // Link the Rust core as a STATIC archive by explicit path. Using
                // the archive path directly (rather than -L/-l) guarantees a
                // static link: with -l the linker would prefer the sibling
                // libstackpulse_ffi.dylib and bake in a fragile absolute dynamic
                // dependency that breaks when the .app is re-signed. Path is
                // relative to this package dir; build from here (scripts do).
                .unsafeFlags([
                    "../../target/release/libstackpulse_ffi.a",
                    // System frameworks the Rust std references on macOS.
                    "-framework", "CoreFoundation",
                    "-framework", "Security",
                    "-framework", "SystemConfiguration",
                    "-liconv",
                ])
            ]
        ),
        .testTarget(
            name: "StackPulseAppTests",
            dependencies: ["StackPulseApp"],
            path: "Tests/StackPulseAppTests",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                // Same static archive the executable links: the test binary pulls
                // in the app module, which calls the Rust core over the C ABI.
                .unsafeFlags([
                    "../../target/release/libstackpulse_ffi.a",
                    "-framework", "CoreFoundation",
                    "-framework", "Security",
                    "-framework", "SystemConfiguration",
                    "-liconv",
                ])
            ]
        )
    ]
)
