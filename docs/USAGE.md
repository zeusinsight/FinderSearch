# FinderSearch

A native macOS file browser with fast fuzzy filename search, powered by
[fsearch](https://github.com/noahdunnagan/fsearch) by Noah Dunnagan.

FinderSearch brings indexed search into a familiar Finder-style interface:
sidebar navigation, four file views, tabs, Quick Look, and everyday file actions.
It is an early prototype, with incomplete Finder parity and no OS-shell replacement.

## Requirements

- macOS 15 or newer.
- An Apple Silicon Mac for the downloadable release.

Download the `.dmg` from [GitHub Releases](https://github.com/zeusinsight/FinderSearch/releases/latest),
drag FinderSearch into Applications, eject the image, and open the app. If macOS
blocks it, use **System Settings → Privacy & Security → Open Anyway** for FinderSearch.
The release is ad-hoc signed, not Developer ID-signed or notarized by Apple.

Building from source additionally requires:

- Xcode 16 or newer, or compatible Command Line Tools with the macOS 15 SDK.
- Rust/Cargo with support for Rust edition 2024 (Rust 1.85 or newer).
- Python 3 only for optional engine verification and index maintenance.

The build produces an app for the host architecture. The current locally verified
build is Apple Silicon; Intel and clean second-Mac installation have not been verified.

## Build and run

After cloning this repository, run from its root:

```sh
./scripts/build.sh
open dist/FinderSearch.app
```

The script builds the vendored engine with its lockfile, builds the native app,
embeds the helper and upstream license, and verifies its ad-hoc signature.
The first Rust build downloads dependencies. A separate fsearch installation
is not required.

Quit and reopen the app after rebuilding. `dist/` and build caches are generated
locally and excluded from version control.

To build a disk image with the app, an Applications shortcut, installation
instructions, and a SHA-256 checksum:

```sh
./scripts/package-dmg.sh
```

The image is written to `dist/` and labeled with the build architecture.

## Permissions and indexing

For protected folders such as Documents, grant the app **Full Disk Access** in
System Settings → Privacy & Security → Full Disk Access, then quit and reopen it.
If the helper does not inherit the grant, add `FinderSearch.app/Contents/Helpers/fsearch`
as well. Permissions may need refreshing after a rebuild.

The first launch builds an index; searches become available as indexing progresses.
The engine keeps its index in `~/Library/Application Support/FSearch`, and its daemon
can remain running after the UI closes. The app does not install a login item.
Searches and file data stay on the Mac; the app does not upload them.

All fsearch installations for the current user share the index directory. If a fresh
crawl is necessary after changing permissions, quit FinderSearch and other fsearch
installations, then run:

```sh
python3 scripts/reindex.py
```

The script stops this project's daemon and moves the old index to a timestamped
backup before the next launch. It refuses to proceed when it detects a running app
or a daemon from another installation. It does not delete the backup.

Protected folders, network volumes, unmounted drives, and cloud providers still
obey macOS permissions and availability. Thumbnails skip undownloaded cloud files;
opening or previewing a cloud file may trigger a provider download.

## Usage

- **Browse:** icons, sortable list, columns, and gallery via Command-1 through Command-4.
  Back/forward/up navigation, a path bar, favorites, mounted volumes, and iCloud's local folder.
- **Search:** Command-F; requests begin 300 ms after typing stops. Search This Mac or
  the current folder, with kind filters. Obsolete requests are cancelled and stale
  replies ignored. Up to 500 matches are shown; column-mode search uses the list.
- **Filters:** filename filters such as `ext:pdf` and `mtime:<7d` work. The UI does not
  yet support content-query syntax. Footer timing measures engine work, excluding
  debounce, IPC, and rendering.
- **Select and preview:** click, Command-click, or Shift-click; double-click or
  Command-O opens, Space/Command-Y uses Quick Look, and Return renames.
- **File actions:** Command-C copies file URLs, Command-V copies items, and
  Option-Command-V moves them. Folder drops move; Option-drag copies. Conflicts
  report an error without overwriting. Command-Shift-N creates a uniquely named folder.
- **Trash and undo:** Command-Delete moves selected files to recoverable Trash;
  while editing text it remains a text-editing command. Command-Z and
  Shift-Command-Z undo/redo file actions and tags. History is in memory per tab.
- **Other actions:** Get Info, Duplicate, Copy Path, tags, sharing, and revealing in Finder.
  Command-T creates a tab; Command-N creates a window; Command-Shift-G opens Go to Folder.
  Command-Shift-period toggles hidden files; Command-R refreshes.

Recents uses indexed files modified within 30 days, limited to 1,000 returned
candidates. Tags use Spotlight metadata and depend on its coverage. Search,
Recents, and tag results do not accept writes into an ambiguous destination.
File mutations run off the UI thread; additional writes are blocked while busy.
Partial failures retain undo for successful operations, and failed restores remain retryable.

## Responsiveness

Recent folder listings and their selections are cached per tab and refreshed in the
background. Clearing a search restores the browsing snapshot and sort immediately.
Uncached listings show inexpensive layout-matched skeletons until loading completes.
Each tab retains up to eight snapshots, evicting older entries above a 40,000-item
budget (a single larger view remains available).

List view uses reusable, fixed-height AppKit rows. Icons load on a background queue
with bounded concurrency and caching; gallery thumbnails load lazily and are cached.
Folder-event bursts are coalesced, and obsolete enumeration is cancelled cooperatively.
Engine cancellation releases the stdio client; it does not interrupt daemon computation
or a blocked filesystem call. Cold folders and slow volumes can still take time.

## Validation and contributions

```sh
swift test -c release
python3 scripts/verify_engine.py
```

Engine checks require a running app/daemon and an indexed home folder; they create
and remove isolated fixtures. Swift tests cover file-operation safety, undo,
selection, debounce/cancellation, cached navigation, and native table restoration.
Performance budgets measure model/table update work, not universal frame rate or
complete paint latency.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for code layout, formatting, and verification.
[PRODUCT.md](../PRODUCT.md) records the product scope; [DESIGN.md](../DESIGN.md) records
native interface conventions.

## Known limitations

No Finder extensions, AirDrop integration, disclosure rows, advanced grouping,
batch rename, smart folders, cloud-management UI, or persistent session/undo state.
Column ancestors remain snapshots until revisited. New Folder/Rename use dialogs
rather than inline editing. Clipboard/drop conflicts have no merge/overwrite dialog.
Full keyboard/multi-drag parity remains in progress.

## Credits

The search engine is [fsearch](https://github.com/noahdunnagan/fsearch), created by
**Noah Dunnagan**, distributed under the MIT license and vendored unmodified at
`af9476d39ec98108552670adf6badbbd77331b0a`.
See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and [its license](../vendor/fsearch/LICENSE).
