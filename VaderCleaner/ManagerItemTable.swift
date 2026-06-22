// ManagerItemTable.swift
// AppKit NSTableView bridge for the Smart Scan manager's item pane — native row recycling keeps scrolling fluid even when a category holds tens of thousands of files, where a SwiftUI List still janks.

import AppKit
import SwiftUI

/// SwiftUI wrapper around an `NSTableView` for the manager's right-hand item
/// list. The list is the one pane that can hold a very large number of rows, and
/// AppKit's view-based row recycling scrolls far more smoothly there than a
/// SwiftUI `List`. Selection stays owned by the caller: the table reads it
/// through `isSelected` and reports taps through `onToggle`.
struct ManagerItemTable: NSViewRepresentable {
    let items: [ManagerItem]
    let showsSelection: Bool
    let isSelected: (String) -> Bool
    let onToggle: (String) -> Void
    /// Accent for the checked checkbox, so it matches the section's glow.
    let accent: Color
    let rowHeight: CGFloat
    /// Changes whenever the displayed *content* (category, sort, or search)
    /// changes, so the bridge reloads rows then — and only refreshes checkbox
    /// state (no reload) on a selection toggle.
    let contentToken: String
    let accessibilityPrefix: String
    /// When true the table and its scroll view adopt the aqua (light) appearance
    /// so their row text reads dark-on-white — matching the Cleanup Manager's
    /// white surface. AppKit views follow `effectiveAppearance`, not SwiftUI's
    /// `colorScheme`, so this must be set explicitly here.
    var forcesLightAppearance: Bool = false
    /// When true each row shows a decorative pink sparkle before its size.
    var showsSparkle: Bool = false
    /// Whether an expandable row (by `ManagerItem.id`) is currently disclosed —
    /// drives the chevron direction.
    var isExpanded: (String) -> Bool = { _ in false }
    /// Toggle an expandable row's disclosure (chevron tap).
    var onToggleExpand: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.target = context.coordinator
        table.action = #selector(Coordinator.rowClicked(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        context.coordinator.table = table
        context.coordinator.apply(self)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.documentView = table
        if forcesLightAppearance {
            let aqua = NSAppearance(named: .aqua)
            scroll.appearance = aqua
            table.appearance = aqua
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let reload = coordinator.contentToken != contentToken
        coordinator.apply(self)
        if reload {
            coordinator.table?.reloadData()
            coordinator.table?.scroll(.zero)
        } else {
            coordinator.refreshVisibleSelection()
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var items: [ManagerItem] = []
        private var showsSelection = true
        private var isSelected: (String) -> Bool = { _ in false }
        private var onToggle: (String) -> Void = { _ in }
        private var accent: NSColor = .controlAccentColor
        private var accessibilityPrefix = ""
        private var showsSparkle = false
        private var isExpanded: (String) -> Bool = { _ in false }
        private var onToggleExpand: (String) -> Void = { _ in }
        private var roundedCheckbox = false
        fileprivate var contentToken = ""
        weak var table: NSTableView?

        func apply(_ source: ManagerItemTable) {
            items = source.items
            showsSelection = source.showsSelection
            isSelected = source.isSelected
            onToggle = source.onToggle
            accent = NSColor(source.accent)
            accessibilityPrefix = source.accessibilityPrefix
            showsSparkle = source.showsSparkle
            isExpanded = source.isExpanded
            onToggleExpand = source.onToggleExpand
            // The white Cleanup card uses the rounded, accent-outlined checkbox.
            roundedCheckbox = source.forcesLightAppearance
            contentToken = source.contentToken
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("ManagerRow")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ManagerRowCellView)
                ?? ManagerRowCellView(reuseIdentifier: id)
            guard row < items.count else { return cell }
            let item = items[row]
            cell.configure(
                item: item,
                selected: showsSelection && isSelected(item.id),
                showsCheckbox: showsSelection,
                accent: accent,
                showsSparkle: showsSparkle,
                isExpanded: isExpanded(item.id),
                onToggleExpand: onToggleExpand,
                roundedCheckbox: roundedCheckbox
            )
            cell.setAccessibilityIdentifier("\(accessibilityPrefix).item.\(item.id)")
            return cell
        }

        @objc func rowClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard showsSelection, row >= 0, row < items.count else { return }
            onToggle(items[row].id)
        }

