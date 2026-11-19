import AppKit

/// One result row: file icon, highlighted name, location, modified date.
final class ResultCellView: NSTableCellView {
    static var compact = false
    static var invertsWhenChosen = true
    static var rowHeight: CGFloat { compact ? 30 : 46 }
    private static let icons = NSCache<NSString, NSImage>()
    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
    private static let timeOnly = formatter("Hm")
    private static let dayOnly = formatter("MMMd")
    private static let fullDate = formatter("yMMMd")

    /// Short, scannable dates: a time for today, month and day for this
    /// year, a full date otherwise.
    static func displayDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return timeOnly.string(from: date) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            return dayOnly.string(from: date)
        }
        return fullDate.string(from: date)
    }

    /// Keeps the start of a name and its extension, cutting the middle.
    private static let singleLine: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return style
    }()

    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let location = NSTextField(labelWithString: "")
    private let modified = NSTextField(labelWithString: "")
    private let badge = NSImageView()
    private var hit: SearchHit?
    private var terms: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 14)
        name.lineBreakMode = .byTruncatingMiddle
        location.font = .systemFont(ofSize: 11.5)
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingMiddle
        modified.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        modified.textColor = .tertiaryLabelColor
        modified.alignment = .right
        badge.contentTintColor = .tertiaryLabelColor
        badge.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        // One line each, however long: a name without spaces must not wrap
        // onto the location line below it.
        for label in [name, location] {
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
            label.cell?.wraps = false
            label.cell?.truncatesLastVisibleLine = true
        }
        for view in [icon, name, location, modified, badge] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        location.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modified.setContentHuggingPriority(.required, for: .horizontal)
        modified.setContentCompressionResistancePriority(.required, for: .horizontal)
        let side: CGFloat = Self.compact ? 18 : 30
        var rules = [
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: side),
            icon.heightAnchor.constraint(equalToConstant: side),
            badge.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 5),
            badge.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            modified.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            modified.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if Self.compact {
            // One line: name, then the location in a quieter colour, then the date.
            name.font = .systemFont(ofSize: 13)
            location.alignment = .right
            name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            modified.widthAnchor.constraint(equalToConstant: 76).isActive = true
            rules += [
                name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
                name.centerYAnchor.constraint(equalTo: centerYAnchor),
                location.leadingAnchor.constraint(greaterThanOrEqualTo: badge.trailingAnchor, constant: 14),
                location.centerYAnchor.constraint(equalTo: centerYAnchor),
                location.trailingAnchor.constraint(equalTo: modified.leadingAnchor, constant: -14),
            ]
        } else {
            rules += [
                name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
                name.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                badge.trailingAnchor.constraint(lessThanOrEqualTo: modified.leadingAnchor, constant: -10),
                location.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                location.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
                location.trailingAnchor.constraint(lessThanOrEqualTo: modified.leadingAnchor, constant: -10),
            ]
        }
        NSLayoutConstraint.activate(rules)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(_ hit: SearchHit, terms: [String]) {
        self.hit = hit
        self.terms = terms
        isChosen = false
        let key = hit.path as NSString
        if let cached = Self.icons.object(forKey: key) {
            icon.image = cached
        } else {
            let image = NSWorkspace.shared.icon(forFile: hit.path)
            Self.icons.setObject(image, forKey: key)
            icon.image = image
        }
        location.stringValue = Self.displayLocation(of: hit.path)
        modified.stringValue = hit.modified == .distantPast ? "" : Self.displayDate(hit.modified)
        if hit.isCloudPlaceholder {
            badge.image = NSImage(systemSymbolName: "icloud", accessibilityDescription: "在云端，未下载")
        } else if hit.isOnExternalVolume {
            badge.image = NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "在外接盘上")
        } else {
            badge.image = nil
        }
        renderName()
    }

    /// The table draws no selection of its own; the controller slides a
    /// capsule behind the selected row and tells the cell to turn white.
    var isChosen = false {
        didSet {
            guard isChosen != oldValue else { return }
            let selected = isChosen && Self.invertsWhenChosen
            location.textColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
            modified.textColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .tertiaryLabelColor
            badge.contentTintColor = selected ? .alternateSelectedControlTextColor : .tertiaryLabelColor
            renderName()
        }
    }

    private func renderName() {
        guard let hit else { return }
        let selected = isChosen && Self.invertsWhenChosen
        let base: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        // The attributed string carries its own line breaking; without this
        // paragraph style it wraps instead of cutting in the middle.
        let text = NSMutableAttributedString(string: hit.name, attributes: [
            .font: NSFont.systemFont(ofSize: Self.compact ? 13 : 14), .foregroundColor: base,
            .paragraphStyle: Self.singleLine,
        ])
        let whole = hit.name as NSString
        for term in terms {
            var search = NSRange(location: 0, length: whole.length)
            while search.length > 0 {
                let found = whole.range(of: term, options: [.caseInsensitive], range: search)
                guard found.location != NSNotFound else { break }
                // Weight alone marks the match; colour stays reserved for the selected row.
                text.addAttribute(.font, value: NSFont.systemFont(ofSize: Self.compact ? 13 : 14, weight: .semibold), range: found)
                let next = found.location + found.length
                search = NSRange(location: next, length: whole.length - next)
            }
        }
        name.attributedStringValue = text
    }

    /// "/Users/me/Documents/a/b.txt" becomes "个人 › Documents › a".
    static func displayLocation(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        var parts: [String]
        if parent == home || parent.hasPrefix(home + "/") {
            parts = ["个人"] + parent.dropFirst(home.count).split(separator: "/").map(String.init)
        } else if parent.hasPrefix("/Volumes/") {
            parts = parent.dropFirst("/Volumes/".count).split(separator: "/").map(String.init)
        } else {
            parts = parent.split(separator: "/").map(String.init)
            if parts.isEmpty { parts = ["Macintosh HD"] }
        }
        return parts.joined(separator: " › ")
    }
}
