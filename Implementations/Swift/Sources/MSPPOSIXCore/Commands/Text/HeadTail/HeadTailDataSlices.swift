import Foundation

extension Data {
    func headTailPrefixData(_ count: Int) -> Data {
        Data(prefix(Swift.max(0, count)))
    }

    func headTailSuffixData(_ count: Int) -> Data {
        Data(suffix(Swift.max(0, count)))
    }
}
