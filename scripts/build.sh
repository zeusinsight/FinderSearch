#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "$(uname -s)" != Darwin ]]; then
    print -u2 'FinderSearch requires macOS 15 or newer.'
    exit 1
fi
for tool in cargo swift codesign; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        print -u2 "Missing $tool. Install Xcode development tools and Rust/Cargo; see README.md."
        exit 1
    fi
done
if (( ${$(sw_vers -productVersion)%%.*} < 15 )); then
    print -u2 'FinderSearch requires macOS 15 or newer.'
    exit 1
fi

# Pin dependency resolution and the output location, even when the caller has
# CARGO_TARGET_DIR configured for another project.
cargo build --release --locked --manifest-path vendor/fsearch/Cargo.toml --target-dir vendor/fsearch/target
swift build -c release
swift_bin="$(swift build -c release --show-bin-path)"
app="$PWD/dist/FinderSearch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$swift_bin/FinderSearch" "$app/Contents/MacOS/"
cp vendor/fsearch/target/release/fsearch "$app/Contents/Helpers/"
cp vendor/fsearch/LICENSE "$app/Contents/Resources/fsearch-LICENSE"
if [[ -f LICENSE ]]; then
    cp LICENSE "$app/Contents/Resources/FinderSearch-LICENSE"
fi
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>FinderSearch</string>
<key>CFBundleIdentifier</key><string>local.findersearch.app</string>
<key>CFBundleName</key><string>FinderSearch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>0.2.0</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/Helpers/fsearch"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"
