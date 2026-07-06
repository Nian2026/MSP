import Foundation

public struct MSPCommandRuntimeStateChange: Sendable, Equatable {
    public var currentDirectory: String?

    public init(currentDirectory: String? = nil) {
        self.currentDirectory = currentDirectory
    }
}

public struct MSPCommandModelContentItem: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case inputText = "input_text"
        case inputImage = "input_image"
    }

    public var kind: Kind
    public var text: String?
    public var data: Data?
    public var mimeType: String?
    public var detail: String?

    public init(
        kind: Kind,
        text: String? = nil,
        data: Data? = nil,
        mimeType: String? = nil,
        detail: String? = nil
    ) {
        self.kind = kind
        self.text = text
        self.data = data
        self.mimeType = mimeType
        self.detail = detail
    }

    public static func inputText(_ text: String) -> MSPCommandModelContentItem {
        MSPCommandModelContentItem(kind: .inputText, text: text)
    }

    public static func inputImage(
        data: Data,
        mimeType: String,
        detail: String = "auto"
    ) -> MSPCommandModelContentItem {
        MSPCommandModelContentItem(
            kind: .inputImage,
            data: data,
            mimeType: mimeType,
            detail: detail
        )
    }
}

public struct MSPCommandResult: Sendable, Equatable {
    public var stdoutData: Data
    public var stderrData: Data
    public var exitCode: Int32
    public var stateChange: MSPCommandRuntimeStateChange?
    public var modelContentItems: [MSPCommandModelContentItem]

    public var stdout: String {
        get { String(decoding: stdoutData, as: UTF8.self) }
        set { stdoutData = Data(newValue.utf8) }
    }

    public var stderr: String {
        get { String(decoding: stderrData, as: UTF8.self) }
        set { stderrData = Data(newValue.utf8) }
    }

    public init(
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        stateChange: MSPCommandRuntimeStateChange? = nil,
        modelContentItems: [MSPCommandModelContentItem] = []
    ) {
        self.stdoutData = Data(stdout.utf8)
        self.stderrData = Data(stderr.utf8)
        self.exitCode = exitCode
        self.stateChange = stateChange
        self.modelContentItems = modelContentItems
    }

    public init(
        stdoutData: Data,
        stderrData: Data = Data(),
        exitCode: Int32 = 0,
        stateChange: MSPCommandRuntimeStateChange? = nil,
        modelContentItems: [MSPCommandModelContentItem] = []
    ) {
        self.stdoutData = stdoutData
        self.stderrData = stderrData
        self.exitCode = exitCode
        self.stateChange = stateChange
        self.modelContentItems = modelContentItems
    }

    public init(
        stdoutData: Data,
        stderr: String,
        exitCode: Int32 = 0,
        stateChange: MSPCommandRuntimeStateChange? = nil,
        modelContentItems: [MSPCommandModelContentItem] = []
    ) {
        self.stdoutData = stdoutData
        self.stderrData = Data(stderr.utf8)
        self.exitCode = exitCode
        self.stateChange = stateChange
        self.modelContentItems = modelContentItems
    }

    public var succeeded: Bool {
        exitCode == 0
    }

    public static func success(
        stdout: String = "",
        stderr: String = "",
        stateChange: MSPCommandRuntimeStateChange? = nil,
        modelContentItems: [MSPCommandModelContentItem] = []
    ) -> MSPCommandResult {
        MSPCommandResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: 0,
            stateChange: stateChange,
            modelContentItems: modelContentItems
        )
    }

    public static func success(
        stdoutData: Data,
        stderr: String = "",
        stateChange: MSPCommandRuntimeStateChange? = nil,
        modelContentItems: [MSPCommandModelContentItem] = []
    ) -> MSPCommandResult {
        MSPCommandResult(
            stdoutData: stdoutData,
            stderr: stderr,
            exitCode: 0,
            stateChange: stateChange,
            modelContentItems: modelContentItems
        )
    }

    public static func failure(
        exitCode: Int32 = 1,
        stdout: String = "",
        stderr: String,
        stateChange: MSPCommandRuntimeStateChange? = nil,
        modelContentItems: [MSPCommandModelContentItem] = []
    ) -> MSPCommandResult {
        MSPCommandResult(
            stdout: stdout,
            stderr: stderr,
            exitCode: exitCode,
            stateChange: stateChange,
            modelContentItems: modelContentItems
        )
    }

    public static func failure(
        exitCode: Int32 = 1,
        stdoutData: Data,
        stderr: String,
        stateChange: MSPCommandRuntimeStateChange? = nil,
        modelContentItems: [MSPCommandModelContentItem] = []
    ) -> MSPCommandResult {
        MSPCommandResult(
            stdoutData: stdoutData,
            stderr: stderr,
            exitCode: exitCode,
            stateChange: stateChange,
            modelContentItems: modelContentItems
        )
    }
}
