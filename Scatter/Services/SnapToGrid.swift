import Foundation
import CoreGraphics

enum SnapToGrid {
    static let origin = CGPoint(x: 24, y: 24)

    /// Fully empty grid rows (no items) use this fraction of a normal occupied row pitch.
    private static let emptyRowHeightFactor: CGFloat = 0.5

    struct Cell: Hashable {
        var column: Int
        var row: Int
    }

    private static func cellSize(settings: AppState.Settings) -> CGSize {
        let tileW = TileMetrics.itemWidth(iconSize: settings.iconSize)
        let tileH = TileMetrics.itemHeight(iconSize: settings.iconSize, labelSize: settings.labelSize)
        return CGSize(
            width: tileW + settings.gridSpacingHorizontal,
            height: tileH + settings.gridSpacingVertical
        )
    }

    /// Uniform full-row pitch for migrating legacy layouts that only stored `position`.
    static func legacyCellSize(settings: AppState.Settings) -> CGSize {
        cellSize(settings: settings)
    }

    private static func fullRowHeight(settings: AppState.Settings) -> CGFloat {
        cellSize(settings: settings).height
    }

    private static func emptyRowHeight(settings: AppState.Settings) -> CGFloat {
        fullRowHeight(settings: settings) * emptyRowHeightFactor
    }

    /// Axis-aligned union of all item tiles (top-leading canvas coords). `.null` when empty.
    static func contentBounds(items: [LauncherItem], settings: AppState.Settings) -> CGRect {
        guard let first = items.first else { return .null }
        let tileW = TileMetrics.itemWidth(iconSize: settings.iconSize)
        let tileH = TileMetrics.itemHeight(iconSize: settings.iconSize, labelSize: settings.labelSize)
        var bounds = CGRect(x: first.position.x, y: first.position.y, width: tileW, height: tileH)
        for item in items.dropFirst() {
            bounds = bounds.union(
                CGRect(x: item.position.x, y: item.position.y, width: tileW, height: tileH)
            )
        }
        return bounds
    }

    // MARK: - Apply grid → absolute positions (empty rows = half height)

    /// Renumber `gridRow` so consecutive empty indices become a single empty row.
    /// Leading empties pack away (first occupied → 0). At most one empty between occupied rows.
    private static func collapseConsecutiveEmptyRows(items: inout [LauncherItem]) {
        let occupied = Set(items.map(\.gridRow)).sorted()
        guard !occupied.isEmpty else { return }

        var mapping: [Int: Int] = [:]
        var nextNew = 0
        var prevOld: Int?
        for old in occupied {
            if let prev = prevOld, old - prev > 1 {
                nextNew += 1 // keep one spacer
            }
            mapping[old] = nextNew
            nextNew += 1
            prevOld = old
        }

        guard mapping.contains(where: { $0.key != $0.value }) else { return }

        for i in items.indices {
            if let mapped = mapping[items[i].gridRow] {
                items[i].gridRow = mapped
            }
        }
    }

    /// Rewrite every item’s `position` from its `gridColumn`/`gridRow`.
    /// Collapses consecutive empty rows to one, then empty indices use half pitch.
    static func applyCompressedPositions(items: inout [LauncherItem], settings: AppState.Settings) {
        collapseConsecutiveEmptyRows(items: &items)
        let occupiedRows = Set(items.map(\.gridRow))
        for i in items.indices {
            items[i].position = .init(
                positionForGrid(
                    row: items[i].gridRow,
                    column: items[i].gridColumn,
                    occupiedRows: occupiedRows,
                    settings: settings
                )
            )
        }
    }

    private static func applyAssignments(
        _ assignments: [UUID: Cell],
        to items: inout [LauncherItem],
        settings: AppState.Settings
    ) {
        for i in items.indices {
            guard let cell = assignments[items[i].id] else { continue }
            items[i].gridColumn = cell.column
            items[i].gridRow = cell.row
        }
        applyCompressedPositions(items: &items, settings: settings)
    }

    /// Whether Insert Row would create a visible spacer before `row`.
    /// False at the top occupied row (leading empties pack away) or when `row - 1` is already empty.
    static func canInsertEmptyRow(before row: Int, items: [LauncherItem]) -> Bool {
        let target = max(0, row)
        guard target > 0 else { return false }
        return items.contains { $0.gridRow == target - 1 }
    }

