import Foundation

struct PhotoSorterMediaVLMSummaryCacheKey: Codable, Hashable, Sendable, Equatable {
    var localIdentifier: String
    var assetVersion: String
    var providerKind: String
    var modelID: String
    var modelVersion: String
    var processorConfigFingerprint: String
    var promptVersion: String
    var language: String
    var summarySchemaVersion: Int

    var storageKey: String {
        [
            localIdentifier,
            Self.canonicalAssetVersion(assetVersion),
            providerKind,
            modelID,
            modelVersion,
            processorConfigFingerprint,
            promptVersion,
            language,
            String(summarySchemaVersion)
        ]
        .map(Self.escapeStorageComponent)
        .joined(separator: "|")
    }

    static func canonicalAssetVersion(_ assetVersion: String) -> String {
        guard assetVersion.hasPrefix("modified:"),
              let stableSuffixRange = assetVersion.range(of: "|size:")
        else {
            return assetVersion
        }
        return String(assetVersion[stableSuffixRange.lowerBound...].dropFirst())
    }

    static func canonicalizedStorageKey(_ storageKey: String) -> String {
        var components = storageKey.components(separatedBy: "|")
        guard components.count == 9 else {
            return storageKey
        }
        let decodedAssetVersion = unescapeStorageComponent(components[1])
        components[1] = escapeStorageComponent(canonicalAssetVersion(decodedAssetVersion))
        return components.joined(separator: "|")
    }

    static func assetVersion(in storageKey: String) -> String? {
        let components = storageKey.components(separatedBy: "|")
        guard components.count == 9 else {
            return nil
        }
        return unescapeStorageComponent(components[1])
    }

    static func modificationDateRank(in storageKey: String) -> Double? {
        guard let assetVersion = assetVersion(in: storageKey) else {
            return nil
        }
        guard assetVersion.hasPrefix("modified:"),
              let separatorRange = assetVersion.range(of: "|size:")
        else {
            return nil
        }
        let valueStart = assetVersion.index(
            assetVersion.startIndex,
            offsetBy: "modified:".count
        )
        return Double(assetVersion[valueStart..<separatorRange.lowerBound])
    }

    private static func escapeStorageComponent(_ component: String) -> String {
        component
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "|", with: "%7C")
    }

    private static func unescapeStorageComponent(_ component: String) -> String {
        component
            .replacingOccurrences(of: "%7C", with: "|")
            .replacingOccurrences(of: "%25", with: "%")
    }
}

enum PhotoSorterMediaVLMConfiguration {
    static let providerKind = "bundled-local"
    static let backend = "bundled local model"
    static let modelID = "FastVLM-0.5B"
    static let modelVersion = "stage3"
    static let processorConfigFingerprintNotInstalled = "fastvlm-official-processor-config-not-installed"
    static let promptVersion = "vlm-summary-zh-v1"
    static let prompt = "用简体中文一到两句话描述这张图片的主要内容，总字数不超过50字。不要转写大段文字。"
    static let language = "zh-Hans"
    static let summarySchemaVersion = 1
    static let maximumSummaryCharacterCount = 50

    static let bundledModelResourcePath = "FastVLM/model"

    static var bundledFastVLMUnavailableProviderStatus: PhotoSorterMediaVLMProviderStatus {
        bundledFastVLMProviderStatus(
            modelBundle: PhotoSorterFastVLMModelBundle.notInstalled()
        )
    }

    static let systemUnavailableProviderStatus = PhotoSorterMediaVLMProviderStatus(
        kind: "system",
        backend: "Apple Intelligence",
        modelID: "system-visual-intelligence",
        modelVersion: "unavailable",
        modelState: .unavailable,
        isLiveSummarizationAvailable: false,
        processorConfigFingerprint: "system-provider-unavailable",
        reason: "Apple Intelligence is unavailable on this device"
    )

