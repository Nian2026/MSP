# MSP 模型工作区执行 SDK 总目标

Status: long-term conformance target.

这份文档是 `MSPModelWorkspaceExecutionSDKProfile.md` 的中文总目标说明。英文 profile 继续作为测试和脚本引用的执行型规范；这份中文说明用于固定长期产品语义和验收口径。

## 最终目标

MSP 要成为一套通用的“模型工作区执行 SDK”。

模型面对的是一套稳定的工作区路径和执行环境。底层可以是真实宿主目录、iOS 沙盒目录、虚拟照片库、远程文件、懒加载文件、混合后端，但这些差异不能暴露到模型实际执行的命令、Python、脚本、子进程、UI 文件树、预览、缓存和路径查找里。

MSP 不是 PhotoSorter 专用 shell，也不是 Readex 的临时复刻。它的长期目标是把 Readex 已经成熟的工作区执行语义 SDK 化、通用化，并同时吃下真实宿主目录、虚拟后端、混合后端和真实模型压力测试。

## Readex 硬边界

Readex 只作为长期语义标尺和行为参考，不作为当前实施对象。

当前阶段禁止修改 Readex 源码，禁止把 MSP 实验代码接进 Readex，禁止为了验证 MSP 去改 Readex 的构建、配置、运行时、提示词或工作区实现。

所有实现、实验、测试、压测、fixture、临时脚本、调试入口，都必须只发生在 MSP 仓库内。

允许做的只有只读查看 Readex 现有行为、文档、代码和运行表现，用它定义 MSP 应该达到的语义标准。

未来 Readex 应该能够迁到 MSP，并且模型体验不倒退。但这只是长期兼容目标，不是当前交付动作。

## 必须交付的核心能力

MSP 必须支持真实宿主目录工作区。真实文件就在宿主目录或 app 沙盒目录里，Python 和外部命令可以高效处理大文件、批量文件，不应该所有读写都绕 broker 临时复制。

MSP 必须支持虚拟工作区。比如 PhotoSorter 的照片库文件不是普通磁盘文件，需要通过 workspace backend 读取、预览、缩略图、OCR、overlay、按需 materialize。

MSP 必须支持混合工作区。同一个工作区里可以同时有真实目录、虚拟目录、临时目录、懒加载文件。模型不需要知道底层差异，只按路径和命令操作。

MSP 必须有完整路径映射。模型写 `/tmp/a.py`、`/docs/a.txt`，运行时可以映射成真实沙盒路径或 materialized 路径交给 Python 和子进程执行。stdout、stderr、traceback、日志、错误消息里出现真实路径时，必须映射回模型看到的路径。

MSP 必须让 Python 进入同一套工作区语义。`open`、`io.open`、`os`、`pathlib`、`shutil`、`tempfile`、`cwd`、`__file__`、`sys.argv[0]`、fd 读写关闭、异常路径，都必须和工作区路径系统一致。

MSP 必须让 Python 子进程一致。`subprocess.run(["find", "/tmp"])`、`subprocess.run(["cat", "/docs/a.txt"])` 不能跑到真实 iOS 根目录，必须继续走 MSP command runner 或受控 child runtime。

MSP policy 必须是通用 SDK 能力。隐藏路径、只读路径、可写路径、是否允许外部命令、是否允许网络、是否允许原始媒体读取、命令包排除，都应该在 MSP policy/workspace contract 里表达，不能散落成 app 特判。

MSP 必须保证 UI 和运行时一致。模型改了工作区，UI 文件树、预览、缩略图、缓存、路径查找也必须看到同一个结果。不能 UI 读一套世界，命令读另一套世界。

## 验收入口

MSPPlaygroundApp 或专门 fixture 必须代表真实宿主目录工作区。如果现在不是 Readex 那种 direct-host 模式，就要补成等价入口。

PhotoSorter 负责验证虚拟照片库后端，但不能代表全部 MSP 验收。

必须有混合后端验收：真实 `/tmp`、真实文档目录、虚拟媒体目录同时存在，模型能在同一轮任务里稳定操作它们。

