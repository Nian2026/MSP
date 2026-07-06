# iOS Examples

This directory contains the two public iOS example apps for Model Shell Protocol.

## Requirements

- Xcode with an iOS SDK that can build the checked-in app targets.
- An iPhone or iPad that can run `IPHONEOS_DEPLOYMENT_TARGET = 26.0`.
- An Apple development team for direct device runs.
- Network access on first device build if the local BeeWare CPython iOS cache has
  not already been populated.

## One-Time Device Setup

From the repository root:

```sh
Examples/iOS/Tools/bootstrap-ios-examples.sh \
  --team ABCDE12345 \
  --bundle-prefix com.yourname.msp
```

The script writes ignored local signing settings to
`Examples/iOS/Shared/Signing/ExampleSigning.local.xcconfig` and prepares the
CPython iOS cache used by the app build phases. The checked-in projects do not
contain a personal signing team or provisioning profile.

## Apps

- `MSPPlaygroundApp` is the lightweight app-loop example for chat, transcript
  state, workspace browsing, command execution, and app-owned runtime
  boundaries.
- `PhotoSorter` is the Photos workspace example. It projects the iOS Photos
  Library into MSP workspace paths and requires Photos permission for the
  product-shaped demo.

Open the checked-in projects directly:

```sh
open Examples/iOS/MSPPlaygroundApp/Project/MSPPlaygroundApp.xcodeproj
open Examples/iOS/PhotoSorter/Project/PhotoSorter.xcodeproj
```

Each app has its own README with local test commands, optional real-model E2E
checks, and CPython packaging notes.
