// swift-tools-version: 6.2

import Foundation
import PackageDescription

let packageDirectoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localFastVLMSourcePath = "Local/FastVLM"
let localFastVLMSourceURL = packageDirectoryURL
    .appendingPathComponent(localFastVLMSourcePath, isDirectory: true)
    .appendingPathComponent("FastVLM.swift")
let includeLocalFastVLM = ProcessInfo.processInfo.environment["PHOTOSORTER_ENABLE_LOCAL_FASTVLM"] == "1"
    && FileManager.default.fileExists(atPath: localFastVLMSourceURL.path)

let packageDependencies: [Package.Dependency] = [
    .package(name: "ModelShellProxy", path: "../../../Implementations/Swift")
] + (includeLocalFastVLM ? [
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.21.2"),
    .package(url: "https://github.com/ml-explore/mlx-swift-examples", exact: "2.21.2"),
    .package(url: "https://github.com/huggingface/swift-transformers", exact: "0.1.18")
] : [])

let photoSorterTargetDependencies: [Target.Dependency] = [
    "PhotoSorterVisionSupport",
    .product(name: "ModelShellProxy", package: "ModelShellProxy"),
    .product(name: "MSPCore", package: "ModelShellProxy"),
    .product(name: "MSPAgentBridge", package: "ModelShellProxy"),
    .product(name: "MSPAgentChatStore", package: "ModelShellProxy"),
    .product(name: "MSPApple", package: "ModelShellProxy"),
    .product(name: "MSPChatCommands", package: "ModelShellProxy"),
    .product(name: "MSPPythonEmbeddedRuntime", package: "ModelShellProxy"),
    .product(name: "MSPPythonRuntime", package: "ModelShellProxy")
] + (includeLocalFastVLM ? [
    .product(name: "MLX", package: "mlx-swift"),
    .product(name: "MLXNN", package: "mlx-swift"),
    .product(name: "MLXFast", package: "mlx-swift"),
    .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
    .product(name: "MLXVLM", package: "mlx-swift-examples"),
    .product(name: "Transformers", package: "swift-transformers")
] : [])

let photoSorterSources = [
    "App",
    "Shell",
    "Workspace",
    "Diagnostics",
    "DesignSystem",
    "Adapters/ExampleChatTranscriptRenderer",
    "Agent/AccessControl",
    "Agent/ModelConfig",
    "Agent/CodexOAuth",
    "Agent/ToolLoop",
    "Agent/Transcript",
    "Vendor/ExampleChatTranscriptRenderer/Swift",
    "Features/Chat/Views",
    "Features/Files/Models",
    "Features/Files/Views",
    "Features/WorkspaceDrawer/Views"
] + (includeLocalFastVLM ? [localFastVLMSourcePath] : [])

let photoSorterResources: [Resource] = [
    .copy("Vendor/ExampleChatTranscriptRenderer/RuntimeResources")
] + (includeLocalFastVLM ? [
    .copy("Resources/FastVLM")
] : [])

let photoSorterExcludes = [
    "README.md",
    "Agent/README.md",
    "Agent/PhotoSorterAgentInstructionsDraft.md",
    "Docs/ProductShape.md",
    "Features/Chat/README.md",
    "Features/Files/README.md",
    "Features/WorkspaceDrawer/README.md",
    "App/Info.plist",
    "Vendor/README.md",
    "Vendor/ExampleChatTranscriptRenderer/VENDOR_MANIFEST.md",
    "VisionSupport",
    "Project",
    "Tests",
    "Tools",
    "VLM"
] + (includeLocalFastVLM ? [
    "Local/README.md"
] : [
    "Local",
    "Resources/FastVLM"
])

let package = Package(
    name: "PhotoSorter",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
    ],
    products: [
        .executable(name: "PhotoSorter", targets: ["PhotoSorter"])
    ],
    dependencies: packageDependencies,
    targets: [
        .executableTarget(
            name: "PhotoSorter",
            dependencies: photoSorterTargetDependencies,
            path: ".",
            exclude: photoSorterExcludes,
            sources: photoSorterSources,
            resources: photoSorterResources
        ),
        .target(
            name: "PhotoSorterVisionSupport",
            path: "VisionSupport",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("ImageIO"),
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "PhotoSorterTests",
            dependencies: [
                "PhotoSorter",
                .product(name: "ModelShellProxy", package: "ModelShellProxy"),
                .product(name: "MSPCore", package: "ModelShellProxy"),
                .product(name: "MSPAgentBridge", package: "ModelShellProxy")
            ],
            path: "Tests/PhotoSorterTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
