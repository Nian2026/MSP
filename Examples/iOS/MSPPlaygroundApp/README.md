# MSP Playground App

MSP Playground App is the developer-facing iOS proof for Model Shell Proxy.

It demonstrates that an iOS app can give an agent a Linux-like virtual
workspace without exposing a raw host shell.

The agent sees files, paths, commands, stdout, stderr, exit codes, scripts, and
tool extensions through one MSP command runtime. The app still owns the real
storage, iOS permissions, embedded runtimes, policy decisions, and audit
boundary.

This is the example to read when you want to integrate MSP into an app that owns
a normal workspace directory. `Examples/iOS/PhotoSorter` is the companion
virtual-backend example for the iOS Photos Library.

## What It Demonstrates

MSP Playground shows a complete app loop:

```text
user message
-> iOS app
-> model stream
-> exec_command / write_stdin / apply_patch
-> MSP shell
-> WorkspaceFS
-> Python, Git, or app-owned command capability
-> model-visible result
-> continued assistant response
```

The app includes:

- a chat-first iOS UI with streamed assistant output
- inline tool-call blocks in the transcript
- a left-edge workspace drawer exposing the MSP workspace root `/`
- an app-owned workspace directory behind model-visible virtual paths
- an MSP shell runtime instead of `/bin/sh`, `bash`, or `zsh`
- `exec_command` and `write_stdin` as the small agent-facing command surface
- optional embedded CPython so `python3` can run inside the MSP boundary
- optional Git command support through the `MSPGit` package
- a Codex-compatible `apply_patch` runtime for workspace text edits
- transcript and visual checks that make tool activity inspectable

The important proof is not that iOS becomes Linux. It does not.

The proof is that an iOS app can present a model-operable environment that feels
close enough to a regular Linux workspace for agent workflows: paths, files,
commands, streams, errors, scripts, Python, Git, and patch application all flow
through one controlled runtime.

## Workspace Model

The model-facing workspace is rooted at `/`.

Paths such as `/notes/example.md` are MSP workspace paths. They are not raw host
filesystem paths, and they are not iOS sandbox paths. The app maps those virtual
paths to storage it owns.

The same boundary applies to external capabilities:

- Python runs through an app-supplied CPython runtime.
- Git runs through an MSP Git command pack backed by libgit2.
- `apply_patch` runs through the MSP/Codex patch bridge.

Those capabilities participate in the same command environment as ordinary MSP
filesystem and text commands. They are not separate one-off buttons beside the
agent.

## Quick Start

From this directory, run the fast local checks:

```bash
swift test

xcodebuild \
  -project Project/MSPPlaygroundApp.xcodeproj \
  -scheme MSPPlaygroundApp \
  -configuration Debug \
  -sdk iphonesimulator \
  build

Tools/E2E/run-transcript-fixture-visual-check.sh
```

The default `swift test` run is source-oriented. It may skip optional checks that
need local runtime artifacts, such as a macOS CPython framework or a locally
built host dynamic `apply_patch` bridge.

## Direct Device Runs

One-time setup for direct device runs:

```bash
../Tools/bootstrap-ios-examples.sh \
  --team ABCDE12345 \
  --bundle-prefix com.yourname.modelshellproxy
```

The public Xcode project does not contain a personal signing team. The bootstrap
script writes ignored local signing settings and pre-populates the CPython iOS
cache used by the app build phases.

After that, open `Project/MSPPlaygroundApp.xcodeproj`, select your connected
iPhone or iPad, and press Run. Xcode may still ask you to sign in with an Apple
ID or trust the device.

The checked-in app target currently uses `IPHONEOS_DEPLOYMENT_TARGET = 26.0`.
Use an Xcode/iOS SDK that can build that target and a device that can run it.

For command-line device builds, either run the bootstrap once or pass the same
values as Xcode build settings:

```bash
xcodebuild \
  -project Project/MSPPlaygroundApp.xcodeproj \
  -scheme MSPPlaygroundApp \
  -configuration Debug \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  MSP_EXAMPLE_DEVELOPMENT_TEAM=ABCDE12345 \
  MSP_EXAMPLE_BUNDLE_ID_PREFIX=com.yourname.modelshellproxy \
  build
```

## Embedded CPython

MSPPlaygroundApp builds require a configured or cached CPython runtime by
default so direct Xcode builds do not silently ship a missing `python3` backend.

The app copies `Python.framework` into the bundle, installs the Python home at
`MSPPlaygroundApp.app/python`, and uses that bundled runtime automatically.
When the local cache is missing, the build phase populates it from BeeWare
Python-Apple-support before packaging the app.

Set `MSP_PLAYGROUND_REQUIRE_CPYTHON=0` only for non-Python build diagnostics.

## Optional Tests

To run the optional CPython runtime smoke test from this directory:

```bash
eval "$(MSP_CPYTHON_APPLE_SUPPORT_PLATFORMS=macOS ../../../Conformance/Scripts/cache_beeware_cpython_apple_support.sh)"
MSP_PLAYGROUND_CPYTHON_LIBRARY_PATH="$MSP_CPYTHON_LIBRARY_PATH" \
MSP_PLAYGROUND_CPYTHON_HOME="$MSP_CPYTHON_HOME" \
  swift test --filter MSPPlaygroundPythonRuntimeTests
```

To run the optional host dynamic bridge test from this directory:

```bash
REPO_ROOT="$(cd ../../.. && pwd)"
APPLY_PATCH_DIR="$REPO_ROOT/Implementations/Swift/Sources/Tools/Vendor/Codex/apply_patch"
APPLY_PATCH_TARGET_DIR="$APPLY_PATCH_DIR/Artifacts/Build/target"
MSP_CODEX_APPLY_PATCH_TARGET_DIR="$APPLY_PATCH_TARGET_DIR" \
  "$APPLY_PATCH_DIR/Scripts/build-rust-bridge.sh"
MSP_CODEX_APPLY_PATCH_DYLIB="$APPLY_PATCH_TARGET_DIR/release/libmsp_codex_apply_patch_bridge.dylib" \
  swift test --filter MSPPlaygroundApplyPatchRuntimeTests
```

## Real-Model E2E

Real-model checks require local provider credentials. They are not stored in the
repository.

Provider smoke check before the full simulator E2E:

```bash
MSP_PLAYGROUND_MODEL_BASE_URL=...
MSP_PLAYGROUND_MODEL_API_KEY=...
MSP_PLAYGROUND_MODEL=...
Tools/E2E/check-openai-responses-provider.sh
```

Full real-model simulator E2E:

```bash
MSP_PLAYGROUND_MODEL_BASE_URL=...
MSP_PLAYGROUND_MODEL_API_KEY=...
MSP_PLAYGROUND_MODEL=...
Tools/E2E/run-real-model-e2e.sh
```

Real-model no-tool chat E2E:

```bash
MSP_PLAYGROUND_MODEL_BASE_URL=...
MSP_PLAYGROUND_MODEL_API_KEY=...
MSP_PLAYGROUND_MODEL=...
MSP_PLAYGROUND_E2E_PROMPT='你好'
MSP_PLAYGROUND_E2E_EXPECT_TOOL=0
Tools/E2E/run-real-model-e2e.sh
```

Git-specific real-model pressure:

```bash
MSP_PLAYGROUND_MODEL_BASE_URL=...
MSP_PLAYGROUND_MODEL_API_KEY=...
MSP_PLAYGROUND_MODEL=...
Tools/E2E/run-real-model-git-pressure.sh
```
