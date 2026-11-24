import Foundation

/// A compact, text-mode BASIC with the language used by small DOS-era programs. The blue
/// editor is deliberately separate: both it and `QBASIC /RUN` use the same interpreter.
enum QBasic {
    static let utilities: [String: CommandHandler] = ["QBASIC": Shell.uQBasic]
    static let stubFiles: [(String, String, Int)] = [
        ("WINDOWS\\COMMAND", "QBASIC.EXE", 194309),
    ]
    static let help: [String: String] = [
        "QBASIC": """
        Edits and runs BASIC programs.

        QBASIC [/RUN] [drive:][path]filename

          /RUN   Run the program in the text screen instead of opening the editor.

        With no filename, QBASIC opens an empty editing window. A program can use
        numbered or unnumbered lines. Press Ctrl+C to leave a running program.
        """,
    ]
    static let stubVersion = "1"

    /// Three small programs written for Command98. They are also used by the editor's
    /// Samples menu, so none of them needs files or any other external resource.
    static let samples: [(name: String, source: String)] = [
        ("HELLO", """
        10 REM A first trip around the Command98 screen
        20 CLS
        30 PRINT "Hello from your own BASIC!"
        40 FOR I = 1 TO 3
        50 PRINT "Line"; I; "is ready."
        60 NEXT I
        70 END
        """),
        ("GUESS", """
        10 REM Guess the secret number; every attempt gets a hint
        20 RANDOMIZE 98
        30 TARGET = INT(RND * 10) + 1
        40 TRIES = 0
        50 PRINT "Choose a whole number from 1 to 10."
        60 INPUT "Your guess"; GUESS
        70 TRIES = TRIES + 1
        80 IF GUESS = TARGET THEN GOTO 120
        90 IF GUESS < TARGET THEN PRINT "Aim higher." ELSE PRINT "Aim lower."
        100 GOTO 60
        110 REM The answer is celebrated here
        120 PRINT "That is it! Attempts:"; TRIES
        130 END
        """),
        ("PYRAMID", """
        10 REM Draw a little monument out of asterisks
        20 HEIGHT = 5
        30 FOR ROW = 1 TO HEIGHT
        40 PRINT SPACE$(HEIGHT - ROW); STRING$(ROW * 2 - 1, "*")
        50 NEXT ROW
        60 PRINT "The pyramid is complete."
        70 END
        """),
    ]

    /// Runs a program entirely through its IO object. No terminal or editor is required.
    static func run(source: String, io: QBasicIO) -> Int32 {
        do {
            let program = try QBasicSourceParser.parse(source)
            try QBasicInterpreter(program: program, io: io).execute()
            return 0
        } catch let interrupt as QBasicInterrupt {
            io.write("Break in line \(interrupt.line)\n")
            return 2
        } catch let problem as QBasicProblem {
            io.write(problem.display + "\n")
            return 1
        } catch {
            io.write("Program error\n")
            return 1
        }
    }
}

/// The plain /RUN console. Full-screen programs get a different implementation from the IDE.
private final class QBasicConsoleIO: QBasicIO {
    let io: IO
    /// Screen control only belongs on a real terminal. `QBASIC /RUN PROG.BAS > LOG.TXT` still
    /// prints to the log, but escape sequences there are garbage; stdin may well be a terminal
    /// in that case, so only the output end is considered.
    private let paintsScreen: Bool

    init(_ io: IO) {
        self.io = io
        paintsScreen = Console.isFullScreen(io.out, inputIsTTY: true)
    }

    func write(_ s: String) { io.out.write(s) }

    func cls() {
        guard paintsScreen else { return }
        io.out.control("\u{1B}[2J\u{1B}[H")
    }

    func locate(_ row: Int, _ col: Int) {
        guard paintsScreen else { return }
        io.out.control("\u{1B}[\(row);\(col)H")
    }

    func color(_ fg: Int, _ bg: Int) {
        guard paintsScreen else { return }
        // DOS and ANSI number the six non-gray colours differently.
        let ansi = [0, 4, 2, 6, 1, 5, 3, 7]
        let fore = ansi[fg & 7] + 30 + (fg >= 8 ? 60 : 0)
        let back = ansi[bg & 7] + 40 + (bg >= 8 ? 60 : 0)
        io.out.control("\u{1B}[\(fore);\(back)m")
    }

    func input(_ prompt: String) -> String? {
        io.out.write(prompt)
        switch io.inFD == 0 ? Console.readLine(template: "") : Console.readLine(fd: io.inFD) {
        case .line(let text): return text
        case .eof, .interrupt: return nil
        }
    }

    func sleep(_ ms: Int) {
        guard ms > 0 else { return }
        Thread.sleep(forTimeInterval: Double(ms) / 1000)
    }

    func key() -> Key? {
        guard io.inFD == 0, KeyReader.hasBufferedKey(fd: 0) else { return nil }
        return KeyReader.read()
    }
}

extension Shell {
    func uQBasic(_ c: Ctx) {
        var words = Tok.posix(c.tail)
        var runOnly = false
        while let first = words.first, first.hasPrefix("/") {
            guard first.uppercased() == "/RUN" else {
                c.out.line("Invalid switch - \(first)")
                errorLevel = 1
                return
            }
            runOnly = true
            words.removeFirst()
        }
        guard words.count <= 1 else {
            c.out.line("Too many parameters")
            errorLevel = 1
            return
        }
        let file = words.first
        if !runOnly {
            errorLevel = QBasicIDE.run(self, c.io, file: file)
            return
        }
        guard let file else {
            c.out.line("Required parameter missing")
            errorLevel = 1
            return
        }
        guard let resolved = try? drives.resolve(file), resolved.exists else {
            c.out.line("File not found")
            errorLevel = 1
            return
        }
        let url = drives.url(resolved)
        guard !isDir(url), let bytes = FileManager.default.contents(atPath: url.path) else {
            c.out.line("File not found")
            errorLevel = 1
            return
        }
        let source = String(decoding: Shell.cutZ(bytes), as: UTF8.self)
        errorLevel = QBasic.run(source: source, io: QBasicConsoleIO(c.io))
    }
}
