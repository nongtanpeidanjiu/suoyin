import Foundation

/// `--showcase`（与 `--demo` 同用）用的演示内容：一台普通电脑里会有的文件，
/// 全部虚构、中性，用来给介绍页截图。
///
/// 除了少数几个文字文件，这些条目都不在磁盘上：它们的路径放在个人文件夹、
/// iCloud 云盘和一块虚构的移动硬盘下，好让位置一栏显示得像真的一样。那几个
/// 文字文件（包括 `README.md`）启动时真实写进 `--data-dir` 指定的目录，结果
/// 里对应条目的预览改读这些真实文件（见 `previewPath(for:)`），这样快速查看
/// 能显示排版后的 Markdown。
enum ShowcaseData {
    struct Item {
        let path: String
        let isDirectory: Bool
        let modified: Date
        let size: Int64
        let isCloudPlaceholder: Bool
        let isOnExternalVolume: Bool
    }

    /// 演示里移动硬盘的名字，与“其他磁盘”列表一致。
    static let volumeName = "移动硬盘"
    /// 状态里显示的总项目数，以及其中移动硬盘的部分。
    static let totalCount = 2_084_317
    static let volumeCount = 186_420

    private static let home = NSHomeDirectory()
    private static let cloudRoot = home + "/Library/Mobile Documents/com~apple~CloudDocs"
    private static let volumeRoot = "/Volumes/" + volumeName
    /// 结果里显示的项目文件夹；里面的文字文件真实写在数据目录下。
    private static let projectFolder = home + "/Documents/项目/拾页"

    // MARK: 真实的示例文件

    /// 显示路径 → 磁盘上的真实文件，`prepareFiles` 之后才有内容。只在主线程
    /// 读写。
    private(set) static var realFiles: [String: String] = [:]

    /// 预览时改读的真实文件；不是示例文件时原样返回。
    static func previewPath(for path: String) -> String { realFiles[path] ?? path }

    /// 在 `directory` 下写出示例项目文件夹（已有的覆盖），并记下显示路径
    /// 与真实文件的对应。
    static func prepareFiles(in directory: URL) {
        let folder = directory.appendingPathComponent("展示样例/拾页", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var map: [String: String] = [:]
            for (name, text) in sampleFiles {
                let url = folder.appendingPathComponent(name)
                try Data(text.utf8).write(to: url, options: .atomic)
                map[projectFolder + "/" + name] = url.path
            }
            realFiles = map
        } catch {
            NSLog("showcase: 无法写出示例文件：\(error)")
        }
    }

    private static let sampleFiles: [(String, String)] = [
        ("README.md", readme),
        ("更新记录.md", changelog),
        ("待办.txt", todo),
        ("拾页.example.toml", exampleConfig),
    ]

    private static let readme = """
    # 拾页

    把零散的笔记整理成一本可以翻阅的小册子。拾页读取一个文件夹里的 Markdown 笔记，按标签和日期排好，生成一份带目录的网页或 PDF。

    ## 功能

    - **按标签成章**：同一个标签的笔记归到一章，章内按日期排列
    - **自动目录**：标题、章节和页码自动生成，可以点按跳转
    - **离线运行**：只读本机文件，不联网、不上传任何内容
    - **增量更新**：只重新处理改动过的笔记，几百篇也是一眨眼

    ## 安装

    ```sh
    git clone https://example.com/shiye.git
    cd shiye
    make install
    ```

    ## 用法

    ```sh
    shiye build ~/笔记 --output 小册子.pdf
    shiye watch ~/笔记          # 笔记有改动时自动重新生成
    ```

    | 命令 | 作用 | 常用选项 |
    | --- | --- | --- |
    | `build` | 生成一次小册子 | `--output`、`--theme` |
    | `watch` | 监视文件夹，改动后自动生成 | `--interval` |
    | `tags` | 列出所有标签和篇数 | `--sort count` |
    | `check` | 检查断开的内部链接 | 无 |

    ## 目录结构

    ```
    拾页/
    ├── README.md
    ├── 拾页.example.toml   配置示例
    ├── 更新记录.md
    └── 主题/
        ├── 素雅.css
        └── 夜读.css
    ```

    ## 配置

    把 `拾页.example.toml` 复制为 `拾页.toml`，按需修改书名、作者和主题。所有选项都有注释说明。

    > 小提示：在笔记开头写上 `标签: 旅行, 读书`，拾页就会把它放进对应的章节。

    ## 许可

    以 MIT 许可发布，欢迎修改和分享。
    """

