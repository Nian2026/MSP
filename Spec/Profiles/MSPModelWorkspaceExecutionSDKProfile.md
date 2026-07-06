# MSP Model Workspace Execution SDK Profile

Status: long-term conformance target.

Chinese total-goal statement:
`Spec/Profiles/MSPModelWorkspaceExecutionSDKProfile.zh-CN.md`.

This profile defines MSP as a general model workspace execution SDK. It is not
a PhotoSorter-specific shell and it is not a temporary Readex clone.

MSP presents one stable workspace execution world to the model. The underlying
backend may be a direct host directory, an app sandbox directory, a virtual
media library, a remote file store, lazy materialized files, or a mixed
workspace. Those backend differences must not appear in model-facing command
text, Python behavior, subprocess behavior, UI file trees, previews, caches, or
path lookups.

## Readex Boundary

Readex is a long-term semantic reference only. It is not an implementation
target for current MSP work.

Current MSP work must not modify Readex source code, build settings, runtime
configuration, prompts, workspace implementation, fixtures, or tests. MSP
experiments must not be wired into Readex to prove MSP behavior.

All implementation, experiments, test fixtures, pressure tests, debug entry
points, and temporary scripts for this profile must live inside the MSP
repository.

Read-only inspection of Readex behavior, docs, source, and runtime output is
allowed only to define the behavior MSP must eventually match. A future Readex
migration to MSP is a compatibility goal, not a current delivery action.

## Required Workspace Backends

A conforming SDK must support a direct host-backed workspace. Files live in the
host directory or app sandbox directory, and Python plus allowed external
commands can process large files and large batches efficiently. Direct
host-backed operation must not force all file reads and writes through brokered
temporary copies.

A conforming SDK must support virtual workspaces. Files may not be ordinary
disk files and may need backend calls for read, write, preview, thumbnails,
metadata, OCR, overlays, or materialization.

A conforming SDK must support mixed workspaces. One workspace can contain
direct directories, virtual directories, temporary directories, lazy files, and
remote-backed files. The model uses paths and commands without knowing which
backend serves a given subtree.

## Unified Path Contract

Model-visible paths are workspace paths rooted at `/`.

When a model writes `/tmp/a.py` or `/docs/a.txt`, the runtime may map that path
to a real sandbox path or a materialized path internally. stdout, stderr,
tracebacks, logs, diagnostics, subprocess output, and UI text must map internal
paths back to model-visible paths before the model can see them.

The following path classes are never model-visible output:

- host sandbox roots;
- broker directories;
- materialized file directories;
- launcher scripts;
- temporary runtime bookkeeping files;
- backend-private cache paths.

## Python Contract

Python must run inside the same workspace world as shell commands.

The contract includes at least:

- `open` and `io.open`;
- `os` filesystem calls;
- `pathlib`;
- `shutil`;
- `tempfile`;
- `cwd` and `os.chdir`;
- `__file__`;
- `sys.argv[0]`;
- fd open, read, write, close, and writeback;
- exception paths;
- formatted traceback output.

Python output must not leak the real host path used to execute Python, the
launcher script path, broker paths, materialized paths, or app sandbox paths.

## Subprocess Contract

Python subprocess APIs must keep using the MSP workspace execution world.

Examples that must stay in MSP semantics:

```python
subprocess.run(["find", "/tmp"])
subprocess.run(["cat", "/docs/a.txt"])
subprocess.run("cat /tmp/a.txt | sort | uniq", shell=True)
os.popen("find /tmp -type f")
os.system("printf side > /tmp/out.txt")
```

These calls must not escape to the platform root filesystem. They must run
through the MSP command runner or an equivalently controlled child runtime with
the same cwd, path mapping, policy, stdin, stdout, stderr, timeout, and
cancellation semantics.

## Policy Contract

Policy is an SDK-level workspace contract, not an app-specific patch surface.

The SDK must expose policy for:

- hidden paths;
- read-only paths;
- writable paths;
- command pack inclusion and exclusion;
- external command availability;
- network availability;
- raw media access;
- destructive operation authorization;
- backend-specific capability declarations.

Apps configure policy. They must not need to patch individual command
implementations or individual Python scripts to enforce generic workspace
rules.

## UI And Runtime Consistency

The UI and runtime must read the same effective workspace state.

When a model changes the workspace, shell commands, Python, subprocesses, UI
file trees, previews, thumbnails, caches, and path lookups must converge on the
same result. A UI view must not read one world while command execution reads
another.

## Acceptance Entrypoints

MSPPlaygroundApp or a dedicated fixture must represent direct host-backed
workspace behavior. If MSPPlaygroundApp does not match the direct host-backed
Readex-style workspace class, the MSP repository must provide another
equivalent entrypoint for this profile.

PhotoSorter validates virtual media workspace behavior. It is not sufficient
as the only MSP conformance target.

The repository must also provide a mixed-backend conformance target where a
direct `/tmp`, a direct document subtree, and a virtual media subtree are
available in the same workspace.

