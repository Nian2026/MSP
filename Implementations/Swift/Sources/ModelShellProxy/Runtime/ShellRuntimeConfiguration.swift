import MSPCore
import MSPShell

struct ShellRuntimeConfiguration {
    var shell: MSPConfiguration
    var registry: MSPCommandRegistry
    var parser: MSPShellParser

    init(
        shell: MSPConfiguration,
        registry: MSPCommandRegistry,
        parser: MSPShellParser
    ) {
        self.shell = shell
        self.registry = registry
        self.parser = parser
    }
}