    /// Open an empty grid row at `row` by shifting every item on/below that row down by one.
    /// Compression still keeps at most one empty between occupied rows.
    static func insertEmptyRow(
        before row: Int,
        items: inout [LauncherItem],
        settings: AppState.Settings
    ) {
        guard canInsertEmptyRow(before: row, items: items) else { return }
        let target = max(0, row)
        for i in items.indices where items[i].gridRow >= target {
            items[i].gridRow += 1
        }
        applyCompressedPositions(items: &items, settings: settings)
    }

    /// Open an empty grid column at `column` by shifting every item on/right of that column right by one.
    static func insertEmptyColumn(
        before column: Int,
        items: inout [LauncherItem],
        settings: AppState.Settings
    ) {
        let target = max(0, column)
        for i in items.indices where items[i].gridColumn >= target {
            items[i].gridColumn += 1
        }
        applyCompressedPositions(items: &items, settings: settings)
    }

    /// True when no item occupies `row` and at least one item sits below it (delete would shift).
    static func canDeleteEmptyRow(_ row: Int, items: [LauncherItem]) -> Bool {
        let target = max(0, row)
        guard !items.contains(where: { $0.gridRow == target }) else { return false }
        return items.contains { $0.gridRow > target }
    }

    /// True when no item occupies `column` and at least one item sits to its right (delete would shift).
    static func canDeleteEmptyColumn(_ column: Int, items: [LauncherItem]) -> Bool {
        let target = max(0, column)
        guard !items.contains(where: { $0.gridColumn == target }) else { return false }
        return items.contains { $0.gridColumn > target }
    }

    /// Remove empty `row` by shifting every item below it up by one.
    static func deleteEmptyRow(
        _ row: Int,
        items: inout [LauncherItem],
        settings: AppState.Settings
    ) {
        guard canDeleteEmptyRow(row, items: items) else { return }
        let target = max(0, row)
        for i in items.indices where items[i].gridRow > target {
            items[i].gridRow -= 1
        }
        applyCompressedPositions(items: &items, settings: settings)
    }

    /// Remove empty `column` by shifting every item to its right left by one.
    static func deleteEmptyColumn(
        _ column: Int,
        items: inout [LauncherItem],
        settings: AppState.Settings
    ) {
        guard canDeleteEmptyColumn(column, items: items) else { return }
        let target = max(0, column)
        for i in items.indices where items[i].gridColumn > target {
            items[i].gridColumn -= 1
        }
        applyCompressedPositions(items: &items, settings: settings)
    }

    /// Map a canvas click/point to the nearest grid cell (compressed empty-row strips).
    /// Unlike drag targeting, `point` is the probe itself (not a tile top-left).
    static func hitTestCell(
        at point: CGPoint,
        items: [LauncherItem],
        settings: AppState.Settings,
        canvasSize: CGSize
    ) -> Cell {
        let occupiedRows = Set(items.map(\.gridRow))
        let bounds = gridBounds(canvasSize: canvasSize, settings: settings)
        let size = cellSize(settings: settings)
        guard size.width > 0 else { return Cell(column: 0, row: 0) }
        let column = Int(round((point.x - origin.x) / size.width))

        var bestRow = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        var y = origin.y
        for row in 0...max(0, bounds.row) {
            let h = rowHeight(row: row, occupiedRows: occupiedRows, settings: settings)
            let center = y + h / 2
            let dist = abs(point.y - center)
            if dist < bestDist {
                bestDist = dist
                bestRow = row
            }
            y += h
        }
        return clamp(Cell(column: max(0, column), row: bestRow), to: bounds)
    }

    /// Resolve an item’s grid cell from stored coordinates.
    static func cell(of item: LauncherItem) -> Cell {
        Cell(column: item.gridColumn, row: item.gridRow)
    }

    // MARK: - Interactive layout

