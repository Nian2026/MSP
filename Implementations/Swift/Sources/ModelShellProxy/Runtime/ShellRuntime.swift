import MSPCore
import MSPShell

final class ShellRuntime {
    var configuration: MSPConfiguration
    var state = ShellRuntimeMutableState()
    var io = IORuntimeState()
    var processSubstitutionLifetime = ProcessSubstitutionLifetime()
    let registry: MSPCommandRegistry
    let parser: MSPShellParser

    init(configuration: ShellRuntimeConfiguration) {
        self.configuration = configuration.shell
        self.registry = configuration.registry
        self.parser = configuration.parser
        self.state.seedExportedVariables(from: configuration.shell.environment)
    }
}
