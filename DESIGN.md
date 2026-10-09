---
name: FinderSearch
description: Native macOS Finder-style browser with fast filename search and everyday file workflows.
colors:
  accent: "AccentColor"
  window-background: "Canvas"
  control-background: "ButtonFace"
  primary-text: "CanvasText"
  secondary-text: "GrayText"
  tertiary-text: "GrayText"
  tag-red: "red"
  tag-orange: "orange"
  tag-yellow: "yellow"
  tag-green: "green"
  tag-blue: "blue"
  tag-purple: "purple"
  tag-gray: "gray"
typography:
  file-label:
    fontFamily: "SF Pro (system)"
    fontSize: "12pt"
    fontWeight: 400
  gallery-label:
    fontFamily: "SF Pro (system)"
    fontSize: "11pt"
    fontWeight: 400
  path-status:
    fontFamily: "SF Pro (system)"
    fontSize: "11pt"
    fontWeight: 400
  search-scope:
    fontFamily: "SF Pro (system)"
    fontSize: "12pt"
    fontWeight: 400
  preview-title:
    fontFamily: "SF Pro (system)"
    fontSize: "headline"
    fontWeight: 600
rounded:
  native-control: "platform-defined"
  file-tile: "5pt"
spacing:
  sidebar-ideal: "208pt"
  toolbar-view-switcher: "150pt"
  tab-height: "32pt"
  tab-horizontal: "12pt"
  tab-vertical: "8pt"
  scope-horizontal: "16pt"
  scope-vertical: "7pt"
  icon-grid-padding: "18pt"
  icon-grid-column: "14pt"
  icon-grid-row: "18pt"
  icon-cell: "6pt"
  gallery-strip-height: "115pt"
  path-horizontal: "12pt"
  path-vertical: "6pt"
  status-horizontal: "14pt"
  status-height: "28pt"
components:
  toolbar-search:
    textColor: "{colors.primary-text}"
    typography: "{typography.search-scope}"
    rounded: "{rounded.native-control}"
  scope-bar:
    backgroundColor: "{colors.control-background}"
    textColor: "{colors.secondary-text}"
    typography: "{typography.search-scope}"
    padding: "7pt 16pt"
  view-switcher:
    width: "150pt"
    size: "segmented"
  tab-bar:
    backgroundColor: "{colors.window-background}"
    textColor: "{colors.primary-text}"
    height: "32pt"
    padding: "8pt 12pt"
  icon-tile:
    textColor: "{colors.primary-text}"
    typography: "{typography.file-label}"
    rounded: "{rounded.file-tile}"
    padding: "6pt"
  path-bar:
    backgroundColor: "{colors.window-background}"
    textColor: "{colors.secondary-text}"
    typography: "{typography.path-status}"
    padding: "6pt 12pt"
  status-bar:
    backgroundColor: "{colors.window-background}"
    textColor: "{colors.secondary-text}"
    typography: "{typography.path-status}"
    height: "28pt"
---

# Design System: FinderSearch

## Overview

**Creative North Star: "Finder, in the System Voice"**

FinderSearch is a native macOS file browser with Finder’s familiar structure and everyday file workflows: a sidebar, unified toolbar, tabs, path and status bars, and four file views. It keeps the operating system’s visual language intact through SwiftUI/AppKit controls, SF Pro system typography, semantic system colors, SF Symbols, and real macOS file icons and thumbnails. Fast fuzzy filename search is part of the browser rather than a separate surface.

The interface is dense enough for file work while keeping location, selection, errors, and current view visible. Browsing uses the same surfaces as searching: icon tiles, a sortable list table, columns, or a gallery with Quick Look. The design records the current everyday workflow scope; it does not claim full advanced Finder parity.

**Key Characteristics:**
- Native Finder-style chrome with a sidebar, unified toolbar, tabs, and path/status bars.
- Four interchangeable file surfaces: icons, list, columns, and gallery.
- Real file icons/thumbnails, system typography/colors, and familiar keyboard actions.
- Search integrated into the toolbar with a 300ms typing debounce.

## Colors

The palette comes from macOS semantic surfaces and the user’s system accent. FinderSearch uses `windowBackgroundColor` for window-level bars, `controlBackgroundColor` for toolbar and error surfaces, `.secondary`/`.tertiary` for supporting text, `.accentColor` for selection and emphasis, and the seven native tag colors.

### Primary
- **macOS Accent** (`AccentColor`): Selection emphasis, active search-scope button tint, and selected icon/gallery tile backgrounds at the implemented opacity.