当前已经提交的混合后端 conformance 种子是 `Tests/Swift/Integration/ModelShellProxy/WorkspaceFS/ModelShellProxyMixedWorkspaceTests.swift`。它证明 shell、Python、Python 子进程能在同一轮流程里共享 host + virtual 的同一个工作区，稳定操作真实 `/docs`、真实 `/tmp` 和虚拟 `/media`，也证明 remote/lazy 风格的 mounted backend 在 shell 和 Python 子进程读取文件头部和尾部时可以先走 `readFileRange`，不被强制全量读取，随后 Python 仍能按虚拟路径读取同一文件且不泄露底层路径。这个测试是有效进展，但还不能等同于完整的 remote-backed 或 lazy-materialized workspace release certification。

focused gate 还包含 `MSPPythonHostProcessVFSTestsBytesAndMetadata/testHostProcessPythonTempfileAndDirFDStayVirtual`、`MSPPythonHostProcessVFSTestsBytesAndMetadata/testHostProcessPythonEntrypointsAndPathlibStayVirtual` 和 `MSPPythonHostProcessVFSTestsSecurity/testHostProcessPythonVFSGuardsImportsLinksPathStringsAndRealPathEscapes`。它们证明 host-process Python 里的 `tempfile`、`dir_fd`、入口脚本、`pathlib` 和逃逸防护都留在虚拟工作区语义里。

focused gate 还包含 `MSPPythonHostProcessTracebackTests/testHostProcessPythonScriptEntrypointTracebackUsesVirtualScriptPath`、`MSPPythonHostProcessTracebackTests/testPythonOutputPathSanitizerHidesEncodedFileURLs` 和 `MSPPythonHostProcessTracebackTests/testPythonStreamingOutputSanitizerKeepsSplitInternalPathsUntilComplete`，作为 Python 输出路径虚拟化覆盖。它们证明在 `/tmp` 生成的 Python 脚本失败时，`__file__`、`sys.argv[0]` 和 traceback 文件路径都保持工作区虚拟路径；编码后的 `file://` URL 输出会映射回模型看到的工作区路径；长流式输出也不能通过把内部路径拆到多个输出块里来泄露真实 workspace、broker、materialized 或 launcher 路径。

focused gate 还包含 `MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualAbsolutePathArgumentsToHostPaths`、`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInsideOptionValues`、`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentValuesToHostPaths`、`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentPathListsToHostPaths`、`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualFileURLsToHostFileURLs`、`MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresKeepPathsVirtual`、`MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresDoNotLeakHostOnlyExecutablePaths`、`MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesHostOnlyExecutablePathsInOutput`、`MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesVersionOutputPaths` 和 `MSPExternalRunnerTests/testHostProcessExternalRunnerVirtualizesEnvironmentAndOutputPaths`，作为 external runner 路径虚拟化覆盖。它证明 host-process 外部命令会把虚拟绝对路径参数映射成 host path 去执行，也会映射 option value 里的虚拟路径，还会把环境变量里的虚拟路径映射成 host path 交给进程真正访问，会逐个映射环境变量路径列表里的虚拟路径，也会把虚拟 file URL 映射成 host file URL；workspace 内可映射 executable 启动失败时错误路径仍保持虚拟，host-only executable 启动失败时不会泄露真实 host path，命令成功执行并在 stdout/stderr 打印自身 host-only executable 路径或编码后的 host-only file URL 时也不会泄露真实 host path，也不会把模型可见的 `PATH` 项重复一遍，静态 `--version` 输出也必须在给模型之前完成路径虚拟化；同时模型仍然看到虚拟 `PWD`、虚拟 `TMPDIR`、虚拟 `MSP_WORKSPACE_ROOT`，stdout/stderr 里也不能泄露真实 workspace 根路径或编码后的真实 `file://` URL。
换句话说，host-process 外部命令看到虚拟 `PWD`、虚拟 `TMPDIR`、虚拟 `MSP_WORKSPACE_ROOT`。
host-process 外部命令会映射 option value 里的虚拟路径。
host-process 外部命令会把环境变量里的虚拟路径映射成 host path。
host-process 外部命令会把环境变量路径列表里的虚拟路径映射成 host path。
host-process 外部命令会把虚拟 file URL 映射成 host file URL。
host-process 外部命令启动失败时路径仍保持虚拟。
host-process 外部命令启动失败时不会泄露 host-only executable 路径。
host-process 外部命令 stdout/stderr 不会泄露 host-only executable 路径或编码后的 host-only file URL，也不会重复模型可见的 PATH 项。
host-process 外部命令静态 version 输出路径也保持虚拟。

