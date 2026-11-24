import Foundation

enum QBasicEditorAction: Equatable {
    case none
    case new, open, save, exit
    case run
    case about, keys
    case clear, selectAll
    case openFile(String), saveFile(String)
}

struct QBasicMenuItem {
    let title: String
    let shortcut: String
    let action: QBasicEditorAction
}

struct QBasicMenuDefinition {
    let title: String
    let items: [QBasicMenuItem]
}

struct QBasicEditorPrompt: Equatable {
    enum Kind: Equatable {
        case open, save
    }

    let kind: Kind
    var text = ""

    var label: String {
        kind == .open ? "Open file: " : "Save as: "
    }
}

struct QBasicEditorDialog: Equatable {
    let title: String
    let lines: [String]
}

enum QBasicEditorError: LocalizedError {
    case missingFileName
    case fileNotFound(String)
    case notAFile(String)
    case missingParent(String)

    var errorDescription: String? {
        switch self {
        case .missingFileName:
            return "No file name was supplied."
        case .fileNotFound(let path):
            return "Cannot find \(path)."
        case .notAFile(let path):
            return "\(path) is not a file."
        case .missingParent(let path):
            return "The folder for \(path) does not exist."
        }
    }
}

/// File-system adapters stay outside the editing operations so the model can be tested
/// with nothing but strings and keys. Names shown by the editor remain DOS names.
enum QBasicEditorFiles {
    static func read(_ path: String, shell: Shell) throws -> (source: String, name: String) {
        let resolved = try shell.drives.resolve(path)
        guard resolved.exists else { throw QBasicEditorError.fileNotFound(path) }
        let url = shell.drives.url(resolved)
        guard !isDir(url) else { throw QBasicEditorError.notAFile(path) }

        let data = try Data(contentsOf: url)
        let text = String(decoding: Shell.cutZ(data), as: UTF8.self)
        let source = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return (source, shell.dosShow(resolved))
    }

    @discardableResult
    static func write(_ source: String, path: String, shell: Shell) throws -> String {
        let resolved = try shell.drives.resolve(path)
        guard resolved.parentExists else { throw QBasicEditorError.missingParent(path) }
        let url = shell.drives.url(resolved)
        guard !isDir(url) else { throw QBasicEditorError.notAFile(path) }

        // BASIC files of the period were DOS text files. Other extensions retain LF so
        // the editor is still useful for the occasional plain text file.
        let separator = path.uppercased().hasSuffix(".BAS") ? "\r\n" : "\n"
        let diskText = source.replacingOccurrences(of: "\n", with: separator)
        try diskText.write(to: url, atomically: true, encoding: .utf8)
        return shell.dosShow(resolved)
    }
}

/// A character-cell editor model. Rows and columns are zero-based internally; only the
/// status line shows the one-based numbers that QBASIC users expect.
struct QBasicEditor {
    static let width = 80
    static let height = 25
    static let editTop = 2
    static let editBottom = 22
    static let editHeight = editBottom - editTop + 1
    static let tabWidth = 4

    static let sampleSource = """
    REM A first program in the command98 workbench
    CLS
    PRINT "Hello from your BASIC editor."
    PRINT "Change this text, then press F5."
    END
    """

    static let aboutDialog = QBasicEditorDialog(
        title: "About QBASIC",
        lines: [
            "command98 QBASIC",
            "A compact BASIC workbench for an 80 by 25 console.",
            "Edit a program here, or run it without saving a file.",
        ])

    static let keysDialog = QBasicEditorDialog(
        title: "Editor Keys",
        lines: [
            "F5              Run the current buffer",
            "Ctrl+S          Save the current buffer",
            "F10 or Alt+F    Use the menu bar",
            "Insert          Toggle insert and overwrite",
            "Ctrl+Home/End   First or last line",
            "PgUp/PgDn       Move one editor page",
            "Tab             Advance to a four-column stop",
            "Esc             Close a menu, dialogue, or prompt",
        ])

