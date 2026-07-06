# PhotoSorter Vendor Directory

This directory contains PhotoSorter assets that must stay local to the example.
Do not use it as a cache for large third-party package checkouts.

Required local vendor directories:

- `Vendor/ExampleChatTranscriptRenderer`

PhotoSorter consumes MLX through public SwiftPM package references, not local
`Vendor/` symlinks, and only for the optional local FastVLM build:

- `https://github.com/ml-explore/mlx-swift`, exact `0.21.2`
- `https://github.com/ml-explore/mlx-swift-examples`, exact `2.21.2`
- `https://github.com/huggingface/swift-transformers`, exact `0.1.18`

The default open-source package and Xcode project do not include MLX package
products or Swift Transformers package products. If the optional local FastVLM
SwiftPM versions change, update `Package.swift` and the local-only setup notes
in the same patch.

Do not place local `Vendor/mlx-swift` or `Vendor/mlx-swift-examples`
checkouts here. The open-source hygiene gate treats those paths as release
blockers, even when they are ignored by git.

When the package graph is broken, Xcode may report a long cascade of errors
such as:

```text
Missing package product 'MSPAgentBridge'
Missing package product 'ModelShellProxy'
Missing package product 'MLX'
Missing package product 'MLXVLM'
```

Those MSP products usually are not the root cause. The root cause is often that
one package reference failed to resolve and Xcode then collapsed the rest of the
graph. Default Xcode builds should not require the MLX products at all.

Before opening or building the Xcode project after moving files, run:

```bash
Examples/iOS/PhotoSorter/Tools/check-local-packages.sh
```