Python 子进程 focused 覆盖还包含 `MSPPythonHostProcessSubprocessTests/testHostProcessPythonNestedPythonSubprocessTracebacksStayVirtual`。它证明父 Python 可以通过 `subprocess.run` 和 `Popen(..., stdin=PIPE)` 启动子 Python，子 Python 失败时 traceback 仍保持虚拟路径，不泄露 broker、materialized、launcher 或真实 workspace 根路径。

它还必须包含 `MSPPythonSubprocessBrokerTests/testSessionIncludesReturnedResultOutputWhenRunnerDoesNotStream` 和 `MSPPythonSubprocessBrokerTests/testSessionMergesReturnedStderrWhenRunnerDoesNotStream`。它们证明 Python `Popen` session 模式会保留非 streaming command runner 通过普通结果返回的 stdout/stderr，也会保留 `stderr=STDOUT` 合并语义，不会因为 runner 没有写 session stream 就把子进程输出吞掉。

Popen session 会保留非 streaming runner 返回的 stdout/stderr。

它还必须包含 `MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenFileTargetsAndValidationUseControlledSubprocessBroker`、`MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenPipeChainsAndNestedPythonUseControlledSubprocessBroker` 和 `MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenLifecycleTimeoutsAndConcurrencyUseControlledSubprocessBroker`。它们证明 Python `Popen` 的文件目标、非法 target 诊断、stdout/stderr 管道、pipe chain、嵌套 Python 输出、deferred 嵌套 Python 输出、timeout、kill 和并发子进程都留在受控 subprocess broker 里。

Popen stdout/stderr 管道像普通 Python 文件对象一样可迭代。

它还证明 Python `Popen` pipe 对象会暴露 CPython 兼容的 file-like 元数据、`readable`/`writable`/`seekable`/`isatty` 语义，以及 context manager 自动关闭语义，同时不泄露 host path 或 MSP 内部对象。

Popen pipe 对象会暴露 CPython 兼容的 file-like 元数据、readable/writable/seekable/isatty 语义和 context manager close 语义。

它还证明 `with subprocess.Popen(...) as p` 会遵守 CPython 生命周期语义：`__exit__` 会关闭 stdout、stderr、stdin，等待子进程结束，并且不会把 MSP session 细节暴露给模型。覆盖项包括 `MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenLifecycleTimeoutsAndConcurrencyUseControlledSubprocessBroker` 和 `MSPPythonSubprocessBrokerTests/testClosingOutputReadEndTurnsReturnedOutputIntoBrokenPipe`。

broker 层覆盖还证明：关闭 Popen 输出读端会发送受控 `closeOutput` action，之后这个 stream 的未读输出不再返回；如果子进程之后继续写 stdout，或者 command runner 完成时才返回 stdout，就按 CPython 兼容的 broken-pipe 终止处理，也就是 `-13`，而不是把晚到字节泄露给模型。

Popen context-manager exit 会关闭管道、等待子进程，并把读端关闭后的晚到输出映射成 broken-pipe 终止。

它还证明已完成的 `Popen.communicate()` 结果会按 CPython 语义缓存。重复调用 `communicate()`、先 `wait()` 再 `communicate()`、先手动读取 pipe 再 `communicate()`，以及嵌套 Python 路径，都必须返回对齐结果。

Popen communicate 会缓存已完成的 stdout/stderr 结果，覆盖重复调用、wait 后 communicate、手动读 pipe 后 communicate，以及嵌套 Python 路径。

它还证明 Python `Popen` 会暴露 CPython 兼容的 `pid`、`repr` 和 `send_signal` 生命周期语义，同时不会泄露 MSP 内部类名。

