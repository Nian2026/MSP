import Foundation

extension PhotoSorterMediaCommand {
    struct PhotoSorterMediaUsageError: Error {
        var message: String
    }

    struct PhotoSorterMediaListArguments {
        var scopePath = "/图库"
        var limit = PhotoSorterMediaCommand.defaultListLimit
        var offset = 0
        var sort: PhotoSorterMediaListSort = .created
        var order: PhotoSorterMediaListOrder = .desc
        var mediaType: PhotoSorterMediaType = .all
        var format: PhotoSorterMediaListFormat = .paths
    }

    struct PhotoSorterMediaShowArguments {
        var rawPaths: [String] = []
        var pathListFile: String?
        var limit: Int?
        var format: PhotoSorterMediaShowFormat = .text
    }

    struct PhotoSorterMediaPathListArguments {
        var rawPaths: [String] = []
        var pathListFile: String?
        var limit: Int?
    }

    struct PhotoSorterMediaAskArguments {
        var rawPaths: [String] = []
        var pathListFile: String?
        var jsonlFile: String?
        var limit: Int?
        var message: String?
        var writeSelectedPath: String?
        var writeExcludedPath: String?
        var writeSkippedPath: String?
    }

    struct PhotoSorterMediaStatsArguments {
        var scopePath = "/图库"
        var groupBy: PhotoSorterMediaStatsGroup = .month
        var dateField: PhotoSorterMediaStatsDateField = .created
        var mediaType: PhotoSorterMediaType = .all
        var format: PhotoSorterMediaStatsFormat = .tsv
    }

    enum PhotoSorterMediaListFormat: String {
        case paths
        case tsv
        case jsonl
    }

    enum PhotoSorterMediaShowFormat: String {
        case text
        case tsv
        case jsonl
    }

    enum PhotoSorterMediaStatsFormat: String {
        case tsv
        case jsonl
    }
}