    private static let changelog = """
    # 更新记录

    ## 0.4.0

    - 新增“夜读”主题
    - `watch` 命令改动后两秒内重新生成
    - 修正目录里中英文混排时页码错位

    ## 0.3.2

    - 标签名支持空格
    - `check` 命令列出断开链接所在的行号

    ## 0.3.0

    - 支持导出 PDF
    - 首次发布 `tags` 命令
    """

    private static let todo = """
    待办

    [ ] 封面支持自定义图片
    [ ] 目录页加一个按日期排列的视图
    [x] 夜读主题的代码块颜色再调暗一点
    [x] 更新记录里补上 0.4.0
    [ ] 写一篇入门教程，配三张示意图
    """

    private static let exampleConfig = """
    # 拾页配置示例：复制为 拾页.toml 后修改

    [书]
    书名 = "我的小册子"
    作者 = "某某"
    主题 = "素雅"        # 可选：素雅、夜读

    [生成]
    输出 = "小册子.pdf"
    按标签成章 = true
    忽略 = ["草稿/", "*.tmp"]
    """

    // MARK: 条目

    /// 所有演示条目，文件夹在内。用固定的种子生成，每次启动都一样。
    static func items(now: Date = Date()) -> [Item] {
        var generator = Seeded(seed: 20_261_120)
        var rows: [(path: String, days: Double, cloud: Bool)] = []
        var directories = Set<String>()
        var added = Set<String>()
        func add(_ path: String, _ days: Double, cloud: Bool = false) {
            var full = expand(path)
            if full.hasSuffix("/") {
                full.removeLast()
                directories.insert(full)
            }
            // 随机编号的照片偶尔撞名，同一路径只留一条。
            guard added.insert(full).inserted else { return }
            rows.append((full, days, cloud))
        }

        // 精心挑过的几组，保证“方案”“报告 2026”“readme”“封面／截图”有好看的结果。
        for (path, days, cloud) in curated { add(path, days, cloud: cloud) }

        // 其余是一台电脑上常见的大量文件，避开上面那几组关键词。
        var filler: [(String, Double, Bool)] = []
        func fill(_ path: String, _ days: Double, cloud: Bool = false) { filler.append((path, days, cloud)) }

        // 照片图库导出，按月份分文件夹。
        let trips = ["海边", "秋游", "家里", "公园", "老街", "雪山", "古镇", "露营", "花市", "江边", "生日", "春节"]
        for month in 0..<24 {
            let year = 2024 + (month + 6) / 12
            let monthNumber = (month + 6) % 12 + 1
            let folder = String(format: "~/Pictures/照片导出/%d-%02d %@", year, monthNumber, trips[month % trips.count])
            let baseDays = Double(24 - month) * 30.4 + 8
            for _ in 0..<Int(generator.next(in: 22...40)) {
                let number = generator.next(in: 1000...9999)
                fill("\(folder)/IMG_\(number).HEIC", baseDays - Double(generator.next(in: 0...27)))
            }
        }
        // 桌面上的截屏。
        for index in 0..<48 {
            let days = Double(index) * 2.6 + 0.2 + Double(generator.next(in: 0...86_399)) / 86_400
            let date = now.addingTimeInterval(-days * 86_400)
            fill("~/Desktop/截屏\(stamp(date)).png", days)
        }
        // 周报和会议纪要。
        for week in 1...46 { fill(String(format: "~/Documents/工作/周报/周报 2026-W%02d.docx", week), Double(47 - week) * 7 + 2) }
        for index in 0..<110 {
            let days = Double(index) * 4.3 + 1
            fill("~/Documents/工作/会议纪要/会议纪要 \(day(now.addingTimeInterval(-days * 86_400))).md", days)
        }
        // 账单、发票、证件扫描。
        for month in 1...24 {
            let year = 2024 + (month - 1) / 12
            let name = String(format: "%d-%02d", year, (month - 1) % 12 + 1)
            let days = Double(25 - month) * 30.4
            fill("~/Documents/家庭账本/电费账单 \(name).pdf", days)
            fill("~/Documents/家庭账本/水费账单 \(name).pdf", days + 1)
            fill("~/Downloads/电子发票 \(name)-\(generator.next(in: 10...99)).pdf", days + 3)
        }
        for year in 2023...2026 { fill("~/Documents/家庭账本/记账 \(year).numbers", Double(2026 - year) * 365 + 4) }
        // 读书笔记（iCloud 云盘，一部分只在云端）。
        let books = ["关于时间的小书", "城市散步", "植物图鉴", "极简烹饪", "写作练习", "旧物志", "海边的一年",
                     "声音与耳朵", "读书的方法", "慢下来的旅行", "家常菜五十道", "观星入门", "纸的历史",
                     "山野手记", "睡眠的秘密", "颜色的故事", "建筑漫谈", "咖啡笔记", "地图的诞生", "茶事杂记",
                     "数字的乐趣", "鸟类观察", "四季饮食", "灯塔与航线", "博物馆一日"]
        for (index, book) in books.enumerated() {
            let days = Double(index) * 23 + 5
            fill("☁/读书笔记/\(book).md", days, cloud: index % 3 == 1)
            fill("☁/读书笔记/摘抄/\(book) 摘抄.txt", days + 2, cloud: index % 3 != 0)
        }
        // 本地音乐。
        let albums = ["晨光小集", "雨天的窗", "城市夜行", "山间来信", "慢火车", "海风与盐"]
        let tracks = ["序曲", "晨光", "远方", "旧照片", "慢慢走", "风从南来", "回声", "夜航", "灯火", "小雨",
                      "归途", "尾声"]
        for (index, album) in albums.enumerated() {
            for (number, track) in tracks.enumerated() {
                fill(String(format: "~/Music/本地音乐/%@/%02d %@.flac", album, number + 1, track), Double(index) * 90 + 200)
            }
        }
        // 家庭录像，一部分在移动硬盘上。
        for index in 0..<60 {
            let days = Double(index) * 11 + 3
            let date = now.addingTimeInterval(-days * 86_400)
            let name = "VID_\(compact(date)).mp4"
            fill(index % 2 == 0 ? "~/Movies/家庭录像/\(name)" : "⏏/影像/家庭录像/\(name)", days)
        }
        // 移动硬盘上的旧照片和归档。
        for year in 2018...2023 {
            for _ in 0..<90 {
                let number = generator.next(in: 1000...9999)
                fill("⏏/照片备份/\(year)/DSC_\(number).JPG", Double(2026 - year) * 365 + Double(generator.next(in: 0...300)))
            }
            fill("⏏/归档/\(year) 资料整理.zip", Double(2026 - year) * 365 + 40)
        }
        // 下载文件夹：安装包、说明书、压缩包。
        let downloads = ["番茄钟-2.3.1.dmg", "记账本-1.8.0.dmg", "白噪音-4.0.2.dmg", "看图-3.2.zip", "字体合集.zip",
                         "路由器说明书.pdf", "空气净化器说明书.pdf", "洗衣机使用手册.pdf", "租房合同模板.docx",
                         "课程表.xlsx", "地铁线路图.pdf", "菜谱合集.epub", "壁纸 - 山间.jpg", "壁纸 - 湖面.jpg",
                         "图标素材.zip", "演讲稿模板.pptx", "旅行清单.numbers", "签证材料清单.pdf",
                         "家具安装图.pdf", "跑步训练计划.pdf"]
        for (index, name) in downloads.enumerated() { fill("~/Downloads/\(name)", Double(index) * 6.5 + 0.5) }
        // 资源库里应用自己的备份。
        for index in 0..<40 {
            let days = Double(index) * 3 + 1
            fill("~/Library/Application Support/笔记本/备份/备份 \(day(now.addingTimeInterval(-days * 86_400))).zip", days)
        }
        // 自己的小项目源码。
        for name in ["main.swift", "排版.swift", "目录.swift", "标签.swift", "导出.swift", "监视.swift"] {
            fill("~/Documents/项目/拾页/源码/\(name)", Double(name.count) * 1.7)
        }
        for name in ["素雅.css", "夜读.css"] { fill("~/Documents/项目/拾页/主题/\(name)", 9) }
        // 学习资料。
        let courses = ["线性代数", "概率论", "数据结构", "摄影基础", "日语入门", "写作课"]
        for (index, course) in courses.enumerated() {
            for lesson in 1...12 {
                fill("~/Documents/学习/\(course)/第 \(lesson) 讲.pdf", Double(index) * 40 + Double(13 - lesson) * 6 + 300)
            }
            fill("~/Documents/学习/\(course)/笔记.md", Double(index) * 40 + 280)
        }
        // 应用程序。
        for (index, name) in ["番茄钟", "记账本", "白噪音", "看图", "单词卡", "剪贴板历史", "屏幕尺", "拾色器"].enumerated() {
            fill("/Applications/\(name).app", Double(index) * 37 + 15)
        }
        // 设计素材。
        for index in 1...60 {
            let ext = ["png", "png", "psd", "jpg"][index % 4]
            fill(String(format: "~/Pictures/设计素材/图标/图标 %03d.%@", index, ext), Double(index) * 5 + 10)
        }

        let avoided = ["方案", "报告", "封面", "截图", "readme"]
        for (path, days, cloud) in filler {
            let name = (path as NSString).lastPathComponent.lowercased()
            if avoided.contains(where: name.contains) { continue }
            add(path, days, cloud: cloud)
        }

        // 每个条目的上级文件夹也是条目，到个人文件夹、iCloud 云盘和硬盘为止。
        let stops: Set<String> = [home, cloudRoot, volumeRoot, "/Applications", home + "/Library",
                                  home + "/Library/Application Support"]
        var folders: [String: Double] = [:]
        for row in rows {
            var parent = (row.path as NSString).deletingLastPathComponent
            while !stops.contains(parent), parent.count > 1 {
                folders[parent] = min(folders[parent] ?? .infinity, row.days)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        var seen = Set(rows.map(\.path))
        for (path, days) in folders.sorted(by: { $0.key < $1.key }) where !seen.contains(path) {
            rows.append((path, days, false))
            seen.insert(path)
        }

        return rows.map { row in
            let path = row.path
            let name = (path as NSString).lastPathComponent
            let isDirectory = folders[path] != nil || directories.contains(path) || name.hasSuffix(".app")
            return Item(path: path, isDirectory: isDirectory,
                        modified: now.addingTimeInterval(-row.days * 86_400 - Double(stableHash(path) % 3_600)),
                        size: isDirectory ? 0 : size(of: name, seed: path),
                        isCloudPlaceholder: row.cloud, isOnExternalVolume: path.hasPrefix(volumeRoot + "/"))
        }
    }

    /// `~/`、`☁/`（iCloud 云盘）、`⏏/`（移动硬盘）开头的写法换成完整路径。
    private static func expand(_ path: String) -> String {
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        if path.hasPrefix("☁/") { return cloudRoot + path.dropFirst(1) }
        if path.hasPrefix("⏏/") { return volumeRoot + path.dropFirst(1) }
        return path
    }

    /// （路径, 几天前, 是否只在云端）。路径以 `/` 结尾的是文件夹。
    private static let curated: [(String, Double, Bool)] = [
        // 方案
        ("~/Documents/工作/2026 年度工作方案.docx", 3, false),
        ("~/Documents/工作/活动策划方案（终稿）.pages", 12, false),
        ("~/Documents/工作/预算方案.xlsx", 30, false),
        ("~/Documents/工作/方案评审/", 8, false),
        ("~/Documents/工作/方案评审/评审意见汇总.docx", 8, false),
        ("~/Desktop/新办公室布置方案.key", 0.1, false),
        ("~/Downloads/社区花园改造方案.pdf", 6, false),
        ("☁/家庭/装修/客厅灯光方案.numbers", 40, true),
        ("☁/家庭/旅行/暑假出行方案.md", 20, true),
        ("~/Pictures/设计稿/包装方案 A.png", 25, false),
        ("~/Pictures/设计稿/包装方案 B.png", 25, false),
        ("~/Movies/方案演示录屏.mov", 15, false),
        ("~/Documents/学习/毕业设计方案.pptx", 700, false),
        ("⏏/归档/2024/展厅布置方案.zip", 520, false),
        ("⏏/项目备份/网站改版方案.pdf", 210, false),
        // 报告 2026
        ("~/Documents/工作/报告/2026 第一季度运营报告.pdf", 50, false),
        ("~/Documents/工作/报告/2026-06 月度报告.xlsx", 140, false),
        ("~/Documents/工作/报告/用户调研报告 2026-03.docx", 230, false),
        ("~/Documents/工作/报告/2026 半年报告/", 125, false),
        ("~/Desktop/2026 市场观察报告.key", 2, false),
        ("☁/家庭/健康/2026 年度体检报告.pdf", 64, true),
        ("~/Documents/学习/读书报告 2026 春.md", 180, false),
        ("⏏/资料/实验报告_2026_05.pdf", 190, false),
        ("~/Documents/工作/报告/2025 年度总结报告.pdf", 320, false),
        // 封面
        ("~/Pictures/设计稿/相册封面.jpg", 33, false),
        ("~/Pictures/设计稿/播客封面 第 12 期.png", 9, false),
        ("~/Pictures/设计稿/读书笔记封面.psd", 75, false),
        ("~/Pictures/设计稿/封面候选 01.jpg", 4, false),
        ("~/Pictures/设计稿/封面候选 02.jpg", 4, false),
        ("~/Pictures/设计稿/封面候选 03.jpg", 4, false),
        ("☁/相册/年度相册封面草稿.heic", 110, true),
        ("⏏/影像/视频封面.webp", 260, false),
        ("~/Documents/项目/拾页/封面草图.png", 18, false),
        // 截图
        ("~/Pictures/截图/登录页截图.png", 7, false),
        ("~/Pictures/截图/设置页截图.png", 7, false),
        ("~/Pictures/截图/首页截图 浅色.png", 1, false),
        ("~/Pictures/截图/首页截图 深色.png", 1, false),
        ("~/Desktop/报名表截图.png", 0.3, false),
        ("~/Downloads/地图截图.jpg", 16, false),
        ("☁/家庭/旅行/车票截图.png", 22, true),
        ("~/Documents/工作/错误提示截图.png", 45, false),
        // 示例项目（真实文件在数据目录下）
        ("~/Documents/项目/拾页/README.md", 0.05, false),
        ("~/Documents/项目/拾页/更新记录.md", 2, false),
        ("~/Documents/项目/拾页/待办.txt", 1, false),
        ("~/Documents/项目/拾页/拾页.example.toml", 9, false),
        // 其他常见文件
        ("~/Desktop/待办清单.md", 0.2, false),
        ("~/Desktop/草稿/", 5, false),
        ("~/Desktop/草稿/随手记.txt", 5, false),
        ("~/Documents/个人/简历 2026.pdf", 60, false),
        ("~/Documents/个人/证件扫描/", 400, false),
        ("~/Documents/个人/证件扫描/护照首页.pdf", 400, false),
        ("☁/家庭/装修/装修预算.numbers", 41, true),
        ("☁/家庭/旅行/行李清单.md", 21, false),
        ("~/Movies/年会节目彩排.mov", 330, false),
        ("~/Music/录音/采访录音 01.m4a", 95, false),
        ("~/Music/录音/采访录音 02.m4a", 95, false),
        ("~/Music/铃声/清晨鸟鸣.m4a", 600, false),
    ]

    // MARK: 辅助

    private static func size(of name: String, seed: String) -> Int64 {
        let ext = (name as NSString).pathExtension.lowercased()
        let range: ClosedRange<Int64>
        switch ext {
        case "heic", "jpg", "jpeg", "webp": range = 900_000...4_800_000
        case "png", "svg": range = 40_000...2_400_000
        case "psd", "tiff": range = 12_000_000...86_000_000
        case "mov", "mp4", "mkv": range = 60_000_000...1_800_000_000
        case "flac": range = 18_000_000...46_000_000
        case "m4a", "mp3": range = 2_000_000...24_000_000
        case "zip", "dmg": range = 4_000_000...420_000_000
        case "pdf": range = 80_000...9_000_000
        case "md", "txt", "toml", "swift", "css": range = 600...24_000
        default: range = 20_000...3_200_000
        }
        let span = range.upperBound - range.lowerBound
        return range.lowerBound + Int64(stableHash(seed) % UInt64(span))
    }

    /// 每次启动都一样的散列（`hashValue` 每个进程不同）。
    private static func stableHash(_ text: String) -> UInt64 {
        text.utf8.reduce(14_695_981_039_346_656_037 as UInt64) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    private static func stamp(_ date: Date) -> String { format(date, "yyyy-MM-dd HH.mm.ss") }
    private static func day(_ date: Date) -> String { format(date, "yyyy-MM-dd") }
    private static func compact(_ date: Date) -> String { format(date, "yyyyMMdd_HHmmss") }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// 固定种子的简单随机数，让每次启动的演示数据一样。
    private struct Seeded {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(in range: ClosedRange<Int>) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let span = UInt64(range.upperBound - range.lowerBound + 1)
            return range.lowerBound + Int((state >> 33) % span)
        }
    }
}
