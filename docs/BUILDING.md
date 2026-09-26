# Building and releasing Pelican

Apple silicon, macOS 15 or later, Xcode's command-line tools.

## Build from source

Pelican builds against a checkout of [Frigate](https://github.com/rao-studios/Frigate). Point
`FRIGATE_DIR` at it (the default is a sibling at `../../rao/repositories/Frigate`).

```bash
git clone https://github.com/rao-studios/Frigate.git
export FRIGATE_DIR="$PWD/Frigate"

swift build --build-system native
./scripts/build-metallib.sh              # MLX's Metal kernels, next to the binary (once per build)
swift run --build-system native Pelican
swift test --build-system native
```

> **Why `--build-system native`:** SwiftPM's default engine tries to compile Frigate's vendored
> `.metal` sources and fails where the Metal toolchain stub is broken; the native engine has no
> Metal step, and `build-metallib.sh` compiles the shaders with `xcrun`. Set
> `PELICAN_BUILD_SYSTEM=swiftbuild` for the scripts once your toolchain handles it.
>
> **Metal note:** MLX loads `mlx.metallib` from next to the running binary. Without it, inference
> fails with *"Failed to load the default metallib"*; the Model tab shows the fix. From Xcode, run
> `./scripts/build-metallib.sh` after the first build — it copies the metallib into Pelican's
> DerivedData products too.

## Diagnostics

All headless:

| Command | Shows |
|---|---|
| `Pelican --capture-probe 15 curl` | every flow opened and closed, optionally for one process name |
| `Pelican --identity sewn-server` | a process's path, bundle and code signature as macOS reports it (a pid, a name, or an app path) |
| `Pelican --trust-probe 20` | Ambient's trust level, processes, findings and the day's report |
| `Pelican --snapshot rao.png 10` | the Rao screen rendered offscreen at full height |
| `Pelican --selftest` | loads the model and runs one analysis batch |

`PELICAN_LEDGER_DIR=/tmp/ledger` points the ledger somewhere else while experimenting.

## Build the app

No certificates are needed: without an identity, the app is signed ad-hoc.

```bash
./scripts/make-app.sh                 # build/Pelican.app, ad-hoc signed
./scripts/make-app.sh --install       # …and copy it to /Applications
DEVELOPER_ID=1 ./scripts/make-app.sh  # hardened runtime + timestamp, for distribution
swift scripts/gen-app-icon.swift      # redraw the icon (drawn in code — no assets)
```

`build/app-metadata.json` records the version, build, commit, signer and the SHA-256 of the
signed executable. Everything under `build/` is ignored by git; it names the signer, so keep it
out of commits.

## Release

A release is signed with your own Developer ID. The scripts find it in your keychain at run
time; nothing about a team, certificate or notary profile is stored in this repository.

```bash
xcrun notarytool store-credentials <any-name> --apple-id <apple-id> --team-id <team-id>   # once
NOTARY_PROFILE=<any-name> ./scripts/make-pkg.sh
```

`make-pkg.sh` refuses dirty trees, never overwrites a build number, builds and signs the app,
checks it is Developer ID signed with the hardened runtime and a timestamp, packages it
(non-relocatable, arm64, the macOS floor from `Support/Info.plist`), signs the installer,
notarizes and staples both, runs Gatekeeper's assessment, and writes the `.sha256` and a manifest
of every commit and dependency pin. Bump `CFBundleVersion` in `Support/Info.plist` for each build.

| Variable | Meaning | Default |
|---|---|---|
| `SIGN_IDENTITY` | codesigning identity (name or hash) | first "Developer ID Application" in the keychain (`make-pkg.sh`, `DEVELOPER_ID=1`); ad-hoc otherwise |
| `INSTALLER_IDENTITY` | installer signing identity | first "Developer ID Installer" in the keychain |
| `NOTARY_PROFILE` | notarytool keychain profile | none — required unless `SKIP_NOTARIZE=1` |
| `SKIP_NOTARIZE` | stop at the signed, unnotarized pkg | `0` |
| `ALLOW_DIRTY` | build from uncommitted work (dry runs) | `0` |
| `FORCE` | overwrite a pkg of the same build number | `0` |
| `DEVELOPER_ID` | `make-app.sh`: sign for distribution | `0` |
| `FRIGATE_DIR` | the Frigate checkout | `../../rao/repositories/Frigate` |
| `PELICAN_BUILD_SYSTEM` | `swift build --build-system` | `native` |

## Layout

```
Sources/
  Core/
    Capture/   FlowSource, NetworkStatistics events, nettop polling, endpoint formatting
    Identity/  code signatures and process identity (path, bundle, parent, start time)
    Rao/       app profiles, consent detection, attribution, classification, host table,
               identity audit, day ledger + trust level, the trust monitor, reports
    …          AppState, flow models, NetworkMonitor (merges the sources), DNSResolver,
               LLMSession (MLX), ModelStore, AnalysisEngine, Presets, BuildInfo, Probes
  Views/       ContentView (sidebar shell), Rao/ (trust screen, menubar), Connections,
               Processes, Analysis, Model
Support/       Info.plist, entitlements, app icon
scripts/       make-app.sh, make-pkg.sh, build-metallib.sh, gen-app-icon.swift, make-iconset.sh
pkg/           installer Distribution.xml and postinstall
Tests/         PelicanTests (swift-testing)
```
