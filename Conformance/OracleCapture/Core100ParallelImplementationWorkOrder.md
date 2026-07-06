# Core100 全量闭环并行派工单

本文档是 MSP Core100 全量闭环阶段的硬规则。它替代早期“只实现新增 32 个命令、只消费既有 746 case”的派工口径。

当前目标不是把某一批测试跑绿，而是把 100 个已声明 Linux 原生命令全部推进到：

- 已对照本地 reference Linux/GNU/bash/dash/findutils/diffutils 等源码；
- 已明确完整参数面、已支持参数、必须补齐参数、硬性 deferred 理由；
- 已安全 VPS oracle 采样 stdout/stderr/exit code 和必要 side effects；
- 已修 SDK 实现，而不是修 demo 或 fixture 特判；
- 已补模块化 unit/integration/oracle/stress 测试；
- 已清零攻坚矩阵 `Still open implementation` 和 `Still open oracle/stress`；
- 已通过普通全量、gated 全量、fixture 校验和 safety audit。

没有以上证据，任何 batch 都不能声称闭环。

## 固定输入

子 agent 和父 agent 必须以当前仓库状态为准。以下文件是执行入口：

- `Conformance/Fixtures/MSPV1LinuxCommandLayer.required-commands.json`
- `Conformance/Inventory/CommandCompatibilityDrafts/README.md`
- `Conformance/Inventory/CommandCompatibilityDrafts/batch-01-shell-path-runtime.md`
- `Conformance/Inventory/CommandCompatibilityDrafts/batch-02-filesystem.md`
- `Conformance/Inventory/CommandCompatibilityDrafts/batch-03-text-streams.md`
- `Conformance/Inventory/CommandCompatibilityDrafts/batch-04-text-languages-search.md`
- `Conformance/Inventory/CommandCompatibilityDrafts/batch-05-data-comparison-numeric.md`
- `Conformance/Inventory/CommandCompatibilityDrafts/batch-06-metadata-process-identity.md`
- `Conformance/OracleCapture/Core100CaptureCases.generated.json`
- `Conformance/ReferenceOutputs/MSPV1Core100Debian12Oracle/noninteractive-cases.json`
- `Conformance/OracleCapture/Core100CaptureStatus.md`
- `Conformance/OracleCapture/DebianOracleCaptureSafetyPolicy.md`
- `Conformance/OracleCapture/Core100DebianCapturePlan.md`
- `Conformance/OracleCapture/Core100ShellStressCases.md`
- `References/LinuxSourceSnapshot/README.md`
- 本地恢复的 `References/LinuxSourceSnapshot/debian12-bookworm/sources/**`

`References/LinuxSourceSnapshot/debian12-bookworm/sources/**` 是本地 reference source，不属于默认开源仓库面。如果某个命令缺少 reference source，先在本机恢复源码快照或交给父 agent 补本地源码快照，禁止 force-add 进 repo，也禁止凭印象实现。

## VPS 安全红线

所有新 oracle 采样必须先通过本地 safety audit。没有通过 audit，不允许 SSH 执行。

只允许在自动生成的唯一临时根目录内采样：

```text
/tmp/msp-oracle-capture-<run-id>/<case-id>/case-root
```

禁止：

- 写入、删除、移动、改权限系统目录：`/`, `/home`, `/root`, `/etc`, `/var`, `/usr`, `/opt`, `/dev`, `/proc`, `/sys`；
- 停止、重启、安装、卸载、修改系统服务；
- 修改 ssh、防火墙、shell 配置、包管理器状态；
- 对真实设备或真实服务路径执行 `dd`、`truncate`、`chmod`、`chown`、`mv`、`rm`；
- 用未审计变量拼接危险路径；
- 为了学习危险诊断而执行真实危险命令；
- 把 VPS 私有路径、IP、账号写进公开 fixture。

必须：

- 每次采样创建唯一 `/tmp/msp-oracle-capture-*` run root；
- 所有 fixture、输出、软链接、子目录都留在 case root 内；
- cleanup 前校验删除目标以 `/tmp/msp-oracle-capture-` 开头并包含当前 run id；
- cleanup 不跟随 symlink；
- 高风险命令只用 allowlist case；
- 每个 case 记录 command、cwd、stdin、stdout、stderr、exit code、fixture、side effect；
- 采样后确认没有临时目录外 side effect；
- 采样后确认临时目录已清理。

本地安全检查入口：

```sh
python3 Conformance/Scripts/core100_oracle_capture.py safety-self-test
python3 Conformance/Scripts/core100_oracle_capture.py safety-audit --cases Conformance/OracleCapture/Core100CaptureCases.generated.json
```

