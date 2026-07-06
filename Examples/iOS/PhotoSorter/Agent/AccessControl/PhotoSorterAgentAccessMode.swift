import Foundation

enum PhotoSorterAgentAccessMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard = "default"
    case full = "full"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            return "默认访问"
        case .full:
            return "完全访问"
        }
    }

    var subtitle: String {
        switch self {
        case .standard:
            return "模型只能看到路径、文件名、尺寸和创建时间"
        case .full:
            return "允许模型读取 OCR、地点、人脸等高价值信息"
        }
    }

    var systemImageName: String {
        switch self {
        case .standard:
            return "hand.raised"
        case .full:
            return "exclamationmark.shield"
        }
    }

    var environmentNotes: [String] {
        switch self {
        case .standard:
            return [
                "Photos access mode: default.",
                "In default access mode, `media show <path>` only exposes cheap metadata: path, pixel size, creation time, and OCR cache status.",
                "Do not assume OCR text, location, people, scene labels, original image pixels, or video frames are available in default access mode."
            ]
        case .full:
            return [
                "Photos access mode: full.",
                "In full access mode, PhotoSorter may expose richer Photos metadata through media commands when those capabilities are available.",
                "`media show <path>` may include `OCR: true/false`; this means whether OCR text is cached, not whether the image contains text.",
                "For large cache-backed filtering, prefer `media search --ocr` or `media search --vlm`; use `media show` to inspect `OCR: true/false` only when cache state itself is needed.",
                "For direct live OCR reads, cap uncached input paths to 20 per command-tool call before invoking `media show --ocr`.",
                "Use `media view <path> [path ...]` only when image pixels are necessary. It accepts one or more image paths, returns at most the first 20 per call, and returns model-visible images resized for model use while keeping the short side at least 1080px when source pixels are available.",
                "Original image pixels and video frames remain sensitive reads and may still require explicit user approval."
            ]
        }
    }
}

enum PhotoSorterAgentAccessModeStore {
    private static let key = "photosorter.agentAccess.mode"

    static func load(defaults: UserDefaults = .standard) -> PhotoSorterAgentAccessMode {
        guard let rawValue = defaults.string(forKey: key),
              let mode = PhotoSorterAgentAccessMode(rawValue: rawValue)
        else {
            return .standard
        }
        return mode
    }

    static func save(_ mode: PhotoSorterAgentAccessMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
    }
}

protocol PhotoSorterAgentAccessModeProviding: Sendable {
    func currentAgentAccessMode() -> PhotoSorterAgentAccessMode
}

final class PhotoSorterAgentAccessModeState: PhotoSorterAgentAccessModeProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedMode: PhotoSorterAgentAccessMode

    init(_ mode: PhotoSorterAgentAccessMode = .standard) {
        self.storedMode = mode
    }

    func currentAgentAccessMode() -> PhotoSorterAgentAccessMode {
        lock.lock()
        defer { lock.unlock() }
        return storedMode
    }

    func update(_ mode: PhotoSorterAgentAccessMode) {
        lock.lock()
        storedMode = mode
        lock.unlock()
    }
}

enum PhotoSorterSensitiveReadPolicy: String, CaseIterable, Codable, Identifiable, Sendable {
    case askEveryTime = "ask_every_time"
    case alwaysAllow = "always_allow"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .askEveryTime:
            return "每次询问"
        case .alwaysAllow:
            return "始终允许"
        }
    }

    var subtitle: String {
        switch self {
        case .askEveryTime:
            return "模型查看原图或视频帧前需要你确认"
        case .alwaysAllow:
            return "模型查看原图或视频帧时不再弹窗"
        }
    }

    var systemImageName: String {
        switch self {
        case .askEveryTime:
            return "questionmark.shield"
        case .alwaysAllow:
            return "checkmark.shield"
        }
    }

    var environmentNotes: [String] {
        switch self {
        case .askEveryTime:
            return [
                "Sensitive media read policy: ask every time.",
                "Original image pixels and video frames are sensitive reads. Execute `media view` when pixels are needed; the app will pause the tool call and show the user a real approval picker. Do not ask the user to type an authorization sentence."
            ]
        case .alwaysAllow:
            return [
                "Sensitive media read policy: always allow.",
                "Original image pixels and video frames are still sensitive reads, but the user has chosen not to show an approval prompt for each read."
            ]
        }
    }
}

enum PhotoSorterSensitiveReadPolicyStore {
    private static let key = "photosorter.agentAccess.sensitiveReadPolicy"

    static func load(defaults: UserDefaults = .standard) -> PhotoSorterSensitiveReadPolicy {
        guard let rawValue = defaults.string(forKey: key),
              let policy = PhotoSorterSensitiveReadPolicy(rawValue: rawValue)
        else {
            return .askEveryTime
        }
        return policy
    }

    static func save(_ policy: PhotoSorterSensitiveReadPolicy, defaults: UserDefaults = .standard) {
        defaults.set(policy.rawValue, forKey: key)
    }
}

protocol PhotoSorterSensitiveReadPolicyProviding: Sendable {
    func currentSensitiveReadPolicy() -> PhotoSorterSensitiveReadPolicy
}

final class PhotoSorterSensitiveReadPolicyState: PhotoSorterSensitiveReadPolicyProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPolicy: PhotoSorterSensitiveReadPolicy

    init(_ policy: PhotoSorterSensitiveReadPolicy = .askEveryTime) {
        self.storedPolicy = policy
    }

    func currentSensitiveReadPolicy() -> PhotoSorterSensitiveReadPolicy {
        lock.lock()
        defer { lock.unlock() }
        return storedPolicy
    }

    func update(_ policy: PhotoSorterSensitiveReadPolicy) {
        lock.lock()
        storedPolicy = policy
        lock.unlock()
    }
}
