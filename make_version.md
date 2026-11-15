# make_version

1. Edit `AppVersion.clientVersionString` and `AppVersion.clientVersionInt` in
   `SmallGit/Sources/SmallGit/Models/AppConfig.swift`.
2. Run `./make_version.sh`, then `./make_version.sh --check`.
3. Build with `SmallGit/scripts/build-app.sh --release` and verify both version
   fields in `release/SmallGit.app/Contents/Info.plist`.
4. Commit the Swift source, synced plist, and `SmallGit/project.yml` together.

The Xcode project, when present, is synced too but stays gitignored.
See [MAKE_VERSION_GUIDE.MD](MAKE_VERSION_GUIDE.MD) for the SwiftPM adaptation.