    static func bundledFastVLMProviderStatus(
        modelBundle: PhotoSorterFastVLMModelBundle
    ) -> PhotoSorterMediaVLMProviderStatus {
        if modelBundle.isInstalled {
            return PhotoSorterMediaVLMProviderStatus(
                kind: providerKind,
                backend: backend,
                modelID: modelID,
                modelVersion: modelVersion,
                modelState: .installed,
                isLiveSummarizationAvailable: false,
                processorConfigFingerprint: modelBundle.processorConfigFingerprint,
                reason: "local FastVLM model bundle is installed; live inference runtime is not wired yet"
            )
        }
        return PhotoSorterMediaVLMProviderStatus(
            kind: providerKind,
            backend: backend,
            modelID: modelID,
            modelVersion: modelVersion,
            modelState: .notInstalled,
            isLiveSummarizationAvailable: false,
            processorConfigFingerprint: modelBundle.processorConfigFingerprint,
            reason: modelBundle.reason ?? "local FastVLM model is not installed"
        )
    }

    static func cacheKey(
        localIdentifier: String,
        assetVersion: String,
        processorConfigFingerprint: String = processorConfigFingerprintNotInstalled
    ) -> PhotoSorterMediaVLMSummaryCacheKey {
        PhotoSorterMediaVLMSummaryCacheKey(
            localIdentifier: localIdentifier,
            assetVersion: assetVersion,
            providerKind: providerKind,
            modelID: modelID,
            modelVersion: modelVersion,
            processorConfigFingerprint: processorConfigFingerprint,
            promptVersion: promptVersion,
            language: language,
            summarySchemaVersion: summarySchemaVersion
        )
    }

    static func normalizedSummaryOutput(_ output: String) -> String {
        let collapsed = output
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else {
            return ""
        }

        let sentenceEnders: Set<Character> = ["。", "！", "？", ".", "!", "?"]
        var summary = ""
        var sentenceCount = 0
        var truncatedByLength = false
        for character in collapsed {
            guard summary.count < maximumSummaryCharacterCount else {
                truncatedByLength = true
                break
            }
            summary.append(character)
            if sentenceEnders.contains(character) {
                sentenceCount += 1
                if sentenceCount >= 2 {
                    break
                }
            }
        }
        summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard truncatedByLength, !summary.isEmpty else {
            return summary
        }
        guard summary.last.map({ !sentenceEnders.contains($0) }) ?? false else {
            return summary
        }

        summary = sentenceLikePrefix(from: summary, sentenceEnders: sentenceEnders)
        while summary.count >= maximumSummaryCharacterCount {
            summary.removeLast()
            summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return summary + "。"
    }

    private static func sentenceLikePrefix(
        from summary: String,
        sentenceEnders: Set<Character>
    ) -> String {
        let clauseBreaks: Set<Character> = ["，", "；", ";", ",", "、", "：", ":"]
        let minimumUsefulPrefixLength = 16
        if let breakIndex = summary.indices
            .dropFirst(minimumUsefulPrefixLength)
            .first(where: { clauseBreaks.contains(summary[$0]) || sentenceEnders.contains(summary[$0]) }) {
            let prefix = summary[..<breakIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                return String(prefix)
            }
        }
        return summary
    }
}

struct PhotoSorterFastVLMModelBundle: Sendable, Equatable {
    static let requiredConfigFileNames = [
        "config.json",
        "preprocessor_config.json",
        "processor_config.json",
        "tokenizer_config.json"
    ]

    var directoryPath: String
    var processorConfigFingerprint: String
    var missingRequiredConfigFileNames: [String]
    var modelComponentIssues: [String]
    var reason: String?

    var isInstalled: Bool {
        missingRequiredConfigFileNames.isEmpty && modelComponentIssues.isEmpty
    }

    static func notInstalled(reason: String? = "local FastVLM model is not installed") -> PhotoSorterFastVLMModelBundle {
        PhotoSorterFastVLMModelBundle(
            directoryPath: PhotoSorterMediaVLMConfiguration.bundledModelResourcePath,
            processorConfigFingerprint: PhotoSorterMediaVLMConfiguration.processorConfigFingerprintNotInstalled,
            missingRequiredConfigFileNames: requiredConfigFileNames,
            modelComponentIssues: ["missing *.safetensors", "missing exactly one *.mlpackage"],
            reason: reason
        )
    }

