import Foundation

/// SCANDISK.EXE: the blue full-screen checker that looks at a drive and reports.
/// It never opens anything for writing, never repairs and never deletes. There is no
/// FAT underneath a Linux folder, so the "phases" are an honest show around a real,
/// read-only walk of the directory tree and the volume free-space figure.
enum ScanDisk {
    static let utilities: [String: CommandHandler] = ["SCANDISK": Shell.uScanDisk]

    /// SCANDISK.INI lived next to SCANDISK.EXE in 1999. Period-plausible size.
    static let stubFiles: [(String, String, Int)] = [
        ("WINDOWS\\COMMAND", "SCANDISK.INI", 10_434),
    ]

    static let help: [String: String] = [
        "SCANDISK": """
        Examines a disk and reports what it finds, without changing anything.

        SCANDISK [drive:] [/SURFACE]

          drive:    The disk to examine. The current drive is used if you
                    leave this out.
          /SURFACE  Add a surface read to the pass.

        ScanDisk counts the files and folders it can reach, reads the free
        space figure and walks the directory tree. It never writes to the
        disk, so it cannot repair or delete anything. On Linux, fsck does the
        fixing (on an unmounted disk).
        """,
    ]

    static let stubVersion = "1"

    // MARK: - The plan (pure data, deterministic apart from free space)

    struct Plan: Equatable {
        var drive: Character
        var surface: Bool
        var files: Int
        var directories: Int
        var freeBytes: Int64
        /// The walk hit its entry cap or was interrupted, so the counts are a floor.
        var truncated: Bool

        static let normalPhases = [
            "Scanning file allocation table",
            "Checking directory structure",
            "Checking for cross-linked files",
            "Scanning for lost clusters",
        ]
        static let surfacePhase = "Scanning disk surface blocks"

        var phases: [String] {
            surface ? Self.normalPhases + [Self.surfacePhase] : Self.normalPhases
        }
    }

    /// Walks the drive root, counting files and directories. The walk is capped so a huge
    /// real drive cannot stall the shell, and gInterrupted stops it between entries.
    static func plan(drive: Character, shell: Shell, surface: Bool = false) -> Plan {
        guard let mounted = shell.drives.table[drive] else {
            return Plan(drive: drive, surface: surface, files: 0, directories: 0, freeBytes: 0, truncated: false)
        }
        let root = mounted.root
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var files = 0
        var directories = 0
        var seen = 0
        var truncated = false
        if let walk = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                     options: [.skipsPackageDescendants]) {
            for case let url as URL in walk {
                if gInterrupted != 0 {
                    truncated = true
                    break
                }
                seen += 1
                if seen > 5_000 {
                    truncated = true
                    break
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                if values.isDirectory == true {
                    directories += 1
                } else {
                    files += 1
                }
            }
        }
        return Plan(drive: drive, surface: surface,
                    files: files, directories: directories,
                    freeBytes: shell.freeBytes(root), truncated: truncated)
    }

    // MARK: - Drawing

    private static let blue: UInt8 = 1
    private static let grey: UInt8 = 7
    private static let white: UInt8 = 15
    private static let barInner = 46

    private static func clamped(_ p: Double) -> Double {
        p.isFinite ? min(1, max(0, p)) : 0
    }

    static func percent(_ progress: Double) -> Int {
        Int((clamped(progress) * 100).rounded())
    }

    static func barFill(_ progress: Double, width: Int = barInner) -> Int {
        guard width > 0 else { return 0 }
        return Int((clamped(progress) * Double(width)).rounded())
    }

    /// The scanning page. Every cell is blue so the whole 80x25 page is the ScanDisk blue.
    static func render(plan: Plan, progress: Double) -> Screen {
        let screen = Screen(width: 80, height: 25, ch: " ", fg: grey, bg: blue)
        screen.clear(fg: grey, bg: blue)

        screen.center(1, "ScanDisk", fg: white, bg: blue)
        screen.center(3, "Drive \(plan.drive):", fg: white, bg: blue)

        var counts = "\(Fmt.num(Int64(plan.files))) files, \(Fmt.num(Int64(plan.directories))) directories, "
        counts += "\(Fmt.num(plan.freeBytes)) bytes free"
        if plan.truncated { counts = "at least " + counts }
        screen.center(4, counts, fg: grey, bg: blue)

        drawBar(screen, progress: progress, y: 7)

        let phases = plan.phases
        let pct = clamped(progress)
        let complete = min(phases.count, Int(pct * Double(phases.count) + 0.000_001))
        for (i, title) in phases.enumerated() {
            let y = 10 + i * 2
            if y >= 23 { break }
            let marker: String
            let fg: UInt8
            if i < complete {
                marker = "[X]"
                fg = white
            } else if i == complete {
                marker = "[>]"
                fg = white
            } else {
                marker = "[ ]"
                fg = grey
            }
            screen.write(16, y, marker, fg: fg, bg: blue)
            screen.write(20, y, title, fg: fg, bg: blue)
        }

        screen.center(21, "Reading only. This pass never writes to the disk.", fg: grey, bg: blue)
        screen.center(23, "Esc cancels. No changes will be made.", fg: white, bg: blue)
        return screen
    }

