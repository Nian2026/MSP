import Foundation

struct TrScalarProcessor {
    private var sourceSet: MSPPOSIXScalarSetExpression
    private var targetSet: MSPPOSIXScalarSetExpression?
    private var complement: Bool
    private var delete: Bool
    private var squeezeSet: MSPPOSIXScalarSetExpression?
    private var squeezeComplement: Bool
    private var translation: [UnicodeScalar: UnicodeScalar]
    private var previousOutputScalar: UnicodeScalar?

    init(configuration: MSPTrConfiguration) {
        self.init(
            sourceSet: configuration.sourceSet,
            targetSet: configuration.targetSet,
            complement: configuration.complement,
            delete: configuration.delete,
            squeezeSet: configuration.squeezeSet,
            squeezeComplement: configuration.squeezeComplement,
            truncateSet1: configuration.truncateSet1
        )
    }

    init(
        sourceSet: MSPPOSIXScalarSetExpression,
        targetSet: MSPPOSIXScalarSetExpression?,
        complement: Bool,
        delete: Bool,
        squeezeSet: MSPPOSIXScalarSetExpression?,
        squeezeComplement: Bool,
        truncateSet1: Bool
    ) {
        self.sourceSet = sourceSet
        self.targetSet = targetSet
        self.complement = complement
        self.delete = delete
        self.squeezeSet = squeezeSet
        self.squeezeComplement = squeezeComplement
        var translation: [UnicodeScalar: UnicodeScalar] = [:]
        if !complement, let targetSet {
            let sourceScalars = truncateSet1
                ? Array(sourceSet.scalars.prefix(targetSet.scalars.count))
                : sourceSet.scalars
            for (offset, source) in sourceScalars.enumerated() {
                let targetIndex = min(offset, max(targetSet.scalars.count - 1, 0))
                if targetSet.scalars.indices.contains(targetIndex) {
                    translation[source] = targetSet.scalars[targetIndex]
                }
            }
        }
        self.translation = translation
    }

    mutating func process(_ input: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            guard let transformed = transform(scalar) else {
                continue
            }
            if let squeezeSet,
               transformed == previousOutputScalar,
               squeezeSet.contains(transformed, complement: squeezeComplement) {
                continue
            }
            output.append(transformed)
            previousOutputScalar = transformed
        }
        return String(output)
    }

    private func transform(_ scalar: UnicodeScalar) -> UnicodeScalar? {
        if delete {
            return sourceSet.contains(scalar, complement: complement) ? nil : scalar
        }
        if complement,
           sourceSet.contains(scalar, complement: true),
           let replacement = targetSet?.scalars.last {
            return replacement
        }
        return translation[scalar] ?? scalar
    }
}