Popen 会暴露 CPython 兼容的 pid、repr 和 send_signal 生命周期语义，不泄露 MSP 内部类名。

它还证明 `subprocess.run` 和 `Popen` 会保持 CPython 兼容的文本模式行为：`Popen.encoding`、`Popen.errors`、`Popen.text_mode`、`Popen.universal_newlines` 这些公开属性存在，`encoding`/`errors` 会进入文本输出模式，并且冲突的 `text` 与 `universal_newlines` 参数会抛出 `SubprocessError`。

subprocess.run 和 Popen 会暴露 CPython 兼容的文本模式行为，并拒绝冲突的 text/universal_newlines 参数。

它也证明 `subprocess.run` 和 `Popen` 的 stdout/stderr 可写文件目标会写回 MSP 虚拟文件系统，而不是绕过工作区视图或泄露 host path。

subprocess.run 和 Popen 的 stdout/stderr 可写文件目标会写回 MSP 虚拟文件系统。

它也证明 `subprocess.run` 和 `Popen` 会在启动子进程前拒绝非法 stream/stdin target，并对 `stdout=STDOUT`、非法 stdin fd、没有 `fileno` 的 stdin 对象给出 CPython 兼容诊断，所以参数校验失败不会偷偷修改工作区。

subprocess.run 和 Popen 会在启动子进程前拒绝非法 stream/stdin target，并给出 CPython 兼容诊断。

它也证明 Python `TimeoutExpired` 异常在 `run`、`wait`、`communicate` 里都会把 `cmd` 保持为调用方命令，而不是暴露 MSP subprocess session id。

TimeoutExpired 异常的 cmd 保持调用方命令，不泄露 MSP session id。

它也证明 `subprocess.run` 和 `Popen.communicate` 超时时，`TimeoutExpired.output`、`TimeoutExpired.stdout`、`TimeoutExpired.stderr` 会保留 CPython 兼容的 partial stdout/stderr bytes，包括 `stderr=STDOUT` 的合并语义，并且之后继续 `communicate()` 仍然能拿到完整进程输出。

这个覆盖必须包含 `MSPPythonSubprocessBrokerTests/testWaitTimeoutIncludesUnreadOutputWithoutConsumingIt`。

TimeoutExpired 异常会为 run 和 communicate timeout 保留 CPython 兼容的 partial stdout/stderr bytes。

它还必须包含 `MSPPythonHostProcessSubprocessTests/testHostProcessPythonNestedPythonScriptSubprocessUsesVirtualCWDArgumentsAndSiblingFiles`，证明 host-process runtime 里的嵌套 Python 脚本子进程能保持虚拟 `cwd`、虚拟 `sys.argv`、脚本路径 `__file__`、`sys.path[0]`，并能通过虚拟路径读取脚本同目录文件。

动态嵌入式 CPython 覆盖还必须包含 `MSPCPythonEngineSubprocessTests/testCPythonEngineNestedPythonSubprocessTracebacksStayVirtualWhenLibraryIsAvailable`。它证明同一个嵌套子 Python traceback 虚拟路径不变量在真实 embedded CPython runtime 里也成立，而不只是 macOS host-process Python bridge 成立。

它还必须覆盖 `MSPCPythonEngineSubprocessTests/testCPythonEngineNestedPythonScriptSubprocessUsesVirtualCWDArgumentsAndSiblingFilesWhenLibraryIsAvailable`，证明嵌套 Python 脚本子进程能保持虚拟 `cwd`、`sys.argv`、脚本路径 `__file__`、`sys.path[0]`，并能通过虚拟路径读取脚本同目录文件。

它还必须包含 `MSPCPythonEngineWorkspaceTests/testCPythonEngineTempfileAndDirFDStayVirtualWhenLibraryIsAvailable`，证明真实 embedded CPython runtime 里的默认 `tempfile` 目录、`TemporaryDirectory`、`NamedTemporaryFile`、`mkstemp` 和 `dir_fd` 操作都留在虚拟 `/tmp` 工作区里，不泄露也不残留底层临时路径。

## 必须覆盖的行为