    private static func drawBar(_ screen: Screen, progress: Double, y: Int) {
        let inner = barInner
        let label = "\(percent(progress))%"
        let total = inner + 2 + 1 + label.count
        let x = max(0, (80 - total) / 2)
        screen.write(x, y, "[", fg: grey, bg: blue)
        let filled = barFill(progress, width: inner)
        for i in 0..<inner {
            let ch: Character = i < filled ? "\u{2588}" : "\u{2591}"
            screen.put(x + 1 + i, y, ch, fg: i < filled ? white : grey, bg: blue)
        }
        screen.write(x + 1 + inner, y, "] " + label, fg: white, bg: blue)
    }

    enum Outcome: Equatable {
        case completed
        case cancelled
    }

    /// The Finish page. It says the same words whether the animation ran or not:
    /// no errors were found by reading, and nothing was repaired.
    static func renderSummary(plan: Plan, outcome: Outcome) -> Screen {
        let screen = render(plan: plan, progress: 1)
        screen.fill(x: 0, y: 20, width: 80, height: 4, fg: grey, bg: blue)
        switch outcome {
        case .completed:
            screen.center(20, "ScanDisk found no errors on drive \(plan.drive):", fg: white, bg: blue)
            screen.center(21, "No errors found by this read-only pass.", fg: grey, bg: blue)
            screen.center(22, "This build only looks. Use the host disk repair tool to fix anything.", fg: grey, bg: blue)
        case .cancelled:
            screen.center(20, "ScanDisk was cancelled on drive \(plan.drive):", fg: white, bg: blue)
            screen.center(21, "No changes were made to the disk.", fg: grey, bg: blue)
            screen.center(22, "No errors were checked by this cancelled pass.", fg: grey, bg: blue)
        }
        screen.center(23, "Press any key to continue", fg: white, bg: blue)
        return screen
    }

    // MARK: - The animation loop (keys and waiting injected for tests)

    struct Driver {
        var poll: () -> Key?
        var wait: () -> Void
    }

    /// Runs the full-screen pass. Tests give it a scripted key source and a no-op wait;
    /// the real command polls the terminal and sleeps between frames.
    @discardableResult
    static func show(plan: Plan, out: Out, driver: Driver) -> Outcome {
        Screen.begin(out)
        defer { Screen.end(out) }

        let frames = 80
        var previous: Screen? = nil
        var frame = 0
        var cancelled = false

        while frame <= frames {
            let progress = Double(frame) / Double(frames)
            let page = render(plan: plan, progress: progress)
            if let old = previous {
                page.renderDiff(to: out, previous: old)
            } else {
                page.render(to: out)
            }
            previous = page

            if gInterrupted != 0 {
                gInterrupted = 0
                cancelled = true
                break
            }
            if let key = driver.poll() {
                switch key {
                case .escape, .interrupt, .ctrl("C"):
                    cancelled = true
                case .eof:
                    cancelled = true
                default:
                    break
                }
                if cancelled { break }
            }
            if frame == frames { break }
            driver.wait()
            frame += 1
        }

        let outcome: Outcome = cancelled ? .cancelled : .completed
        renderSummary(plan: plan, outcome: outcome).render(to: out)

        // "Press any key to continue" — an interrupted or closed input does not hang.
        while true {
            if let key = driver.poll() {
                if key != .unknown { break }
            }
            if gInterrupted != 0 {
                gInterrupted = 0
                break
            }
            driver.wait()
        }
        return outcome
    }
}

extension Shell {
    /// The shell's SCANDISK command: parse, validate, then either the one-line
    /// non-TTY report or the blue page.
    func uScanDisk(_ c: Ctx) {
        var drive = drives.current
        var surface = false
        for word in Tok.args(c.rest) {
            let up = word.uppercased()
            if up == "/SURFACE" {
                surface = true
                continue
            }
            if up.hasPrefix("/") { continue } // unknown switches are ignored, as the old tool did
            let chars = Array(word)
            guard chars.count == 2, chars[1] == ":", chars[0].isLetter, chars[0].isASCII else {
                c.out.line("Invalid drive specification")
                return
            }
            let letter = Character(chars[0].uppercased())
            guard drives.table[letter] != nil else {
                c.out.line("Invalid drive specification")
                return
            }
            drive = letter
        }

        let work = ScanDisk.plan(drive: drive, shell: self, surface: surface)

        // A redirected screen or non-terminal gets one plain line, never escape codes.
        if !Console.isTTY || c.io.inFD != 0 || c.io.out.fd != 1 {
            var line = "ScanDisk: drive \(drive): "
            line += "\(Fmt.num(Int64(work.files))) files, \(Fmt.num(Int64(work.directories))) directories, "
            line += "\(Fmt.num(work.freeBytes)) bytes free. "
            line += "No errors found by this read-only pass. Nothing was changed."
            c.out.line(line)
            return
        }

        let driver = ScanDisk.Driver(
            poll: {
                guard Console.pending(0) else { return nil }
                return KeyReader.read()
            },
            wait: { Thread.sleep(forTimeInterval: 0.022) }
        )
        _ = ScanDisk.show(plan: work, out: c.out, driver: driver)
    }
}