        /// Refresh only the checkbox state of on-screen rows — used on a
        /// selection change so a toggle doesn't reload the whole table.
        func refreshVisibleSelection() {
            guard let table else { return }
            let range = table.rows(in: table.visibleRect)
            guard range.length > 0 else { return }
            for row in range.location..<(range.location + range.length) where row < items.count {
                guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ManagerRowCellView else { continue }
                cell.setSelected(showsSelection && isSelected(items[row].id), accent: accent)
            }
        }
    }
}

/// A native, recycled row cell: an optional indent, a checkbox, a tinted icon
/// or real Finder icon, a title + optional subtitle, an optional decorative
/// sparkle, a right-aligned size, and an optional disclosure chevron. Built from
/// AppKit controls (not SwiftUI) so the table can recycle it cheaply while
/// scrolling.
final class ManagerRowCellView: NSTableCellView {
    private let indentSpacer = NSView()
    private let checkbox = NSImageView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let sparkleView = NSImageView()
    private let sizeField = NSTextField(labelWithString: "")
    private let chevron = NSButton()
    private let textStack: NSStackView
    private let rowStack: NSStackView
    private var indentWidth: NSLayoutConstraint!

    /// Per-indent-level inset (matches the icon column so children line up).
    private static let indentStep: CGFloat = 28

    /// Invoked when the disclosure chevron is clicked. Set per `configure`.
    private var onChevron: (() -> Void)?
    /// Whether to draw the rounded, accent-outlined checkbox (Cleanup card)
    /// instead of the system SF-symbol checkbox.
    private var roundedCheckbox = false

    init(reuseIdentifier: NSUserInterfaceItemIdentifier) {
        textStack = NSStackView(views: [titleField, subtitleField])
        rowStack = NSStackView(views: [indentSpacer, checkbox, iconView, textStack, sparkleView, sizeField, chevron])
        super.init(frame: .zero)
        self.identifier = reuseIdentifier
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func setup() {
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleField.lineBreakMode = .byTruncatingMiddle
        subtitleField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sparkleView.image = ManagerSymbolCache.image("sparkles", pointSize: 14)
        sparkleView.contentTintColor = .systemPink
        sparkleView.setContentHuggingPriority(.required, for: .horizontal)

        sizeField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        sizeField.textColor = .secondaryLabelColor
        sizeField.alignment = .right
        sizeField.setContentHuggingPriority(.required, for: .horizontal)
        sizeField.setContentCompressionResistancePriority(.required, for: .horizontal)
        // Fixed-width, right-aligned size column so every row's size lines up,
        // parents and indented children alike.
        sizeField.widthAnchor.constraint(equalToConstant: 86).isActive = true

        chevron.isBordered = false
        chevron.bezelStyle = .regularSquare
        chevron.imagePosition = .imageOnly
        chevron.target = self
        chevron.action = #selector(chevronTapped)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        // The chevron always reserves its column even on rows without children,
        // so the size column to its left stays aligned across every row.
        chevron.widthAnchor.constraint(equalToConstant: 16).isActive = true

        checkbox.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        indentSpacer.setContentHuggingPriority(.required, for: .horizontal)
        indentWidth = indentSpacer.widthAnchor.constraint(equalToConstant: 0)
        indentWidth.isActive = true

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 12
        rowStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowStack)
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(
        item: ManagerItem,
        selected: Bool,
        showsCheckbox: Bool,
        accent: NSColor,
        showsSparkle: Bool,
        isExpanded: Bool,
        onToggleExpand: @escaping (String) -> Void,
        roundedCheckbox: Bool
    ) {
        self.roundedCheckbox = roundedCheckbox
        indentWidth.constant = CGFloat(item.indentLevel) * Self.indentStep
        checkbox.isHidden = !showsCheckbox
        if item.usesFileIcon {
            // The real Finder icon for the file/app, so rows read like Finder.
            iconView.image = ManagerFileIconCache.icon(forPath: item.id)
            iconView.contentTintColor = nil
        } else {
            iconView.image = ManagerSymbolCache.image(item.systemImage, pointSize: 16)
            iconView.contentTintColor = item.tint.nsColor
        }
        titleField.stringValue = item.title
        if let subtitle = item.subtitle {
            subtitleField.stringValue = subtitle
            subtitleField.isHidden = false
        } else {
            subtitleField.isHidden = true
        }
        sparkleView.isHidden = !showsSparkle
        if let sizeText = item.sizeText {
            sizeField.stringValue = sizeText
            sizeField.isHidden = false
        } else {
            sizeField.isHidden = true
        }

        // Disclosure chevron: pointing down when open. Expandable rows show and
        // enable it; others keep the reserved column (alpha 0) so the size
        // column stays aligned. The button consumes its own click so it never
        // toggles selection.
        if item.isExpandable {
            chevron.image = ManagerSymbolCache.image(isExpanded ? "chevron.down" : "chevron.right", pointSize: 13)
            chevron.contentTintColor = accent
            chevron.alphaValue = 1
            chevron.isEnabled = true
            let id = item.id
            onChevron = { onToggleExpand(id) }
        } else {
            chevron.image = nil
            chevron.alphaValue = 0
            chevron.isEnabled = false
            onChevron = nil
        }

        setSelected(selected, accent: accent)
    }

    @objc private func chevronTapped() { onChevron?() }

    func setSelected(_ selected: Bool, accent: NSColor) {
        guard !checkbox.isHidden else { return }
        if roundedCheckbox {
            // A rounded square: an accent-outlined box when unchecked, filled
            // with a white check when selected — matching the reference card.
            checkbox.image = ManagerCheckboxImage.image(checked: selected, accent: accent)
            checkbox.contentTintColor = nil
        } else {
            checkbox.image = ManagerSymbolCache.image(
                selected ? "checkmark.square.fill" : "square",
                pointSize: 15
            )
            checkbox.contentTintColor = selected ? accent : .tertiaryLabelColor
        }
    }
}

/// Caches the few SF Symbol images the rows reuse, so scrolling doesn't
/// re-create them. Main-thread only (cells are configured on the main actor).
private enum ManagerSymbolCache {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String, pointSize: CGFloat) -> NSImage? {
        let key = "\(name)|\(pointSize)"
        if let cached = cache[key] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
        cache[key] = image
        return image
    }
}