### Neutral
- **Window Background** (`Canvas`): Tab, path, and status bar surfaces.
- **Control Background** (`ButtonFace`): Search-scope bar and error banner surfaces.
- **Primary Text** (`CanvasText`): File names, toolbar labels, and navigation text.
- **Secondary Text** (`GrayText`): Dates, sizes, kinds, status counts, and supporting labels.
- **Tertiary Text** (`GrayText`): Path separators and low-emphasis navigation details.

### Tags
- **Red, Orange, Yellow, Green, Blue, Purple, Gray** (`red`, `orange`, `yellow`, `green`, `blue`, `purple`, `gray`): Sidebar tag labels and the Tags menu.

**The System Surface Rule.** Use macOS semantic colors and let the operating system resolve light/dark appearance and accent variants.

## Typography

**Display Font:** None; FinderSearch has no display treatment.
**Body Font:** SF Pro system typography.
**Label/Mono Font:** SF Pro system typography, with monospaced digits for search timing.

**Character:** Compact, legible, and familiar. The hierarchy comes from native system sizes and weights rather than a branded typeface.

### Hierarchy
- **File Label** (regular, 12pt): Icon-tile names, table rows, and column-browser items.
- **Gallery Label** (regular, 11pt): Thumbnail-strip names.
- **Path and Status** (regular, 11pt): Breadcrumbs, item counts, selection counts, and icon-size controls.
- **Search Scope** (regular, 12pt): Toolbar search-scope controls and file-kind picker.
- **Preview Title** (system headline): The Quick Look sheet’s filename.

**The System Type Rule.** Keep SF Pro system typography and the exact local weights already used by the SwiftUI views; do not introduce a display face.

## Layout

The window opens at 1050 × 680pt with an 850 × 470pt minimum and a unified toolbar. `NavigationSplitView` keeps the sidebar between 170pt and 280pt wide, with 208pt as its ideal width. Sidebar sections are Recents, Favorites, Locations, and Tags; mounted volumes and iCloud Drive appear under Locations. Full Disk Access status sits in the sidebar’s bottom safe-area inset when required.

The detail pane stacks an optional 32pt tab bar, the toolbar search field, an optional search-scope bar, an error banner, the active file surface, a horizontal path bar, and a 28pt status bar. The toolbar has back/forward controls, a 150pt segmented view switcher, sorting, sharing, tags, and actions. The scope bar uses 16pt horizontal and 7pt vertical inset, 10pt internal spacing, and a 130pt kind picker. Search waits for 300ms of typing inactivity before querying; search results use the table in column mode.

The four views retain their exact local density. Icon view starts at 64pt icons and exposes a 40–96pt slider with a 100pt track; its adaptive grid uses 14pt columns, 18pt rows, and 18pt outer padding. Icon labels are 12pt, centered, and capped at two lines. List view is a native AppKit `NSTableView` with fixed 24pt rows and reusable cells with 12pt text, 16pt file icons, and Name, Date Modified, Size, and Kind columns. Columns use 235pt item columns and a 240pt file preview column. Gallery uses a full preview, an 115pt thumbnail strip, 64pt thumbnails, 11pt labels, and 100pt label width.

Focus is explicit across the browser. Command-F focuses the toolbar search and sorts by relevance. With results present, Down Arrow moves focus into the file surface and selects the first sorted result. Grid and gallery keyboard navigation scrolls the focused item into view; Shift-arrow extends or shrinks a contiguous range from its original anchor. In icon and gallery views, arrow keys move by one item or by the current grid column count; Shift extends selection and Command toggles it. Space opens Quick Look, Return renames the focused item, Escape clears selection, and Command-Down opens the selected item. Standard commands cover Command-O, Command-Y, Command-I, Command-D, Delete, Shift-Command-G, and the view shortcuts 1–4.

## Elevation & Depth

FinderSearch has no app-defined shadows or gradients. Depth comes from macOS window and control backgrounds, unified toolbar treatment, native sidebar/list materials, Dividers, selected-tile accent opacity, and the Quick Look sheet. The only custom shape is the 5pt radius on selected icon and gallery tiles; controls remain platform-defined.

**The Native Depth Rule.** Use SwiftUI/AppKit surfaces, system separators, and native selection states; do not add ornamental panels or custom drop shadows.

## Shapes

