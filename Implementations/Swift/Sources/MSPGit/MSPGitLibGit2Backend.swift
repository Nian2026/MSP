import Cgit2
import Foundation
import MSPCore

public actor MSPGitLibGit2Backend: MSPGitBackend {
    private let authorName: String
    private let authorEmail: String
    private let signatureTime: Int
    private let signatureOffsetMinutes: Int

    public init(
        authorName: String = "MSP Git",
        authorEmail: String = "msp-git@example.invalid",
        signatureTime: Int = 1_700_000_000,
        signatureOffsetMinutes: Int = 0
    ) {
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.signatureTime = signatureTime
        self.signatureOffsetMinutes = signatureOffsetMinutes
        git_libgit2_init()
    }

    deinit {
        git_libgit2_shutdown()
    }

    public func run(
        _ request: MSPGitCommandRequest,
        context: MSPCommandContext
    ) async throws -> MSPCommandResult {
        guard let mapping = request.workspaceMapping else {
            return .failure(exitCode: 128, stderr: "fatal: not a git repository (or any of the parent directories): .git\n")
        }
        let parsed = MSPGitParsedArguments(request.arguments)
        let result: MSPCommandResult
        switch parsed.subcommand {
        case "init":
            result = runInit(mapping: mapping)
        case "status":
            result = runStatus(parsed, request: request, mapping: mapping)
        case "add":
            result = runAdd(parsed, request: request, mapping: mapping)
        case "diff":
            result = runDiff(parsed, request: request, mapping: mapping)
        case "commit":
            result = runCommit(parsed, mapping: mapping)
        case "log":
            result = runLog(parsed, mapping: mapping)
        case "ls-files":
            result = runLsFiles(mapping: mapping)
        case "rev-parse":
            result = runRevParse(parsed, request: request, mapping: mapping)
        case "show":
            result = runShow(parsed, mapping: mapping)
        case let subcommand?:
            result = .failure(
                exitCode: 129,
                stderr: "git: unsupported git subcommand for iOS libgit2 backend: \(subcommand)\n"
            )
        case nil:
            result = .failure(exitCode: 129, stderr: "usage: git <command> [<args>]\n")
        }
        return mapping.sanitize(result)
    }

    private func runInit(mapping: MSPGitWorkspaceMapping) -> MSPCommandResult {
        let wasRepository = FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: mapping.physicalRootPath)
                .appendingPathComponent(".git", isDirectory: true)
                .path
        )
        var repository: OpaquePointer?
        let code = git_repository_init(&repository, mapping.physicalRootPath, 0)
        guard code == 0, let repository else {
            return gitFailure(exitCode: 128, fallback: "fatal: could not initialize repository\n")
        }
        defer { git_repository_free(repository) }
        _ = git_repository_set_head(repository, "refs/heads/main")
        let verb = wasRepository ? "Reinitialized existing" : "Initialized empty"
        return .success(stdout: "\(verb) Git repository in /.git/\n")
    }

    private func runStatus(
        _ parsed: MSPGitParsedArguments,
        request: MSPGitCommandRequest,
        mapping: MSPGitWorkspaceMapping
    ) -> MSPCommandResult {
        guard parsed.positionals.isEmpty || parsed.positionals.first == "status" else {
            return unsupportedOption("status")
        }
        guard let repository = openRepository(mapping: mapping) else {
            return notARepository()
        }
        defer { git_repository_free(repository) }
        let pathspecs = parsed.pathspecsAfterDoubleDash.isEmpty
            ? parsed.subcommandArguments.filter { !$0.hasPrefix("-") }
            : parsed.pathspecsAfterDoubleDash
        do {
            let entries = try loadIndexEntries(repository: repository)
            let headTree = lookupHeadTree(repository: repository)
            defer { if let headTree { git_tree_free(headTree) } }
            let statuses = try renderShortStatus(
                repository: repository,
                mapping: mapping,
                request: request,
                indexEntries: entries,
                headTree: headTree,
                pathspecs: pathspecs
            )
            return .success(stdout: statuses)
        } catch {
            return .failure(exitCode: 128, stderr: "fatal: \(error)\n")
        }
    }

    private func runAdd(
        _ parsed: MSPGitParsedArguments,
        request: MSPGitCommandRequest,
        mapping: MSPGitWorkspaceMapping
    ) -> MSPCommandResult {
        guard let repository = openRepository(mapping: mapping) else {
            return notARepository()
        }
        defer { git_repository_free(repository) }
        let paths = parsed.pathspecsAfterDoubleDash.isEmpty
            ? parsed.subcommandArguments.filter { !$0.hasPrefix("-") }
            : parsed.pathspecsAfterDoubleDash
        guard !paths.isEmpty else {
            return .failure(exitCode: 129, stderr: "Nothing specified, nothing added.\n")
        }
        var index: OpaquePointer?
        guard git_repository_index(&index, repository) == 0, let index else {
            return gitFailure(exitCode: 128, fallback: "fatal: could not read index\n")
        }
        defer { git_index_free(index) }

        for rawPath in paths {
            let virtualPath = MSPWorkspacePathResolver.normalize(rawPath, from: request.currentDirectory)
            let physicalPath = mapping.physicalPath(
                forVirtualPath: virtualPath,
                from: request.currentDirectory
            )
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: physicalPath, isDirectory: &isDirectory) else {
                return .failure(
                    exitCode: 128,
                    stderr: "fatal: pathspec '\(rawPath)' did not match any files\n"
                )
            }
            let relativePaths: [String]
            if isDirectory.boolValue {
                relativePaths = regularFilesUnder(physicalPath: physicalPath, mapping: mapping)
            } else {
                relativePaths = [relativePath(forVirtualPath: virtualPath)]
            }
            for relativePath in relativePaths {
                guard git_index_add_bypath(index, relativePath) == 0 else {
                    return gitFailure(exitCode: 128, fallback: "fatal: could not add \(rawPath)\n")
                }
            }
        }
        guard git_index_write(index) == 0 else {
            return gitFailure(exitCode: 128, fallback: "fatal: could not write index\n")
        }
        return .success()
    }

    private func runDiff(
        _ parsed: MSPGitParsedArguments,
        request: MSPGitCommandRequest,
        mapping: MSPGitWorkspaceMapping
    ) -> MSPCommandResult {
        guard let repository = openRepository(mapping: mapping) else {
            return notARepository()
        }
        defer { git_repository_free(repository) }
        let cached = parsed.subcommandArguments.contains("--cached")
        let pathspecs = parsed.pathspecsAfterDoubleDash.map {
            relativePath(forVirtualPath: MSPWorkspacePathResolver.normalize($0, from: request.currentDirectory))
        }
        guard let diff = cached
            ? makeCachedDiff(repository: repository, pathspecs: pathspecs)
            : makeWorktreeDiff(repository: repository, pathspecs: pathspecs)
        else {
            return gitFailure(exitCode: 128, fallback: "fatal: could not produce diff\n")
        }
        defer { git_diff_free(diff) }
        return .success(stdoutData: printDiff(diff))
    }

    private func runCommit(
        _ parsed: MSPGitParsedArguments,
        mapping: MSPGitWorkspaceMapping
    ) -> MSPCommandResult {
        guard let repository = openRepository(mapping: mapping) else {
            return notARepository()
        }
        defer { git_repository_free(repository) }
        guard let message = parsed.value(after: "-m") ?? parsed.value(after: "--message") else {
            return .failure(exitCode: 129, stderr: "error: switch `m' requires a value\n")
        }
        var index: OpaquePointer?
        guard git_repository_index(&index, repository) == 0, let index else {
            return gitFailure(exitCode: 128, fallback: "fatal: could not read index\n")
        }
        defer { git_index_free(index) }
        guard git_index_write(index) == 0 else {
            return gitFailure(exitCode: 128, fallback: "fatal: could not write index\n")
        }
        var treeOID = git_oid()
        guard git_index_write_tree(&treeOID, index) == 0 else {
            return gitFailure(exitCode: 128, fallback: "fatal: could not write tree\n")
        }
        var tree: OpaquePointer?
        guard withUnsafePointer(to: &treeOID, { git_tree_lookup(&tree, repository, $0) }) == 0,
              let tree else {
            return gitFailure(exitCode: 128, fallback: "fatal: could not read tree\n")
        }
        defer { git_tree_free(tree) }

        let parentCommit = lookupHeadCommit(repository: repository)
        defer { if let parentCommit { git_commit_free(parentCommit) } }
        let parentTree = parentCommit.flatMap { commit -> OpaquePointer? in
            var tree: OpaquePointer?
            return git_commit_tree(&tree, commit) == 0 ? tree : nil
        }
        defer { if let parentTree { git_tree_free(parentTree) } }
        let summary = makeDiffSummary(repository: repository, oldTree: parentTree, newTree: tree)

        var signature: UnsafeMutablePointer<git_signature>?
        guard git_signature_new(
            &signature,
            authorName,
            authorEmail,
            git_time_t(signatureTime),
            Int32(signatureOffsetMinutes)
        ) == 0, let signature else {
            return gitFailure(exitCode: 128, fallback: "fatal: could not create signature\n")
        }
        defer { git_signature_free(signature) }
        var commitOID = git_oid()
        let commitCode: Int32
        if let parentCommit {
            var parents: [OpaquePointer?] = [parentCommit]
            commitCode = parents.withUnsafeMutableBufferPointer { buffer in
                git_commit_create(
                    &commitOID,
                    repository,
                    "HEAD",
                    signature,
                    signature,
                    nil,
                    message,
                    tree,
                    1,
                    buffer.baseAddress
                )
            }
        } else {
            commitCode = git_commit_create(
                &commitOID,
                repository,
                "HEAD",
                signature,
                signature,
                nil,
                message,
                tree,
                0,
                nil
            )
        }
        guard commitCode == 0 else {
            return gitFailure(exitCode: 128, fallback: "fatal: could not create commit\n")
        }
        let rootLabel = parentCommit == nil ? " (root-commit)" : ""
        var stdout = "[main\(rootLabel) \(shortOID(commitOID))] \(firstLine(message))\n"
        stdout += summary.commitSummaryText()
        return .success(stdout: stdout)
    }

    private func runLog(
        _ parsed: MSPGitParsedArguments,
        mapping: MSPGitWorkspaceMapping
    ) -> MSPCommandResult {
        guard let repository = openRepository(mapping: mapping) else {
            return notARepository()
        }
        defer { git_repository_free(repository) }
        let maxCount = parsed.subcommandArguments.compactMap { argument -> Int? in
            guard argument.hasPrefix("--max-count=") else { return nil }
            return Int(argument.dropFirst("--max-count=".count))
        }.first
        var walk: OpaquePointer?
        guard git_revwalk_new(&walk, repository) == 0, let walk else {
            return gitFailure(exitCode: 128, fallback: "fatal: could not create revwalk\n")
        }
        defer { git_revwalk_free(walk) }
        git_revwalk_sorting(walk, UInt32(GIT_SORT_TIME.rawValue))
        guard git_revwalk_push_head(walk) == 0 else {
            return gitFailure(exitCode: 128, fallback: "fatal: your current branch 'main' does not have any commits yet\n")
        }
        var stdout = ""
        var count = 0
        while maxCount == nil || count < maxCount! {
            var oid = git_oid()
            guard git_revwalk_next(&oid, walk) == 0 else {
                break
            }
            var commit: OpaquePointer?
            guard withUnsafePointer(to: &oid, { git_commit_lookup(&commit, repository, $0) }) == 0,
                  let commit else {
                break
            }
            stdout += "\(shortOID(oid)) \(commitSummary(commit))\n"
            git_commit_free(commit)
            count += 1
        }
        return .success(stdout: stdout)
    }

    private func runLsFiles(mapping: MSPGitWorkspaceMapping) -> MSPCommandResult {
        guard let repository = openRepository(mapping: mapping) else {
            return notARepository()
        }
        defer { git_repository_free(repository) }
        do {
            let entries = try loadIndexEntries(repository: repository)
            return .success(stdout: entries.map(\.path).sorted().joined(separator: "\n") + (entries.isEmpty ? "" : "\n"))
        } catch {
            return .failure(exitCode: 128, stderr: "fatal: \(error)\n")
        }
    }

    private func runRevParse(
        _ parsed: MSPGitParsedArguments,
        request: MSPGitCommandRequest,
        mapping: MSPGitWorkspaceMapping
    ) -> MSPCommandResult {
        guard let repository = openRepository(mapping: mapping) else {
            return notARepository()
        }
        git_repository_free(repository)
        var outputs: [String] = []
        for argument in parsed.subcommandArguments {
            switch argument {
            case "--show-toplevel":
                outputs.append(mapping.virtualRootPath)
            case "--is-inside-work-tree":
                outputs.append("true")
            case "--git-dir":
                outputs.append(".git")
            case "--show-prefix":
                let normalized = MSPWorkspacePathResolver.normalize(request.currentDirectory)
                let relative = relativePath(forVirtualPath: normalized)
                outputs.append(relative.isEmpty ? "" : relative + "/")
            default:
                if argument.hasPrefix("-") {
                    return .failure(exitCode: 129, stderr: "git rev-parse: unsupported option for iOS libgit2 backend\n")
                }
            }
        }
        return .success(stdout: outputs.joined(separator: "\n") + (outputs.isEmpty ? "" : "\n"))
    }

    private func runShow(
        _ parsed: MSPGitParsedArguments,
        mapping: MSPGitWorkspaceMapping
    ) -> MSPCommandResult {
        guard let repository = openRepository(mapping: mapping) else {
            return notARepository()
        }
        defer { git_repository_free(repository) }
        let revision = parsed.subcommandArguments.last(where: { !$0.hasPrefix("-") }) ?? "HEAD"
        var object: OpaquePointer?
        guard git_revparse_single(&object, repository, revision) == 0, let object else {
            return gitFailure(exitCode: 128, fallback: "fatal: ambiguous argument '\(revision)': unknown revision or path not in the working tree.\n")
        }
        defer { git_object_free(object) }
        guard git_object_type(object).rawValue == GIT_OBJECT_COMMIT.rawValue else {
            return .failure(exitCode: 128, stderr: "fatal: \(revision) is not a commit\n")
        }
        let commit = object
        var tree: OpaquePointer?
        guard git_commit_tree(&tree, commit) == 0, let tree else {
            return gitFailure(exitCode: 128, fallback: "fatal: could not read commit tree\n")
        }
        defer { git_tree_free(tree) }
        var parentTree: OpaquePointer?
        if git_commit_parentcount(commit) > 0 {
            var parent: OpaquePointer?
            if git_commit_parent(&parent, commit, 0) == 0, let parent {
                parentTree = {
                    var tree: OpaquePointer?
                    return git_commit_tree(&tree, parent) == 0 ? tree : nil
                }()
                git_commit_free(parent)
            }
        }
        defer { if let parentTree { git_tree_free(parentTree) } }
        let oid = git_commit_id(commit).pointee
        var stdout = "\(shortOID(oid)) \(commitSummary(commit))\n"
        stdout += makeDiffSummary(
            repository: repository,
            oldTree: parentTree,
            newTree: tree
        ).showStatText()
        return .success(stdout: stdout)
    }

    private func renderShortStatus(
        repository: OpaquePointer,
        mapping: MSPGitWorkspaceMapping,
        request: MSPGitCommandRequest,
        indexEntries: [MSPGitIndexEntry],
        headTree: OpaquePointer?,
        pathspecs: [String]
    ) throws -> String {
        var lines: [String] = []
        for entry in indexEntries.sorted(by: { $0.path < $1.path }) where matchesPathspec(entry.path, pathspecs, request: request) {
            let headOID = headTree.flatMap { treeEntryOID(path: entry.path, tree: $0) }
            let indexStatus: Character
            if let headOID {
                indexStatus = oidEquals(entry.oid, headOID) ? " " : "M"
            } else {
                indexStatus = "A"
            }
            let physicalPath = URL(fileURLWithPath: mapping.physicalRootPath)
                .appendingPathComponent(entry.path)
                .path
            let worktreeStatus: Character
            if !FileManager.default.fileExists(atPath: physicalPath) {
                worktreeStatus = "D"
            } else if let worktreeOID = hashFile(path: physicalPath) {
                worktreeStatus = oidEquals(entry.oid, worktreeOID) ? " " : "M"
            } else {
                worktreeStatus = " "
            }
            if indexStatus != " " || worktreeStatus != " " {
                lines.append("\(indexStatus)\(worktreeStatus) \(quoteStatusPath(entry.path))")
            }
        }

        let tracked = Set(indexEntries.map(\.path))
        let untracked = untrackedStatusPaths(
            mapping: mapping,
            tracked: tracked,
            pathspecs: pathspecs,
            request: request
        )
        for path in untracked {
            lines.append("?? \(quoteStatusPath(path))")
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    private func untrackedStatusPaths(
        mapping: MSPGitWorkspaceMapping,
        tracked: Set<String>,
        pathspecs: [String],
        request: MSPGitCommandRequest
    ) -> [String] {
        let allFiles = regularFilesUnder(physicalPath: mapping.physicalRootPath, mapping: mapping)
            .filter { !tracked.contains($0) }
            .filter { matchesPathspec($0, pathspecs, request: request) }
        if !pathspecs.isEmpty {
            return allFiles.sorted()
        }
        var collapsed = Set<String>()
        for file in allFiles {
            let components = file.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if components.count > 1 {
                collapsed.insert(components[0] + "/")
            } else {
                collapsed.insert(file)
            }
        }
        return collapsed.sorted()
    }

    private func makeCachedDiff(repository: OpaquePointer, pathspecs: [String]) -> OpaquePointer? {
        var index: OpaquePointer?
        guard git_repository_index(&index, repository) == 0, let index else {
            return nil
        }
        defer { git_index_free(index) }
        let headTree = lookupHeadTree(repository: repository)
        defer { if let headTree { git_tree_free(headTree) } }
        return withDiffOptions(pathspecs: pathspecs) { options in
            var diff: OpaquePointer?
            let code = git_diff_tree_to_index(&diff, repository, headTree, index, options)
            return code == 0 ? diff : nil
        }
    }

    private func makeWorktreeDiff(repository: OpaquePointer, pathspecs: [String]) -> OpaquePointer? {
        var index: OpaquePointer?
        guard git_repository_index(&index, repository) == 0, let index else {
            return nil
        }
        defer { git_index_free(index) }
        return withDiffOptions(pathspecs: pathspecs) { options in
            var diff: OpaquePointer?
            let code = git_diff_index_to_workdir(&diff, repository, index, options)
            return code == 0 ? diff : nil
        }
    }

    private func makeTreeDiff(
        repository: OpaquePointer,
        oldTree: OpaquePointer?,
        newTree: OpaquePointer?
    ) -> OpaquePointer? {
        var diff: OpaquePointer?
        let code = git_diff_tree_to_tree(&diff, repository, oldTree, newTree, nil)
        return code == 0 ? diff : nil
    }

    private func makeDiffSummary(
        repository: OpaquePointer,
        oldTree: OpaquePointer?,
        newTree: OpaquePointer?
    ) -> MSPGitDiffSummary {
        guard let diff = makeTreeDiff(repository: repository, oldTree: oldTree, newTree: newTree) else {
            return MSPGitDiffSummary(files: [])
        }
        defer { git_diff_free(diff) }
        return MSPGitDiffSummary(diffText: String(decoding: printDiff(diff), as: UTF8.self))
    }

    private func printDiff(_ diff: OpaquePointer) -> Data {
        let buffer = MSPGitDiffBuffer()
        let opaque = Unmanaged.passUnretained(buffer).toOpaque()
        git_diff_print(diff, GIT_DIFF_FORMAT_PATCH, mspGitDiffPrintCallback, opaque)
        return buffer.data as Data
    }

    private func withDiffOptions<T>(
        pathspecs: [String],
        _ body: (UnsafeMutablePointer<git_diff_options>?) -> T
    ) -> T {
        var options = git_diff_options()
        git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
        guard !pathspecs.isEmpty else {
            return body(&options)
        }
        let cStrings = pathspecs.map { strdup($0) }
        defer {
            for cString in cStrings {
                free(cString)
            }
        }
        var mutableStrings = cStrings
        return mutableStrings.withUnsafeMutableBufferPointer { buffer in
            options.pathspec = git_strarray(strings: buffer.baseAddress, count: buffer.count)
            return body(&options)
        }
    }

    private func openRepository(mapping: MSPGitWorkspaceMapping) -> OpaquePointer? {
        var repository: OpaquePointer?
        let code = git_repository_open(&repository, mapping.physicalRootPath)
        return code == 0 ? repository : nil
    }

    private func lookupHeadCommit(repository: OpaquePointer) -> OpaquePointer? {
        var commit: OpaquePointer?
        return git_revparse_single(&commit, repository, "HEAD^{commit}") == 0 ? commit : nil
    }

    private func lookupHeadTree(repository: OpaquePointer) -> OpaquePointer? {
        var object: OpaquePointer?
        guard git_revparse_single(&object, repository, "HEAD^{tree}") == 0, let object else {
            return nil
        }
        git_object_free(object)
        guard let commit = lookupHeadCommit(repository: repository) else {
            return nil
        }
        defer { git_commit_free(commit) }
        var tree: OpaquePointer?
        return git_commit_tree(&tree, commit) == 0 ? tree : nil
    }

    private func loadIndexEntries(repository: OpaquePointer) throws -> [MSPGitIndexEntry] {
        var index: OpaquePointer?
        guard git_repository_index(&index, repository) == 0, let index else {
            throw MSPGitLibGit2Error.indexUnavailable
        }
        defer { git_index_free(index) }
        let count = git_index_entrycount(index)
        var entries: [MSPGitIndexEntry] = []
        entries.reserveCapacity(count)
        for offset in 0..<count {
            guard let pointer = git_index_get_byindex(index, offset),
                  let pathPointer = pointer.pointee.path else {
                continue
            }
            entries.append(MSPGitIndexEntry(
                path: String(cString: pathPointer),
                oid: pointer.pointee.id
            ))
        }
        return entries
    }

    private func treeEntryOID(path: String, tree: OpaquePointer) -> git_oid? {
        var entry: OpaquePointer?
        guard git_tree_entry_bypath(&entry, tree, path) == 0, let entry else {
            return nil
        }
        defer { git_tree_entry_free(entry) }
        guard let oid = git_tree_entry_id(entry) else {
            return nil
        }
        return oid.pointee
    }

    private func hashFile(path: String) -> git_oid? {
        var oid = git_oid()
        return git_odb_hashfile(&oid, path, GIT_OBJECT_BLOB) == 0 ? oid : nil
    }

    private func regularFilesUnder(
        physicalPath: String,
        mapping: MSPGitWorkspaceMapping
    ) -> [String] {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: physicalPath, isDirectory: &isDirectory) else {
            return []
        }
        if !isDirectory.boolValue {
            return mapping.virtualPath(forPhysicalPath: physicalPath)
                .map(relativePath(forVirtualPath:))
                .map { [$0] } ?? []
        }
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: physicalPath, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var paths: [String] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            guard values?.isRegularFile == true,
                  let virtualPath = mapping.virtualPath(forPhysicalPath: url.path) else {
                continue
            }
            paths.append(relativePath(forVirtualPath: virtualPath))
        }
        return paths.sorted()
    }

    private func relativePath(forVirtualPath virtualPath: String) -> String {
        MSPWorkspacePathResolver.components(in: MSPWorkspacePathResolver.normalize(virtualPath))
            .joined(separator: "/")
    }

    private func matchesPathspec(
        _ relativePath: String,
        _ pathspecs: [String],
        request: MSPGitCommandRequest
    ) -> Bool {
        guard !pathspecs.isEmpty else {
            return true
        }
        for pathspec in pathspecs {
            let relativeSpec = self.relativePath(
                forVirtualPath: MSPWorkspacePathResolver.normalize(pathspec, from: request.currentDirectory)
            )
            if relativePath == relativeSpec || relativePath.hasPrefix(relativeSpec + "/") {
                return true
            }
        }
        return false
    }

    private func quoteStatusPath(_ path: String) -> String {
        guard path.contains(" ") || path.contains("\t") || path.contains("\"") else {
            return path
        }
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func oidEquals(_ lhs: git_oid, _ rhs: git_oid) -> Bool {
        var lhs = lhs
        var rhs = rhs
        return withUnsafePointer(to: &lhs) { lhsPointer in
            withUnsafePointer(to: &rhs) { rhsPointer in
                git_oid_cmp(lhsPointer, rhsPointer) == 0
            }
        }
    }

    private func shortOID(_ oid: git_oid) -> String {
        var oid = oid
        return withUnsafePointer(to: &oid) { pointer in
            var buffer = [CChar](repeating: 0, count: 8)
            git_oid_tostr(&buffer, buffer.count, pointer)
            return String(cString: buffer)
        }
    }

    private func commitSummary(_ commit: OpaquePointer) -> String {
        guard let summary = git_commit_summary(commit) else {
            return ""
        }
        return String(cString: summary)
    }

    private func firstLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? text
    }

    private func notARepository() -> MSPCommandResult {
        .failure(exitCode: 128, stderr: "fatal: not a git repository (or any of the parent directories): .git\n")
    }

    private func unsupportedOption(_ command: String) -> MSPCommandResult {
        .failure(exitCode: 129, stderr: "git \(command): unsupported option for iOS libgit2 backend\n")
    }

    private func gitFailure(exitCode: Int32, fallback: String) -> MSPCommandResult {
        guard let error = git_error_last(), let message = error.pointee.message else {
            return .failure(exitCode: exitCode, stderr: fallback)
        }
        return .failure(exitCode: exitCode, stderr: "fatal: \(String(cString: message))\n")
    }
}

