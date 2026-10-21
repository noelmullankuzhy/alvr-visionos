# ALVR for Apple visionOS

This repository hosts the platform-specific code for the Apple visionOS client.

## Building

See the [Building](https://github.com/alvr-org/alvr-visionos/wiki/Building) wiki page for detailed instructions.

## Lumen build (personal)

Signs the client for the Lumen team (`uk.lumenio.alvr`, app group `group.uk.lumenio.alvr`) with no edits in Xcode.
An upstream-style build (no `Override.xcconfig`) keeps `alvr.client` / `group.alvr.client.ALVR`.

```sh
sh tools/use-lumen-signing.sh
xcodebuild -project ALVRClient.xcodeproj -scheme ALVRClient -destination 'generic/platform=visionOS' -allowProvisioningUpdates build
```

The first command writes a local, gitignored `Override.xcconfig` containing `#include "Lumen.xcconfig"`. It is
idempotent and refuses to overwrite a different existing Override.

### Simulator flow

1. Build the Rust core and repack the xcframework: `sh build_and_repack.sh`.
2. Build for the simulator: `xcodebuild -project ALVRClient.xcodeproj -scheme ALVRClient -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build`.
3. Ad-hoc codesign the built app and its embedded frameworks (`codesign --force --sign - <path>` on each framework in
   `ALVRClient.app/Frameworks`, then on `ALVRClient.app`). Unsigned builds fail in dyld ("unsigned library").