验收必须覆盖 `pwd`、`ls`、`find`、`xargs`、管道、重定向、脚本文件、临时脚本生成和删除、Python 调子进程、大量文件遍历、大文件读写、错误路径、权限错误、移动、删除、恢复。

验收必须覆盖路径泄露：模型输出、命令输出、Python traceback、子进程 stderr 里不能出现真实沙盒路径、broker 路径、materialized 路径。

验收必须覆盖一致性：同一个文件变化后，shell、Python、UI 文件树、预览、缓存、路径查找都看到一致结果。

## 真实 Linux 字符级对齐

MSP 必须利用已有的真 Linux 字符级对齐测试资产做 oracle。

在压力测试覆盖的命令、Python 脚本、临时脚本、子进程、文件树、预览和缓存行为范围内，MSP 的输入输出必须和真 Linux 工作区字符级对齐。

对齐范围包括 `pwd`、`ls`、`find`、管道、重定向、`/tmp`、cwd、路径错误、权限错误、Python traceback、`os`、`pathlib`、`shutil`、subprocess 输出、脚本路径、文件读写结果。

压力测试时不告诉模型这是 iOS 沙盒或 MSP 虚拟环境。只要任务落在承诺范围内，模型绝对不能从命令输出、Python 输出、错误信息、路径表现、文件树刷新、预览结果中区分它面对的是真 Linux 工作区还是 iOS 沙盒里的 MSP 工作区。

## 真实模型压力测试

最终 UI 验收必须使用真实模型，不能用 mock provider。

真实模型配置走环境变量：

```text
MSP_PLAYGROUND_MODEL_BASE_URL
MSP_PLAYGROUND_MODEL_API_KEY
MSP_PLAYGROUND_MODEL
```

正式 final gate 和 pressure matrix 都必须要求 `MSP_PLAYGROUND_MODEL` 精确等于 `gpt-5.5`。使用其他模型可以作为本地诊断，但不能作为最终验收或 release evidence。

`pressure-matrix-report.json` 必须记录 `required_model`、`model`、`model_matches_required` 和 `model_failures`。这样即使脱离启动它的 shell runner 单独验 report，也能拒绝错模型跑出来的 matrix evidence。

`final-exec-session-gate-report.json` 也必须记录 `required_model`、`model`、`model_matches_required` 和 `model_failures`。final gate report 本身必须足够自解释，不能只靠启动它的 shell preflight 来证明模型正确。

`final-exec-session-gate-report.json` 还必须记录 `linux_character_oracle_alignment`。这个字段是从 Core100 非交互 oracle、Debian 非交互 oracle、live 非交互 Linux/VPS oracle、Debian Linux PTY oracle 这四类报告重新汇总出来的机器可验摘要。它必须证明所有被引用的 Linux 字符级 oracle case 都通过、selected 和 passed 总数一致、failed 总数为 0、compatibility adjustment 为空。final gate runner 自己必须在写入 `passed: true` 前检查这个摘要；如果摘要不干净，就必须拒绝写通过报告，不能先写通过再留给后置 verifier 才发现。verifier 仍然必须重新打开这些 oracle 报告并重算摘要，如果 report 里的 `linux_character_oracle_alignment` 和证据不完全一致，就必须失败。

final gate 还必须把开源发布 dry-run 作为证据写进报告。这个 release dry-run report 必须证明当前 publishable worktree surface 已经复制到一个临时 release tree，复制后的树没有被阻断路径、坏 symlink 或绝对 symlink，并且复制后的树通过 open-source example boundary gate、open-source hygiene gate，以及 `MSPPlaygroundApp` 和 `PhotoSorter` 这两个公开 SwiftPM example package 的默认 `swift test`。final gate 必须把 `open-source-release-dry-run-report.json` 保存在 final gate 输出目录下，通过 `open_source_release_dry_run_report` 引用它，verifier 必须重新打开这个 report 检查，不能把只在源树上通过的结果报告成 publishable release 通过。这个步骤必须由 `Conformance/Scripts/run_open_source_release_dry_run.py` 生成。

