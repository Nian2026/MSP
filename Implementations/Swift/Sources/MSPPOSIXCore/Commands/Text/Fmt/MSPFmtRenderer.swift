import Foundation

func mspFmtRender(data: Data, configuration: MSPFmtConfiguration) -> Data {
    let lines = mspFmtPhysicalLines(data)
    var output = Data()
    var index = 0
    var taggedOtherIndent = 0
    while index < lines.count {
        let line = lines[index]
        if line.isBlank {
            output.append(0x0a)
            index += 1
            continue
        }

        if let rawPrefix = configuration.prefix {
            let prefix = Array(rawPrefix.utf8)
            guard mspFmtLine(line, hasPrefix: prefix) else {
                output.append(contentsOf: line.bytes)
                output.append(0x0a)
                index += 1
                continue
            }
            var paragraph: [MSPFmtPhysicalLine] = [line]
            index += 1
            while index < lines.count, !lines[index].isBlank, mspFmtLine(lines[index], hasPrefix: prefix) {
                if configuration.splitOnly {
                    break
                }
                paragraph.append(lines[index])
                index += 1
            }
            output.append(mspFmtFormatPrefixParagraph(paragraph, prefix: prefix, configuration: configuration))
            continue
        }

        let paragraph: [MSPFmtPhysicalLine]
        if configuration.splitOnly {
            paragraph = [line]
            index += 1
        } else if configuration.crownMargin {
            var collected = [line]
            index += 1
            if index < lines.count, !lines[index].isBlank {
                let otherIndent = lines[index].indentColumns
                repeat {
                    collected.append(lines[index])
                    index += 1
                } while index < lines.count
                    && !lines[index].isBlank
                    && lines[index].indentColumns == otherIndent
            }
            paragraph = collected
        } else if configuration.taggedParagraph {
            var collected = [line]
            index += 1
            if index < lines.count,
               !lines[index].isBlank,
               lines[index].indentColumns != line.indentColumns {
                let otherIndent = lines[index].indentColumns
                repeat {
                    collected.append(lines[index])
                    index += 1
                } while index < lines.count
                    && !lines[index].isBlank
                    && lines[index].indentColumns == otherIndent
            }
            paragraph = collected
        } else {
            let indent = line.indentColumns
            var collected = [line]
            index += 1
            while index < lines.count, !lines[index].isBlank, lines[index].indentColumns == indent {
                collected.append(lines[index])
                index += 1
            }
            paragraph = collected
        }

        output.append(mspFmtFormatParagraph(
            paragraph,
            configuration: configuration,
            taggedOtherIndent: &taggedOtherIndent
        ))
    }
    return output
}

func mspFmtDefaultGoalWidth(_ width: Int) -> Int {
    width * 187 / 200
}

func mspFmtLine(_ line: MSPFmtPhysicalLine, hasPrefix prefix: [UInt8]) -> Bool {
    guard !prefix.isEmpty, line.firstTextIndex + prefix.count <= line.bytes.count else {
        return false
    }
    return Array(line.bytes[line.firstTextIndex..<(line.firstTextIndex + prefix.count)]) == prefix
}

func mspFmtFormatPrefixParagraph(
    _ lines: [MSPFmtPhysicalLine],
    prefix: [UInt8],
    configuration: MSPFmtConfiguration
) -> Data {
    var words: [MSPFmtWord] = []
    for line in lines {
        var start = line.firstTextIndex + prefix.count
        while start < line.bytes.count, line.bytes[start] == 0x20 || line.bytes[start] == 0x09 {
            start += 1
        }
        words.append(contentsOf: mspFmtWords(in: line.bytes, start: start, uniformSpacing: configuration.uniformSpacing))
    }
    return mspFmtFormatWords(
        words,
        firstIndent: prefix.count,
        otherIndent: prefix.count,
        linePrefix: prefix,
        configuration: configuration
    )
}

func mspFmtFormatParagraph(
    _ lines: [MSPFmtPhysicalLine],
    configuration: MSPFmtConfiguration,
    taggedOtherIndent: inout Int
) -> Data {
    guard let first = lines.first else {
        return Data()
    }
    let firstIndent = first.indentColumns
    let otherIndent: Int
    if configuration.splitOnly {
        otherIndent = firstIndent
    } else if configuration.crownMargin {
        otherIndent = lines.dropFirst().first?.indentColumns ?? firstIndent
    } else if configuration.taggedParagraph {
        if let second = lines.dropFirst().first, second.indentColumns != firstIndent {
            otherIndent = second.indentColumns
            taggedOtherIndent = otherIndent
        } else {
            if taggedOtherIndent == firstIndent {
                taggedOtherIndent = firstIndent == 0 ? 3 : 0
            }
            otherIndent = taggedOtherIndent
        }
    } else {
        otherIndent = firstIndent
    }

    var words: [MSPFmtWord] = []
    for line in lines {
        words.append(contentsOf: mspFmtWords(
            in: line.bytes,
            start: line.firstTextIndex,
            uniformSpacing: configuration.uniformSpacing
        ))
    }

    return mspFmtFormatWords(
        words,
        firstIndent: firstIndent,
        otherIndent: otherIndent,
        linePrefix: [],
        configuration: configuration
    )
}