    /// Where `itemID` would land (drag ghost).
    /// Row pick uses distance to each strip’s **vertical center** (half-height empty rows
    /// included). Ghost is vertically centered in the landing strip. Origin row stays
    /// occupied for geometry until drop commits.
    static func previewFrame(
        itemID: UUID,
        proposed: CGPoint,
        items: [LauncherItem],
        settings: AppState.Settings,
        canvasSize: CGSize
    ) -> CGRect {
        guard let plan = placementPlan(
            itemID: itemID,
            proposed: proposed,
            items: items,
            settings: settings,
            canvasSize: canvasSize
        ) else { return .null }

        let w = TileMetrics.itemWidth(iconSize: settings.iconSize)
        let h = TileMetrics.itemHeight(iconSize: settings.iconSize, labelSize: settings.labelSize)
        let top = positionForGrid(
            row: plan.landing.row,
            column: plan.landing.column,
            occupiedRows: plan.occupiedRowsForGeometry,
            settings: settings
        )
        let rowH = rowHeight(
            row: plan.landing.row,
            occupiedRows: plan.occupiedRowsForGeometry,
            settings: settings
        )
        // Center the ghost in the row strip (works for full and half-height rows).
        let centeredY = top.y + (rowH - h) / 2
        return CGRect(x: top.x, y: centeredY, width: w, height: h)
    }

    static func placeReplacing(
        itemID: UUID,
        proposed: CGPoint,
        items: [LauncherItem],
        settings: AppState.Settings,
        canvasSize: CGSize
    ) -> [LauncherItem] {
        var result = items
        guard let plan = placementPlan(
            itemID: itemID,
            proposed: proposed,
            items: items,
            settings: settings,
            canvasSize: canvasSize
        ) else { return items }

        var assignments = plan.assignments
        assignments[itemID] = plan.landing
        applyAssignments(assignments, to: &result, settings: settings)
        return result
    }

    private struct PlacementPlan {
        var landing: Cell
        var assignments: [UUID: Cell] // others only
        var occupiedRowsForGeometry: Set<Int>
    }

    /// Shared drop-target resolution for preview + commit.
    private static func placementPlan(
        itemID: UUID,
        proposed: CGPoint,
        items: [LauncherItem],
        settings: AppState.Settings,
        canvasSize: CGSize
    ) -> PlacementPlan? {
        guard let dragging = items.first(where: { $0.id == itemID }) else { return nil }

        let bounds = gridBounds(canvasSize: canvasSize, settings: settings)
        let originCell = cell(of: dragging)

        // Geometry while dragging: origin row still occupied (matches on-screen layout).
        var occupiedRowsForGeometry = Set(items.map { cell(of: $0).row })
        occupiedRowsForGeometry.insert(originCell.row)

        let target = clamp(
            cell(
                for: proposed,
                occupiedRows: occupiedRowsForGeometry,
                settings: settings,
                bounds: bounds
            ),
            to: bounds
        )

        var assignments: [UUID: Cell] = [:]
        for item in items where item.id != itemID {
            assignments[item.id] = cell(of: item)
        }
        resolveDuplicateAssignments(bounds: bounds, assignments: &assignments)
        if assignments.values.contains(target) {
            insertOpeningOneCell(at: target, bounds: bounds, assignments: &assignments)
        }

        // Do NOT mark landing row occupied for preview geometry — an empty half-height
        // strip must stay half-height so the ghost can center in it (may overlap neighbors).
        return PlacementPlan(
            landing: target,
            assignments: assignments,
            occupiedRowsForGeometry: occupiedRowsForGeometry
        )
    }

    private static func rowHeight(row: Int, occupiedRows: Set<Int>, settings: AppState.Settings) -> CGFloat {
        occupiedRows.contains(row)
            ? fullRowHeight(settings: settings)
            : emptyRowHeight(settings: settings)
    }

    private static func resolveDuplicateAssignments(bounds: Cell, assignments: inout [UUID: Cell]) {
        // Stable order so which duplicate keeps the cell does not depend on Dictionary hash order.
        let ordered = assignments.sorted { $0.key.uuidString < $1.key.uuidString }
        var seen: [Cell: UUID] = [:]
        var duplicates: [(UUID, Cell)] = []
        for (id, cell) in ordered {
            if seen[cell] != nil {
                duplicates.append((id, cell))
            } else {
                seen[cell] = id
            }
        }
        var occupied = Set(assignments.values)
        for (id, preferred) in duplicates {
            occupied.remove(assignments[id]!)
            let free = nearestFreeCell(from: preferred, occupied: occupied, bounds: bounds)
            assignments[id] = free
            occupied.insert(free)
        }
    }

