import Foundation

extension ModelShellProxyCore100OracleConformanceTests {
    static let commandGroups: [String: Set<String>] = [
        "a": ["export", "unset", "set", "umask"],
        "shell-state": ["export", "unset", "set", "umask"],
        "b": ["read", "source", "alias", "unalias"],
        "shell-input-source-alias": ["read", "source", "alias", "unalias"],
        "c": ["rmdir", "unlink", "truncate", "install", "tree"],
        "filesystem": ["rmdir", "unlink", "truncate", "install", "tree"],
        "d": ["dd", "split", "shuf", "tsort"],
        "byte-stream": ["dd", "split", "shuf", "tsort"],
        "e": ["expr", "strings", "fold", "expand", "unexpand", "fmt"],
        "text-layout": ["expr", "strings", "fold", "expand", "unexpand", "fmt"],
        "f": ["uname", "whoami", "id", "hostname", "sleep", "base32", "basenc", "sha512sum", "b2sum"],
        "identity-encoding-time": ["uname", "whoami", "id", "hostname", "sleep", "base32", "basenc", "sha512sum", "b2sum"],
        "stress": [],
        "shell-stress": []
    ]

    static func selectedCases(from cases: [Core100OracleCase]) -> [Core100OracleCase] {
        let environment = ProcessInfo.processInfo.environment
        var selected = cases
        if let categoryList = environment["MSP_CORE100_ORACLE_CATEGORIES"], !categoryList.isEmpty {
            let categories = commaSeparatedSet(categoryList)
            selected = selected.filter { categories.contains($0.category) }
        }
        if let excludedCategoryList = environment["MSP_CORE100_ORACLE_EXCLUDE_CATEGORIES"],
           !excludedCategoryList.isEmpty {
            let excludedCategories = commaSeparatedSet(excludedCategoryList)
            selected = selected.filter { !excludedCategories.contains($0.category) }
        }
        if let groupList = environment["MSP_CORE100_ORACLE_GROUPS"], !groupList.isEmpty {
            let groups = commaSeparatedSet(groupList).map { $0.lowercased() }
            selected = selected.filter { testCase in
                groups.contains { groupName in
                    guard let groupCommands = commandGroups[groupName] else {
                        return false
                    }
                    if groupName == "stress" || groupName == "shell-stress" {
                        return testCase.category == "core100-shell-stress"
                    }
                    return !groupCommands.isDisjoint(with: Set(testCase.commands))
                }
            }
        }
        if let commandList = environment["MSP_CORE100_ORACLE_COMMANDS"], !commandList.isEmpty {
            let commands = commaSeparatedSet(commandList)
            selected = selected.filter { !commands.isDisjoint(with: Set($0.commands)) }
        }
        if let excludedCommandList = environment["MSP_CORE100_ORACLE_EXCLUDE_COMMANDS"],
           !excludedCommandList.isEmpty {
            let excludedCommands = commaSeparatedSet(excludedCommandList)
            selected = selected.filter { excludedCommands.isDisjoint(with: Set($0.commands)) }
        }
        if let caseList = environment["MSP_CORE100_ORACLE_CASES"], !caseList.isEmpty {
            let ids = commaSeparatedSet(caseList)
            selected = selected.filter { ids.contains($0.id) }
        } else if let singleCase = environment["MSP_CORE100_ORACLE_CASE"], !singleCase.isEmpty {
            selected = selected.filter { $0.id == singleCase }
        }
        if let limitText = environment["MSP_CORE100_ORACLE_LIMIT"],
           let limit = Int(limitText),
           limit >= 0 {
            selected = Array(selected.prefix(limit))
        }
        return selected
    }

    private static func commaSeparatedSet(_ value: String) -> Set<String> {
        Set(value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
    }
}