The current committed mixed-backend conformance seed is
`Tests/Swift/Integration/ModelShellProxy/WorkspaceFS/ModelShellProxyMixedWorkspaceTests.swift`.
It proves that shell commands, Python, and Python subprocesses share a mixed
host and virtual workspace through direct `/docs`, direct `/tmp`, and virtual
`/media` operations in one shell/Python/subprocess flow; it also proves that a
remote/lazy-style mounted backend can serve shell and Python-subprocess
head/tail reads through `readFileRange` before Python performs a full virtual
read. This seed is useful evidence, but it is not yet the full remote-backed or
lazy-materialized workspace release certification.

The focused gate also includes
`MSPPythonHostProcessVFSTestsBytesAndMetadata/testHostProcessPythonTempfileAndDirFDStayVirtual`,
`MSPPythonHostProcessVFSTestsBytesAndMetadata/testHostProcessPythonEntrypointsAndPathlibStayVirtual`,
and
`MSPPythonHostProcessVFSTestsSecurity/testHostProcessPythonVFSGuardsImportsLinksPathStringsAndRealPathEscapes`.
They prove that host-process Python keeps `tempfile`, `dir_fd`, entrypoint,
`pathlib`, and escape-guard behavior inside virtual workspace semantics.

The focused gate also includes
`MSPPythonHostProcessTracebackTests/testHostProcessPythonScriptEntrypointTracebackUsesVirtualScriptPath`,
`MSPPythonHostProcessTracebackTests/testPythonOutputPathSanitizerHidesEncodedFileURLs`,
and
`MSPPythonHostProcessTracebackTests/testPythonStreamingOutputSanitizerKeepsSplitInternalPathsUntilComplete`
as Python output-path virtualization coverage. They prove that scripts generated
under `/tmp` expose virtual `__file__`, virtual `sys.argv[0]`, and virtual
traceback paths when they fail; that encoded `file://` URL output maps back to
workspace-visible paths; and that long streaming output cannot leak an internal
path by splitting it across output chunks.

The focused gate also includes
`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualAbsolutePathArgumentsToHostPaths`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInsideOptionValues`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentValuesToHostPaths`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentPathListsToHostPaths`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualFileURLsToHostFileURLs`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresKeepPathsVirtual`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresDoNotLeakHostOnlyExecutablePaths`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesHostOnlyExecutablePathsInOutput`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesVersionOutputPaths`
and
`MSPExternalRunnerTests/testHostProcessExternalRunnerVirtualizesEnvironmentAndOutputPaths`
as external runner path virtualization coverage. It proves that host-process
external commands map virtual absolute path arguments to host paths for
execution, map virtual paths embedded in option values, and map virtual paths
carried in environment values to host paths before launching the process, map
virtual paths carried in environment path lists component-by-component, map
virtual file URLs to host file URLs for execution, and keep launch-failure
paths virtual for workspace-mapped executables, and avoid leaking host-only
executable paths when launch fails or when successful commands print their own
host-only executable paths or encoded host-only file URLs, without duplicating
model-visible `PATH` entries, and sanitize static `--version` output before it
reaches the model, while still exposing virtual `PWD`, virtual `TMPDIR`, virtual
`MSP_WORKSPACE_ROOT`, sanitized extra environment path values, and sanitized
stdout/stderr instead of host workspace roots or encoded host `file://` URLs.
In short: host-process external commands expose virtual `PWD`, virtual
`TMPDIR`, virtual `MSP_WORKSPACE_ROOT`.
host-process external commands map virtual paths embedded in option values.
host-process external commands map virtual paths carried in environment values to host paths.
host-process external commands map virtual paths carried in environment path lists to host paths.
host-process external commands map virtual file URLs to host file URLs.
host-process external commands keep launch-failure paths virtual.
host-process external commands do not leak host-only executable paths when launch fails.
host-process external commands do not leak host-only executable paths or encoded host-only file URLs in stdout or stderr, or duplicate model-visible PATH entries.
host-process external commands keep static version output paths virtual.

