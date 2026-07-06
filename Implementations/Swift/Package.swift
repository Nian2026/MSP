// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ModelShellProxy",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "ModelShellProxy", targets: ["ModelShellProxy"]),
        .library(name: "MSPCore", targets: ["MSPCore"]),
        .library(name: "MSPShellLanguage", targets: ["MSPShellLanguage"]),
        .library(name: "MSPShellExpansion", targets: ["MSPShellExpansion"]),
        .library(name: "MSPShell", targets: ["MSPShell"]),
        .library(name: "MSPCommandKit", targets: ["MSPCommandKit"]),
        .library(name: "MSPExternalRunner", targets: ["MSPExternalRunner"]),
        .library(name: "MSPGit", targets: ["MSPGit"]),
        .library(name: "MSPAgentBridge", targets: ["MSPAgentBridge"]),
        .library(name: "MSPPOSIXCore", targets: ["MSPPOSIXCore"]),
        .library(name: "MSPPythonRuntime", targets: ["MSPPythonRuntime"]),
        .library(name: "MSPPythonEmbeddedRuntime", targets: ["MSPPythonEmbeddedRuntime"]),
        .library(name: "MSPApple", targets: ["MSPApple"]),
        .library(name: "MSPChat", targets: ["MSPChat"]),
        .library(name: "MSPChatCommands", targets: ["MSPChatCommands"]),
        .library(name: "MSPAgentChatStore", targets: ["MSPAgentChatStore"]),
        .library(name: "MSPCodexApplyPatchRuntime", targets: ["MSPCodexApplyPatchRuntime"]),
        .executable(name: "msp-chat-validate", targets: ["MSPChatValidatorCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sharplet/swift-cgit2.git", exact: "1.1.1")
    ],
    targets: [
        .target(
            name: "MSPCore",
            path: "Sources/MSPCore"
        ),
        .target(
            name: "MSPShellLanguage",
            path: "Sources/MSPShellLanguage",
            sources: ["AST", "Conversion", "Lexer", "Parsed", "Parser", "Reconstruction", "Syntax", "Values"]
        ),
        .target(
            name: "MSPShellExpansion",
            dependencies: ["MSPShellLanguage"],
            path: "Sources/MSPShellExpansion",
            sources: ["API", "Arithmetic", "Brace", "Effects", "FieldSplitting", "Parameters", "Pattern", "Words"]
        ),
        .target(
            name: "MSPShell",
            dependencies: ["MSPShellLanguage", "MSPShellExpansion"],
            path: "Sources/MSPShell"
        ),
        .target(
            name: "MSPCommandKit",
            dependencies: ["MSPCore"],
            path: "Sources/MSPCommandKit"
        ),
        .target(
            name: "MSPExternalRunner",
            dependencies: ["MSPCore"],
            path: "Sources/MSPExternalRunner"
        ),
        .target(
            name: "MSPGit",
            dependencies: [
                "MSPCore",
                .product(name: "Cgit2", package: "swift-cgit2")
            ],
            path: "Sources/MSPGit"
        ),
        .target(
            name: "MSPAgentBridge",
            dependencies: ["MSPCore"],
            path: "Sources",
            exclude: [
                "MSPApple",
                "MSPChat",
                "MSPChatCommands",
                "MSPAgentChatStore",
                "MSPChatValidatorCLI",
                "MSPCodexApplyPatchRuntime",
                "MSPCommandKit",
                "MSPCore",
                "MSPExternalRunner",
                "MSPGit",
                "MSPPOSIXCore",
                "MSPPtySupport",
                "MSPPythonEmbeddedRuntime",
                "MSPPythonRuntime",
                "MSPShell",
                "MSPShellExpansion",
                "MSPShellLanguage",
                "ModelShellProxy",
                "Tools/Vendor"
            ],
            sources: [
                "MSPAgentBridge/Capabilities",
                "MSPAgentBridge/Compaction",
                "MSPAgentBridge/JSON",
                "MSPAgentBridge/Model",
                "MSPAgentBridge/Model/ResponsesStreaming",
                "MSPAgentBridge/Rendering",
                "MSPAgentBridge/Request",
                "MSPAgentBridge/Runtime",
                "Tools/MSP/exec_command/Contract",
                "Tools/MSP/exec_command/Runtime",
                "Tools/MSP/apply_patch/Contract",
                "Tools/MSP/apply_patch/Runtime",
                "Tools/MSP/write_stdin/Contract",
                "Tools/MSP/write_stdin/Runtime",
                "Tools/MSP/update_plan/Contract",
                "Tools/MSP/update_plan/Runtime"
            ]
        ),
        .target(
            name: "MSPCodexApplyPatchRuntime",
            dependencies: [
                "MSPAgentBridge",
                .target(name: "MSPCodexApplyPatchBridge", condition: .when(platforms: [.iOS]))
            ],
            path: "Sources/MSPCodexApplyPatchRuntime"
        ),
        .binaryTarget(
            name: "MSPCodexApplyPatchBridge",
            path: "Sources/Tools/Vendor/Codex/apply_patch/Artifacts/MSPCodexApplyPatchBridge.xcframework"
        ),
        .target(
            name: "MSPPOSIXCore",
            dependencies: ["MSPCore"],
            path: "Sources/MSPPOSIXCore",
            sources: ["Commands", "Registry", "Support"]
        ),
        .target(
            name: "MSPPythonRuntime",
            dependencies: ["MSPCore"],
            path: "Sources/MSPPythonRuntime"
        ),
        .target(
            name: "MSPPythonEmbeddedRuntime",
            dependencies: ["MSPCore", "MSPPythonRuntime"],
            path: "Sources/MSPPythonEmbeddedRuntime",
            sources: ["CPython", "Runtime"]
        ),
        .target(
            name: "MSPApple",
            dependencies: ["MSPCore"],
            path: "Sources/MSPApple"
        ),
        .target(
            name: "MSPPtySupport",
            path: "Sources/MSPPtySupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MSPChat",
            path: "Sources/MSPChat",
            sources: [
                "MSPChat.swift",
                "MSPChatError.swift",
                "JSON/MSPChatJSONIO.swift",
                "JSON/MSPChatJSONValue.swift",
                "Manifest/MSPChatManifest.swift",
                "Package/MSPChatCoreReader.swift",
                "Package/MSPChatCoreWriter.swift",
                "Package/MSPChatPackage.swift",
                "Timeline/MSPChatTimelineEvent.swift",
                "Timeline/MSPChatTimelineRecords.swift",
                "MSPChatValidator.swift",
                "Validation"
            ]
        ),
        .target(
            name: "MSPAgentChatStore",
            dependencies: ["MSPChat", "MSPAgentBridge"],
            path: "Sources/MSPAgentChatStore"
        ),
        .target(
            name: "MSPChatCommands",
            dependencies: ["MSPCore", "MSPChat"],
            path: "Sources/MSPChatCommands"
        ),
        .executableTarget(
            name: "MSPChatValidatorCLI",
            dependencies: ["MSPChat"],
            path: "Sources/MSPChatValidatorCLI",
            sources: ["main.swift"]
        ),
        .target(
            name: "ModelShellProxy",
            dependencies: [
                "MSPCore",
                "MSPShell",
                "MSPCommandKit",
                "MSPExternalRunner",
                "MSPAgentBridge",
                "MSPPOSIXCore",
                "MSPApple",
                "MSPPtySupport"
            ],
            path: "Sources/ModelShellProxy"
        )
    ]
)
