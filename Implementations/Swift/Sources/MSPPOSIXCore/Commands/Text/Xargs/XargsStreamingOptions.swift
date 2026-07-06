import Foundation

struct MSPXargsStreamingOptions {
    var commandWords: [String] = ["echo"]
    var delimiter: Character?
    var nullDelimited = false
    var replacement: String?
    var maxArgs: Int?
    var maxLines: Int?
    var maxCharacters = 128 * 1024
    var noRunIfEmpty = false
    var verbose = false
    var argFile: String?
    var eofMarker: String?
    var clearsChildStandardInput = true
}
