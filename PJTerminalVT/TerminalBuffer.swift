import AppKit

/// A single cell in the terminal grid.
struct Cell {
    var character: Character = " "
    var attrs: CellAttributes = CellAttributes()
}

/// SGR-derived text attributes for a cell.
struct CellAttributes: Equatable {
    var fg: NSColor = .white
    var bg: NSColor = .black
    var bold: Bool = false
    var italic: Bool = false
    var underline: Bool = false
    var inverse: Bool = false
    var dim: Bool = false
    var strikethrough: Bool = false

    /// Return effective fg/bg considering inverse.
    var effectiveFG: NSColor { inverse ? bg : fg }
    var effectiveBG: NSColor { inverse ? fg : bg }
}

/// A grid buffer for terminal cells with cursor tracking and scrollback.
final class TerminalBuffer {
    private(set) var rows: Int
    private(set) var cols: Int
    private(set) var cursorRow: Int = 0
    private(set) var cursorCol: Int = 0
    var currentAttrs = CellAttributes()

    /// The visible grid (rows × cols).
    private(set) var grid: [[Cell]]

    /// Scrollback buffer — lines that scrolled off the top.
    private(set) var scrollback: [[Cell]] = []
    let maxScrollback = 1000

    /// Scroll region (top/bottom, inclusive, 0-based).
    var scrollTop: Int = 0
    var scrollBottom: Int

    /// Title set by OSC sequences.
    var title: String = "PJTerminalVT"

    init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
        self.scrollBottom = rows - 1
        self.grid = Self.makeGrid(rows: rows, cols: cols)
    }

    private static func makeGrid(rows: Int, cols: Int) -> [[Cell]] {
        Array(repeating: Array(repeating: Cell(), count: cols), count: rows)
    }

    // MARK: - Resize

    func resize(newRows: Int, newCols: Int) {
        var newGrid = Self.makeGrid(rows: newRows, cols: newCols)
        for r in 0..<min(rows, newRows) {
            for c in 0..<min(cols, newCols) {
                newGrid[r][c] = grid[r][c]
            }
        }
        grid = newGrid
        rows = newRows
        cols = newCols
        scrollTop = 0
        scrollBottom = newRows - 1
        cursorRow = min(cursorRow, newRows - 1)
        cursorCol = min(cursorCol, newCols - 1)
    }

    // MARK: - Character output

    func putChar(_ ch: Character) {
        if cursorCol >= cols {
            carriageReturn()
            lineFeed()
        }
        grid[cursorRow][cursorCol].character = ch
        grid[cursorRow][cursorCol].attrs = currentAttrs
        cursorCol += 1
    }

    // MARK: - Cursor movement

    func moveCursor(row: Int, col: Int) {
        cursorRow = clampRow(row)
        cursorCol = clampCol(col)
    }

    func moveCursorUp(_ n: Int) { cursorRow = clampRow(cursorRow - n) }
    func moveCursorDown(_ n: Int) { cursorRow = clampRow(cursorRow + n) }
    func moveCursorForward(_ n: Int) { cursorCol = clampCol(cursorCol + n) }
    func moveCursorBackward(_ n: Int) { cursorCol = clampCol(cursorCol - n) }

    func carriageReturn() { cursorCol = 0 }

    func lineFeed() {
        if cursorRow == scrollBottom {
            scrollUp()
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    func reverseLineFeed() {
        if cursorRow == scrollTop {
            scrollDown()
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    // MARK: - Scrolling

    func scrollUp() {
        let line = grid[scrollTop]
        if scrollback.count >= maxScrollback { scrollback.removeFirst() }
        scrollback.append(line)
        grid.remove(at: scrollTop)
        grid.insert(Array(repeating: Cell(), count: cols), at: scrollBottom)
    }

    func scrollDown() {
        grid.remove(at: scrollBottom)
        grid.insert(Array(repeating: Cell(), count: cols), at: scrollTop)
    }

    // MARK: - Erase

    func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0: // cursor to end
            eraseLine(0)
            for r in (cursorRow + 1)..<rows { clearRow(r) }
        case 1: // start to cursor
            for r in 0..<cursorRow { clearRow(r) }
            eraseLine(1)
        case 2, 3: // entire screen
            for r in 0..<rows { clearRow(r) }
            cursorRow = 0
            cursorCol = 0
        default: break
        }
    }

    func eraseLine(_ mode: Int) {
        switch mode {
        case 0: // cursor to end
            for c in cursorCol..<cols { grid[cursorRow][c] = Cell() }
        case 1: // start to cursor
            for c in 0...min(cursorCol, cols - 1) { grid[cursorRow][c] = Cell() }
        case 2: // entire line
            clearRow(cursorRow)
        default: break
        }
    }

    func insertLines(_ n: Int) {
        for _ in 0..<n {
            if cursorRow <= scrollBottom {
                grid.remove(at: scrollBottom)
                grid.insert(Array(repeating: Cell(), count: cols), at: cursorRow)
            }
        }
    }

    func deleteLines(_ n: Int) {
        for _ in 0..<n {
            if cursorRow <= scrollBottom {
                grid.remove(at: cursorRow)
                grid.insert(Array(repeating: Cell(), count: cols), at: scrollBottom)
            }
        }
    }

    func deleteChars(_ n: Int) {
        for _ in 0..<n {
            if cursorCol < cols {
                grid[cursorRow].remove(at: cursorCol)
                grid[cursorRow].append(Cell())
            }
        }
    }

    func eraseChars(_ n: Int) {
        for i in 0..<n {
            let c = cursorCol + i
            if c < cols { grid[cursorRow][c] = Cell() }
        }
    }

    // MARK: - Tab

    func tab() {
        let next = ((cursorCol / 8) + 1) * 8
        cursorCol = min(next, cols - 1)
    }

    // MARK: - Helpers

    private func clearRow(_ r: Int) {
        guard r >= 0 && r < rows else { return }
        grid[r] = Array(repeating: Cell(), count: cols)
    }

    private func clampRow(_ r: Int) -> Int { max(0, min(r, rows - 1)) }
    private func clampCol(_ c: Int) -> Int { max(0, min(c, cols - 1)) }
}
