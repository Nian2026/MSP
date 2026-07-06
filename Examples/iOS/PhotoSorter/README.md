# PhotoSorter App

PhotoSorter is the product-shaped iOS Photos Library example for Model Shell
Proxy. It is the flagship iOS proof that MSP can turn a real, privacy-sensitive
system resource into an agent-operable workspace. The app is example-app
surface; the reusable SDK entry points live in the MSP package.

The point is larger than uploading a few images into a chat model.

The point is to let an iOS app project the Photos Library into an app-owned
operating environment where:

```text
Agent sees a workspace.
App owns the resource.
Policy controls access.
Commands expose capability.
Audit records execution.
```

PhotoSorter demonstrates the MSP claim on a platform where there is no raw shell
for agents, app sandboxing is strict, and user data is both personal and owned
by system frameworks. Albums become folders. Photos and videos become file-like
entries. The model can reason through commands, while the app keeps ownership of
Photos framework access, media reads, writeback, policy, and user confirmation.

## What It Demonstrates

PhotoSorter shows a complete app loop:

```text
user message
-> iOS app
-> agent timeline
-> exec_command
-> MSP shell
-> Photos-backed WorkspaceFS
-> app-specific media commands
-> model-visible result
-> continued assistant response
```

It combines the generic MSP shell model with a real iOS domain backend:

- a chat-first iOS UI with streamed assistant output
- inline tool-call blocks in the transcript
- a left-edge workspace drawer exposing the MSP workspace root `/`
- Photos Library projection through `/图库`, `/相册`, and `/最近删除`
- ordinary MSP/POSIX-style exploration commands such as `pwd`, `ls`, `find`,
  and `cat` where appropriate
- PhotoSorter-specific commands for media metadata, OCR, VLM summaries, visual
  review, user review, album operations, trash, restore, and file-tree snapshots
- app-controlled access modes for metadata-only work versus full Photos access
- sensitive-read policy for original media pixels and video frames
- CPython packaging through the same optional MSP Python runtime path used by
  the other iOS example

PhotoSorter could have been kept as a closed-source product. Photo library
cleanup is a nearly universal problem: almost everyone with a phone eventually
accumulates years of screenshots, duplicates, receipts, memes, documents, and
half-forgotten moments that are too tedious to sort by hand. That makes
PhotoSorter a genuinely commercial app idea.

I am open-sourcing it anyway because the larger point is MSP: app capabilities
should become composable command vocabulary inside product-shaped software,
especially when the data is private, personal, and too valuable to hand to an
uncontrolled tool.

## Photos Workspace

PhotoSorter maps Photos Library content into MSP workspace paths. Instead of
copying photos into the app workspace as ordinary imported files, it projects
them as file-like entries backed by Photos assets.

The implemented workspace shape includes:

```text
/
|-- 图库/
|-- 相册/
|   |-- 系统/
|   |   |-- 个人收藏/
|   |   |-- 截图/
|   |   |-- 最近添加/
|   |   |-- 视频/
|   |   |-- 屏幕录制/
|   |   |-- RAW/
|   |   |-- 实况照片/
|   |   |-- 慢动作/
|   |   |-- 全景照片/
|   |   |-- 自拍/
|   |   |-- 连拍/
|   |   |-- 延时摄影/
|   |   |-- 电影效果/
|   |   `-- 空间/
|   `-- 用户/
|       |-- ...
`-- 最近删除/
```

`/图库` exposes the library as a global media space. `/相册/系统` exposes system
album views. `/相册/用户` exposes user albums. `/最近删除` is the app-visible
trash/restore surface for approved destructive workflows.

The app still owns the underlying Photos framework calls. Workspace paths are
model-facing virtual paths, while private user media stays behind the app's
Photos framework boundary.

## Command Surface

PhotoSorter registers a domain command pack alongside the MSP shell runtime.
The current pack includes:

- `media` for media listing, metadata, OCR, VLM summaries, visual inspection,
  user review, cache status, stats, trash, and restore
- `album` for adding/removing media references and removing user album
  containers
- `filetree` for compact workspace tree snapshots
- `rm` for workspace-style removal that respects the Photos-backed trash
  boundary

The most important `media` subcommands are:

```text
media list <scope>
media show <path>...
media show --ocr <path>...
media show --vlm <path>...
media search --ocr <keyword|--regex pattern> ...
media search --vlm <keyword|--regex pattern> ...
media view <path>...
media ask --from-file <path-list> [--message <text>]
media status
media cache status [ocr|vlm|place]
media stats <scope>
media trash --from-file <path-list>
media restore --from-file <path-list>
```

The important `album` commands are:

```text
album add [--create] --from-file <path-list> <user-album-path>
album remove --from-file <path-list> <user-album-path>
album rm --from-file <path-list>
```

This makes photo-library work composable. A model can list a scoped batch,
filter it with OCR or cached VLM summaries, write intermediate path lists under
`/tmp`, ask the user to review a refined candidate set, and then act only on the
confirmed paths.

Example workflow shape:

```sh
media list /相册/系统/截图 > /tmp/screenshots.txt
media search --ocr "invoice" --from-file /tmp/screenshots.txt --format paths > /tmp/invoice_hits.txt
media show --from-file /tmp/invoice_hits.txt --limit 200 --format tsv
media ask --message "请确认这些疑似票据截图。" --from-file /tmp/invoice_hits.txt --limit 200 --write-selected /tmp/confirmed_invoices.txt
album add --create --from-file /tmp/confirmed_invoices.txt /相册/用户/票据截图
```

For cleanup or deletion workflows, the intended path is evidence first, user
review second, action last:

```sh
media ask --message "请确认这些清理候选。" --from-file /tmp/refined_candidates.txt --limit 200 --write-selected /tmp/approved_delete.txt
media trash --from-file /tmp/approved_delete.txt --limit 200
```

## Access And Safety

PhotoSorter deliberately separates cheap inspection from sensitive reads.

The model can start with workspace shape, metadata, album context, cached OCR,
cached VLM summaries, and bounded stats. Original image pixels and video frames
are treated as sensitive reads. `media view` attaches selected images to the
model for visual inspection and is limited to focused batches. `media ask` opens
a user-facing review UI for confirmation while original media remains under app
policy.

Writeback is also constrained. Album edits, trash operations, and restore
operations are exposed as commands, but high-impact workflows are expected to
work from refined path lists and explicit user confirmation. The app remains the
owner of Photos permission, media access, writeback, and audit state.

## Product Shape

- The first screen is a chat conversation.
- The user types into a bottom composer.
- The composer accepts natural language; shell commands run inside the agent
  tool loop.
- Assistant output streams into the transcript.
- Tool calls appear inline in the real timeline as processed work blocks.
- The workspace filesystem is hidden off the left edge.
- The user drags right from the left edge to pull out the workspace.
- The workspace shows the MSP workspace root `/`.
- Photos Library mounts appear as workspace folders.
- Photo preview remains user-visible and controlled by the app.

The UI is intentionally product-shaped. It shows how MSP fits inside an app
while still making the shell runtime concrete.

## Quick Start

Run these checks from `Examples/iOS/PhotoSorter`:

```bash
Tools/check-local-packages.sh
swift test
xcodebuild -project Project/PhotoSorter.xcodeproj -target PhotoSorter -sdk iphonesimulator -configuration Debug build
Tools/E2E/run-transcript-fixture-visual-check.sh
```

`Tools/check-local-packages.sh` verifies that the default open-source package
stays independent of copied local FastVLM or MLX sources.

## Direct Device Run

Create local signing settings once:

```bash
../../../Examples/iOS/Tools/bootstrap-ios-examples.sh \
  --team ABCDE12345 \
  --bundle-prefix com.yourname.msp
