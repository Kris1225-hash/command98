import Foundation

/// One console event. The shared Key decoder has no Alt modifier, so the IDE keeps that
/// small piece of terminal knowledge here instead of widening the shared key API.
enum QBasicIDEEvent: Equatable {
    case key(Key, control: Bool)
    case alt(Character)

    init(_ key: Key) {
        self = .key(key, control: false)
    }
}

enum QBasicIDEKeyReader {
    /// Where the reader gets bytes. Production polls the console; tests seed an array,
    /// so the reader's continuation logic is exercised without a real terminal.
    struct ByteSource {
        /// The next byte, blocking like a terminal. -1 is EOF and -2 is ^C.
        var read: () -> Int
        /// True when another byte arrives within `ms`.
        var ready: (Int32) -> Bool

        static func console() -> ByteSource {
            ByteSource(read: { Console.readByte() }, ready: { Console.pending($0) })
        }

        /// An in-memory source whose bytes are all available immediately.
        static func seeded(_ bytes: [Int]) -> ByteSource {
            var remaining = bytes
            return ByteSource(
                read: { remaining.isEmpty ? -1 : remaining.removeFirst() },
                ready: { _ in !remaining.isEmpty })
        }
    }

    static func read(from source: ByteSource = .console()) -> QBasicIDEEvent {
        let byte = source.read()
        if byte == -2 { return .key(.interrupt, control: false) }
        guard byte == 27 else {
            return QBasicIDEEvent(KeyReader.decode(byte) ?? .unknown)
        }
        guard source.ready(30) else { return QBasicIDEEvent(.escape) }

        let first = source.read()
        if first == -2 { return .key(.interrupt, control: false) }
        guard first >= 0 else { return QBasicIDEEvent(.escape) }
        if first == 91 { // '[': CSI parameters finish at a byte in @...~.
            var sequence = "["
            var complete = false
            while sequence.count < 18 {
                // A truncated sequence must not leave the program blocked in the
                // alternate screen, and ^C must win over a half-read CSI.
                guard source.ready(30) else { break }
                let next = source.read()
                if next == -2 { return .key(.interrupt, control: false) }
                guard next >= 0 else { break }
                sequence.append(Character(UnicodeScalar(UInt8(next))))
                if next >= 0x40 && next <= 0x7E {
                    complete = true
                    break
                }
            }
            return complete ? decodeEscape(sequence) : QBasicIDEEvent(.escape)
        }
        if first == 79 { // 'O': the short SS3 function-key and Home/End forms.
            var sequence = "O"
            guard source.ready(30) else { return QBasicIDEEvent(.escape) }
            let next = source.read()
            if next == -2 { return .key(.interrupt, control: false) }
            guard next >= 0 else { return QBasicIDEEvent(.escape) }
            sequence.append(Character(UnicodeScalar(UInt8(next))))
            return decodeEscape(sequence)
        }
        if first < 128 {
            let ch = Character(UnicodeScalar(UInt8(first)))
            if ch.isLetter { return .alt(Character(ch.uppercased())) }
        }
        return QBasicIDEEvent(.unknown)
    }

    private static func decodeEscape(_ sequence: String) -> QBasicIDEEvent {
        switch sequence {
        case "[1;5H", "[5H":
            return .key(.home, control: true)
        case "[1;5F", "[5F":
            return .key(.end, control: true)
        default:
            return QBasicIDEEvent(KeyReader.decodeEscape(sequence))
        }
    }
}

/// The interpreter's output page. It owns a real Screen rather than writing terminal
/// escapes itself, which keeps PRINT, CLS, LOCATE and COLOR testable and consistent.
final class QBasicScreenIO: QBasicIO {
    let screen = Screen(width: 80, height: 25, fg: 7, bg: 0)
    private let out: Out
    private var previous: Screen?
    private(set) var cursorRow = 0
    private(set) var cursorColumn = 0
    private(set) var foreground: UInt8 = 7
    private(set) var background: UInt8 = 0
    private var wrapPending = false

    init(out: Out) {
        self.out = out
        paint()
    }

