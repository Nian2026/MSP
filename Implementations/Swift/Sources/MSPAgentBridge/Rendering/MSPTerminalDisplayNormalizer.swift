import Foundation

public enum MSPTerminalDisplayNormalizer {
    public static func normalize(_ text: String) -> String {
        let input = Array(text.unicodeScalars)
        guard input.contains(where: isTerminalEditingScalar) else {
            return text
        }

        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(input.count)
        var cursor = 0
        var index = 0
        while index < input.count {
            let scalar = input[index]
            switch scalar.value {
            case 0x08, 0x7f:
                cursor = max(currentLineStart(in: scalars, cursor: cursor), cursor - 1)
            case 0x0d:
                if index + 1 < input.count,
                   input[index + 1] == "\n" {
                    appendNewline(to: &scalars, cursor: &cursor)
                    index += 1
                } else {
                    cursor = currentLineStart(in: scalars, cursor: cursor)
                }
            case 0x0a:
                appendNewline(to: &scalars, cursor: &cursor)
            default:
                write(scalar, to: &scalars, cursor: &cursor)
            }
            index += 1
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func isTerminalEditingScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x08 || scalar.value == 0x7f || scalar.value == 0x0d
    }

    private static func write(
        _ scalar: Unicode.Scalar,
        to scalars: inout [Unicode.Scalar],
        cursor: inout Int
    ) {
        let lineEnd = currentLineEnd(in: scalars, cursor: cursor)
        if cursor < lineEnd {
            scalars[cursor] = scalar
        } else {
            scalars.insert(scalar, at: cursor)
        }
        cursor += 1
    }

    private static func appendNewline(
        to scalars: inout [Unicode.Scalar],
        cursor: inout Int
    ) {
        let lineEnd = currentLineEnd(in: scalars, cursor: cursor)
        if lineEnd < scalars.count,
           scalars[lineEnd] == "\n" {
            cursor = lineEnd + 1
            return
        }
        scalars.insert("\n", at: lineEnd)
        cursor = lineEnd + 1
    }

    private static func currentLineStart(
        in scalars: [Unicode.Scalar],
        cursor: Int
    ) -> Int {
        var index = min(max(cursor, 0), scalars.count)
        while index > 0 {
            let previousIndex = index - 1
            if scalars[previousIndex] == "\n" {
                return index
            }
            index = previousIndex
        }
        return 0
    }

    private static func currentLineEnd(
        in scalars: [Unicode.Scalar],
        cursor: Int
    ) -> Int {
        var index = min(max(cursor, 0), scalars.count)
        while index < scalars.count,
              scalars[index] != "\n" {
            index += 1
        }
        return index
    }
}
