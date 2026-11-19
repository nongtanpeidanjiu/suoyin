#!/bin/zsh
# Builds the interface and wraps it in an application bundle.
# Output: App/.build/FileSearchDemo.app (locally signed).
#
#   bundle.sh             预览版：显示名“索隐（预览）”，打开测试入口（FSTestHooksEnabled）
#   bundle.sh --install   预览版，并复制到 ~/Applications/文件搜索预览.app
#   bundle.sh --release   正式版：显示名“索隐”，不带测试入口；只打包，不能与 --install 同用
set -euo pipefail
cd "$(dirname "$0")/.."

release=false
install=false
for argument in "$@"; do
    case "$argument" in
        --release) release=true ;;
        --install) install=true ;;
        *) echo "未知参数：$argument" >&2; exit 2 ;;
    esac
done
if $release && $install; then
    # 正式版与预览版包标识相同，安装会覆盖用户正在使用的预览版。
    echo "--release 不能与 --install 同时使用。" >&2
    exit 2
fi

if $release; then
    display_name="索隐"
    plist_display_name="索隐"
    test_hooks=""
else
    display_name="索隐（预览）"
    # 访达和系统设置只在包的文件名与 Info.plist 里（未本地化的）
    # CFBundleDisplayName 相同时才采用本地化表里的显示名，否则当作用户改过名、
    # 直接显示文件名。预览版装在固定的“文件搜索预览.app”（改了会丢掉已授予的
    # 完整磁盘访问权限），所以这里写文件名，实际显示的“索隐（预览）”来自下面的
    # InfoPlist.strings。
    plist_display_name="文件搜索预览"
    test_hooks="    <key>FSTestHooksEnabled</key><true/>"
fi
# 正式标识待定：--release 暂时沿用预览版的包标识。
# The identifier, install path, data directory and signing identity stay as
# they are: changing them would drop the Full Disk Access already granted.
bundle_id="dev.local.filesearch.demo"

swift build -c release
app=".build/FileSearchDemo.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/SearchApp "$app/Contents/MacOS/SearchApp"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>SearchApp</string>
    <key>CFBundleIdentifier</key><string>$bundle_id</string>
    <key>CFBundleName</key><string>$display_name</string>
    <key>CFBundleDisplayName</key><string>$plist_display_name</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSHasLocalizedDisplayName</key><true/>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
$test_hooks
</dict>
</plist>
EOF
# 访达、系统设置和“关于”窗口实际显示的名字。
for language in zh-Hans en; do
    mkdir -p "$app/Contents/Resources/$language.lproj"
    cat > "$app/Contents/Resources/$language.lproj/InfoPlist.strings" <<EOF
"CFBundleName" = "$display_name";
"CFBundleDisplayName" = "$display_name";
EOF
done
plutil -lint "$app/Contents/Info.plist" >/dev/null
# A fixed local identity keeps the system's privacy grants (Full Disk Access)
# across rebuilds; fall back to ad-hoc signing where it is not installed.
identity="FileSearch Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "$identity"; then
    codesign --force --sign "$identity" "$app" >/dev/null 2>&1
else
    codesign --force --sign - "$app" >/dev/null 2>&1
fi
# `--install` puts a copy where System Settings can find it easily.
if $install; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/文件搜索预览.app"
    cp -R "$app" "$HOME/Applications/文件搜索预览.app"
    echo "$HOME/Applications/文件搜索预览.app"
else
    echo "$PWD/$app"
fi
