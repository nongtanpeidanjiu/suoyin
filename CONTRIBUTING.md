# 参与贡献

欢迎反馈问题，也欢迎提交改动。

## 反馈问题

在 [Issues](https://github.com/nongtanpeidanjiu/suoyin/issues) 里新建一条，尽量写上：

- Mac 型号、macOS 版本、索隐的版本（菜单栏图标右键 › 设置… 或“关于索隐”里可以看到）；
- 怎么操作、期望看到什么、实际看到什么；
- 界面上出现的报错原文。出错提示末尾括号里的“原始信息”对定位很有帮助，请一并贴上。

贴出来之前请检查一遍：截图和日志里可能有你的文件名、用户名和路径，不想公开的请打码或替换。

## 提交改动

1. Fork 本仓库，在新分支上改动。
2. 确认能编译、自动化测试全部通过（见下文）。
3. 发起 Pull Request，说明改了什么、为什么改、怎么验证的。改动界面的，请附上浅色和深色模式的截图。

许可： 你提交的改动（代码、文档、图片等），即表示你同意以本项目的许可证 [PolyForm Noncommercial License 1.0.0](LICENSE) 授权，与项目其余部分相同，并确认你有权这样授权。

## 代码结构

| 位置 | 内容 |
|---|---|
| `Sources/SearchCore` | 搜索核心：扫描、文件变化跟踪、索引、查询、快照、云盘与其他磁盘。界面只通过 `SearchEngine` 门面使用它。 |
| `Sources/DarwinMetadata` | 核心用到的 C 代码：批量读取目录元数据、名称匹配等。 |
| `Sources/SearchCLI` | 命令行工具 `file-search`，用于基准测试和不经界面复核核心行为。 |
| `Tests/SearchCoreTests` | 核心的自动化测试（Swift Testing）。 |
| `App/` | 界面，独立的 SwiftPM 工程，依赖上面的 `SearchCore`。`App/Sources/SearchApp` 是界面代码，`App/Tools/bundle.sh` 打包应用，`App/Tools/make-icon.swift` 生成图标。 |
| `scripts/` | 测量和对照用的 Python 脚本。 |
| `docs/` | 设计和验收文档。界面的行为以 [界面规格](docs/界面规格.md) 为准，核心的设计见 [技术设计](docs/技术设计-v1.1.md)。 |

## 编译与运行

不需要 Xcode，装好 Command Line Tools（`xcode-select --install`）即可。需要 Apple 芯片的 Mac、macOS 15.7.9 或更高版本；项目用 Swift 6.1.2 开发。

```sh
# 核心和命令行工具（在仓库根目录）
swift build

# 核心的自动化测试
swift test --disable-xctest --enable-swift-testing

# 界面：用演示数据运行，不读你的磁盘
cd App
swift run SearchApp --demo

# 界面：打包成应用（预览版，带测试入口；输出 App/.build/FileSearchDemo.app）
Tools/bundle.sh
```

说明：

- 不在 `.app` 包里运行（`swift run`）时，测试入口自动打开；不带 `--demo` 时会用真实核心，按你当前的权限建索引。想与日常使用的索引隔离，加 `--data-dir <目录>`。
- 系统按签名识别“完整磁盘访问权限”。没有固定签名证书时打包脚本使用临时签名，每次重新打包都可能需要重新授权。
- 界面的测试入口（启动参数、分布式通知、调试日志）见 [界面规格](docs/界面规格.md) 第 10 节“测试入口与开关”。快捷键规则可以用 `SearchApp --self-test-shortcuts` 自检。
- 核心的命令行用法和基准复现见 [构建与基准](docs/构建与基准.md) 以及 [里程碑 4 门面验收](docs/里程碑4-门面验收.md) 的“CLI 复核”一节。

## 硬性要求

> 不要运行 `spike/` 目录（如果你在某个分支或副本里见到它）下的任何程序。其中一个探针程序曾导致整机内核崩溃并重启，相关代码只作为事故记录保留。项目已禁用 `searchfs` 系统调用，请不要在任何改动中使用它。

此外：

- 会写文件的测试只在项目自己的临时目录里进行，不要在测试中改动用户的真实文件。
- 不要在提交里带上真实的文件路径清单、索引文件或测量原始记录，它们可能含有个人信息。
- 界面文字目前只有简体中文，直接写在代码里。改动界面文字或行为时，请同步更新 [界面规格](docs/界面规格.md)。