## 父 Agent 独占职责

以下文件或能力默认只允许父 agent 修改：

- `Package.swift`
- `Implementations/Swift/Sources/MSPCore/**`
- `Implementations/Swift/Sources/MSPShell/**`
- `Implementations/Swift/Sources/ModelShellProxy/**`
- `Implementations/Swift/Sources/MSPPOSIXCore/Registry/MSPPOSIXCoreCommandPack.swift`
- oracle fixture loader、conformance runner、全局测试 harness；
- parser、executor、pipeline、redirection、workspace、policy、audit、streaming bridge 等共享底座；
- 新 VPS capture 批次的执行、安全审核、fixture promotion；
- 6 个 batch 的最终审核和全量验证。

子 agent 如果发现必须改共享底座，只能在交付说明中写清：

- 需要改什么共享能力；
- 为什么命令局部实现无法正确解决；
- 对照源码依据；
- 最小 API 形状；
- 需要的测试。

父 agent 审核后再决定是否改共享底座。

## 子 Agent 通用规则

每个子 agent 只处理自己分配的 batch。

允许：

- 修改自己 batch 的命令实现文件；
- 新建或修改自己 batch 的模块化测试文件；
- 新增自己 batch 的局部 helper；
- 修改自己 batch 的攻坚矩阵段落；
- 提交需要父 agent 统一采样或统一改共享底座的明确请求。

禁止：

- 修改其他 batch 的命令；
- 修改共享底座；
- 修改 `Package.swift`；
- 修改 registry；
- 修改采样脚本；
- 修改本地恢复的 `References/LinuxSourceSnapshot/debian12-bookworm/sources/**`；
- 硬编码 oracle case id 或 oracle 输出；
- 为单个 fixture 打特判；
- 直接访问真实 host 绝对路径；
- 新增真实系统危险操作；
- 把多个无关命令塞进一个巨大实现文件；
- 扩张旧的巨型 smoke test。

## 文件组织规则

新增或拆分命令实现优先采用：

```text
Implementations/Swift/Sources/MSPPOSIXCore/Commands/<Category>/MSP<Command>Command.swift
```

新增或拆分单命令测试优先采用：

```text
Tests/Swift/Unit/MSPPOSIXCore/Commands/<Category>/MSP<Command>CommandTests.swift
```

oracle 或 stress 级测试放在对应层级：

```text
Tests/Swift/Integration/ModelShellProxy/Conformance/Debian12/Core100/**
Tests/Swift/Integration/ModelShellProxy/Pipelines/**
Tests/Swift/Integration/ModelShellProxy/Redirection/**
Tests/Swift/Integration/ModelShellProxy/ShellLanguage/**
Tests/Swift/Unit/MSPPOSIXCore/Performance/**
```

原则：

- 一个命令尽量一个实现文件；
- 一个命令尽量一个直接测试文件；
- 多命令共享测试只能用于 shell stress、pipeline、registry、workspace 层；
- 共享测试不能替代单命令测试；
- 不再扩张旧的大杂烩 smoke 文件。

## 6 组派工

派工以 `Conformance/Inventory/CommandCompatibilityDrafts/README.md` 为准：

- Batch 01 shell/path/runtime：`:`, `[`, `[[`, `basename`, `builtin`, `cd`, `command`, `dirname`, `echo`, `env`, `false`, `printf`, `printenv`, `pwd`, `test`, `true`, `type`, `which`
- Batch 02 filesystem：`chmod`, `cp`, `du`, `find`, `install`, `link`, `ln`, `ls`, `mkdir`, `mktemp`, `mv`, `rm`, `rmdir`, `touch`, `tree`, `truncate`, `unlink`
- Batch 03 text streams：`cat`, `comm`, `cut`, `expand`, `fmt`, `fold`, `grep`, `head`, `join`, `nl`, `paste`, `sort`, `tail`, `tac`, `tee`, `tr`, `uniq`, `unexpand`, `wc`, `yes`
- Batch 04 text languages/search：`awk`, `sed`, `rg`, `xargs`, `seq`, `shuf`, `strings`, `tsort`, `split`
- Batch 05 data/comparison/numeric：`b2sum`, `base32`, `base64`, `basenc`, `bc`, `cksum`, `cmp`, `date`, `dd`, `diff`, `expr`, `factor`, `md5sum`, `numfmt`, `od`, `sha1sum`, `sha256sum`, `sha512sum`, `sum`, `xxd`
- Batch 06 metadata/process/identity：`file`, `groups`, `hostname`, `id`, `ldd`, `nproc`, `pathchk`, `ps`, `readlink`, `realpath`, `sleep`, `stat`, `timeout`, `tty`, `uname`, `whoami`

