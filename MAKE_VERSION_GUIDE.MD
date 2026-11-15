# MAKE_VERSION_GUIDE

SmallGit uses the Swift-source versioning pattern from the j2me project.
Both the marketing version and build number have one editable source.

## Source of truth

Edit `AppVersion` in `SmallGit/Sources/SmallGit/Models/AppConfig.swift`:

```swift
enum AppVersion {
    static let clientVersionString = "26.11.01"
    static let clientVersionInt = 261101
}
```

Keep plain constants in the same declaration so the sync script can parse
them. Use calendar-style release versions and increase the build number for
each submitted build. Values are chosen explicitly; the script never replaces
them with today's date.

## Sync

From the repository root:

```sh
./make_version.sh
./make_version.sh --check
```

The script needs Bash and Python 3. It updates:

- `SmallGit/Info.plist`: `CFBundleShortVersionString`, `CFBundleVersion`.
- `SmallGit/project.yml`: `MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` on
  the app target.
- `SmallGit/SmallGit.xcodeproj/project.pbxproj`, if generated locally: the
  same two settings in every SmallGit app build configuration.

The generated Xcode project remains ignored by Git. Commit the Swift constants,
plist, and `project.yml` together. `--check` makes no changes and fails if
any present metadata is stale or the source cannot be parsed.

## SwiftPM and Xcode

SmallGit shares one manual `Info.plist` across both build systems. SwiftPM
embeds it directly into the executable's `__TEXT,__info_plist` section and
does not expand Xcode build variables. Therefore this project's plist keeps
concrete synced values instead of `$(MARKETING_VERSION)` and
`$(CURRENT_PROJECT_VERSION)` placeholders. Xcode's build settings carry the
same values.

`build-app.sh`, `build-dmg.sh`, and `xcode.sh` sync before building or generating
metadata. CI and `test-ui.sh` use `--check` so forgotten syncs fail clearly.
For a direct `swift build` or Xcode build, run the sync command first.

## Runtime and verification

UI and diagnostics should read `Bundle.main`'s `CFBundleShortVersionString`
and `CFBundleVersion`, rather than displaying the Swift constants directly.
The standard macOS About panel already reads bundle metadata.

```sh
SmallGit/scripts/build-app.sh --release
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' release/SmallGit.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' release/SmallGit.app/Contents/Info.plist
```

Verify the bundle and embedded plist agree with the Swift constants, and that
the release executable is stripped with no `.dSYM` or `__DWARF` content in
the bundle. Do not create a DMG unless one is requested. Version sync and a
local release build do not create a tag, push code, or publish a release.
