#!/bin/zsh
# 编译界面并打成应用包，带上 Sparkle.framework（自动更新）。
#
#   bundle.sh                         预览版：.build/FileSearchDemo.app
#                                     显示名“索隐（预览）”，标识 dev.local.filesearch.demo，
#                                     打开测试入口（FSTestHooksEnabled）
#   bundle.sh --install               预览版，并复制到 ~/Applications/文件搜索预览.app
#   bundle.sh --release --version 0.1.0 [--build 42]
#                                     正式版：.build/release-app/索隐.app，显示名“索隐”，
#                                     标识 io.github.nongtanpeidanjiu.suoyin，不带测试入口；
#                                     另外产出 dist/索隐-<版本>.dmg（安装用）和
#                                     dist/updates/Suoyin-<版本>.zip（Sparkle 更新包，
#                                     由 Tools/make-appcast.sh 签名并生成 appcast.xml）。
#                                     不能与 --install 同用。
#
# 参数：
#   --version <x.y.z>   CFBundleShortVersionString。--release 必填；预览版默认 0.0.0-preview。
#   --build <整数>       CFBundleVersion（Sparkle 用它比较新旧）。缺省取 git rev-list --count HEAD。
#
# 签名：全部用本机自签名证书“FileSearch Local Signing”，由内到外逐个签名。
#   正式版找不到证书就报错退出，不退回临时签名；预览版找不到时用临时签名并警告。
# 更新：公钥从 App/Release/sparkle-public-key.txt 读取。正式版缺它报错退出；
#   预览版缺它就不写更新相关的键，应用里的更新功能整个隐藏。
# 本脚本不读写钥匙串（只用 security find-identity 查证书是否存在），
# 不调用 Sparkle 的 generate_keys、sign_update。
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { print -u2 -- "错误：$*"; exit 1; }