private struct MSPGitParsedArguments {
    var rawArguments: [String]
    var subcommand: String?
    var subcommandIndex: Int?
    var pathspecsAfterDoubleDash: [String]

    init(_ arguments: [String]) {
        rawArguments = arguments
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                break
            }
            if argument == "-C" || argument == "-c" || argument == "--git-dir" || argument == "--work-tree" {
                index += 2
                continue
            }
            if argument.hasPrefix("--git-dir=") || argument.hasPrefix("--work-tree=") {
                index += 1
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            subcommand = argument
            subcommandIndex = index
            break
        }
        if let doubleDash = arguments.firstIndex(of: "--") {
            pathspecsAfterDoubleDash = Array(arguments[arguments.index(after: doubleDash)...])
        } else {
            pathspecsAfterDoubleDash = []
        }
    }

    var subcommandArguments: [String] {
        guard let subcommandIndex else {
            return []
        }
        return Array(rawArguments.dropFirst(subcommandIndex + 1))
    }

    var positionals: [String] {
        rawArguments.filter { !$0.hasPrefix("-") }
    }

    func value(after option: String) -> String? {
        let inlinePrefix = option + "="
        if let inline = subcommandArguments.first(where: { $0.hasPrefix(inlinePrefix) }) {
            return String(inline.dropFirst(inlinePrefix.count))
        }
        guard let index = subcommandArguments.firstIndex(of: option) else {
            return nil
        }
        let valueIndex = subcommandArguments.index(after: index)
        guard subcommandArguments.indices.contains(valueIndex) else {
            return nil
        }
        return subcommandArguments[valueIndex]
    }
}