因为这个 gate 仍然不是 MSP 总体验收，`final-exec-session-gate-report.json` 里的 `missing_final_gate_classes` 必须保持非空，明确列出当前 exec-session gate 没有认证的长期总目标类别：`remote-backed-workspace-conformance`、`lazy-materialized-workspace-conformance`、`full-ui-preview-thumbnail-cache-e2e-conformance`、`readex-migration-compatibility-conformance`。这样即使 exec-session gate 全绿，也不能被误读成 MSP 最终总目标已经完成。

final gate 还必须把动态嵌入式 CPython Swift 测试作为证据写进报告：`MSPCPythonEngineWorkspaceTests`、`MSPCPythonEngineSubprocessTests`、`MSPCPythonEngineControlledSubprocessMatrixTests`、`MSPCPythonEngineControlledSubprocessCommunicationTests`、`MSPCPythonEngineControlledSubprocessFileTargetTests`、`MSPCPythonEngineControlledSubprocessStreamingTests`、`MSPCPythonEngineControlledSubprocessSignalTests`、`MSPCPythonEngineSubprocessLifecycleTests`、`MSPCPythonEngineSubprocessPressureMatrixTests` 和 `MSPCPythonEnginePressureTests` 必须在真实 `MSP_CPYTHON_LIBRARY_PATH` 下运行，不能 skip，不能失败，并覆盖嵌套子 Python traceback 虚拟路径、嵌套脚本子进程的 `cwd`、参数、同目录文件语义、controlled Popen 元数据/pipe mode、run/communicate/pipe-chain、文件 target/非法 stream、streaming/timeout/nested process、signal/kill/terminate、子进程生命周期/timeout、embedded subprocess pressure，以及 embedded `tempfile`/`dir_fd` 虚拟工作区语义，把 `dynamic-embedded-cpython-swift-tests-report.json` 及对应日志保存在 final gate 输出目录下。

final gate 还必须把根 SwiftPM 全量测试作为证据写进报告。这个 full SwiftPM test-suite report 必须运行无 `--filter` 的根包 `swift test`，使用 final gate 输出树下的 scratch path，并显式准备 macOS CPython、Codex apply_patch dylib、Core100/Debian oracle flag，以及 `linux-external` PTY oracle backend。它必须证明至少执行 850 个测试，不能 skip，不能失败，并把 `full-swift-test-suite-report.json` 及对应日志保存在 final gate 输出目录下。

final gate 还必须把完整 AgentBridge parity matrix 作为证据写进报告。这个 matrix 必须由 `run_full_agentbridge_parity_matrix.sh` 发现并运行 `Tests/Swift/Unit/MSPAgentBridge` 下全部 AgentBridge XCTest class，显式准备 Codex `apply_patch` dylib 覆盖，证明 exec command/session、Responses streaming/tool call、apply_patch、conversation history、interrupt、compaction、goal、turn steer 这些 capability bucket 全部存在，并运行 Codex compaction source-currentness 检查。它必须不能 skip、不能失败，并把 `full-agentbridge-parity-matrix-report.json` 及对应日志保存在 final gate 输出目录下。

final gate 还必须把 live 非交互 Linux/VPS oracle 作为证据写进报告。这个 live oracle 必须由 `run_live_noninteractive_linux_vps_oracle.py` 通过 SSH 在已证明的 Debian 12/bookworm Linux 主机上现场运行全部 50 个 Debian 非交互 fixture case，写出 `live-noninteractive-linux-vps-oracle-report.json`，并证明 failed case 为 0、runner failure 为 0、compatibility adjustment 为空，同时记录 live runner 的平台和 OS 证据。

