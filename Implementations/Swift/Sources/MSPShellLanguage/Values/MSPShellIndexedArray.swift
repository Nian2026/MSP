import Foundation

public struct MSPShellIndexedArray: Sendable, Equatable {
    public package(set) var storage: [Int: String]

    public init(storage: [Int: String] = [:]) {
        self.storage = storage.filter { $0.key >= 0 }
    }

    public init(_ denseValues: [String]) {
        self.storage = Dictionary(uniqueKeysWithValues: denseValues.enumerated().map { index, value in
            (index, value)
        })
    }

    public var first: String? {
        storage[0]
    }

    public var count: Int {
        storage.count
    }

    public var valuesByIndex: [String] {
        indicesByIndex.compactMap { storage[$0] }
    }

    public var indicesByIndex: [Int] {
        storage.keys.sorted()
    }

    public var hasDenseZeroBasedIndices: Bool {
        indicesByIndex == Array(0..<storage.count)
    }

    public package(set) subscript(index: Int) -> String? {
        get {
            storage[index]
        }
        set {
            guard index >= 0 else {
                return
            }
            storage[index] = newValue
        }
    }

    package mutating func append(contentsOf values: [String]) {
        var index = (storage.keys.max() ?? -1) + 1
        for value in values {
            storage[index] = value
            index += 1
        }
    }

    package mutating func assign(_ value: String, at index: Int, appending: Bool = false) {
        guard index >= 0 else {
            return
        }
        if appending {
            storage[index] = (storage[index] ?? "") + value
        } else {
            storage[index] = value
        }
    }
}