    static let menus: [QBasicMenuDefinition] = [
        QBasicMenuDefinition(title: "File", items: [
            QBasicMenuItem(title: "New", shortcut: "", action: .new),
            QBasicMenuItem(title: "Open", shortcut: "", action: .open),
            QBasicMenuItem(title: "Save", shortcut: "Ctrl+S", action: .save),
            QBasicMenuItem(title: "Exit", shortcut: "", action: .exit),
        ]),
        QBasicMenuDefinition(title: "Edit", items: [
            QBasicMenuItem(title: "Clear", shortcut: "", action: .clear),
            QBasicMenuItem(title: "Select All", shortcut: "", action: .selectAll),
        ]),
        QBasicMenuDefinition(title: "Run", items: [
            QBasicMenuItem(title: "Start", shortcut: "F5", action: .run),
        ]),
        QBasicMenuDefinition(title: "Help", items: [
            QBasicMenuItem(title: "About", shortcut: "", action: .about),
            QBasicMenuItem(title: "Keys", shortcut: "", action: .keys),
        ]),
    ]

    private static let menuColumns = [1, 8, 15, 21]

    private(set) var lines: [String]
    private(set) var cursorRow = 0
    private(set) var cursorColumn = 0
    private(set) var topRow = 0
    private(set) var leftColumn = 0
    private(set) var dirty: Bool

    var insertMode = true
    var fileName: String?
    var statusMessage: String?
    var prompt: QBasicEditorPrompt?
    var dialog: QBasicEditorDialog?

    private(set) var menuFocused = false
    private(set) var menuOpen = false
    private(set) var selectedMenu = 0
    private(set) var selectedItem = 0
    private(set) var selectsAll = false

    var source: String {
        lines.joined(separator: "\n")
    }

    var displayName: String {
        guard let fileName, !fileName.isEmpty else { return "UNTITLED.BAS" }
        let unified = fileName.replacingOccurrences(of: "/", with: "\\")
        return unified.split(separator: "\\").last.map(String.init) ?? fileName
    }

    init(source: String = QBasicEditor.sampleSource, fileName: String? = nil, dirty: Bool = true) {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let split = normalized.components(separatedBy: "\n")
        self.lines = split.isEmpty ? [""] : split
        self.fileName = fileName
        self.dirty = dirty
    }

    mutating func reset(source: String = QBasicEditor.sampleSource,
                        fileName: String? = nil,
                        dirty: Bool = true) {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let split = normalized.components(separatedBy: "\n")
        lines = split.isEmpty ? [""] : split
        cursorRow = 0
        cursorColumn = 0
        topRow = 0
        leftColumn = 0
        self.fileName = fileName
        self.dirty = dirty
        insertMode = true
        statusMessage = nil
        prompt = nil
        dialog = nil
        closeMenu()
        selectsAll = false
    }

    mutating func load(_ path: String, shell: Shell) throws {
        let file = try QBasicEditorFiles.read(path, shell: shell)
        reset(source: file.source, fileName: file.name, dirty: false)
        statusMessage = "Opened \(displayName)"
    }

    mutating func save(_ path: String? = nil, shell: Shell) throws {
        guard let requested = path ?? fileName, !requested.isEmpty else {
            throw QBasicEditorError.missingFileName
        }
        fileName = try QBasicEditorFiles.write(source, path: requested, shell: shell)
        dirty = false
        statusMessage = "Saved \(displayName)"
    }

    mutating func beginPrompt(_ kind: QBasicEditorPrompt.Kind) {
        closeMenu()
        statusMessage = nil
        prompt = QBasicEditorPrompt(kind: kind)
    }

    mutating func focusMenu(_ index: Int = 0) {
        selectedMenu = min(max(0, index), Self.menus.count - 1)
        selectedItem = 0
        menuFocused = true
        menuOpen = false
        prompt = nil
        dialog = nil
    }

    mutating func closeMenu() {
        menuFocused = false
        menuOpen = false
        selectedItem = 0
    }

    static func menuIndex(forAccessLetter letter: Character) -> Int? {
        let upper = Character(letter.uppercased())
        return menus.firstIndex { $0.title.first == upper }
    }

    mutating func clear() {
        lines = [""]
        cursorRow = 0
        cursorColumn = 0
        topRow = 0
        leftColumn = 0
        selectsAll = false
        dirty = true
    }

    mutating func selectAll() {
        selectsAll = true
        closeMenu()
    }

    mutating func moveToDocumentStart() {
        cursorRow = 0
        cursorColumn = 0
        selectsAll = false
        ensureCursorVisible()
    }

    mutating func moveToDocumentEnd() {
        cursorRow = lines.count - 1
        cursorColumn = lines[cursorRow].count
        selectsAll = false
        ensureCursorVisible()
    }

