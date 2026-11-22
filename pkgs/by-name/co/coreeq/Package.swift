// swift-tools-version: 6.0
//
// Upstream builds with `xcodebuild` (CoreEQ.xcodeproj) and ships no
// Package.swift; this manifest reproduces that project's Release settings for
// SwiftPM (see project.pbxproj). String Catalogs are excluded because the
// build system would shell out to `xcstringstool`, which ships only with
// Xcode; package.nix compiles the catalog when installing the bundle instead.

import PackageDescription

let package = Package(
    name: "CoreEQ",
    defaultLocalization: "en",
    platforms: [
        // Matches MACOSX_DEPLOYMENT_TARGET: the engine calls the process-tap
        // APIs (AudioHardwareCreateProcessTap, macOS 14.2+) unguarded.
        .macOS("14.2"),
    ],
    targets: [
        .executableTarget(
            name: "CoreEQ",
            path: "CoreEQ",
            exclude: [
                "Resources/InfoPlist.xcstrings",
                "Resources/Localizable.xcstrings",
            ],
            resources: [
                .copy("Resources/AppIcon.icns"),
                .copy("Resources/AppIcon.icon"),
                .copy("Resources/AutoEq-LICENSE.txt"),
                .copy("Resources/MenuBarIconSlashTemplate.png"),
                .copy("Resources/MenuBarIconSlashTemplate@2x.png"),
                .copy("Resources/MenuBarIconTemplate.png"),
                .copy("Resources/MenuBarIconTemplate@2x.png"),
            ],
            swiftSettings: [
                // Xcode's Release builds define COREEQ_TCC_SPI
                // (SWIFT_ACTIVE_COMPILATION_CONDITIONS), which allows looking
                // up TCC's private entry points with dlsym at runtime.
                .define("COREEQ_TCC_SPI"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("ImmutableWeakCaptures"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("InternalImportsByDefault"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        )
    ]
)