    static func discover(
        directoryURL explicitDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> PhotoSorterFastVLMModelBundle {
        guard let directoryURL = explicitDirectoryURL ?? bundledModelDirectoryURL() else {
            return notInstalled()
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return PhotoSorterFastVLMModelBundle(
                directoryPath: directoryURL.path,
                processorConfigFingerprint: PhotoSorterMediaVLMConfiguration.processorConfigFingerprintNotInstalled,
                missingRequiredConfigFileNames: requiredConfigFileNames,
                modelComponentIssues: ["missing *.safetensors", "missing exactly one *.mlpackage"],
                reason: "local FastVLM model is not installed at \(directoryURL.path)"
            )
        }

        let missing = requiredConfigFileNames.filter { fileName in
            !fileManager.fileExists(
                atPath: directoryURL.appendingPathComponent(fileName).path
            )
        }
        guard missing.isEmpty else {
            return PhotoSorterFastVLMModelBundle(
                directoryPath: directoryURL.path,
                processorConfigFingerprint: PhotoSorterMediaVLMConfiguration.processorConfigFingerprintNotInstalled,
                missingRequiredConfigFileNames: missing,
                modelComponentIssues: modelComponentIssues(
                    in: directoryURL,
                    fileManager: fileManager
                ),
                reason: "local FastVLM model bundle is incomplete; \(incompleteReason(missingConfigFileNames: missing, modelComponentIssues: modelComponentIssues(in: directoryURL, fileManager: fileManager)))"
            )
        }

        let componentIssues = modelComponentIssues(
            in: directoryURL,
            fileManager: fileManager
        )
        guard componentIssues.isEmpty else {
            return PhotoSorterFastVLMModelBundle(
                directoryPath: directoryURL.path,
                processorConfigFingerprint: PhotoSorterMediaVLMConfiguration.processorConfigFingerprintNotInstalled,
                missingRequiredConfigFileNames: [],
                modelComponentIssues: componentIssues,
                reason: "local FastVLM model bundle is incomplete; \(incompleteReason(missingConfigFileNames: [], modelComponentIssues: componentIssues))"
            )
        }

        return PhotoSorterFastVLMModelBundle(
            directoryPath: directoryURL.path,
            processorConfigFingerprint: fingerprint(
                fileNames: requiredConfigFileNames,
                in: directoryURL,
                fileManager: fileManager
            ),
            missingRequiredConfigFileNames: [],
            modelComponentIssues: [],
            reason: nil
        )
    }

    private static func bundledModelDirectoryURL() -> URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("FastVLM", isDirectory: true)
            .appendingPathComponent("model", isDirectory: true)
    }

    private static func fingerprint(
        fileNames: [String],
        in directoryURL: URL,
        fileManager: FileManager
    ) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func update(with byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        for fileName in fileNames.sorted() {
            for byte in fileName.utf8 {
                update(with: byte)
            }
            update(with: 0)
            let fileURL = directoryURL.appendingPathComponent(fileName)
            if let data = fileManager.contents(atPath: fileURL.path) {
                for byte in data {
                    update(with: byte)
                }
            }
            update(with: 0xff)
        }

        return String(format: "fastvlm-official-config-fnv1a64-%016llx", hash)
    }

    private static func modelComponentIssues(
        in directoryURL: URL,
        fileManager: FileManager
    ) -> [String] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let safetensors = contents.filter { url in
            url.pathExtension == "safetensors"
        }
        let mlpackages = contents.filter { url in
            url.pathExtension == "mlpackage"
        }

        var issues: [String] = []
        if safetensors.isEmpty {
            issues.append("missing *.safetensors")
        }
        if mlpackages.count != 1 {
            if mlpackages.isEmpty {
                issues.append("missing exactly one *.mlpackage")
            } else {
                issues.append("expected exactly one *.mlpackage, found \(mlpackages.count)")
            }
        }
        return issues
    }

    private static func incompleteReason(
        missingConfigFileNames: [String],
        modelComponentIssues: [String]
    ) -> String {
        var parts: [String] = []
        if !missingConfigFileNames.isEmpty {
            parts.append("missing \(missingConfigFileNames.joined(separator: ", "))")
        }
        parts.append(contentsOf: modelComponentIssues)
        return parts.joined(separator: "; ")
    }
}