    @discardableResult
    mutating func handle(_ key: Key, control: Bool = false) -> QBasicEditorAction {
        if dialog != nil {
            dialog = nil
            return .none
        }

        if prompt != nil {
            return handlePrompt(key)
        }

        if key == .f(10) {
            if menuFocused { closeMenu() } else { focusMenu(selectedMenu) }
            return .none
        }
        if key == .f(5) { closeMenu(); return .run }
        if case .ctrl(let letter) = key, Character(letter.uppercased()) == "S" {
            closeMenu()
            return .save
        }

        if menuFocused {
            return handleMenu(key)
        }

        statusMessage = nil
        switch key {
        case .char(let ch):
            insert(ch)
        case .enter:
            if selectsAll { clear() }
            splitLine()
        case .backspace:
            if selectsAll { clear() } else { backspace() }
        case .delete:
            if selectsAll { clear() } else { delete() }
        case .tab:
            if selectsAll { clear() }
            insertTab()
        case .left:
            moveLeft()
        case .right:
            moveRight()
        case .up:
            moveVertical(-1)
        case .down:
            moveVertical(1)
        case .home:
            if control { moveToDocumentStart() } else { moveLineStart() }
        case .end:
            if control { moveToDocumentEnd() } else { moveLineEnd() }
        case .pageUp:
            moveVertical(-Self.editHeight)
        case .pageDown:
            moveVertical(Self.editHeight)
        case .insert:
            insertMode.toggle()
        case .ctrl(let letter):
            switch Character(letter.uppercased()) {
            case "H": moveToDocumentStart()
            case "E": moveToDocumentEnd()
            default: break
            }
        case .escape:
            selectsAll = false
        case .interrupt, .eof:
            return .exit
        default:
            break
        }
        return .none
    }

    private mutating func handlePrompt(_ key: Key) -> QBasicEditorAction {
        guard var current = prompt else { return .none }
        switch key {
        case .escape:
            prompt = nil
        case .enter:
            prompt = nil
            switch current.kind {
            case .open: return .openFile(current.text)
            case .save: return .saveFile(current.text)
            }
        case .backspace:
            if !current.text.isEmpty { current.text.removeLast() }
            prompt = current
        case .delete:
            break
        case .char(let ch) where !ch.isNewline && ch != "\u{7F}" && current.text.count < 240:
            current.text.append(ch)
            prompt = current
        case .ctrl(let letter) where Character(letter.uppercased()) == "U":
            current.text = ""
            prompt = current
        case .interrupt, .eof:
            prompt = nil
            return .exit
        default:
            break
        }
        return .none
    }

    private mutating func handleMenu(_ key: Key) -> QBasicEditorAction {
        switch key {
        case .escape:
            closeMenu()
        case .left:
            selectedMenu = (selectedMenu + Self.menus.count - 1) % Self.menus.count
            selectedItem = 0
        case .right:
            selectedMenu = (selectedMenu + 1) % Self.menus.count
            selectedItem = 0
        case .up:
            if menuOpen {
                let count = Self.menus[selectedMenu].items.count
                selectedItem = (selectedItem + count - 1) % count
            } else {
                menuOpen = true
                selectedItem = Self.menus[selectedMenu].items.count - 1
            }
        case .down:
            if menuOpen {
                let count = Self.menus[selectedMenu].items.count
                selectedItem = (selectedItem + 1) % count
            } else {
                menuOpen = true
                selectedItem = 0
            }
        case .enter:
            if !menuOpen {
                menuOpen = true
                selectedItem = 0
            } else {
                return activateMenuItem()
            }
        case .char(let letter):
            if menuOpen {
                let upper = Character(letter.uppercased())
                if let index = Self.menus[selectedMenu].items.firstIndex(where: {
                    $0.title.first == upper
                }) {
                    selectedItem = index
                    return activateMenuItem()
                }
            } else if let index = Self.menuIndex(forAccessLetter: letter) {
                selectedMenu = index
                selectedItem = 0
            }
        default:
            break
        }
        return .none
    }

    private mutating func activateMenuItem() -> QBasicEditorAction {
        let action = Self.menus[selectedMenu].items[selectedItem].action
        closeMenu()
        return action
    }

    private func index(_ row: Int, _ column: Int) -> String.Index {
        lines[row].index(lines[row].startIndex, offsetBy: column)
    }

    private mutating func prepareForTextChange() {
        if selectsAll { clear() }
        selectsAll = false
    }

