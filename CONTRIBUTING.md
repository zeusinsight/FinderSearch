# Contributing

See [README.md](README.md) for build requirements, permissions, and running the app.
FinderSearch is an early macOS prototype; keep changes focused and describe how
they were verified.

## Code layout

- `App.swift`: app entry point, commands, toolbar, sidebar, and file-view composition.
- `Model.swift`: per-tab navigation, selection, cached snapshots, search scheduling,
  folder observation, and file-operation history.
- `Engine.swift`: fsearch JSON-lines client, reply types, cancellation, and timeouts.
- `FileSystem.swift`: local directory enumeration, file mutations, icons, and previews.
- `FileList.swift`: native fixed-height AppKit table and its selection/drop handling.
- `SessionState.swift`, `BrowserTabBar.swift`, and `TabControls.swift`: session snapshots, tab UI, and native tab interactions.
- `FileOperationControl.swift` and `FileTransfers.swift`: cancellation, native copies,
  progress, and explicit conflict choices.
- `ArchiveFiles.swift` and `BatchRename.swift`: staged archive and rename transactions.
- `OpenWith.swift`, `QuickLookBrowser.swift`, and `SpringLoading.swift`: shared file UX.
- `FileViews.swift`: thumbnails, grid-adjacent components, column/gallery views, and drops.
- `FolderLoadingSkeleton.swift`: inexpensive placeholders for uncached listings.
- `Tests/FinderSearchTests`: file-operation, search, and responsiveness regressions.

App source lives under `Sources/FinderSearch`. Keep blocking filesystem work off
the main thread. Search edits must cancel obsolete requests and ignore stale
replies. File mutations must refuse silent overwrites and preserve undo for
successful operations, including partial batches.

## Checks

```sh
swift test -c release
./scripts/build.sh
```

For real engine integration, launch the app, wait for indexing, then run:

```sh
python3 scripts/verify_engine.py
```

Tests create isolated files. The engine checks need a running daemon and permission
to index the current user's home folder. Check affected native interactions manually,
especially keyboard focus, search clearing, selection, and drag/drop.

When `swift-format` is available in your toolchain:

```sh
swift format format --in-place --recursive Package.swift Sources Tests
swift format lint --strict --recursive Package.swift Sources Tests
```

The root `.swift-format` config defines the app's formatting. Do not format vendored
Rust code. Preserve the upstream revision and license; document any future vendor
update in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Do not commit generated bundles, search indexes, local permissions/settings,
credentials, or screenshots containing personal filenames. Use authored fixtures
for screenshots and bug reproductions.