private enum MSPGitLibGit2Error: Error {
    case indexUnavailable
}

private struct MSPGitIndexEntry {
    var path: String
    var oid: git_oid
}

private final class MSPGitDiffBuffer {
    let data = NSMutableData()
}

private func mspGitDiffPrintCallback(
    _ delta: UnsafePointer<git_diff_delta>?,
    _ hunk: UnsafePointer<git_diff_hunk>?,
    _ line: UnsafePointer<git_diff_line>?,
    _ payload: UnsafeMutableRawPointer?
) -> Int32 {
    guard let line,
          let payload,
          let content = line.pointee.content,
          line.pointee.content_len > 0 else {
        return 0
    }
    let buffer = Unmanaged<MSPGitDiffBuffer>.fromOpaque(payload).takeUnretainedValue()
    if line.pointee.origin == Int8(UInt8(ascii: "+"))
        || line.pointee.origin == Int8(UInt8(ascii: "-"))
        || line.pointee.origin == Int8(UInt8(ascii: " ")) {
        var origin = line.pointee.origin
        buffer.data.append(&origin, length: 1)
    }
    buffer.data.append(content, length: Int(line.pointee.content_len))
    return 0
}

private struct MSPGitDiffSummary {
    var files: [File]

    init(files: [File]) {
        self.files = files
    }