    private static func insertOpeningOneCell(
        at target: Cell,
        bounds: Cell,
        assignments: inout [UUID: Cell]
    ) {
        let occupied = Set(
            assignments.values
                .filter { $0.row == target.row }
                .map(\.column)
        )

        var gap: Int?
        for col in target.column...bounds.column {
            if !occupied.contains(col) {
                gap = col
                break
            }
        }

        if let gap {
            let toShift = assignments
                .filter {
                    $0.value.row == target.row
                        && $0.value.column >= target.column
                        && $0.value.column < gap
                }
                .sorted { $0.value.column < $1.value.column }
            for entry in toShift.reversed() {
                assignments[entry.key] = Cell(column: entry.value.column + 1, row: target.row)
            }
            return
        }

        let toShift = assignments
            .filter { $0.value.row == target.row && $0.value.column >= target.column }
            .sorted { $0.value.column < $1.value.column }

        var overflow: [UUID] = []
        for entry in toShift.reversed() {
            let newColumn = entry.value.column + 1
            if newColumn > bounds.column {
                overflow.insert(entry.key, at: 0)
                assignments.removeValue(forKey: entry.key)
            } else {
                assignments[entry.key] = Cell(column: newColumn, row: target.row)
            }
        }

        if !overflow.isEmpty {
            wrapInsert(overflow, ontoRow: target.row + 1, bounds: bounds, assignments: &assignments)
        }
    }

    private static func wrapInsert(
        _ overflow: [UUID],
        ontoRow row: Int,
        bounds: Cell,
        assignments: inout [UUID: Cell]
    ) {
        guard !overflow.isEmpty else { return }

        let columnsPerRow = bounds.column + 1
        var remaining = overflow

        let fitCount = min(remaining.count, columnsPerRow)
        let head = Array(remaining.prefix(fitCount))
        remaining = Array(remaining.suffix(from: fitCount))

        for column in 0..<head.count {
            let cell = Cell(column: column, row: row)
            if assignments.values.contains(cell) {
                insertOpeningOneCell(at: cell, bounds: bounds, assignments: &assignments)
            }
        }

        for (index, id) in head.enumerated() {
            assignments[id] = Cell(column: index, row: row)
        }

        if !remaining.isEmpty {
            // Allow one extra row past the canvas bounds so overflow can land; column width stays clamped.
            let nextBounds = Cell(column: bounds.column, row: max(bounds.row, row + 1))
            wrapInsert(remaining, ontoRow: row + 1, bounds: nextBounds, assignments: &assignments)
        }
    }

    static func gridBounds(canvasSize: CGSize?, settings: AppState.Settings) -> Cell {
        let size = cellSize(settings: settings)
        // Bound drop rows using empty-row pitch so half-height strips remain addressable.
        let emptyH = emptyRowHeight(settings: settings)
        guard let canvasSize, size.width > 0, emptyH > 0 else {
            return Cell(column: 5, row: 8)
        }
        let usableWidth = max(size.width, canvasSize.width - origin.x)
        let usableHeight = max(emptyH, canvasSize.height - origin.y)
        let tileW = TileMetrics.itemWidth(iconSize: settings.iconSize)
        let tileH = TileMetrics.itemHeight(iconSize: settings.iconSize, labelSize: settings.labelSize)
        let maxColumn = max(0, Int(floor((usableWidth - tileW) / size.width)))
        let maxRow = max(0, Int(floor((usableHeight - tileH) / emptyH)))
        return Cell(column: maxColumn, row: maxRow)
    }

    private static func clamp(_ cell: Cell, to bounds: Cell) -> Cell {
        Cell(
            column: min(max(0, cell.column), bounds.column),
            row: min(max(0, cell.row), bounds.row)
        )
    }

    /// Sparse-row layout: empty row indices use half pitch.
    static func positionForGrid(
        row: Int,
        column: Int,
        occupiedRows: Set<Int>,
        settings: AppState.Settings
    ) -> CGPoint {
        let size = cellSize(settings: settings)
        var y = origin.y
        if row > 0 {
            for r in 0..<row {
                y += occupiedRows.contains(r)
                    ? fullRowHeight(settings: settings)
                    : emptyRowHeight(settings: settings)
            }
        }
        return CGPoint(
            x: origin.x + Double(max(0, column)) * size.width,
            y: y
        )
    }

