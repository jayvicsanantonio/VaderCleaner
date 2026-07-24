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
    /// Changes whenever the *selection* changes (the host's selection revision).
    /// When set, `updateNSView` refreshes visible checkbox state only when this
    /// moves, so the frequent SwiftUI updates that fire during momentum
    /// scrolling — same content, same selection — don't re-walk every visible
    /// row's selection each frame. A folder row over a huge subtree makes that
    /// per-frame walk the dominant scroll cost; gating on this token removes it.
    /// `nil` (the default) keeps the always-refresh behavior for the small flat
    /// managers that don't track a revision — without it a toggle wouldn't
    /// repaint the checkbox, since its image is driven by `isSelected`, not by
    /// the click.
    var selectionToken: Int? = nil
    let accessibilityPrefix: String
    /// When true the table and its scroll view adopt the aqua (light) appearance
    /// so their row text reads dark-on-white — matching the Cleanup Manager's
    /// white surface. AppKit views follow `effectiveAppearance`, not SwiftUI's
    /// `colorScheme`, so this must be set explicitly here.
    var forcesLightAppearance: Bool = false
    /// When true each row shows a decorative accent-tinted sparkle before its size.
    var showsSparkle: Bool = false
    /// Whether an expandable row (by `ManagerItem.id`) is currently disclosed —
    /// drives the chevron direction.
    var isExpanded: (String) -> Bool = { _ in false }
    /// Toggle an expandable row's disclosure (chevron tap).
    var onToggleExpand: (String) -> Void = { _ in }

    /// Builds the reload token for a displayed row set: the row count, an
    /// order-sensitive hash of every row id, and the sort/search inputs. Any
    /// change to the rows or their order changes the token, so the bridge
    /// reloads exactly when the content differs — including a swap in the
    /// middle of the list that a count/first/last heuristic can't see. O(n)
    /// over the ids, so callers with large lists compute it when the row set
    /// changes rather than per render; tiny lists may build it inline.
    static func contentToken(items: [ManagerItem], sort: String, search: String) -> String {
        var hasher = Hasher()
        for item in items { hasher.combine(item.id) }
        return "\(items.count)|\(hasher.finalize())|\(sort)|\(search)"
    }

    /// Whether `updateNSView` should repaint visible checkbox state. A `nil`
    /// current token means the host tracks no selection revision (the flat
    /// managers), so it must always refresh — their checkbox image is driven by
    /// `isSelected`, not by the click, and would otherwise freeze after a
    /// toggle. A non-`nil` token refreshes only when it moves, sparing the
    /// per-frame walk during momentum scrolls of the huge Cleanup Manager.
    static func shouldRefreshSelection(previous: Int?, current: Int?) -> Bool {
        current == nil || previous != current
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = HoverTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = rowHeight
        // The 10-point visual gap between row cards comes from each card's
        // 4-point vertical inset (×2) plus this spacing.
        table.intercellSpacing = NSSize(width: 0, height: 2)
        // No table-wide click action: only the row's checkbox toggles selection.
        table.onHoverRowChange = { [weak coordinator = context.coordinator] row in
            coordinator?.setHoveredRow(row)
        }

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
        let selectionChanged = Self.shouldRefreshSelection(
            previous: coordinator.selectionToken,
            current: selectionToken
        )
        coordinator.apply(self)
        if reload {
            coordinator.setHoveredRow(nil) // a stale hover index can't survive a reload
            coordinator.table?.reloadData()
            coordinator.table?.scroll(.zero)
        } else if selectionChanged {
            // Only when the selection actually moved — otherwise the many
            // no-op SwiftUI updates during a momentum scroll would each re-walk
            // every visible row's selection, and a folder row over a huge
            // subtree makes that walk the scroll's dominant cost.
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
        fileprivate var contentToken = ""
        fileprivate var selectionToken: Int? = nil
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
            contentToken = source.contentToken
            selectionToken = source.selectionToken
        }

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("ManagerRow")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? ManagerRowCellView)
                ?? ManagerRowCellView(reuseIdentifier: id)
            // A row queried past the data (mid-reload) renders nothing rather
            // than a stray sparkle from a never-configured cell.
            guard row < items.count else { cell.blank(); return cell }
            let item = items[row]
            cell.configure(
                item: item,
                selected: showsSelection && isSelected(item.id),
                showsCheckbox: showsSelection,
                accent: accent,
                showsSparkle: showsSparkle,
                isExpanded: isExpanded(item.id),
                onToggleExpand: onToggleExpand,
                onToggleSelection: onToggle
            )
            cell.setAccessibilityIdentifier("\(accessibilityPrefix).item.\(item.id)")
            return cell
        }

        /// Vends a row view that draws the card background and hover highlight.
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("HoverRow")
            let view = (tableView.makeView(withIdentifier: id, owner: self) as? HoverTableRowView)
                ?? HoverTableRowView()
            view.identifier = id
            view.isHovered = (row == hoveredRow)
            return view
        }

        private var hoveredRow: Int?

        /// Move the hover highlight to `row` (or clear it), redrawing only the
        /// row views that changed.
        func setHoveredRow(_ row: Int?) {
            let newRow = (row.map { $0 >= 0 && $0 < items.count ? $0 : nil } ?? nil)
            guard newRow != hoveredRow else { return }
            let previous = hoveredRow
            hoveredRow = newRow
            guard let table else { return }
            for index in [previous, newRow].compactMap({ $0 }) {
                (table.rowView(atRow: index, makeIfNecessary: false) as? HoverTableRowView)?.isHovered = index == newRow
            }
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

/// `NSTableView` that reports which row the pointer is over so the delegate can
/// draw a hover highlight (the table has no system selection highlight).
final class HoverTableView: NSTableView {
    var onHoverRowChange: ((Int?) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        onHoverRowChange?(row >= 0 ? row : nil)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverRowChange?(nil)
    }
}

/// Row view that draws each row as a rounded card — the same look as the
/// SwiftUI glass card rows in the manager panes — plus a soft hover tint over
/// the card.
final class HoverTableRowView: NSTableRowView {
    var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        // Inset to the panes' 24-point content margin; the vertical inset pairs
        // with the table's intercell spacing to form the gap between cards.
        let card = bounds.insetBy(dx: 24, dy: 4)
        let path = NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12)
        let isLight = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        if isLight {
            // A white card with a soft shadow and hairline border, standing in
            // for SwiftUI's glass card on the white manager surface.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.10)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSColor.white.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.06).setStroke()
            path.lineWidth = 1
            path.stroke()
        } else {
            // A translucent white card over the section's dark gradient.
            NSColor.white.withAlphaComponent(0.08).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.12).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        guard isHovered else { return }
        // A quieter magenta hover fill matching the manager nav rows and the
        // SwiftUI row cards, a touch stronger over the dark card so it stays
        // visible there.
        ManagerChrome.nsAccent.withAlphaComponent(isLight ? 0.08 : 0.16).setFill()
        path.fill()
    }
}

