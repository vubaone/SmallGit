// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SmallGit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SmallGit", targets: ["SmallGit"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        // Test-only SwiftUI inspection. Pin reflection support so SDK changes
        // can be reviewed explicitly; this is never linked into the app.
        .package(url: "https://github.com/nalexn/ViewInspector.git", exact: "0.10.5")
    ],
    targets: [
        .executableTarget(
            name: "SmallGit",
            dependencies: ["Yams"],
            path: "Sources/SmallGit",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
                .enableUpcomingFeature("BareSlashRegexLiterals")
            ],
            // Embeds Info.plist into the executable's __TEXT,__info_plist
            // section so even `swift run SmallGit` is treated as a proper
            // app by macOS (correct Dock identification, window focus,
            // restoration ID, bundle identifier). When wrapped into a
            // proper .app via scripts/build-app.sh the same plist is also
            // dropped at Contents/Info.plist for tools that read it from
            // the bundle structure directly.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "SmallGitTests",
            dependencies: ["SmallGit"],
            path: "Tests/SmallGitTests"
        ),
        .testTarget(
            name: "SmallGitUITests",
            dependencies: ["SmallGit", .product(name: "ViewInspector", package: "ViewInspector")],
            path: "Tests/SmallGitUITests"
        )
    ]
)