The Python subprocess focused coverage also includes
`MSPPythonHostProcessSubprocessTests/testHostProcessPythonNestedPythonSubprocessTracebacksStayVirtual`.
It proves that a parent Python process can launch child Python processes via
`subprocess.run` and `Popen(..., stdin=PIPE)` without losing virtual traceback
paths or leaking broker, materialized, launcher, or workspace-root paths.
It must also include
`MSPPythonSubprocessBrokerTests/testSessionIncludesReturnedResultOutputWhenRunnerDoesNotStream`
and
`MSPPythonSubprocessBrokerTests/testSessionMergesReturnedStderrWhenRunnerDoesNotStream`.
They prove that Python `Popen` session mode preserves stdout/stderr returned by
a non-streaming command runner, including `stderr=STDOUT` merge semantics,
instead of dropping output when the runner does not write to session streams.
Python subprocess Popen sessions preserve returned stdout/stderr for
non-streaming runners.
It must also include
`MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenFileTargetsAndValidationUseControlledSubprocessBroker`,
`MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenPipeChainsAndNestedPythonUseControlledSubprocessBroker`,
and
`MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenLifecycleTimeoutsAndConcurrencyUseControlledSubprocessBroker`.
They prove that Python `Popen` file targets, invalid target validation,
stdout/stderr pipes, pipe chains, nested Python output, deferred nested-Python
output, lifecycle timeouts, kill behavior, and concurrent children all stay
inside the controlled subprocess broker.
Python subprocess Popen stdout/stderr pipes are iterable file-like objects
across streaming, bytes, memory, and deferred nested-Python paths.
It also proves that Python `Popen` pipe objects expose CPython-compatible
file-like metadata and `readable`/`writable`/`seekable`/`isatty` semantics
plus context-manager close semantics without leaking host paths or MSP internal
objects.
Python subprocess Popen pipe objects expose CPython-compatible file-like
metadata, readable/writable/seekable/isatty semantics, and context-manager close
semantics.
It also proves that `with subprocess.Popen(...) as p` follows CPython lifecycle
semantics: `__exit__` closes stdout, stderr, and stdin, waits for the child, and
does not expose MSP session details. This coverage includes
`MSPPythonHostProcessSubprocessTests/testHostProcessPythonPopenLifecycleTimeoutsAndConcurrencyUseControlledSubprocessBroker`
and
`MSPPythonSubprocessBrokerTests/testClosingOutputReadEndTurnsReturnedOutputIntoBrokenPipe`.
The broker-level coverage proves that closing a Popen output read end sends a
controlled `closeOutput` action, suppresses unread output from that stream, and
turns later child writes or returned stdout into CPython-compatible broken-pipe
termination (`-13`) instead of leaking late bytes to the model.
Python subprocess Popen context-manager exit closes pipes, waits, and maps
late output after read-end close to broken-pipe termination.
It also proves that completed `Popen.communicate()` results are cached with
CPython-compatible semantics across repeated `communicate()` calls,
`wait()`-then-`communicate()`, manual pipe reads before `communicate()`, and
nested-Python paths.
Python subprocess Popen communicate caches completed stdout/stderr results
across repeated calls, wait-then-communicate, manual-read-before-communicate,
and nested-Python paths.
It also proves that Python `Popen` exposes CPython-compatible `pid`, `repr`,
and `send_signal` lifecycle semantics without leaking MSP internal class names.
Python subprocess Popen exposes CPython-compatible pid, repr, and send_signal
lifecycle semantics without leaking MSP internal class names.
It also proves that `subprocess.run` and `Popen` preserve CPython-compatible
text-mode behavior: public `Popen.encoding`, `Popen.errors`,
`Popen.text_mode`, and `Popen.universal_newlines` attributes are present,
`encoding`/`errors` imply text output, and conflicting `text` plus
`universal_newlines` arguments are rejected with `SubprocessError`.
Python subprocess.run and Popen expose CPython-compatible text-mode behavior
and reject conflicting text/universal_newlines arguments.
It also proves that `subprocess.run` and `Popen` stdout/stderr writable file
targets write through the MSP virtual filesystem instead of bypassing the
workspace view or leaking host paths.
Python subprocess.run and Popen stdout/stderr writable file targets write
through the MSP virtual filesystem.
It also proves that `subprocess.run` and `Popen` reject invalid stream/stdin
targets before child execution, including CPython-compatible diagnostics for
`stdout=STDOUT`, invalid stdin file descriptors, and stdin objects without
`fileno`, so failed argument validation cannot secretly mutate the workspace.
Python subprocess.run and Popen reject invalid stream/stdin targets before child
execution with CPython-compatible diagnostics.
It also proves that Python `TimeoutExpired` exceptions preserve the caller's
command in `cmd` for `run`, `wait`, and `communicate` instead of exposing MSP
subprocess session ids.
Python subprocess TimeoutExpired exceptions preserve the caller command in cmd
without leaking MSP session ids.
It also proves that `TimeoutExpired.output`, `TimeoutExpired.stdout`, and
`TimeoutExpired.stderr` preserve CPython-compatible partial stdout/stderr bytes
for `subprocess.run` and `Popen.communicate` timeouts, including
`stderr=STDOUT` merge behavior, while later `communicate()` calls can still
return the complete process output.
This coverage must include
`MSPPythonSubprocessBrokerTests/testWaitTimeoutIncludesUnreadOutputWithoutConsumingIt`.
Python subprocess TimeoutExpired exceptions preserve CPython-compatible partial
stdout/stderr bytes for run and communicate timeouts.
It must also include
`MSPPythonHostProcessSubprocessTests/testHostProcessPythonNestedPythonScriptSubprocessUsesVirtualCWDArgumentsAndSiblingFiles`.
It proves that nested Python script subprocesses in the host-process runtime
preserve virtual `cwd`, virtual `sys.argv`, script-path `__file__`,
`sys.path[0]`, and script-sibling file access.