## 每个命令的闭环流程

每个命令必须按顺序完成：

1. 阅读对应本地 reference Linux/GNU/bash/dash/findutils/diffutils/binutils/ripgrep 等源码。
2. 在矩阵中写清源码文件和核心函数。
3. 列出完整参数面、默认行为、错误行为、性能模型。
4. 对比 MSP 当前实现，列出必须补齐参数和硬性 deferred。
5. 需要新增 oracle 时，先写安全 case，再通过 safety audit。
6. 在真实 Linux VPS 的安全临时目录采样 stdout/stderr/exit code 和必要 side effects。
7. 把采样结果落入本地 fixture。
8. 按源码和 oracle 修 SDK 实现。
9. 增加模块化 unit/integration/oracle/stress 测试。
10. targeted tests 通过后更新矩阵。
11. 只有 `Still open implementation` 和 `Still open oracle/stress` 清零，或只剩父 agent 认可的硬性 deferred，才算 batch 可交父 agent 审核。

## 子 Agent 交付标准

每个子 agent 完成时必须给出：

- 处理的命令列表；
- 每个命令读过的源码文件和函数；
- 新增/修改文件列表；
- 每个命令支持参数和仍 deferred 参数；
- 每个命令 oracle case 数量；
- 每个命令 normal/error/boundary/long/complex/stress 覆盖证据；
- targeted test 命令和结果；
- 是否请求父 agent 改共享底座；
- 是否请求父 agent 做新 VPS capture；
- 是否存在性能风险；
- 是否存在安全风险；
- 攻坚矩阵对应 open gap 是否清零。

不得只说“完成了”。

## 父 Agent 最终验收标准

父 agent 必须审核并执行：

1. 审核 6 个 batch 的源码对照是否真实。
2. 审核 6 个 batch 的参数面是否完整。
3. 审核 deferred 是否极少且理由成立。
4. 审核所有新 VPS capture 是否通过 safety audit。
5. 审核所有 fixture 是否有 command/stdin/stdout/stderr/exit code/side effect。
6. 审核没有 demo 局部补丁冒充 SDK 修复。
7. 审核没有硬编码 oracle 输出。
8. 审核测试层级没有重新混成大杂烩。
9. 运行 Core100 closure gate。
10. 运行 ordinary 全量 `swift test`。
11. 运行 gated 全量 `swift test`，不得有 skipped。
12. 运行 Core100 oracle safety audit，finding_count 必须为 0。

建议的最终命令：

```sh
python3 Conformance/Scripts/check_core100_closure.py
python3 Conformance/Scripts/core100_oracle_capture.py safety-self-test
python3 Conformance/Scripts/core100_oracle_capture.py safety-audit --cases Conformance/OracleCapture/Core100CaptureCases.generated.json
swift test
MSP_RUN_CORE100_ORACLE=1 \
MSP_RUN_DEBIAN12_ORACLE=1 \
MSP_DEBIAN12_ORACLE_ENABLE_HOST_PYTHON=1 \
MSP_DEBIAN12_ORACLE_PYTHON_EXECUTABLE=/usr/bin/python3 \
MSP_DEBIAN12_ORACLE_NODE_EXECUTABLE="$(command -v node)" \
MSP_DEBIAN12_ORACLE_NODE_LOOKUP_PATH=/usr/local/bin/node \
MSP_DEBIAN12_ORACLE_NODE_VERSION_OUTPUT=$'v24.14.0\n' \
MSP_CPYTHON_LIBRARY_PATH=/Library/Frameworks/Python.framework/Versions/3.13/lib/libpython3.13.dylib \
swift test
```

## 不允许交付的情况

- 有任何测试失败；
- gated oracle 有任何 skipped；
- 有任何命令没读源码就实现；
- 有任何声明支持参数没 oracle；
- 攻坚矩阵还有未解释 open gap；
- deferred 只是因为复杂、冷门或暂时没做；
- VPS safety audit 有任何 finding；
- 采样可能影响临时目录外系统状态；
- 只给失败清单或后续计划。

## 完成定义

只有当以下结论全部可由当前仓库和命令输出证明，才允许说完成：

```text
MSP Core100 中所有声明支持的 Linux 命令和参数，
已经源码对照、VPS 安全采样、SDK 实现、模块化测试、
字符级 oracle、压力测试、普通全量、gated 全量、安全审计全部通过，
结果为 0 failure、0 skipped、0 safety finding、0 未解释缺口。
```