    mutating func insert(_ ch: Character) {
        guard !ch.isNewline, ch != "\r", ch != "\u{7F}" else { return }
        prepareForTextChange()
        let i = index(cursorRow, cursorColumn)
        if insertMode || cursorColumn == lines[cursorRow].count {
            lines[cursorRow].insert(ch, at: i)
        } else {
            lines[cursorRow].replaceSubrange(i...i, with: [ch])
        }
        cursorColumn += 1
        dirty = true
        ensureCursorVisible()
    }

    mutating func insertTab() {
        prepareForTextChange()
        let spaces = Self.tabWidth - cursorColumn % Self.tabWidth
        for _ in 0..<spaces { insert(" ") }
    }

    private mutating func splitLine() {
        prepareForTextChange()
        let i = index(cursorRow, cursorColumn)
        let tail = String(lines[cursorRow][i...])
        lines[cursorRow] = String(lines[cursorRow][..<i])
        lines.insert(tail, at: cursorRow + 1)
        cursorRow += 1
        cursorColumn = 0
        dirty = true
        ensureCursorVisible()
    }

    private mutating func backspace() {
        prepareForTextChange()
        if cursorColumn > 0 {
            let i = index(cursorRow, cursorColumn - 1)
            lines[cursorRow].remove(at: i)
            cursorColumn -= 1
        } else if cursorRow > 0 {
            let oldColumn = lines[cursorRow - 1].count
            lines[cursorRow - 1] += lines[cursorRow]
            lines.remove(at: cursorRow)
            cursorRow -= 1
            cursorColumn = oldColumn
        } else {
            return
        }
        dirty = true
        ensureCursorVisible()
    }

    private mutating func delete() {
        prepareForTextChange()
        if cursorColumn < lines[cursorRow].count {
            lines[cursorRow].remove(at: index(cursorRow, cursorColumn))
        } else if cursorRow + 1 < lines.count {
            lines[cursorRow] += lines[cursorRow + 1]
            lines.remove(at: cursorRow + 1)
        } else {
            return
        }
        dirty = true
        ensureCursorVisible()
    }

    private mutating func moveLeft() {
        selectsAll = false
        if cursorColumn > 0 {
            cursorColumn -= 1
        } else if cursorRow > 0 {
            cursorRow -= 1
            cursorColumn = lines[cursorRow].count
        }
        ensureCursorVisible()
    }

    private mutating func moveRight() {
        selectsAll = false
        if cursorColumn < lines[cursorRow].count {
            cursorColumn += 1
        } else if cursorRow + 1 < lines.count {
            cursorRow += 1
            cursorColumn = 0
        }
        ensureCursorVisible()
    }

    private mutating func moveVertical(_ amount: Int) {
        selectsAll = false
        cursorRow = min(max(0, cursorRow + amount), lines.count - 1)
        cursorColumn = min(cursorColumn, lines[cursorRow].count)
        ensureCursorVisible()
    }

    private mutating func moveLineStart() {
        selectsAll = false
        cursorColumn = 0
        ensureCursorVisible()
    }

    private mutating func moveLineEnd() {
        selectsAll = false
        cursorColumn = lines[cursorRow].count
        ensureCursorVisible()
    }

    private mutating func ensureCursorVisible() {
        if cursorRow < topRow { topRow = cursorRow }
        if cursorRow >= topRow + Self.editHeight {
            topRow = cursorRow - Self.editHeight + 1
        }
        topRow = min(max(0, topRow), max(0, lines.count - Self.editHeight))

        if cursorColumn < leftColumn { leftColumn = cursorColumn }
        if cursorColumn >= leftColumn + Self.width {
            leftColumn = cursorColumn - Self.width + 1
        }
        leftColumn = max(0, leftColumn)
    }

    func render() -> Screen {
        let screen = Screen(width: Self.width, height: Self.height)
        render(to: screen)
        return screen
    }

    func render(to screen: Screen, showCursor: Bool = true) {
        screen.fill(x: 0, y: 0, width: screen.width, height: screen.height, fg: 7, bg: 1)
        drawMenuBar(screen)
        screen.center(1, displayName, fg: 15, bg: 1)
        drawText(screen)

        if let statusMessage {
            screen.write(0, 23, String(statusMessage.prefix(Self.width)), fg: 15, bg: 1)
        } else {
            screen.fill(x: 0, y: 23, width: Self.width, height: 1, ch: "\u{2500}", fg: 7, bg: 1)
        }
        drawStatus(screen)

        if showCursor && !menuFocused && prompt == nil && dialog == nil {
            let x = cursorColumn - leftColumn
            let y = Self.editTop + cursorRow - topRow
            screen.put(x, y, "_", fg: 15, bg: 1)
        }

        if menuOpen { drawOpenMenu(screen) }
        if let dialog { drawDialog(screen, dialog) }
        if prompt != nil { drawPrompt(screen) }
    }