Toolbar controls, menus, lists, tables, sheets, and buttons use the system control shape. Icon and gallery cells use a 5pt rounded rectangle for the selected accent surface and otherwise remain clear. Path and status bars are flat horizontal bands separated by a system Divider. The design has no custom pills, border system, or card radius scale.

## Components

### Sidebar
- **Style:** Native `NavigationSplitView` sidebar with Recents, Favorites, Locations, and Tags sections.
- **Content:** SF Symbol labels, mounted-volume rows, custom favorites, seven colored tag rows, and the Full Disk Access action in the bottom inset.
- **State:** The system selection state tracks the current route; favorite rows expose Remove from Sidebar in a context menu.

### Unified Toolbar and Search
- **Style:** Unified macOS toolbar with back/forward `ControlGroup`, segmented view picker, sort menu, ShareLink, tag menu, and actions menu.
- **Search:** Native `.searchable` field with “Search” prompt, 12pt scope controls, This Mac/current-folder buttons, and a 130pt kind picker.
- **State:** Search switches sorting to relevance and applies the 300ms debounce; clearing restores the cached browsing view and sort order while refreshing in the background. Errors use a control-background banner with a dismiss symbol.

### Tabs
- **Style:** Tabs appear when more than one tab exists, with 32pt height, 8pt internal vertical padding, 12pt horizontal padding, plain title/close buttons, a selected control background, and a plus action.
- **Behavior:** New Window, New Tab, and close-tab actions follow native macOS conventions.

### Icon View
- **Style:** Scrollable adaptive grid with real `FileThumbnail` content, 64pt default icons, 12pt two-line labels, 5pt selection tile radius, drag/drop, and context menus.
- **Controls:** A status-bar slider ranges from 40pt to 96pt and uses an exact 100pt width.

### List View
- **Style:** Native AppKit table with fixed 24pt rows, reusable cells, 16pt file icons, 12pt text, sortable Name, Date Modified, Size, and Kind columns, and selection/context-menu/primary-open behavior.

### Column View
- **Style:** Horizontally scrolling 235pt columns with 16pt file icons, 12pt names, folder chevrons, and a 240pt preview column using 120pt thumbnails.
- **State:** Selecting a folder appends its next column; selecting a file shows its preview. Search uses the list table in this mode.

### Gallery View
- **Style:** AppKit Quick Look preview above a lazy 115pt horizontal thumbnail strip. Thumbnails are 64pt, labels are 11pt in a 100pt frame, and selected cells use the same 5pt accent tile.

### Path and Status Bars
- **Path:** Horizontal breadcrumb strip with 11pt text, 11pt SF Symbols, 8pt chevrons, 5pt item spacing, and 12pt/6pt inset.
- **Status:** 11pt secondary text in a 28pt window-background bar, with progress, item/selection count, monospaced search timing, and the 40–96pt icon slider.

### Loading
- **Style:** Static system-color skeletons follow the current list, icon, column, or gallery layout while an uncached listing loads. They use one Canvas drawing pass, expose “Loading files” to accessibility, and accept no file interactions.
- **Behavior:** Cached folders remain immediately visible during refresh. In column view only the loading child column uses placeholders; parent columns remain usable. Empty-folder messaging appears after loading completes.

### Quick Look Sheet
- **Style:** Native sheet with headline filename, Open and cancelable Done actions, Divider, and AppKit `QLPreviewView` at a 650 × 470pt minimum.

## Do's and Don'ts

### Do:
- **Do** preserve Finder’s native structure, system colors, SF Pro typography, SF Symbols, real file icons, and Quick Look thumbnails.
- **Do** keep browsing, search, icon/list/column/gallery views, tabs, path, status, selection, and errors visible in their native surfaces.
- **Do** keep exact density tokens: 1050 × 680pt default, 850 × 470pt minimum, 208pt ideal sidebar, 64pt default icons, 40–96pt icon slider, 12pt file labels/list text, and 11pt footer/path text.
- **Do** retain the explicit keyboard focus path from toolbar search to the first result and through native file-selection actions.
- **Do** keep everyday file actions recoverable and native: undo/redo, copy/paste/move, duplicate, rename, new folder, tags, info, sharing, and Trash.

### Don't:
- **Don't** invent a custom visual identity, branded font, fixed hex palette, gradient, or shadow system.
- **Don't** remove or prohibit browsing, grids, columns, gallery, tabs, or Finder-style file workflows; they are part of the shipped surface.
- **Don't** describe this prototype as full advanced Finder parity; keep guidance within the everyday workflow scope.
- **Don't** hide location, selection, index coverage, errors, or the current file view.
