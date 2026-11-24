import Foundation

/// DEFRAG.EXE: the coloured block show from 1998, with none of the disk access.
///
/// SAFETY: this file is deliberately synthetic. It never opens, stats, reads, writes,
/// renames, truncates, chmods or deletes a file, and it never asks FileManager anything
/// about the drive. Every block comes from a little generator seeded by the drive letter
/// and a constant, so the picture is the same every time and no real allocation table is
/// consulted or touched. A real DEFRAG rewrote the FAT; this one only paints cells.
enum Defrag {
    static let utilities: [String: CommandHandler] = ["DEFRAG": Shell.uDefrag]

    /// The real Win98 SE file was about 147 KB; this is a period-plausible stand-in.
    static let stubFiles: [(String, String, Int)] = [
        ("WINDOWS\\COMMAND", "DEFRAG.EXE", 150_784),
    ]

    static let help: [String: String] = [
        "DEFRAG": """
        Tidies the placement of files on a disk.

        DEFRAG [drive:]

          drive:   The disk to tidy. The current drive is assumed when none is given.

        The block map, the moving blocks and the progress figure are drawn for show.
        This DEFRAG never reads or writes the disk, so every file stays exactly where
        it is.

        Press Esc to stop the display.
        """,
    ]

    static let stubVersion = "1"

    // MARK: - synthetic plan

    /// 20 columns by 10 rows, the same shape the original used on an 80x25 page.
    static let columns = 20
    static let rows = 10

    /// One block stood for a whole run of clusters. Nothing here asks the disk how many.
    static let clustersPerBlock = 256

    static let mapX = 10
    static let mapY = 6
    static let blockCells = 2
    static let blockStride = 3
    static let barY = 17
    static let barWidth = 60

    /// A stable seed, mixed with the drive letter, so C: always looks like C:.
    private static let seedConstant: UInt64 = 0x0DEF_2A6B_1998_0423

    struct Plan {
        let drive: Character
        /// Row-major block map. True means a used block.
        let used: [Bool]
        let clustersPerBlock: Int

        var blockCount: Int { used.count }
        var usedCount: Int { used.reduce(0) { $0 + ($1 ? 1 : 0) } }
        var totalClusters: Int { blockCount * clustersPerBlock }
    }

    struct Move {
        let from: Int
        let to: Int
    }

    /// The fake allocation map. Seeded only by the letter and the constant above; no call
    /// into the file system happens here, not even a stat.
    static func plan(drive: Character) -> Plan {
        let letter = UInt64(drive.unicodeScalars.first?.value ?? 67)
        var rng = Generator(seed: seedConstant ^ (letter &* 0x9E37_79B9_7F4A_7C15))
        let count = columns * rows
        var used = [Bool](repeating: false, count: count)
        for i in 0..<count {
            used[i] = rng.next() % 100 < 56
        }
        // Keep the picture honest: never an empty disk, never a completely full one.
        let minimum = 24
        let maximum = count - 16
        var n = used.reduce(0) { $0 + ($1 ? 1 : 0) }
        var i = 0
        while n < minimum && i < count {
            if !used[i] { used[i] = true; n += 1 }
            i += 1
        }
        i = 0
        while n > maximum && i < count {
            if used[i] { used[i] = false; n -= 1 }
            i += 1
        }
        return Plan(drive: drive, used: used, clustersPerBlock: clustersPerBlock)
    }

    /// Deterministic compaction: every used block tries to move into the first free slot
    /// to its left. This is what the animation draws; it is arithmetic on a Bool array.
    static func moves(for plan: Plan) -> [Move] {
        var occupied = plan.used
        var result: [Move] = []
        for source in 0..<occupied.count where occupied[source] {
            guard let target = (0..<source).first(where: { !occupied[$0] }) else { continue }
            occupied[target] = true
            occupied[source] = false
            result.append(Move(from: source, to: target))
        }
        return result
    }

    // MARK: - frame drawing

    enum BlockState: Equatable {
        case free
        case usedGrey
        case usedCyan
        case movingSource
        case movingTarget
        case done
    }

    /// Pure frame renderer. Progress runs 0...1; values outside are clamped.
    static func frame(_ plan: Plan, progress: Double) -> Screen {
        let p = min(1, max(0, progress))
        let screen = Screen(width: 80, height: 25, fg: 15, bg: 1)

        screen.center(1, "Drive \(plan.drive): Defragmentation", fg: 15, bg: 1)
        screen.write(1, 2, String(repeating: "\u{2550}", count: 78), fg: 7, bg: 1)

        var x = drawLegend(screen, x: mapX, y: 4, state: .usedGrey, label: "Used")
        x = drawLegend(screen, x: x, y: 4, state: .free, label: "Free")
        x = drawLegend(screen, x: x, y: 4, state: .movingSource, label: "Moving")
        _ = drawLegend(screen, x: x, y: 4, state: .done, label: "Done")

        let states = blockStates(plan, progress: p)
        for row in 0..<rows {
            for col in 0..<columns {
                let index = row * columns + col
                drawBlock(screen, x: mapX + col * blockStride, y: mapY + row,
                          state: states[index])
            }
        }

        let percent = Int((p * 100).rounded(.down))
        let filled = Int((p * Double(barWidth)).rounded(.down))
        for i in 0..<barWidth {
            screen.put(mapX + i, barY, " ", fg: 15, bg: i < filled ? 2 : 8)
        }
        screen.write(mapX, 18, "\(percent)% complete", fg: 15, bg: 1)

        let clusters = min(plan.totalClusters,
                           Int((p * Double(plan.totalClusters)).rounded(.down)))
        screen.write(mapX, 19, "Cluster \(clusters) of \(plan.totalClusters)", fg: 15, bg: 1)
        screen.write(mapX, 20, "Press Esc to cancel", fg: 11, bg: 1)
        screen.center(22, "No files will be moved; nothing is written to the disk.", fg: 7, bg: 1)
        return screen
    }

