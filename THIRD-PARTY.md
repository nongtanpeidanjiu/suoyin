# 第三方组件

## 随应用分发的组件

| 组件 | 版本 | 用途 | 许可 |
|---|---|---|---|
| [Sparkle](https://sparkle-project.org/)（[源码](https://github.com/sparkle-project/Sparkle)） | 2.10.1 | 自动检查、下载和安装更新，并校验更新包签名 | MIT 许可 |

Sparkle 由界面工程通过 SwiftPM 以确切版本引入（见 `App/Package.swift`），打包时随应用一起分发（应用包内的 `Contents/Frameworks/Sparkle.framework`）。它的许可证全文见 `App/ThirdParty/Sparkle-LICENSE.txt`。

## 系统自带框架

除上表外，索隐只使用 macOS 自带的系统框架和系统库，例如 AppKit、Foundation、Quick Look、Service Management（登录时启动）、Carbon（全局快捷键）、IOKit、Disk Arbitration、Core Services（文件系统事件）、Network（感知网络恢复）、CryptoKit（索引校验）。这些框架随 macOS 提供，不随本项目分发。

搜索核心和命令行工具没有任何第三方依赖（见根目录 `Package.swift`）；界面依赖本仓库的搜索核心和上表的 Sparkle（见 `App/Package.swift`）。

## 图标与符号

- 界面里的小图标是苹果的系统符号（SF Symbols），由系统在运行时提供，只在应用界面内使用，不单独分发。
- 应用图标由 `App/Tools/make-icon.swift` 用代码绘制生成，属于本项目，随本项目的[许可证](LICENSE)授权。
- 结果列表里的文件图标由系统按文件实际类型提供。

## 开发和测试工具

开发中用到的 Swift 编译器、Swift Testing、Python 3（`scripts/` 下的测量脚本）均为开发工具，不随应用分发。`scripts/` 下的脚本只用 Python 标准库。
