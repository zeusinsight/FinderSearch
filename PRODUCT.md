# FinderSearch
<!-- impeccable:product-schema 1 -->

## Platform
Native macOS desktop app, macOS 15 or newer.

## Stack
SwiftUI/AppKit and Quick Look; Rust fsearch via persistent JSON-lines connection.

## Users and Purpose
A Mac user frustrated by Finder search speed and accuracy. The app should offer Finder's familiar browsing and everyday file workflows, retaining fast fuzzy filename search.

## Capabilities and Constraints
Finder-style unified toolbar, sidebar, real file icons/thumbnails, icon/list/column/gallery views, sortable columns, path/status bars, tabs, back/forward/up navigation, favorites, mounted volumes and iCloud folder browsing. Everyday actions: open, Quick Look, rename, copy/paste/move, duplicate, new folder, recoverable Trash, tags, undo/redo, info and sharing. File mutations run off the UI thread and refuse overwrites; undo retains failed restore operations so they can be retried.

Recent folder views and their selections are cached per tab for immediate back/forward navigation and search clearing, followed by a background refresh. Icons use bounded background loading; gallery thumbnails are lazy and reused across views. Keyboard grid/gallery navigation keeps the focused item visible, with anchored Shift ranges.

Filename search uses fsearch relevance and filters. It waits for 300 ms of typing inactivity, cancels pending searches and rejects stale replies. Search in column mode uses the results table. Full Disk Access is required to index protected folders. Protected folders and cloud availability still depend on OS permissions and provider state. Tags use native metadata indexing, separate from filename search. Recents is a modified-within-30-days view, limited to the returned candidates.

## Brand Commitment
Follow Finder's native appearance and interaction conventions. Preserve macOS semantic colors, system typography, SF Symbols, native file icons and familiar density; do not invent a visual identity.

## Product Principles
- Familiar browsing with fast, accurate search.
- No silent overwrites; retain undo for successful file actions.
- Keep locations, selection and errors visible.
- Native keyboard conventions and system appearance.

## Open Decisions and Limits
The working name is provisional. Full OS-shell replacement is not available. AirDrop integration, Finder extension menus, folder disclosure rows, advanced grouping, batch rename, cloud management, saved smart folders and persistent session restoration remain beyond the current build. The current scope covers everyday file workflows.