final gate 还必须把 focused test suites ledger 作为证据写进报告。这个 ledger 必须列出 exec-session gate 依赖的每一个 focused Swift filter 和 gate-style focused 验证入口，包括命令合同、package path、覆盖标签、canonical step log，以及对应的 nested evidence report。`final-exec-session-gate-report.json` 必须引用 `focused-test-suites-ledger/focused-test-suites-ledger-report.json`，verifier 必须重新打开它检查，防止有人悄悄删掉某个 focused 验证入口但报告仍然声称 gate 通过。这个 ledger 必须包含 `MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualAbsolutePathArgumentsToHostPaths`、`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInsideOptionValues`、`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentValuesToHostPaths`、`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentPathListsToHostPaths`、`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualFileURLsToHostFileURLs`、`MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresKeepPathsVirtual`、`MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresDoNotLeakHostOnlyExecutablePaths`、`MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesHostOnlyExecutablePathsInOutput`、`MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesVersionOutputPaths` 和 `MSPExternalRunnerTests/testHostProcessExternalRunnerVirtualizesEnvironmentAndOutputPaths`，作为当前 host-process 外部命令参数、option value、环境变量值、环境变量路径列表、file URL、workspace 内 executable 启动失败路径虚拟化、host-only executable 启动失败路径不泄露、host-only executable stdout/stderr 路径和 encoded file URL 不泄露且不重复模型可见 PATH 项、静态 version 输出路径虚拟化，以及 stdout/stderr 路径虚拟化切片；必须包含 `ModelShellProxyMixedWorkspaceTests/testShellPythonAndSubprocessShareMixedHostAndVirtualBackends`，作为真实 `/docs` + `/tmp` + 虚拟 `/media` 的读写删除和子进程一致性覆盖；也必须包含 `ModelShellProxyMixedWorkspaceTests/testShellRangeReadsLazyRemoteMountBeforePythonFullRead`，作为当前 remote/lazy mixed-workspace 种子覆盖；还必须包含 `MSPPlaygroundViewModelTests/testWorkspaceMediaPreviewInvalidatesCachedContentWhenWorkspaceCacheVersionChanges`，作为当前 PhotoSorter UI 预览缓存随工作区版本失效的切片覆盖；也必须包含 `MSPPlaygroundShellRuntimePreviewTests/testThumbnailCacheKeyIncludesWorkspaceCacheVersion`，作为当前 PhotoSorter UI 缩略图缓存 key 随工作区版本隔离的切片覆盖。但 `full-ui-preview-thumbnail-cache-e2e-conformance` 必须继续留在 missing final gate classes 里，直到完整 UI 预览、缩略图、缓存和路径查找 E2E 面都被认证。

正式 final gate 和 pressure matrix 必须拒绝跳过 provider smoke，也必须拒绝固定 provider smoke 的 prompt、expected output 或 nonce。单独 smoke 脚本可以为了诊断暴露这些覆盖变量，但任何可作为最终验收证据的压测入口都必须现场生成不可预置的检查内容。

final gate 和 pressure matrix 还必须拒绝把必需子验收关掉的 suite 级环境变量，例如 `MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON=0`、`MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC=0`、`MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE=0`、`MSP_PLAYGROUND_PRESSURE_RESET_APP=0`、`MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON=0`、`MSP_PHOTOSORTER_PRESSURE_RESET_APP=0`。matrix 自己启动每个 suite 时也必须显式把这些要求设回必需状态；final gate 调用 matrix 时也必须显式把这些要求设回必需状态，不能因为调用者环境里关掉了 Python、shell diagnostic、Python oracle、嵌入式 CPython 或 fresh app reset，就产出看起来通过但实际变弱的验收报告。

final gate 必须先运行 `Conformance/Scripts/check_real_model_pressure_preflight.py`，并把它作为 `real-model-pressure-preflight-hardening` step 记录进最终报告。这个 step 必须证明 final gate、pressure matrix、MSPPlaygroundApp suite runner、PhotoSorter suite runner 都会在拿 UI lock、跑 provider smoke、启动 Simulator UI 之前拒绝错模型、跳过 provider smoke、固定 provider smoke payload、关闭 Python/CPython、关闭 oracle、关闭 shell diagnostic、关闭 fresh app reset，以及只跑部分 matrix suite。它还必须写出 `real-model-pressure-preflight-report.json`，final gate report 必须引用这个 artifact，让 verifier 能重新检查 case 数、runner 覆盖、精确的必需 case label 集合、每个 case 的 exit code 2、stderr 匹配、没有越过启动边界，以及失败数为 0。

