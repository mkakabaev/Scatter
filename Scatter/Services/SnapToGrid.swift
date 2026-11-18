import Foundation
import CoreGraphics

enum SnapToGrid {
    static let origin = CGPoint(x: 24, y: 24)

    /// Fully empty grid rows (no items) use this fraction of a normal occupied row pitch.
    static let emptyRowHeightFactor: CGFloat = 0.5

    struct Cell: Hashable {
        var column: Int
        var row: Int
    }

    static func cellSize(settings: AppState.Settings) -> CGSize {
        let tileW = TileMetrics.itemWidth(iconSize: settings.iconSize)
        let tileH = TileMetrics.itemHeight(iconSize: settings.iconSize, labelSize: settings.labelSize)
        return CGSize(
            width: tileW + settings.gridSpacingHorizontal,
            height: tileH + settings.gridSpacingVertical
        )
    }

    static func fullRowHeight(settings: AppState.Settings) -> CGFloat {
        cellSize(settings: settings).height
    }

    static func emptyRowHeight(settings: AppState.Settings) -> CGFloat {
        fullRowHeight(settings: settings) * emptyRowHeightFactor
    }

    // MARK: - Apply grid → absolute positions (empty rows = half height)

    /// Renumber `gridRow` so consecutive empty indices become a single empty row.
    /// Leading empties pack away (first occupied → 0). At most one empty between occupied rows.
    static func collapseConsecutiveEmptyRows(items: inout [LauncherItem]) {
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

    static func applyAssignments(
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

    /// Resolve an item’s grid cell: prefer stored coords; bootstrap from absolute position if unset.
    static func cell(of item: LauncherItem, settings: AppState.Settings) -> Cell {
        // Treat (0,0) with a non-origin position as “legacy / needs bootstrap” only when
        // position clearly isn’t at the (0,0) slot. Otherwise trust stored grid.
        if item.gridColumn != 0 || item.gridRow != 0 {
            return Cell(column: item.gridColumn, row: item.gridRow)
        }
        let inferred = cell(for: item.position.cgPoint, settings: settings)
        if inferred.column == 0 && inferred.row == 0 {
            return inferred
        }
        // Legacy item still at default grid 0,0 but drawn elsewhere — trust position once.
        if hypot(item.position.x - origin.x, item.position.y - origin.y) > 8 {
            return inferred
        }
        return Cell(column: item.gridColumn, row: item.gridRow)
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
        let originCell = cell(of: dragging, settings: settings)

        // Geometry while dragging: origin row still occupied (matches on-screen layout).
        var occupiedRowsForGeometry = Set(items.map { cell(of: $0, settings: settings).row })
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
            assignments[item.id] = cell(of: item, settings: settings)
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

    static func rowHeight(row: Int, occupiedRows: Set<Int>, settings: AppState.Settings) -> CGFloat {
        occupiedRows.contains(row)
            ? fullRowHeight(settings: settings)
            : emptyRowHeight(settings: settings)
    }

    private static func resolveDuplicateAssignments(bounds: Cell, assignments: inout [UUID: Cell]) {
        var seen: [Cell: UUID] = [:]
        var duplicates: [(UUID, Cell)] = []
        for (id, cell) in assignments {
            if let existing = seen[cell], existing != id {
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
            wrapInsert(remaining, ontoRow: row + 1, bounds: bounds, assignments: &assignments)
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

    /// Uniform grid cell from a canvas point (legacy bootstrap only).
    static func cell(for point: CGPoint, settings: AppState.Settings) -> Cell {
        let size = cellSize(settings: settings)
        guard size.width > 0, size.height > 0 else { return Cell(column: 0, row: 0) }
        let column = Int(round((point.x - origin.x) / size.width))
        let row = Int(round((point.y - origin.y) / size.height))
        return Cell(column: max(0, column), row: max(0, row))
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
        return Cell(column: max(0, column), row: bestRow)
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
                    if let bounds, column > bounds.column || row > bounds.row { continue }
                    let candidate = Cell(column: column, row: row)
                    if !occupied.contains(candidate) {
                        return candidate
                    }
                }
            }
        }
        return Cell(column: start.column, row: start.row + occupied.count + 1)
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
