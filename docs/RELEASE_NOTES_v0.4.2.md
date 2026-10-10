## What’s new

- Reduced combined icon and thumbnail cache budgets from 256 MB to 64 MB.
- Sized thumbnails to their display size and screen scale, using 75% less bitmap memory for 64-point filmstrip thumbnails on Retina displays.
- Released images when cells disappear and prevented cancelled requests from repopulating the thumbnail cache.
- Kept separate cached resolutions so small thumbnails never replace larger previews.

Actual memory savings depend on browsing history and cache usage. All 82 release-mode tests passed.

## Install

Download the Apple Silicon DMG below, quit FinderSearch, and replace the app in Applications. Requires macOS 15 or newer.

The app is not yet notarized. If macOS blocks it, use **System Settings → Privacy & Security → Open Anyway**.