/// Draws and caches the rounded checkbox used on the Cleanup card: an
/// accent-outlined rounded square when unchecked, filled with a white check when
/// selected. Keyed by checked-state + accent so it redraws only when those
/// change. Main-thread only (cells are configured on the main actor).
private enum ManagerCheckboxImage {
    private static var cache: [String: NSImage] = [:]

    static func image(checked: Bool, accent: NSColor) -> NSImage {
        let srgb = accent.usingColorSpace(.sRGB) ?? accent
        let key = "\(checked)|\(Int(srgb.redComponent * 255))-\(Int(srgb.greenComponent * 255))-\(Int(srgb.blueComponent * 255))"
        if let cached = cache[key] { return cached }

        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let box = NSRect(x: 1.5, y: 1.5, width: side - 3, height: side - 3)
            let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
            if checked {
                accent.setFill()
                path.fill()
                let check = NSBezierPath()
                check.lineWidth = 2
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.move(to: NSPoint(x: box.minX + box.width * 0.26, y: box.minY + box.height * 0.52))
                check.line(to: NSPoint(x: box.minX + box.width * 0.43, y: box.minY + box.height * 0.34))
                check.line(to: NSPoint(x: box.minX + box.width * 0.74, y: box.minY + box.height * 0.68))
                NSColor.white.setStroke()
                check.stroke()
            } else {
                // A softened accent for the empty outline so it reads as a light
                // pink border rather than the bolder filled state.
                let outline = accent.blended(withFraction: 0.25, of: .white) ?? accent
                outline.setStroke()
                path.lineWidth = 1.5
                path.stroke()
            }
            return true
        }
        cache[key] = image
        return image
    }
}

/// Caches the real Finder icons the Cleanup Manager rows show, keyed by path.
/// `NSWorkspace.icon(forFile:)` is reasonably fast and OS-cached, but caching
/// the sized `NSImage` here keeps scrolling smooth for large categories.
/// Main-thread only (cells are configured on the main actor).
private enum ManagerFileIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(forPath path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 28, height: 28)
        cache[path] = image
        return image
    }
}

extension ManagerTint {
    /// AppKit counterpart of `color`, for the native table rows.
    var nsColor: NSColor {
        switch self {
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .purple: return .systemPurple
        case .secondary: return .secondaryLabelColor
        }
    }
}
