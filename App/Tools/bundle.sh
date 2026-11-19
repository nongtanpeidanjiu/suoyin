#!/bin/zsh
# Builds the interface skeleton and wraps it in an application bundle.
# Output: App/.build/FileSearchDemo.app (locally signed, for preview only).
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
app=".build/FileSearchDemo.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/SearchApp "$app/Contents/MacOS/SearchApp"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SearchApp</string>
    <key>CFBundleIdentifier</key><string>dev.local.filesearch.demo</string>
    <key>CFBundleName</key><string>文件搜索（预览）</string>
    <key>CFBundleDisplayName</key><string>文件搜索（预览）</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
# A fixed local identity keeps the system's privacy grants (Full Disk Access)
# across rebuilds; fall back to ad-hoc signing where it is not installed.
identity="FileSearch Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$identity"; then
    codesign --force --sign "$identity" "$app" >/dev/null 2>&1
else
    codesign --force --sign - "$app" >/dev/null 2>&1
fi
# `--install` puts a copy where System Settings can find it easily.
if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/文件搜索预览.app"
    cp -R "$app" "$HOME/Applications/文件搜索预览.app"
    echo "$HOME/Applications/文件搜索预览.app"
else
    echo "$PWD/$app"
fi
