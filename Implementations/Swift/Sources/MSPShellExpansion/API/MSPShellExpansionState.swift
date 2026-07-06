import Foundation
import MSPShellLanguage

public struct MSPShellExpansionState: Sendable, Equatable {
    public var environment: [String: String]
    public var arrays: [String: MSPShellIndexedArray]
    public var associativeArrays: [String: [String: String]]

    public init(
        environment: [String: String] = [:],
        arrays: [String: MSPShellIndexedArray] = [:],
        associativeArrays: [String: [String: String]] = [:]
    ) {
        self.environment = environment
        self.arrays = arrays
        self.associativeArrays = associativeArrays
    }
}

extension MSPShellExpansionState {
    init(context: MSPShellExpansionContext) {
        self.init(
            environment: context.environment,
            arrays: context.arrays,
            associativeArrays: context.associativeArrays
        )
    }
}

extension MSPShellExpansionContext {
    var expansionState: MSPShellExpansionState {
        get {
            MSPShellExpansionState(context: self)
        }
        set {
            environment = newValue.environment
            arrays = newValue.arrays
            associativeArrays = newValue.associativeArrays
        }
    }
}