The dynamic embedded CPython coverage must include
`MSPCPythonEngineSubprocessTests/testCPythonEngineNestedPythonSubprocessTracebacksStayVirtualWhenLibraryIsAvailable`.
It proves the same nested child-Python traceback invariant against the real
embedded CPython runtime, not only the macOS host-process Python bridge.
It must also cover nested script subprocesses preserving virtual `cwd`,
`sys.argv`, script-path `__file__`, `sys.path[0]`, and script-sibling file
access through
`MSPCPythonEngineSubprocessTests/testCPythonEngineNestedPythonScriptSubprocessUsesVirtualCWDArgumentsAndSiblingFilesWhenLibraryIsAvailable`.
It must also include
`MSPCPythonEngineWorkspaceTests/testCPythonEngineTempfileAndDirFDStayVirtualWhenLibraryIsAvailable`.
It proves that the real embedded CPython runtime keeps default `tempfile`
locations, `TemporaryDirectory`, `NamedTemporaryFile`, `mkstemp`, and `dir_fd`
operations inside the virtual `/tmp` workspace without leaking or leaving
temporary host paths behind.

## Linux Character-Level Oracle

This profile is oracle-first.

MSP must use the existing Debian/Linux character-level oracle assets as the
standard for command and Python behavior. In the pressure-test scope, MSP input
and output must match the Linux oracle at the character level.

The oracle scope includes at least:

- `pwd`, `ls`, `find`, `xargs`, pipes, redirection, and scripts;
- `/tmp`, cwd, missing paths, permission errors, and command diagnostics;
- Python `open`, `os`, `pathlib`, `shutil`, `tempfile`, and traceback output;
- subprocess stdout, stderr, return codes, timeout, kill, and side effects;
- script path, `__file__`, `sys.argv[0]`, and file read/write results.

The current oracle and coverage assets include:

- `Conformance/ReferenceOutputs/MSPV1Debian12Oracle/noninteractive-cases.json`;
- `Conformance/ReferenceOutputs/MSPV1Core100Debian12Oracle/noninteractive-cases.json`;
- `Conformance/Fixtures/MSPV1LinuxCommandLayer.parity-cases.json`;
- `Conformance/Fixtures/MSPV1LinuxCommandLayer.direct-parity-cases.json`;
- `Conformance/Fixtures/MSPV1PythonRuntimeCoverage.json`;
- `Conformance/Scripts/check_python_oracle_coverage.py`;
- `Conformance/Scripts/cache_beeware_cpython_apple_support.sh`;
- `Conformance/Scripts/check_real_model_pressure_preflight.py`;
- `Conformance/Scripts/run_final_exec_session_release_gate.sh`;
- `Conformance/Scripts/run_exec_session_stress_gate.sh`;
- `Conformance/Scripts/run_core100_oracle_conformance.sh`;
- `Conformance/Scripts/run_debian12_pty_oracle.py`;
- `Conformance/Scripts/run_debian12_pty_oracle_container.sh`;
- `Conformance/Scripts/verify_debian12_pty_oracle_report.py`;
- `Tests/Swift/Integration/ModelShellProxy/Conformance/`;
- `Tests/Swift/Unit/MSPPythonRuntime/`;
- `Tests/Swift/Unit/MSPPythonEmbeddedRuntime/`.

## Real Model Pressure Tests

Final UI acceptance must use a real model provider, not a mock provider.

The real model configuration is supplied through:

```text
MSP_PLAYGROUND_MODEL_BASE_URL
MSP_PLAYGROUND_MODEL_API_KEY
MSP_PLAYGROUND_MODEL
```

The current committed host-backed pressure harness assets are:

- `Examples/iOS/MSPPlaygroundApp/Tools/E2E/run-real-model-pressure.sh`;
- `Examples/iOS/MSPPlaygroundApp/Tools/E2E/run-real-model-e2e.sh`;
- `Examples/iOS/MSPPlaygroundApp/Tools/E2E/run-shell-diagnostic.sh`;
- `Examples/iOS/MSPPlaygroundApp/Tools/E2E/embed-cpython-xcframework.sh`;
- `Examples/iOS/MSPPlaygroundApp/Tools/E2E/check-openai-responses-provider.sh`;
- `Examples/iOS/MSPPlaygroundApp/Tools/E2E/verify-real-model-pressure-log.py`;
- `Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/host-backed-linux-parity-prompts.json`;
- `Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/exec-session-parity-prompts.json`;
- `Examples/iOS/MSPPlaygroundApp/Tools/E2E/pressure/mixed-backend-linux-parity-prompts.json`.

The current committed virtual PhotoSorter pressure harness assets are:

- `Examples/iOS/PhotoSorter/Tools/E2E/run-real-model-pressure.sh`;
- `Examples/iOS/PhotoSorter/Tools/E2E/run-real-model-e2e.sh`;
- `Examples/iOS/PhotoSorter/Tools/E2E/check-openai-responses-provider.sh`;
- `Examples/iOS/PhotoSorter/Tools/E2E/pressure/photosorter-virtual-workspace-prompts.json`;
- `Examples/iOS/PhotoSorter/Tools/E2E/pressure/photosorter-exec-session-parity-prompts.json`.

The repository-level real-model pressure matrix assets are:

