#!/bin/zsh
# 给正式版的更新包签名，并生成 Sparkle 的更新清单 appcast.xml。
#
#   make-appcast.sh --version 0.1.0 [--ed-key-file <私钥文件>]
#
# !! 注意：这个脚本会用到更新私钥。
# !! 默认从“登录”钥匙串里读取 Sparkle 的 EdDSA（ed25519）私钥（generate_keys 存进去的，
# !! 账户名 ed25519），系统会弹窗请求访问钥匙串；也可以用 --ed-key-file 指定私钥文件。
# !! 私钥一旦泄露，别人就能向所有用户推送“更新”，务必只在自己的电脑上运行。
#
# 前提：
#   1. 已经运行过 Tools/bundle.sh --release --version <同一个版本>，
#      产出了 dist/updates/Suoyin-<版本>.zip。
#   2. 已经用 Sparkle 的 generate_keys 生成过密钥，公钥写在 App/Release/sparkle-public-key.txt
#      （打包时写进了 Info.plist 的 SUPublicEDKey）。
#
# 做法：把这一版的更新包单独放进 dist/appcast-<版本>/，调用 Sparkle 自带的
# generate_appcast（在 swift build 拉下来的 .build/artifacts/sparkle/Sparkle/bin/ 里）：
# 它用私钥给更新包签名，生成只含这一版的 appcast.xml。
#
# 发布：在 GitHub 上建一个标签为 v<版本> 的 Release，上传三个文件：
#   dist/appcast-<版本>/Suoyin-<版本>.zip   （更新包，下载地址按 v<版本> 标签拼出）
#   dist/appcast-<版本>/appcast.xml          （应用从 releases/latest/download/appcast.xml 读取）
#   dist/索隐-<版本>.dmg                      （给新用户下载安装；GitHub 会改掉非英文附件名，
#                                             上传前可改名为 Suoyin-<版本>.dmg）
# 每个 Release 自带只描述自己的 appcast.xml，“最新 Release”永远指向最新版本。
#
# 发布说明：在 dist/appcast-<版本>/ 里放一个同名的 Suoyin-<版本>.md 或 .html，
# generate_appcast 会自动把它作为这一版的更新说明（本脚本会把 dist/updates/ 里的同名文件一起拷过去）。
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { print -u2 -- "错误：$*"; exit 1; }

version=""
key_args=()
while (( $# > 0 )); do
    case "$1" in
        --version) (( $# >= 2 )) || fail "--version 后面要跟版本号"; version="$2"; shift ;;
        --ed-key-file) (( $# >= 2 )) || fail "--ed-key-file 后面要跟文件路径"; key_args=(--ed-key-file "$2"); shift ;;
        *) print -u2 -- "未知参数：$1"; exit 2 ;;
    esac
    shift
done
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "要用 --version <x.y.z> 指定版本"

tool=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
[[ -x "$tool" ]] || fail "找不到 $tool，先运行一次 swift build"
archive="dist/updates/Suoyin-$version.zip"
[[ -f "$archive" ]] || fail "找不到 $archive，先运行 Tools/bundle.sh --release --version $version"

out="dist/appcast-$version"
rm -rf "$out"
mkdir -p "$out"
cp "$archive" "$out/"
for notes in dist/updates/Suoyin-$version.{md,html,txt}(N); do cp "$notes" "$out/"; done

"$tool" "${key_args[@]}" \
    --download-url-prefix "https://github.com/nongtanpeidanjiu/suoyin/releases/download/v$version/" \
    --link "https://github.com/nongtanpeidanjiu/suoyin" \
    --maximum-deltas 0 \
    "$out"

echo "$PWD/$out/appcast.xml"
