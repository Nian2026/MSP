// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MSPPlaygroundApp",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .executable(name: "MSPPlaygroundApp", targets: ["MSPPlaygroundApp"])
    ],
    dependencies: [
        .package(name: "ModelShellProxy", path: "../../../Implementations/Swift")
    ],
    targets: [
        .executableTarget(
            name: "MSPPlaygroundApp",
            dependencies: [
                .product(name: "ModelShellProxy", package: "ModelShellProxy"),
                .product(name: "MSPCore", package: "ModelShellProxy"),
                .product(name: "MSPAgentBridge", package: "ModelShellProxy"),
                .product(name: "MSPApple", package: "ModelShellProxy"),
                .product(name: "MSPCodexApplyPatchRuntime", package: "ModelShellProxy"),
                .product(name: "MSPGit", package: "ModelShellProxy"),
                .product(name: "MSPPythonEmbeddedRuntime", package: "ModelShellProxy"),
                .product(name: "MSPPythonRuntime", package: "ModelShellProxy")
            ],
            path: ".",
            exclude: [
                "README.md",
                "Agent/README.md",
                "Docs/ProductShape.md",
                "Features/Chat/README.md",
                "Features/Files/README.md",
                "Features/WorkspaceDrawer/README.md",
                "App/Info.plist",
                "Vendor/ExampleChatTranscriptRenderer/VENDOR_MANIFEST.md",
                "Project",
                "Resources",
                "Tests",
                "Tools"
            ],
            sources: [
                "App",
                "Shell",
                "Workspace",
                "DesignSystem",
                "Adapters/ExampleChatTranscriptRenderer",
                "Agent/ModelConfig",
                "Agent/CodexOAuth",
                "Agent/ToolLoop",
                "Agent/Transcript",
                "Vendor/ExampleChatTranscriptRenderer/Swift",
                "Features/Chat/Views",
                "Features/Files/Models",
                "Features/Files/Views",
                "Features/WorkspaceDrawer/Views"
            ],
            resources: [
                .copy("Vendor/ExampleChatTranscriptRenderer/RuntimeResources")
            ]
        ),
        .testTarget(
            name: "MSPPlaygroundAppTests",
            dependencies: [
                "MSPPlaygroundApp",
                .product(name: "MSPAgentBridge", package: "ModelShellProxy")
            ],
            path: "Tests/MSPPlaygroundAppTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