    func write(_ string: String) {
        for ch in string {
            switch ch {
            case "\n":
                wrapPending = false
                newLine()
            case "\r":
                cursorColumn = 0
                wrapPending = false
            case "\t":
                let spaces = 8 - cursorColumn % 8
                for _ in 0..<spaces { writeCharacter(" ") }
            default:
                writeCharacter(ch)
            }
        }
        paint()
    }

    func cls() {
        screen.clear(fg: foreground, bg: background)
        cursorRow = 0
        cursorColumn = 0
        wrapPending = false
        paint()
    }

    func locate(_ row: Int, _ col: Int) {
        cursorRow = min(max(1, row), 25) - 1
        cursorColumn = min(max(1, col), 80) - 1
        wrapPending = false
    }

    func color(_ fg: Int, _ bg: Int) {
        foreground = UInt8(min(max(0, fg), 15))
        background = UInt8(min(max(0, bg), 15))
    }

    func input(_ prompt: String) -> String? {
        var text = ""
        var column = 0
        cursorRow = 24
        cursorColumn = 0
        wrapPending = false

        while true {
            drawInput(prompt: prompt, text: text, column: column)
            let event = QBasicIDEKeyReader.read()
            switch event {
            case .alt:
                break
            case .key(let key, _):
                switch key {
                case .enter:
                    newLine()
                    paint()
                    return text
                case .escape:
                    return nil
                case .interrupt:
                    gInterrupted = 0
                    return nil
                case .eof:
                    return nil
                case .char(let ch):
                    guard text.count < 255, !ch.isNewline, ch != "\u{7F}" else { continue }
                    let i = text.index(text.startIndex, offsetBy: column)
                    text.insert(ch, at: i)
                    column += 1
                case .backspace:
                    if column > 0 {
                        let i = text.index(text.startIndex, offsetBy: column - 1)
                        text.remove(at: i)
                        column -= 1
                    }
                case .delete:
                    if column < text.count {
                        text.remove(at: text.index(text.startIndex, offsetBy: column))
                    }
                case .left:
                    column = max(0, column - 1)
                case .right:
                    column = min(text.count, column + 1)
                case .home:
                    column = 0
                case .end:
                    column = text.count
                default:
                    break
                }
            }
        }
    }

    func sleep(_ ms: Int) {
        paint()
        guard ms > 0 else { return }
        Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
    }

    func key() -> Key? {
        guard KeyReader.hasBufferedKey(fd: 0) else { return nil }
        return KeyReader.read()
    }

    func showContinue() {
        screen.fill(x: 0, y: 24, width: 80, height: 1, fg: 15, bg: 0)
        screen.center(24, "Press any key to continue", fg: 15, bg: 0)
        paint()
    }

    private func writeCharacter(_ ch: Character) {
        if wrapPending {
            newLine()
            wrapPending = false
        }
        screen.put(cursorColumn, cursorRow, ch, fg: foreground, bg: background)
        if cursorColumn == 79 {
            wrapPending = true
        } else {
            cursorColumn += 1
        }
    }

    private func newLine() {
        cursorColumn = 0
        wrapPending = false
        if cursorRow < 24 {
            cursorRow += 1
        } else {
            for y in 0..<24 {
                for x in 0..<80 {
                    screen[x, y] = screen[x, y + 1]
                }
            }
            screen.fill(x: 0, y: 24, width: 80, height: 1, fg: foreground, bg: background)
        }
    }

    private func drawInput(prompt: String, text: String, column: Int) {
        screen.fill(x: 0, y: 24, width: 80, height: 1, fg: foreground, bg: background)
        let full = prompt + text
        let absoluteCursor = prompt.count + column
        let left = max(0, absoluteCursor - 79)
        let visible = full.dropFirst(min(left, full.count)).prefix(80)
        screen.write(0, 24, String(visible), fg: foreground, bg: background)
        screen.put(absoluteCursor - left, 24, "_", fg: foreground, bg: background)
        paint()
    }

    private func paint() {
        if let previous {
            screen.renderDiff(to: out, previous: previous)
        } else {
            screen.render(to: out)
        }
        previous = screen.copy()
    }
}