- `Conformance/Scripts/cache_beeware_cpython_apple_support.sh`;
- `Conformance/Scripts/run_final_exec_session_release_gate.sh`;
- `Conformance/Scripts/run_exec_session_stress_gate.sh`;
- `Conformance/Scripts/run_dynamic_embedded_cpython_swift_tests.sh`;
- `Conformance/Scripts/run_full_agentbridge_parity_matrix.sh`;
- `Conformance/Scripts/verify_readex_boundary.py`;
- `Conformance/Scripts/run_real_model_pressure_matrix.sh`;
- `Conformance/Scripts/verify_real_model_pressure_matrix.py`;
- `Conformance/Scripts/verify_final_exec_session_release_gate_report.py`;
- `Conformance/Scripts/verify_agentbridge_compaction_source_currentness.sh`;
- `Tests/Swift/Integration/ModelShellProxy/StandardFixtures/ModelShellProxyPressureHarnessSourceGuardTests.swift`.

The exec-session profile release gate is:

```bash
MSP_PLAYGROUND_MODEL_BASE_URL=... \
MSP_PLAYGROUND_MODEL_API_KEY=... \
MSP_PLAYGROUND_MODEL=gpt-5.5 \
  Conformance/Scripts/run_final_exec_session_release_gate.sh
```

This gate is intentionally not a smoke test, but it is also not the overall MSP
open-source release gate. The final open-source gate must additionally prove the
final-scope capabilities outside this exec-session profile.
The exec-session gate report must mark
that narrower scope explicitly so it cannot be mistaken for total project
completion.

The exec-session gate and standalone real-model pressure matrix both refuse any
run where `MSP_PLAYGROUND_MODEL` is
not exactly `gpt-5.5`; where provider smoke checks are disabled; where the
provider smoke prompt, expected output, or nonce are overridden by environment
variables; where suite-level environment variables disable the required Python,
shell diagnostic, Python oracle, embedded CPython, or fresh-app-reset pressure
checks; where the required CPython packaging asset is missing;
where the Linux/Debian PTY oracle is not proven by `--require-linux-runner`;
where the live noninteractive Linux/VPS oracle has not rerun all 50 Debian
noninteractive fixture cases on a proven Debian 12/bookworm SSH host;
where the Readex boundary verifier has not proven the reference snapshots clean
and the release scripts free of external Readex source dependencies; where the
local exec-session stress gate has not passed; where Python subprocess calls have not
proven they honor command-pack exclusions through the MSP command runner and
preserve virtual traceback paths for nested Python processes; or
where the Core100 noninteractive oracle has not passed all 905 fixture cases;
or where the pressure matrix does not include all required workspace classes. A run
that uses a mock model, a partial matrix, a macOS-only PTY smoke backend, no
embedded CPython pressure path, or a different model may be useful for local
debugging, but it cannot certify this profile.

The exec-session gate must run
`Conformance/Scripts/check_real_model_pressure_preflight.py` as the
`real-model-pressure-preflight-hardening` step before the expensive release
evidence steps. That real-model pressure preflight hardening step must prove
that the final gate, the pressure matrix, and both suite-level pressure runners
all reject wrong
models, provider-smoke bypasses, fixed provider-smoke payloads, disabled
Python/CPython gates, disabled oracle gates, disabled shell diagnostics,
disabled fresh-app resets, and partial matrix suite lists before acquiring UI
locks, running provider smoke, or starting Simulator UI work. The step log must
end with the audit marker `real-model pressure preflight checks passed`. The
same step must write `real-model-pressure-preflight-report.json`, and the final
gate report must reference that artifact so the verifier can independently
check the case count, required runner classes, per-case exit code 2, expected
stderr match, absence of startup-boundary markers, exact required case labels,
and zero failed preflight cases.

The final gate, real-model pressure matrix, and suite-level real-model pressure
runners must run under repository-level exclusive locks. They drive real iOS
Simulator UI state and install apps with fixed bundle identifiers, so
concurrent runs make the resulting evidence ambiguous and cannot certify the
profile. The final gate must also default `TMPDIR` to a directory under its
output tree, exposed through a no-whitespace temporary symlink alias when
needed, and must pass the same root to Swift conformance tests through
`MSP_CONFORMANCE_TMPDIR`, so Swift tests and oracle fixtures do not depend on
the host system temporary volume.

The Debian noninteractive oracle runner must be safe when invoked directly,
not only through the final gate. If `MSP_CONFORMANCE_TMPDIR` is not already set,
it must default its conformance temp root under
`.build/msp-conformance/debian12-oracle/tmp` and expose a no-whitespace alias
when needed.

The matrix runner's default build roots must live under the matrix output
directory, not under system `/tmp`. Final-gate evidence should be reproducible
and auditable from one output tree, and large Simulator build products must not
depend on free space in the host system temporary volume. Developers may still
override build roots explicitly for local diagnostics. The matrix runner must
also default `TMPDIR` to a directory under the matrix output tree so child
build tools and temporary-file users inherit the same storage policy. If the
output-tree temp path contains whitespace, the runner must expose it to child
tools through a no-whitespace temporary symlink alias, because some third-party
build helper scripts are not robust to whitespace in temp paths.