/// The "smart insights" sparkle in a manager row's trailing column. Hovering it
/// fills a rounded accent chip behind the glyph and reveals its tooltip; it has
/// no click action of its own.
final class ManagerSparkleView: NSView {
    /// The chip's fixed side length: a square larger than the 15-point glyph so
    /// the hover background reads as a squircle with padding around the sparkle.
    private static let side: CGFloat = 26

    /// The hover chip, drawn as its own centered square sublayer so it stays
    /// square (a squircle) regardless of how the row stack sizes this view.
    private let chipLayer = CALayer()
    /// The sparkle glyph, centered on top of the chip.
    private let glyph = NSImageView()
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false
    /// The popover presented on click, reused so a second click toggles it shut.
    private var insightsPopover: NSPopover?

    /// The row's display name, summarized by the Smart Insights popover.
    var itemTitle: String = ""
    /// The manager accent the hover chip is tinted with, set per row so the
    /// sparkle matches the section's chevrons and checkboxes.
    private(set) var accentColor: NSColor = ManagerChrome.nsAccent

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // A squircle: a continuous corner curve rather than a plain arc.
        chipLayer.cornerRadius = 8
        chipLayer.cornerCurve = .continuous
        chipLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(chipLayer)

        glyph.image = ManagerSymbolCache.image("sparkles", pointSize: 15)
        glyph.imageScaling = .scaleNone
        glyph.imageAlignment = .alignCenter
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        toolTip = String(
            localized: "Get smart insights about this item",
            comment: "Tooltip on the smart-insights sparkle in a Cleanup Manager row."
        )
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(
            localized: "Smart Insights",
            comment: "Accessibility label for the smart-insights sparkle button in a Cleanup Manager row."
        ))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // Click the sparkle to open (or toggle shut) the Smart Insights popover. The
    // event is consumed here so it never falls through to the row or table.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        presentInsights()
    }

    /// A pointing-hand cursor so the sparkle reads as clickable on hover.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// Shows the Smart Insights popover anchored to the sparkle, or closes it if
    /// it is already open. The popover opens in its "thinking" loading state; the
    /// Apple Intelligence summary populates it once generation is wired up.
    private func presentInsights() {
        if let popover = insightsPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let popover = insightsPopover ?? NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingController(rootView: SmartInsightsPopoverView(itemTitle: itemTitle))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        insightsPopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxX)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func layout() {
        super.layout()
        // Center a fixed square chip within whatever frame the stack hands us so
        // the squircle stays square rather than following a rectangular bounds.
        let s = min(Self.side, bounds.width, bounds.height)
        chipLayer.frame = CGRect(
            x: (bounds.width - s) / 2,
            y: (bounds.height - s) / 2,
            width: s,
            height: s
        )
    }

    /// Tints the glyph and the hover chip with the manager accent.
    func setAccent(_ color: NSColor) {
        accentColor = color
        glyph.contentTintColor = color
        if isHovering { chipLayer.backgroundColor = color.withAlphaComponent(0.18).cgColor }
    }

    /// Clears the hover chip so a recycled cell never shows a stale highlight.
    func clearHover() {
        isHovering = false
        chipLayer.backgroundColor = NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        chipLayer.backgroundColor = accentColor.withAlphaComponent(0.18).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }
}

