import Foundation

struct FindNumericPredicateValue: Equatable {
    var relation: FindPredicateRelation
    var count: Int64

    func matches(observed: Int64) -> Bool {
        switch relation {
        case .equal:
            return observed == count
        case .greaterThan:
            return observed > count
        case .lessThan:
            return observed < count
        }
    }
}

enum FindPredicateRelation: Equatable {
    case equal
    case greaterThan
    case lessThan
}

struct FindSizeComparison: Equatable {
    var value: FindNumericPredicateValue
    var unit: FindSizeUnit

    func matches(byteCount: Int64) -> Bool {
        value.matches(observed: unit.count(forByteCount: byteCount))
    }
}

enum FindSizeUnit: Equatable {
    case blocks
    case bytes
    case kibibytes
    case mebibytes
    case gibibytes

    var multiplier: Int64 {
        switch self {
        case .blocks:
            return 512
        case .bytes:
            return 1
        case .kibibytes:
            return 1024
        case .mebibytes:
            return 1024 * 1024
        case .gibibytes:
            return 1024 * 1024 * 1024
        }
    }

    func count(forByteCount byteCount: Int64) -> Int64 {
        guard self != .bytes else {
            return byteCount
        }
        guard byteCount > 0 else {
            return 0
        }
        return (byteCount + multiplier - 1) / multiplier
    }
}

struct FindTimeComparison: Equatable {
    var value: FindNumericPredicateValue
    var unit: FindTimeUnit

    func matches(modifiedAt: Date, now: Date = Date()) -> Bool {
        value.matches(observed: unit.elapsedCount(since: modifiedAt, now: now))
    }
}

enum FindTimeUnit: Equatable {
    case days
    case minutes

    func elapsedCount(since date: Date, now: Date = Date()) -> Int64 {
        let elapsed = max(0, now.timeIntervalSince(date))
        switch self {
        case .days:
            return Int64(elapsed / (24 * 60 * 60))
        case .minutes:
            return Int64(elapsed / 60)
        }
    }
}

struct FindPermissionPredicate: Equatable {
    var mode: UInt16
    var match: FindPermissionMatch

    func matches(mode observedMode: UInt16) -> Bool {
        let observed = observedMode & 0o7777
        let expected = mode & 0o7777
        switch match {
        case .exact:
            return observed == expected
        case .all:
            return (observed & expected) == expected
        case .any:
            return (observed & expected) != 0
        }
    }
}

enum FindPermissionMatch: Equatable {
    case exact
    case all
    case any
}