    init(diffText: String) {
        var files: [File] = []
        var current: File?
        for line in diffText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                if let current {
                    files.append(current)
                }
                current = File(path: Self.newPath(fromDiffHeader: line))
                continue
            }
            guard current != nil else {
                continue
            }
            if line.hasPrefix("new file mode ") {
                current?.isNew = true
                current?.mode = String(line.dropFirst("new file mode ".count))
            } else if line.hasPrefix("+"), !line.hasPrefix("+++") {
                current?.insertions += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                current?.deletions += 1
            }
        }
        if let current {
            files.append(current)
        }
        self.files = files
    }

    private static func newPath(fromDiffHeader line: String) -> String {
        let payload = String(line.dropFirst("diff --git ".count))
        let rawToken: String
        if let quotedRange = payload.range(of: "\"b/", options: .backwards) {
            rawToken = String(payload[quotedRange.lowerBound...])
        } else if let bRange = payload.range(of: " b/", options: .backwards) {
            rawToken = String(payload[payload.index(after: bRange.lowerBound)...])
        } else {
            rawToken = payload
                .split(separator: " ")
                .last
                .map(String.init) ?? ""
        }

        let decoded = decodeGitPathToken(rawToken)
        return decoded.replacingOccurrences(of: "b/", with: "", options: [.anchored])
    }

    private static func decodeGitPathToken(_ token: String) -> String {
        var token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.hasPrefix("\"") {
            token.removeFirst()
            var bytes: [UInt8] = []
            var index = token.startIndex
            while index < token.endIndex {
                let character = token[index]
                if character == "\"" {
                    break
                }
                if character == "\\" {
                    let nextIndex = token.index(after: index)
                    guard nextIndex < token.endIndex else {
                        bytes.append(contentsOf: "\\".utf8)
                        break
                    }
                    let remaining = String(token[nextIndex...])
                    if let octalByte = octalBytePrefix(in: remaining) {
                        bytes.append(octalByte.value)
                        index = token.index(nextIndex, offsetBy: octalByte.length)
                        continue
                    }
                    let escaped = token[nextIndex]
                    switch escaped {
                    case "n":
                        bytes.append(0x0A)
                    case "t":
                        bytes.append(0x09)
                    case "r":
                        bytes.append(0x0D)
                    case "\"":
                        bytes.append(0x22)
                    case "\\":
                        bytes.append(0x5C)
                    default:
                        bytes.append(contentsOf: String(escaped).utf8)
                    }
                    index = token.index(after: nextIndex)
                    continue
                }
                bytes.append(contentsOf: String(character).utf8)
                index = token.index(after: index)
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        return token
    }

    private static func octalBytePrefix(in string: String) -> (value: UInt8, length: Int)? {
        var digits: [UInt8] = []
        for scalar in string.unicodeScalars.prefix(3) {
            guard let digit = scalar.value >= 48 && scalar.value <= 55
                    ? UInt8(exactly: scalar.value - 48)
                    : nil
            else {
                break
            }
            digits.append(digit)
        }
        guard digits.count == 3 else {
            return nil
        }
        let value = digits.reduce(UInt8(0)) { partial, digit in
            partial &* 8 &+ digit
        }
        return (value, digits.count)
    }

    func commitSummaryText() -> String {
        var output = aggregateText()
        for file in files where file.isNew {
            output += " create mode \(file.mode) \(file.path)\n"
        }
        return output
    }

    func showStatText() -> String {
        var output = ""
        for file in files {
            let changed = file.insertions + file.deletions
            guard changed > 0 else {
                continue
            }
            output += " \(file.path) | \(changed) "
            output += String(repeating: "+", count: file.insertions)
            output += String(repeating: "-", count: file.deletions)
            output += "\n"
        }
        output += aggregateText()
        return output
    }

    private func aggregateText() -> String {
        let fileCount = files.count
        let insertions = files.reduce(0) { $0 + $1.insertions }
        let deletions = files.reduce(0) { $0 + $1.deletions }
        var parts = ["\(fileCount) \(fileCount == 1 ? "file" : "files") changed"]
        if insertions > 0 {
            parts.append("\(insertions) \(insertions == 1 ? "insertion" : "insertions")(+)")
        }
        if deletions > 0 {
            parts.append("\(deletions) \(deletions == 1 ? "deletion" : "deletions")(-)")
        }
        return " " + parts.joined(separator: ", ") + "\n"
    }

    struct File {
        var path: String
        var insertions: Int = 0
        var deletions: Int = 0
        var isNew: Bool = false
        var mode: String = "100644"
    }
}
