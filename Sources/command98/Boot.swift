import Foundation

/// The options IO.SYS would have read out of MSDOS.SYS. Only the ones that change what
/// happens on this machine are kept: whether to show the graphical boot at all, whether
/// the old boot menu was asked for, and how long it wanted to wait.
struct BootOptions: Equatable {
    var bootGUI = false
    var bootMenu = false
    var bootDelay = 0
}

/// What the splash should do on this particular start. `splash` is false for the ordinary
/// command-prompt launch, which is the default when there is no MSDOS.SYS.
struct BootPlan: Equatable {
    var splash = false
    var winComPresent = false
}

/// The Win98-era boot splash. It is only a tribute: WIN.COM is checked and the command
/// prompt follows, but Windows itself never starts. Everything is silent unless
/// C:\MSDOS.SYS asks for it, because that is how the original machine behaved.
enum Boot {
    static let splashText = "Starting Windows 98..."
    static let missingWinText = "WIN.COM is missing, so Windows cannot continue loading."
    static let pressKeyText = "Press any key to return to the command prompt."

    /// The full animation is deliberately short: about seven tenths of a second.
    static let splashFrames = 14
    static let frameSeconds = 0.05

    // MARK: MSDOS.SYS

    /// Reads C:\MSDOS.SYS from the given drive root. A missing file, a missing [Options]
    /// section, or anything unparseable leaves the defaults, which means no splash.
    static func options(root: URL) -> BootOptions {
        var opts = BootOptions()
        guard let file = findFile(named: "MSDOS.SYS", in: root),
              let data = try? Data(contentsOf: file) else { return opts }
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // MSDOS.SYS was padded with ^Z and spaces so its size looked right to old tools.
        if let eof = text.firstIndex(of: "\u{1A}") { text = String(text[..<eof]) }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
                   .replacingOccurrences(of: "\r", with: "\n")

        var inOptions = false
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if let semi = line.firstIndex(of: ";") { line = String(line[..<semi]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let name = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                inOptions = name.caseInsensitiveCompare("Options") == .orderedSame
                continue
            }
            guard inOptions, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).uppercased()
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "BOOTGUI":
                opts.bootGUI = flag(value)
            case "BOOTMENU":
                opts.bootMenu = flag(value)
            case "BOOTDELAY":
                opts.bootDelay = max(0, Int(value) ?? 0)
            default:
                break
            }
        }
        return opts
    }

    /// DOS itself accepted 1/0 here; the words are a harmless extra.
    private static func flag(_ value: String) -> Bool {
        switch value.uppercased() {
        case "1", "ON", "YES", "TRUE": return true
        default: return false
        }
    }

    private static func findFile(named name: String, in dir: URL) -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let actual = entries.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        return dir.appendingPathComponent(actual)
    }

    // MARK: plan

    static func plan(for shell: Shell) -> BootPlan {
        var plan = BootPlan()
        guard let root = shell.drives.table["C"]?.root else { return plan }
        plan.splash = options(root: root).bootGUI
        if let resolved = try? shell.drives.resolve("C:\\WINDOWS\\WIN.COM") {
            plan.winComPresent = resolved.exists
        }
        return plan
    }

    // MARK: screen

    /// One animation frame. Tests use this directly instead of waiting for real ticks.
    static func render(plan: BootPlan, to screen: Screen, tick: Int = 0) {
        screen.clear(ch: " ", fg: 7, bg: 0)
        guard plan.splash else { return }

        // A blue banner across the middle, with the phrase centred inside it.
        let phraseY = screen.height / 2 - 3
        let bandTop = max(0, phraseY - 1)
        let bandHeight = max(0, min(3, screen.height - bandTop))
        screen.fill(x: 0, y: bandTop, width: screen.width, height: bandHeight,
                    ch: " ", fg: 15, bg: 1)
        screen.center(phraseY, splashText, fg: 15, bg: 1)

        // The little progress bar underneath. It advances one step per frame and is
        // clamped, so an injected tick can never scribble off the page.
        let barWidth = max(2, min(40, screen.width - 4))
        let barX = max(0, (screen.width - barWidth) / 2)
        let barY = min(screen.height - 1, max(0, phraseY + 5))
        let inner = barWidth - 2
        screen.put(barX, barY, "[", fg: 7, bg: 0)
        screen.put(barX + barWidth - 1, barY, "]", fg: 7, bg: 0)
        let progress = max(0, min(tick, splashFrames))
        let filled = min(inner, progress * inner / max(1, splashFrames))
        for i in 0..<inner {
            screen.put(barX + 1 + i, barY, " ", fg: 7, bg: i < filled ? 9 : 8)
        }
    }

    private static func animate(to out: Out, frameDelay: () -> Void) {
        Screen.begin(out)
        var previous: Screen?
        for tick in 0...splashFrames {
            let frame = Screen()
            render(plan: BootPlan(splash: true, winComPresent: true), to: frame, tick: tick)
            if let previous {
                frame.renderDiff(to: out, previous: previous)
            } else {
                frame.render(to: out)
            }
            previous = frame.copy()
            if tick < splashFrames { frameDelay() }
        }
        Screen.end(out)
    }

    // MARK: run

    /// Called from main between CONFIG.SYS and AUTOEXEC.BAT. The defaults keep an ordinary
    /// start silent; tests can inject the output, the terminal flag and the frame clock.
    static func run(_ shell: Shell,
                    out: Out = Console.tty,
                    interactive: Bool = Console.isTTY,
                    frameDelay: () -> Void = { Thread.sleep(forTimeInterval: frameSeconds) }) {
        let plan = plan(for: shell)
        guard plan.splash else { return }

        if interactive {
            animate(to: out, frameDelay: frameDelay)
        } else {
            out.line(splashText)
        }

        guard !plan.winComPresent else { return }
        out.line(missingWinText)
        out.line(pressKeyText)
        // The original sat on "Press any key". Redirected input must never hang the shell.
        if interactive && Console.isTTY { _ = Console.readKey() }
    }
}
