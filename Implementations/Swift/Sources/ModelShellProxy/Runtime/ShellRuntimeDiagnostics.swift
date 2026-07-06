enum MSPShellDiagnosticStyle {
    case bash
    case dash
}

struct MSPShellDiagnosticContext {
    var scriptName: String
    var style: MSPShellDiagnosticStyle
}