final gate 的源码层还必须有 source guard 防退化测试。`ModelShellProxyPressureHarnessSourceGuardTests` 必须固定 pressure runner、matrix runner、provider smoke、prompt suite、反馈字段、泄露扫描和必需 workspace suite 的关键合同，防止之后有人把真实模型压测悄悄改回 mock、错模型、部分 suite、跳过 provider smoke、关闭 Python/CPython/oracle，或者在任务 prompt 里直接泄露 iOS、MSP、sandbox、broker、materialized 等底层线索。

每个 suite 的 `pressure-report.json` 必须自解释地记录模型身份、主压测请求模型证据和 provider smoke 证据；换句话说，每个 suite 的 `pressure-report.json` 必须记录 `required_model`、`model`、`model_matches_required`、`model_failures`、`model_request_built`、`provider_smoke.checked: true`、request/response artifact 路径、`request_model`、`request_model_matches_required`、`expected_output` 和 `actual_output`。`model` 必须精确等于 `gpt-5.5`，`model_failures` 必须为空；`model_request_built` 必须记录 `count`、`expected_count`、`models`、`all_match_required` 和 `failures`，其中 `expected_count` 必须精确等于这个 suite 必需的 prompt 轮数，包括最后的反馈轮，`count` 必须大于等于 `expected_count`，并且主压测事件里的 `model_request_built.model` 必须全部精确等于 `gpt-5.5`；provider smoke 报告里的 `request_model` 以及 request artifact 里的真实 `model` 字段也必须精确等于 `gpt-5.5`。`expected_output` 与 `actual_output` 必须字符级一致，并且必须来自 smoke request 里的动态 `MSP_PROVIDER_OK_<nonce>`。matrix 和 final gate verifier 必须能重新打开这些 request/response artifact；相对路径按对应 suite 的 `pressure-report.json` 所在目录解析。它们必须拒绝缺少模型身份、错模型、主压测请求数量不足、伪造或调低必需 prompt 轮数、主压测请求模型不对、缺少 provider smoke 证据、provider smoke request 模型不对、artifact 缺失或 expected/actual 不一致的 suite report。

压测必须在真实 app 里跑大量自然任务，比如整理文件、生成脚本、删除临时脚本、批量查找、生成报告、移动文件、处理失败后继续下一步。

每轮压测后必须问模型反馈：输出是否符合它对真 Linux 工作区的预期；它有没有看到 iOS 沙盒路径、broker 路径、materialized 路径；它能否区分这是真 Linux 还是 iOS 沙盒；哪些命令行为让它觉得不对。反馈只能要求模型根据已经观察到的命令输出、Python 输出、错误信息、路径表现、文件树刷新和预览结果判断，不能允许它脱离可见输出猜测。

## 问题处理原则

任何压测不一致都必须先归因，禁止给某个命令、某段脚本、某条路径、某个相册场景打补丁特判。

归因必须分清：MSP 通用底层能力问题、workspace backend 适配问题、POSIX 命令包语义问题、Python/runtime bridge 问题、policy 配置问题、app UI 同步问题、agent 提示词问题、测试任务超出 MSP 承诺的问题。

修复必须落在通用层。修完以后，同类问题应该自然一起消失。

## 最终通过标准

同一类模型任务在 host-backed MSPPlaygroundApp、virtual-backed PhotoSorter、混合工作区里都能长期稳定运行。

模型看到的路径一致，Python 和 shell 看到的世界一致，UI 看到的世界一致，输出不泄露真实底层路径，子进程不逃逸，缓存不陈旧，失败能解释清楚并落到通用修复点。

在所有压力测试承诺范围内，MSP 的输入输出必须和真 Linux 字符级对齐。模型在不知道底层环境的情况下，绝对不能区分它面对的是真 Linux 工作区还是 iOS 沙盒里的 MSP 工作区。

如果任何一轮压测中模型能稳定指出某个输出不像真 Linux，或者出现真实沙盒路径、broker 路径、materialized 路径泄露，就必须继续归因和修复，直到同类测试重新达到字符级对齐、模型无法区分为止。

最终交付不允许保留已知不一致，不允许用“这是沙盒环境所以正常”解释，不允许用特定命令、特定脚本、特定路径的补丁绕过。