```

The public Xcode project does not contain a personal signing team. The bootstrap
script writes ignored local signing settings and pre-populates the CPython iOS
cache. After that, open `Project/PhotoSorter.xcodeproj`, select your connected
iPhone or iPad, and press Run. You can also set the same values in Xcode's
Signing & Capabilities UI or pass `MSP_EXAMPLE_DEVELOPMENT_TEAM` and
`MSP_EXAMPLE_BUNDLE_ID_PREFIX` to `xcodebuild`.

The checked-in app target currently uses `IPHONEOS_DEPLOYMENT_TARGET = 26.0`.
Use an Xcode/iOS SDK that can build that target and a device that can run it.

Command-line device build:

```bash
MSP_EXAMPLE_DEVELOPMENT_TEAM=ABCDE12345 \
MSP_EXAMPLE_BUNDLE_ID_PREFIX=com.yourname.msp \
  xcodebuild -project Project/PhotoSorter.xcodeproj \
    -scheme PhotoSorter \
    -configuration Debug \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    build
```

## CPython Runtime

PhotoSorter copies the matching `Python.framework` slice into the app bundle and
installs the Python home at `PhotoSorter.app/python`.

PhotoSorter builds require a configured or cached CPython runtime by default so
developer and distributable app packages do not silently ship a
registered-but-unavailable `python3`. When the local cache is missing, the build
phase populates it from BeeWare Python-Apple-support before packaging the app.
Set `MSP_PHOTOSORTER_REQUIRE_CPYTHON=0` only for non-Python build diagnostics.

Default `swift test` may skip PhotoSorter CPython runtime tests when no bundled
or configured CPython runtime is available. To run those optional tests from
this directory with a cached macOS CPython framework:

```bash
eval "$(MSP_CPYTHON_APPLE_SUPPORT_PLATFORMS=macOS ../../../Conformance/Scripts/cache_beeware_cpython_apple_support.sh)"
MSP_PHOTOSORTER_CPYTHON_LIBRARY_PATH="$MSP_CPYTHON_LIBRARY_PATH" \
MSP_PHOTOSORTER_CPYTHON_HOME="$MSP_CPYTHON_HOME" \
  swift test --filter PhotoSorterPythonRuntimeTests
```

## Optional FastVLM

The default open-source package does not include copied FastVLM source, model
weights, or MLX package products.

Local FastVLM live inference is opt-in. Keep copied FastVLM Swift source in
ignored `Local/FastVLM/`, keep model files in ignored
`Resources/FastVLM/model/`, and build SwiftPM with:

```bash
PHOTOSORTER_ENABLE_LOCAL_FASTVLM=1 swift test --filter PhotoSorterFastVLMLiveTests
```

For local Xcode live-FastVLM work, use an ignored project copy such as
`Project/PhotoSorter.local.xcodeproj` and keep its FastVLM source/package
references out of the default project.

## Real-Model E2E

PhotoSorter shares the current example provider environment variable names with
MSPPlaygroundApp.

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
