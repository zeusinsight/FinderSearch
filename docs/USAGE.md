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
as well. Permissions may need refreshing after a rebuild. FinderSearch restarts
a restricted search daemon from the same helper executable once per app session
after detecting Full Disk Access. The existing index is kept; the engine rescans
previously skipped folders. A daemon belonging to another fsearch installation
is left running; quit that installation before reopening FinderSearch.

The first launch builds an index; searches become available as indexing progresses.
Updating to fsearch 0.2 automatically rebuilds the older index format. FinderSearch
restarts its own daemon when the helper has been replaced since that daemon started.
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

### Dropbox and other cloud folders

Filename search includes locally enumerable files under
`~/Library/CloudStorage`, including Dropbox, when the search helper has Full Disk
Access. No Dropbox account connection or custom index path is required. Use
**Go → Go to Folder…** to browse your provider's folder, then search within it.

If cloud files are missing, grant Full Disk Access and reopen FinderSearch. If
necessary, also grant access to the bundled helper as described above. Cloud-only
folders that the provider has not made available locally may not be enumerable;
make the folder available offline in the provider and search again. Indexing does
not intentionally download cloud file contents.

## Usage

- **Browse:** icons, sortable list, columns, and gallery via Command-1 through Command-4.
  Back/forward/up navigation, a path bar, favorites, mounted volumes, and iCloud's local folder.
  Eject buttons beside external/removable volumes and disk images safely unmount them.
  Right-click empty space for New Folder, New Text File, Paste, view options, and Refresh; right-click
  files for their actions in every view, including columns and gallery.
  Rename edits the name in place: Return saves, Escape or clicking away cancels.
  Files initially select their name without the extension; folders select the whole name.
  Creating a folder or text file immediately starts inline rename. Select multiple items
  and choose Rename for Replace Text, Add Text, or Numbered Names with a preview.
  Tabs restore folders, view modes, sorting, selection, and scroll positions on relaunch.
- **Search:** Command-F; requests begin 50 ms after typing stops; Return submits a pending search immediately. Search This Mac or
  the current folder, with kind filters. Obsolete requests are cancelled and stale
  replies ignored. Up to 500 matches are shown; column-mode search uses the list.
- **Filters:** filename filters such as `ext:pdf` and `mtime:<7d` work. The UI does not
  yet support content-query syntax. Footer timing measures engine work, excluding
  debounce, IPC, and rendering.
- **Select and preview:** click, Command-click, or Shift-click; double-click or
  Command-O opens, Space/Command-Y uses Quick Look, and Return renames.
  In Quick Look, arrow keys browse the current selection (or visible files); Space closes it.
- **File actions:** Command-C copies file URLs, Command-V copies items, and
  Option-Command-V moves them. Folder drops move; Option-drag copies. Conflicts
  offer Replace, Keep Both, or Skip, with an apply-to-all option. Replace preserves
  the old item in Trash for Undo. Long operations show progress and a Cancel button;
  cancellation retains completed items and restores interrupted replacements.
  Command-Shift-N creates a uniquely named folder. Hover over a folder while dragging
  to open it after a short delay.
- **Trash and undo:** Command-Delete moves selected files to recoverable Trash;
  while editing text it remains a text-editing command. Command-Z and
  Shift-Command-Z undo/redo file actions and tags. History is in memory per tab.
- **Other actions:** Get Info, Duplicate, Copy Path, tags, sharing, and revealing in Finder.
  Open With lists compatible applications and offers an application chooser.
  Compress creates a ZIP; Extract ZIP creates a uniquely named folder beside the archive.
  Standard, unencrypted ZIPs are supported; ZIP64, symbolic links, and special files are rejected.
  Command-T creates a tab; drag tabs to reorder, middle-click to close, and Command-Shift-T
  reopens the last closed tab. Command-N creates a window; Command-Shift-G opens Go to Folder.
  Command-Shift-period toggles hidden files; Command-R refreshes.
- **Go shortcuts:** Command-Shift-F opens Recents; Command-Shift-O Documents;
  Command-Shift-D Desktop; Option-Command-L Downloads; Command-Shift-H Home;
  Command-Shift-L Library; Command-Shift-A Applications; Command-Shift-U Utilities.
  Option-Command-O opens the folder chooser. Go menu destinations use the same
  navigation as the sidebar.

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
Local child folders are prefetched in bounded batches, and hovering a folder in
icon or column view prepares its contents. Cached or prefetched contents appear
immediately on navigation and refresh from disk. On an uncached first visit,
the loading view appears immediately, then a lightweight directory listing shows
filenames and basic folder kinds before dates and sizes finish loading. Pending
details show a dash rather than invented values, and selection survives the refresh.
Known network/cloud locations and protected home folders without Full Disk Access
are excluded from speculative prefetching.

