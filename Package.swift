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
        .executable(name: "msp-chat-validate", targets: ["MSPChatValidatorCLI"]),
        .executable(name: "msp-request-parity-runner", targets: ["MSPRequestParityRunnerCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sharplet/swift-cgit2.git", exact: "1.1.1")
    ],
    targets: [
        .target(
            name: "MSPCore",
            path: "Implementations/Swift/Sources/MSPCore"
        ),
        .target(
            name: "MSPShellLanguage",
            path: "Implementations/Swift/Sources/MSPShellLanguage",
            sources: ["AST", "Conversion", "Lexer", "Parsed", "Parser", "Reconstruction", "Syntax", "Values"]
        ),
        .target(
            name: "MSPShellExpansion",
            dependencies: ["MSPShellLanguage"],
            path: "Implementations/Swift/Sources/MSPShellExpansion",
            sources: ["API", "Arithmetic", "Brace", "Effects", "FieldSplitting", "Parameters", "Pattern", "Words"]
        ),
        .target(
            name: "MSPShell",
            dependencies: ["MSPShellLanguage", "MSPShellExpansion"],
            path: "Implementations/Swift/Sources/MSPShell"
        ),
        .target(
            name: "MSPCommandKit",
            dependencies: ["MSPCore"],
            path: "Implementations/Swift/Sources/MSPCommandKit"
        ),
        .target(
            name: "MSPExternalRunner",
            dependencies: ["MSPCore"],
            path: "Implementations/Swift/Sources/MSPExternalRunner"
        ),
        .target(
            name: "MSPGit",
            dependencies: [
                "MSPCore",
                .product(name: "Cgit2", package: "swift-cgit2")
            ],
            path: "Implementations/Swift/Sources/MSPGit"
        ),
        .target(
            name: "MSPAgentBridge",
            dependencies: ["MSPCore"],
            path: "Implementations/Swift/Sources",
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
            path: "Implementations/Swift/Sources/MSPCodexApplyPatchRuntime"
        ),
        .binaryTarget(
            name: "MSPCodexApplyPatchBridge",
            path: "Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch/Artifacts/MSPCodexApplyPatchBridge.xcframework"
        ),
        .target(
            name: "MSPPOSIXCore",
            dependencies: ["MSPCore"],
            path: "Implementations/Swift/Sources/MSPPOSIXCore",
            sources: ["Commands", "Registry", "Support"]
        ),
        .target(
            name: "MSPPythonRuntime",
            dependencies: ["MSPCore"],
            path: "Implementations/Swift/Sources/MSPPythonRuntime"
        ),
        .target(
            name: "MSPPythonEmbeddedRuntime",
            dependencies: ["MSPCore", "MSPPythonRuntime"],
            path: "Implementations/Swift/Sources/MSPPythonEmbeddedRuntime",
            sources: ["CPython", "Runtime"]
        ),
        .target(
            name: "MSPApple",
            dependencies: ["MSPCore"],
            path: "Implementations/Swift/Sources/MSPApple"
        ),
        .target(
            name: "MSPPtySupport",
            path: "Implementations/Swift/Sources/MSPPtySupport",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MSPChat",
            path: "Implementations/Swift/Sources/MSPChat",
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
                "Validation/MSPChatArtifactBlobValidation.swift",
                "Validation/MSPChatCommandEventValidation.swift",
                "Validation/MSPChatConversationEventValidation.swift",
                "Validation/MSPChatJournalIndexValidation.swift",
                "Validation/MSPChatManifestValidation.swift",
                "Validation/MSPChatProjectionValidation.swift",
                "Validation/MSPChatTimelineValidation.swift",
                "Validation/MSPChatValidationDiagnostics.swift",
                "Validation/MSPChatValidationJSONReading.swift",
                "Validation/MSPChatValidationReport.swift",
                "Validation/MSPChatValidationRun.swift"
            ]
        ),
        .target(
            name: "MSPAgentChatStore",
            dependencies: ["MSPChat", "MSPAgentBridge"],
            path: "Implementations/Swift/Sources/MSPAgentChatStore"
        ),
        .target(
            name: "MSPChatCommands",
            dependencies: ["MSPCore", "MSPChat"],
            path: "Implementations/Swift/Sources/MSPChatCommands"
        ),
        .executableTarget(
            name: "MSPChatValidatorCLI",
            dependencies: ["MSPChat"],
            path: "Implementations/Swift/Sources/MSPChatValidatorCLI",
            sources: ["main.swift"]
        ),
        .executableTarget(
            name: "MSPRequestParityRunnerCLI",
            dependencies: ["ModelShellProxy"],
            path: "Tools/RequestParity/MSPRequestParityRunnerCLI",
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
            path: "Implementations/Swift/Sources/ModelShellProxy"
        ),
        .testTarget(
            name: "MSPCoreTests",
            dependencies: ["MSPCore"],
            path: "Tests/Swift/Unit/MSPCore"
        ),
        .testTarget(
            name: "MSPShellTests",
            dependencies: ["MSPShell"],
            path: "Tests/Swift/Unit/MSPShell"
        ),
        .testTarget(
            name: "MSPCommandKitTests",
            dependencies: ["MSPCommandKit", "MSPCore"],
            path: "Tests/Swift/Unit/MSPCommandKit"
        ),
        .testTarget(
            name: "MSPExternalRunnerTests",
            dependencies: ["MSPExternalRunner", "MSPCore"],
            path: "Tests/Swift/Unit/MSPExternalRunner"
        ),
        .testTarget(
            name: "MSPGitTests",
            dependencies: ["MSPGit", "MSPCore", "MSPApple"],
            path: "Tests/Swift/Unit/MSPGit"
        ),
        .testTarget(
            name: "MSPAgentBridgeTests",
            dependencies: ["MSPAgentBridge", "MSPCodexApplyPatchRuntime", "MSPCore"],
            path: "Tests/Swift/Unit/MSPAgentBridge"
        ),
        .testTarget(
            name: "MSPPOSIXCoreTests",
            dependencies: ["MSPPOSIXCore", "MSPCore", "MSPShell"],
            path: "Tests/Swift/Unit/MSPPOSIXCore",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "MSPPythonRuntimeTests",
            dependencies: ["MSPPythonRuntime", "ModelShellProxy", "MSPApple"],
            path: "Tests/Swift/Unit/MSPPythonRuntime"
        ),
        .testTarget(
            name: "MSPPythonEmbeddedRuntimeTests",
            dependencies: ["MSPPythonEmbeddedRuntime", "ModelShellProxy", "MSPApple"],
            path: "Tests/Swift/Unit/MSPPythonEmbeddedRuntime"
        ),
        .testTarget(
            name: "MSPAppleTests",
            dependencies: ["MSPApple", "MSPCore"],
            path: "Tests/Swift/Unit/MSPApple"
        ),
        .testTarget(
            name: "MSPChatTests",
            dependencies: ["MSPChat"],
            path: "Tests/Swift/Unit/MSPChat"
        ),
        .testTarget(
            name: "MSPChatCommandsTests",
            dependencies: ["MSPChatCommands", "MSPChat", "MSPCore"],
            path: "Tests/Swift/Unit/MSPChatCommands"
        ),
        .testTarget(
            name: "MSPAgentChatStoreTests",
            dependencies: ["MSPAgentChatStore", "MSPChat", "MSPAgentBridge"],
            path: "Tests/Swift/Unit/MSPAgentChatStore"
        ),
        .testTarget(
            name: "ModelShellProxyIntegrationTests",
            dependencies: ["ModelShellProxy", "MSPApple", "MSPPythonRuntime", "MSPPythonEmbeddedRuntime"],
            path: "Tests/Swift/Integration/ModelShellProxy",
            exclude: ["README.md", "Conformance/README.md"]
        )
    ]
)