    static func blockStates(_ plan: Plan, progress: Double) -> [BlockState] {
        let p = min(1, max(0, progress))
        let allMoves = moves(for: plan)
        let done = min(allMoves.count, Int((p * Double(allMoves.count)).rounded(.down)))
        var states = [BlockState](repeating: .free, count: plan.blockCount)

        for i in 0..<plan.blockCount where plan.used[i] {
            states[i] = (i + Int(plan.drive.unicodeScalars.first?.value ?? 0)) % 3 == 0
                ? .usedCyan : .usedGrey
        }
        for move in allMoves.prefix(done) {
            states[move.from] = .free
            states[move.to] = .done
        }
        if done < allMoves.count && p < 1 {
            let move = allMoves[done]
            states[move.from] = .movingSource
            states[move.to] = .movingTarget
        }
        if p >= 1 {
            // Blocks that were already in place never needed a move; they finish too.
            for i in 0..<plan.usedCount { states[i] = .done }
        }
        return states
    }

    private static func drawBlock(_ screen: Screen, x: Int, y: Int, state: BlockState) {
        switch state {
        case .free:
            screen.put(x, y, "\u{00B7}", fg: 9, bg: 1)
            screen.put(x + 1, y, " ", fg: 9, bg: 1)
        case .usedGrey:
            fillBlock(screen, x: x, y: y, fg: 7, bg: 7)
        case .usedCyan:
            fillBlock(screen, x: x, y: y, fg: 3, bg: 3)
        case .movingSource:
            fillBlock(screen, x: x, y: y, fg: 12, bg: 12)
        case .movingTarget:
            fillBlock(screen, x: x, y: y, fg: 14, bg: 14)
        case .done:
            fillBlock(screen, x: x, y: y, fg: 2, bg: 2)
        }
    }

    private static func fillBlock(_ screen: Screen, x: Int, y: Int, fg: UInt8, bg: UInt8) {
        for i in 0..<blockCells {
            screen.put(x + i, y, " ", fg: fg, bg: bg)
        }
    }

    @discardableResult
    private static func drawLegend(_ screen: Screen, x: Int, y: Int,
                                   state: BlockState, label: String) -> Int {
        drawBlock(screen, x: x, y: y, state: state)
        screen.write(x + blockStride, y, label, fg: 15, bg: 1)
        return x + blockStride + label.count + 3
    }

    // MARK: - animation

    enum Outcome: Equatable {
        case complete
        case cancelled
    }

    static let defaultFrames = 120
    static let frameDelay = 0.03

    /// The animated pass. Tests replace the clock and the key source; nothing else in the
    /// utility depends on wall time or the terminal.
    @discardableResult
    static func animate(_ plan: Plan, out: Out, frames: Int,
                        tick: (Int) -> Void,
                        key: () -> Key?,
                        observe: ((Screen, Int) -> Void)? = nil) -> Outcome {
        Screen.begin(out)
        defer { Screen.end(out) }

        let total = max(1, frames)
        var previous: Screen? = nil
        for frameNumber in 0..<total {
            let progress = total == 1 ? 1.0 : Double(frameNumber) / Double(total - 1)
            let screen = frame(plan, progress: progress)
            if let previous {
                screen.renderDiff(to: out, previous: previous)
            } else {
                screen.render(to: out)
            }
            observe?(screen, frameNumber)
            previous = screen

            guard frameNumber < total - 1 else { break }
            tick(frameNumber)
            // ^C during the sleep sets the shell-wide flag; treat it like Esc and clear it
            // so the next command does not inherit the interrupt.
            if gInterrupted != 0 {
                gInterrupted = 0
                return .cancelled
            }
            if let pressed = key(), pressed == .escape || pressed == .interrupt {
                return .cancelled
            }
        }
        return .complete
    }

    /// Runs the display and prints the one summary line the caller sees afterwards.
    /// `frames`, `tick` and `key` are the test seams; the command itself uses the 120
    /// frames at 30 ms and real keyboard polling.
    @discardableResult
    static func run(drive: Character, out: Out,
                    frames: Int = defaultFrames,
                    tick: (Int) -> Void = { _ in
                        Thread.sleep(forTimeInterval: frameDelay)
                    },
                    key: () -> Key? = pollKey) -> Outcome {
        let plan = plan(drive: drive)
        let outcome = Console.withRaw {
            animate(plan, out: out, frames: frames, tick: tick, key: key)
        }
        switch outcome {
        case .complete:
            out.line("Defragmentation complete. No files were moved.")
        case .cancelled:
            out.line("Defrag cancelled. No files were moved.")
        }
        return outcome
    }

    /// Esc, or any byte already waiting. Keys other than Esc are ignored by the animation.
    static func pollKey() -> Key? {
        guard KeyReader.hasBufferedKey(fd: 0) else { return nil }
        return KeyReader.read()
    }

    /// Small deterministic generator; the same seed always draws the same map.
    private struct Generator {
        var state: UInt64

        init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
    }
}

extension Shell {
    /// DEFRAG [drive:]. The drive table is the only thing consulted; no file is opened.
    func uDefrag(_ c: Ctx) {
        guard let drive = driveArg(c) else {
            errorLevel = 1
            return
        }
        guard c.io.inFD == 0, Console.isFullScreen(c.out) else {
            c.out.line("DEFRAG needs an interactive console. No files were moved.")
            errorLevel = 1
            return
        }
        _ = Defrag.run(drive: drive, out: c.out)
    }
}