    private func drawMenuBar(_ screen: Screen) {
        for (i, menu) in Self.menus.enumerated() {
            let x = Self.menuColumns[i]
            let highlighted = menuFocused && selectedMenu == i
            screen.write(x, 0, " \(menu.title) ", fg: highlighted ? 15 : 7, bg: 1)
            screen.put(x + 1, 0, menu.title.first!, fg: 15, bg: 1)
        }
    }

    private func drawText(_ screen: Screen) {
        for visibleRow in 0..<Self.editHeight {
            let row = topRow + visibleRow
            guard row < lines.count else { continue }
            let line = lines[row]
            let start = min(leftColumn, line.count)
            let text = line.dropFirst(start).prefix(Self.width)
            screen.write(0, Self.editTop + visibleRow, String(text), fg: selectsAll ? 15 : 7, bg: 1)
        }
    }

    private func drawStatus(_ screen: Screen) {
        let right = "F5=Run  F10=Menu "
        let rightX = Self.width - right.count
        let left = " Ln \(cursorRow + 1), Col \(cursorColumn + 1)  \(insertMode ? "INS" : "OVR")  \(displayName)"
        screen.write(0, 24, String(left.prefix(max(0, rightX - 1))), fg: 7, bg: 1)
        screen.write(rightX, 24, right, fg: 15, bg: 1)
    }

    private func drawOpenMenu(_ screen: Screen) {
        let menu = Self.menus[selectedMenu]
        let widest = menu.items.map { $0.title.count + $0.shortcut.count + 7 }.max() ?? 18
        let menuWidth = max(18, widest)
        let x = min(Self.menuColumns[selectedMenu], Self.width - menuWidth)
        screen.box(x: x, y: 1, width: menuWidth, height: menu.items.count + 2,
                   fg: 7, bg: 1, double: false)

        for (i, item) in menu.items.enumerated() {
            let y = 2 + i
            let selected = i == selectedItem
            if selected { screen.put(x + 1, y, ">", fg: 15, bg: 1) }
            screen.write(x + 2, y, item.title, fg: selected ? 15 : 7, bg: 1)
            if let first = item.title.first {
                screen.put(x + 2, y, first, fg: 15, bg: 1)
            }
            if !item.shortcut.isEmpty {
                screen.write(x + menuWidth - item.shortcut.count - 2, y, item.shortcut, fg: 15, bg: 1)
            }
        }
    }

    private func drawDialog(_ screen: Screen, _ dialog: QBasicEditorDialog) {
        let contentWidth = max(dialog.title.count + 2,
                               dialog.lines.map(\.count).max() ?? 0)
        let dialogWidth = min(Self.width - 4, max(34, contentWidth + 6))
        let dialogHeight = min(21, dialog.lines.count + 4)
        let x = (Self.width - dialogWidth) / 2
        let y = max(2, (Self.height - dialogHeight) / 2)
        screen.box(x: x, y: y, width: dialogWidth, height: dialogHeight, fg: 15, bg: 1)
        let title = " \(dialog.title) "
        screen.write(x + max(1, (dialogWidth - title.count) / 2), y, title, fg: 15, bg: 1)
        for (i, line) in dialog.lines.prefix(dialogHeight - 4).enumerated() {
            screen.write(x + 3, y + 2 + i, String(line.prefix(dialogWidth - 6)), fg: 7, bg: 1)
        }
        let footer = "Press any key"
        screen.write(x + (dialogWidth - footer.count) / 2, y + dialogHeight - 2,
                     footer, fg: 15, bg: 1)
    }

    private func drawPrompt(_ screen: Screen) {
        guard let prompt else { return }
        screen.fill(x: 0, y: 24, width: Self.width, height: 1, fg: 7, bg: 1)
        let full = prompt.label + prompt.text
        let left = max(0, full.count - Self.width + 1)
        let visible = full.dropFirst(left).prefix(Self.width)
        screen.write(0, 24, String(visible), fg: 15, bg: 1)
        screen.put(full.count - left, 24, "_", fg: 15, bg: 1)
    }
}