    /// Drop targeting: column from uniform X; row = nearest strip by **vertical center**.
    /// Probe uses the item tile’s vertical center (`point` is top-left).
    static func cell(
        for point: CGPoint,
        occupiedRows: Set<Int>,
        settings: AppState.Settings,
        bounds: Cell
    ) -> Cell {
        let size = cellSize(settings: settings)
        guard size.width > 0 else { return Cell(column: 0, row: 0) }
        let column = Int(round((point.x - origin.x) / size.width))
        let tileH = TileMetrics.itemHeight(iconSize: settings.iconSize, labelSize: settings.labelSize)
        let probeY = point.y + tileH / 2

        var bestRow = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        var y = origin.y
        for row in 0...max(0, bounds.row) {
            let h = rowHeight(row: row, occupiedRows: occupiedRows, settings: settings)
            let center = y + h / 2
            let dist = abs(probeY - center)
            if dist < bestDist {
                bestDist = dist
                bestRow = row
            }
            y += h
        }
        return clamp(Cell(column: max(0, column), row: bestRow), to: bounds)
    }

    /// First free cell + top-left point in row-major order (for ⌘V / auto-place).
    static func nextFreePlacement(
        items: [LauncherItem],
        settings: AppState.Settings,
        canvasSize: CGSize
    ) -> (point: CGPoint, cell: Cell) {
        let bounds = gridBounds(canvasSize: canvasSize, settings: settings)
        let occupied = Set(items.map { cell(of: $0) })
        let free = nearestFreeCell(from: Cell(column: 0, row: 0), occupied: occupied, bounds: bounds)
        let occupiedRows = Set(items.map(\.gridRow)).union([free.row])
        let point = positionForGrid(
            row: free.row,
            column: free.column,
            occupiedRows: occupiedRows,
            settings: settings
        )
        return (point, free)
    }

    /// Top-left of the first free cell in row-major order (for ⌘V / auto-place).
    static func nextFreePosition(
        items: [LauncherItem],
        settings: AppState.Settings,
        canvasSize: CGSize
    ) -> CGPoint {
        nextFreePlacement(items: items, settings: settings, canvasSize: canvasSize).point
    }

    static func nearestFreeCell(from preferred: Cell, occupied: Set<Cell>, bounds: Cell? = nil) -> Cell {
        let start = Cell(column: max(0, preferred.column), row: max(0, preferred.row))
        if !occupied.contains(start) { return start }

        let limit = bounds ?? Cell(column: 64, row: 64)
        if let free = firstFreeCell(preferringAfter: start, occupied: occupied, bounds: limit) {
            return free
        }

        for radius in 1...64 {
            for row in (start.row - radius)...(start.row + radius) {
                for column in (start.column - radius)...(start.column + radius) {
                    if abs(row - start.row) != radius && abs(column - start.column) != radius {
                        continue
                    }
                    if row < 0 || column < 0 { continue }
                    if column > limit.column || row > limit.row { continue }
                    let candidate = Cell(column: column, row: row)
                    if !occupied.contains(candidate) {
                        return candidate
                    }
                }
            }
        }

        // Packed within limit: walk row-major with column clamp, allowing rows past `limit.row`.
        var row = 0
        while row < limit.row + occupied.count + 2 {
            for column in 0...limit.column {
                let candidate = Cell(column: column, row: row)
                if !occupied.contains(candidate) {
                    return candidate
                }
            }
            row += 1
        }
        return Cell(column: min(start.column, limit.column), row: limit.row)
    }

    private static func firstFreeCell(
        preferringAfter from: Cell,
        occupied: Set<Cell>,
        bounds: Cell
    ) -> Cell? {
        if from.column + 1 <= bounds.column {
            for column in (from.column + 1)...bounds.column {
                let candidate = Cell(column: column, row: from.row)
                if !occupied.contains(candidate) { return candidate }
            }
        }
        if from.row + 1 <= bounds.row {
            for row in (from.row + 1)...bounds.row {
                for column in 0...bounds.column {
                    let candidate = Cell(column: column, row: row)
                    if !occupied.contains(candidate) { return candidate }
                }
            }
        }
        return nil
    }
}
