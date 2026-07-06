import Foundation

enum PhotoSorterPlaceCacheTaskMode: String, Sendable, Equatable {
    case idle
    case running
    case paused
}

enum PhotoSorterPlaceCacheTaskStore {
    private static let key = "photosorter.photoLibrary.placeCache.taskMode"

    static func load(defaults: UserDefaults = .standard) -> PhotoSorterPlaceCacheTaskMode {
        guard let rawValue = defaults.string(forKey: key),
              let mode = PhotoSorterPlaceCacheTaskMode(rawValue: rawValue)
        else {
            return .idle
        }
        return mode
    }

    static func save(_ mode: PhotoSorterPlaceCacheTaskMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: key)
    }
}
