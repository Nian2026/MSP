import Foundation
import MSPShellLanguage

public struct MSPShellExpansionContext: Sendable, Equatable {
    public var environment: [String: String]
    public var arrays: [String: MSPShellIndexedArray]
    public var associativeArrays: [String: [String: String]]
    public var namerefVariables: [String: String]
    public var specialParameters: [String: String]
    public var positionalParameters: [String]
    public var currentDirectory: String
    public var pathnameCandidates: [String]
    public var enablesPathnameExpansion: Bool
    public var enablesWordSplitting: Bool
    public var treatsUnsetParametersAsErrors: Bool
    public var enablesNullGlob: Bool
    public var enablesFailGlob: Bool
    public var enablesDotGlob: Bool
    public var enablesNoCaseGlob: Bool
    public var enablesExtendedGlob: Bool
    public var enablesGlobStar: Bool
    public var ifs: String
    public var enablesBashParameterExtensions: Bool
    public var enablesBraceExpansion: Bool

    public init(
        environment: [String: String] = [:],
        arrays: [String: MSPShellIndexedArray] = [:],
        associativeArrays: [String: [String: String]] = [:],
        namerefVariables: [String: String] = [:],
        specialParameters: [String: String] = [:],
        positionalParameters: [String] = [],
        currentDirectory: String = "/",
        pathnameCandidates: [String] = [],
        enablesPathnameExpansion: Bool = true,
        enablesWordSplitting: Bool = true,
        treatsUnsetParametersAsErrors: Bool = false,
        enablesNullGlob: Bool = false,
        enablesFailGlob: Bool = false,
        enablesDotGlob: Bool = false,
        enablesNoCaseGlob: Bool = false,
        enablesExtendedGlob: Bool = false,
        enablesGlobStar: Bool = false,
        ifs: String = " \t\n",
        enablesBashParameterExtensions: Bool = true,
        enablesBraceExpansion: Bool = true
    ) {
        self.environment = environment
        self.arrays = arrays
        self.associativeArrays = associativeArrays
        self.namerefVariables = namerefVariables
        self.specialParameters = specialParameters
        self.positionalParameters = positionalParameters
        self.currentDirectory = currentDirectory
        self.pathnameCandidates = pathnameCandidates
        self.enablesPathnameExpansion = enablesPathnameExpansion
        self.enablesWordSplitting = enablesWordSplitting
        self.treatsUnsetParametersAsErrors = treatsUnsetParametersAsErrors
        self.enablesNullGlob = enablesNullGlob
        self.enablesFailGlob = enablesFailGlob
        self.enablesDotGlob = enablesDotGlob
        self.enablesNoCaseGlob = enablesNoCaseGlob
        self.enablesExtendedGlob = enablesExtendedGlob
        self.enablesGlobStar = enablesGlobStar
        self.ifs = ifs
        self.enablesBashParameterExtensions = enablesBashParameterExtensions
        self.enablesBraceExpansion = enablesBraceExpansion
    }
}