Rename, move, and Trash update the visible listing immediately while the operation
runs. Known copies and new folders can also appear immediately. Pending operations
keep the busy indicator visible and block further writes and opens. Failed items
return to their original state with an error; successful items retain undo even
when other items in the batch fail. A background listing confirms the final result.
Unique-name checks, transfer validation, and tag reads run in the background;
the busy indicator covers this preparation as well as the write itself.

List view uses reusable, fixed-height AppKit rows. Icons load on a background queue
with bounded concurrency and caching; gallery thumbnails load lazily and are cached.
Folder and search results are sorted in the background before display, with
filenames and file types prepared once per sort. Changing the sort keeps current
rows visible until the new order is ready; abandoned sorts cannot replace newer
results. Get Info and Spotlight tag results also load file metadata off the UI thread.
Leaving a view cancels pending
icon work and Quick Look thumbnail requests. Column folders open on the first
selection without waiting for a possible double-click.
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
smart folders, cloud-management UI, or persistent undo history.
Column ancestors remain snapshots until revisited. New Text File creates an empty
`untitled.txt` with a unique name. Folder replacement replaces the whole folder; it does not merge contents.
Full keyboard/multi-drag parity remains in progress.

## Credits

The search engine is [fsearch](https://github.com/noahdunnagan/fsearch), created by
**Noah Dunnagan**, distributed under the MIT license and vendored unmodified at
`e96ebeb52545ea4facd4a4b3af393c42c980fb5d`.
See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and [its license](../vendor/fsearch/LICENSE).

### Drag selection

In icon view or the gallery strip, drag from empty space to draw a selection box.
In list view, start below the rows and drag upward to select them. Hold Shift to
add to the selection or Command to toggle the enclosed files. Escape cancels the
gesture and restores the previous selection. Drag toward the edge to scroll.
Starting a drag on a file keeps the normal file drag-and-drop behavior.

### Cut and paste files

Select files or folders and press **Cmd+X**, then navigate to the destination and
press **Cmd+V**. Cut items appear dimmed in every view and stay in their original location until
the move succeeds.
Conflicts use the normal move dialog, and **Cmd+Z** undoes a completed move.
Failed or skipped items remain pending for another paste. Copying something else
cancels the pending cut. This cut intent applies within FinderSearch, including
across its tabs and windows; other apps receive ordinary file URLs.

### Mouse navigation and sidebar favorites

Use your mouse’s Back and Forward buttons to navigate the current tab, just like
the toolbar buttons. Standard side-button events are supported; a mouse utility
that remaps them to another action may need its mapping adjusted.

**Sync Finder Favorites** in Settings is off by default. Enable it to import the
ordinary folders and their order from Finder immediately and when a window opens.
The switch is saved across restarts. Turning it off keeps the current sidebar
and stops automatic imports. Virtual destinations, saved searches, files, and
application packages aren't imported. This is one-way: FinderSearch never changes Finder's
favorites. If reading Finder fails, the last sidebar stays available; previously
synced offline folders keep their cached positions. The original local list is
saved in the app's preferences before the first successful sync.

Drag folders from the file view or Finder onto the sidebar to add local favorites.
Files and application packages are ignored, and the folders stay in their original location.
Drag folders within **Favorites** to reorder them. A floating row preview follows
your mouse, and a blue insertion marker shows where it will land. Press **Esc**
to cancel a drag. Right-click a favorite for
**Open**, **Open in New Tab**, **Reveal in Finder**, or **Remove from Sidebar**.
Removing a shortcut does not delete the folder. Local edits are saved and shared
between windows and restarts. With sync enabled, a newly opened window follows
Finder again. For lasting changes to the synchronized list, edit the favorites
in Finder.
To restore a removed folder, browse to it and choose **Add Folder to Sidebar**.
Right-click locations for navigation actions and, where available, **Eject**.

Finder tag colors appear beside file names in every view. Tags assigned in FinderSearch and Undo update
the indicators immediately; hover over the dots to see the tag names.
Go to Folder supports **Cmd+A**, **Cmd+C**, **Cmd+X**, **Cmd+V**, and Undo/Redo.