/// A native, recycled row cell: an optional indent, a checkbox, a tinted icon
/// or real Finder icon, a title + optional subtitle, an optional decorative
/// sparkle, a right-aligned size, and an optional disclosure chevron. Built from
/// AppKit controls (not SwiftUI) so the table can recycle it cheaply while
/// scrolling.
final class ManagerRowCellView: NSTableCellView {
    private let indentSpacer = NSView()
    private let checkbox = NSButton()
    private let iconView = NSImageView()
    /// The "Kept" seal shown on a locked row (a similar-photo group's best shot),
    /// where the checkbox would be. Hidden on every other row.
    private let keptGlyph = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let sparkleView = ManagerSparkleView()
    private let sizeField = NSTextField(labelWithString: "")
    private let chevron = NSButton()
    /// Fixed square for the icon column, activated only in thumbnail mode so a
    /// Quick Look preview fills a consistent tile; symbol/Finder-icon rows keep
    /// their intrinsic size and stay pixel-identical to before.
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!
    /// The file path whose thumbnail this cell is currently expecting, so an
    /// async load that resolves after the cell was recycled is discarded.
    private var thumbnailToken: String?
    /// Point size the manager rows request thumbnails at (rendered at 2× by
    /// Quick Look), matching the 38-point icon column.
    private static let thumbnailPointSize: CGFloat = 38
    /// Flexible gap between the text and the trailing column. It absorbs the
    /// row's free space so the sparkle / size / chevron sit in a fixed right
    /// column regardless of how wide each row's text is — without it the sparkle
    /// floats just past the text and never lines up between rows.
    private let trailingSpacer = NSView()
    private let textStack: NSStackView
    private let rowStack: NSStackView
    private var indentWidth: NSLayoutConstraint!

    /// Per-indent-level inset (matches the icon column so children line up).
    private static let indentStep: CGFloat = 38

    /// Invoked when the disclosure chevron is clicked. Set per `configure`.
    private var onChevron: (() -> Void)?
    /// Invoked when the checkbox is clicked — the only way to (de)select a row.
    private var onCheckbox: (() -> Void)?