/// The blue full-screen QBASIC workbench. The interpreter is deliberately behind QBasicIO:
/// running a buffer never saves it and never changes the shell's file system state.
enum QBasicIDE {
    static func run(_ shell: Shell, _ io: IO, file: String?) -> Int32 {
        guard io.inFD == 0, Console.isFullScreen(io.out) else {
            io.out.line("QBASIC needs a console.")
            return 1
        }

        var editor = QBasicEditor()
        if let file { openInitial(&editor, file: file, shell: shell) }

        gInterrupted = 0
        Screen.begin(io.out)
        defer { Screen.end(io.out) }

        return Console.withRaw {
            var previous: Screen? = nil

            func paint(force: Bool = false) {
                let next = editor.render()
                if !force, let previous {
                    next.renderDiff(to: io.out, previous: previous)
                } else {
                    next.render(to: io.out)
                }
                previous = next
            }

            paint(force: true)
            while true {
                let event = QBasicIDEKeyReader.read()
                if case .alt(let letter) = event {
                    if let index = QBasicEditor.menuIndex(forAccessLetter: letter) {
                        editor.focusMenu(index)
                    }
                    paint()
                    continue
                }
                guard case .key(let key, let control) = event else { continue }
                if key == .interrupt {
                    gInterrupted = 0
                    return 0
                }
                if key == .eof { return 0 }

                let action = editor.handle(key, control: control)
                switch action {
                case .none:
                    break
                case .exit:
                    return 0
                case .new:
                    editor.reset()
                case .open:
                    editor.beginPrompt(.open)
                case .save:
                    if editor.fileName == nil {
                        editor.beginPrompt(.save)
                    } else {
                        save(&editor, path: nil, shell: shell)
                    }
                case .openFile(let path):
                    open(&editor, path: path, shell: shell)
                case .saveFile(let path):
                    save(&editor, path: path, shell: shell)
                case .run:
                    runProgram(editor.source, out: io.out)
                    previous = nil
                case .about:
                    editor.dialog = QBasicEditor.aboutDialog
                case .keys:
                    editor.dialog = QBasicEditor.keysDialog
                case .clear:
                    editor.clear()
                case .selectAll:
                    editor.selectAll()
                }
                paint()
            }
        }
    }

    /// The buffer the IDE starts with. A file that exists but cannot be read must not keep
    /// its name on the buffer: Ctrl+S would then overwrite the file that just failed. The
    /// failed load leaves an empty, untitled buffer, so saving needs an explicit Save As.
    static func openInitial(_ editor: inout QBasicEditor, file: String, shell: Shell) {
        do {
            let resolved = try shell.drives.resolve(file)
            if resolved.exists {
                try editor.load(file, shell: shell)
            } else {
                editor.reset(fileName: shell.dosShow(resolved))
            }
        } catch {
            editor.reset(source: "", fileName: nil, dirty: false)
            editor.statusMessage = errorText("Cannot open \(file)", error)
        }
    }

    private static func open(_ editor: inout QBasicEditor, path: String, shell: Shell) {
        let name = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        do {
            try editor.load(name, shell: shell)
        } catch {
            editor.statusMessage = errorText("Cannot open \(name)", error)
        }
    }

    private static func save(_ editor: inout QBasicEditor, path: String?, shell: Shell) {
        if let path {
            let name = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            do {
                try editor.save(name, shell: shell)
            } catch {
                editor.statusMessage = errorText("Cannot save \(name)", error)
            }
        } else {
            do {
                try editor.save(shell: shell)
            } catch {
                editor.statusMessage = errorText("Cannot save file", error)
            }
        }
    }

    private static func errorText(_ prefix: String, _ error: Error) -> String {
        let detail = error.localizedDescription
        return detail.isEmpty ? prefix : "\(prefix): \(detail)"
    }

    private static func runProgram(_ source: String, out: Out) {
        let programScreen = QBasicScreenIO(out: out)
        _ = QBasic.run(source: source, io: programScreen)
        if gInterrupted != 0 { gInterrupted = 0 }
        programScreen.showContinue()
        let event = QBasicIDEKeyReader.read()
        if case .key(.interrupt, _) = event { gInterrupted = 0 }
    }
}