release=false
install=false
version=""
build=""
while (( $# > 0 )); do
    case "$1" in
        --release) release=true ;;
        --install) install=true ;;
        --version) (( $# >= 2 )) || fail "--version 后面要跟版本号"; version="$2"; shift ;;
        --build) (( $# >= 2 )) || fail "--build 后面要跟整数"; build="$2"; shift ;;
        *) print -u2 -- "未知参数：$1"; exit 2 ;;
    esac
    shift
done
if $release && $install; then
    # 正式版不装到预览版的位置，免得覆盖用户正在使用的预览版。
    print -u2 -- "--release 不能与 --install 同时使用。"
    exit 2
fi

# 版本号。
if $release; then
    [[ -n "$version" ]] || fail "--release 必须带 --version <x.y.z>"
    [[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "版本号要写成 x.y.z（例如 0.1.0），现在是“$version”"
else
    version="${version:-0.0.0-preview}"
fi
if [[ -z "$build" ]]; then
    build="$(git rev-list --count HEAD 2>/dev/null)" || fail "取不到 git 提交数，请用 --build <整数> 指定"
fi
[[ "$build" =~ '^[0-9]+$' ]] || fail "--build 要是正整数，现在是“$build”"

# 最低系统版本只在 Package.swift 里写一次（let minimumMacOS = "x.y.z"）。
minimum_os="$(sed -nE 's/^let minimumMacOS = "([0-9.]+)".*/\1/p' Package.swift)"
[[ -n "$minimum_os" ]] || fail "没能从 Package.swift 读出 minimumMacOS"

# 更新公钥（Ed25519 公钥的 base64，44 个字符）。
key_file="Release/sparkle-public-key.txt"
feed_url="https://github.com/nongtanpeidanjiu/suoyin/releases/latest/download/appcast.xml"
public_key=""
if [[ -f "$key_file" ]]; then
    public_key="$(tr -d ' \t\r\n' < "$key_file")"
    [[ "$public_key" =~ '^[A-Za-z0-9+/]{43}=$' ]] || fail "$key_file 不是合法的 Sparkle 公钥（应为 44 个字符的 base64）"
elif $release; then
    fail "缺少 $key_file。先生成更新密钥：在本机运行 Sparkle 的 generate_keys（私钥存进钥匙串），把它打印的公钥写进这个文件。"
else
    print -u2 -- "提示：没有 $key_file，预览版不启用自动更新。"
fi

if $release; then
    display_name="索隐"
    plist_display_name="索隐"
    bundle_id="io.github.nongtanpeidanjiu.suoyin"
    app=".build/release-app/索隐.app"
    test_hooks=""
else
    display_name="索隐（预览）"
    # 访达和系统设置只在包的文件名与 Info.plist 里（未本地化的）
    # CFBundleDisplayName 相同时才采用本地化表里的显示名，否则当作用户改过名、
    # 直接显示文件名。预览版装在固定的“文件搜索预览.app”（改了会丢掉已授予的
    # 完整磁盘访问权限），所以这里写文件名，实际显示的“索隐（预览）”来自下面的
    # InfoPlist.strings。
    plist_display_name="文件搜索预览"
    # 标识、安装位置、数据目录和签名证书都保持原样：改了会丢掉已授予的完整磁盘访问权限。
    bundle_id="dev.local.filesearch.demo"
    app=".build/FileSearchDemo.app"
    test_hooks="    <key>FSTestHooksEnabled</key><true/>"
fi

update_keys=""
# 预览版即使有公钥也不写更新配置：否则它会去读正式版的更新地址，被“更新”成正式版。
# 要测更新流程，用 --release 打包，或给预览版加测试参数 --feed-url。
if [[ -n "$public_key" ]] && $release; then
    # SUEnableSystemProfiling=false：不发送系统信息。SUEnableAutomaticChecks 写明
    # 后 Sparkle 不再弹窗询问是否自动检查；SUAutomaticallyUpdate=true 加上应用里
    # “安装前询问”缺省为真，就是默认的“自动下载，安装前询问”（见 Updater.swift）。
    update_keys="    <key>SUFeedURL</key><string>$feed_url</string>
    <key>SUPublicEDKey</key><string>$public_key</string>
    <key>SUEnableSystemProfiling</key><false/>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
    <key>SUAllowsAutomaticUpdates</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>"
fi

# 签名证书。
identity="FileSearch Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$identity\""; then
    sign_identity="$identity"
elif $release; then
    fail "钥匙串里找不到签名证书“$identity”。正式版不允许用临时签名。"
else
    sign_identity="-"
    print -u2 -- ""
    print -u2 -- "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    print -u2 -- "!! 警告：找不到签名证书“$identity”，改用临时签名。"
    print -u2 -- "!! 临时签名的包每次重新打包都会丢失已授予的完整磁盘访问权限。"
    print -u2 -- "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    print -u2 -- ""
fi

swift build -c release
sparkle=".build/release/Sparkle.framework"
[[ -d "$sparkle" ]] || fail "找不到 $sparkle（swift build 应该已经从 Sparkle 的二进制包里拷出它）"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ThirdParty" "$app/Contents/Frameworks"
cp .build/release/SearchApp "$app/Contents/MacOS/SearchApp"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp ThirdParty/Sparkle-LICENSE.txt "$app/Contents/Resources/ThirdParty/Sparkle-LICENSE.txt"
# ditto 保留框架里的符号链接。
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
# 主程序链接时已带上运行路径 @executable_path/../Frameworks（见 Package.swift），这里核对一下。
otool -l "$app/Contents/MacOS/SearchApp" | grep -q "@executable_path/../Frameworks" \
    || fail "主程序缺少运行路径 @executable_path/../Frameworks"

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
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>LSHasLocalizedDisplayName</key><true/>
    <key>LSMinimumSystemVersion</key><string>$minimum_os</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
$update_keys
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
plutil -lint "$app/Contents/Info.plist" >/dev/null || fail "Info.plist 格式不对"

# 由内到外签名：先框架里的各个可执行组件，再框架本身，最后主程序。
# 不开强化运行时：自签名证书没有团队标识，开了会因库校验而加载不了 Sparkle.framework。
sign() {
    local target="$1"; shift
    if ! codesign --force --sign "$sign_identity" "$@" "$target"; then
        fail "签名失败：$target"
    fi
}
framework="$app/Contents/Frameworks/Sparkle.framework"
components=(
    "$framework/Versions/B/XPCServices/Installer.xpc"
    "$framework/Versions/B/XPCServices/Downloader.xpc"
    "$framework/Versions/B/Autoupdate"
    "$framework/Versions/B/Updater.app"
)
for component in "${components[@]}"; do
    [[ -e "$component" ]] || continue
    # Downloader.xpc 带有沙盒权限声明，重签时保留。
    sign "$component" --preserve-metadata=entitlements
done
sign "$framework"
sign "$app"
codesign --verify --deep --strict "$app" || fail "签名校验没通过：$app"

if $release; then
    mkdir -p dist/updates
    # 安装用的磁盘映像：索隐.app 加一个指向“应用程序”文件夹的替身。
    staging="$(mktemp -d)"
    trap 'rm -rf "$staging"' EXIT
    ditto "$app" "$staging/索隐.app"
    ln -s /Applications "$staging/应用程序"
    dmg="dist/索隐-$version.dmg"
    rm -f "$dmg"
    hdiutil create -volname "索隐" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null \
        || fail "生成磁盘映像失败"
    sign "$dmg"
    # Sparkle 推荐的更新包：用 ditto 压成 zip（保留符号链接和签名）。文件名用
    # 英文，因为它会出现在 appcast 的下载地址里，GitHub 也会改掉非英文的附件名。
    archive="dist/updates/Suoyin-$version.zip"
    rm -f "$archive"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$archive" || fail "生成更新包失败"
    echo "$PWD/$app"
    echo "$PWD/$dmg"
    echo "$PWD/$archive"
    echo "下一步：运行 Tools/make-appcast.sh --version $version 签名更新包并生成 appcast.xml。"
elif $install; then
    # `--install` puts a copy where System Settings can find it easily.
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/文件搜索预览.app"
    cp -R "$app" "$HOME/Applications/文件搜索预览.app"
    echo "$HOME/Applications/文件搜索预览.app"
else
    echo "$PWD/$app"
fi