The exec-session release gate report must be audit-ready on its own. Its
`final-exec-session-gate-report.json` must include the ordered step list,
per-step log paths, the required pressure suite names, `completion_scope:
exec-session-release-gate`, `not_final_msp_open_source_release_gate: true`,
`missing_final_gate_classes`, `required_model`, `model`,
`model_matches_required`, `model_failures`, and evidence artifact paths for the
real-model pressure preflight report, Readex boundary report, exec-session stress report,
open-source release dry-run report, dynamic embedded CPython Swift tests report,
full SwiftPM test-suite report,
full AgentBridge parity matrix report,
Debian noninteractive oracle report, live noninteractive Linux/VPS oracle report,
Linux PTY oracle report, pressure matrix report,
Core100 noninteractive oracle report, and each required suite's `pressure-report.json`.
Because this is not the overall MSP open-source release gate,
`missing_final_gate_classes` must stay non-empty and must explicitly list the
long-term final-goal classes not certified by this exec-session gate:
`remote-backed-workspace-conformance`,
`lazy-materialized-workspace-conformance`,
`full-ui-preview-thumbnail-cache-e2e-conformance`, and
`readex-migration-compatibility-conformance`.
The open-source release dry-run report must prove that the current publishable
worktree surface was copied into a release tree, that the copied tree has no
blocked paths or broken/absolute symlinks, that the copied tree passes the
open-source example boundary gate and open-source hygiene gate, and that both
public SwiftPM example packages, `MSPPlaygroundApp` and `PhotoSorter`, completed
default `swift test` inside that copied tree. The final gate must write
`open-source-release-dry-run-report.json` under the final gate output tree,
reference it through `open_source_release_dry_run_report`, and the verifier must
reopen that report so a source-tree-only pass cannot be reported as a
publishable release pass. The release dry-run step must be produced by
`Conformance/Scripts/run_open_source_release_dry_run.py`.
The dynamic embedded CPython Swift tests report must prove that the real
`MSPCPythonEngineWorkspaceTests`, `MSPCPythonEngineSubprocessTests`,
`MSPCPythonEngineControlledSubprocessMatrixTests`,
`MSPCPythonEngineControlledSubprocessCommunicationTests`,
`MSPCPythonEngineControlledSubprocessFileTargetTests`,
`MSPCPythonEngineControlledSubprocessStreamingTests`,
`MSPCPythonEngineControlledSubprocessSignalTests`,
`MSPCPythonEngineSubprocessLifecycleTests`,
`MSPCPythonEngineSubprocessPressureMatrixTests`, and
`MSPCPythonEnginePressureTests` ran against a configured CPython library with
zero skipped tests, zero failures, nested child-Python traceback virtualization
coverage, nested script `cwd`/argument/sibling-file coverage, controlled Popen
metadata/pipe-mode, run/communicate/pipe-chain, file-target/invalid-stream,
streaming/timeout/nested-process, signal/kill/terminate, subprocess
lifecycle/timeout, embedded subprocess pressure, embedded `tempfile`/`dir_fd`
virtual workspace coverage, and logs kept under the final gate output tree.
The full SwiftPM test-suite report must run the root package with unfiltered
`swift test`, no `--filter`, the final-gate scratch path, configured macOS
CPython, configured Codex apply_patch dylib coverage, Core100 and Debian
oracle flags enabled, and the Linux-external PTY oracle backend required. It
must prove the full suite executed at least 850 tests with zero skipped tests,
zero failures, and logs kept under the final gate output tree.
The full AgentBridge parity matrix report must be produced by
`run_full_agentbridge_parity_matrix.sh`, must run every discovered
`Tests/Swift/Unit/MSPAgentBridge` XCTest class with configured Codex
`apply_patch` dylib coverage, must prove all required capability buckets are
present, must run the Codex compaction source-currentness check, and must record
zero skipped tests, zero failures, and logs kept under the final gate output
tree.
The live noninteractive Linux/VPS oracle report must be produced by
`run_live_noninteractive_linux_vps_oracle.py`, must run all 50 Debian
noninteractive fixture cases through SSH on a proven Debian 12/bookworm Linux
host, must write `live-noninteractive-linux-vps-oracle-report.json`, and must
record zero failed cases, zero runner failures, no compatibility adjustments,
and the live runner platform/OS evidence.
The focused test-suites ledger must list every focused Swift filter and
gate-style focused validation step that the exec-session gate relies on,
including the command contract, package path, coverage label, canonical step log,
and any nested evidence report. The final gate report must reference
`focused-test-suites-ledger/focused-test-suites-ledger-report.json`, and the
verifier must reopen that ledger so a run cannot silently drop a focused
validation entry while still claiming the exec-session gate passed.
The ledger must include
`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualAbsolutePathArgumentsToHostPaths`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInsideOptionValues`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentValuesToHostPaths`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualPathsInEnvironmentPathListsToHostPaths`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerMapsVirtualFileURLsToHostFileURLs`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresKeepPathsVirtual`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerLaunchFailuresDoNotLeakHostOnlyExecutablePaths`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesHostOnlyExecutablePathsInOutput`
,
`MSPExternalRunnerTests/testHostProcessExternalRunnerSanitizesVersionOutputPaths`
and
`MSPExternalRunnerTests/testHostProcessExternalRunnerVirtualizesEnvironmentAndOutputPaths`
as the current host-process external-command argument, option-value, environment
value, environment path-list, file-URL, workspace-mapped launch-failure,
host-only executable launch-failure no-leak, host-only executable stdout/stderr
no-leak without duplicated model-visible PATH entries, static version-output path
virtualization, and stdout/stderr path virtualization slice. It must also include
`ModelShellProxyMixedWorkspaceTests/testShellPythonAndSubprocessShareMixedHostAndVirtualBackends`
as mixed host `/docs` + `/tmp` + virtual `/media` read/write/delete/subprocess
consistency coverage, and
`ModelShellProxyMixedWorkspaceTests/testShellRangeReadsLazyRemoteMountBeforePythonFullRead`
as the current remote/lazy mixed-workspace seed coverage. It must also include
`MSPPlaygroundViewModelTests/testWorkspaceMediaPreviewInvalidatesCachedContentWhenWorkspaceCacheVersionChanges`
as the current PhotoSorter UI preview-cache invalidation slice, while
`MSPPlaygroundShellRuntimePreviewTests/testThumbnailCacheKeyIncludesWorkspaceCacheVersion`
is the current PhotoSorter UI thumbnail-cache key slice. The
`full-ui-preview-thumbnail-cache-e2e-conformance` remains a missing final gate
class until the full UI preview, thumbnail, cache, and path-lookup E2E surface is
certified.
The final gate report must be
self-explanatory
enough to reject a wrong-model run even when it is verified outside the shell
runner that launched it. The final gate must refuse to write `passed: true` if
any required evidence artifact is missing. After
writing the report, the final gate must run
`verify_final_exec_session_release_gate_report.py` against it and write a
verifier summary in the same output directory. The verifier must reopen the
referenced evidence reports and fail if any nested gate report is missing, not
passed, has failures, has dirty Readex reference snapshots, depends on external
Readex source paths, omits required suites, leaks internal paths, says the
model can distinguish MSP from regular Linux, or does not prove all 905
Core100 noninteractive oracle cases passed.

The final gate report must also write `linux_character_oracle_alignment`.
This field is a machine-checkable summary derived from the Core100
noninteractive oracle, Debian noninteractive oracle, live noninteractive
Linux/VPS oracle, and Debian Linux PTY oracle reports. It must prove that all
referenced Linux character-level oracle cases passed, that the total selected
and passed case counts match, that failed case count is zero, and that
compatibility adjustments are empty. The verifier must recompute the summary
from the referenced oracle reports and fail if the report's
`linux_character_oracle_alignment` does not match the evidence exactly. The
final gate runner itself must also refuse to write `passed: true` when this
alignment summary is not clean; it must not emit a passing report and leave the
oracle failure for a later verifier step.

The matrix runner must default to all five required suites:
`host-backed`, `exec-session`, `mixed-backend`, `photosorter-virtual`, and
`photosorter-exec-session`. It must write a
single `pressure-matrix-report.json` that records whether all required suites
were present, whether the required model was used, whether each suite passed,
which completion sentinels were observed, whether the model reported suspicious
output, and whether any scanner found model-visible internal path leaks. The
matrix report must include `required_model`, `model`, `model_matches_required`,
and `model_failures`, so the evidence artifact can reject a wrong-model run
even when it is verified outside the shell runner that launched it. A matrix run
is not a final pass unless all five suite reports pass the same hard feedback
and leak checks.
Because the matrix report can be used as release evidence, both the final gate
and the matrix runner must refuse provider-smoke skip flags and must refuse
fixed provider-smoke prompt, expected output, or nonce overrides. They must also
refuse suite-level weakening overrides such as
`MSP_PLAYGROUND_PRESSURE_REQUIRE_PYTHON=0`,
`MSP_PLAYGROUND_PRESSURE_RUN_SHELL_DIAGNOSTIC=0`,
`MSP_PLAYGROUND_PRESSURE_RUN_PYTHON_ORACLE=0`,
`MSP_PLAYGROUND_PRESSURE_RESET_APP=0`,
`MSP_PHOTOSORTER_PRESSURE_REQUIRE_CPYTHON=0`, and
`MSP_PHOTOSORTER_PRESSURE_RESET_APP=0`. The matrix runner and final gate's
matrix invocation must force these requirements back to the required state for
every suite they launch, so no release evidence can be certified by inheriting
disabled Python, shell diagnostic, Python oracle, embedded CPython, or
fresh-app-reset checks.

Each suite-level `pressure-report.json` must be self-explanatory. It must
include a boolean `passed` field, a string-array `failures` field,
`required_model`, `model`, `model_matches_required`, `model_failures`, and a
`model_request_built` evidence block proving that the main pressure-turn
request events used only the required model. That block must include `count`,
`expected_count`, `models`, `all_match_required`, and `failures`;
`expected_count` must exactly equal the required prompt turns for that suite,
including the feedback turn, and `count` must be at least `expected_count`. It
must also include a
`provider_smoke` evidence block with `checked: true` plus the request and
response artifact paths. The same block must record `request_model`,
`request_model_matches_required`, `expected_output`, and `actual_output`. The
reported request model and the actual `model` field inside the provider-smoke
request artifact must both be exactly `gpt-5.5`; `expected_output` and
`actual_output` must exactly match the dynamic
`MSP_PROVIDER_OK_<nonce>` string from the smoke request. Matrix and final-gate
verifiers must reopen the referenced provider-smoke request and response
artifacts; relative artifact paths are resolved against the suite
`pressure-report.json` directory. A failing suite must write the same
owner-actionable failure reasons into `failures` that the verifier prints to
stderr, so a report artifact is enough to distinguish a wrong model, a
model-visible leak, model confusion, missing sentinel, missing provider-smoke
evidence, missing provider-smoke artifacts, mismatched provider-smoke output,
missing tool activity, exec-session contract failure, or malformed feedback.
The matrix verifier must honor a suite report's `passed: false` or non-empty
`failures` even when the matrix layer can re-derive other fields, and it must
reject any suite report whose model evidence is missing or does not match
`gpt-5.5`, whose main `model_request_built` evidence is missing, forges or
undercounts the required prompt turns, or is not exclusively `gpt-5.5`, whose
`provider_smoke.checked` is not true, whose
provider-smoke request model evidence is missing or not `gpt-5.5`, whose
provider-smoke artifacts cannot be reopened, or whose provider-smoke actual
output does not exactly match the expected output.

The host-backed real-model pressure runner must preflight the same app class
with `run-shell-diagnostic.sh` and the Python oracle before asking the real
model to judge the workspace. A pressure failure should not be accepted until
the underlying shell/Python oracle gate is already green or the failure is
explicitly assigned to that lower layer.

Each pressure run must default to a fresh app workspace. Reusing installed app
data is allowed only when the caller explicitly opts in, because stale files
from a prior real-model run can make the model-visible Linux state inconsistent
with the prompt sequence being judged.

The pressure runner must accept a prompt suite path so the same real-model E2E
and verifier can be reused for host-backed, virtual-backed, and mixed-backend
workspace pressure runs. The runner must derive each suite's required
completion sentinels from the prompt text rather than hardcoding one host-only
sentinel.

MSPPlaygroundApp exposes `MSP_PLAYGROUND_WORKSPACE_PROFILE=mixed-backend` as
the current mixed workspace pressure entrypoint. That entrypoint combines a
direct `/tmp`, a direct `/docs`, and a non-host `/media` backend in one
model-visible workspace.

PhotoSorter exposes `Examples/iOS/PhotoSorter/Tools/E2E/run-real-model-pressure.sh`
as the current virtual Photos workspace pressure entrypoint. That entrypoint
must run the same multi-turn real-model/verifier loop against the app's `/图库`,
`/相册`, `/最近删除`, and `/tmp` workspace surface. Task prompts before the
final feedback turn must not disclose iOS, sandbox, MSP, broker, materialized,
launcher, or app-internal implementation details.

Pressure tests must run in a real app and exercise natural model tasks:

- organize files;
- create, run, and delete temporary scripts;
- traverse many files;
- read and write large files;
- generate reports;
- move, remove, and restore files;
- run Python that starts subprocesses;
- recover after command failures and continue.

The pressure prompt must not tell the model that the environment is iOS, an app
sandbox, or an MSP virtual workspace. Inside the committed pressure-test scope,
the model must not be able to distinguish the MSP environment from a real Linux
workspace by observing command output, Python output, errors, paths, file tree
refreshes, previews, or cache behavior.

After each pressure run, the harness must ask the model whether the observed
outputs matched its expectations for a real Linux workspace; whether it saw any
iOS sandbox path, broker path, materialized path, or other non-workspace path;
whether it can distinguish a real Linux workspace from an iOS sandbox MSP
workspace using only observed command/Python output, errors, paths, file-tree
refreshes, previews, and cache behavior; and which command behaviors looked
wrong. The feedback answer must be based only on text the model actually
observed, and any claimed leak must quote the observed text.

## Failure Handling

Any pressure-test mismatch must be assigned to one of these layers before a fix
is accepted:

- MSP generic runtime;
- workspace backend adapter;
- POSIX command pack;
- shell parser or shell runtime;
- Python runtime bridge;
- subprocess bridge;
- policy configuration;
- app UI synchronization;
- agent prompt;
- task outside the profile commitment.

Fixes must land in the generic layer that owns the mismatch. Command-specific,
script-specific, path-specific, album-specific, or test-specific patches are
not acceptable as final fixes.

Every observed mismatch inside the committed pressure-test scope must be fixed
until the same class of task returns to Linux character-level parity and the
model can no longer distinguish the environments. Final delivery may not keep
known mismatches and may not explain them away as normal sandbox behavior.

## Final Passing Standard

The same class of model tasks must run stably in:

- a host-backed MSPPlaygroundApp or equivalent host-backed fixture;
- virtual-backed PhotoSorter;
- a mixed-backend workspace.

For all committed pressure-test cases:

- model-visible paths are consistent;
- Python and shell see the same workspace;
- subprocesses do not escape the workspace;
- UI file trees, previews, thumbnails, caches, and path lookup see the same
  effective state;
- stdout, stderr, tracebacks, diagnostics, and logs do not leak internal paths;
- cache state is not stale after workspace changes;
- failures are explainable and fixed in the owning generic layer;
- input and output match the Linux oracle at character level;
- a real model that is not told about the backend cannot distinguish MSP from a
  real Linux workspace within the test scope.