    init(reuseIdentifier: NSUserInterfaceItemIdentifier) {
        textStack = NSStackView(views: [titleField, subtitleField])
        rowStack = NSStackView(views: [indentSpacer, checkbox, iconView, textStack, trailingSpacer, keptGlyph, sparkleView, sizeField, chevron])
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

        // Hug and resist on both axes so the row stack honors the sparkle's fixed
        // square intrinsic size exactly — never stretching or compressing it into
        // a rectangle.
        sparkleView.setContentHuggingPriority(.required, for: .horizontal)
        sparkleView.setContentHuggingPriority(.required, for: .vertical)
        sparkleView.setContentCompressionResistancePriority(.required, for: .horizontal)
        sparkleView.setContentCompressionResistancePriority(.required, for: .vertical)

        // Lowest hugging so the stack hands this view all the row's slack,
        // parking the trailing column (sparkle / size / chevron) at a fixed
        // right edge across every row.
        trailingSpacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        trailingSpacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

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

        // The checkbox is a borderless image button so only a click on it
        // toggles selection (a click anywhere else in the row does nothing).
        checkbox.isBordered = false
        checkbox.bezelStyle = .regularSquare
        checkbox.imagePosition = .imageOnly
        checkbox.setButtonType(.momentaryChange)
        checkbox.title = ""
        checkbox.focusRingType = .none
        checkbox.target = self
        checkbox.action = #selector(checkboxTapped)
        checkbox.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        // Fixed square, toggled on only for thumbnail rows in `configure`.
        iconWidth = iconView.widthAnchor.constraint(equalToConstant: Self.thumbnailPointSize)
        iconHeight = iconView.heightAnchor.constraint(equalToConstant: Self.thumbnailPointSize)

        // The "Kept" seal: a green sealed checkmark sitting where the checkbox
        // would be, marking a row that is shown but can't be deleted.
        keptGlyph.image = ManagerSymbolCache.image("checkmark.seal.fill", pointSize: 16)
        keptGlyph.contentTintColor = .systemGreen
        keptGlyph.isHidden = true
        keptGlyph.setContentHuggingPriority(.required, for: .horizontal)
        keptGlyph.setContentCompressionResistancePriority(.required, for: .horizontal)
        keptGlyph.toolTip = String(localized: "Kept — this shot is the best of the group and is never removed.", comment: "Tooltip on the kept best shot in a similar-photo group.")

        indentSpacer.setContentHuggingPriority(.required, for: .horizontal)
        indentWidth = indentSpacer.widthAnchor.constraint(equalToConstant: 0)
        indentWidth.isActive = true

        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        rowStack.orientation = .horizontal
        rowStack.alignment = .centerY
        rowStack.spacing = 12
        // 24-point card inset plus the card's 14-point interior padding, so the
        // content sits inside the row's card background.
        rowStack.edgeInsets = NSEdgeInsets(top: 0, left: 38, bottom: 0, right: 38)
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
        onToggleSelection: @escaping (String) -> Void
    ) {
        indentWidth.constant = CGFloat(item.indentLevel) * Self.indentStep
        // A locked row (a similar-photo group's kept best shot) is shown for
        // context but can't be selected: no checkbox, a "Kept" seal instead.
        let rowShowsCheckbox = showsCheckbox && !item.isLocked
        checkbox.isHidden = !rowShowsCheckbox
        keptGlyph.isHidden = !item.isLocked
        let selectionID = item.id
        onCheckbox = { onToggleSelection(selectionID) }
        configureIcon(for: item)
        titleField.stringValue = item.title
        if let subtitle = item.subtitle {
            subtitleField.stringValue = subtitle
            subtitleField.isHidden = false
        } else {
            subtitleField.isHidden = true
        }
        sparkleView.isHidden = !showsSparkle || item.isLocked
        // Tint the sparkle and its hover chip with the manager's accent so it
        // matches the chevron, search, and back icons rather than a fixed pink.
        sparkleView.setAccent(accent)
        sparkleView.itemTitle = item.title
        // A recycled cell may arrive still tinted from a prior hover.
        sparkleView.clearHover()
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

    /// Draws the row's leading image in one of three modes: a Quick Look
    /// thumbnail of the file (image managers), the real Finder icon, or a tinted
    /// symbol badge. Only thumbnail mode pins the icon to a fixed rounded square
    /// and loads asynchronously — the other two stay pixel-identical to before.
    private func configureIcon(for item: ManagerItem) {
        iconView.contentTintColor = nil

        guard item.usesThumbnail else {
            thumbnailToken = nil
            iconWidth.isActive = false
            iconHeight.isActive = false
            iconView.imageScaling = .scaleProportionallyDown
            iconView.layer?.cornerRadius = 0
            iconView.layer?.borderWidth = 0
            iconView.layer?.masksToBounds = false
            if item.usesFileIcon {
                // The real Finder icon for the file/app, so rows read like
                // Finder. `iconPath` lets a row draw an icon from a path other
                // than its selection `id` (e.g. a login item keyed by bundle id).
                iconView.image = ManagerFileIconCache.icon(forPath: item.iconPath ?? item.id)
            } else {
                // A tinted gradient badge — the same look as the SwiftUI
                // `TaskIconBadge` — so symbol rows match the card panes.
                iconView.image = ManagerBadgeImageCache.image(symbol: item.systemImage, tint: item.tint)
            }
            return
        }

        // Thumbnail mode: a fixed rounded square filled with the picture.
        let path = item.iconPath ?? item.id
        thumbnailToken = path
        iconWidth.isActive = true
        iconHeight.isActive = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 6
        iconView.layer?.borderWidth = 0.5
        iconView.layer?.borderColor = NSColor.separatorColor.cgColor
        iconView.layer?.masksToBounds = true

        let url = URL(fileURLWithPath: path)
        if let cached = ClutterThumbnailCache.cached(url, pointSize: Self.thumbnailPointSize) {
            iconView.image = cached
            return
        }
        // Miss: show a neutral placeholder, then fill in when Quick Look
        // resolves — unless the cell was recycled onto a different file first.
        iconView.image = ManagerSymbolCache.image("photo", pointSize: 16)
        Task { @MainActor in
            let image = await ClutterThumbnailCache.load(url, pointSize: Self.thumbnailPointSize)
            guard self.thumbnailToken == path, let image else { return }
            self.iconView.image = image
        }
    }

    /// Clears a recycled cell so a row requested past the data shows nothing.
    func blank() {
        checkbox.isHidden = true
        keptGlyph.isHidden = true
        thumbnailToken = nil
        iconView.image = nil
        titleField.stringValue = ""
        subtitleField.isHidden = true
        sparkleView.isHidden = true
        sparkleView.clearHover()
        sizeField.isHidden = true
        chevron.image = nil
        chevron.alphaValue = 0
        chevron.isEnabled = false
        onChevron = nil
        onCheckbox = nil
    }

    @objc private func chevronTapped() { onChevron?() }
    @objc private func checkboxTapped() { onCheckbox?() }

    func setSelected(_ selected: Bool, accent: NSColor) {
        guard !checkbox.isHidden else { return }
        // A rounded square: an accent-outlined box when unchecked, filled
        // with a white check when selected — matching the reference card.
        checkbox.image = ManagerCheckboxImage.image(checked: selected, accent: accent)
        checkbox.contentTintColor = nil
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

/// Draws and caches the rounded checkbox used on every manager row: an
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

/// Draws and caches the tinted gradient icon badges for symbol rows — the same
/// look as the SwiftUI `TaskIconBadge` so table rows match the card panes.
/// Keyed by symbol + tint. Main-thread only (cells are configured on the main
/// actor).
private enum ManagerBadgeImageCache {
    private static var cache: [String: NSImage] = [:]

    static func image(symbol: String, tint: ManagerTint) -> NSImage {
        let key = "\(symbol)|\(tint)"
        if let cached = cache[key] { return cached }

        let side: CGFloat = 38
        let fill = NSColor(tint.color.deepenedForWhite).usingColorSpace(.sRGB) ?? .systemGray
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            )
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let bounds = NSRect(x: 0, y: 0, width: side, height: side)
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).addClip()
            // Top-to-bottom fade matching TaskIconBadge's LinearGradient.
            NSGradient(
                starting: fill.withAlphaComponent(0.95),
                ending: fill.withAlphaComponent(0.65)
            )?.draw(in: bounds, angle: 270)
            if let glyph {
                let size = glyph.size
                glyph.draw(in: NSRect(
                    x: (side - size.width) / 2,
                    y: (side - size.height) / 2,
                    width: size.width,
                    height: size.height
                ))
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
/// LRU-bounded so scrolling a category of tens of thousands of files can't
/// grow the cache without limit — evicted icons just re-fetch from
/// `NSWorkspace` on the next pass. Main-thread only (cells are configured on
/// the main actor).
private enum ManagerFileIconCache {
    private static var cache = LRUCache<String, NSImage>(capacity: 1024)

    static func icon(forPath path: String) -> NSImage {
        if let cached = cache.value(forKey: path) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 38, height: 38)
        cache.setValue(image, forKey: path)
        return image
    }
}
