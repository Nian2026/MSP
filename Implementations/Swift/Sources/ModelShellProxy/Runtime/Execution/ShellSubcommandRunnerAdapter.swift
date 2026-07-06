import MSPCore

extension ModelShellProxy {
    func makeSubcommandRunner() -> MSPSubcommandRunner {
        let registry = registry
        return { invocation, context in
            var resolvedInvocation = invocation
            var resolvedExplicitVirtualExecutablePath = false
            if let resolvedCommandName = ShellVirtualExecutableCommandPath.commandName(
                for: invocation.name,
                registryCommandNames: registry.commandNames,
                commandLookupPaths: context.commandLookupPaths
            ) {
                resolvedExplicitVirtualExecutablePath = invocation.name.contains("/")
                resolvedInvocation.name = resolvedCommandName
            }
            let availableCommandNames = Array(Set(context.availableCommandNames).union(registry.commandNames))
            guard ShellVirtualExecutableCommandPath.commandCanRunWithPathSearch(
                commandName: resolvedInvocation.name,
                resolvedExplicitVirtualExecutablePath: resolvedExplicitVirtualExecutablePath,
                availableCommandNames: availableCommandNames,
                commandLookupPaths: context.commandLookupPaths,
                environmentPath: context.environment["PATH"]
            ) else {
                return .failure(exitCode: 127, stderr: "\(resolvedInvocation.name): command not found\n")
            }
            let policyRequest = MSPPolicyRequest(
                commandName: resolvedInvocation.name,
                arguments: resolvedInvocation.arguments,
                currentDirectory: context.currentDirectory
            )
            switch await context.policyEngine.evaluate(policyRequest) {
            case .allow:
                if !registry.commandNames.contains(resolvedInvocation.name),
                   context.availableCommandNames.contains(resolvedInvocation.name),
                   let commandLineRunner = context.commandLineRunner {
                    var childContext = context
                    childContext.standardInput = context.standardInput
                    childContext.standardInputClosed = context.standardInputClosed
                    return await commandLineRunner(resolvedInvocation.rawInput, childContext)
                }
                return await MSPCommandExecutor(registry: registry)
                    .run(invocation: resolvedInvocation, context: context)
            case .deny(let reason):
                return .failure(exitCode: 126, stderr: "\(resolvedInvocation.name): \(reason)\n")
            case .requiresConfirmation(let prompt):
                return .failure(exitCode: 126, stderr: "\(resolvedInvocation.name): confirmation required: \(prompt)\n")
            }
        }
    }
}
