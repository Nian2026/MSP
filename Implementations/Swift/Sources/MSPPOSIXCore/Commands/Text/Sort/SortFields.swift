import Foundation

func sortKeyField(
    in line: String,
    key: SortKey,
    ordering: SortEffectiveKeyOrdering,
    separator: String?
) -> String {
    let bytes = Array(line.utf8)
    let separatorByte = sortFieldSeparatorByte(separator)
    var start = sortKeyStart(in: bytes, key: key, ordering: ordering, separator: separatorByte)
    var end = sortKeyEnd(in: bytes, key: key, ordering: ordering, separator: separatorByte)
    if end < start {
        end = start
    }
    start = min(start, bytes.count)
    end = min(end, bytes.count)
    return String(decoding: bytes[start..<end], as: UTF8.self)
}

func sortKeyStart(
    in bytes: [UInt8],
    key: SortKey,
    ordering: SortEffectiveKeyOrdering,
    separator: UInt8?
) -> Int {
    var pointer = 0
    let limit = bytes.count
    if var fieldIndex = key.startFieldIndex {
        if let separator {
            while pointer < limit, fieldIndex > 0 {
                while pointer < limit, bytes[pointer] != separator {
                    pointer += 1
                }
                if pointer < limit {
                    pointer += 1
                }
                fieldIndex -= 1
            }
        } else {
            while pointer < limit, fieldIndex > 0 {
                while pointer < limit, isSortFieldBlank(bytes[pointer]) {
                    pointer += 1
                }
                while pointer < limit, !isSortFieldBlank(bytes[pointer]) {
                    pointer += 1
                }
                fieldIndex -= 1
            }
        }
    }
    if ordering.skipsStartBlanks {
        while pointer < limit, isSortFieldBlank(bytes[pointer]) {
            pointer += 1
        }
    }
    return min(limit, pointer + key.startCharacterOffset)
}

func sortKeyEnd(
    in bytes: [UInt8],
    key: SortKey,
    ordering: SortEffectiveKeyOrdering,
    separator: UInt8?
) -> Int {
    guard let endFieldIndex = key.endFieldIndex else {
        return bytes.count
    }

    var pointer = 0
    let limit = bytes.count
    var fieldsToPass = endFieldIndex
    if key.endCharacterCount == 0 {
        fieldsToPass += 1
    }

    if let separator {
        while pointer < limit, fieldsToPass > 0 {
            while pointer < limit, bytes[pointer] != separator {
                pointer += 1
            }
            fieldsToPass -= 1
            if pointer < limit, fieldsToPass > 0 || key.endCharacterCount != 0 {
                pointer += 1
            }
        }
    } else {
        while pointer < limit, fieldsToPass > 0 {
            while pointer < limit, isSortFieldBlank(bytes[pointer]) {
                pointer += 1
            }
            while pointer < limit, !isSortFieldBlank(bytes[pointer]) {
                pointer += 1
            }
            fieldsToPass -= 1
        }
    }

    if key.endCharacterCount != 0 {
        if ordering.skipsEndBlanks {
            while pointer < limit, isSortFieldBlank(bytes[pointer]) {
                pointer += 1
            }
        }
        pointer = min(limit, pointer + key.endCharacterCount)
    }
    return pointer
}

func sortFieldSeparatorByte(_ separator: String?) -> UInt8? {
    guard let separator else {
        return nil
    }
    return Array(separator.utf8).first
}

private func isSortFieldBlank(_ byte: UInt8) -> Bool {
    byte == 0x09 || byte == 0x0A || byte == 0x20
}
