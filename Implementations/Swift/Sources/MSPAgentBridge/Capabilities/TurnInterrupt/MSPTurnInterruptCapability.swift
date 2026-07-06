import Foundation

public struct MSPTurnInterruptCapability: Hashable, Sendable {
    public static let defaultGracefulAbortTimeoutNanoseconds: UInt64 = 100_000_000

    public enum Mode: String, Hashable, Sendable {
        case enabled
        case disabled
    }

    public var mode: Mode
    public var supportsStartupInterrupt: Bool
    public var gracefulAbortTimeoutNanoseconds: UInt64

    public init(
        mode: Mode = .enabled,
        supportsStartupInterrupt: Bool = true,
        gracefulAbortTimeoutNanoseconds: UInt64 = Self.defaultGracefulAbortTimeoutNanoseconds
    ) {
        self.mode = mode
        self.supportsStartupInterrupt = supportsStartupInterrupt
        self.gracefulAbortTimeoutNanoseconds = gracefulAbortTimeoutNanoseconds
    }

    public static func enabled(
        supportsStartupInterrupt: Bool = true,
        gracefulAbortTimeoutNanoseconds: UInt64 = Self.defaultGracefulAbortTimeoutNanoseconds
    ) -> MSPTurnInterruptCapability {
        MSPTurnInterruptCapability(
            mode: .enabled,
            supportsStartupInterrupt: supportsStartupInterrupt,
            gracefulAbortTimeoutNanoseconds: gracefulAbortTimeoutNanoseconds
        )
    }

    public static let disabled = MSPTurnInterruptCapability(
        mode: .disabled,
        supportsStartupInterrupt: false,
        gracefulAbortTimeoutNanoseconds: 0
    )

    public var isEnabled: Bool {
        mode == .enabled
    }

    public var declaration: MSPTurnInterruptCapabilityDeclaration {
        MSPTurnInterruptCapabilityDeclaration(
            name: "turn_interrupt",
            enabled: isEnabled,
            methods: isEnabled ? ["turn/interrupt"] : [],
            supportsStartupInterrupt: isEnabled && supportsStartupInterrupt
        )
    }
}

public struct MSPTurnInterruptCapabilityDeclaration: Hashable, Sendable {
    public var name: String
    public var enabled: Bool
    public var methods: [String]
    public var supportsStartupInterrupt: Bool

    public init(
        name: String,
        enabled: Bool,
        methods: [String],
        supportsStartupInterrupt: Bool
    ) {
        self.name = name
        self.enabled = enabled
        self.methods = methods
        self.supportsStartupInterrupt = supportsStartupInterrupt
    }
}
