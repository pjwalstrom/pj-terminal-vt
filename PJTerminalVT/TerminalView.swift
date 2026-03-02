import AppKit
import SwiftUI

/// SwiftUI wrapper for the terminal NSView.
struct TerminalRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalView {
        TerminalView()
    }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}

/// NSView that renders the terminal buffer using CoreText and handles input.
final class TerminalView: NSView {
    private let buffer: TerminalBuffer
    private let parser: VTParser
    private let keyEncoder = KeyEncoder()
    private var pty: PTY?
    private var readSource: DispatchSourceRead?
    private var keyMonitor: Any?
    private var cursorBlinkTimer: Timer?
    private var cursorVisible = true

    // Font metrics
    private let font: NSFont
    private let cellWidth: CGFloat
    private let cellHeight: CGFloat
    private let baseline: CGFloat

    override init(frame: NSRect) {
        let f = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        self.font = f

        // Compute cell metrics from the font
        let attrStr = NSAttributedString(string: "M", attributes: [.font: f])
        let size = attrStr.size()
        self.cellWidth = ceil(size.width)
        self.cellHeight = ceil(f.ascender - f.descender + f.leading)
        self.baseline = ceil(-f.descender)

        self.buffer = TerminalBuffer(rows: 24, cols: 80)
        self.parser = VTParser(buffer: buffer)

        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        readSource?.cancel()
        cursorBlinkTimer?.invalidate()
    }

    // MARK: - Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startTerminal()
        installKeyMonitor()
        startCursorBlink()
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        cursorVisible = true
        needsDisplay = true
        return ok
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let newCols = max(1, Int(bounds.width / cellWidth))
        let newRows = max(1, Int(bounds.height / cellHeight))
        if newRows != buffer.rows || newCols != buffer.cols {
            buffer.resize(newRows: newRows, newCols: newCols)
            pty?.resize(rows: UInt16(newRows), cols: UInt16(newCols))
            needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    // MARK: - Terminal startup

    private func startTerminal() {
        guard pty == nil else { return }

        let cols = max(1, Int(bounds.width / cellWidth))
        let rows = max(1, Int(bounds.height / cellHeight))
        buffer.resize(newRows: rows, newCols: cols)

        do {
            pty = try PTY.spawn(rows: UInt16(rows), cols: UInt16(cols))
        } catch {
            NSLog("Failed to spawn PTY: \(error)")
            return
        }

        // Read from PTY asynchronously
        let fd = pty!.masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                self.parser.feed(Data(bytes: buf, count: n))
                self.needsDisplay = true
                self.updateWindowTitle()
            } else if n == 0 {
                // Shell exited
                self.readSource?.cancel()
            }
        }
        source.setCancelHandler { /* cleanup */ }
        source.resume()
        readSource = source

        // Focus
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func updateWindowTitle() {
        window?.title = buffer.title
    }

    // MARK: - Rendering

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)

        let viewHeight = bounds.height

        for row in 0..<buffer.rows {
            let y = viewHeight - CGFloat(row + 1) * cellHeight

            for col in 0..<buffer.cols {
                let cell = buffer.grid[row][col]
                let x = CGFloat(col) * cellWidth
                let cellRect = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)

                // Draw cell background if not default black
                let bgColor = cell.attrs.effectiveBG
                if bgColor != .black {
                    ctx.setFillColor(bgColor.cgColor)
                    ctx.fill(cellRect)
                }

                // Draw character
                let ch = cell.character
                if ch != " " && ch != "\0" {
                    let fgColor = cell.attrs.effectiveFG
                    var fontToUse = font
                    if cell.attrs.bold {
                        fontToUse = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .bold)
                    }

                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: fontToUse,
                        .foregroundColor: fgColor
                    ]
                    let str = NSAttributedString(string: String(ch), attributes: attrs)
                    let line = CTLineCreateWithAttributedString(str)
                    ctx.textPosition = CGPoint(x: x, y: y + baseline)
                    CTLineDraw(line, ctx)
                }

                // Draw underline
                if cell.attrs.underline {
                    ctx.setStrokeColor(cell.attrs.effectiveFG.cgColor)
                    ctx.setLineWidth(1)
                    ctx.move(to: CGPoint(x: x, y: y + 1))
                    ctx.addLine(to: CGPoint(x: x + cellWidth, y: y + 1))
                    ctx.strokePath()
                }

                // Draw strikethrough
                if cell.attrs.strikethrough {
                    ctx.setStrokeColor(cell.attrs.effectiveFG.cgColor)
                    ctx.setLineWidth(1)
                    let mid = y + cellHeight / 2
                    ctx.move(to: CGPoint(x: x, y: mid))
                    ctx.addLine(to: CGPoint(x: x + cellWidth, y: mid))
                    ctx.strokePath()
                }
            }
        }

        // Draw cursor
        if cursorVisible {
            let cx = CGFloat(buffer.cursorCol) * cellWidth
            let cy = viewHeight - CGFloat(buffer.cursorRow + 1) * cellHeight
            let cursorRect = CGRect(x: cx, y: cy, width: cellWidth, height: cellHeight)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.5).cgColor)
            ctx.fill(cursorRect)
        }
    }

    // MARK: - Cursor blink

    private func startCursorBlink() {
        cursorBlinkTimer?.invalidate()
        cursorBlinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.cursorVisible.toggle()
            self.needsDisplay = true
        }
    }

    // MARK: - Keyboard input

    override func keyDown(with event: NSEvent) {
        if let data = keyEncoder.encode(event) {
            pty?.write(data)
        }
    }

    override func keyUp(with event: NSEvent) {}

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if let data = self.keyEncoder.encode(event) {
                self.pty?.write(data)
            }
            return nil
        }
    }

    // MARK: - Mouse (basic scroll support)

    override func scrollWheel(with event: NSEvent) {
        let lines = Int(-event.scrollingDeltaY)
        if lines > 0 {
            pty?.write("\u{1B}[B".repeated(lines))
        } else if lines < 0 {
            pty?.write("\u{1B}[A".repeated(-lines))
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }
}

private extension String {
    func repeated(_ n: Int) -> String {
        String(repeating: self, count: max(0, n))
    }
}
