FinderSearch's first downloadable release: a native Mac file browser powered by
[fsearch](https://github.com/noahdunnagan/fsearch), with fuzzy filename search,
four views, tabs, Quick Look, and everyday file operations.

## Install

1. Download **FinderSearch-0.2.0-AppleSilicon.dmg** below.
2. Open the disk image and drag **FinderSearch** into **Applications**.
3. Eject the image and open FinderSearch from Applications.
4. If macOS blocks it, go to **System Settings → Privacy & Security**, click
   **Open Anyway** for FinderSearch, and confirm.
5. For protected folders, enable **Full Disk Access** for FinderSearch, then quit
   and reopen the app. Allow the first search index to build.

**Requires macOS 15 or newer and an Apple Silicon Mac (M1 or later).**
No Xcode, Rust, or separate fsearch installation is needed.

## Release status

This is an early release. The app uses an ad-hoc signature and is **not Developer
ID-signed or notarized by Apple**. It has been checked locally on Apple Silicon;
installation on a second Mac remains unverified. An Intel build is not included.

Search runs locally. Files and search queries are not uploaded.

File operations include copy, move, rename, and Trash. Conflicts refuse overwrites;
there is no merge dialog. Undo history and tabs do not persist after quitting.
Content search, AirDrop, Finder extensions, and saved smart folders are not included.

[Report a bug](https://github.com/zeusinsight/FinderSearch/issues/new) with your macOS
version and reproduction steps. See the [usage guide](https://github.com/zeusinsight/FinderSearch/blob/main/docs/USAGE.md)
for permissions and troubleshooting.

The `.sha256` attachment contains the DMG's SHA-256 checksum.

## Credits and license

FinderSearch is MIT-licensed. The bundled fsearch engine is created by
[Noah Dunnagan](https://github.com/noahdunnagan) and distributed under its MIT license.
Both license notices are included in the app.
